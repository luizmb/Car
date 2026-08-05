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
    /// When the fix was taken, which is not when it was received — queued fixes arrive in bursts
    /// after a tunnel or a backgrounded stretch, and distance integration needs the former.
    public let timestamp: Date
    /// Horizontal accuracy in metres, `nil` when CoreLocation reports the fix as invalid.
    ///
    /// The gate for distance accumulation: a stationary receiver random-walks, and every metre of
    /// that drift lands directly in the fuel maths as distance never travelled.
    public let horizontalAccuracy: Meters?

    public init(_ location: CLLocation) {
        speed         = location.speed         >= 0 ? MPS(location.speed)         : nil
        speedAccuracy = location.speedAccuracy >= 0 ? MPS(location.speedAccuracy) : nil
        course        = location.course        >= 0 ? Course(location.course)      : nil
        latitude      = Latitude(location.coordinate.latitude)
        longitude     = Longitude(location.coordinate.longitude)
        altitude      = Meters(location.altitude)
        timestamp     = location.timestamp
        horizontalAccuracy = location.horizontalAccuracy >= 0
            ? Meters(location.horizontalAccuracy)
            : nil
    }

    /// Memberwise, for tests and for replaying recorded fixes.
    public init(
        speed: MPS?, speedAccuracy: MPS?, course: Course?,
        latitude: Latitude, longitude: Longitude, altitude: Meters,
        timestamp: Date, horizontalAccuracy: Meters?
    ) {
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
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
