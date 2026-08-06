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

    /// Addresses and postcodes near a position.
    ///
    /// `resultTypes = .address` is the whole reason this is a search rather than a completer:
    /// points of interest are excluded at the source, so "Tesco" returns the streets it matched and
    /// not fifty shops. A rider at a junction is not going to scroll a list.
    ///
    /// The region biases rather than restricts — a search from Bedfordshire still finds a Cornish
    /// postcode, it just offers local matches first, which is right far more often than not.
    static let searchAddresses: @Sendable (String, Latitude?, Longitude?)
        -> Publisher<[AddressSuggestion], Never> = { query, latitude, longitude in
        Publisher { continuation in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continuation.yield([])
                return
            }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            request.resultTypes = .address
            if let latitude, let longitude {
                // 100 km or so. Wide enough that the whole of a day's riding is "local", narrow
                // enough that it actually orders the results.
                request.region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: latitude.rawValue, longitude: longitude.rawValue
                    ),
                    latitudinalMeters: 200_000,
                    longitudinalMeters: 200_000
                )
            }

            let response = try? await MKLocalSearch(request: request).start()
            continuation.yield((response?.mapItems ?? []).compactMap(suggestion))
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

private func suggestion(_ item: MKMapItem) -> AddressSuggestion? {
    let placemark = item.placemark
    let coordinate = placemark.coordinate
    guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

    // `name` is the street line for an address result; the title falls back to the thoroughfare so
    // a bare postcode search still says something useful rather than showing an empty row.
    let title = item.name ?? placemark.thoroughfare ?? placemark.postalCode ?? "Unknown"
    return AddressSuggestion(
        title: title,
        subtitle: contextLine(placemark, excluding: title),
        latitude: Latitude(coordinate.latitude),
        longitude: Longitude(coordinate.longitude)
    )
}

/// Town, county and postcode, minus whatever the title already said.
///
/// Without the exclusion the common case reads "Bedford Road, Bedford Road, Bedford, MK40" — the
/// street appears twice because `name` and `thoroughfare` are usually the same string.
private func contextLine(_ placemark: MKPlacemark, excluding title: String) -> String {
    [placemark.locality, placemark.administrativeArea, placemark.postalCode]
        .compactMap { $0 }
        .filter { $0 != title }
        .joined(separator: ", ")
}

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
            .map {
                RouteStep(
                    instructions: $0.instructions,
                    distance: Meters($0.distance),
                    notice: $0.notice
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
