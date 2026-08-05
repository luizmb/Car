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
    let delegate: RoadSpeedLocationDelegate

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
    /// Set by ``forceRefresh(box:)``. The next fix restores the distance filter it lifted.
    nonisolated(unsafe) var restoreDistanceAfterNextFix: Double?
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
        // A forced refresh lifted the distance filter to get this one fix promptly; put it back so
        // the next lookup is throttled normally again.
        if let distance = restoreDistanceAfterNextFix {
            manager.distanceFilter = distance
            restoreDistanceAfterNextFix = nil
        }
        continuation?.yield(LocationUpdate(location))
    }
}

// MARK: - Forced refresh

/// Brings the next Overpass lookup forward to the next GPS fix, about a second away.
///
/// Needed because completing a turn is a *semantic* road change that the throttle cannot see. The
/// throttle is a 300 m distance filter plus a 20 s gate — sensible for riding straight, useless at a
/// junction, where it means the new road is not fetched until 300 m later. At 20 mph that is
/// thirty-three seconds of announcing nothing while sitting on a road whose limit may have changed.
///
/// Both gates are lifted rather than one: clearing `lastUpdateTime` alone achieves nothing, because
/// no fix is delivered at all until the distance filter is satisfied.
///
/// `requestLocation()` is deliberately not used — it is documented as incompatible with an active
/// `startUpdatingLocation`, which this manager relies on.
func forceRoadRefresh(box: RoadSpeedBox) {
    box.delegate.lastUpdateTime = .distantPast
    if box.delegate.restoreDistanceAfterNextFix == nil {
        box.delegate.restoreDistanceAfterNextFix = box.manager.distanceFilter
    }
    box.manager.distanceFilter = kCLDistanceFilterNone
}

// MARK: - Road speed stream builder

/// Builds a **cold** `Publisher<RoadInfo, Never>` driven by the pre-created `RoadSpeedBox`.
///
/// Coldness is the whole point. The store reconciles supervision after *every* state change — i.e.
/// after every GPS fix, several times a minute — and each reconciliation calls this function again to
/// describe the channel set. Anything performed eagerly here would therefore be re-performed on that
/// cadence: re-pointing the delegate at a continuation nobody consumes, and tearing the manager down
/// through the discarded stream's `onTermination`. Every side-effect consequently lives inside
/// `Publisher { … }`, whose body runs only when a subscriber actually attaches.
///
/// `switchToLatest` rather than `flatMap`: only the newest fix's road matters, so an in-flight fetch
/// for a location already left behind is cancelled instead of racing the current one.
func makeRoadSpeedStream(
    box: RoadSpeedBox,
    httpClient: HTTPClient,
    decoder: DataDecoder<OverpassResponse>
) -> Publisher<RoadInfo, Never> {
    throttledLocations(box: box)
        .map(fetchRoadInfo(httpClient: httpClient, decoder: decoder))
        .switchToLatest()
}

// MARK: - Location source

/// The throttled fixes that trigger an Overpass lookup, as a cold publisher. The manager is wired on
/// subscribe and torn down when the subscription ends, so the delegate's continuation always points at
/// the stream someone is actually reading.
///
/// Shared with the camera fetcher, which wants the same behaviour on a much coarser throttle — the
/// box carries the distance and time gates, so one function serves both.
func throttledLocations(box: RoadSpeedBox) -> Publisher<LocationUpdate, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<LocationUpdate>.makeStream()

        await MainActor.run {
            box.delegate.continuation   = streamContinuation
            box.delegate.lastUpdateTime = .distantPast   // ensures the first fix triggers a fetch
            box.manager.delegate        = box.delegate
            // Explicitly start if already authorized — startUpdatingLocation is idempotent, so calling
            // it here and again from locationManagerDidChangeAuthorization is safe.
            let status = box.manager.authorizationStatus
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                box.manager.startUpdatingLocation()
            }
        }

        await continuation.yieldAll(stream)   // parks here until cancelled

        await MainActor.run {
            box.manager.stopUpdatingLocation()
            box.manager.delegate      = nil
            box.delegate.continuation = nil
        }
    }
}

// MARK: - Overpass lookup

/// One Overpass lookup for a fix.
///
/// Transient failure **drops the event** rather than emitting `.unknown`: the public Overpass endpoint
/// answers 504 ("server too busy") often enough that replacing errors with `.unknown` would blank a
/// perfectly good speed limit mid-ride and re-announce the road once it came back. Emitting nothing
/// leaves the last known road standing, which is both quieter and more accurate.
private func fetchRoadInfo(
    httpClient: HTTPClient,
    decoder: DataDecoder<OverpassResponse>
) -> @Sendable (LocationUpdate) -> Publisher<RoadInfo, Never> {
    { location in
        httpClient(overpassRequest(latitude: location.latitude, longitude: location.longitude))
            .validateStatusCode()
            .decode(using: decoder)
            // Position and course come from the fix that triggered this lookup — the road you were
            // on when it was requested, not wherever you have reached by the time it answers.
            .map { parseRoadInfo($0, at: (location.latitude, location.longitude), course: location.course) }
            .retry(2)
            .catch { _ in Publisher<RoadInfo, Never>.empty() }
    }
}
