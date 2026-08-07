import FP
import FPMacros
import Foundation

// MARK: - Where you are going

/// One result from an address search.
///
/// Addresses and postcodes only — no points of interest. That is a deliberate narrowing rather than
/// a missing feature: "Tesco" is a hundred places and picking one from a list at a junction is
/// exactly the interaction this app exists to avoid, whereas a postcode is unambiguous and is what a
/// rider actually has written down.
public struct AddressSuggestion: Sendable, Equatable, Identifiable {
    /// Composed from the text, because nothing Apple returns carries a stable identifier across
    /// searches and SwiftUI needs one that survives a re-query.
    public var id: String { "\(title)|\(subtitle)" }
    /// The headline — usually the street line.
    public let title: String
    /// Town, county, postcode. Empty when the match had no further context.
    public let subtitle: String

    /// **Absent until resolved.** A completion is text: Apple's completer returns "Ampthill Road,
    /// Bedford" with no coordinates at all, and getting them costs a second request. Resolving every
    /// suggestion as it is typed would be a request per keystroke per row, so it happens once, for
    /// the one the rider actually picks.
    public let latitude: Latitude?
    public let longitude: Longitude?

    public init(
        title: String, subtitle: String,
        latitude: Latitude? = nil, longitude: Longitude? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }

    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// What to send back to the geocoder to turn this into a position.
    public var searchText: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }

    /// One line, for speaking and for the route header.
    public var spoken: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }
}

// MARK: - What you will and will not ride on

/// The two exclusions, and they are **exclusions rather than preferences**.
///
/// Apple's `MKDirectionsRoutePreference.avoid` is a hint: the routing server tries, and returns a
/// motorway route anyway when it cannot find another. That is the correct behaviour for a car
/// navigation app and the wrong one here — a rider who has said "no motorways" on a carburettor bike
/// with no fairing has said something about what they are willing to ride, not what they would
/// prefer. So the hint is sent *and* the answer is checked, and anything still carrying what was
/// excluded is dropped rather than shown greyed out or annotated.
public struct RoutePreferences: Sendable, Equatable {
    public var avoidTolls: Bool
    public var avoidMotorways: Bool

    public init(avoidTolls: Bool = false, avoidMotorways: Bool = false) {
        self.avoidTolls = avoidTolls
        self.avoidMotorways = avoidMotorways
    }

    public static let none = RoutePreferences()
}

// MARK: - A route

/// One turn of the route, as written instructions.
public struct RouteStep: Sendable, Equatable {
    public let instructions: String
    public let distance: Meters
    /// A legal or warning notice attached to this step — level crossings, restricted access.
    public let notice: String?
    /// Where the manoeuvre happens — the first point of the step's own geometry.
    ///
    /// This is what makes guidance possible at all: an instruction without a position can be
    /// listed but never spoken at the right moment.
    public let start: Coordinate?

    public init(instructions: String, distance: Meters, notice: String?, start: Coordinate? = nil) {
        self.instructions = instructions
        self.distance = distance
        self.notice = notice
        self.start = start
    }
}

/// A complete way of getting there.
public struct RouteOption: Sendable, Equatable, Identifiable {
    /// Derived from the shape rather than supplied: `MKRoute` has no identifier, and two requests
    /// are made per search, so the same road can come back twice and needs to be recognised.
    public var id: String { signature }
    /// What Apple calls it — usually the most significant road, e.g. "A421".
    public let name: String
    public let distance: Meters
    public let travelTime: TimeInterval
    /// As **measured on the returned route**, not as asked for. This is what the filter acts on.
    public let hasTolls: Bool
    public let hasMotorways: Bool
    public let steps: [RouteStep]
    /// The shape, for drawing. Kept as domain coordinates so nothing downstream needs MapKit.
    public let shape: [Coordinate]

    public init(
        name: String, distance: Meters, travelTime: TimeInterval,
        hasTolls: Bool, hasMotorways: Bool, steps: [RouteStep], shape: [Coordinate]
    ) {
        self.name = name
        self.distance = distance
        self.travelTime = travelTime
        self.hasTolls = hasTolls
        self.hasMotorways = hasMotorways
        self.steps = steps
        self.shape = shape
    }

    /// The road it takes, sampled.
    ///
    /// Two requests are issued per search — one asking for the exclusions, one unconstrained — and
    /// the same road comes back from both. Quantised distance and time were tried first and were not
    /// enough: Apple returns the *same* road from the two requests with figures that differ slightly,
    /// so a route 150 m apart in two buckets survived as a duplicate and the list showed it twice.
    ///
    /// The geometry does not drift that way. Eight points along the line, rounded to about a hundred
    /// metres, identify the road taken rather than the numbers attached to it — and two genuinely
    /// different ways round diverge by far more than that somewhere among eight samples.
    var signature: String {
        // A route with no geometry has nothing to identify it by, so it falls back to its figures.
        // Both of them: distance alone made two different routes of the same length one route.
        guard shape.count > 1 else {
            return "\(Int(distance.rawValue / 100))|\(Int(travelTime / 30))"
        }
        let samples = 8
        return (0..<samples).map { index in
            let position = Int((Double(shape.count - 1) * Double(index) / Double(samples - 1)).rounded())
            let point = shape[max(0, min(shape.count - 1, position))]
            return "\(Int(point.latitude.rawValue * 1_000)),\(Int(point.longitude.rawValue * 1_000))"
        }
        .joined(separator: "|")
    }
}

// MARK: - Choosing what to show

/// Why routing failed.
///
/// A closed enum rather than a message string, so the cases that mean *different things to the
/// rider* stay distinguishable: `noRoute` is a fact about the journey and `throttled` is a reason to
/// press the button again in a moment. The wording lives in ``routeErrorMessage(_:)`` — building the
/// sentence at the point of failure would put presentation inside a MapKit callback and make the
/// distinction unrecoverable.
@Prisms
public enum RouteError: Error, Sendable, Equatable {
    case placeNotFound
    case noRoute
    case throttled
    case serviceUnavailable
    /// Anything the routing service reported that does not map to the above. Carries its own text
    /// because there is nothing better to say about it, and swallowing it would leave a rider with
    /// a silent failure and no way to report what happened.
    case other(String)
}

public func routeErrorMessage(_ error: RouteError) -> String {
    switch error {
    case .placeNotFound: "Could not find that place."
    case .noRoute: "No route found."
    case .throttled: "Too many requests — try again in a moment."
    case .serviceUnavailable: "The routing service is unavailable."
    case let .other(message): message
    }
}

/// Why there is nothing to show, when there is nothing to show.
///
/// The distinction matters and is the reason this is not just an empty array. "Every route Apple
/// knows uses a motorway" is a fact about the journey the rider needs to hear — it means *change the
/// preference or do not go this way*. "The routing service failed" means try again. Collapsing both
/// into an empty list would offer no way to tell one from the other, and the rider would sit at a
/// junction wondering which had happened.
@Prisms
public enum RouteSearchOutcome: Sendable, Equatable {
    case routes([RouteOption])
    /// Routes exist, but every one of them uses something the rider excluded.
    case excludedByPreferences(RoutePreferences)
    case failed(RouteError)
}

/// The routes worth offering: those that actually honour the exclusions, best first.
///
/// - Anything still carrying an excluded feature is **dropped**, not annotated. See
///   ``RoutePreferences`` for why the hint alone is not enough.
/// - Duplicates are merged, because two requests are issued per search and they overlap heavily.
/// - Sorted by time, capped at `limit`. A list of ten routes at a junction is not a choice, it is a
///   reading task.
public func acceptableRoutes(
    _ routes: [RouteOption],
    preferences: RoutePreferences,
    limit: Int = 5
) -> RouteSearchOutcome {
    let honoured = routes.filter { route in
        !(preferences.avoidTolls && route.hasTolls)
            && !(preferences.avoidMotorways && route.hasMotorways)
    }

    guard !honoured.isEmpty else {
        // Nothing survived. If nothing was asked for either, the search genuinely found nothing;
        // otherwise the exclusions are what emptied it, and saying so is the whole point.
        return routes.isEmpty || preferences == .none
            ? .routes([])
            : .excludedByPreferences(preferences)
    }

    var seen: Set<String> = []
    let unique = honoured
        .sorted { $0.travelTime < $1.travelTime }
        .filter { seen.insert($0.signature).inserted }

    return .routes(Array(unique.prefix(limit)))
}

// MARK: - Labelling the options

/// The short phrase that distinguishes a route from the others on screen.
///
/// What a rider needs at a glance is not "route 2" but *why they might pick it*. Fastest is the
/// obvious one; the exclusions are the ones this app exists for, since a route that avoids motorways
/// is the whole reason someone on a carburettor 400 is looking at this list.
///
/// `nil` when there is nothing to distinguish — a middling route needs no label, and inventing one
/// would make three identical badges.
public func routeBadge(_ route: RouteOption, among routes: [RouteOption]) -> String? {
    // Compared on time rather than identity: identity is the geometry, and asking whether *this*
    // route is the fastest object is a subtly different question from whether it takes the least
    // time — which is the one a rider is asking.
    if route.travelTime == routes.map(\.travelTime).min() { return "Fastest" }
    if !route.hasMotorways, routes.contains(where: \.hasMotorways) { return "Avoids motorways" }
    if !route.hasTolls, routes.contains(where: \.hasTolls) { return "Avoids tolls" }
    return nil
}

/// Where to hang a route's badge on the map.
///
/// Spread along the line by position in the list rather than all at the midpoint, because routes
/// between the same two points converge at both ends — three badges stacked on top of each other
/// would defeat the purpose of drawing them at all.
public func badgeAnchor(_ route: RouteOption, index: Int, of count: Int) -> Coordinate? {
    guard !route.shape.isEmpty else { return nil }
    let spread = count > 1 ? 0.3 + 0.4 * (Double(index) / Double(count - 1)) : 0.5
    let position = Int((Double(route.shape.count - 1) * spread).rounded())
    return route.shape[max(0, min(route.shape.count - 1, position))]
}

/// A point `metres` away on a bearing.
///
/// Used to aim the map camera *ahead* of the rider rather than at them. Centring on the rider puts
/// them in the middle of the screen with half the view showing road already travelled — which is
/// the one half that cannot matter. Navigation mode centres ahead so the rider sits low and the
/// road they are about to ride fills the screen.
public func coordinate(
    from origin: Coordinate, bearing degrees: Double, metres: Double
) -> Coordinate {
    let radians = degrees * .pi / 180
    let latitude = origin.latitude.rawValue + (metres * cos(radians)) / 111_320
    let scale = cos(origin.latitude.rawValue * .pi / 180)
    // At the poles a metre of longitude is unbounded degrees; guard rather than divide by zero.
    let longitude = abs(scale) < 0.000_001
        ? origin.longitude.rawValue
        : origin.longitude.rawValue + (metres * sin(radians)) / (111_320 * scale)
    return Coordinate(latitude: Latitude(latitude), longitude: Longitude(longitude))
}

/// Which way the route goes from here.
///
/// The map's heading while navigating, and **not** the GPS course. Course is the direction the
/// receiver last observed movement in: it is undefined when stopped, and jitters badly at walking
/// pace — so a rider waiting at the junction they are about to turn at would watch the whole map
/// swing around them. The route does not move, so taking the bearing from here to a point a little
/// further along it is steady whether the bike is doing seventy or nothing at all.
///
/// `nil` when there is no route or nowhere further along it to look, in which case the caller keeps
/// whatever heading it was using.
public func routeBearing(
    shape: [Coordinate], from position: Coordinate, lookahead: Double = 120
) -> Double? {
    guard shape.count > 1 else { return nil }

    // The nearest vertex is where we are on the line. Nearest rather than "next unvisited", because
    // this is recomputed from scratch each fix and carries no memory of progress.
    var nearest = 0
    var best = Double.greatestFiniteMagnitude
    for (index, point) in shape.enumerated() {
        let distance = distanceMetres(from: position.pair, to: point.pair)
        if distance < best {
            best = distance
            nearest = index
        }
    }

    // Walk forward until far enough ahead to give a stable bearing. Too close and every wobble in
    // the polyline becomes a turn of the map.
    var travelled = 0.0
    var index = nearest
    while index + 1 < shape.count, travelled < lookahead {
        travelled += distanceMetres(from: shape[index].pair, to: shape[index + 1].pair)
        index += 1
    }
    guard index > nearest else { return nil }
    return bearing(from: position.pair, to: shape[index].pair)
}

/// How far above the road the camera should sit while following a route.
///
/// Two pulls, and the tighter wins.
///
/// **Speed** sets the baseline, because what a rider needs to see is *time* ahead rather than
/// distance: at 70 mph a fixed 400 m of view is twelve seconds of warning, and at walking pace it is
/// two minutes of empty road. Roughly fifteen seconds of travel, floored so a stationary map is not
/// pressed against the tarmac and capped so a motorway does not zoom to a county.
///
/// **The next turn** overrides it on the approach. A junction is read from its shape — which lane,
/// which exit — and that is unreadable from height, so the last few hundred metres pull the camera
/// down regardless of speed.
public func navigationCameraDistance(speed: MPS, nextTurn: Meters?) -> Double {
    let forSpeed = min(1_100, max(280, speed.rawValue * 15))
    guard let nextTurn, nextTurn.rawValue < 400 else { return forSpeed }
    // Closing on the junction: 250 m up at 400 m out, down to 180 m at the junction itself.
    let approach = 180 + (nextTurn.rawValue / 400) * 70
    return min(forSpeed, approach)
}

// MARK: - Following it

/// How far from a manoeuvre each of the two calls is made.
///
/// Two, not one. A single call is either too early to act on or too late to prepare for, and on a
/// bike the preparation is the part that matters — a lane change and a gear change both have to
/// happen before the junction, not at it.
///
/// The early call scales with speed for the same reason ``lookaheadDistance`` does: 300 m is a
/// comfortable twenty seconds at 30 mph and six at 70.
public func guidanceDistances(speed: MPS) -> (early: Meters, imminent: Meters) {
    let early = min(800, max(200, speed.rawValue * 20))
    return (Meters(early), Meters(40))
}

/// What has been said about the step being approached.
///
/// Tracked so each call happens once. Without it every fix inside the window would repeat the
/// instruction, which at one fix a second is unusable in a helmet.
public enum GuidanceStage: Int, Sendable, Equatable, Comparable {
    case none = 0
    case early = 1
    case imminent = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where the rider is along a route, and what remains to be said.
public struct GuidanceState: Sendable, Equatable {
    /// The step being approached. Steps are followed in order rather than by proximity: a route that
    /// doubles back passes close to a later manoeuvre long before it is due, and picking the nearest
    /// would announce it then.
    public var stepIndex: Int
    public var stage: GuidanceStage
    /// The closest this step's junction has been so far.
    ///
    /// A step is finished by *receding*, not by being reached — which is the difference between
    /// "you are near the turn" and "you have taken it". Being near it was the rule at first and it
    /// was wrong in the most visible way possible: MapKit's first manoeuvre is often a few dozen
    /// metres from where the bike is parked, so pressing GO consumed it on the spot and the very
    /// first instruction shown was the *second* turn of the route.
    public var closest: Double
    /// Set once the last step has been passed, so arrival is announced exactly once.
    public var arrived: Bool

    public init(
        stepIndex: Int = 0,
        stage: GuidanceStage = .none,
        closest: Double = .greatestFiniteMagnitude,
        arrived: Bool = false
    ) {
        self.stepIndex = stepIndex
        self.stage = stage
        self.closest = closest
        self.arrived = arrived
    }
}

/// How far past the closest approach counts as having taken the turn.
///
/// Generous enough not to trip on GPS noise while stopped at the junction — a fix wandering by ten
/// metres must not read as having gone through it — and small enough that the next instruction
/// arrives promptly once actually moving.
let passedByMetres: Double = 30

/// How short a run between two manoeuvres counts as "and then immediately".
///
/// At 30 mph, 150 m is about eleven seconds — not enough to hear one instruction, act on it, and
/// then be told the next in time to get into the right lane for it. Below that the two are really
/// one manoeuvre and are spoken as one.
public let chainWithinMetres: Double = 150

/// The instruction for a step, with the one after it attached when they come too close together.
///
/// "Turn left onto Tennyson Road, then immediately turn right onto London Road" — because being
/// told only the first, in a junction where both happen within a few seconds, puts a rider in the
/// wrong lane. Only ever two: a third would be a paragraph, and by then the first is done and the
/// next call is due anyway.
///
/// **Spoken only.** The banner deliberately keeps showing the immediate next manoeuvre alone, since
/// a glance has to answer one question, and the chained pair is twice the text for the half of it
/// that matters right now.
public func chainedInstruction(
    _ steps: [RouteStep], from index: Int, within: Double = chainWithinMetres
) -> String {
    guard steps.indices.contains(index) else { return "" }
    let instruction = steps[index].instructions
    // The step's own length *is* the gap to the next manoeuvre: a step runs from one turn to the
    // next, so no geometry is needed to measure it.
    guard
        steps[index].distance.rawValue <= within,
        steps.indices.contains(index + 1)
    else { return instruction }
    return "\(instruction), then immediately \(lowercasedFirst(steps[index + 1].instructions))"
}

/// One thing to say, and the guidance state that follows from having said it.
public struct GuidanceUpdate: Sendable, Equatable {
    public let announcement: String?
    public let state: GuidanceState

    public init(announcement: String?, state: GuidanceState) {
        self.announcement = announcement
        self.state = state
    }
}

/// The next manoeuvre, as something to keep on screen.
///
/// Distinct from the spoken calls, which happen twice and then stop: a banner is *always* showing
/// the current answer to "what am I doing next", counting down as the junction approaches. On a bike
/// that is what replaces glancing at a phone.
public struct GuidanceBanner: Sendable, Equatable {
    public let instruction: String
    /// Already formatted. The root view deliberately holds no `World` — it knows a view store and a
    /// router and nothing else — so the distance arrives as text rather than as something the view
    /// would need a formatter to render.
    public let distanceText: String
    /// The same distance as a number, for the camera. Text cannot be compared against a threshold,
    /// and the map has to tighten as a junction approaches.
    public let distance: Meters

    public init(instruction: String, distanceText: String, distance: Meters) {
        self.instruction = instruction
        self.distanceText = distanceText
        self.distance = distance
    }
}

/// What to display for a fix, independent of what has been said about it.
public func guidanceBanner(
    route: RouteOption, at position: Coordinate, state: GuidanceState,
    formatDistance: (Meters) -> String
) -> GuidanceBanner? {
    guard !state.arrived else { return nil }
    let steps = route.steps.filter { $0.start != nil }
    guard state.stepIndex < steps.count, let start = steps[state.stepIndex].start else {
        return nil
    }
    let remaining = Meters(distanceMetres(from: position.pair, to: start.pair))
    return GuidanceBanner(
        instruction: steps[state.stepIndex].instructions,
        distanceText: formatDistance(remaining),
        distance: remaining
    )
}

/// Advances guidance for one position fix.
///
/// Pure, and the whole of the turn-by-turn logic — which is what makes it testable without a bike, a
/// route server, or a moving map.
///
/// The rules, in order:
/// - past the last step, announce arrival once
/// - within the imminent window, give the instruction and move to the next step
/// - within the early window, give it as a warning
/// - otherwise say nothing
public func guidance(
    route: RouteOption,
    at position: Coordinate,
    speed: MPS,
    state: GuidanceState,
    formatDistance: (Meters) -> String
) -> GuidanceUpdate {
    guard !state.arrived else { return GuidanceUpdate(announcement: nil, state: state) }

    let steps = route.steps.filter { $0.start != nil }
    guard state.stepIndex < steps.count else {
        // Nothing left to turn at. Arrival is judged against the end of the line rather than the
        // last instruction, because the last instruction is usually "arrive" at the same place.
        guard let destination = route.shape.last else {
            return GuidanceUpdate(announcement: nil, state: state)
        }
        let remaining = distanceMetres(from: position.pair, to: destination.pair)
        guard remaining <= 60 else { return GuidanceUpdate(announcement: nil, state: state) }
        var next = state
        next.arrived = true
        return GuidanceUpdate(announcement: "You have arrived.", state: next)
    }

    let step = steps[state.stepIndex]
    guard let start = step.start else { return GuidanceUpdate(announcement: nil, state: state) }

    let distance = Meters(distanceMetres(from: position.pair, to: start.pair))
    let windows = guidanceDistances(speed: speed)
    var next = state
    next.closest = min(state.closest, distance.rawValue)

    // Taken the turn: it was reached, and is now receding.
    if state.stage == .imminent, distance.rawValue > next.closest + passedByMetres {
        next.stepIndex += 1
        next.stage = .none
        next.closest = .greatestFiniteMagnitude
        return GuidanceUpdate(announcement: nil, state: next)
    }

    if distance.rawValue <= windows.imminent.rawValue, state.stage < .imminent {
        next.stage = .imminent
        return GuidanceUpdate(
            announcement: chainedInstruction(steps, from: state.stepIndex), state: next
        )
    }

    if distance.rawValue <= windows.early.rawValue, state.stage < .early {
        next.stage = .early
        return GuidanceUpdate(
            announcement: "In \(formatDistance(distance)), "
                + lowercasedFirst(chainedInstruction(steps, from: state.stepIndex)),
            state: next
        )
    }

    return GuidanceUpdate(announcement: nil, state: next)
}

/// "Turn left onto A421" becomes "turn left onto A421", so it reads as one sentence after "In 300
/// metres,". Only the first character — lowercasing the lot would ruin every road name in it.
func lowercasedFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.lowercased() + text.dropFirst()
}

// MARK: - Leaving the route

/// How far the rider is from the line they are supposed to be on.
///
/// Measured to the nearest **segment**, not the nearest point: a polyline through open country can
/// have vertices hundreds of metres apart, and measuring only to vertices would call a rider
/// perfectly on the road fifty metres off it, halfway between two of them.
public func distanceToRoute(shape: [Coordinate], from position: Coordinate) -> Double {
    guard let first = shape.first else { return .greatestFiniteMagnitude }
    guard shape.count > 1 else { return distanceMetres(from: position.pair, to: first.pair) }

    var best = Double.greatestFiniteMagnitude
    for index in 0..<(shape.count - 1) {
        best = min(best, distanceToSegment(position, shape[index], shape[index + 1]))
    }
    return best
}

/// Perpendicular distance to a segment, falling back to the nearer end when the foot of the
/// perpendicular lies outside it.
///
/// Done in metres on a local flat approximation rather than in degrees. A degree of longitude is
/// two thirds of a degree of latitude at this latitude, so treating them as interchangeable would
/// make every east–west road look closer than it is.
func distanceToSegment(_ point: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
    let scale = cos(a.latitude.rawValue * .pi / 180)
    let ax = 0.0, ay = 0.0
    let bx = (b.longitude.rawValue - a.longitude.rawValue) * 111_320 * scale
    let by = (b.latitude.rawValue - a.latitude.rawValue) * 111_320
    let px = (point.longitude.rawValue - a.longitude.rawValue) * 111_320 * scale
    let py = (point.latitude.rawValue - a.latitude.rawValue) * 111_320

    let dx = bx - ax, dy = by - ay
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }

    // Clamped, so a point beyond either end measures to that end rather than to the infinite line.
    let t = max(0, min(1, (px * dx + py * dy) / lengthSquared))
    let cx = t * dx, cy = t * dy
    return ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
}

/// How far off the line counts as off the route.
///
/// Wide, and deliberately. A parallel service road, a dual carriageway's other carriageway and a
/// GPS fix bouncing off a building are all tens of metres, and re-routing a rider who is in fact on
/// the right road is worse than being slow to notice one who is not.
public let offRouteMetres: Double = 55

/// How many consecutive fixes off the line before believing it. At roughly one a second, three is
/// enough to rule out a single bad fix without dawdling.
public let offRouteFixes: Int = 3

/// What is known about having left the route.
public struct RerouteState: Sendable, Equatable {
    /// Consecutive fixes measured off the line. Reset by a single fix back on it.
    public var offRouteFixCount: Int
    /// How many times a new route has been needed on this journey. The escalation is built on this:
    /// one missed turn is a missed turn, and four is a road that is not there any more.
    public var deviations: Int
    /// Set while a request is out, so a reroute is not asked for again on every fix while the first
    /// one is still in flight.
    public var isRerouting: Bool

    public init(offRouteFixCount: Int = 0, deviations: Int = 0, isRerouting: Bool = false) {
        self.offRouteFixCount = offRouteFixCount
        self.deviations = deviations
        self.isRerouting = isRerouting
    }
}

/// What to do about being off the route.
@Prisms
public enum RerouteDecision: Sendable, Equatable {
    case carryOn
    /// Get back to the route the rider chose, joining it at the next manoeuvre. The default
    /// response to a missed turn or a wrong exit, and the reason a single mistake does not throw
    /// away the route they picked and send them somewhere else entirely.
    case rejoin
    /// Give up on the original line and route to the destination afresh. Reached only after
    /// repeated deviations, on the theory that a rider who keeps not taking a turn is being stopped
    /// from taking it — roadworks, a closure, a no-entry that OSM has not caught up with.
    case replan
}

public func rerouteDecision(
    distanceOff: Double, state: RerouteState, afterDeviations threshold: Int = 3
) -> RerouteDecision {
    guard !state.isRerouting else { return .carryOn }
    guard state.offRouteFixCount >= offRouteFixes else { return .carryOn }
    return state.deviations >= threshold ? .replan : .rejoin
}

/// Advances the off-route counter for one fix.
public func trackingRoute(_ state: RerouteState, distanceOff: Double) -> RerouteState {
    var next = state
    next.offRouteFixCount = distanceOff > offRouteMetres ? state.offRouteFixCount + 1 : 0
    return next
}

// MARK: - Stitching a way back on

/// The rejoin route, followed by whatever was left of the original.
///
/// This is what makes ``RerouteDecision/rejoin`` mean what it says. Routing straight to the final
/// destination after a missed turn is what sends a rider down a completely different road — Apple
/// answers "best way there from here", which after one wrong turn is frequently a different route
/// altogether. Splicing keeps the ride the rider actually chose and treats the mistake as a
/// detour back onto it.
///
/// Distance and travel time add; the exclusions are `true` if either half carries them, since a
/// spliced route uses a motorway if any part of it does.
public func splice(
    rejoin: RouteOption, onto original: RouteOption, fromStep index: Int
) -> RouteOption {
    let remainingSteps = index < original.steps.count
        ? Array(original.steps[index...])
        : []
    // The tail of the original's geometry, from the manoeuvre being rejoined at. Falls back to the
    // whole of it when that manoeuvre has no position, which is the same fallback guidance uses.
    let joinPoint = remainingSteps.first?.start
    let tail = joinPoint.map { point in
        Array(original.shape.drop { distanceMetres(from: $0.pair, to: point.pair) > 25 })
    } ?? []

    return RouteOption(
        name: original.name,
        distance: Meters(rejoin.distance.rawValue + original.distance.rawValue),
        travelTime: rejoin.travelTime + original.travelTime,
        hasTolls: rejoin.hasTolls || original.hasTolls,
        hasMotorways: rejoin.hasMotorways || original.hasMotorways,
        steps: rejoin.steps + remainingSteps,
        shape: rejoin.shape + tail
    )
}

// MARK: - When the exclusions cannot be kept

/// What to say when a new route has had to break one of the rider's rules.
///
/// Spoken, unlike the reroute itself. A reroute is routine and gets a tone; this is a change to the
/// terms the rider agreed to — they said no motorways, and they are about to be sent down one — and
/// that is worth words.
public func exclusionBrokenAnnouncement(
    original: RoutePreferences, replacement: RoutePreferences
) -> String? {
    let motorway = original.avoidMotorways && !replacement.avoidMotorways
    let toll = original.avoidTolls && !replacement.avoidTolls
    switch (motorway, toll) {
    case (true, true): return "No way round from here. New route uses a motorway and tolls."
    case (true, false): return "No way round from here. New route uses a motorway."
    case (false, true): return "No way round from here. New route uses a toll."
    case (false, false): return nil
    }
}

/// The exclusions, given up one at a time.
///
/// Motorways go first because that is the one most likely to be genuinely unavoidable — a rider
/// already *on* a motorway cannot be routed off it without using it, and slip roads are motorway.
/// Tolls are almost always avoidable, so they are surrendered last.
public func relaxed(_ preferences: RoutePreferences) -> RoutePreferences? {
    if preferences.avoidMotorways {
        return RoutePreferences(avoidTolls: preferences.avoidTolls, avoidMotorways: false)
    }
    if preferences.avoidTolls {
        return RoutePreferences(avoidTolls: false, avoidMotorways: false)
    }
    return nil
}

// MARK: - Drawing it

/// The route thinned to something a map can draw once a second.
///
/// A route across England is tens of thousands of points, and the map camera sits 500 m above the
/// rider — so all but a few hundred metres of it is off screen, and the full polyline is detail
/// nobody can see being redrawn on every GPS fix.
///
/// Strided rather than Douglas–Peucker: the expensive algorithm earns its keep when the shape must
/// survive being zoomed into, and this one is only ever seen at one zoom level with the far end of
/// it beyond the horizon. At the default cap a 50 km route keeps a point every 25 m, which is finer
/// than the map draws at that height.
///
/// The **first and last points are always kept**, so the line still starts under the rider and ends
/// at the destination rather than near them.
public func simplified(_ shape: [Coordinate], maxPoints: Int = 2_000) -> [Coordinate] {
    guard maxPoints >= 2, shape.count > maxPoints else { return shape }
    let stride = Int((Double(shape.count) / Double(maxPoints - 1)).rounded(.up))
    var kept = shape.enumerated().compactMap { $0.offset.isMultiple(of: stride) ? $0.element : nil }
    if let last = shape.last, kept.last != last { kept.append(last) }
    return kept
}

// MARK: - Saying it

/// "42 minutes, 18 miles, via A421."
///
/// Time first because it is what a rider chooses on, and the road name last because it is what
/// distinguishes two options that take about as long as each other.
public func routeSummary(
    _ route: RouteOption,
    formatDistance: (Meters) -> String,
    formatDuration: (TimeInterval) -> String
) -> String {
    let base = "\(formatDuration(route.travelTime)), \(formatDistance(route.distance))"
    return route.name.isEmpty ? base : "\(base), via \(route.name)"
}

/// What to say when a route has been chosen.
///
/// Spoken once, on selection, and deliberately short: the rider is about to set off and everything
/// after this arrives turn by turn.
public func routeChosenAnnouncement(
    _ route: RouteOption,
    to destination: String,
    formatDistance: (Meters) -> String,
    formatDuration: (TimeInterval) -> String
) -> String {
    "Heading to \(destination). \(formatDuration(route.travelTime)), \(formatDistance(route.distance))."
}

/// What to say when the exclusions have left nothing.
///
/// Names the exclusion that did it, because the rider's next move depends on which one: a toll is
/// usually a few pounds, a motorway on this bike is a different question entirely.
public func noRouteAnnouncement(_ preferences: RoutePreferences) -> String {
    switch (preferences.avoidMotorways, preferences.avoidTolls) {
    case (true, true):
        "No route that avoids both motorways and tolls."
    case (true, false):
        "No route that avoids motorways."
    case (false, true):
        "No route that avoids tolls."
    case (false, false):
        "No route found."
    }
}
