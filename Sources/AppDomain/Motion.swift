import FP
import FPMacros
import Foundation

// MARK: - Vector

/// A three-axis reading in the **device's** frame of reference.
///
/// Device frame is the crux of everything here: the phone rides loose in a jacket pocket, so its
/// axes bear no fixed relationship to the bike. Individual components are therefore close to
/// meaningless, while magnitudes — which are invariant under rotation — remain trustworthy. The raw
/// components are still recorded, because a future calibration might recover the pocket-to-bike
/// rotation, and discarded data cannot be recovered.
public struct Vector3: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

// MARK: - Barometer

/// A barometric reading. The reason this matters is carburation: a carb meters fuel by air
/// *volume* while the engine needs air *mass*, so falling air density richens the mixture and costs
/// economy. Density is derived from pressure and temperature — and this is a pressure measured in
/// your pocket, not interpolated from a weather station twenty kilometres away.
public struct BarometricSample: Sendable, Equatable {
    public let pressure: KPa
    /// Altitude change since monitoring began. Relative by nature, but far less noisy than GPS
    /// altitude, so climbs and descents are worth having on their own.
    public let relativeAltitude: Meters

    public init(pressure: KPa, relativeAltitude: Meters) {
        self.pressure = pressure
        self.relativeAltitude = relativeAltitude
    }
}

// MARK: - Motion

public struct MotionSample: Sendable, Equatable {
    /// Acceleration excluding gravity, in g, device frame.
    public let userAcceleration: Vector3
    /// The gravity vector as the device sees it, in g.
    public let gravity: Vector3
    /// Angular velocity in radians/second, device frame.
    public let rotationRate: Vector3

    public init(userAcceleration: Vector3, gravity: Vector3, rotationRate: Vector3) {
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
    }
}

// MARK: - Orientation-independent derivations

public extension MotionSample {
    /// Total specific force in g — gravity plus everything else. **Rotation-invariant**, so it
    /// survives the phone tumbling in a pocket, which is what makes it the only trustworthy basis
    /// for inference here.
    var totalForce: Double {
        Vector3(
            x: gravity.x + userAcceleration.x,
            y: gravity.y + userAcceleration.y,
            z: gravity.z + userAcceleration.z
        ).magnitude
    }

    /// How hard the bike is being pushed around, in g, ignoring direction. Braking, accelerating
    /// and cornering all raise it; separating them needs GPS, which supplies longitudinal
    /// acceleration independently as the derivative of speed.
    var effort: Double { userAcceleration.magnitude }

    /// How fast the whole assembly is rotating, rad/s. Cannot be resolved into yaw/pitch/roll from
    /// a pocket, but the magnitude still distinguishes a sweeping bend from a flick.
    var rotationSpeed: Double { rotationRate.magnitude }

    /// Lean angle in degrees, inferred without knowing the phone's orientation.
    ///
    /// A motorcycle in a steady turn leans until the resultant of gravity and centripetal force
    /// runs through the tyre contact patch. That resultant has magnitude `g / cos(θ)`, so the lean
    /// follows from a scalar the pocket cannot corrupt:
    ///
    ///     θ = acos(1 / totalForce)
    ///
    /// **Assumes a steady turn.** Braking, accelerating and bumps all inflate `totalForce` and will
    /// read as lean — so this is a candidate to validate offline against GPS-derived lateral
    /// acceleration (speed × yaw rate), not a number to trust on its own. `nil` below 1 g, which
    /// means the bike is going over a crest or the phone is in free fall, and no lean is implied.
    var leanEstimate: Double? {
        let force = totalForce
        guard force >= 1 else { return nil }
        return acos(1 / force) * 180 / .pi
    }
}

// MARK: - Activity

/// CoreMotion's own classification of what you are doing.
///
/// Whether iOS calls a motorcycle `automotive` or `cycling` is genuinely unknown — a bike sits
/// between the two, and the phone is on a leaning body rather than a seat. One ride settles it,
/// which is why the raw classification is recorded rather than mapped to something opinionated.
@Prisms
public enum MotionActivity: Sendable, Equatable {
    case stationary
    case walking
    case running
    case automotive
    case cycling
    case unknown
}

public struct MotionActivitySample: Sendable, Equatable {
    public let activity: MotionActivity
    /// CoreMotion's own confidence, 0 (low) to 2 (high).
    public let confidence: Int

    public init(activity: MotionActivity, confidence: Int) {
        self.activity = activity
        self.confidence = confidence
    }
}

// MARK: - Air density

/// Air density in kg/m³, from measured pressure and temperature.
///
/// The physically-motivated single feature that replaces temperature, pressure and altitude as
/// three weak statistical ones — it is the actual causal driver of how rich a carburettor runs, so
/// it learns from far fewer refuelling data points than the alternatives would.
///
/// Dry-air ideal gas law: `ρ = p / (R_specific × T)`. Humidity lowers density further (water vapour
/// is lighter than air) and is ignored here until a weather source supplies it.
public func airDensity(pressure: KPa, temperature: Celsius) -> Double {
    let pascals = pressure.rawValue * 1000
    let kelvin = temperature.rawValue + 273.15
    let specificGasConstant = 287.058   // J/(kg·K), dry air
    return pascals / (specificGasConstant * kelvin)
}
