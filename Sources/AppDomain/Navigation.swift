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
    /// Composed from the text rather than from anything Apple supplies, because `MKMapItem` carries
    /// no stable identifier across searches and SwiftUI needs one that survives a re-query.
    public var id: String { "\(title)|\(subtitle)|\(latitude.rawValue),\(longitude.rawValue)" }
    /// The headline — usually the street line.
    public let title: String
    /// Town, county, postcode. Empty when the search matched something with no further context.
    public let subtitle: String
    public let latitude: Latitude
    public let longitude: Longitude

    public init(title: String, subtitle: String, latitude: Latitude, longitude: Longitude) {
        self.title = title
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
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

    public init(instructions: String, distance: Meters, notice: String?) {
        self.instructions = instructions
        self.distance = distance
        self.notice = notice
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

    /// Distance and time, quantised.
    ///
    /// Two requests are issued per search — one asking for the exclusions, one unconstrained — and
    /// the same road very often comes back from both. Comparing whole polylines would be exact and
    /// pointless: the routes are identical to the metre when they are the same route, so 100 m and
    /// 30 s is enough to recognise a duplicate without ever merging two genuinely different ways
    /// round.
    var signature: String {
        "\(Int(distance.rawValue / 100))|\(Int(travelTime / 30))"
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
