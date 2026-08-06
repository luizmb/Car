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
    /// Set by ``forceRoadRefresh(box:)``. The next fix restores the distance filter it lifted.
    nonisolated(unsafe) var restoreDistanceAfterNextFix: Double?
    /// Where a forced refresh was last honoured, so a roundabout cannot fire five from one spot.
    nonisolated(unsafe) var lastForcedPosition: (Latitude, Longitude)?
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
func forceRoadRefresh(box: RoadSpeedBox, at position: (Latitude, Longitude)) {
    // Deduped by **place, not by clock**. A one-a-minute limit was tried and is far too blunt: in
    // town the rider changes road every few seconds, and knowing the name and limit of the road just
    // entered is the whole point of acting on the indicator at all.
    //
    // What actually needs suppressing is narrower — a roundabout cancels the indicator several times
    // within seconds *from the same spot*, and those are all the same question. Fifty metres apart is
    // a different junction; fifty metres is not.
    if let last = box.delegate.lastForcedPosition,
       distanceMetres(from: last, to: position) < 50 {
        return
    }
    box.delegate.lastForcedPosition = position
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
    decoder: DataDecoder<OverpassResponse>,
    reverseGeocode: @escaping @Sendable (Latitude, Longitude) -> Publisher<String?, Never>,
    log: @escaping @Sendable (String) -> Void
) -> Publisher<RoadInfo, Never> {
    throttledLocations(box: box)
        .map { location -> Publisher<LocationUpdate, Never> in
            log("road-fetch lat=\(String(format: "%.5f", location.latitude.rawValue))")
            return .just(location)
        }
        .switchToLatest()
        .map(fetchRoadInfo(
            httpClient: httpClient, decoder: decoder,
            reverseGeocode: reverseGeocode, log: log
        ))
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
    decoder: DataDecoder<OverpassResponse>,
    reverseGeocode: @escaping @Sendable (Latitude, Longitude) -> Publisher<String?, Never>,
    log: @escaping @Sendable (String) -> Void
) -> @Sendable (LocationUpdate) -> Publisher<RoadInfo, Never> {
    { location in
        @Sendable func attempt(_ hostIndex: Int) -> Publisher<RoadInfo, Never> {
            httpClient(overpassRequest(
                latitude: location.latitude, longitude: location.longitude, hostIndex: hostIndex
            ))
            .validateStatusCode()
            .decode(using: decoder)
            // Position and course come from the fix that triggered this lookup — the road you were
            // on when it was requested, not wherever you have reached by the time it answers.
            .map { response -> RoadInfo in
                // Which mirror answered, not only which failed. Without it there is no way to tell a
                // working fallback from a primary that never needed one.
                log("road-fetch-ok host\(hostIndex)")
                return parseRoadInfo(
                    response, at: (location.latitude, location.longitude), course: location.course
                )
            }
            // A *different* host on failure, not the same one again. Retrying a server that
            // answered 429 earns another 429; retrying one that refused the connection achieves
            // nothing. The other mirror is very often fine — this afternoon one was down while the
            // other answered in a second.
            //
            // Failures are dropped rather than blanking a good limit, but they are no longer
            // silent: swallowing them identically made "one success then an hour of nothing"
            // indistinguishable between a dead location stream and every request being refused.
            .catch { error in
                // Straight to Apple. Chaining a second Overpass mirror first sounded prudent and
                // cost thirty seconds of silence, because the mirror hung rather than refusing.
                // Apple answers in about a second and knows the street, and a road with no limit is
                // far better than nothing — losing Overpass used to lose both, since both came from
                // the same request.
                log("road-fetch-failed host\(hostIndex) \(String(describing: error).prefix(80))")
                // The next mirror if there is one, then Apple for the name alone.
                guard hostIndex >= OverpassEndpoint.primary.urls.count - 1 else {
                    return attempt(hostIndex + 1)
                }
                log("road-fallback-geocoder")
                return reverseGeocode(location.latitude, location.longitude)
                    .compactMap { name -> RoadInfo? in
                        name.map {
                            RoadInfo(limit: .unknown, ref: nil, name: $0, origin: .unattributed)
                        }
                    }
            }
        }
        return attempt(0)
    }
}
