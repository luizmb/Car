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
public enum AppScopes: Rig {
    public typealias Action = AppAction
    public typealias State = AppState
    public typealias Environment = World

    // `ScopeOf<AppScopes>` pins the app triad (`Action`/`State`/`Environment`) as the entry point, so the
    // scope is just `.action(\.x).state(\.x).environment(…)` — no explicit witnesses.
    //
    // NB: this ONE scope uses the named `fanout(keypaths:into:)` rather than `fanout(…) >>> Env.init`.
    // `SpeedMonitorFeature.Environment.init` (13 params) refuses to coerce to `@Sendable` in operator-operand
    // position (a Swift type-checker quirk) — the named `into:` parameter accepts the very same init.
    static let speedMonitor = ScopeOf<AppScopes>
        .action(\.speedMonitor).state(\.speedMonitor)
        .environment(fanout(
            keypaths: \.requestAuthorization, \.authorizationUpdates, \.locationUpdates, \.subscribeToRoadSpeed,
                      \.speak, \.announceOverLimit, \.announceUnderLimit, \.thresholds, \.formatSpeed,
                      \.formatSpeedSpeech, \.formatAltitude, \.formatBearing, \.formatCoordinate,
            into: SpeedMonitorFeature.Environment.init
        ))
}
