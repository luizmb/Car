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
        #expect(update.state == GuidanceState())
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

    @Test("At the junction the instruction is given plainly and the next step becomes current")
    func imminentAdvances() {
        let update = guidance(
            route: routeWithSteps(3), at: at(52.00973), speed: MPS(13.4),
            state: GuidanceState(stepIndex: 0, stage: .early), formatDistance: metres
        )
        #expect(update.announcement == "Turn left onto Road 1")
        #expect(update.state.stepIndex == 1)
        #expect(update.state.stage == .none)
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
