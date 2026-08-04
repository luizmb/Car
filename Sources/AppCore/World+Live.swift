import AVFoundation
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

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-GB")
        u.rate  = 0.65
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }
}

// MARK: - Live world

extension World {
    public static var real: World {
        let loc       = LocationBox()
        let roadSpeed = RoadSpeedBox(minDistance: Meters(300), minTime: 20)
        let speech    = SpeechBox()
        let indimate  = IndimateCentral()
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
            speak: { text in
                Publisher.future { DispatchQueue.main.async { speech.speak(text) } }
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
