import FP
import Foundation

// MARK: - Unit tags (phantom types)

public enum MPHTag {}
public enum MPSTag {}
public enum KPHTag {}
public enum MetersTag {}
public enum FeetTag {}
public enum LatTag {}
public enum LonTag {}
public enum CourseTag {}

// MARK: - Newtypes

public typealias MPH       = Newtype<MPHTag,    Double>
public typealias MPS       = Newtype<MPSTag,    Double>
public typealias KPH       = Newtype<KPHTag,    Double>
public typealias Meters    = Newtype<MetersTag, Double>
public typealias Feet      = Newtype<FeetTag,   Double>
public typealias Latitude  = Newtype<LatTag,    Double>
public typealias Longitude = Newtype<LonTag,    Double>
public typealias Course    = Newtype<CourseTag, Double>

// MARK: - Generic unit-conversion helper

/// Builds an `Iso` between any two `Double`-backed `Newtype`s using Foundation's `Measurement`
/// for the math. `Measurement` is an implementation detail — callers only see typed newtypes.
public func measurementIso<STag, ATag, U: Dimension>(
    from sourceUnit: U,
    to targetUnit: U
) -> Iso<Newtype<STag, Double>, Newtype<ATag, Double>> {
    iso(
        get:        { Newtype(Measurement(value: $0.rawValue, unit: sourceUnit).converted(to: targetUnit).value) },
        reverseGet: { Newtype(Measurement(value: $0.rawValue, unit: targetUnit).converted(to: sourceUnit).value) }
    )
}

// MARK: - Length isos

extension Iso where S == Meters, A == Feet {
    public static var convert: Self { measurementIso(from: UnitLength.meters, to: .feet) }
}

// MARK: - Speed isos

extension Iso where S == MPS, A == MPH {
    public static var convert: Self { measurementIso(from: UnitSpeed.metersPerSecond, to: .milesPerHour) }
}

extension Iso where S == MPS, A == KPH {
    public static var convert: Self { measurementIso(from: UnitSpeed.metersPerSecond, to: .kilometersPerHour) }
}

extension Iso where S == MPH, A == KPH {
    public static var convert: Self { measurementIso(from: UnitSpeed.milesPerHour, to: .kilometersPerHour) }
}
