import AppDomain
import FP
import SpeedMonitorFeature
import SwiftRex
import SwiftRexArchitecture

// MARK: - AppState

/// Flat application state. Every feature is a sibling — none is parent to another.
/// (Single feature today; structured for growth — add a slice + a Scope + a route to add a screen.)
@Lenses
public struct AppState: Sendable {
    public var navigation:   NavigationFeature.State   = .init()
    public var speedMonitor: SpeedMonitorFeature.State = SpeedMonitorFeature.initialState(with: ())
    public init() {}
}

// MARK: - AppAction

/// Flat action space. Navigation actions are their own case, not a parent wrapper.
@Prisms
public enum AppAction: Sendable {
    case navigation(NavigationFeature.Action)
    case speedMonitor(SpeedMonitorFeature.Action)
}

public typealias MainStoreType = any StoreType<AppAction, AppState>
public typealias MainStore     = Store<AppAction, AppState, World>

// MARK: - Store conveniences

public extension MainStore {

    /// Builds the app store wired to the given environment.
    /// Call `.app(world: .real)` at the entry point; pass a mock world in tests.
    @MainActor static func app(world: World) -> MainStoreType {
        Store(
            initial: AppState(),
            behavior: NavigationFeature.behavior().lift(.action(\.navigation).state(\.navigation).environment(ignore))
                <> AppScopes.speedMonitor.behavior(of: SpeedMonitorFeature.self),
            environment: world
        )
    }
}

// MARK: - Feature scopes

// The SpeedMonitor slice of the app: action/state are addressed by `\.speedMonitor` on the flat
// AppAction/AppState; the environment is narrowed from `World`.
public enum AppScopes {
    static let speedMonitor = Relay.Empty
        .action(AppAction.prism.speedMonitor).state(\AppState.speedMonitor)
        .environment { @Sendable (world: World) in
            SpeedMonitorFeature.Environment(
                    requestAuthorization: world.requestAuthorization,
                    authorizationUpdates: world.authorizationUpdates,
                    locationUpdates:      world.locationUpdates,
                    subscribeToRoadSpeed: world.subscribeToRoadSpeed,
                    speak:                world.speak,
                    announceOverLimit:    world.announceOverLimit,
                    announceUnderLimit:   world.announceUnderLimit,
                    thresholds:           world.thresholds,
                    formatSpeed:          world.formatSpeed,
                    formatSpeedSpeech:    world.formatSpeedSpeech,
                    formatAltitude:       world.formatAltitude,
                    formatBearing:        world.formatBearing,
                    formatCoordinate:     world.formatCoordinate
                )
        }
}
