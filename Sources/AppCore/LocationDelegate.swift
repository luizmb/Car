import CoreLocation
import AppDomain

// Bridges CLLocationManagerDelegate into two independent streams:
//   authStream    — authorization status changes
//   locationStream — GPS fixes (only flowing after startUpdatingLocation is called)
//
// Lives in AppCore because it is an implementation detail of the live World.
final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var authContinuation: AsyncStream<AuthorizationUpdate>.Continuation?
    var locationContinuation: AsyncStream<LocationUpdate>.Continuation?

    // Reports the current authorization status. Does NOT start location updates —
    // that is driven by the store via the readyToMonitor action.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authContinuation?.yield(AuthorizationUpdate(
            manager.authorizationStatus,
            manager.accuracyAuthorization
        ))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locations
            .map(LocationUpdate.init)
            .forEach { locationContinuation?.yield($0) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Errors are not propagated as stream events; the location stream simply
        // stops delivering until the manager recovers.
    }
}
