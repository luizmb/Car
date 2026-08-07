import AppDomain
import FP
import Foundation
import ReactiveConcurrency

/// Asking for a way back, and giving up the rider's exclusions only when there is no other way.
///
/// Separate from `AppFeature` because it is a small recursion rather than a reaction: a request, a
/// judgement about the answer, and possibly a second request on relaxed terms. Written once here
/// instead of inline, where the retry would have to be spelled out twice.
/// Rejoining: compare several places to pick the route back up, and take the soonest.
///
/// The rule this replaces always aimed at the *next* manoeuvre, which is wrong whenever the rider
/// left the route on purpose. Riding a preferred road that converges further along is not a mistake
/// to be undone, and being sent back to the turn they skipped costs a U-turn plus the leg they just
/// rode. Comparing candidates lets the obvious answer — carry on, pick it up ahead — win on its
/// merits rather than by a special case.
///
/// Only the legs need routing. The remainder along the original is estimated from the route's own
/// distance and duration, so four candidates cost one round trip's worth of waiting, not five
/// requests in series.
func rejoinRequest(
    from position: Coordinate,
    original: RouteOption,
    fromStep stepIndex: Int,
    preferences: RoutePreferences,
    chosen: RoutePreferences,
    finished: RerouteState,
    world: World
) -> Publisher<AppAction, Never> {
    let candidates = rejoinCandidates(original, from: stepIndex)
    guard !candidates.isEmpty else {
        // Nothing left to rejoin at — past the last manoeuvre, so the destination is the only
        // target and a plain replan is the honest answer.
        return rerouteRequest(
            from: position, to: original.shape.last ?? position,
            preferences: preferences, chosen: chosen, original: original,
            decision: .replan, fromStep: stepIndex, finished: finished, world: world
        )
    }

    return world.routesToEach(position, candidates.map(\.point), preferences)
        .map { legs -> Publisher<AppAction, Never> in
            let times = legs.map { $0?.travelTime }
            guard
                let winner = bestRejoin(candidates, legTimes: times),
                let index = candidates.firstIndex(of: winner),
                let leg = legs[index]
            else {
                // Every leg failed. Fall back to a full replan rather than leaving the rider on a
                // route they are not on.
                return rerouteRequest(
                    from: position, to: original.shape.last ?? position,
                    preferences: preferences, chosen: chosen, original: original,
                    decision: .replan, fromStep: stepIndex, finished: finished, world: world
                )
            }
            return .just(.rerouted(
                splice(rejoin: leg, onto: original, fromStep: winner.stepIndex), finished
            ))
        }
        .switchToLatest()
}

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
                return .just(.rerouted(routes[0], finished))

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
