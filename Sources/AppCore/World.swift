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
