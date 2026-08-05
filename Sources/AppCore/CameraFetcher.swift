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
    radius: Meters
) -> Publisher<CameraSet, Never> {
    throttledLocations(box: box)
        .map(fetchCameras(httpClient: httpClient, decoder: decoder, radius: radius))
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
    radius: Meters
) -> @Sendable (LocationUpdate) -> Publisher<CameraSet, Never> {
    { location in
        httpClient(
            overpassCameraRequest(
                latitude: location.latitude,
                longitude: location.longitude,
                radius: radius
            )
        )
        .validateStatusCode()
        .decode(using: decoder)
        .map(parseCameraSet)
        .retry(2)
        .catch { _ in Publisher<CameraSet, Never>.empty() }
    }
}
