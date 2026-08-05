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

        /// Conditions along the route. Feeds air density, which drives how rich the carb runs.
        public var weather: WeatherFeature.State

        /// GPS distance since the last fill — the figure the fuel maths will use.
        public var trip: TripFeature.State

        /// Whether the pre-ride briefing has been spoken this session. It fires once, when the last
        /// of CHIGEE and Cardo connects — no Cardo means no greeting, but also no ears, so nothing
        /// is lost.
        public var flightPlanSpoken: Bool = false

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
            weather = WeatherFeature.initialState(with: ())
            trip = TripFeature.initialState(with: ())
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
        case weather(WeatherFeature.Action)
        case trip(TripFeature.Action)
        case fuel(FuelFeature.Action)
        /// Speak the briefing on demand, at either verbosity.
        case speakFlightPlan(FlightPlanVerbosity)
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
        //
        // Every observation reaches the store as an action, so one handler captures GPS, road info,
        // Indimate, Cardo, CHIGEE, tyres and motion in true interleaved order — the whole raw
        // timeline, with no per-source wiring. Temporary, until the real recorder exists.
        Behavior<AppAction, AppState, World>.handle { action, _ in
            .produce { ctx in
                ctx.environment.logAction(String(describing: action)) |> Effect.fireAndForget
            }
        }

        <> navigationBehavior()

        // Bluetooth is requested only once location has resolved. Constructing a `CBCentralManager`
        // *is* the permission request, so chaining the two here is what keeps the system dialogs
        // sequential and in order of importance — the speedometer's permission first, the
        // indicator enhancement second.
        <> AppScopes.speedMonitor.behavior(of: SpeedMonitorFeature.self)
            .on(.action(\.speedMonitor.readyToMonitor), dispatch: .action(\.indicator.start))

        <> AppScopes.indicator.behavior(of: IndicatorFeature.self)
            .on(.action(\.appLaunch), dispatch: .action(\.indicator.launch))

        // An indicator cancelling means a turn was completed, which is a *semantic* signal that
        // the road has changed — where the distance/time throttle is only a proxy. Positive-only:
        // it can bring a refresh forward but never gates one, because the rider is human and does
        // not always indicate.
        <> Behavior<AppAction, AppState, World>.handle { action, context in
            guard
                let indicatorAction = AppAction.prism.indicator.preview(action),
                case let .event(.indicator(side)) = indicatorAction,
                side == nil,
                context.stateBefore?.indicator.side != nil
            else { return .doNothing }
            return .produce { _ in Effect.just(.speedMonitor(.roadMayHaveChanged)) }
        }

        <> AppScopes.cardo.behavior(of: CardoFeature.self)

        <> AppScopes.chigee.behavior(of: ChigeeFeature.self)

        <> AppScopes.tyres.behavior(of: TyreFeature.self)

        <> AppScopes.motion.behavior(of: MotionFeature.self)

        <> AppScopes.weather.behavior(of: WeatherFeature.self)

        // Keep the fuel form's distance in step with the counter, so whatever is on screen when
        // Save is pressed is what gets recorded.
        <> Behavior<AppAction, AppState, World>.handle { action, context in
            guard
                AppAction.prism.trip.preview(action) != nil,
                let state = context.stateBefore
            else { return .doNothing }
            return .produce { _ in
                Effect.just(.fuel(.setGPSDistance(state.trip.kilometresSinceFill)))
            }
        }

        <> AppScopes.trip.behavior(of: TripFeature.self)
            // A fill or a reserve switch starts a fresh measurement.
            .on(.action(\.fuel.saved), dispatch: .action(review: const(.trip(.reset))))

        <> AppScopes.fuel.behavior(of: FuelFeature.self)

        // Location fans out from the one feature that owns the stream. A second subscription would
        // clobber the delegate's single continuation slot — the failure that silently killed the
        // road-speed stream before it was made cold.
        <> Behavior<AppAction, AppState, World>.handle { action, _ in
            guard
                let monitorAction = AppAction.prism.speedMonitor.preview(action),
                let update = SpeedMonitorFeature.Action.prism.locationUpdate.preview(monitorAction)
            else { return .doNothing }
            return .produce { ctx in
                Effect.just(.weather(.located(update.latitude, update.longitude, ctx.environment.now())))
                    <> Effect.just(.fuel(.setPosition(update.latitude, update.longitude)))
                    <> Effect.just(.trip(.located(update)))
            }
        }

        // Flight Plan, spoken once when the last of CHIGEE and Cardo arrives — during the
        // two-minute choked warm-up, when the rider is sitting there anyway.
        <> Behavior<AppAction, AppState, World>.handle { _, context in
            guard
                let state = context.stateBefore,
                !state.flightPlanSpoken,
                state.chigee.isIgnitionOn == true,
                state.cardo.isConnected
            else { return .doNothing }
            return .reduce { $0.flightPlanSpoken = true }
                .produce { ctx in
                    ctx.environment.speakSequence(
                        composeFlightPlan(state.flightPlanInputs(ctx.environment), verbosity: .exceptions),
                        flightPlanGap
                    ) |> Effect.fireAndForget
                }
        }

        // On demand, at whichever verbosity was asked for. The full report is a diagnostic: a
        // provider that has quietly failed is indistinguishable from a healthy one under
        // `.exceptions`, but names itself here.
        <> Behavior<AppAction, AppState, World>.handle { action, context in
            guard
                let verbosity = AppAction.prism.speakFlightPlan.preview(action),
                let state = context.stateBefore
            else { return .doNothing }
            return .produce { ctx in
                ctx.environment.speakSequence(
                    composeFlightPlan(state.flightPlanInputs(ctx.environment), verbosity: verbosity),
                    flightPlanGap
                ) |> Effect.fireAndForget
            }
        }

        // Drain any briefing requested by Siri. An intent cannot dispatch, so it leaves a value
        // behind and this picks it up on the next action — of which there are several a second.
        <> Behavior<AppAction, AppState, World>.handle { _, context in
            guard
                let verbosity = FlightPlanRequest.shared.take(),
                let state = context.stateBefore
            else { return .doNothing }
            return .produce { ctx in
                ctx.environment.speakSequence(
                    composeFlightPlan(state.flightPlanInputs(ctx.environment), verbosity: verbosity),
                    flightPlanGap
                ) |> Effect.fireAndForget
            }
        }

        // Publish a snapshot for App Intents. Siri constructs intents itself and cannot be handed a
        // store, so state is mirrored into a plain value they can read — including when the app is
        // suspended, where a stale answer beats a hang.
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

/// Pause between briefing segments. Long enough to separate sources through a helmet, short
/// enough that the whole thing still fits inside the warm-up.
let flightPlanGap: TimeInterval = 0.45

public extension AppState {
    /// Gathers everything the briefing can speak about. Kept in one place so the automatic and
    /// on-demand paths cannot drift apart.
    func flightPlanInputs(_ world: World) -> FlightPlanInputs {
        let display = speedMonitor.display
        let gpsAccuracy = speedMonitor.lastLocation?.horizontalAccuracy?.rawValue
        return FlightPlanInputs(
            ignitionOn: chigee.isIgnitionOn,
            indimateConnected: indicator.isConnected,
            cardoConnected: cardo.isConnected,
            tyres: tyres.readings,
            weather: weather.latest,
            road: display.roadRef ?? display.roadName,
            speedLimit: display.roadLimitDisplay.spokenLimit,
            bikeMillivolts: indicator.battery?.hexMillivolts,
            phoneBattery: world.phoneBattery(),
            lowPowerMode: world.isLowPowerMode(),
            gpsAccuracy: gpsAccuracy
        )
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
                      \.subscribeToCameras,
                      \.speak, \.speakQueued, \.speakQueued, \.announceOverLimit, \.announceUnderLimit,
                      \.thresholds, \.formatSpeed,
                      \.formatSpeedSpeech, \.formatAltitude, \.formatBearing, \.formatCoordinate,
            into: SpeedMonitorFeature.Environment.init
        ))

    public static let indicator = ScopeOf<AppScopes>
        .action(\.indicator).state(\.indicator)
        .environment(fanout(
            \.bluetoothAuthorization, \.indimateEvents,
            \.playIndicatorLoop, \.stopIndicatorLoop, \.speakQueued
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
            keypaths: \.tyreReadings, \.speakQueued, \.formatPressure, \.formatTemperature,
            into: TyreFeature.Environment.init
        ))

    public static let motion = ScopeOf<AppScopes>
        .action(\.motion).state(\.motion)
        .environment(fanout(\.barometer, \.motion, \.motionActivity) >>> MotionFeature.Environment.init)

    public static let trip = ScopeOf<AppScopes>
        .action(\.trip).state(\.trip)
        .environment(fanout(\.loadTripDistance, \.saveTripDistance) >>> TripFeature.Environment.init)

    public static let weather = ScopeOf<AppScopes>
        .action(\.weather).state(\.weather)
        .environment(\.fetchWeather >>> WeatherFeature.Environment.init)

    // The first **affine** scope: the fuel screen's state lives inside a `path` element rather than
    // as a permanent field, so reads and writes both go through the same prism. `replacing` cannot
    // append, so the feature can never conjure a screen navigation did not push.
    public static let fuel = ScopeOf<AppScopes>
        .action(\.fuel)
        .state(preview: topmost(StackEntry.prism.fuel), set: replacing(StackEntry.prism.fuel))
        .environment(fanout(
            \.loadFuelLog, \.saveFuelLog, \.now, \.newID
        ) >>> FuelFeature.Environment.init)
}
