import Foundation

// Lane guidance from the map's own paint.
//
// MapKit's routes carry no lane data, so everything here runs on OSM's `turn:lanes` — the tag
// that records what is actually painted on the carriageway, lane by lane, left to right in the
// direction of travel. Where the tag exists it *is* the ground truth the rider can see; where it
// does not, the whole feature stays silent, which is the same bargain as every other announcement
// in this app: no advice beats advice that is sometimes wrong.
//
// The scenario this exists for: a three-lane road whose left lane becomes exit-only. A rider
// keeping on the road needs "use the right two lanes" *before* the paint forces the issue; a
// rider leaving needs "use the left lane to exit". Which of the two applies is decided by the
// route — whether its next manoeuvre falls at the fork or beyond it.

/// One painted arrow. `unmarked` is OSM's `none` — a lane with no arrows, which continues by
/// definition. `unknown` is a token this parser has not met; a lane carrying one still counts,
/// but never confidently.
public enum LaneTurn: Sendable, Equatable {
    case through
    case left, slightLeft, sharpLeft
    case right, slightRight, sharpRight
    case mergeLeft, mergeRight
    case reverse
    case unmarked
    case unknown
}

/// `turn:lanes` grammar: lanes split on `|`, arrows within a lane on `;`. An empty lane slot is
/// a real lane with no marking, so empty subsequences are kept.
public func parseTurnLanes(_ raw: String) -> [[LaneTurn]] {
    raw.split(separator: "|", omittingEmptySubsequences: false).map { lane in
        lane.isEmpty ? [.unmarked] : lane.split(separator: ";").map { token in
            switch token.trimmingCharacters(in: .whitespaces) {
            case "through": .through
            case "left": .left
            case "slight_left": .slightLeft
            case "sharp_left": .sharpLeft
            case "right": .right
            case "slight_right": .slightRight
            case "sharp_right": .sharpRight
            case "merge_to_left": .mergeLeft
            case "merge_to_right": .mergeRight
            case "reverse": .reverse
            case "none", "": .unmarked
            default: .unknown
            }
        }
    }
}

/// The lane picture where the rider is: the painted way under the wheels, read in the direction
/// of travel.
///
/// `splitWayID` names the way where the paint runs out — the fork itself — so one fork is advised
/// once however many tagged ways lead up to it. `splitDistance` is measured along the road, not
/// across the fields.
public struct LaneWayContext: Sendable, Equatable {
    public let splitWayID: Int
    public let turnLanes: String
    public let splitDistance: Meters

    public init(splitWayID: Int, turnLanes: String, splitDistance: Meters) {
        self.splitWayID = splitWayID
        self.turnLanes = turnLanes
        self.splitDistance = splitDistance
    }
}

/// How far ahead of the fork lane advice is worth giving. Fifteen seconds of travel, floored at
/// 250 m so town speeds still get warning, capped at 800 m so a motorway's long painted approach
/// does not produce advice miles before it matters.
public func laneAdviceWindow(speed: MPS) -> Meters {
    Meters(min(800, max(250, speed.rawValue * 15)))
}

/// How far apart the route's manoeuvre and the paint's fork can be and still be the same place.
/// MapKit's manoeuvre point and OSM's way boundary are two independent digitisations of one
/// junction; 150 m absorbs their disagreement without confusing adjacent junctions.
let laneForkToleranceMetres = 150.0

/// What to say about lanes, or nothing.
///
/// Nothing is the common answer, and each silence is deliberate: no fork in the paint, a fork the
/// route turns off before, a manoeuvre whose wording names no side the paint can be matched
/// against, a roundabout whose geometry cannot be read, or a lane picture where every lane serves
/// the movement anyway.
public func laneAdvice(
    steps: [RouteStep],
    stepIndex: Int,
    at position: Coordinate,
    heading: Course?,
    speed: MPS,
    context: LaneWayContext,
    formatDistance: (Meters) -> String
) -> String? {
    let split = context.splitDistance.rawValue
    guard split >= 0, split <= laneAdviceWindow(speed: speed).rawValue else { return nil }

    let turns = parseTurnLanes(context.turnLanes)
    guard turns.count >= 2 else { return nil }
    let continuing = turns.map { lane in lane.contains(.through) || lane.contains(.unmarked) }

    // A lane that ends by merging ends whatever the route does — the announcement is the same
    // one the roadside sign makes, and it outranks fork logic.
    if let ending = mergeAdvice(
        turns: turns, continuing: continuing,
        distance: context.splitDistance, formatDistance: formatDistance
    ) {
        return ending
    }

    // Where the route makes its next move decides which side of the fork the rider belongs on.
    let manoeuvre: Double
    let instruction: String
    if let step = steps[safe: stepIndex] {
        guard let measured = distanceToManoeuvre(steps, index: stepIndex, at: position, heading: heading)
        else { return nil }
        manoeuvre = measured
        instruction = step.instructions.lowercased()
    } else {
        // Past the last manoeuvre the route simply continues, and so should the rider.
        manoeuvre = .infinity
        instruction = ""
    }

    if manoeuvre > split + laneForkToleranceMetres {
        return throughAdvice(
            turns: turns, continuing: continuing,
            distance: context.splitDistance, formatDistance: formatDistance
        )
    }
    guard abs(manoeuvre - split) <= laneForkToleranceMetres else { return nil }
    if instruction.contains("roundabout") {
        return roundaboutAdvice(
            turns: turns, steps: steps, stepIndex: stepIndex,
            distance: Meters(manoeuvre), formatDistance: formatDistance
        )
    }
    return exitAdvice(
        turns: turns, continuing: continuing, instruction: instruction,
        distance: Meters(manoeuvre), formatDistance: formatDistance
    )
}

/// "The left lane ends in 300 yards" — paint whose only divergence is a merge. No route reading
/// needed: the lane ends whichever way the ride goes, and saying so early is exactly what the
/// roadside "lane ends" sign exists for. Spoken only when every non-continuing lane is a merge —
/// paint mixing merges with turn arrows is a fork and is read as one — and only when the ending
/// lanes hug one edge, because "a middle lane ends" is a sentence no one can act on cleanly.
private func mergeAdvice(
    turns: [[LaneTurn]],
    continuing: [Bool],
    distance: Meters,
    formatDistance: (Meters) -> String
) -> String? {
    let merges: Set<LaneTurn> = [.mergeLeft, .mergeRight]
    let ending = zip(turns, continuing).map { lane, keeps in
        !keeps && lane.allSatisfy { merges.contains($0) }
    }
    guard ending.contains(true) else { return nil }
    guard zip(continuing, ending).allSatisfy({ keeps, ends in keeps || ends }) else { return nil }

    let side: String
    let ordered: [Bool]
    if ending[safe: 0] == true {
        side = "left"
        ordered = ending
    } else if ending[safe: ending.count - 1] == true {
        side = "right"
        ordered = Array(ending.reversed())
    } else {
        return nil
    }
    let count = ordered.firstIndex(of: false) ?? ordered.count
    guard count < turns.count else { return nil }
    let verb = count == 1 ? "ends" : "end"
    return "The \(side) \(laneWord(count)) \(verb) in \(formatDistance(distance))"
}

/// "Use the right lane at the roundabout in 200 yards" — the arrows that serve the route's own
/// exit, placed on the clock exactly as the spoken "3 o'clock" is. This is not the withdrawn
/// after-12 heuristic wearing a new coat: that guessed the markings from a rule of thumb, this
/// reads the markings themselves and only maps *which* of them the route's exit angle needs.
/// Paint too unusual for its serving lanes to sit together against an edge gets silence.
private func roundaboutAdvice(
    turns: [[LaneTurn]],
    steps: [RouteStep],
    stepIndex: Int,
    distance: Meters,
    formatDistance: (Meters) -> String
) -> String? {
    guard
        let step = steps[safe: stepIndex],
        let next = steps[safe: stepIndex + 1],
        let incoming = junctionBearing(step.path, approaching: true),
        let outgoing = junctionBearing(next.path, approaching: false)
    else { return nil }

    let rightArrows: Set<LaneTurn> = [.right, .slightRight, .sharpRight]
    let leftArrows: Set<LaneTurn> = [.left, .slightLeft, .sharpLeft]
    let serving: [Bool]
    switch clockDirection(incoming: incoming, outgoing: outgoing) {
    case 1...5:
        serving = turns.map { $0.contains(where: rightArrows.contains) }
    case 7...11:
        serving = turns.map { $0.contains(where: leftArrows.contains) }
    case 12:
        serving = turns.map { $0.contains(.through) || $0.contains(.unmarked) }
    default:
        // Straight back on yourself — paint almost never says, and the clock call already has.
        return nil
    }
    guard
        let first = serving.firstIndex(of: true),
        let last = serving.lastIndex(of: true),
        serving[first...last].allSatisfy({ $0 })
    else { return nil }
    let count = last - first + 1
    guard count < turns.count else { return nil }
    let side = first == 0 ? "left" : (last == turns.count - 1 ? "right" : "middle")
    return "Use the \(side) \(laneWord(count)) at the roundabout in \(formatDistance(distance))"
}

/// "Use the right two lanes to keep on the road in 300 yards" — the through lanes, named by the
/// edge they hug. Spoken only when some lane genuinely leaves the road by a painted arrow: a
/// lane that merely merges is closed by the road itself, and paint weird enough to interleave
/// through lanes with turn lanes gets silence rather than a sentence no one could act on.
private func throughAdvice(
    turns: [[LaneTurn]],
    continuing: [Bool],
    distance: Meters,
    formatDistance: (Meters) -> String
) -> String? {
    let directional: Set<LaneTurn> = [.left, .slightLeft, .sharpLeft, .right, .slightRight, .sharpRight]
    let forks = zip(turns, continuing).contains { lane, keeps in
        !keeps && lane.contains { directional.contains($0) }
    }
    guard forks else { return nil }
    guard
        let first = continuing.firstIndex(of: true),
        let last = continuing.lastIndex(of: true),
        continuing[first...last].allSatisfy({ $0 })
    else { return nil }
    let count = last - first + 1
    guard count < turns.count else { return nil }
    let side = first == 0 ? "left" : (last == turns.count - 1 ? "right" : "middle")
    return "Use the \(side) \(laneWord(count)) to keep on the road in \(formatDistance(distance))"
}

/// "Use the left lane to exit in 200 yards" — the lanes whose arrows serve the route's own
/// manoeuvre. The side comes from the instruction's wording when it names one, and from which
/// edge of the paint diverges when it only says "exit".
private func exitAdvice(
    turns: [[LaneTurn]],
    continuing: [Bool],
    instruction: String,
    distance: Meters,
    formatDistance: (Meters) -> String
) -> String? {
    let leftish: Set<LaneTurn> = [.left, .slightLeft, .sharpLeft]
    let rightish: Set<LaneTurn> = [.right, .slightRight, .sharpRight]

    let side: String
    if instruction.contains("left") {
        side = "left"
    } else if instruction.contains("right") {
        side = "right"
    } else if instruction.contains("exit") || instruction.contains("merge") || instruction.contains("motorway") {
        // The instruction names no side, so the paint decides: whichever edge stops continuing.
        if continuing[safe: 0] == false, turns[safe: 0]?.contains(where: leftish.contains) == true {
            side = "left"
        } else if continuing[safe: turns.count - 1] == false,
                  turns[safe: turns.count - 1]?.contains(where: rightish.contains) == true {
            side = "right"
        } else {
            return nil
        }
    } else {
        return nil
    }

    let serves = side == "left" ? leftish : rightish
    let serving = turns.map { lane in lane.contains(where: serves.contains) }
    // Count from the named edge inward; the group must start at that edge or the sentence lies.
    // Every lane serving would leave nothing to choose between, and that is the nil case too:
    // firstIndex finds no false and the guard falls through to silence.
    let ordered = side == "left" ? serving : Array(serving.reversed())
    guard let count = ordered.firstIndex(of: false), count > 0 else { return nil }

    let verb: String
    if instruction.contains("turn") {
        verb = "turn \(side)"
    } else if instruction.contains("exit") || instruction.contains("motorway") || instruction.contains("merge") {
        verb = "exit"
    } else {
        verb = "keep \(side)"
    }
    return "Use the \(side) \(laneWord(count)) to \(verb) in \(formatDistance(distance))"
}

private func laneWord(_ count: Int) -> String {
    switch count {
    case 1: "lane"
    case 2: "two lanes"
    case 3: "three lanes"
    case 4: "four lanes"
    default: "\(count) lanes"
    }
}
