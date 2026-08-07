import AppDomain
import FP
import Foundation
import ReactiveConcurrency

/// Asking for a way back, and giving up the rider's exclusions only when there is no other way.
///
/// Separate from `AppFeature` because it is a small recursion rather than a reaction: a request, a
/// judgement about the answer, and possibly a second request on relaxed terms. Written once here
/// instead of inline, where the retry would have to be spelled out twice.
func rerouteRequest(
    from position: Coordinate,
    to target: Coordinate,
    preferences: RoutePreferences,
    /// The exclusions the rider actually chose, which is what an eventual apology is measured
    /// against — not whatever this attempt happens to be asking for.
    chosen: RoutePreferences,
    original: RouteOption,
    decision: RerouteDecision,
    fromStep stepIndex: Int,
    finished: RerouteState,
    world: World
) -> Publisher<AppAction, Never> {
    world.routes(position, target, preferences)
        .map { result -> Publisher<AppAction, Never> in
            let found = (try? result.get()) ?? []
            let outcome = acceptableRoutes(found, preferences: preferences)

            switch outcome {
            case let .routes(routes) where !routes.isEmpty:
                // Rejoining keeps the rest of the route the rider chose; replanning replaces it.
                // Routing straight to the destination after one missed turn is exactly how a single
                // mistake becomes a completely different ride.
                let route = decision == .rejoin
                    ? splice(rejoin: routes[0], onto: original, fromStep: stepIndex)
                    : routes[0]
                return .just(.rerouted(route, finished))

            case .excludedByPreferences:
                // Routes exist and every one of them breaks a rule. The rider may well be *on* the
                // motorway already, in which case no amount of asking politely will produce a way
                // off it that avoids one.
                guard let next = relaxed(preferences) else {
                    return .just(.rerouted(nil, finished))
                }
                let retry = rerouteRequest(
                    from: position, to: target, preferences: next, chosen: chosen,
                    original: original, decision: decision, fromStep: stepIndex,
                    finished: finished, world: world
                )
                // This one *is* spoken. A reroute is routine; being sent down a motorway after
                // saying no motorways is a change to the terms the rider agreed to.
                guard let apology = exclusionBrokenAnnouncement(original: chosen, replacement: next)
                else { return retry }
                return world.speakQueued(apology)
                    .flatMap { _ in retry }

            case .routes, .failed:
                // Nothing to be had. The old route stands: stale, but it still points at the
                // destination, which is more than nothing does.
                return .just(.rerouted(nil, finished))
            }
        }
        .switchToLatest()
}
