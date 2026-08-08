import AppDomain
import CoreLocation
import Foundation
import MapKit
import ReactiveConcurrency

/// Address search and routing, wrapped so `World` exposes closures rather than MapKit objects.
///
/// MapKit rather than a self-hosted router, and that is a decision with a real trade-off. GraphHopper
/// or Valhalla would give genuine motorcycle profiles — avoid narrow lanes, prefer sweeping bends —
/// which is the thing a rider actually wants and which no consumer navigation app offers. Both need
/// 4–8 GB of RAM to serve England, so both need a server, and a server is a thing to run and pay for
/// and keep alive. MapKit needs none of that, ships today, and already knows about tolls and
/// motorways well enough to be *checked* rather than trusted. The custom-profile version is a
/// separate project, not a blocked one.
///
/// Everything here is `@Sendable` closures over one-shot requests. No shared `MKDirections`, no
/// delegate state: each search builds what it needs and lets it go.
enum RoutingClient {

    // MARK: Address search

    /// Address and postcode completions for what has been typed so far.
    ///
    /// `MKLocalSearchCompleter`, not `MKLocalSearch`. The difference is the whole reason search felt
    /// broken: a full search *resolves* a query and returns the handful of places it is confident
    /// about — type a street name and you get one result. The completer is what Apple Maps' own
    /// suggestion list uses, and returns every address it can complete the fragment to.
    ///
    /// Completions carry **no coordinates** — see ``AddressSuggestion``. Resolving happens once, for
    /// the one the rider picks, via ``resolve``.
    static let completeAddress: @Sendable (String, Latitude?, Longitude?)
        -> Publisher<[AddressSuggestion], Never> = { query, latitude, longitude in
        Publisher { continuation in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else {
                continuation.yield([])
                return
            }
            continuation.yield(
                await CompleterBox.shared.complete(trimmed, latitude: latitude, longitude: longitude)
            )
        }
    }

    /// Turns a chosen completion into a position.
    ///
    /// Uses the original `MKLocalSearchCompletion` when the box still holds it, which is the exact
    /// thing the rider tapped. Falls back to a natural-language search on the same text — a second
    /// best that still lands on the right street, and covers the case where the suggestion outlived
    /// the completer's result set.
    static let resolve: @Sendable (AddressSuggestion) -> Publisher<AddressSuggestion?, Never> = {
        suggestion in
        Publisher { continuation in
            let request: MKLocalSearch.Request
            if let completion = await CompleterBox.shared.completion(for: suggestion.id) {
                request = MKLocalSearch.Request(completion: completion)
            } else {
                request = MKLocalSearch.Request()
                request.naturalLanguageQuery = suggestion.searchText
                request.resultTypes = .address
            }
            let response = try? await MKLocalSearch(request: request).start()
            guard
                let placemark = response?.mapItems.first?.placemark,
                CLLocationCoordinate2DIsValid(placemark.coordinate)
            else {
                continuation.yield(nil)
                return
            }
            continuation.yield(AddressSuggestion(
                title: suggestion.title,
                subtitle: suggestion.subtitle,
                latitude: Latitude(placemark.coordinate.latitude),
                longitude: Longitude(placemark.coordinate.longitude)
            ))
        }
    }

    // MARK: Routing

    /// Every route worth considering between two points, **unfiltered**.
    ///
    /// Two requests, deliberately. The first asks Apple to honour the exclusions, which is what its
    /// routing server is best placed to do. The second asks for anything at all — because
    /// `requestsAlternateRoutes` returns at most about three, and an unconstrained alternate quite
    /// often happens to avoid motorways anyway, so the union yields more usable options than either
    /// request alone. Both are needed to have a realistic chance of the three-to-five the rider
    /// asked for.
    ///
    /// Filtering is **not** done here. This returns what was found and `acceptableRoutes` decides,
    /// so the rule about what is acceptable lives in the domain with a test around it rather than
    /// inside a MapKit callback.
    static let routes: @Sendable (Coordinate, Coordinate, RoutePreferences)
        -> Publisher<Result<[RouteOption], RouteError>, Never> = { from, to, preferences in
        Publisher { continuation in
            // With nothing excluded the two requests are the same request, and issuing it twice
            // would double the pressure on a service that answers `loadingThrottled` for exactly
            // that — to union a set with itself.
            guard preferences != .none else {
                continuation.yield(await fetch(from: from, to: to, preferences: .none))
                return
            }

            async let constrained = fetch(from: from, to: to, preferences: preferences)
            async let unconstrained = fetch(from: from, to: to, preferences: .none)
            let (a, b) = await (constrained, unconstrained)

            // A failure only counts if *both* failed. One of the two coming back empty is ordinary
            // — asking to avoid motorways between two points either side of a motorway simply has
            // no answer, and that must not read as an outage.
            switch (a, b) {
            case let (.failure(error), .failure(_)):
                continuation.yield(.failure(error))
            default:
                continuation.yield(.success(((try? a.get()) ?? []) + ((try? b.get()) ?? [])))
            }
        }
    }

    private static func fetch(
        from: Coordinate, to: Coordinate, preferences: RoutePreferences
    ) async -> Result<[RouteOption], RouteError> {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.clCoordinate))
        // Vehicle only. Not a limitation to lift later — this app is strapped to a motorcycle, and
        // a walking route would be actively dangerous to follow on one.
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.tollPreference = preferences.avoidTolls ? .avoid : .any
        request.highwayPreference = preferences.avoidMotorways ? .avoid : .any

        do {
            let response = try await MKDirections(request: request).calculate()
            return .success(response.routes.map(option))
        } catch {
            return .failure(describe(error))
        }
    }

    /// MapKit's errors as domain ones.
    ///
    /// Mapped to cases rather than to sentences, so the wording stays in the domain and the
    /// distinctions survive: `.directionsNotFound` is a fact about the journey, `.loadingThrottled`
    /// is a reason to try again shortly, and a screen that only had a string could not tell them
    /// apart. `MKError` itself stops here — it is Apple's type and has no business past this file.
    private static func describe(_ error: any Error) -> RouteError {
        guard let mapError = error as? MKError else { return .other(error.localizedDescription) }
        switch mapError.code {
        case .placemarkNotFound: return .placeNotFound
        case .directionsNotFound: return .noRoute
        case .loadingThrottled: return .throttled
        case .serverFailure: return .serviceUnavailable
        default: return .other(error.localizedDescription)
        }
    }
}

// MARK: - MapKit to domain

private func option(_ route: MKRoute) -> RouteOption {
    RouteOption(
        name: route.name,
        distance: Meters(route.distance),
        travelTime: route.expectedTravelTime,
        hasTolls: route.hasTolls,
        hasMotorways: route.hasHighways,
        steps: route.steps
            // MapKit's first step is always a zero-distance "Proceed to …", which is not a turn and
            // reads as noise at the top of the list.
            .filter { !$0.instructions.isEmpty }
            .map { step -> RouteStep in
                // The step's own polyline, kept whole. It is the **approach**: it leads up to the
                // manoeuvre, and the instruction applies at its END. Settled empirically, not from
                // the docs — the rider measured Newlands Road at 1.1 km and the "Turn right onto
                // Church Road" step's polyline is 1,022 m (the length of Newlands, not of Church),
                // and the final "destination is on your left" step carries a 292 m polyline, which
                // is meaningless as road-after-arrival and exact as the final approach. Reading it
                // the other way keyed every announcement one junction early.
                let path = simplified(step.polyline.coordinates, maxPoints: 150)
                return RouteStep(
                    instructions: step.instructions,
                    distance: Meters(step.distance),
                    notice: step.notice,
                    // The manoeuvre point — where the instruction happens.
                    start: path.last,
                    path: path
                )
            },
        shape: route.polyline.coordinates
    )
}

private extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude.rawValue, longitude: longitude.rawValue)
    }
}

private extension MKPolyline {
    /// The polyline's points, copied out into domain coordinates.
    ///
    /// `getCoordinates(_:range:)` rather than the deprecated direct buffer access, and the array is
    /// sized up front because `pointCount` is known — a motorway route across England is tens of
    /// thousands of points and growing an array into that is measurable.
    var coordinates: [Coordinate] {
        guard pointCount > 0 else { return [] }
        var points = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: pointCount
        )
        getCoordinates(&points, range: NSRange(location: 0, length: pointCount))
        return points.map {
            Coordinate(latitude: Latitude($0.latitude), longitude: Longitude($0.longitude))
        }
    }
}
