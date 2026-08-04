import AppDomain
import CoreFP
import CoreFPOperators
import FP
import SpeedMonitorFeature
import SwiftRex
import SwiftRexArchitecture
import SwiftRexOperators
import SwiftUI

// MARK: - AppFeature

/// The app is a `Feature` like any other: it owns state, actions and a behavior, and it builds its own
/// view. Nothing about the root is special-cased — which is the point. A root that hands a bare `Store`
/// to a view silently never re-renders, because `Store` is not `@Observable`; the SwiftRex APIs that
/// tempt you into it (`binding` / `presence` / `item`) are declared on `StoreType`, which the concrete
/// `Store` also satisfies. Going through the standard `Feature` machinery means the root's view store is
/// built exactly the way every other screen's is, so that failure is not expressible here.
///
/// It is also the app's coordinator: it holds the `World`, constructs the ``AppRouter``, and injects it
/// into the root view. Child screens are created by that router on demand and never cached.
@Feature(strategy: .observationSimple)
public enum AppFeature {

    // MARK: - State

    public struct State: Sendable, Equatable {
        /// The root screen — always on screen, so never optional.
        public var speedMonitor: SpeedMonitorFeature.State

        /// Indicator audio. A sibling of the root screen, not a child of it: it has no view and
        /// runs for the whole journey regardless of what is displayed.
        public var indicator: IndicatorFeature.State

        /// Helmet intercom status. Another sibling overlay — the map is the canvas and each
        /// concern contributes its own pill.
        public var cardo: CardoFeature.State

        /// Ignition state, from the CarPlay head unit — the only dependable bike-on signal here.
        public var chigee: ChigeeFeature.State

        /// Tyre pressure and temperature. Passive, and independent of the bike being on.
        public var tyres: TyreFeature.State

        /// Barometer, inertial motion and activity classification. Collection-first: its job is to
        /// put raw samples into the ride log so inference can be worked out offline.
        public var motion: MotionFeature.State

        /// The pushed screens, each carrying its own state. One source of truth: there is no parallel
        /// table to keep in step, so a route and its data cannot disagree.
        public var path: [StackEntry]

        public init() {
            speedMonitor = SpeedMonitorFeature.initialState(with: ())
            indicator = IndicatorFeature.initialState(with: ())
            cardo = CardoFeature.initialState(with: ())
            chigee = ChigeeFeature.initialState(with: ())
            tyres = TyreFeature.initialState(with: ())
            motion = MotionFeature.initialState(with: ())
            path = []
        }
    }

    // MARK: - Action

    /// Flat action space. Navigation is its own case, a sibling of every screen — not a parent wrapper.
    public enum Action: Sendable {
        /// Dispatched once at store creation — which includes the background relaunches iOS
        /// performs for BLE state restoration, where no view ever appears.
        case appLaunch
        case navigation(NavigationAction)
        case speedMonitor(SpeedMonitorFeature.Action)
        case indicator(IndicatorFeature.Action)
        case cardo(CardoFeature.Action)
        case chigee(ChigeeFeature.Action)
        case tyres(TyreFeature.Action)
        case motion(MotionFeature.Action)
    }

    // MARK: - Environment

    public typealias Environment = World

    // No `ViewState`/`ViewAction`: the macro aliases them to `State`/`Action`, so the root view's store
    // is `ViewStore<State, Action>` — the whole app, which is what a router needs to project children.

    // MARK: - Lifecycle

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: - View
    //
    // Hand-written rather than `typealias Content`: the generated `view()` passes only the view store,
    // and the root view also needs its router. This is the one place holding the `World`, so it is the
    // one place that can build a router — and the `World` goes no further.

    @MainActor
    public static func view(store: any StoreType<Action, State>, environment: World) -> some View {
        AppRootView(
            viewStore: ViewStore(store),
            router: AppRouter(store: store, world: environment)
        )
    }

    // MARK: - Behavior

    public static func behavior() -> Behavior<Action, State, World> {
        // Each feature's own wiring sits with it: the lift, then the actions it sends onward. Reading a
        // feature's row tells you everything it participates in, without a separate bridge to cross-check.
        // A screen that navigates gains a `.on(.action(\.x.tapped), dispatch: .action(\.navigation.push.y))`
        // here and nothing else changes.
        // Every observation reaches the store as an action, so one handler captures GPS, road
        // info, Indimate, Cardo, CHIGEE and tyres in true interleaved order — the whole raw
        // timeline, with no per-source wiring. Temporary, until the real recorder exists.
        Behavior<AppAction, AppState, World>.handle { action, _ in
            .produce { ctx in
                ctx.environment.logAction(String(describing: action)) |> Effect.fireAndForget
            }
        }

        // Publish a snapshot for App Intents. Siri constructs intents itself and cannot be handed
        // a store, so state is mirrored into a plain value they can read — including when the app
        // is suspended, where a stale answer beats a hang.
        <> Behavior<AppAction, AppState, World>.handle { _, context in
            guard let state = context.stateBefore else { return .doNothing }
            return .produce { ctx in
                let display = state.speedMonitor.display
                let tyres = state.tyres.readings.reduce(
                    into: [TyrePosition: (psi: String, status: TyreStatus)]()
                ) {
                    $0[$1.key] = (ctx.environment.formatPressure($1.value.telemetry.psi), $1.value.status)
                }
                IntentSnapshot.shared.update(
                    speed: display.speedText,
                    limit: display.roadLimitDisplay.spokenLimit,
                    road: display.roadRef ?? display.roadName,
                    tyres: tyres,
                    ignition: state.chigee.isIgnitionOn,
                    indimate: state.indicator.isConnected
                )
                return .empty
            }
        }
    }
}

// Familiar spellings for the app triad — `AppFeature.State` everywhere would only add noise.
public typealias AppState = AppFeature.State
public typealias AppAction = AppFeature.Action
public typealias MainStoreType = any StoreType<AppAction, AppState>
public typealias MainStore = Store<AppAction, AppState, World>

// MARK: - The path, as SwiftUI sees it

public extension AppState {
    /// The `Hashable` identities SwiftUI navigates by. Read-only — the path is the truth, this is a view
    /// of it. A screen's data can change all it likes without changing which screen it is.
    var routes: [AppRoute] { path.map(\.route) }
}

// MARK: - Store factory

public extension MainStore {

    /// Builds the app store wired to the given environment.
    /// Call `.app(world: .real)` at the entry point; pass a mock world in tests.
    @MainActor static func app(world: World) -> MainStoreType {
        Store(
            initial: AppState(),
            behavior: AppFeature.behavior(),
            environment: world
        )
        .dispatching(.appLaunch)
    }
}

private extension Store<AppAction, AppState, World> {
    /// Fires an action as the store is built. Needed because BLE state restoration relaunches the
    /// app with no UI at all — nothing driven by `onAppear` will ever run in that case.
    func dispatching(
        _ action: AppAction,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) -> Self {
        dispatch(action, source: .init(file: file, function: function, line: line))
        return self
    }
}

// MARK: - Feature scopes
//
// One declaration per feature carrying all three axes — action, state, environment — so the same value
// drives the behavior fold and the router. The root's state axis is **total** (`\.speedMonitor`); a
// pushed screen's would be **affine**, focusing the `path` element it lives in through a single prism
// (`topmost` / `replacing` in AppRouter.swift), so there is no derived copy and nothing to keep in step.

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
    public static let speedMonitor = ScopeOf<AppScopes>
        .action(\.speedMonitor).state(\.speedMonitor)
        .environment(fanout(
            keypaths: \.requestAuthorization, \.authorizationUpdates, \.locationUpdates, \.subscribeToRoadSpeed,
                      \.speak, \.announceOverLimit, \.announceUnderLimit, \.thresholds, \.formatSpeed,
                      \.formatSpeedSpeech, \.formatAltitude, \.formatBearing, \.formatCoordinate,
            into: SpeedMonitorFeature.Environment.init
        ))

    public static let indicator = ScopeOf<AppScopes>
        .action(\.indicator).state(\.indicator)
        .environment(fanout(
            \.bluetoothAuthorization, \.indimateEvents,
            \.playIndicatorLoop, \.stopIndicatorLoop, \.speak
        ) >>> IndicatorFeature.Environment.init)

    public static let cardo = ScopeOf<AppScopes>
        .action(\.cardo).state(\.cardo)
        .environment(fanout(\.audioRouteChanges, \.cardoEvents) >>> CardoFeature.Environment.init)

    public static let chigee = ScopeOf<AppScopes>
        .action(\.chigee).state(\.chigee)
        .environment(\.chigeeEvents >>> ChigeeFeature.Environment.init)

    public static let tyres = ScopeOf<AppScopes>
        .action(\.tyres).state(\.tyres)
        .environment(fanout(
            keypaths: \.tyreReadings, \.speak, \.formatPressure, \.formatTemperature,
            into: TyreFeature.Environment.init
        ))

    public static let motion = ScopeOf<AppScopes>
        .action(\.motion).state(\.motion)
        .environment(fanout(\.barometer, \.motion, \.motionActivity) >>> MotionFeature.Environment.init)
}
