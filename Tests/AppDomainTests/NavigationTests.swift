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
    @Test("The same route from both requests is offered once")
    func deduplicates() {
        let same = route(name: "A421", miles: 12, minutes: 24)
        #expect(routes(acceptableRoutes([same, same], preferences: .none)).count == 1)
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
            subtitle: "Bedford, MK42",
            latitude: Latitude(52.12), longitude: Longitude(-0.46)
        )
        #expect(suggestion.spoken == "Ampthill Road, Bedford, MK42")
    }

    @Test("A suggestion with no context does not trail a comma")
    func spokenWithoutSubtitle() {
        let suggestion = AddressSuggestion(
            title: "MK42",
            subtitle: "",
            latitude: Latitude(52.12), longitude: Longitude(-0.46)
        )
        #expect(suggestion.spoken == "MK42")
    }

    /// The id has to survive a re-query, since SwiftUI keys the results list on it, and two
    /// different addresses in the same town must not collide.
    @Test("Suggestions at different places have different identities")
    func identity() {
        let a = AddressSuggestion(
            title: "High Street", subtitle: "Bedford",
            latitude: Latitude(52.12), longitude: Longitude(-0.46)
        )
        let b = AddressSuggestion(
            title: "High Street", subtitle: "Bedford",
            latitude: Latitude(52.20), longitude: Longitude(-0.50)
        )
        #expect(a.id != b.id)
    }
}
