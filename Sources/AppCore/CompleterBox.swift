import AppDomain
import CoreLocation
import Foundation
import MapKit

/// `MKLocalSearchCompleter`, wrapped so `World` can expose a closure rather than the object.
///
/// The completer is unavoidably stateful — one long-lived object with a delegate, a mutable
/// `queryFragment`, and results that arrive later — which is the opposite shape from everything else
/// in `World`. It is confined here; everything outside sees
/// `(String, Latitude?, Longitude?) -> Publisher<[AddressSuggestion], Never>`.
///
/// A single shared instance rather than one per query, because that is what the class is for: it
/// keeps a session across keystrokes, which is how it completes "ampt" better than a cold object.
///
/// **Nothing non-`Sendable` leaves this file.** `MKLocalSearchCompletion` is not `Sendable`, so the
/// conversion to ``AddressSuggestion`` happens inside the delegate callback and only the value type
/// crosses the continuation. The completions themselves stay behind, keyed by id, so that the one
/// the rider taps can be resolved from the exact object Apple produced.
final class CompleterBox: NSObject, MKLocalSearchCompleterDelegate, @unchecked Sendable {
    static let shared = CompleterBox()

    private let lock = NSLock()
    /// Touched only on the main actor — `MKLocalSearchCompleter` is a UI-adjacent class that
    /// delivers its results there, and `queryFragment` must be set from the same place.
    @MainActor private let completer = MKLocalSearchCompleter()
    private var pending: CheckedContinuation<[AddressSuggestion], Never>?
    /// The completions last shown, by the id the domain knows them as. A lookup for the current
    /// list, not a cache — replaced wholesale on every update.
    private var shown: [String: MKLocalSearchCompletion] = [:]

    override private init() {
        super.init()
        Task { @MainActor in
            completer.delegate = self
            // Addresses only. `.pointOfInterest` is what turns "Tesco" into fifty shops, and
            // `.query` adds bare search terms that cannot be navigated to at all.
            completer.resultTypes = .address
        }
    }

    func complete(
        _ query: String, latitude: Latitude?, longitude: Longitude?
    ) async -> [AddressSuggestion] {
        await withCheckedContinuation { continuation in
            // A keystroke arriving while the previous one is outstanding abandons it. The completer
            // has a single result set, so the older request can never be answered separately — and
            // a leaked continuation would hang that effect for ever.
            resume(with: [])
            lock.withLock { pending = continuation }

            Task { @MainActor in
                if let latitude, let longitude {
                    // Biases, does not restrict — a search from Bedfordshire still finds a Cornish
                    // postcode, it just offers local matches first.
                    completer.region = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(
                            latitude: latitude.rawValue, longitude: longitude.rawValue
                        ),
                        latitudinalMeters: 200_000,
                        longitudinalMeters: 200_000
                    )
                }
                completer.queryFragment = query
            }
        }
    }

    func completion(for id: String) -> MKLocalSearchCompletion? { lock.withLock { shown[id] } }

    private func resume(with suggestions: [AddressSuggestion]) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<[AddressSuggestion], Never>? in
            defer { pending = nil }
            return pending
        }
        continuation?.resume(returning: suggestions)
    }

    // MARK: MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        lock.withLock {
            shown = Dictionary(
                results.map { ("\($0.title)|\($0.subtitle)", $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        resume(with: results.map { AddressSuggestion(title: $0.title, subtitle: $0.subtitle) })
    }

    /// A failure is an empty list, not an error. The completer fails routinely — on a fragment it
    /// cannot complete, and whenever a request is superseded — and none of that is worth putting in
    /// front of a rider who is simply still typing.
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        resume(with: [])
    }
}
