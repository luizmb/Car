import AppDomain
import Core
import FP
import Foundation
import NetworkClient
import ReactiveConcurrency

/// Enforcement cameras around you, as a **cold** publisher.
///
/// The requirements are the opposite of the road-limit lookup, which is why this is a separate
/// stream rather than another field on the same query:
///
/// | | radius | cadence | must be |
/// |---|---|---|---|
/// | road limit | 40 m | every 300 m / 20 s | current |
/// | cameras | ~3 km | every 1 km / 2 min | *complete* |
///
/// So cameras are fetched rarely over a wide area and held in state, and the "is one ahead of me"
/// test then runs on every GPS fix with no network at all. A camera a kilometre away does not stop
/// being there because the last fetch failed.
///
/// Kept separate from the road query for a second reason: a camera fetch failing must never cost you
/// the speed limit, and the speed limit is the thing every announcement depends on.
func makeCameraStream(
    box: RoadSpeedBox,
    httpClient: HTTPClient,
    decoder: DataDecoder<OverpassCameraResponse>,
    radius: Meters,
    localCameras: @escaping @Sendable (Latitude, Longitude, Meters) -> CameraSet?,
    log: @escaping @Sendable (String) -> Void
) -> Publisher<CameraSet, Never> {
    throttledLocations(box: box)
        .map(fetchCameras(
            httpClient: httpClient, decoder: decoder, radius: radius,
            localCameras: localCameras, log: log
        ))
        .switchToLatest()
}

/// One camera lookup.
///
/// Failure drops the event rather than emitting an empty list — same reasoning as the road fetch,
/// but with more at stake. The public Overpass endpoint answers 504 often enough that treating a
/// timeout as "no cameras here" would silently disarm the warnings on exactly the road you were
/// being warned about. Holding the previous set is both quieter and safer.
private func fetchCameras(
    httpClient: HTTPClient,
    decoder: DataDecoder<OverpassCameraResponse>,
    radius: Meters,
    localCameras: @escaping @Sendable (Latitude, Longitude, Meters) -> CameraSet?,
    log: @escaping @Sendable (String) -> Void
) -> @Sendable (LocationUpdate) -> Publisher<CameraSet, Never> {
    { location in
        // The extract first, and for cameras this matters more than it does for roads. There is no
        // second source for camera data, so a refused request used to mean riding the whole journey
        // with the warnings silently disarmed — the single point of failure the road lookup has
        // already escaped.
        //
        // `nil` means the position is outside the extract, **not** that there is nothing here. An
        // empty set from inside the bounds is a real answer and is used as one; ride to France and
        // every lookup falls through to Overpass, which is exactly right.
        if let local = localCameras(location.latitude, location.longitude, radius) {
            log("camera-local n=\(local.cameras.count) zones=\(local.zones.count)")
            return .just(local)
        }

        @Sendable func attempt(_ hostIndex: Int) -> Publisher<CameraSet, Never> {
            // A request that will not build is the same outcome as one that fails: hold the set
            // already known rather than blanking it.
            guard let request = overpassCameraRequest(
                latitude: location.latitude,
                longitude: location.longitude,
                radius: radius,
                hostIndex: hostIndex
            ) else { return .empty() }

            return httpClient(request)
            .validateStatusCode()
            .decode(using: decoder)
            .map(parseCameraSet)
            .catch { error in
                // No fallback: there is no second source for camera data, and the held set stays
                // valid until the next scheduled lookup.
                log("camera-fetch-failed \(String(describing: error).prefix(90))")
                return Publisher<CameraSet, Never>.empty()
            }
        }
        log("camera-fetch")
        return attempt(0)
    }
}
