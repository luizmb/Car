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
    /// Roads from the on-device extract, tried before Overpass. `nil` means the file is absent or
    /// has nothing here, and the network answers instead.
    public let localRoad: @Sendable (Latitude, Longitude, Course?) -> RoadInfo?
    /// Enforcement cameras over a wide radius, refreshed rarely. Held in state and filtered per fix —
    /// see `makeCameraStream` for why the cadence is the opposite of the road lookup's.
    public let subscribeToCameras: @Sendable () -> Publisher<CameraSet, Never>
    /// Brings the next road lookup forward to the next GPS fix. Completing a turn is a road change
    /// the 300 m / 20 s throttle cannot see.
    /// The street name at a position, from Apple's own geocoder.
    ///
    /// The fallback for when Overpass is unreachable — which on 2026-08-06 meant losing the road
    /// name *and* the limit together, because both came from the same request. Apple has no speed
    /// limits, but it has the name, and knowing the road you are on is most of the value.
    public let reverseGeocode: @Sendable (Latitude, Longitude) -> Publisher<String?, Never>
    public let refreshRoadNow: @Sendable (Latitude, Longitude) -> Publisher<Void, Never>
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
    /// Distance since the last fill, in metres. Survives relaunch — the app is killed constantly.
    public let loadTripDistance: @Sendable () -> Publisher<Result<Double, FileError>, Never>
    public let saveTripDistance: @Sendable (Double) -> Publisher<Result<Void, FileError>, Never>
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
    /// Reading and writing numbers the way the rider's device does.
    ///
    /// `NumberFormatter` is not a primitive and must not leak past this boundary, so the World
    /// exposes the two operations rather than the object — and as two independent closures rather
    /// than an `Iso`, because neither direction is total: parsing fails on an empty or malformed
    /// field, and formatting then parsing does not return the original string.
    /// The forecourt at a position. Empty rather than failing — a fill with no station beats no fill.
    public let fetchStation: @Sendable (Latitude, Longitude) -> Publisher<FuelStation?, Never>
    public let parseNumber: @Sendable (String) -> Result<Double, NumberError>
    public let formatNumber: @Sendable (Double) -> Result<String, NumberError>
    public let now: @Sendable () -> Date
    public let newID: @Sendable () -> UUID
    /// Appends a line to the ride log. Temporary raw capture until the journey recorder lands.
    /// The firehose: every action, on or off journey. Useful for a week, not for a year.
    public let logAction: @Sendable (String) -> Publisher<Void, Never>
    /// The record worth keeping: typed events, only while a journey is active.
    public let logJourney: @Sendable (any JourneyPayloadType) -> Publisher<Void, Never>
    // Audio
    public let speak: @Sendable (String) -> Publisher<Void, Never>
    /// Queues behind whatever is playing rather than interrupting it. Everything informational
    /// uses this; only time-critical speed announcements use `speak`.
    public let speakQueued: @Sendable (String) -> Publisher<Void, Never>
    /// Speaks several lines with a pause between each. Used for the briefing, where a beat between
    /// sources is what makes it followable through a helmet.
    public let speakSequence: @Sendable ([String], TimeInterval) -> Publisher<Void, Never>
    public let announceOverLimit: @Sendable () -> Publisher<Void, Never>
    public let announceUnderLimit: @Sendable () -> Publisher<Void, Never>
    // Navigation
    /// Addresses and postcodes matching a query, biased toward a position. Addresses only — points
    /// of interest are excluded at the source, because "Tesco" is a hundred places and picking one
    /// from a list at a junction is the interaction this app exists to avoid.
    public let searchAddresses: @Sendable (String, Latitude?, Longitude?)
        -> Publisher<[AddressSuggestion], Never>
    /// Every route found between two points, **unfiltered** — the preferences are passed on to the
    /// routing service as a hint, and the domain then checks the answers and drops what does not
    /// honour them. `Result` rather than an empty list, so "no route" and "routing failed" stay
    /// distinguishable all the way to the screen.
    public let routes: @Sendable (Coordinate, Coordinate, RoutePreferences)
        -> Publisher<Result<[RouteOption], RouteError>, Never>
    // Domain config
    public let thresholds: [MPH]
    // Locale-dependent formatters
    public let formatSpeed: @Sendable (MPH) -> String
    public let formatSpeedSpeech: @Sendable (MPH) -> String
    public let formatAltitude: @Sendable (Meters) -> String
    /// A travelling distance, as a rider reads it. Distinct from ``formatAltitude`` despite sharing
    /// a unit: an altitude is metres above sea level and a route is miles on a sign, and collapsing
    /// them would make one of the two wrong.
    public let formatDistance: @Sendable (Meters) -> String
    public let formatDuration: @Sendable (TimeInterval) -> String
    public let formatBearing: @Sendable (Course) -> String
    public let formatCoordinate: @Sendable (Latitude, Longitude) -> String
}
