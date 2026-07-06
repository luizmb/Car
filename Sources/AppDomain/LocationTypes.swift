import CoreLocation
import FP

// MARK: - Value types

public struct LocationUpdate: Sendable, Equatable {
    public let speed: MPS?          // nil when CLLocation reports invalid (< 0)
    public let speedAccuracy: MPS?  // nil when CLLocation reports invalid (< 0)
    public let course: Course?      // nil when CLLocation reports invalid (< 0)
    public let latitude: Latitude
    public let longitude: Longitude
    public let altitude: Meters

    public init(_ location: CLLocation) {
        speed         = location.speed         >= 0 ? MPS(location.speed)         : nil
        speedAccuracy = location.speedAccuracy >= 0 ? MPS(location.speedAccuracy) : nil
        course        = location.course        >= 0 ? Course(location.course)      : nil
        latitude      = Latitude(location.coordinate.latitude)
        longitude     = Longitude(location.coordinate.longitude)
        altitude      = Meters(location.altitude)
    }
}

// MARK: - Authorization update (separate from location data)

public struct AuthorizationUpdate: Sendable, Equatable {
    public let status: CLAuthorizationStatus
    public let accuracy: CLAccuracyAuthorization
    public init(_ status: CLAuthorizationStatus, _ accuracy: CLAccuracyAuthorization) {
        self.status   = status
        self.accuracy = accuracy
    }
}
