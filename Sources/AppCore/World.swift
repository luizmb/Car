import Core
import ReactiveConcurrency
import AppDomain
import FP
import Foundation
import NetworkClient
import SpeedMonitorFeature

public struct World: Sendable {
    // Authorization (separate from GPS data — drives the state machine)
    public let requestAuthorization: @Sendable () -> Publisher<Void, Never>
    public let authorizationUpdates: @Sendable () -> Publisher<AuthorizationUpdate, Never>
    // Location (started only after readyToMonitor action)
    public let locationUpdates: @Sendable () -> Publisher<LocationUpdate, Never>
    // Road speed
    public let subscribeToRoadSpeed: @Sendable () -> Publisher<RoadInfo, Never>
    // Indimate (BLE indicator unit on the bike)
    /// Reads `CBManager.authorization`. A pure snapshot — unlike constructing a central, reading
    /// this never puts a permission dialog on screen.
    public let bluetoothAuthorization: @Sendable () -> BluetoothAuthorization
    public let indimateEvents: @Sendable () -> Publisher<IndimateEvent, Never>
    /// Starts the looping tick for a side, replacing whatever was playing. Runs on its own
    /// `AVAudioPlayer`, so speech neither stops it nor is stopped by it.
    public let playIndicatorLoop: @Sendable (Side) -> Publisher<Void, Never>
    public let stopIndicatorLoop: @Sendable () -> Publisher<Void, Never>
    /// Tyre pressure and temperature from the FOBO sensors. Advertisement-only — these run coin
    /// cells and sleep between broadcasts, so nothing is ever connected to.
    /// Already matched to a wheel and graded against its band. Sensor identity is keyed on the
    /// broadcast serial rather than the CoreBluetooth identifier, so a reinstall cannot invalidate
    /// it and the other bike in the garage is excluded by construction.
    public let tyreReadings: @Sendable () -> Publisher<TyreReading, Never>
    public let formatPressure: @Sendable (PSI) -> String
    public let formatTemperature: @Sendable (Celsius) -> String
    /// Presence of the CarPlay head unit, i.e. whether the ignition is on. Observed only — never
    /// connected to, since connecting is what suppressed its advertising.
    public let chigeeEvents: @Sendable () -> Publisher<ChigeeEvent, Never>
    /// Telemetry from the helmet intercom. Connection is required — its advertisement carries a
    /// constant, so nothing useful is broadcast.
    public let cardoEvents: @Sendable () -> Publisher<CardoEvent, Never>
    /// Current output route, emitted on subscribe and on every change. The reliable way to know
    /// the helmet intercom is connected — far more so than its sparse BLE advertising.
    public let audioRouteChanges: @Sendable () -> Publisher<AudioRoute, Never>
    /// Barometric pressure — measured locally, which is what makes it worth having over a weather
    /// model's interpolation, since it feeds the air-density term directly.
    public let barometer: @Sendable () -> Publisher<BarometricSample, Never>
    /// Inertial motion at 4 Hz. Device frame, so only rotation-invariant magnitudes are meaningful.
    public let motion: @Sendable () -> Publisher<MotionSample, Never>
    /// iOS's own activity classification. Unknown whether it calls a motorcycle automotive or
    /// cycling — recorded raw so a real ride answers it.
    public let motionActivity: @Sendable () -> Publisher<MotionActivitySample, Never>
    /// Conditions at a position. Feeds air density, which is the causal driver of how rich a
    /// carburettor runs — the single physically-motivated feature that replaces temperature,
    /// pressure and altitude as three weak statistical ones.
    public let fetchWeather: @Sendable (Latitude, Longitude) -> Publisher<WeatherObservation, Never>
    /// Persisted fuel log. Plain JSON in Documents, so it can be inspected or corrected by hand.
    public let loadFuelLog: @Sendable () -> Publisher<Result<FuelLog, FileError>, Never>
    public let saveFuelLog: @Sendable (FuelLog) -> Publisher<Result<Void, FileError>, Never>
    /// The phone is the instrument cluster, so its battery is a pre-ride check. Low Power Mode
    /// matters more than the percentage: it throttles the background work location and Bluetooth
    /// depend on, and can silently disable most of the app mid-ride.
    public let phoneBattery: @Sendable () -> Double?
    public let isLowPowerMode: @Sendable () -> Bool
    /// Injected rather than called ambiently — the architecture forbids `Date()`/`UUID()` inside
    /// logic, and a refuel record needs both.
    public let now: @Sendable () -> Date
    public let newID: @Sendable () -> UUID
    /// Appends a line to the ride log. Temporary raw capture until the journey recorder lands.
    public let logAction: @Sendable (String) -> Publisher<Void, Never>
    // Audio
    public let speak: @Sendable (String) -> Publisher<Void, Never>
    /// Speaks several lines with a pause between each. Used for the briefing, where a beat between
    /// sources is what makes it followable through a helmet.
    public let speakSequence: @Sendable ([String], TimeInterval) -> Publisher<Void, Never>
    public let announceOverLimit: @Sendable () -> Publisher<Void, Never>
    public let announceUnderLimit: @Sendable () -> Publisher<Void, Never>
    // Domain config
    public let thresholds: [MPH]
    // Locale-dependent formatters
    public let formatSpeed: @Sendable (MPH) -> String
    public let formatSpeedSpeech: @Sendable (MPH) -> String
    public let formatAltitude: @Sendable (Meters) -> String
    public let formatBearing: @Sendable (Course) -> String
    public let formatCoordinate: @Sendable (Latitude, Longitude) -> String
}
