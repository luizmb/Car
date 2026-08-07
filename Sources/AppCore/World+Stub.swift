import AppDomain
import Foundation
import ReactiveConcurrency

public extension World {
    /// A `World` that does nothing, for tests that care about *wiring* rather than behaviour.
    ///
    /// Every stream is empty and every command a no-op, so a store built on it is inert except for
    /// the reducers — which is exactly what a wiring test needs to observe.
    static var stub: World {
        World(
            requestAuthorization: { .empty() },
            authorizationUpdates: { .empty() },
            locationUpdates: { .empty() },
            subscribeToRoadSpeed: { .empty() },
            localRoad: { _, _, _ in nil },
            subscribeToCameras: { .empty() },
            reverseGeocode: { _, _ in .just(nil) },
            refreshRoadNow: { _, _ in .empty() },
            bluetoothAuthorization: { .notDetermined },
            indimateEvents: { .empty() },
            playIndicatorLoop: { _ in .empty() },
            stopIndicatorLoop: { .empty() },
            tyreReadings: { .empty() },
            formatPressure: { "\($0.rawValue)" },
            formatTemperature: { "\($0.rawValue)" },
            chigeeEvents: { .empty() },
            cardoEvents: { .empty() },
            audioRouteChanges: { .empty() },
            barometer: { .empty() },
            motion: { .empty() },
            motionActivity: { .empty() },
            fetchWeather: { _, _ in .empty() },
            loadTripDistance: { .just(.success(0)) },
            saveTripDistance: { _ in .just(.success(())) },
            loadFuelLog: { .just(.success(.empty)) },
            saveFuelLog: { _ in .just(.success(())) },
            phoneBattery: { 1.0 },
            isLowPowerMode: { false },
            fetchStation: { _, _ in .just(nil) },
            parseNumber: { parseDecimal($0).map(Result.success) ?? .failure(.unparseable($0)) },
            formatNumber: { .success(String($0)) },
            now: { Date(timeIntervalSince1970: 0) },
            newID: { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! },
            logAction: { _ in .empty() },
            logJourney: { _ in .empty() },
            speak: { _ in .empty() },
            speakQueued: { _ in .empty() },
            speakSequence: { _, _ in .empty() },
            announceOverLimit: { .empty() },
            announceUnderLimit: { .empty() },
            completeAddress: { _, _, _ in .empty() },
            resolveAddress: { _ in .empty() },
            routes: { _, _, _ in .empty() },
            thresholds: [],
            formatSpeed: { "\($0.rawValue)" },
            formatSpeedSpeech: { "\($0.rawValue)" },
            formatAltitude: { "\($0.rawValue)" },
            formatDistance: { "\($0.rawValue)" },
            formatDuration: { "\($0)" },
            formatTime: { "\($0)" },
            formatBearing: { "\($0.rawValue)" },
            formatCoordinate: { _, _ in "" }
        )
    }
}
