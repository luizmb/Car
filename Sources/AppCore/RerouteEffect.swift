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
