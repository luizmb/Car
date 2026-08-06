import AppDomain
import CoreLocation
import Foundation
import ReactiveConcurrency

/// Apple's reverse geocoder, wrapped so `World` can expose a primitive closure rather than the
/// object — `CLGeocoder` is not `Sendable` and has no business past the boundary.
///
/// Only ever asked once Overpass has failed. Apple rate-limits geocoding per app, and asking on
/// every fix would earn a throttle of its own — trading one unavailable service for another.
enum GeocoderBox {
    /// The street at a position, or `nil`.
    ///
    /// A fresh `CLGeocoder` per lookup rather than a shared one: the class is not `Sendable`, it
    /// cancels any request in flight when a new one starts on the same instance, and at this
    /// cadence — only after Overpass has already failed — there is nothing to reuse it for.
    ///
    /// `thoroughfare` specifically. Falling back to the locality would announce the *town*, which
    /// answers a question nobody asked and would sound like the app knew the road when it did not.
    static let streetName: @Sendable (Latitude, Longitude) -> Publisher<String?, Never> = {
        latitude, longitude in
        Publisher { continuation in
            let location = CLLocation(latitude: latitude.rawValue, longitude: longitude.rawValue)
            let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
            continuation.yield(placemarks?.first?.thoroughfare)
        }
    }
}
