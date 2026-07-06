import Core
import ReactiveConcurrency
import CoreLocation
import AppDomain
import FP
import Foundation
import NetworkClient

// MARK: - Road speed location box

// Created synchronously in World.live() — same pattern as LocationBox —
// so that allowsBackgroundLocationUpdates = true is set on the main thread
// during app initialisation, not inside an async Task (which crashes on iOS 26).
final class RoadSpeedBox: @unchecked Sendable {
    nonisolated(unsafe) let manager: CLLocationManager
    nonisolated(unsafe) let delegate: RoadSpeedLocationDelegate

    init(minDistance: Meters, minTime: TimeInterval) {
        let m = CLLocationManager()
        m.desiredAccuracy                    = kCLLocationAccuracyHundredMeters
        m.distanceFilter                     = minDistance.rawValue
        m.allowsBackgroundLocationUpdates    = true
        m.pausesLocationUpdatesAutomatically = false
        manager  = m
        delegate = RoadSpeedLocationDelegate(minTime: minTime)
    }
}

// MARK: - Location delegate

final class RoadSpeedLocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    nonisolated(unsafe) var continuation: AsyncStream<LocationUpdate>.Continuation?
    nonisolated(unsafe) var lastUpdateTime: Date = .distantPast
    private let minTime: TimeInterval

    init(minTime: TimeInterval) { self.minTime = minTime }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            lastUpdateTime = .distantPast   // ensures first fix triggers a fetch
            manager.startUpdatingLocation()
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard
            let location = locations.last,
            Date().timeIntervalSince(lastUpdateTime) >= minTime
        else { return }
        lastUpdateTime = Date()
        continuation?.yield(LocationUpdate(location))
    }
}

// MARK: - DeferredTask stream helpers

extension DeferredTask {
    /// Yields the success value, or `fallback` on any failure — never silently discards.
    func asStreamWithFallback<S, E>(_ fallback: S) -> DeferredStream<S> where Success == Result<S, E> {
        DeferredStream {
            AsyncStream<S> { continuation in
                Task {
                    switch await self.run() {
                    case .success(let value): continuation.yield(value)
                    case .failure:            continuation.yield(fallback)
                    }
                    continuation.finish()
                }
            }
        }
    }
}

// MARK: - Road speed stream builder

/// Builds a `DeferredStream<RoadInfo>` driven by the pre-created `RoadSpeedBox`.
/// The manager is already configured with background updates; this function only
/// wires the continuation and starts delivery.
func makeRoadSpeedStream(
    box: RoadSpeedBox,
    taskRequester: TaskRequester,
    decoder: DataDecoder<OverpassResponse>
) -> Publisher<RoadInfo, Never> {
    let (locStream, locContinuation) = AsyncStream<LocationUpdate>.makeStream()

    Task { @MainActor in
        box.delegate.continuation   = locContinuation
        box.delegate.lastUpdateTime = .distantPast
        box.manager.delegate        = box.delegate
        // Explicitly start if already authorized — startUpdatingLocation is idempotent
        // so calling it here and again from locationManagerDidChangeAuthorization is safe.
        let status = box.manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            box.manager.startUpdatingLocation()
        }
        locContinuation.onTermination = { [box] _ in
            box.manager.stopUpdatingLocation()
            box.manager.delegate = nil
        }
    }

    let fetch: @Sendable (LocationUpdate) -> Publisher<RoadInfo, Never> = { location in
        let request = overpassRequest(latitude: location.latitude, longitude: location.longitude)
        return taskRequester
            .validateStatusCode()
            .decode(using: decoder)
            .mapT(parseRoadInfo)
            .callAsFunction(request)
            .replaceError(with: .unknown)
    }

    return locStream.eraseToPublisher().flatMap(fetch)
}
