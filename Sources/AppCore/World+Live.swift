import AVFoundation
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

private final class SpeechBox: @unchecked Sendable {
    nonisolated(unsafe) let synth = AVSpeechSynthesizer()

    init() {
        // `.duckOthers` (not `.mixWithOthers`) is what lets Music and Apple Maps keep playing
        // while dipping under our audio — the arrangement the rider already runs four apps on.
        // The session is activated once and never deactivated: `setActive(false)` would cut the
        // indicator loop as well as speech, and the app spends whole journeys backgrounded.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
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
        u.voice = AVSpeechSynthesisVoice(language: "en-GB")
        u.rate  = 0.65
        return u
    }

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
            u.voice = AVSpeechSynthesisVoice(language: "en-GB")
            u.rate  = 0.65
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

// MARK: - Live world

extension World {
    public static var real: World {
        let loc       = LocationBox()
        let roadSpeed = RoadSpeedBox(minDistance: Meters(300), minTime: 20)
        let speech    = SpeechBox()
        let indimate  = IndimateCentral()
        let cardo     = CardoCentral()
        let chigee    = ChigeeCentral()
        let tyres     = TyreCentral()
        let rideLog   = ActionLogBox()
        let motionBox = MotionBox()
        let device    = DeviceBox()
        let ticks     = IndicatorAudioBox()

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

        // Overpass API client — HTTPClient over URLSession (NetworkTools 0.7)
        let httpClient = HTTPClient.live(session: .shared)
        let decoder       = JSONDecoder().dataDecoder(for: OverpassResponse.self)
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
                    decoder: decoder
                )
            },
            bluetoothAuthorization: { CBManager.authorization.domain },
            indimateEvents: { makeIndimateStream(central: indimate) },
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
            chigeeEvents: { makeChigeeStream(central: chigee, log: rideLog.append) },
            cardoEvents: { makeCardoStream(central: cardo) },
            audioRouteChanges: { makeAudioRouteStream() },
            barometer: { makeBarometerStream(box: motionBox) },
            motion: { makeMotionStream(box: motionBox) },
            motionActivity: { makeActivityStream(box: motionBox) },
            fetchWeather: weatherFetch,
            loadTripDistance: { makeFileReader(Double.self, filename: TripStore.filename) },
            saveTripDistance: { makeFileWriter($0, filename: TripStore.filename) },
            loadFuelLog: { makeFileReader(FuelLog.self, filename: FuelStore.filename) },
            saveFuelLog: { makeFileWriter($0, filename: FuelStore.filename) },
            phoneBattery: { device.batteryLevel },
            isLowPowerMode: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            now: { Date() },
            newID: { UUID() },
            logAction: { line in
                Publisher.future { rideLog.append(line) }
            },
            speak: { text in
                Publisher.future { DispatchQueue.main.async { speech.speak(text) } }
            },
            speakQueued: { text in
                Publisher.future { DispatchQueue.main.async { speech.enqueue(text) } }
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
            thresholds: [110.0, 99, 88, 77, 66, 55, 44, 33, 22, 11].map { MPH($0) },
            formatSpeed: {
                Measurement(value: $0.rawValue, unit: UnitSpeed.milesPerHour).formatted(speedFmt)
            },
            formatSpeedSpeech: { @Sendable mph in numFmt0dp.format(mph.rawValue) },
            formatAltitude: {
                Measurement(value: $0.rawValue, unit: UnitLength.meters).formatted(altFmt)
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
