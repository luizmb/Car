import AppDomain
import CoreFP
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
    heading: Course?,
    speed: MPS?,
    original: RouteOption,
    fromStep stepIndex: Int,
    preferences: RoutePreferences,
    chosen chosenPreferences: RoutePreferences,
    finished: RerouteState,
    world: World
) -> Publisher<AppAction, Never> {
    let candidates = rejoinCandidates(original, from: stepIndex, at: position, heading: heading)
    guard !candidates.isEmpty else {
        // Nothing left to rejoin at — past the last manoeuvre, so the destination is the only
        // target and a plain replan is the honest answer.
        return rerouteRequest(
            from: position, course: heading, speed: speed,
            to: original.shape.last ?? position,
            preferences: preferences, chosen: chosenPreferences, original: original,
            decision: .replan, fromStep: stepIndex, finished: finished, world: world
        )
    }

    // The legs carry the rider's direction: asked from a point projected ahead along the course,
    // and any leg that opens against the traveller pays the U-turn penalty — so "carry on, pick
    // it up ahead" beats "double back" on merit, and doubling back still wins when it is clearly
    // cheaper. The short way back to the chosen route, without the summons.
    return world.routesToEach(
        projectedOrigin(position, course: heading, speed: speed),
        candidates.map(\.point),
        preferences
    )
        .map { legs -> Publisher<AppAction, Never> in
            let times = legs.map { leg in
                leg.map { $0.travelTime + uTurnPenaltySeconds(route: $0, course: heading) }
            }
            // Why this candidate and not another. Every reroute so far has been diagnosed by
            // reasoning about what *should* have been chosen, and that has been wrong twice: a
            // candidate can lose because it is genuinely slower, or because its leg failed to route
            // and it was dropped, and those two look identical from outside.
            let scores = zip(candidates, times)
                .map { candidate, leg in
                    "step\(candidate.stepIndex)="
                        + (leg.map { "\(Int($0))+\(Int(candidate.remainingTime))=\(Int($0 + candidate.remainingTime))" }
                            ?? "failed")
                }
                .joined(separator: " ")
            let chosen = bestRejoin(candidates, legTimes: times)
            let logged = world.logAction("rejoin \(scores) -> step\(chosen.map { String($0.stepIndex) } ?? "none")")

            guard
                let winner = chosen,
                let index = candidates.firstIndex(of: winner),
                let leg = legs[safe: index] ?? nil
            else {
                // Every leg failed. Fall back to a full replan rather than leaving the rider on a
                // route they are not on.
                return logged.flatMap { _ in
                    rerouteRequest(
                        from: position, course: heading, speed: speed,
                        to: original.shape.last ?? position,
                        preferences: preferences, chosen: chosenPreferences, original: original,
                        decision: .replan, fromStep: stepIndex, finished: finished, world: world
                    )
                }
            }
            return logged.flatMap { _ in
                Publisher<AppAction, Never>.just(.rerouted(
                    splice(rejoin: leg, onto: original, fromStep: winner.stepIndex), finished
                ))
            }
        }
        .switchToLatest()
}

func rerouteRequest(
    from position: Coordinate,
    course: Course?,
    speed: MPS?,
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
    // The origin sits a few metres *ahead* of the bike: the public routing API cannot be told a
    // heading, but a router asked from in front of the rider has already been told which way
    // they are going — this, plus the U-turn penalty below, is why a deliberate detour now gets
    // a forward route instead of a summons back to the missed turn.
    world.routes(projectedOrigin(position, course: course, speed: speed), target, preferences)
        .map { result -> Publisher<AppAction, Never> in
            let found = (try? result.get()) ?? []
            let outcome = acceptableRoutes(found, preferences: preferences)

            switch outcome {
            case let .routes(routes) where !routes.isEmpty:
                let best = routes.min { a, b in
                    a.travelTime + uTurnPenaltySeconds(route: a, course: course)
                        < b.travelTime + uTurnPenaltySeconds(route: b, course: course)
                }
                return .just(.rerouted(best ?? routes[0], finished))

            case .excludedByPreferences:
                // Routes exist and every one of them breaks a rule. The rider may well be *on* the
                // motorway already, in which case no amount of asking politely will produce a way
                // off it that avoids one.
                guard let next = relaxed(preferences) else {
                    return .just(.rerouted(nil, finished))
                }
                let retry = rerouteRequest(
                    from: position, course: course, speed: speed, to: target,
                    preferences: next, chosen: chosen,
                    original: original, decision: decision, fromStep: stepIndex,
                    finished: finished, world: world
                )
                // This one *is* spoken. A reroute is routine; being sent down a motorway after
                // saying no motorways is a change to the terms the rider agreed to.
                guard let apology = exclusionBrokenAnnouncement(original: chosen, replacement: next)
                else { return retry }
                return world.speakDirections(apology)
                    .flatMap { _ in retry }

            case .routes, .failed:
                // Nothing to be had. The old route stands: stale, but it still points at the
                // destination, which is more than nothing does.
                return .just(.rerouted(nil, finished))
            }
        }
        .switchToLatest()
}
