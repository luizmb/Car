import FP

// MARK: - Road speed limit

public enum RoadSpeedLimit: Sendable, Equatable {
    case unknown
    case value(MPH)
    case national   // UK national speed limit: 60 mph single carriageway, 70 mph dual/motorway
}

// MARK: - Speed zone

/// The rider's zone relative to a known speed limit and its 10% tolerance.
public enum SpeedZone: Equatable, Comparable {
    case underLimit
    case overLimitUnderTolerance    // over actual limit but within 10%
    case overTolerance              // over the 10% tolerance threshold
}

public func speedZone(_ speed: MPH, limit: MPH) -> SpeedZone {
    if speed < limit                    { return .underLimit }
    if speed < MPH(limit.rawValue * 1.1) { return .overLimitUnderTolerance }
    return .overTolerance
}

public func toleranceThreshold(for limit: MPH) -> MPH {
    MPH(limit.rawValue * 1.1)
}

// MARK: - National beep limits

/// The speed values at which beeps fire when the road limit is .national.
public let nationalBeepLimits: [MPH] = [MPH(30), MPH(60), MPH(70)]

// MARK: - Road info

/// Everything SpeedJarvis needs about the current road — limit (fully resolved) and display name.
public struct RoadInfo: Sendable, Equatable {
    public let limit: RoadSpeedLimit
    /// OSM `ref` tag — road number, e.g. "M25", "A40", "B1234". Preferred for audio (shorter).
    public let ref: String?
    /// OSM `name` tag — road name, e.g. "High Street", "Oxford Road".
    public let name: String?
    /// True when `limit` was derived by resolving a `maxspeed: national` tag via `highway` / `maxspeed:type`.
    /// Used to decide whether to show the NSL sign alongside the resolved limit in the UI.
    public let resolvedFromNational: Bool

    public init(limit: RoadSpeedLimit, ref: String?, name: String?, resolvedFromNational: Bool) {
        self.limit                = limit
        self.ref                  = ref
        self.name                 = name
        self.resolvedFromNational = resolvedFromNational
    }

    public static let unknown = RoadInfo(limit: .unknown, ref: nil, name: nil, resolvedFromNational: false)
}
