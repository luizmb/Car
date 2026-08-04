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
    /// Telemetry from the helmet intercom. Connection is required — its advertisement carries a
    /// constant, so nothing useful is broadcast.
    public let cardoEvents: @Sendable () -> Publisher<CardoEvent, Never>
    /// Current output route, emitted on subscribe and on every change. The reliable way to know
    /// the helmet intercom is connected — far more so than its sparse BLE advertising.
    public let audioRouteChanges: @Sendable () -> Publisher<AudioRoute, Never>
    // Audio
    public let speak: @Sendable (String) -> Publisher<Void, Never>
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
