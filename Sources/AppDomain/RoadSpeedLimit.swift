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
    /// True when `limit` was derived from the national limit for the road's class rather than read
    /// from an explicit `maxspeed` tag — either because the tag said `national`, or because there
    /// was no tag at all. Drives the NSL sign in the UI and "national" in the announcement, so the
    /// rider knows the figure is inferred rather than signposted.
    public let resolvedFromNational: Bool

    /// The road carries variable limits — a smart motorway with gantry signs.
    ///
    /// OSM records *that* the limit varies, never what it currently is: gantry settings are live
    /// data no static map has. So the number here is the default, and the honest thing is to say
    /// the limit is variable rather than assert a figure the signs may be contradicting.
    public let isVariable: Bool

    public init(
        limit: RoadSpeedLimit, ref: String?, name: String?,
        resolvedFromNational: Bool, isVariable: Bool = false
    ) {
        self.limit                = limit
        self.ref                  = ref
        self.name                 = name
        self.resolvedFromNational = resolvedFromNational
        self.isVariable           = isVariable
    }

    public static let unknown = RoadInfo(
        limit: .unknown, ref: nil, name: nil, resolvedFromNational: false
    )

    /// How the road is referred to out loud — `ref` preferred over `name` because "A40" is shorter to
    /// hear at speed than "Western Avenue". `nil` when OSM gave us neither.
    public var roadLabel: String? { ref ?? name }

    /// Everything an announcement would mention. Comparing this — rather than the limit alone — is what
    /// makes turning from a 30 road onto a different 30 road speak, while driving the length of the A40
    /// stays silent across Overpass polls.
    public var announcement: Announcement {
        Announcement(limit: limit, label: roadLabel, national: resolvedFromNational, variable: isVariable)
    }

    public struct Announcement: Sendable, Equatable {
        public let limit: RoadSpeedLimit
        public let label: String?
        public let national: Bool
        public let variable: Bool
    }
}
