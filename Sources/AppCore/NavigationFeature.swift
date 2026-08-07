import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftRexSwiftUI
import SwiftUI

// MARK: - NavigationFeature

/// Getting from here to one other place.
///
/// Scoped hard, on purpose. One destination, no waypoints, no points of interest, vehicle only —
/// which is not a first cut of a bigger thing but the shape of the problem: a rider picks a
/// destination while stationary, then wants their eyes on the road. Every additional control is
/// something to operate in gloves at a junction.
///
/// The part that is not like other navigation apps is ``RoutePreferences``. "Avoid motorways" here
/// means routes with motorways are **not shown**, rather than shown with a warning — see the type
/// for why that is the honest reading of what a rider on a carburettor 400 is asking for.
public enum NavigationFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        /// What the rider has typed. Held as text because a search box is text, and the results are
        /// a separate thing that arrives later.
        public var query: String = ""
        public var suggestions: [AddressSuggestion] = []
        public var isSearching: Bool = false

        /// Where they chose to go. Set on selection, and the trigger for routing.
        public var destination: AddressSuggestion?

        public var preferences: RoutePreferences = RoutePreferences(
            // Defaults chosen for this bike rather than for a car. A carburettor 400 with no fairing
            // is unpleasant and slow on a motorway and the rider has said as much; tolls are rare
            // enough in England that defaulting to avoiding them costs nothing.
            avoidTolls: true,
            avoidMotorways: true
        )

        public var isRouting: Bool = false
        public var outcome: RouteSearchOutcome?
        /// The one highlighted on the planner's map. Choosing is not yet following.
        public var chosen: RouteOption?
        /// The one actually being followed, and the guidance position along it.
        ///
        /// Separate from `chosen` because they are different commitments: tapping a route to look at
        /// it must not start talking, and re-routing after a preference change must not swap the
        /// route under a rider already following one.
        public var following: RouteOption?
        public var guidanceState: GuidanceState = GuidanceState()

        /// Where the rider is, pushed in from the location stream. Routing needs an origin, and the
        /// bike's own position is the only origin that makes sense.
        public var latitude: Latitude?
        public var longitude: Longitude?

        public init() {}

        /// Routes on offer, or empty while there are none to offer.
        public var routes: [RouteOption] {
            guard case let .routes(routes) = outcome else { return [] }
            return routes
        }

        /// Search can run without a fix — Apple will still find the address — but routing cannot.
        public var canRoute: Bool { latitude != nil && longitude != nil }
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case appeared
        case setQuery(String)
        /// Run the search. Separate from typing: a request per keystroke would be a request per
        /// keystroke, and Apple throttles.
        case search
        /// Carries the query it answers, so a slow completion for "amp" cannot overwrite the
        /// results for "ampthill" typed since.
        case suggestionsLoaded(String, [AddressSuggestion])
        case choose(AddressSuggestion)
        /// The chosen suggestion, now with coordinates. `nil` means it could not be placed.
        case destinationResolved(AddressSuggestion?)
        case setAvoidTolls(Bool)
        case setAvoidMotorways(Bool)
        /// Ask for routes to the chosen destination with the current preferences.
        case route
        case routesLoaded(Result<[RouteOption], RouteError>)
        case select(RouteOption)
        /// Begin following the selected route.
        case start
        case stop
        /// A fix, while following. Drives the turn-by-turn.
        case advance(Coordinate, MPS)
        /// The guidance position that followed from a fix. Separate because working it out needs the
        /// distance formatter, which lives in the environment and is only reachable from an effect.
        case guidanceAdvanced(GuidanceState)
        case clear
        case setPosition(Latitude, Longitude)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        /// Completions for a fragment. Cheap and local-ish, so it runs as the rider types.
        public let completeAddress: @Sendable (String, Latitude?, Longitude?)
            -> Publisher<[AddressSuggestion], Never>
        /// A completion turned into a position. Costs a request, so it runs once, for the one picked.
        public let resolveAddress: @Sendable (AddressSuggestion) -> Publisher<AddressSuggestion?, Never>
        public let routes: @Sendable (Coordinate, Coordinate, RoutePreferences)
            -> Publisher<Result<[RouteOption], RouteError>, Never>
        /// Queued rather than interrupting: nothing here is time-critical, and cutting off a speed
        /// announcement to say a route was found would be the wrong trade in a helmet.
        public let speak: @Sendable (String) -> Publisher<Void, Never>
        public let formatDistance: @Sendable (Meters) -> String
        public let formatDuration: @Sendable (TimeInterval) -> String
        public let formatTime: @Sendable (Date) -> String
        /// Injected, never called ambiently — an arrival estimate is `now + travel time`, and `now`
        /// is exactly the sort of thing the architecture forbids reaching for inside logic.
        public let now: @Sendable () -> Date

        public init(
            completeAddress: @escaping @Sendable (String, Latitude?, Longitude?)
                -> Publisher<[AddressSuggestion], Never>,
            resolveAddress: @escaping @Sendable (AddressSuggestion) -> Publisher<AddressSuggestion?, Never>,
            routes: @escaping @Sendable (Coordinate, Coordinate, RoutePreferences)
                -> Publisher<Result<[RouteOption], RouteError>, Never>,
            speak: @escaping @Sendable (String) -> Publisher<Void, Never>,
            formatDistance: @escaping @Sendable (Meters) -> String,
            formatDuration: @escaping @Sendable (TimeInterval) -> String,
            formatTime: @escaping @Sendable (Date) -> String,
            now: @escaping @Sendable () -> Date
        ) {
            self.completeAddress = completeAddress
            self.resolveAddress = resolveAddress
            self.routes = routes
            self.speak = speak
            self.formatDistance = formatDistance
            self.formatDuration = formatDuration
            self.formatTime = formatTime
            self.now = now
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {
            case .appeared:
                return .doNothing

            case let .setQuery(text):
                return .reduce {
                    $0.query = text
                    guard text.isEmpty else { return }
                    $0.suggestions = []
                }
                .produce { _ in Effect.just(.search) }

            case .search:
                guard let state = context.stateBefore else { return .doNothing }
                let query = state.query
                let (latitude, longitude) = (state.latitude, state.longitude)
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return .doNothing }
                return .reduce { $0.isSearching = true }
                    .produce { ctx in
                        ctx.environment.completeAddress(query, latitude, longitude)
                            .asEffect { Action.suggestionsLoaded(query, $0) }
                    }

            case let .suggestionsLoaded(query, suggestions):
                return .reduce {
                    // Completions arrive out of order — a slow answer for "amp" must not replace the
                    // list for "ampthill" typed since.
                    guard query == $0.query else { return }
                    $0.suggestions = suggestions
                    $0.isSearching = false
                }

            case let .choose(suggestion):
                return .reduce {
                    $0.suggestions = []
                    $0.query = suggestion.searchText
                    // A new destination invalidates the old routes outright rather than leaving them
                    // on screen looking like answers to the new question.
                    $0.outcome = nil
                    $0.chosen = nil
                }
                .produce { ctx in
                    // A completion is text with no coordinates. Resolving is a request, so it
                    // happens here — once, for the one actually picked — rather than for every row
                    // as it was typed.
                    ctx.environment.resolveAddress(suggestion).asEffect(Action.destinationResolved)
                }

            case let .destinationResolved(resolved):
                guard let resolved else {
                    return .reduce { $0.outcome = .failed(.placeNotFound) }
                }
                return .reduce { $0.destination = resolved }
                    .produce { _ in Effect.just(.route) }

            case let .setAvoidTolls(value):
                return .reduce { $0.preferences.avoidTolls = value }
                    .produce(routeIfDestinationSet: context.stateBefore)
            case let .setAvoidMotorways(value):
                return .reduce { $0.preferences.avoidMotorways = value }
                    .produce(routeIfDestinationSet: context.stateBefore)

            case .route:
                guard
                    let state = context.stateBefore,
                    // Resolved, not merely chosen: a completion is text until `resolveAddress` has
                    // placed it, and there is nothing to route towards until then.
                    let target = state.destination?.coordinate,
                    let latitude = state.latitude,
                    let longitude = state.longitude
                else { return .doNothing }
                let origin = Coordinate(latitude: latitude, longitude: longitude)
                // Read here rather than in the effect: `stateBefore` is the state the rider was
                // looking at when they asked, and a preference toggled a moment later must produce
                // its own request rather than retroactively changing this one.
                let preferences = state.preferences
                return .reduce {
                    $0.isRouting = true
                    $0.outcome = nil
                }
                .produce { ctx in
                    ctx.environment.routes(origin, target, preferences)
                        .asEffect(Action.routesLoaded)
                }

            case let .routesLoaded(result):
                guard let state = context.stateBefore else { return .doNothing }
                let preferences = state.preferences
                let outcome: RouteSearchOutcome = switch result {
                case let .success(routes): acceptableRoutes(routes, preferences: preferences)
                case let .failure(error): .failed(error)
                }
                return .reduce {
                    $0.isRouting = false
                    $0.outcome = outcome
                    // Pre-select the fastest, so the map has a highlighted line and GO is live the
                    // moment the sheet appears. A rider who wants the default should not have to
                    // tap a route to say so.
                    if case let .routes(routes) = outcome { $0.chosen = routes.first }
                }
                .produce { ctx in
                    // Spoken, because the rider asked for this before setting off and may already
                    // have their gloves on. Only the bad news — a list of routes is something to
                    // look at, and reading five options aloud would be worse than useless.
                    let line: String? = switch outcome {
                    case let .routes(routes) where routes.isEmpty:
                        noRouteAnnouncement(preferences)
                    case let .excludedByPreferences(preferences):
                        noRouteAnnouncement(preferences)
                    case let .failed(error):
                        routeErrorMessage(error)
                    case .routes:
                        nil
                    }
                    guard let line else { return .empty }
                    return ctx.environment.speak(line) |> Effect<Action>.fireAndForget
                }

            case let .select(route):
                // Highlights it on the map. Deliberately silent and deliberately not the same as
                // following it — tapping through the options to compare them must not start talking.
                return .reduce { $0.chosen = route }

            case .start:
                guard let state = context.stateBefore, let route = state.chosen else {
                    return .doNothing
                }
                let destination = state.destination?.searchText
                return .reduce {
                    $0.following = route
                    $0.guidanceState = GuidanceState()
                }
                .produce { ctx in
                    guard let destination else { return .empty }
                    return ctx.environment.speak(routeChosenAnnouncement(
                        route,
                        to: destination,
                        formatDistance: ctx.environment.formatDistance,
                        formatDuration: ctx.environment.formatDuration
                    )) |> Effect<Action>.fireAndForget
                }

            case .stop:
                return .reduce {
                    $0.following = nil
                    $0.guidanceState = GuidanceState()
                }
                .produce { ctx in
                    ctx.environment.speak("Navigation stopped.") |> Effect<Action>.fireAndForget
                }

            case let .advance(position, speed):
                guard
                    let state = context.stateBefore,
                    let route = state.following
                else { return .doNothing }
                let current = state.guidanceState
                return .produce { ctx in
                    let update = guidance(
                        route: route,
                        at: position,
                        speed: speed,
                        state: current,
                        formatDistance: ctx.environment.formatDistance
                    )
                    let spoken = update.announcement.map {
                        ctx.environment.speak($0) |> Effect<Action>.fireAndForget
                    } ?? .empty
                    guard update.state != current else { return spoken }
                    return Effect.just(.guidanceAdvanced(update.state)) <> spoken
                }

            case let .guidanceAdvanced(guidanceState):
                return .reduce { $0.guidanceState = guidanceState }

            case .clear:
                return .reduce {
                    $0.destination = nil
                    $0.outcome = nil
                    $0.chosen = nil
                    $0.following = nil
                    $0.guidanceState = GuidanceState()
                    $0.query = ""
                    $0.suggestions = []
                }

            case let .setPosition(latitude, longitude):
                // Routing needs an origin, so a destination chosen before the first fix cannot be
                // acted on — the screen says "waiting for a GPS fix" and, without this, says it for
                // ever, because nothing else would ever ask again.
                //
                // Only on the **first** fix, and only with a question outstanding. This action
                // arrives once a second for the whole journey; re-routing on each one would be a
                // request per second, and would replace the route under a rider already following
                // it.
                let waiting = context.stateBefore.map {
                    $0.latitude == nil && $0.destination != nil && $0.outcome == nil && !$0.isRouting
                } ?? false
                return .reduce {
                    $0.latitude = latitude
                    $0.longitude = longitude
                }
                .produce { _ in waiting ? Effect.just(.route) : .empty }
            }
        }
    }
}

extension NavigationFeature: HasBehavior {}

// MARK: - Re-routing on a preference change

private extension Reaction<
    NavigationFeature.Action, NavigationFeature.State, NavigationFeature.Environment
> {
    /// Re-runs the search when a preference changes, but only once there is somewhere to go.
    ///
    /// Toggling a switch is the rider saying "not like that" about a route they are looking at, so
    /// the answer should change immediately rather than waiting for them to find a button. With no
    /// destination there is nothing to re-ask, and firing anyway would put a spinner on an empty
    /// screen.
    func produce(routeIfDestinationSet state: NavigationFeature.State?) -> Self {
        produce { _ in
            state?.destination == nil ? .empty : Effect.just(.route)
        }
    }
}
