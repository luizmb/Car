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
    /// The step's approach, exactly as MapKit segments it.
    ///
    /// **The polyline leads up to the manoeuvre; the instruction applies at its end.** Read the
    /// other way — as the road ridden after the turn — every announcement keys one junction early,
    /// which a side-by-side ride against Apple Maps showed as a consistent off-by-one, down to
    /// "you have arrived" firing at Apple's final turn call. So: the rider is *approaching* this
    /// step's manoeuvre while on this path, and has *completed* it when riding the next step's.
    public let path: [Coordinate]

    public init(
        instructions: String, distance: Meters, notice: String?,
        start: Coordinate? = nil, path: [Coordinate] = []
    ) {
        self.instructions = instructions
        self.distance = distance
        self.notice = notice
        self.start = start
        self.path = path
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
            guard let point = shape[safe: max(0, min(shape.count - 1, position))] else { return "" }
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
    return route.shape[safe: max(0, min(route.shape.count - 1, position))]
}

/// How far along the route a point is, in metres from its start.
///
/// The honest measure of progress, and the only one that survives a bend: straight-line distance to
/// a manoeuvre says nothing about whether it is ahead or behind, because a route that curves puts
/// later turns physically nearer than earlier ones.
///
/// `nil` when the point is nowhere near the route — being off it is a different question, answered
/// by ``distanceToRoute(shape:from:)``.
public func distanceAlongRoute(
    _ shape: [Coordinate],
    to point: Coordinate,
    within: Double = 200,
    /// Progress already made, and how far either side of it to look.
    ///
    /// **The reason the whole sequence ran ahead.** Searching the entire polyline for the nearest
    /// segment has no notion of continuity, and a route passes near itself constantly — most of all
    /// at a roundabout, where it comes within metres. Match the wrong lap and progress leaps
    /// forward, which skips manoeuvres: a rider on Newlands Road was shown "turn left onto
    /// Dunstable Road" because Dunstable's junction was 938 m away in a straight line while the
    /// Church Road turn actually next was 1,883 m.
    ///
    /// `nil` means no progress is known yet — the first fix — and the whole route is fair game.
    near: Double? = nil,
    // 250 m is twenty seconds at 30 mph — far more than a fix ever advances — and small enough
    // that it cannot reach round a roundabout to the far side and match the wrong lap. A wide
    // window defeats the point of having one.
    window: Double = 250
) -> Double? {
    guard shape.count > 1 else { return nil }
    var travelled = 0.0
    var best: (distance: Double, along: Double)?

    for index in 0..<(shape.count - 1) {
        guard let a = shape[safe: index], let b = shape[safe: index + 1] else { continue }
        let segment = distanceMetres(from: a.pair, to: b.pair)
        // Outside the window, so it belongs to another part of the route however near it looks.
        if let near, abs(travelled - near) > window {
            travelled += segment
            continue
        }
        let offset = distanceToSegment(point, a, b)
        if best.map({ offset < $0.distance }) ?? true {
            // Along the segment as far as the foot of the perpendicular, approximated by how much
            // nearer the point is to the segment's end than its start. Good to a few metres, which
            // is far below the thresholds this feeds.
            let toStart = distanceMetres(from: point.pair, to: a.pair)
            // Same NaN guard as `pathFix`: the difference goes fractionally negative at a
            // perpendicular, and a NaN through `min` reads as the whole segment.
            let into = min(segment, max(0, toStart * toStart - offset * offset).squareRoot())
            best = (offset, travelled + into)
        }
        travelled += segment
    }
    guard let best, best.distance <= within else { return nil }
    return best.along
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
        guard let here = shape[safe: index], let next = shape[safe: index + 1] else { break }
        travelled += distanceMetres(from: here.pair, to: next.pair)
        index += 1
    }
    guard index > nearest, let target = shape[safe: index] else { return nil }
    return bearing(from: position.pair, to: target.pair)
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
    // Thirty seconds of warning, measured against a real ride, not guessed. The previous windows
    // put the "now" call 3.5-6 s before every junction - the sentence takes three to four seconds
    // to speak, so it *ended* as the rider entered - and the early call about twenty. A lane
    // change and a gear change both have to happen before the turn, and both need the sentence
    // finished first.
    let early = min(1_200, max(300, speed.rawValue * 30))
    // Eight seconds for the final call: enough to hear it, act, and arrive. The floor matters most
    // - at town speeds the old 40 m floor was four seconds, and every measured call on a real
    // ride sat between 3.5 and 6.
    let imminent = min(250, max(80, speed.rawValue * 8))
    return (Meters(early), Meters(imminent))
}

/// What has been said about the manoeuvre being approached.
///
/// Tracked so each call happens once. Without it every fix inside the window would repeat the
/// instruction, which at one fix a second is unusable in a helmet.
public enum GuidanceStage: Int, Sendable, Equatable, Comparable {
    case none = 0
    case early = 1
    case imminent = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where the rider is along a route, as the *step machine* sees it.
///
/// Small on purpose. The previous state carried a closest-approach, a spoken-ahead flag and a
/// scalar progress along a flattened shape, and the interactions between them produced every
/// off-by-one this feature has shipped. What replaced them is MapKit's own structure: each step's
/// polyline is the road ridden while executing that instruction, so "which instruction is next"
/// reduces to "whose polyline am I on".
public struct GuidanceState: Sendable, Equatable {
    /// The step whose instruction is the next to complete. Everything spoken is about this step —
    /// possibly with the one after attached when they come at once — and never about anything
    /// beyond it. That is the rider's rule, and here it holds by construction.
    public var stepIndex: Int
    public var stage: GuidanceStage
    /// Set once the last step has been passed, so arrival is announced exactly once.
    public var arrived: Bool

    public init(stepIndex: Int = 0, stage: GuidanceStage = .none, arrived: Bool = false) {
        self.stepIndex = stepIndex
        self.stage = stage
        self.arrived = arrived
    }
}

/// How far from a step's path still counts as being on it.
///
/// Roughly a carriageway plus GPS error. Wider would match the parallel road; narrower would lose
/// the rider to a bad fix mid-turn.
public let stepMatchCorridorMetres: Double = 35

/// How far *into* a step's path the rider must be before its instruction counts as done.
///
/// The path begins at the junction itself, where every road at the junction is within a few metres
/// of every other — so matching near the start says only "at the junction", not "took the turn".
/// Twenty metres in says the turn was taken.
public let stepEntryMetres: Double = 20

/// A step short enough to be jumped entirely between two one-second fixes.
public let shortStepSkipMetres: Double = 60

/// How far off a path's local direction the travel vector may point and still count as riding it.
///
/// Generous, because junctions bend sharply mid-turn. What it must exclude is the *opposite*
/// vector: a route that goes out and comes back — a U-turn at a roundabout onto the same road —
/// crosses its own geography exactly, and only the direction of travel tells the legs apart. A
/// rider crossing a future step's road the wrong way must not mark it visited.
public let stepDirectionToleranceDegrees: Double = 100

/// How short a run between two manoeuvres counts as "and then".
///
/// At 30 mph, 150 m is about eleven seconds — not enough to hear one instruction, act on it, and
/// then be told the next in time to get into the right lane for it. Below that the two are really
/// one manoeuvre and are spoken as one.
public let chainWithinMetres: Double = 150

/// A spoken gap, rounded the way a person would say it.
///
/// Not the injected distance formatter: that one is for display and gives "0.04 miles" here, which
/// is unreadable aloud. Between two manoeuvres a few dozen metres apart, metres are what a rider
/// can act on.
func formatGap(_ distance: Meters) -> String {
    let metres = distance.rawValue
    if metres < 100 { return "\(Int((metres / 10).rounded()) * 10) metres" }
    return "\(Int((metres / 50).rounded()) * 50) metres"
}

/// The instruction for a step, with the one after it attached when they come too close together.
///
/// "Turn left onto Tennyson Road, then in 60 metres turn right onto West Hill Road" — because
/// being told only the first, in a junction where both happen within seconds, puts a rider in the
/// wrong lane. Only ever two: a third would be a paragraph, and by then the first is done and the
/// next call is due anyway. The banner deliberately keeps showing the immediate next manoeuvre
/// alone, since a glance has to answer one question.
/// Where the clock face earns its breath. The rider's own finding after real junctions: the
/// hour only helps when the roads are in sight — the *now* call, where "3 o'clock" maps onto
/// tarmac. In "in 250 metres, turn right, 3 o'clock" the hour describes a junction not yet
/// visible and just costs words. Roundabouts are the exception both ways: exit-counting fails a
/// helmet at any distance, so they keep the clock always.
public enum ClockStyle: Sendable {
    case always
    case roundaboutsOnly
}

public func chainedInstruction(
    _ steps: [RouteStep], from index: Int, within: Double = chainWithinMetres,
    clock: ClockStyle = .always
) -> String {
    guard let step = steps[safe: index] else { return "" }
    let wantsClock = clock == .always
        || step.instructions.lowercased().contains("roundabout")
    let instruction = wantsClock
        ? clockSuffix(steps, at: index).map { "\(step.instructions), \($0)" } ?? step.instructions
        : step.instructions
    // The gap between this manoeuvre and the next is the *next* step's approach length — its
    // polyline runs from this junction to that one, so no geometry is needed to measure it.
    guard
        let following = steps[safe: index + 1],
        following.distance.rawValue <= within
    else { return instruction }
    let gap = formatGap(following.distance)
    return "\(instruction), then in \(gap) \(lowercasedFirst(following.instructions))"
}

// MARK: - The clock face

/// A turn's angle as an hour on the clock — the eyes-free description of a junction's shape.
///
/// Twelve is straight on, three is a right angle right, nine a right angle left; each hour is
/// thirty degrees. This is the app's whole point spoken aloud: "second exit" is ambiguous on a
/// five-way roundabout, but "two o'clock" is a shape the body understands inside a helmet.
public func clockDirection(incoming: Double, outgoing: Double) -> Int {
    var relative = (outgoing - incoming).truncatingRemainder(dividingBy: 360)
    if relative > 180 { relative -= 360 }
    if relative < -180 { relative += 360 }
    let hour = Int((relative / 30).rounded())
    return hour == 0 ? 12 : hour > 0 ? hour : 12 + hour
}

/// The clock suffix for a manoeuvre, when its geometry can say one.
///
/// The incoming bearing is the end of this step's approach; the outgoing is the start of the
/// *next* step's approach, which begins at this junction. Straight-ish ordinary turns stay
/// unsuffixed — "continue — 12 o'clock" is noise — but anything naming a roundabout or an exit
/// always gets its hour, because that is exactly where exit-counting goes wrong.
public func clockSuffix(_ steps: [RouteStep], at index: Int) -> String? {
    guard
        let hour = manoeuvreClockHour(steps, at: index),
        let step = steps[safe: index]
    else { return nil }
    let names = step.instructions.lowercased()
    let junction = names.contains("roundabout") || names.contains("exit")
    guard junction || abs(hour - 12) >= 1 && hour != 12 else { return nil }
    return "\(hour) o'clock"
}

/// The junction's trusted hour — the number behind both the spoken suffix and the voice's
/// position in space. Corridor bearings, and the instruction's own word outranks the geometry:
/// a "turn right, 11 o'clock" reached a real helmet, born of a step boundary sitting off the
/// physical junction. When the hour lands on the wrong side of the named turn it is wrong by
/// construction and answers `nil` — no suffix, no position, the word stands alone.
public func manoeuvreClockHour(_ steps: [RouteStep], at index: Int) -> Int? {
    guard
        let step = steps[safe: index],
        let next = steps[safe: index + 1],
        let incoming = junctionBearing(step.path, approaching: true),
        let outgoing = junctionBearing(next.path, approaching: false)
    else { return nil }
    let hour = clockDirection(incoming: incoming, outgoing: outgoing)
    let names = step.instructions.lowercased()
    if names.contains("right"), (7...11).contains(hour) { return nil }
    if names.contains("left"), (1...5).contains(hour) { return nil }
    return hour
}

/// A path's bearing where it meets a junction — measured a corridor *away* from the mouth.
///
/// MapKit's step boundaries do not sit exactly on the physical junction: the approach's final
/// metres, and the exit's first, often contain the rounded corner itself — sometimes the whole
/// turn. A bearing taken inside that stretch collapses the angle or flips its sign, which is
/// how a hard right was once spoken as "11 o'clock". So the nearest 12 m to the junction are
/// skipped and the bearing is a chord across the ~28 m beyond them — long enough to smooth
/// corner rounding, short enough to still describe this road and not the next bend. Paths too
/// short to skip anything fall back to the plain first/last-leg reading.
func junctionBearing(_ points: [Coordinate], approaching: Bool) -> Double? {
    let skipMetres = 12.0
    let spanMetres = 28.0
    // Walk outward from the junction end: reversed for an approach (junction is at the END of
    // an approach path), forward for an exit (junction at the start).
    let ordered = approaching ? Array(points.reversed()) : points
    guard let junction = ordered.first else { return nil }

    var cumulative = 0.0
    var near: Coordinate?
    var far: Coordinate?
    var previous = junction
    for point in ordered.dropFirst() {
        cumulative += distanceMetres(
            from: (previous.latitude, previous.longitude),
            to: (point.latitude, point.longitude)
        )
        previous = point
        if near == nil, cumulative >= skipMetres { near = point }
        if cumulative >= skipMetres + spanMetres {
            far = point
            break
        }
    }
    // Too short to skip the mouth: the old reading is the only honest one left.
    guard let near else {
        return approaching
            ? pathBearing(points.suffix(8).map { $0 }, lastLeg: true)
            : pathBearing(Array(points.prefix(8)), lastLeg: false)
    }
    // The far anchor may be the path's end when the road is short; it still spans ≥ the skip.
    let anchor = far ?? previous
    guard distanceMetres(
        from: (near.latitude, near.longitude), to: (anchor.latitude, anchor.longitude)
    ) >= 8 else {
        return approaching
            ? pathBearing(points.suffix(8).map { $0 }, lastLeg: true)
            : pathBearing(Array(points.prefix(8)), lastLeg: false)
    }
    // Travel runs toward the junction on an approach, away from it on an exit.
    return approaching
        ? bearing(from: (anchor.latitude, anchor.longitude), to: (near.latitude, near.longitude))
        : bearing(from: (near.latitude, near.longitude), to: (anchor.latitude, anchor.longitude))
}

/// The bearing of a short run of path — its first or last resolvable leg of at least ten metres.
/// Internal rather than private: the lane advice reads the same geometry to place a roundabout
/// exit on the clock.
func pathBearing(_ points: [Coordinate], lastLeg: Bool) -> Double? {
    let ordered = lastLeg ? points.reversed().map { $0 } : points
    guard let anchor = ordered.first else { return nil }
    for candidate in ordered.dropFirst() {
        let pair = lastLeg ? (candidate, anchor) : (anchor, candidate)
        if distanceMetres(from: (pair.0.latitude, pair.0.longitude),
                          to: (pair.1.latitude, pair.1.longitude)) >= 10 {
            return bearing(from: (pair.0.latitude, pair.0.longitude), to: (pair.1.latitude, pair.1.longitude))
        }
    }
    return nil
}

/// Which lane to be in, when the rule is knowable without lane data.
///
/// One rule qualifies: a motorway exit is a left-hand slip, always. The roundabout after-12
/// heuristic was tried and withdrawn — road markings override the Highway Code's default often
/// enough that the advice was sometimes wrong, and sometimes-wrong advice teaches the rider to
/// ignore the advice that is right. Real lane guidance — "left lane exits, stay in the right
/// two" — needs lane data, which OSM's turn:lanes can supply from our own extract one day.
public func laneHint(_ steps: [RouteStep], at index: Int) -> String? {
    guard let step = steps[safe: index] else { return nil }
    let words = step.instructions.lowercased()
    if words.contains("exit"), !words.contains("roundabout"),
       words.contains("motorway") || words.contains("towards") {
        return "Keep left"
    }
    return nil
}

// MARK: - Choosing where to rejoin

/// One place the original route could be rejoined at, and what it would cost to finish from there.
public struct RejoinCandidate: Sendable, Equatable {
    /// Index into the route's located steps — the manoeuvre being rejoined at.
    public let stepIndex: Int
    public let point: Coordinate
    /// Time from this manoeuvre to the destination **along the original route**.
    ///
    /// Estimated rather than requested: the route already knows its own distance and duration, so
    /// the remaining distance scaled by its average speed costs nothing and needs no network. It is
    /// only ever compared against other candidates on the same route, so a systematic error in the
    /// average cancels out.
    public let remainingTime: TimeInterval
}

/// The next few manoeuvres, each as a place the route could be picked up again.
///
/// Bounded because each candidate costs a routing request. Four covers the realistic cases — a
/// missed turn, a deliberate detour of a junction or two — and Apple throttles well before ten.
public func rejoinCandidates(
    _ route: RouteOption,
    from stepIndex: Int,
    /// Where the rider is, so candidates already behind them can be dropped.
    at position: Coordinate? = nil,
    /// Which way they are going, which is the only usable answer to "is that behind me" once too
    /// far off the route to measure progress along it.
    heading: Course? = nil,
    limit: Int = 4
) -> [RejoinCandidate] {
    let steps = route.steps.filter { $0.start != nil }
    // `stepIndex` can be past the end — guidance runs off the last manoeuvre on the approach to the
    // destination — and `9..<4` is a crash, not an empty range.
    guard
        stepIndex < steps.count, stepIndex >= 0,
        route.travelTime > 0, route.distance.rawValue > 0
    else { return [] }
    let metresPerSecond = route.distance.rawValue / route.travelTime

    // How far along the route the rider has got. A manoeuvre behind that is behind *them*, and
    // rejoining at it means turning round — which is what the rider saw: "turn right onto Luton
    // Road" while joining Church Road, sending them back the way they came. The time comparison was
    // supposed to make a U-turn lose, and cannot when the legs it needs are the ones that fail.
    //
    // `nil` when too far off the route to place, in which case nothing can be ruled out and every
    // candidate stands.
    let progress = position.flatMap { distanceAlongRoute(route.shape, to: $0) }

    return (stepIndex..<min(stepIndex + limit, steps.count)).compactMap { index in
        guard let point = steps[safe: index]?.start else { return nil }
        if
            let progress,
            let junction = distanceAlongRoute(route.shape, to: point),
            junction < progress {
            return nil
        }
        // And when progress cannot be measured — more than a couple of hundred metres off the
        // route, which is exactly when a reroute happens — direction of travel is the only thing
        // left that says what is behind. Without it the rider was sent back down roads they had
        // just ridden, one reroute after another.
        //
        // A wide cone: rejoining legitimately involves turning, and only something genuinely
        // behind the shoulder should be ruled out.
        if
            progress == nil,
            let heading,
            let position,
            distanceMetres(from: position.pair, to: point.pair) > 100 {
            var apart = abs(bearing(from: position.pair, to: point.pair) - heading.rawValue)
                .truncatingRemainder(dividingBy: 360)
            if apart > 180 { apart = 360 - apart }
            if apart > 120 { return nil }
        }
        // Everything still to drive once back on the route at this manoeuvre.
        let remaining = steps.dropFirst(index).reduce(0.0) { $0 + $1.distance.rawValue }
        return RejoinCandidate(
            stepIndex: index,
            point: point,
            remainingTime: remaining / metresPerSecond
        )
    }
}

/// The candidate that gets to the destination soonest.
///
/// The whole point of comparing rather than always taking the first: a rider who *deliberately*
/// went a different way has not made a mistake to be undone. Sending them back to the turn they
/// skipped is a U-turn plus the leg they just rode, and it loses to simply carrying on and picking
/// the route up further along — which is what a rider means when they take a road they prefer.
///
/// `legTimes` is the time from where the rider is now to each candidate, in the same order. `nil`
/// means that leg could not be routed, and the candidate is dropped rather than guessed at.
public func bestRejoin(
    _ candidates: [RejoinCandidate], legTimes: [TimeInterval?]
) -> RejoinCandidate? {
    zip(candidates, legTimes)
        .compactMap { candidate, leg in leg.map { (candidate, $0 + candidate.remainingTime) } }
        .min { $0.1 < $1.1 }?
        .0
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
    let remainingSteps = Array(original.steps.dropFirst(index))
    // **Drop the way-back's last step.** Every route MapKit returns ends by announcing arrival, and
    // the way back was routed to a *rejoin point* — so splicing it whole puts "arrive at the
    // destination" in the middle of the journey. Heard on a replayed ride: "turn left onto Tennyson
    // Road, then in 10 metres arrive at the destination", ten miles from anywhere.
    //
    // Dropping the last one is exact rather than a guess at the wording: the leg's final step is
    // always the arrival at the join, and the join is where the original route's own step takes
    // over.
    let wayBack = rejoin.steps.dropLast()
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
        steps: Array(wayBack) + remainingSteps,
        shape: rejoin.shape + tail
    )
}

// MARK: - Forward bias for replans

/// Metres ahead of the rider a replan's origin is projected — the public routing API cannot be
/// told a heading, but a router asked from a point in front of the bike has already been told
/// which way the bike is going.
public func projectedOrigin(_ position: Coordinate, course: Course?, speed: MPS?) -> Coordinate {
    guard let course else { return position }
    let metres = min(40, max(10, (speed?.rawValue ?? 0) * 1.5))
    return coordinate(from: position, bearing: course.rawValue, metres: metres)
}

/// Seconds of penalty a candidate route pays for opening against the rider's travel.
///
/// This is the difference between Apple's reroute and being summoned back: a route that begins
/// with a U-turn must be *clearly* faster to win, not merely first in the list. Three minutes is
/// roughly what a U-turn, the ridden-back leg and the indignity actually cost.
public func uTurnPenaltySeconds(route: RouteOption, course: Course?) -> TimeInterval {
    guard
        let course,
        let opening = pathBearing(Array(route.shape.prefix(12)), lastLeg: false)
    else { return 0 }
    var apart = abs(opening - course.rawValue).truncatingRemainder(dividingBy: 360)
    if apart > 180 { apart = 360 - apart }
    return apart > 110 ? 180 : 0
}

/// One thing to say, and the guidance state that follows from having said it.
public struct GuidanceUpdate: Sendable, Equatable {
    public let announcement: String?
    /// Where the manoeuvre sits on the clock, for *positioning* the spoken call in space —
    /// carried even when no hour is said aloud: the early call names no hour by design, yet its
    /// voice can still arrive from the turn's own side. `nil` when the geometry is unreadable
    /// or fails the word-versus-hour trust check.
    public let clockHour: Int?
    public let state: GuidanceState

    public init(announcement: String?, clockHour: Int? = nil, state: GuidanceState) {
        self.announcement = announcement
        self.clockHour = clockHour
        self.state = state
    }
}

/// The next manoeuvre, as something to keep on screen.
///
/// Distinct from the spoken calls, which happen twice and then stop: a banner is *always* showing
/// the current answer to "what am I doing next", counting down as the junction approaches. On a
/// bike that is what replaces glancing at a phone.
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

// MARK: - Riding a step's path

/// Where a position falls on a path: how far off it, how far along it, and whether the travel
/// vector agrees with the path's local direction there.
struct PathFix: Equatable {
    let offset: Double
    let along: Double
    let aligned: Bool
}

/// The nearest point of `path` to `position`, measured perpendicular to its segments.
func pathFix(_ path: [Coordinate], at position: Coordinate, heading: Course?) -> PathFix? {
    guard path.count > 1 else { return nil }
    var travelled = 0.0
    var best: PathFix?
    for index in 0..<(path.count - 1) {
        guard let a = path[safe: index], let b = path[safe: index + 1] else { continue }
        let segment = distanceMetres(from: a.pair, to: b.pair)
        let offset = distanceToSegment(position, a, b)
        if best.map({ offset < $0.offset }) ?? true {
            let toStart = distanceMetres(from: position.pair, to: a.pair)
            // `max(0, …)` *before* the square root. At a perpendicular the difference is zero in
            // exact arithmetic and fractionally negative in floating point, and the NaN that falls
            // out of the root defeats `min` — which turned "30 m before the junction" into "a full
            // segment past it" and advanced steps that were never reached.
            let into = min(segment, max(0, toStart * toStart - offset * offset).squareRoot())
            let aligned: Bool
            if let heading, segment > 1 {
                var apart = abs(bearing(from: a.pair, to: b.pair) - heading.rawValue)
                    .truncatingRemainder(dividingBy: 360)
                if apart > 180 { apart = 360 - apart }
                aligned = apart <= stepDirectionToleranceDegrees
            } else {
                // No usable travel vector — stopped, or a degenerate segment. Alignment cannot be
                // judged, and refusing to match would strand a rider who pauses mid-turn.
                aligned = true
            }
            best = PathFix(offset: offset, along: travelled + into, aligned: aligned)
        }
        travelled += segment
    }
    return best
}

/// Whether the rider is on this path, past its first point, going its way.
///
/// The *visited* test for the manoeuvre this path follows: a step's path begins where the previous
/// instruction happens, so being twenty metres into it means that turn was taken. Deterministic,
/// local to one path, immune to how close any other part of the route passes.
func riding(_ path: [Coordinate], at position: Coordinate, heading: Course?) -> Bool {
    guard let fix = pathFix(path, at: position, heading: heading) else { return false }
    return fix.offset <= stepMatchCorridorMetres && fix.aligned && fix.along >= stepEntryMetres
}

/// Metres still to ride before the manoeuvre at `steps[index]`.
///
/// The step's own path *is* the approach, so the remaining length of it is the honest distance —
/// measured along the road, immune to bends. Falls back to the straight line to the manoeuvre
/// point when the rider cannot be placed on the path.
func distanceToManoeuvre(
    _ steps: [RouteStep], index: Int, at position: Coordinate, heading: Course?
) -> Double? {
    guard let step = steps[safe: index] else { return nil }
    if
        step.path.count > 1,
        let fix = pathFix(step.path, at: position, heading: heading),
        fix.offset <= stepMatchCorridorMetres {
        var length = 0.0
        for i in 0..<(step.path.count - 1) {
            guard let a = step.path[safe: i], let b = step.path[safe: i + 1] else { continue }
            length += distanceMetres(from: a.pair, to: b.pair)
        }
        return max(0, length - fix.along)
    }
    guard let start = step.start else { return nil }
    return distanceMetres(from: position.pair, to: start.pair)
}

/// What to display for a fix, independent of what has been said about it.
public func guidanceBanner(
    route: RouteOption, at position: Coordinate, state: GuidanceState,
    formatDistance: (Meters) -> String
) -> GuidanceBanner? {
    guard !state.arrived, let step = route.steps[safe: state.stepIndex] else { return nil }
    guard let remaining = distanceToManoeuvre(
        route.steps, index: state.stepIndex, at: position, heading: nil
    ) else { return nil }
    let metres = Meters(remaining)
    return GuidanceBanner(
        instruction: step.instructions,
        distanceText: formatDistance(metres),
        distance: metres
    )
}

/// Advances guidance for one position fix.
///
/// Pure, and the whole of the turn-by-turn logic. One rule moves the machine forward, and it is
/// the rider's own: an instruction is **visited** only when the rider is demonstrably riding the
/// road it named — on that step's polyline, past the junction mouth, in its direction. Passing in
/// front of a junction without entering it visits nothing. Crossing a future step's road on the
/// other leg of a roundabout visits nothing, because the vector disagrees. And nothing is ever
/// skipped: a manoeuvre that stops matching anything is the reroute machinery's problem, not an
/// index to quietly advance past.
public func guidance(
    route: RouteOption,
    at position: Coordinate,
    speed: MPS,
    heading: Course? = nil,
    state: GuidanceState,
    formatDistance: (Meters) -> String
) -> GuidanceUpdate {
    guard !state.arrived else { return GuidanceUpdate(announcement: nil, state: state) }

    let steps = route.steps
    guard state.stepIndex < steps.count else {
        // Past the last instruction. Arrival is judged against the end of the line, because the
        // last instruction is usually "arrive" at the same place.
        guard let destination = route.shape.last else {
            return GuidanceUpdate(announcement: nil, state: state)
        }
        guard distanceMetres(from: position.pair, to: destination.pair) <= 60 else {
            return GuidanceUpdate(announcement: nil, state: state)
        }
        var next = state
        next.arrived = true
        return GuidanceUpdate(announcement: "You have arrived.", state: next)
    }

    guard let step = steps[safe: state.stepIndex] else {
        return GuidanceUpdate(announcement: nil, state: state)
    }

    var next = state

    // Visited: the road entered by taking this manoeuvre is the *next* step's approach path, which
    // begins exactly at this junction. Twenty metres into it, going its way, and the turn was
    // demonstrably taken. For the final step there is no next path, and arrival below owns it.
    if
        let entered = steps[safe: state.stepIndex + 1],
        riding(entered.path, at: position, heading: heading) {
        next.stepIndex += 1
        next.stage = .none
        return GuidanceUpdate(announcement: nil, state: next)
    }

    // Two manoeuvres close enough to be jumped between two fixes: if the rider is already on the
    // road after the *second*, both were completed — and both were announced together as a chain,
    // so nothing was skipped unheard. Bounded to one extra step, and only a short one; anything
    // more is the reroute machinery's business.
    if
        let between = steps[safe: state.stepIndex + 1],
        between.distance.rawValue <= shortStepSkipMetres,
        let afterBoth = steps[safe: state.stepIndex + 2],
        riding(afterBoth.path, at: position, heading: heading) {
        next.stepIndex += 2
        next.stage = .none
        return GuidanceUpdate(announcement: nil, state: next)
    }

    // The last manoeuvre is arrival itself: no next path can confirm it, so proximity does.
    if
        state.stepIndex == steps.count - 1,
        let destination = step.start ?? route.shape.last,
        distanceMetres(from: position.pair, to: destination.pair) <= 30 {
        next.arrived = true
        return GuidanceUpdate(announcement: "You have arrived.", state: next)
    }

    // Not visited — so the only thing speakable is this instruction (with its successor attached
    // when they come at once). The rider's rule holds structurally: nothing beyond the next
    // unvisited manoeuvre is ever announced on its own.
    guard let remaining = distanceToManoeuvre(
        steps, index: state.stepIndex, at: position, heading: heading
    ) else { return GuidanceUpdate(announcement: nil, state: next) }

    let windows = guidanceDistances(speed: speed)

    if remaining <= windows.imminent.rawValue, state.stage < .imminent {
        next.stage = .imminent
        return GuidanceUpdate(
            announcement: chainedInstruction(steps, from: state.stepIndex),
            clockHour: manoeuvreClockHour(steps, at: state.stepIndex),
            state: next
        )
    }

    if
        remaining <= windows.early.rawValue,
        // Only when the early call still buys anything. Inside about one-and-a-half imminent
        // windows the "now" call is seconds away, and a real ride produced "In 40 m, turn left"
        // followed one second later by "Turn left" - two sentences for one junction, the second
        // interrupting the first's usefulness.
        remaining > windows.imminent.rawValue * 1.5,
        state.stage < .early {
        next.stage = .early
        // Lane advice belongs to the early call: four hundred metres out is when a lane can
        // still be chosen calmly; at the junction mouth it is a demand, not advice.
        let lane = laneHint(steps, at: state.stepIndex).map { ". \($0)" } ?? ""
        return GuidanceUpdate(
            announcement: "In \(formatDistance(Meters(remaining))), "
                + lowercasedFirst(chainedInstruction(
                    steps, from: state.stepIndex, clock: .roundaboutsOnly
                )) + lane,
            // The early call names no hour aloud — the rider's rule — but its voice still
            // arrives from the turn's own side.
            clockHour: manoeuvreClockHour(steps, at: state.stepIndex),
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
        guard let a = shape[safe: index], let b = shape[safe: index + 1] else { continue }
        best = min(best, distanceToSegment(position, a, b))
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
    /// Fixes counted since the request went out.
    ///
    /// A deadline, and not an optional nicety: a request that never answers leaves `isRerouting`
    /// set for ever, and every later decision returns `carryOn` — so one hung call disables
    /// rerouting for the whole journey. Observed doing exactly that, with the off-route counter
    /// climbing past ninety and not a single reroute attempted after the first.
    ///
    /// Counted in fixes rather than seconds because the domain has no clock, and a fix a second is
    /// the only tick it needs.
    public var reroutingFixes: Int
    /// Fixes spent on the route since the last deviation. The forgiveness clock: three quarters
    /// of a minute back on the line and past mistakes stop counting toward the replan threshold —
    /// a rider who deviated twice this morning has not earned a replan for this afternoon's
    /// missed turn.
    public var onRouteFixes: Int
    /// Fixes to wait after a reroute completes before another may start.
    ///
    /// Without it, a rider still off the *new* route — stopped at a light beside it, say — triggers
    /// a fresh reroute every three fixes, each resetting guidance and re-announcing its first
    /// instruction. A real ride produced exactly that: "In 60 m, turn left onto West Hill Road"
    /// five times in fifteen seconds, alternating destinations as near-equal rejoin candidates
    /// flip-flopped. Two minutes of turn-A-turn-B in the rider's helmet.
    public var cooldownFixes: Int

    public init(
        offRouteFixCount: Int = 0,
        deviations: Int = 0,
        isRerouting: Bool = false,
        reroutingFixes: Int = 0,
        cooldownFixes: Int = 0,
        onRouteFixes: Int = 0
    ) {
        self.offRouteFixCount = offRouteFixCount
        self.deviations = deviations
        self.isRerouting = isRerouting
        self.reroutingFixes = reroutingFixes
        self.cooldownFixes = cooldownFixes
        self.onRouteFixes = onRouteFixes
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

/// How long after one reroute before the next may fire. About fifteen seconds at a fix a second —
/// enough to speak the new route's first instruction and for the rider to act on it.
public let rerouteCooldownFixes: Int = 15

public func rerouteDecision(
    distanceOff: Double, state: RerouteState, afterDeviations threshold: Int = 3
) -> RerouteDecision {
    guard !state.isRerouting, state.cooldownFixes == 0 else { return .carryOn }
    guard state.offRouteFixCount >= offRouteFixes else { return .carryOn }
    return state.deviations >= threshold ? .replan : .rejoin
}

/// Advances the off-route counter for one fix.
/// How many fixes a reroute request gets before it is written off.
///
/// About half a minute at one fix a second. Long enough for four concurrent routing requests over a
/// poor connection, short enough that a rider who has gone the wrong way is not abandoned.
public let reroutePatienceFixes: Int = 30

/// How long back on the route before past deviations are forgiven.
public let deviationForgivenessFixes: Int = 45

/// The cooldown after `deviations` reroutes, escalating.
///
/// A rider who keeps not following the routes offered is not going to follow the next one either —
/// ten minutes of a real ride produced a fresh set of instructions every fifteen seconds, twenty
/// spoken sentences about roads the rider never intended to take. Each successive deviation
/// doubles the quiet period, up to two minutes: the reroute still happens, but the machine stops
/// narrating its own persistence.
public func rerouteCooldown(afterDeviations deviations: Int) -> Int {
    min(120, rerouteCooldownFixes << min(3, max(0, deviations - 1)))
}

public func trackingRoute(_ state: RerouteState, distanceOff: Double) -> RerouteState {
    var next = state
    next.offRouteFixCount = distanceOff > offRouteMetres ? state.offRouteFixCount + 1 : 0
    next.cooldownFixes = max(0, state.cooldownFixes - 1)
    if distanceOff <= offRouteMetres {
        next.onRouteFixes = state.onRouteFixes + 1
        if next.onRouteFixes >= deviationForgivenessFixes {
            next.deviations = 0
            next.onRouteFixes = 0
        }
    } else {
        next.onRouteFixes = 0
    }
    guard state.isRerouting else { return next }
    next.reroutingFixes = state.reroutingFixes + 1
    if next.reroutingFixes > reroutePatienceFixes {
        // Written off. Whatever happened to that request, another one is better than none.
        next.isRerouting = false
        next.reroutingFixes = 0
    }
    return next
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
