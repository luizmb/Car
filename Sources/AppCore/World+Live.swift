import AVFoundation
import AudioToolbox
import UIKit
import ReactiveConcurrency
import Core
import CoreBluetooth
import CoreLocation
import AppDomain
import FP
import Foundation
import NetworkClient
import SpeedMonitorFeature

// MARK: - Private boxes (@unchecked Sendable wrappers for ObjC types)

private final class LocationBox: @unchecked Sendable {
    nonisolated(unsafe) let manager: CLLocationManager = {
        let m = CLLocationManager()
        m.desiredAccuracy                    = kCLLocationAccuracyBestForNavigation
        m.allowsBackgroundLocationUpdates    = true
        m.pausesLocationUpdatesAutomatically = false
        return m
    }()
    nonisolated(unsafe) let delegate = LocationDelegate()
}

/// How good a voice is, as one number.
///
/// `quality` is the headline, but it does not separate the two worst tiers: both `compact` and
/// `super-compact` report `.default`, and super-compact is markedly the more synthetic of the two.
/// The identifier says which, so it breaks the tie.
private func voiceRank(_ voice: AVSpeechSynthesisVoice) -> Int {
    let identifier = voice.identifier.lowercased()
    let tier: Int = if identifier.contains("premium") {
        30
    } else if identifier.contains("enhanced") {
        20
    } else if identifier.contains("super-compact") {
        0
    } else {
        10
    }
    return voice.quality.rawValue * 100 + tier
}

private final class SpeechBox: @unchecked Sendable {
    nonisolated(unsafe) let synth = AVSpeechSynthesizer()
    // Releasing the session between journeys is a real saving — an active `.playback` session with
    // `.duckOthers` dips every other app's audio for as long as we hold it. It is deliberately *not*
    // done yet: GPS, motion and the road lookup all still run continuously, so gating audio alone
    // would be one piece of the battery plan out of order, adding a failure mode before the
    // observation week that is meant to inform the whole thing. See the battery strategy notes.

    init() {
        // `.duckOthers` (not `.mixWithOthers`) is what lets Music and Apple Maps keep playing
        // while dipping under our audio — the arrangement the rider already runs four apps on.
        // The session is activated once and never deactivated: `setActive(false)` would cut the
        // indicator loop as well as speech, and the app spends whole journeys backgrounded.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        // **Recover from route changes.**
        //
        // `AVSpeechSynthesizer` is one long-lived object, and it wedges if the route disappears
        // while it is speaking: every later utterance queues behind the stuck one and is never
        // heard. On 2026-08-06 the Cardo dropped at 19:19:27, one second before "journey finished"
        // was spoken, and the entire return leg was silent — while the indicator *sound* kept
        // working, because that builds a fresh `AVAudioPlayer` each time and recovers by accident.
        //
        // Clearing the synthesiser and reactivating the session on every route change gives speech
        // the same accidental recovery, deliberately.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.synth.stopSpeaking(at: .immediate)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }
    }

    /// Interrupts whatever is playing. For time-critical announcements only — a speed threshold
    /// spoken late is worse than useless, because the number no longer matches the moment.
    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        synth.speak(utterance(text))
    }

    /// Queues behind whatever is playing, interrupting nothing.
    ///
    /// Everything informational goes through here: road names, Indimate connect/disconnect, tyre
    /// warnings. Previously all speech interrupted all other speech, so a road announcement and a
    /// threshold crossing simply cut each other in half and the rider heard neither.
    func enqueue(_ text: String) {
        synth.speak(utterance(text))
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = SpeechBox.voice
        // 0.65 was too fast for the old compact voice and 0.52 too slow for the premium one: a
        // neural voice keeps its consonants at pace, so it can carry speed that a compact voice
        // could not. Apple's default is 0.5.
        u.rate  = 0.57
        return u
    }

    /// The best British voice actually installed, rather than whatever the language defaults to.
    ///
    /// `AVSpeechSynthesisVoice(language: "en-GB")` returns the system default, which on a phone
    /// nobody has configured is `com.apple.voice.super-compact.en-GB.Daniel` — the smallest and
    /// most synthetic tier Apple ships, and the reason the app sounded like a 1990s answering
    /// machine. Enumerating and ranking costs nothing and picks a premium or enhanced voice the
    /// moment one exists.
    ///
    /// The good ones are **downloads**, not code: Settings → Accessibility → Spoken Content →
    /// Voices → English (UK). Until one is installed there is genuinely nothing better on the
    /// device, so this degrades to the same voice as before rather than pretending otherwise.
    nonisolated(unsafe) static let voice: AVSpeechSynthesisVoice? = {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            // British first. The novelty voices (Zarvox, Bells, Bad News) are `en-US` and live
            // under a different identifier prefix — excluded explicitly, because a ranking that
            // ever picked one would be a very bad surprise at 60 mph.
            $0.language.hasPrefix("en-GB")
                && !$0.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
                && !$0.identifier.lowercased().contains("eloquence")
        }
        return candidates.max { voiceRank($0) < voiceRank($1) }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }()

    /// Speaks a sequence with a pause between each item.
    ///
    /// Stops only **once**, up front, then enqueues the lot — `AVSpeechSynthesizer` maintains its
    /// own queue, and calling `stopSpeaking` per item (as `speak` does) would cancel each utterance
    /// with the next. The gap comes from `postUtteranceDelay` rather than sleeping between calls,
    /// so the whole briefing is handed over in one go and survives the app being backgrounded
    /// mid-sentence.
    func speakSequence(_ texts: [String], gap: TimeInterval) {
        guard !texts.isEmpty else { return }
        // Only stop if something is actually speaking, and let the stop settle before enqueuing.
        // `stopSpeaking` is asynchronous, and utterances submitted while the synthesiser is still
        // tearing down are silently dropped — a stop issued when nothing was playing could
        // therefore swallow the entire briefing.
        //
        // The 150 ms stays a raw `asyncAfter` rather than `Publisher.delay(_:clock:)` on purpose.
        // It is not domain timing — nothing decides anything on this interval, and no test would
        // ever want to control it. It is a workaround for `AVSpeechSynthesizer`'s asynchronous
        // teardown, local to this driver, and dressing it up as an injectable clock would imply a
        // schedule that does not exist.
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
            let queued = texts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.enqueue(queued, gap: gap)
            }
            return
        }
        enqueue(texts, gap: gap)
    }

    private func enqueue(_ texts: [String], gap: TimeInterval) {
        for text in texts {
            let u = AVSpeechUtterance(string: text)
            u.voice = SpeechBox.voice
            u.rate  = 0.57
            u.postUtteranceDelay = gap
            synth.speak(u)
        }
    }
}

// MARK: - Tyre configuration
//
// Serials and bands read off the FOBO app for "Milky Way". The other bike parks in the same garage
// and broadcasts on the same scan; its sensors (serial prefix `0a`) are simply not listed, so they
// are discarded rather than filtered by signal strength — which measured −99 to −59 dBm on a single
// sensor and is far too noisy to sort tyres by.

private let milkyWaySensors: [TyreSensor] = [
    TyreSensor(serial: "097d12", position: .front),
    TyreSensor(serial: "09845f", position: .rear)
]

private let milkyWayBands: [TyrePosition: TyreThresholds] = [
    .front: TyreThresholds(minimum: PSI(29), recommended: PSI(31), maximum: PSI(39)),
    .rear:  TyreThresholds(minimum: PSI(33), recommended: PSI(36), maximum: PSI(45))
]

// MARK: - Simulator rig
//
// A simulator has no bike. There is no CHIGEE to say the ignition is on, no Indimate to report the
// indicators, and the audio route is always "Speaker", so the app decides the helmet intercom is
// absent — and the cues that matter most are the ones gated on all three.
//
// Faked at the `World` boundary rather than by dispatching actions into the store, which was tried
// and does not work: the real streams emit on subscribe and on every supervision pass, so a
// pretended state is overwritten within the second. Replacing the stream is the only level at which
// the lie holds.
//
// Compiled out entirely on device.

#if targetEnvironment(simulator)
/// Emits its values and then parks.
///
/// Parking matters: supervision re-subscribes a channel whose stream has finished, so a factory
/// that emitted and returned would re-emit for ever in a tight loop.
private func fakeStream<A: Sendable>(_ values: [A]) -> Publisher<A, Never> {
    Publisher { continuation in
        for value in values { continuation.yield(value) }
        try? await Task.sleep(for: .seconds(86_400))
    }
}

private let simulatedBluetoothRoute = AudioRoute(outputs: [
    AudioOutput(portType: "BluetoothA2DPOutput", portName: "PT EDGE (simulated)", uid: "sim-cardo")
])
#endif

// MARK: - Live world

extension World {
    public static var real: World {
        let loc       = LocationBox()
        let roadSpeed = RoadSpeedBox(minDistance: Meters(300), minTime: 20)
        // Cameras are fetched over a wide radius and rarely: 1 km of travel or two minutes. The set
        // barely changes over that distance, and the per-fix "is one ahead" test needs no network.
        // **Once per journey, near enough.** 40 km travelled, 50 km of radius.
        //
        // The same geometry as before at a different scale — leaving a 50 km circle takes more than
        // 40 km of travel — but the reason for the scale is rate limiting, and it is measured rather
        // than assumed. Ten consecutive road queries to `overpass-api.de` on 2026-08-06 returned
        // five 429s; the successes took 1–2 s and the refusals took 7–12 s. Overpass limits per IP
        // *across all queries*, so a camera fetch every 2 km was competing directly with the road
        // lookup — and the day cameras shipped was the day road limits stopped arriving.
        //
        // At this cadence a typical ride makes one camera request instead of fifteen, and 50 km is
        // further than this rider goes before stopping, which starts a fresh journey anyway.
        let cameraLoc = RoadSpeedBox(minDistance: Meters(40_000), minTime: 120)
        let speech    = SpeechBox()
        let indimate  = IndimateCentral()
        let cardo     = CardoCentral()
        let chigee    = ChigeeCentral()
        let tyres     = TyreCentral()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Two files, deliberately. `journey-*` is the record; `debug-*` is the dump.
        let rideLog    = ActionLogBox(directory: documents, prefix: "debug", now: { Date() })
        // The journey timeline now lives in the app database; only the debug firehose - the
        // temporary, deleted-weekly dump - remains a text file, because grep is its query engine.
        let appDatabase = AppDatabase()
        let watchLink = PhoneWatchBox()
        let cameraOCR = CameraOCRBox()
        let replayBox = ReplayBox()
        let motionBox = MotionBox()
        let device    = DeviceBox()
        let ticks     = IndicatorAudioBox()
        // Absent is normal: without the extract the app behaves exactly as it did before, which is
        // the point of it being a cache rather than a replacement.
        let localRoads = LocalRoadStore()

        // Which voice actually got picked, once, at startup. Without it there is no way to tell a
        // phone with premium voices installed from one still on super-compact — they sound
        // different and nothing else reports which is in use.
        rideLog.append(
            "voice-chosen \(SpeechBox.voice?.identifier ?? "none") "
                + "quality=\(SpeechBox.voice?.quality.rawValue ?? 0)"
        )
        // Every British voice on the device, not just the winner. Ranking cannot improve on a list
        // of one, so the only question that matters is whether a better one is installed at all —
        // and that is a fact about this phone, which no amount of code can report from here.
        for installed in AVSpeechSynthesisVoice.speechVoices()
            where installed.language.hasPrefix("en") {
            rideLog.append(
                "voice-available \(installed.language) q=\(installed.quality.rawValue) "
                    + "\(installed.identifier)"
            )
        }

        // Locale captured once — all formatters below are pure closures over this snapshot
        let locale     = Locale.current
        let numFmt0dp  = FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(0))
        let numFmt1dp  = FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(1))
        let numFmt5dp  = FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(5))
        let speedFmt   = Measurement<UnitSpeed>.FormatStyle(
            width: .abbreviated, usage: .asProvided,
            numberFormatStyle: numFmt0dp
        )
        let altFmt     = Measurement<UnitLength>.FormatStyle(
            width: .abbreviated, usage: .asProvided,
            numberFormatStyle: numFmt1dp
        )

        // Locale-aware number reading and writing. Captured once, like every other formatter here,
        // so nothing downstream ever touches `Locale.current`.
        let numberParser: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 3
            return formatter
        }()

        // Overpass API client — HTTPClient over URLSession (NetworkTools 0.7)
        let httpClient = HTTPClient.live(session: .shared)
        let decoder       = JSONDecoder().dataDecoder(for: OverpassResponse.self)
        let cameraDecoder = JSONDecoder().dataDecoder(for: OverpassCameraResponse.self)
        let stationDecoder = JSONDecoder().dataDecoder(for: OverpassStationResponse.self)
        let weatherDecoder = JSONDecoder().dataDecoder(for: OpenMeteoResponse.self)
        let weatherFetch   = makeWeatherFetch(httpClient: httpClient, decoder: weatherDecoder)

        return World(
            requestAuthorization: {
                Publisher.future { DispatchQueue.main.async { loc.manager.requestAlwaysAuthorization() } }
            },
            authorizationUpdates: {
                DeferredStream {
                    let (stream, continuation) = AsyncStream<AuthorizationUpdate>.makeStream()
                    Task { @MainActor in
                        loc.delegate.authContinuation = continuation
                        loc.manager.delegate          = loc.delegate
                        // Yield current status immediately — covers the "already authorised"
                        // case and any sync firing of locationManagerDidChangeAuthorization.
                        continuation.yield(AuthorizationUpdate(
                            loc.manager.authorizationStatus,
                            loc.manager.accuracyAuthorization
                        ))
                    }
                    return stream
                }
                .eraseToPublisher()
            },
            locationUpdates: {
                // Only subscribed after .readyToMonitor — the manager's delegate is
                // already set by the authorizationUpdates factory at that point.
                DeferredStream {
                    let (stream, continuation) = AsyncStream<LocationUpdate>.makeStream()
                    Task { @MainActor in
                        loc.delegate.locationContinuation = continuation
                        loc.manager.startUpdatingLocation()
                    }
                    return stream
                }
                .eraseToPublisher()
            },
            subscribeToRoadSpeed: {
                makeRoadSpeedStream(
                    box: roadSpeed,
                    httpClient: httpClient,
                    decoder: decoder,
                    localRoad: { latitude, longitude, course in
                        localRoads?.road(at: latitude, longitude: longitude, course: course)
                    },
                    reverseGeocode: GeocoderBox.streetName,
                    log: rideLog.append
                )
            },
            localRoad: { latitude, longitude, course in
                localRoads?.road(at: latitude, longitude: longitude, course: course)
            },
            camerasOnRoad: { key, latitude, longitude in
                .just(localRoads?.cameras(on: key, near: latitude, longitude: longitude) ?? nil)
            },
            subscribeToCameras: {
                makeCameraStream(
                    box: cameraLoc,
                    httpClient: httpClient,
                    decoder: cameraDecoder,
                    radius: Meters(50_000),
                    localCameras: { latitude, longitude, radius in
                        localRoads?.cameraSet(near: latitude, longitude: longitude, radius: radius)
                    },
                    log: rideLog.append
                )
            },
            reverseGeocode: GeocoderBox.streetName,
            refreshRoadNow: { latitude, longitude in
                Publisher.future {
                    DispatchQueue.main.async {
                        forceRoadRefresh(box: roadSpeed, at: (latitude, longitude))
                    }
                }
            },
            bluetoothAuthorization: { CBManager.authorization.domain },
            indimateEvents: {
                #if targetEnvironment(simulator)
                return fakeStream([
                    IndimateEvent.availability(.ready),
                    IndimateEvent.connected
                ])
                #else
                return makeIndimateStream(
                    central: indimate,
                    knownIdentifier: IndimatePeripheralStore.load,
                    onLearn: IndimatePeripheralStore.save
                )
                #endif
            },
            playIndicatorLoop: { side in
                Publisher.future { DispatchQueue.main.async { ticks.play(side) } }
            },
            stopIndicatorLoop: {
                Publisher.future { DispatchQueue.main.async { ticks.stop() } }
            },
            tyreReadings: {
                makeTyreStream(central: tyres)
                    .compactMap { resolveTyreReading($0, sensors: milkyWaySensors, thresholds: milkyWayBands) }
            },
            formatPressure: { numFmt1dp.format($0.rawValue) + " psi" },
            formatTemperature: { numFmt0dp.format($0.rawValue) + "°C" },
            chigeeEvents: {
                #if targetEnvironment(simulator)
                return fakeStream([ChigeeEvent.present])
                #else
                return makeChigeeStream(
                    central: chigee,
                    knownIdentifier: ChigeePeripheralStore.load,
                    log: rideLog.append,
                    onLearn: ChigeePeripheralStore.save
                )
                #endif
            },
            cardoEvents: { makeCardoStream(central: cardo, log: rideLog.append) },
            audioRouteChanges: {
                #if targetEnvironment(simulator)
                // The Cardo is judged present by the audio route, so a simulated Bluetooth output
                // is all it takes for every intercom-gated cue to fire.
                return fakeStream([simulatedBluetoothRoute])
                #else
                return makeAudioRouteStream()
                #endif
            },
            barometer: { makeBarometerStream(box: motionBox) },
            motion: { makeMotionStream(box: motionBox) },
            motionActivity: { makeActivityStream(box: motionBox) },
            fetchWeather: weatherFetch,
            loadTripDistance: {
                Publisher.future { () -> Result<Double, FileError> in
                    guard let appDatabase else { return .failure(.unreadable("app database unavailable")) }
                    return appDatabase.tripDistance().map(Result.success) ?? .failure(.notFound)
                }
            },
            saveTripDistance: { metres in
                Publisher.future { () -> Result<Void, FileError> in
                    guard let appDatabase else { return .failure(.unwritable("app database unavailable")) }
                    appDatabase.saveTripDistance(metres)
                    return .success(())
                }
            },
            loadFuelLog: {
                Publisher.future { () -> Result<FuelLog, FileError> in
                    appDatabase.map { .success($0.fuelLog()) }
                        ?? .failure(.unreadable("app database unavailable"))
                }
            },
            saveFuelLog: { log in
                Publisher.future { () -> Result<Void, FileError> in
                    guard let appDatabase else { return .failure(.unwritable("app database unavailable")) }
                    appDatabase.save(log)
                    return .success(())
                }
            },
            loadMaintenanceLog: {
                Publisher.future { () -> Result<MaintenanceLog, FileError> in
                    appDatabase.map { .success($0.maintenanceLog()) }
                        ?? .failure(.unreadable("app database unavailable"))
                }
            },
            saveMaintenanceLog: { log in
                Publisher.future { () -> Result<Void, FileError> in
                    guard let appDatabase else { return .failure(.unwritable("app database unavailable")) }
                    appDatabase.save(log)
                    return .success(())
                }
            },
            sendWatchSnapshot: { snapshot in
                Publisher.future { watchLink.send(snapshot) }
            },
            watchRefuels: { watchLink.refuels },
            captureText: { cameraOCR.recognizedText },
            stopTextCapture: { Publisher.future { cameraOCR.finishAll() } },
            cameraPreview: { cameraOCR.previewLayer() },
            playback: { steps in replayBox.play(steps) },
            stopPlayback: { Publisher.future { replayBox.stop() } },
            phoneBattery: { device.batteryLevel },
            isLowPowerMode: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            fetchStation: { latitude, longitude in
                // The same 150 m the Overpass query uses. Tight on purpose: this runs while the
                // rider is standing *at* the pump, so anything a street away is a different station
                // and a wrong attribution is worse than none.
                if let local = localRoads?.station(
                    near: latitude, longitude: longitude, radius: Meters(150)
                ) {
                    rideLog.append("station-local id=\(local.id)")
                    return .just(local)
                }
                // A miss falls through rather than being trusted — abroad, or a forecourt that
                // opened after the extract was built, and this request is made once while stopped.
                // A fill with no station is worth far more than no fill, so a request that will
                // not build is simply no station.
                guard let request = overpassStationRequest(
                    latitude: latitude, longitude: longitude
                ) else { return .just(nil) }
                return httpClient(request)
                    .validateStatusCode()
                    .decode(using: stationDecoder)
                    .map { nearestStation($0, to: (latitude, longitude)) }
                    .catch { _ in Publisher<FuelStation?, Never>.just(nil) }
            },
            parseNumber: { text in
                // The device's own formatter first, so a comma-decimal keypad is read the way the
                // rider expects. `parseDecimal` is the fallback rather than the primary because it
                // guesses at the separator, which the locale actually knows — but it accepts a
                // period typed on a comma locale (and vice versa), which the formatter refuses, and
                // being forgiving matters more here than being pedantic.
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return .failure(.empty) }
                if let number = numberParser.number(from: trimmed) { return .success(number.doubleValue) }
                guard let loose = parseDecimal(trimmed) else { return .failure(.unparseable(text)) }
                return .success(loose)
            },
            formatNumber: { value in
                numberParser.string(from: NSNumber(value: value))
                    .map(Result.success) ?? .failure(.unformattable(value))
            },
            now: { Date() },
            newID: { UUID() },
            logAction: { line in
                Publisher.future { rideLog.append(line) }
            },
            loadRecentDestinations: {
                Publisher.future {
                    recentDestinations(from: appDatabase?.recentDestinationRecords() ?? [])
                }
            },
            loadRideSummaries: {
                Publisher.future { appDatabase?.rideSummaries() ?? [] }
            },
            loadRideRecords: { start, seconds in
                Publisher.future { appDatabase?.rideRecords(from: start, seconds: seconds) ?? [] }
            },
            writeShareFile: { name, contents in
                Publisher.future {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(name)
                    guard (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil
                    else { return nil }
                    return url
                }
            },
            logJourney: { event in
                Publisher.future {
                    appDatabase?.append(JourneyRecord(time: Date(), payload: event))
                }
            },
            speak: { text in
                // Every utterance, with the time it was handed over. Step transitions were already
                // logged and were not enough: they show which manoeuvre is current, not what the
                // rider actually heard or when. Told that an instruction arrived one junction
                // early, there was no way to tell a wrong step from the right step at the wrong
                // moment from something arriving late — three different bugs.
                rideLog.append("say! \(text)")
                return Publisher.future { DispatchQueue.main.async { speech.speak(text) } }
            },
            speakQueued: { text in
                rideLog.append("say \(text)")
                return Publisher.future { DispatchQueue.main.async { speech.enqueue(text) } }
            },
            speakSequence: { texts, gap in
                Publisher.future { DispatchQueue.main.async { speech.speakSequence(texts, gap: gap) } }
            },
            announceOverLimit: {
                Publisher.future { DispatchQueue.main.async { speech.speak("over") } }
            },
            announceUnderLimit: {
                Publisher.future { DispatchQueue.main.async { speech.speak("back") } }
            },
            playRerouteTone: {
                // A system sound rather than an asset: it needs no file, ducks nothing, and cannot
                // be cut off by speech the way an `AVAudioPlayer` competing for the session can.
                // 1113 is the short double note iOS uses for "begin recording" — distinctive,
                // unmistakably not an alert, and about a third of a second.
                Publisher.future { AudioServicesPlaySystemSound(1113) }
            },
            completeAddress: RoutingClient.completeAddress,
            resolveAddress: RoutingClient.resolve,
            routes: RoutingClient.routes,
            thresholds: [110.0, 99, 88, 77, 66, 55, 44, 33, 22, 11].map { MPH($0) },
            formatSpeed: {
                Measurement(value: $0.rawValue, unit: UnitSpeed.milesPerHour).formatted(speedFmt)
            },
            formatSpeedSpeech: { @Sendable mph in numFmt0dp.format(mph.rawValue) },
            formatAltitude: {
                Measurement(value: $0.rawValue, unit: UnitLength.meters).formatted(altFmt)
            },
            formatDistance: { metres in
                // `.road` usage, which is what makes this different from `formatAltitude` despite
                // the shared unit: it picks the unit the locale signs roads in — miles here — and
                // rounds the way a sign does rather than to a fixed number of places.
                Measurement(value: metres.rawValue, unit: UnitLength.meters)
                    .formatted(
                        .measurement(width: .abbreviated, usage: .road)
                            .locale(locale)
                    )
            },
            formatDuration: { seconds in
                // `.abbreviated` reads as "1 hr 24 min", which is what a rider scans. `.short`
                // would give "1:24" and be read as a time of day at a glance.
                Duration.seconds(seconds).formatted(
                    .units(allowed: [.hours, .minutes], width: .abbreviated)
                        .locale(locale)
                )
            },
            formatTime: { date in
                date.formatted(.dateTime.hour().minute().locale(locale))
            },
            formatDayTime: { date in
                date.formatted(
                    .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                        .hour().minute().locale(locale)
                )
            },
            formatBearing: { @Sendable course in numFmt1dp.format(course.rawValue) },
            formatCoordinate: { lat, lon in
                CardinalDirection.format(
                    numberFormatter: numFmt5dp,
                    latitude:  lat,
                    longitude: lon
                )
            }
        )
    }
}
