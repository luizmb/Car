import Foundation
import Testing
@testable import AppDomain

// The rule under test is the one that makes this app's navigation different from every other one:
// "avoid motorways" **hides** routes rather than discouraging them. Apple's `avoid` is only a hint
// and it returns a motorway route anyway when it cannot find another, so if this filter is wrong the
// rider is handed exactly the thing they excluded, looking like an answer.

private func route(
    name: String = "A421",
    miles: Double = 10,
    minutes: Double = 20,
    tolls: Bool = false,
    motorways: Bool = false
) -> RouteOption {
    RouteOption(
        name: name,
        distance: Meters(miles * 1_609.344),
        travelTime: minutes * 60,
        hasTolls: tolls,
        hasMotorways: motorways,
        steps: [],
        shape: []
    )
}

private func routes(_ outcome: RouteSearchOutcome) -> [RouteOption] {
    guard case let .routes(routes) = outcome else { return [] }
    return routes
}

// MARK: - Filtering

@Suite("Route exclusions are exclusions")
struct RouteFilteringTests {
    @Test("A motorway route is dropped, not annotated")
    func dropsMotorways() {
        let outcome = acceptableRoutes(
            [route(name: "M1", motorways: true), route(name: "A421")],
            preferences: RoutePreferences(avoidMotorways: true)
        )
        #expect(routes(outcome).map(\.name) == ["A421"])
    }

    @Test("A toll route is dropped when tolls are excluded")
    func dropsTolls() {
        let outcome = acceptableRoutes(
            [route(name: "Tunnel", tolls: true), route(name: "A421")],
            preferences: RoutePreferences(avoidTolls: true)
        )
        #expect(routes(outcome).map(\.name) == ["A421"])
    }

    /// The case that motivates the whole design. Apple was asked to avoid motorways, ignored it
    /// because there is no other way, and the rider must be told that rather than shown the M1.
    @Test("When every route is excluded, that is said rather than shown as nothing found")
    func excludedIsDistinctFromEmpty() {
        let outcome = acceptableRoutes(
            [route(name: "M1", motorways: true), route(name: "M25", motorways: true)],
            preferences: RoutePreferences(avoidMotorways: true)
        )
        #expect(outcome == .excludedByPreferences(RoutePreferences(avoidMotorways: true)))
        #expect(routes(outcome).isEmpty)
    }

    /// With nothing excluded, an empty result means the routing service genuinely found nothing —
    /// a different fact, and one the rider cannot fix by changing a switch.
    @Test("With no exclusions set, empty means nothing was found")
    func emptyWithoutPreferences() {
        #expect(acceptableRoutes([], preferences: .none) == .routes([]))
    }

    /// A route with a toll is fine when only motorways were excluded. Sounds obvious; a single `||`
    /// in the filter would silently drop it.
    @Test("An exclusion only excludes what it names")
    func exclusionsAreIndependent() {
        let outcome = acceptableRoutes(
            [route(name: "Tunnel", tolls: true)],
            preferences: RoutePreferences(avoidTolls: false, avoidMotorways: true)
        )
        #expect(routes(outcome).map(\.name) == ["Tunnel"])
    }

    @Test("Both exclusions together drop anything carrying either")
    func bothExclusions() {
        let outcome = acceptableRoutes(
            [
                route(name: "M6 Toll", tolls: true, motorways: true),
                route(name: "M1", motorways: true),
                route(name: "Dartford", tolls: true),
                route(name: "A421")
            ],
            preferences: RoutePreferences(avoidTolls: true, avoidMotorways: true)
        )
        #expect(routes(outcome).map(\.name) == ["A421"])
    }
}

// MARK: - Ordering and duplicates

@Suite("What the rider is offered")
struct RouteOfferingTests {
    /// Two requests are issued per search and they overlap heavily, so the same road arrives twice.
    /// Quantised distance and time were tried first and were not enough: Apple returns the same road
    /// from the constrained and unconstrained requests with figures that differ slightly, so the list
    /// showed it twice. Identity is the geometry, which does not drift that way.
    @Test("The same road from both requests is offered once, even with different figures")
    func deduplicates() {
        let shape = (0..<200).map {
            Coordinate(latitude: Latitude(52 + Double($0) / 10_000), longitude: Longitude(-0.46))
        }
        let a = RouteOption(
            name: "A421", distance: Meters(19_312), travelTime: 1_440,
            hasTolls: false, hasMotorways: false, steps: [], shape: shape
        )
        // Same road, figures a little different — which is exactly what was slipping through.
        let b = RouteOption(
            name: "A421", distance: Meters(19_460), travelTime: 1_475,
            hasTolls: false, hasMotorways: false, steps: [], shape: shape
        )
        #expect(routes(acceptableRoutes([a, b], preferences: .none)).count == 1)
    }

    /// The counterpart: identity must not be so coarse that two real alternatives collapse into one,
    /// which would hide the very choice this screen exists to offer.
    @Test("Two genuinely different ways round are both kept")
    func distinctShapes() {
        let north = (0..<200).map {
            Coordinate(latitude: Latitude(52 + Double($0) / 10_000), longitude: Longitude(-0.46))
        }
        let east = (0..<200).map {
            Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46 + Double($0) / 10_000))
        }
        let a = RouteOption(
            name: "A421", distance: Meters(19_000), travelTime: 1_400,
            hasTolls: false, hasMotorways: false, steps: [], shape: north
        )
        let b = RouteOption(
            name: "A6", distance: Meters(19_000), travelTime: 1_400,
            hasTolls: false, hasMotorways: false, steps: [], shape: east
        )
        #expect(routes(acceptableRoutes([a, b], preferences: .none)).count == 2)
    }

    /// Quantised, not exact: the two requests return byte-identical geometry for the same road, and
    /// a route 300 m longer is a genuinely different way round.
    @Test("Routes that differ meaningfully are both offered")
    func keepsDistinctRoutes() {
        let outcome = acceptableRoutes(
            [route(name: "A421", miles: 12, minutes: 24), route(name: "A6", miles: 15, minutes: 30)],
            preferences: .none
        )
        #expect(routes(outcome).count == 2)
    }

    @Test("Fastest first")
    func sortedByTime() {
        let outcome = acceptableRoutes(
            [
                route(name: "Slow", miles: 20, minutes: 50),
                route(name: "Fast", miles: 22, minutes: 30),
                route(name: "Middle", miles: 21, minutes: 40)
            ],
            preferences: .none
        )
        #expect(routes(outcome).map(\.name) == ["Fast", "Middle", "Slow"])
    }

    /// A list of ten routes at a junction is a reading task, not a choice.
    @Test("At most five are offered")
    func capped() {
        let many = (1...9).map { route(name: "R\($0)", miles: Double($0) * 3, minutes: Double($0) * 7) }
        #expect(routes(acceptableRoutes(many, preferences: .none)).count == 5)
    }
}

// MARK: - Drawing

@Suite("Thinning a route for the map")
struct RouteSimplificationTests {
    private func shape(_ count: Int) -> [Coordinate] {
        (0..<count).map {
            Coordinate(
                latitude: Latitude(52 + Double($0) / 100_000),
                longitude: Longitude(-0.5)
            )
        }
    }

    @Test("A route already small enough is untouched")
    func belowCap() {
        let original = shape(50)
        #expect(simplified(original, maxPoints: 2_000) == original)
    }

    @Test("A long route is brought under the cap")
    func thinned() {
        #expect(simplified(shape(40_000), maxPoints: 2_000).count <= 2_000)
    }

    /// Otherwise the line stops short of where the rider is going, which looks like a routing bug
    /// rather than a drawing one.
    @Test("The start and the destination always survive")
    func endpointsKept() {
        let original = shape(40_000)
        let thin = simplified(original, maxPoints: 2_000)
        #expect(thin.first == original.first)
        #expect(thin.last == original.last)
    }

    @Test("An empty or single-point route is handled without thinning")
    func degenerate() {
        #expect(simplified([], maxPoints: 2_000).isEmpty)
        #expect(simplified(shape(1), maxPoints: 2_000).count == 1)
    }

    /// A cap below two cannot keep both endpoints, so it declines to thin rather than returning
    /// something that is not the route.
    @Test("A nonsensical cap leaves the route alone")
    func absurdCap() {
        let original = shape(100)
        #expect(simplified(original, maxPoints: 1) == original)
    }
}

// MARK: - Guidance

@Suite("Turn-by-turn")
struct GuidanceTests {
    private func metres(_ m: Meters) -> String { "\(Int(m.rawValue)) metres" }

    /// A step every ~1.11 km north of 52.0 (0.01° of latitude), which is wide enough that the early
    /// and imminent windows are distinguishable rather than overlapping.
    private func routeWithSteps(_ count: Int) -> RouteOption {
        let steps = (1...count).map { index in
            RouteStep(
                instructions: "Turn left onto Road \(index)",
                distance: Meters(1_000),
                notice: nil,
                start: Coordinate(
                    latitude: Latitude(52.0 + Double(index) / 100),
                    longitude: Longitude(-0.46)
                )
            )
        }
        return RouteOption(
            name: "A421", distance: Meters(5_000), travelTime: 600,
            hasTolls: false, hasMotorways: false, steps: steps,
            shape: [
                Coordinate(latitude: Latitude(52.0), longitude: Longitude(-0.46)),
                Coordinate(latitude: Latitude(52.0 + Double(count) / 100), longitude: Longitude(-0.46))
            ]
        )
    }

    private func at(_ latitude: Double) -> Coordinate {
        Coordinate(latitude: Latitude(latitude), longitude: Longitude(-0.46))
    }

    @Test("Far from the next turn, nothing is said")
    func silentWhenFar() {
        let update = guidance(
            route: routeWithSteps(3), at: at(52.0), speed: MPS(13),
            state: GuidanceState(), formatDistance: metres
        )
        #expect(update.announcement == nil)
        // `closest` tracks on every fix by design, so the step and stage are what "nothing
        // happened" means here.
        #expect(update.state.stepIndex == 0)
        #expect(update.state.stage == .none)
    }

    /// The early call is the one that matters on a bike: a lane change and a gear change both have
    /// to happen before the junction, not at it.
    @Test("Approaching, the turn is given as a warning with the distance")
    func earlyWarning() {
        // ~200 m short of the first step, at 30 mph (early window ≈ 270 m).
        let update = guidance(
            route: routeWithSteps(3), at: at(52.0082), speed: MPS(13.4),
            state: GuidanceState(), formatDistance: metres
        )
        #expect(update.announcement?.hasPrefix("In ") == true)
        #expect(update.announcement?.contains("turn left onto Road 1") == true)
        #expect(update.state.stage == .early)
    }

    /// At one fix a second, repeating inside the window would be unusable in a helmet.
    @Test("The warning is given once, not on every fix inside the window")
    func warningIsGivenOnce() {
        let route = routeWithSteps(3)
        let first = guidance(
            route: route, at: at(52.0082), speed: MPS(13.4),
            state: GuidanceState(), formatDistance: metres
        )
        let second = guidance(
            route: route, at: at(52.0083), speed: MPS(13.4),
            state: first.state, formatDistance: metres
        )
        #expect(first.announcement != nil)
        #expect(second.announcement == nil)
    }

    @Test("At the junction the instruction is given plainly")
    func imminentAnnounces() {
        let update = guidance(
            route: routeWithSteps(3), at: at(52.00973), speed: MPS(13.4),
            state: GuidanceState(stepIndex: 0, stage: .early), formatDistance: metres
        )
        #expect(update.announcement == "Turn left onto Road 1")
        #expect(update.state.stage == .imminent)
        // Still the current step — reaching a junction is not taking it.
        #expect(update.state.stepIndex == 0)
    }

    /// The bug this rule exists for. MapKit's first manoeuvre is routinely a few dozen metres from
    /// where the bike is parked — 24 m in the route that exposed it — so a step consumed by mere
    /// proximity meant pressing GO ate the first turn on the spot, and the first instruction shown
    /// was the *second* turn of the route.
    @Test("A first turn close to the parked bike is not consumed by sitting near it")
    func firstStepSurvivesBeingParked() {
        let route = routeWithSteps(3)
        // 30 m short of the first junction, stationary, as if just parked and pressing GO.
        var state = GuidanceState()
        for _ in 0..<5 {
            let update = guidance(
                route: route, at: at(52.00973), speed: MPS(0),
                state: state, formatDistance: metres
            )
            state = update.state
        }
        #expect(state.stepIndex == 0)
        #expect(guidanceBanner(
            route: route, at: at(52.00973), state: state, formatDistance: metres
        )?.instruction == "Turn left onto Road 1")
    }

    /// The other half: once actually through the junction, the next instruction must arrive.
    @Test("The step advances once the junction is receding")
    func advancesOncePassed() {
        let route = routeWithSteps(3)
        // Reach it…
        let reached = guidance(
            route: route, at: at(52.00995), speed: MPS(13.4),
            state: GuidanceState(), formatDistance: metres
        )
        #expect(reached.state.stage == .imminent)
        #expect(reached.state.stepIndex == 0)

        // …then carry on past it.
        let passed = guidance(
            route: route, at: at(52.0106), speed: MPS(13.4),
            state: reached.state, formatDistance: metres
        )
        #expect(passed.state.stepIndex == 1)
        #expect(passed.state.stage == .none)
    }

    /// Stopped at the junction waiting to turn, GPS wanders. That must not read as having gone
    /// through it and skip to the next instruction.
    @Test("A jittery fix while stopped at the junction does not skip it")
    func jitterDoesNotAdvance() {
        let route = routeWithSteps(3)
        let reached = guidance(
            route: route, at: at(52.00995), speed: MPS(0),
            state: GuidanceState(), formatDistance: metres
        )
        // ~11 m of wander, well inside the 30 m margin.
        let wobbled = guidance(
            route: route, at: at(52.00985), speed: MPS(0),
            state: reached.state, formatDistance: metres
        )
        #expect(wobbled.state.stepIndex == 0)
    }

    /// Steps are followed in order rather than by proximity: a route that doubles back passes close
    /// to a later manoeuvre long before it is due.
    @Test("A later step close by is not announced early")
    func inOrderNotNearest() {
        let route = routeWithSteps(3)
        // Sitting right on step 3, but step 1 is still the one being approached.
        let update = guidance(
            route: route, at: at(52.03), speed: MPS(13.4),
            state: GuidanceState(stepIndex: 0), formatDistance: metres
        )
        #expect(update.announcement != "Turn left onto Road 3")
    }

    @Test("Arrival is announced once, at the end of the line")
    func arrival() {
        let route = routeWithSteps(1)
        let past = GuidanceState(stepIndex: 5)
        let arriving = guidance(
            route: route, at: at(52.01), speed: MPS(5),
            state: past, formatDistance: metres
        )
        #expect(arriving.announcement == "You have arrived.")
        #expect(arriving.state.arrived)

        let again = guidance(
            route: route, at: at(52.01), speed: MPS(5),
            state: arriving.state, formatDistance: metres
        )
        #expect(again.announcement == nil)
    }

    /// 300 m is a comfortable twenty seconds at 30 mph and six at 70, which is why the early window
    /// scales rather than being a constant.
    @Test("The early window grows with speed")
    func windowScalesWithSpeed() {
        #expect(guidanceDistances(speed: MPS(13)).early.rawValue < guidanceDistances(speed: MPS(31)).early.rawValue)
        // Clamped at both ends, so it is neither useless when crawling nor absurd on a motorway.
        #expect(guidanceDistances(speed: MPS(0)).early == Meters(200))
        #expect(guidanceDistances(speed: MPS(100)).early == Meters(800))
        // The "now" call scales too: a fixed 40 m is two seconds at 45 mph, and with a fix a
        // second a fast road can pass clean through the window between two of them.
        #expect(guidanceDistances(speed: MPS(0)).imminent == Meters(40))
        #expect(guidanceDistances(speed: MPS(20)).imminent == Meters(80))
        #expect(guidanceDistances(speed: MPS(100)).imminent == Meters(120))
    }

    @Test("Only the first character is lowercased, so road names survive")
    func sentenceJoining() {
        #expect(lowercasedFirst("Turn left onto A421") == "turn left onto A421")
    }
}

@Suite("The guidance banner")
struct GuidanceBannerTests {
    private func metres(_ m: Meters) -> String { "\(Int(m.rawValue)) m" }

    private var route: RouteOption {
        RouteOption(
            name: "A421", distance: Meters(2_000), travelTime: 300,
            hasTolls: false, hasMotorways: false,
            steps: [
                RouteStep(
                    instructions: "Turn left onto Road 1", distance: Meters(1_000), notice: nil,
                    start: Coordinate(latitude: Latitude(52.01), longitude: Longitude(-0.46))
                )
            ],
            shape: [
                Coordinate(latitude: Latitude(52.0), longitude: Longitude(-0.46)),
                Coordinate(latitude: Latitude(52.01), longitude: Longitude(-0.46))
            ]
        )
    }

    /// Shown continuously, unlike the two spoken calls — it is what replaces glancing at a phone.
    @Test("The banner shows the next turn and counts down")
    func countsDown() {
        let far = guidanceBanner(
            route: route,
            at: Coordinate(latitude: Latitude(52.0), longitude: Longitude(-0.46)),
            state: GuidanceState(), formatDistance: metres
        )
        let near = guidanceBanner(
            route: route,
            at: Coordinate(latitude: Latitude(52.008), longitude: Longitude(-0.46)),
            state: GuidanceState(), formatDistance: metres
        )
        #expect(far?.instruction == "Turn left onto Road 1")
        #expect(far != nil && near != nil && far != near)
    }

    @Test("Once arrived there is nothing left to show")
    func clearedOnArrival() {
        #expect(guidanceBanner(
            route: route,
            at: Coordinate(latitude: Latitude(52.01), longitude: Longitude(-0.46)),
            state: GuidanceState(arrived: true), formatDistance: metres
        ) == nil)
    }

    @Test("Past the last step there is nothing to point at")
    func pastLastStep() {
        #expect(guidanceBanner(
            route: route,
            at: Coordinate(latitude: Latitude(52.01), longitude: Longitude(-0.46)),
            state: GuidanceState(stepIndex: 9), formatDistance: metres
        ) == nil)
    }
}

@Suite("Map orientation while navigating")
struct RouteBearingTests {
    /// A line running due north.
    private var north: [Coordinate] {
        (0..<50).map {
            Coordinate(latitude: Latitude(52 + Double($0) / 1_000), longitude: Longitude(-0.46))
        }
    }

    @Test("The heading follows the route, not the rider")
    func pointsAlongTheRoute() {
        let heading = routeBearing(
            shape: north,
            from: Coordinate(latitude: Latitude(52.0), longitude: Longitude(-0.46))
        )
        #expect(heading != nil)
        // Due north, give or take the projection.
        #expect(abs((heading ?? 0) - 0) < 5 || abs((heading ?? 0) - 360) < 5)
    }

    /// The reason this exists rather than using the GPS course: a rider stopped at the junction they
    /// are about to turn at has no course at all, and would otherwise watch the map swing around
    /// them on every jittery fix.
    @Test("Standing still still gives a heading")
    func stableWhenStopped() {
        let first = routeBearing(
            shape: north,
            from: Coordinate(latitude: Latitude(52.01), longitude: Longitude(-0.46))
        )
        let second = routeBearing(
            shape: north,
            from: Coordinate(latitude: Latitude(52.010001), longitude: Longitude(-0.46))
        )
        #expect(first != nil)
        #expect(second != nil)
        #expect(abs((first ?? 0) - (second ?? 0)) < 1)
    }

    @Test("At the very end there is nowhere further along to look")
    func noneAtTheEnd() {
        #expect(routeBearing(
            shape: north,
            from: Coordinate(latitude: Latitude(52.049), longitude: Longitude(-0.46))
        ) == nil)
    }

    @Test("A route with one point or none has no direction")
    func degenerate() {
        let point = Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46))
        #expect(routeBearing(shape: [], from: point) == nil)
        #expect(routeBearing(shape: [point], from: point) == nil)
    }
}

@Suite("Aiming the camera")
struct CameraOffsetTests {
    /// Centring on the rider wastes half the screen on road already travelled.
    @Test("A point ahead is genuinely ahead")
    func offsetNorth() {
        let here = Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46))
        let ahead = coordinate(from: here, bearing: 0, metres: 111)
        #expect(ahead.latitude.rawValue > here.latitude.rawValue)
        #expect(abs(distanceMetres(from: here.pair, to: ahead.pair) - 111) < 2)
    }

    @Test("East is east, and scaled for the latitude")
    func offsetEast() {
        let here = Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46))
        let ahead = coordinate(from: here, bearing: 90, metres: 111)
        #expect(ahead.longitude.rawValue > here.longitude.rawValue)
        #expect(abs(distanceMetres(from: here.pair, to: ahead.pair) - 111) < 2)
    }
}

@Suite("How far above the road")
struct CameraDistanceTests {
    /// What a rider needs to see is *time* ahead, not distance: 400 m is twelve seconds at 70 mph
    /// and two minutes at walking pace.
    @Test("Faster means further out")
    func scalesWithSpeed() {
        let slow = navigationCameraDistance(speed: MPS(9), nextTurn: nil)
        let fast = navigationCameraDistance(speed: MPS(31), nextTurn: nil)
        #expect(slow < fast)
    }

    @Test("Clamped at both ends")
    func clamped() {
        #expect(navigationCameraDistance(speed: MPS(0), nextTurn: nil) == 280)
        #expect(navigationCameraDistance(speed: MPS(200), nextTurn: nil) == 1_100)
    }

    /// A junction is read from its shape — which lane, which exit — and that is unreadable from
    /// height, so the approach pulls the camera down whatever the speed.
    @Test("A junction ahead pulls the camera down regardless of speed")
    func turnOverridesSpeed() {
        let cruising = navigationCameraDistance(speed: MPS(31), nextTurn: nil)
        let approaching = navigationCameraDistance(speed: MPS(31), nextTurn: Meters(120))
        #expect(approaching < cruising)
        #expect(approaching < 250)
    }

    @Test("The closer the junction, the tighter the view")
    func tightensOnApproach() {
        let far = navigationCameraDistance(speed: MPS(13), nextTurn: Meters(350))
        let near = navigationCameraDistance(speed: MPS(13), nextTurn: Meters(50))
        #expect(near < far)
    }

    /// A turn still miles off must not hold the camera down for the whole ride.
    @Test("A distant turn does not override the speed baseline")
    func distantTurnIgnored() {
        #expect(
            navigationCameraDistance(speed: MPS(31), nextTurn: Meters(5_000))
                == navigationCameraDistance(speed: MPS(31), nextTurn: nil)
        )
    }
}

@Suite("Manoeuvres that come at once")
struct ChainedInstructionTests {
    private func step(_ text: String, runningOn metres: Double) -> RouteStep {
        RouteStep(
            instructions: text, distance: Meters(metres), notice: nil,
            start: Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46))
        )
    }

    /// Being told only the first, where both happen within a few seconds, puts a rider in the wrong
    /// lane for the second.
    @Test("Two turns in quick succession are spoken as one instruction")
    func chainsWhenClose() {
        let steps = [step("Turn left onto Tennyson Road", runningOn: 80), step("Turn right onto London Road", runningOn: 500)]
        // The gap is spoken rather than "immediately". On a residential street with side roads
        // every thirty metres, "then immediately turn right" names the wrong turning — a rider who
        // takes the next right is on the wrong road, which is what happened on a real ride.
        #expect(
            chainedInstruction(steps, from: 0)
                == "Turn left onto Tennyson Road, then in 80 metres turn right onto London Road"
        )
    }

    @Test("A turn with a long run after it stands alone")
    func doesNotChainWhenFar() {
        let steps = [step("Turn left onto Tennyson Road", runningOn: 800), step("Turn right onto London Road", runningOn: 500)]
        #expect(chainedInstruction(steps, from: 0) == "Turn left onto Tennyson Road")
    }

    /// A third would be a paragraph, and by then the first is done and its own call is due.
    @Test("At most two are chained")
    func chainsAtMostTwo() {
        let steps = [
            step("Turn left onto A", runningOn: 40),
            step("Turn right onto B", runningOn: 40),
            step("Turn left onto C", runningOn: 40)
        ]
        let spoken = chainedInstruction(steps, from: 0)
        #expect(spoken.contains("40 metres"))
        #expect(spoken.contains("onto A"))
        #expect(spoken.contains("onto B"))
        #expect(!spoken.contains("onto C"))
    }

    @Test("The last step has nothing to chain to")
    func lastStep() {
        let steps = [step("The destination is on your left", runningOn: 10)]
        #expect(chainedInstruction(steps, from: 0) == "The destination is on your left")
    }

    @Test("An index off the end is empty rather than a crash")
    func outOfRange() {
        #expect(chainedInstruction([], from: 0) == "")
    }

    /// The banner is a glance, and a glance answers one question — so it keeps showing the
    /// immediate next manoeuvre alone even when the spoken call chains two.
    @Test("The banner shows only the immediate next manoeuvre")
    func bannerIsNotChained() {
        let close = Coordinate(latitude: Latitude(52.01), longitude: Longitude(-0.46))
        let route = RouteOption(
            name: "A421", distance: Meters(2_000), travelTime: 300,
            hasTolls: false, hasMotorways: false,
            steps: [
                RouteStep(instructions: "Turn left onto Tennyson Road", distance: Meters(80), notice: nil, start: close),
                RouteStep(instructions: "Turn right onto London Road", distance: Meters(500), notice: nil, start: close)
            ],
            shape: [Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46)), close]
        )
        let banner = guidanceBanner(
            route: route,
            at: Coordinate(latitude: Latitude(52.0), longitude: Longitude(-0.46)),
            state: GuidanceState(), formatDistance: { "\(Int($0.rawValue)) m" }
        )
        #expect(banner?.instruction == "Turn left onto Tennyson Road")
    }
}

@Suite("Leaving the route")
struct OffRouteTests {
    /// A line running due north with vertices 111 m apart — sparse, like a route through open
    /// country, which is where measuring to vertices instead of segments goes wrong.
    private var line: [Coordinate] {
        (0..<10).map {
            Coordinate(latitude: Latitude(52 + Double($0) / 1_000), longitude: Longitude(-0.46))
        }
    }

    @Test("On the line is on the line")
    func onRoute() {
        let on = Coordinate(latitude: Latitude(52.003), longitude: Longitude(-0.46))
        #expect(distanceToRoute(shape: line, from: on) < 1)
    }

    /// The reason this measures to segments rather than vertices: a rider exactly on the road but
    /// halfway between two sparse points would otherwise measure ~55 m off it and be rerouted.
    @Test("Halfway between two distant points is still on the line")
    func betweenVertices() {
        let between = Coordinate(latitude: Latitude(52.0005), longitude: Longitude(-0.46))
        #expect(distanceToRoute(shape: line, from: between) < 5)
    }

    @Test("Genuinely off the line measures as off it")
    func offRoute() {
        // ~200 m east.
        let off = Coordinate(latitude: Latitude(52.003), longitude: Longitude(-0.4571))
        #expect(distanceToRoute(shape: line, from: off) > offRouteMetres)
    }

    /// Longitude degrees are two thirds of latitude degrees here, so treating them alike would make
    /// every east–west road look closer than it is.
    @Test("East and west are scaled for the latitude")
    func longitudeScaled() {
        let eastWest = [
            Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46)),
            Coordinate(latitude: Latitude(52), longitude: Longitude(-0.45))
        ]
        let north = Coordinate(latitude: Latitude(52.0009), longitude: Longitude(-0.455))
        #expect(abs(distanceToRoute(shape: eastWest, from: north) - 100) < 10)
    }
}

@Suite("What to do about it")
struct RerouteDecisionTests {
    @Test("One bad fix is not a wrong turn")
    func needsSeveralFixes() {
        var state = RerouteState()
        state = trackingRoute(state, distanceOff: 200)
        #expect(rerouteDecision(distanceOff: 200, state: state) == .carryOn)
    }

    @Test("Consistently off the line means off the route")
    func triggersAfterEnoughFixes() {
        var state = RerouteState()
        for _ in 0..<offRouteFixes { state = trackingRoute(state, distanceOff: 200) }
        #expect(rerouteDecision(distanceOff: 200, state: state) == .rejoin)
    }

    @Test("Coming back onto the line resets the count")
    func resetsWhenBackOn() {
        var state = RerouteState()
        state = trackingRoute(state, distanceOff: 200)
        state = trackingRoute(state, distanceOff: 200)
        state = trackingRoute(state, distanceOff: 5)
        #expect(state.offRouteFixCount == 0)
    }

    /// A missed turn should not throw away the route the rider chose and send them somewhere else.
    @Test("The first few deviations rejoin the chosen route")
    func rejoinsFirst() {
        var state = RerouteState(deviations: 1)
        for _ in 0..<offRouteFixes { state = trackingRoute(state, distanceOff: 200) }
        #expect(rerouteDecision(distanceOff: 200, state: state) == .rejoin)
    }

    /// A rider who keeps not taking the same turn is being stopped from taking it.
    @Test("Repeated deviations replan instead")
    func replansEventually() {
        var state = RerouteState(deviations: 3)
        for _ in 0..<offRouteFixes { state = trackingRoute(state, distanceOff: 200) }
        #expect(rerouteDecision(distanceOff: 200, state: state) == .replan)
    }

    /// Otherwise every fix while a request is in flight would fire another one.
    @Test("Nothing is asked while a request is already out")
    func noStampede() {
        var state = RerouteState(deviations: 1, isRerouting: true)
        for _ in 0..<offRouteFixes { state = trackingRoute(state, distanceOff: 200) }
        #expect(rerouteDecision(distanceOff: 200, state: state) == .carryOn)
    }

    /// The failure this deadline exists for, seen on a replayed ride: a request went out, never
    /// answered, and `isRerouting` stayed set — so every later decision returned `carryOn` and not
    /// one reroute was attempted for the rest of the journey, with the off-route counter climbing
    /// past ninety.
    @Test("A request that never answers is written off, and another can be made")
    func hungRequestDoesNotDisableRerouting() {
        var state = RerouteState(deviations: 1, isRerouting: true)
        for _ in 0..<(reroutePatienceFixes + 1) {
            state = trackingRoute(state, distanceOff: 200)
        }
        #expect(!state.isRerouting)
        #expect(rerouteDecision(distanceOff: 200, state: state) != .carryOn)
    }

    /// But not so impatient that a slow answer is abandoned mid-flight.
    @Test("A request in flight is left alone until the deadline")
    func patientUntilTheDeadline() {
        var state = RerouteState(deviations: 1, isRerouting: true)
        for _ in 0..<(reroutePatienceFixes - 1) {
            state = trackingRoute(state, distanceOff: 200)
        }
        #expect(state.isRerouting)
    }
}

@Suite("Giving up an exclusion")
struct RelaxationTests {
    /// Motorways go first: a rider already on one cannot be routed off it without using it, and
    /// slip roads are motorway. Tolls are nearly always avoidable, so they go last.
    @Test("Motorways are surrendered before tolls")
    func motorwayFirst() {
        let both = RoutePreferences(avoidTolls: true, avoidMotorways: true)
        let once = relaxed(both)
        #expect(once == RoutePreferences(avoidTolls: true, avoidMotorways: false))
        #expect(relaxed(once ?? .none) == RoutePreferences(avoidTolls: false, avoidMotorways: false))
    }

    @Test("With nothing left to give up there is nothing to relax")
    func nothingLeft() {
        #expect(relaxed(.none) == nil)
    }

    /// A reroute gets a tone, not words — but breaking a rule the rider set is a change to the
    /// terms and does deserve saying.
    @Test("Breaking a rule is announced, and names the rule")
    func announcesWhatItBroke() {
        let chosen = RoutePreferences(avoidTolls: true, avoidMotorways: true)
        #expect(
            exclusionBrokenAnnouncement(
                original: chosen,
                replacement: RoutePreferences(avoidTolls: true, avoidMotorways: false)
            ) == "No way round from here. New route uses a motorway."
        )
        #expect(
            exclusionBrokenAnnouncement(
                original: chosen, replacement: RoutePreferences()
            ) == "No way round from here. New route uses a motorway and tolls."
        )
    }

    @Test("A route that keeps the rules says nothing")
    func silentWhenKept() {
        let chosen = RoutePreferences(avoidTolls: true, avoidMotorways: true)
        #expect(exclusionBrokenAnnouncement(original: chosen, replacement: chosen) == nil)
    }
}

@Suite("Stitching a way back on")
struct SpliceTests {
    private func coordinate(_ latitude: Double) -> Coordinate {
        Coordinate(latitude: Latitude(latitude), longitude: Longitude(-0.46))
    }

    private var original: RouteOption {
        RouteOption(
            name: "A421", distance: Meters(3_000), travelTime: 600,
            hasTolls: false, hasMotorways: false,
            steps: [
                RouteStep(instructions: "Turn left onto A", distance: Meters(500), notice: nil, start: coordinate(52.00)),
                RouteStep(instructions: "Turn right onto B", distance: Meters(500), notice: nil, start: coordinate(52.01)),
                RouteStep(instructions: "Arrive", distance: Meters(200), notice: nil, start: coordinate(52.02))
            ],
            shape: (0..<30).map { coordinate(52.0 + Double($0) / 1_000) }
        )
    }

    private var rejoin: RouteOption {
        RouteOption(
            name: "detour", distance: Meters(400), travelTime: 90,
            hasTolls: false, hasMotorways: true, steps: [
                RouteStep(instructions: "Turn around", distance: Meters(400), notice: nil, start: coordinate(51.99))
            ],
            shape: [coordinate(51.99), coordinate(52.005)]
        )
    }

    /// The point of rejoining: the rest of the ride is still the one the rider picked.
    @Test("The remaining original steps follow the way back")
    func keepsTheRest() {
        let spliced = splice(rejoin: rejoin, onto: original, fromStep: 1)
        #expect(spliced.steps.map(\.instructions) == ["Turn right onto B", "Arrive"])
    }

    /// Every MapKit route ends by announcing arrival, and the way back was routed to a *rejoin
    /// point* — so splicing it whole put "arrive at the destination" in the middle of the journey.
    /// Heard on a replayed ride, ten miles from anywhere.
    @Test("The way back does not announce arriving at the join")
    func dropsTheLegsArrival() {
        let leg = RouteOption(
            name: "detour", distance: Meters(400), travelTime: 90,
            hasTolls: false, hasMotorways: false,
            steps: [
                RouteStep(instructions: "Turn around", distance: Meters(300), notice: nil, start: coordinate(51.99)),
                RouteStep(instructions: "Arrive at the destination", distance: Meters(0), notice: nil, start: coordinate(52.005))
            ],
            shape: [coordinate(51.99), coordinate(52.005)]
        )
        let spliced = splice(rejoin: leg, onto: original, fromStep: 1)
        #expect(!spliced.steps.map(\.instructions).contains("Arrive at the destination"))
        #expect(spliced.steps.map(\.instructions) == ["Turn around", "Turn right onto B", "Arrive"])
    }

    @Test("Distance and time add up")
    func sums() {
        let spliced = splice(rejoin: rejoin, onto: original, fromStep: 1)
        #expect(spliced.distance == Meters(3_400))
        #expect(spliced.travelTime == 690)
    }

    /// A spliced route uses a motorway if any part of it does — otherwise the badge would say it
    /// avoids one while the detour back is a slip road.
    @Test("The exclusions of both halves carry over")
    func exclusionsCombine() {
        #expect(splice(rejoin: rejoin, onto: original, fromStep: 1).hasMotorways)
    }

    @Test("Splicing past the last step keeps just the way back, minus its arrival")
    func pastTheEnd() {
        let spliced = splice(rejoin: rejoin, onto: original, fromStep: 9)
        #expect(spliced.steps.isEmpty)
    }
}

@Suite("A manoeuvre that was missed")
struct SkippedStepTests {
    private func metres(_ m: Meters) -> String { "\(Int(m.rawValue)) m" }

    /// Two turns 1.1 km apart, on a line running north.
    private var route: RouteOption {
        RouteOption(
            name: "A", distance: Meters(5_000), travelTime: 600,
            hasTolls: false, hasMotorways: false,
            steps: [
                RouteStep(instructions: "Turn right onto High Street", distance: Meters(1_100), notice: nil,
                          start: Coordinate(latitude: Latitude(52.01), longitude: Longitude(-0.46))),
                RouteStep(instructions: "Turn left onto Dunstable Road", distance: Meters(1_100), notice: nil,
                          start: Coordinate(latitude: Latitude(52.02), longitude: Longitude(-0.46)))
            ],
            shape: (0..<40).map { Coordinate(latitude: Latitude(52 + Double($0) / 1_000), longitude: Longitude(-0.46)) }
        )
    }

    /// The failure this rule exists for. A junction never come within 40 m of never reaches
    /// `.imminent`, so the "reached and receding" rule can never fire — guidance stuck on "turn
    /// right onto High Street" for sixteen minutes, all the way to the destination.
    @Test("A junction that was never reached does not strand guidance for ever")
    func skippedStepAdvances() {
        // Well past the first turn and closer to the second, having never gone near the first.
        let update = guidance(
            route: route,
            at: Coordinate(latitude: Latitude(52.018), longitude: Longitude(-0.46)),
            speed: MPS(13), state: GuidanceState(), formatDistance: metres
        )
        #expect(update.state.stepIndex == 1)
    }

    /// It must not fire while actually manoeuvring around the junction it is about to take.
    @Test("Approaching the turn normally does not skip it")
    func approachingDoesNotSkip() {
        let update = guidance(
            route: route,
            at: Coordinate(latitude: Latitude(52.008), longitude: Longitude(-0.46)),
            speed: MPS(13), state: GuidanceState(), formatDistance: metres
        )
        #expect(update.state.stepIndex == 0)
    }
}

@Suite("Where to rejoin")
struct RejoinChoiceTests {
    private func coordinate(_ latitude: Double) -> Coordinate {
        Coordinate(latitude: Latitude(latitude), longitude: Longitude(-0.46))
    }

    /// Four manoeuvres a kilometre apart, 4 km and 8 minutes end to end.
    private var route: RouteOption {
        RouteOption(
            name: "A", distance: Meters(4_000), travelTime: 480,
            hasTolls: false, hasMotorways: false,
            steps: [
                RouteStep(instructions: "Left onto A", distance: Meters(1_000), notice: nil, start: coordinate(52.00)),
                RouteStep(instructions: "Right onto B", distance: Meters(1_000), notice: nil, start: coordinate(52.01)),
                RouteStep(instructions: "Right onto High Street", distance: Meters(1_000), notice: nil, start: coordinate(52.02)),
                RouteStep(instructions: "Left onto C", distance: Meters(1_000), notice: nil, start: coordinate(52.03))
            ],
            shape: (0..<40).map { coordinate(52 + Double($0) / 1_000) }
        )
    }

    /// The rider reported being sent back the way they came — "turn right onto Luton Road" while
    /// joining Church Road. A manoeuvre behind them is a U-turn, and the time comparison that was
    /// meant to rule it out cannot when the legs it needs are the ones that fail to route.
    @Test("A manoeuvre already behind is not offered as a rejoin")
    func dropsCandidatesBehind() {
        // Two thirds of the way along, so the first two manoeuvres are behind.
        let here = coordinate(52.025)
        let ahead = rejoinCandidates(route, from: 0, at: here).map(\.stepIndex)
        #expect(!ahead.contains(0))
        #expect(!ahead.contains(1))
        #expect(ahead.contains(3))
    }

    /// Too far off the route to place, and with no heading either, nothing can be ruled out.
    @Test("Far off the route with no heading, every candidate is still offered")
    func keepsAllWhenUnplaceable() {
        let miles = Coordinate(latitude: Latitude(53.5), longitude: Longitude(-2.0))
        #expect(rejoinCandidates(route, from: 0, at: miles).count == 4)
    }

    /// The one that kept happening: too far off the route to measure progress — which is exactly
    /// when a reroute fires — so nothing ruled out the manoeuvres behind, and the rider was sent
    /// back down roads they had just ridden, one reroute after another.
    @Test("Far off the route, a manoeuvre behind the shoulder is still ruled out")
    func headingRulesOutBehind() {
        // Past the end of the route and still heading north: every manoeuvre is due south, so
        // every one of them is behind.
        let past = Coordinate(latitude: Latitude(52.05), longitude: Longitude(-0.46))
        #expect(rejoinCandidates(route, from: 0, at: past, heading: Course(0)).isEmpty)

        // Turn around and they are ahead again.
        let turned = rejoinCandidates(route, from: 0, at: past, heading: Course(180))
        #expect(turned.map(\.stepIndex) == [0, 1, 2, 3])
    }

    @Test("Candidates are the next few manoeuvres, bounded")
    func bounded() {
        #expect(rejoinCandidates(route, from: 0, limit: 4).map(\.stepIndex) == [0, 1, 2, 3])
        #expect(rejoinCandidates(route, from: 2, limit: 4).map(\.stepIndex) == [2, 3])
    }

    /// Rejoining later leaves less of the original still to ride, and the estimate has to reflect
    /// that or every comparison would favour the earliest candidate.
    @Test("Rejoining later leaves less of the route to finish")
    func remainingShrinks() {
        let candidates = rejoinCandidates(route, from: 0)
        #expect(candidates[0].remainingTime > candidates[3].remainingTime)
        // 4 km in 480 s, so the last kilometre is about two minutes.
        #expect(abs(candidates[3].remainingTime - 120) < 1)
    }

    /// The case that motivates all of this: a rider who deliberately took a different road that
    /// converges further along should carry on, not be sent back to the turn they skipped.
    @Test("Carrying on beats a U-turn back to the missed turn")
    func prefersConvergingAhead() {
        let candidates = rejoinCandidates(route, from: 0)
        // Going back to the first manoeuvre is a long way; the last is close ahead.
        let legs: [TimeInterval?] = [400, 300, 200, 60]
        #expect(bestRejoin(candidates, legTimes: legs)?.stepIndex == 3)
    }

    /// And the opposite must still work, or a genuine missed turn would never be corrected.
    @Test("A genuine missed turn still goes back for it")
    func goesBackWhenCloser() {
        let candidates = rejoinCandidates(route, from: 0)
        let legs: [TimeInterval?] = [20, 400, 600, 800]
        #expect(bestRejoin(candidates, legTimes: legs)?.stepIndex == 0)
    }

    @Test("A candidate that could not be routed to is dropped, not guessed at")
    func dropsUnroutable() {
        let candidates = rejoinCandidates(route, from: 0)
        let legs: [TimeInterval?] = [nil, nil, nil, 90]
        #expect(bestRejoin(candidates, legTimes: legs)?.stepIndex == 3)
    }

    @Test("With nothing routable there is no winner")
    func noneRoutable() {
        let candidates = rejoinCandidates(route, from: 0)
        #expect(bestRejoin(candidates, legTimes: [nil, nil, nil, nil]) == nil)
    }

    @Test("Past the last manoeuvre there is nowhere left to rejoin")
    func pastTheEnd() {
        #expect(rejoinCandidates(route, from: 9).isEmpty)
    }

    /// A route with no duration cannot yield an average speed, and dividing by it would be a crash
    /// or an infinity that poisons every comparison.
    @Test("A degenerate route yields no candidates rather than infinities")
    func degenerate() {
        let broken = RouteOption(
            name: "", distance: Meters(0), travelTime: 0,
            hasTolls: false, hasMotorways: false, steps: route.steps, shape: []
        )
        #expect(rejoinCandidates(broken, from: 0).isEmpty)
    }
}

@Suite("A chained pair")
struct ChainedPairTests {
    private func metres(_ m: Meters) -> String { "\(Int(m.rawValue)) m" }

    private func coordinate(_ latitude: Double) -> Coordinate {
        Coordinate(latitude: Latitude(latitude), longitude: Longitude(-0.46))
    }

    private var route: RouteOption {
        RouteOption(
            name: "Markyate St Lane", distance: Meters(5_000), travelTime: 600,
            hasTolls: false, hasMotorways: false,
            steps: [
                RouteStep(instructions: "Turn right onto Markyate St Lane", distance: Meters(44),
                          notice: nil, start: coordinate(52.0100)),
                RouteStep(instructions: "Keep left onto Markyate St Lane", distance: Meters(4_000),
                          notice: nil, start: coordinate(52.0104)),
                RouteStep(instructions: "Turn left onto Hicks Road", distance: Meters(500),
                          notice: nil, start: coordinate(52.0464))
            ],
            shape: (0..<60).map { coordinate(52 + Double($0) / 1_000) }
        )
    }

    @Test("Reaching the first says both")
    func saysBoth() {
        let atFork = guidance(
            route: route, at: coordinate(52.00985), speed: MPS(13),
            state: GuidanceState(), formatDistance: metres
        )
        #expect(atFork.announcement?.contains("Turn right onto Markyate St Lane") == true)
        #expect(atFork.announcement?.contains("keep left onto Markyate St Lane") == true)
    }

    /// Wanted, not a defect: hearing the second again on its own approach is the confirmation that
    /// it is happening *now*, and the rider asked for it explicitly.
    @Test("The second is still announced on its own approach")
    func secondRepeats() {
        let passed = guidance(
            route: route, at: coordinate(52.0106), speed: MPS(13),
            state: GuidanceState(stage: .imminent, closest: 5), formatDistance: metres
        )
        #expect(passed.state.stepIndex == 1)

        let atSecond = guidance(
            route: route, at: coordinate(52.01042), speed: MPS(13),
            state: passed.state, formatDistance: metres
        )
        #expect(atSecond.announcement == "Keep left onto Markyate St Lane")
    }
}

@Suite("A route that passes near itself")
struct RouteSelfProximityTests {
    private func metres(_ m: Meters) -> String { "\(Int(m.rawValue)) m" }

    /// Out and back along the same road, which is what a roundabout is in miniature: the return
    /// leg runs within metres of the outward one.
    private var shape: [Coordinate] {
        let out = (0..<60).map {
            Coordinate(latitude: Latitude(52 + Double($0) / 1_000), longitude: Longitude(-0.4600))
        }
        let back = (0..<60).map {
            Coordinate(latitude: Latitude(52.059 - Double($0) / 1_000), longitude: Longitude(-0.4602))
        }
        return out + back
    }

    /// The failure the rider kept reporting: on the first roundabout, hearing the instruction for
    /// after the second. Searching the whole polyline for the nearest segment has no notion of
    /// continuity, so a rider on the outward leg matches the return leg twenty metres away and
    /// their progress leaps to the far end of the route — skipping every manoeuvre between.
    @Test("Progress does not leap to the return leg")
    func progressStaysOnTheOutwardLeg() {
        let here = Coordinate(latitude: Latitude(52.010), longitude: Longitude(-0.4600))
        // Knowing roughly where the rider was a second ago is what keeps the answer continuous.
        let continuous = distanceAlongRoute(shape, to: here, near: 1_100)
        #expect(continuous != nil)
        #expect(abs((continuous ?? 0) - 1_113) < 120)
    }

    /// And the unconstrained search is shown doing the wrong thing, so the guard is not decoration.
    @Test("Without a window it does leap")
    func unconstrainedLeaps() {
        let here = Coordinate(latitude: Latitude(52.010), longitude: Longitude(-0.4602))
        let global = distanceAlongRoute(shape, to: here, near: nil) ?? 0
        // The return leg reaches this latitude far along the route.
        #expect(global > 5_000)
    }

    /// Guidance carries progress between fixes so the window has something to centre on.
    @Test("Guidance keeps its place across fixes")
    func guidanceCarriesProgress() {
        let route = RouteOption(
            name: "loop", distance: Meters(13_000), travelTime: 900,
            hasTolls: false, hasMotorways: false,
            steps: [
                RouteStep(instructions: "Turn left onto A", distance: Meters(3_000), notice: nil,
                          start: Coordinate(latitude: Latitude(52.030), longitude: Longitude(-0.4600))),
                RouteStep(instructions: "Turn left onto B", distance: Meters(3_000), notice: nil,
                          start: Coordinate(latitude: Latitude(52.050), longitude: Longitude(-0.4600)))
            ],
            shape: shape
        )
        var state = GuidanceState()
        for step in 0..<12 {
            let here = Coordinate(
                latitude: Latitude(52 + Double(step) / 1_000), longitude: Longitude(-0.4600)
            )
            state = guidance(
                route: route, at: here, speed: MPS(13), state: state, formatDistance: metres
            ).state
        }
        // Still approaching the first manoeuvre, not leapt past both by matching the return leg.
        #expect(state.stepIndex == 0)
        #expect((state.progress ?? 0) < 2_000)
    }
}

@Suite("The offset that grew")
struct CompoundingAdvanceTests {
    private func metres(_ m: Meters) -> String { "\(Int(m.rawValue)) m" }
    private func at(_ latitude: Double) -> Coordinate {
        Coordinate(latitude: Latitude(latitude), longitude: Longitude(-0.46))
    }

    /// Four manoeuvres, roughly a kilometre apart, on a straight road.
    private var route: RouteOption {
        RouteOption(
            name: "A", distance: Meters(5_000), travelTime: 600,
            hasTolls: false, hasMotorways: false,
            steps: (1...4).map { index in
                RouteStep(
                    instructions: "Turn onto Road \(index)", distance: Meters(1_100),
                    notice: nil, start: at(52.0 + Double(index) / 100)
                )
            },
            shape: (0..<60).map { at(52.0 + Double($0) / 1_000) }
        )
    }

    /// The rider's own description: "off by one, then two, then three". A constant offset would be
    /// a mapping mistake; a growing one means an *extra* advance per junction. Two rules can
    /// advance the step, and both used to fire for the same one — the receding rule at the
    /// junction, then the missed-junction rule on the very next fix, seeing the new step behind.
    @Test("Riding a straight route advances exactly one step per junction")
    func oneAdvancePerJunction() {
        var state = GuidanceState()
        var announced: [String] = []

        // Ride from the start to just past the third manoeuvre, a fix every ~28 m.
        for tick in 0..<130 {
            let update = guidance(
                route: route, at: at(52.0 + Double(tick) * 0.00025), speed: MPS(13),
                state: state, formatDistance: metres
            )
            if let said = update.announcement { announced.append(said) }
            state = update.state
        }

        // Three junctions passed, so the fourth is current — not the sixth.
        #expect(state.stepIndex == 3)
        // And every manoeuvre ridden through was actually announced, in order.
        #expect(announced.contains { $0.contains("Road 1") })
        #expect(announced.contains { $0.contains("Road 2") })
        #expect(announced.contains { $0.contains("Road 3") })
    }
}

// MARK: - Badges

@Suite("Route labels")
struct RouteBadgeTests {
    private func route(_ name: String, minutes: Double, motorways: Bool = false, tolls: Bool = false) -> RouteOption {
        RouteOption(
            name: name, distance: Meters(10_000), travelTime: minutes * 60,
            hasTolls: tolls, hasMotorways: motorways, steps: [], shape: []
        )
    }

    @Test("The quickest is labelled fastest")
    func fastest() {
        let routes = [route("A", minutes: 20), route("B", minutes: 30)]
        #expect(routeBadge(routes[0], among: routes) == "Fastest")
    }

    /// The label this app exists for: a slower route that keeps you off the motorway is the reason
    /// someone on a carburettor 400 is looking at the list at all.
    @Test("A slower route that avoids motorways says so")
    func avoidsMotorways() {
        let routes = [route("M1", minutes: 17, motorways: true), route("A5", minutes: 20)]
        #expect(routeBadge(routes[1], among: routes) == "Avoids motorways")
    }

    @Test("A route with nothing to distinguish it gets no label")
    func noBadge() {
        let routes = [route("A", minutes: 17), route("B", minutes: 20), route("C", minutes: 25)]
        #expect(routeBadge(routes[1], among: routes) == nil)
    }

    /// Routes between the same two points converge at both ends, so badges pinned to the midpoint
    /// would stack on top of each other and defeat the purpose of drawing them.
    @Test("Badges are spread along the line rather than stacked")
    func anchorsDiffer() {
        let shape = (0..<100).map {
            Coordinate(latitude: Latitude(52 + Double($0) / 1_000), longitude: Longitude(-0.46))
        }
        let r = RouteOption(
            name: "A", distance: Meters(1), travelTime: 1,
            hasTolls: false, hasMotorways: false, steps: [], shape: shape
        )
        #expect(badgeAnchor(r, index: 0, of: 3) != badgeAnchor(r, index: 2, of: 3))
    }

    @Test("A route with no shape has nowhere to hang a badge")
    func noShape() {
        #expect(badgeAnchor(route("A", minutes: 10), index: 0, of: 1) == nil)
    }
}

// MARK: - Wording

@Suite("What navigation says")
struct RouteAnnouncementTests {
    private func distance(_ metres: Meters) -> String { "\(Int(metres.rawValue / 1_609.344)) miles" }
    private func duration(_ seconds: TimeInterval) -> String { "\(Int(seconds / 60)) min" }

    /// Names the exclusion that emptied the list, because the rider's next move depends on which:
    /// a toll is a few pounds, a motorway on this bike is a different question entirely.
    @Test("A blocked route says which exclusion blocked it")
    func namesTheExclusion() {
        #expect(
            noRouteAnnouncement(RoutePreferences(avoidMotorways: true))
                == "No route that avoids motorways."
        )
        #expect(
            noRouteAnnouncement(RoutePreferences(avoidTolls: true))
                == "No route that avoids tolls."
        )
        #expect(
            noRouteAnnouncement(RoutePreferences(avoidTolls: true, avoidMotorways: true))
                == "No route that avoids both motorways and tolls."
        )
        #expect(noRouteAnnouncement(.none) == "No route found.")
    }

    @Test("Choosing a route says where and how long")
    func chosen() {
        let spoken = routeChosenAnnouncement(
            route(miles: 18, minutes: 42),
            to: "Ampthill Road, Bedford",
            formatDistance: distance,
            formatDuration: duration
        )
        #expect(spoken == "Heading to Ampthill Road, Bedford. 42 min, 18 miles.")
    }

    @Test("A route with no name omits the via clause rather than trailing an empty one")
    func summaryWithoutName() {
        let summary = routeSummary(
            route(name: "", miles: 5, minutes: 12),
            formatDistance: distance,
            formatDuration: duration
        )
        #expect(summary == "12 min, 5 miles")
    }

    @Test("A named route is distinguished by its road")
    func summaryWithName() {
        let summary = routeSummary(
            route(name: "A6", miles: 5, minutes: 12),
            formatDistance: distance,
            formatDuration: duration
        )
        #expect(summary == "12 min, 5 miles, via A6")
    }
}

// MARK: - Addresses

@Suite("Address suggestions")
struct AddressSuggestionTests {
    @Test("A suggestion with context reads as one line")
    func spokenWithSubtitle() {
        let suggestion = AddressSuggestion(
            title: "Ampthill Road",
            subtitle: "Bedford, MK42"
        )
        #expect(suggestion.searchText == "Ampthill Road, Bedford, MK42")
    }

    @Test("A suggestion with no context does not trail a comma")
    func spokenWithoutSubtitle() {
        let suggestion = AddressSuggestion(
            title: "MK42",
            subtitle: ""
        )
        #expect(suggestion.searchText == "MK42")
    }

    /// Identity is the text, because a completion *is* text — it carries no coordinates at all
    /// until it is resolved, and the id has to be stable across a re-query since SwiftUI keys the
    /// results list on it. Resolving must therefore not change which row it is.
    @Test("Resolving a suggestion does not change its identity")
    func identitySurvivesResolution() {
        let unresolved = AddressSuggestion(title: "High Street", subtitle: "Bedford")
        let resolved = AddressSuggestion(
            title: "High Street", subtitle: "Bedford",
            latitude: Latitude(52.12), longitude: Longitude(-0.46)
        )
        #expect(unresolved.id == resolved.id)
        #expect(unresolved.coordinate == nil)
        #expect(resolved.coordinate != nil)
    }

    @Test("Different streets are different rows")
    func distinctStreets() {
        #expect(
            AddressSuggestion(title: "High Street", subtitle: "Bedford").id
                != AddressSuggestion(title: "High Street", subtitle: "Luton").id
        )
    }
}
