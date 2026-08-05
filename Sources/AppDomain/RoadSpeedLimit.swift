import FP

// MARK: - Road speed limit

public enum RoadSpeedLimit: Sendable, Equatable {
    case unknown
    case value(MPH)
    case national   // UK national speed limit: 60 mph single carriageway, 70 mph dual/motorway
}

// MARK: - Where the number came from

/// How a limit was arrived at.
///
/// This exists because "inferred" was previously one flag covering two very different inferences,
/// and the announcement said "national speed" for both. On a residential street that is simply
/// false: the *national speed limit* is a specific thing meaning 60 or 70, and the sign for it is a
/// white circle with a black diagonal. A 30 on a residential road is the built-up-area default —
/// nothing national about it. Riding a housing estate and hearing "national speed, 30" is
/// contradictory enough to make the rider distrust the announcements that *are* right.
public enum LimitOrigin: Sendable, Equatable {
    /// Read from an explicit `maxspeed` tag — someone surveyed an actual sign.
    case signed
    /// Inferred from the road's class as the built-up-area default of 30.
    case builtUpArea
    /// Inferred as the national speed limit: 60 single carriageway, 70 dual carriageway and motorway.
    case nationalSpeedLimit
    /// Nothing to attribute — the limit is `.unknown`, or `.national` with the class unresolvable.
    case unattributed
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
    /// How `limit` was arrived at. Drives both the wording of the announcement and which sign the UI
    /// shows, so that an inferred figure is never presented as a signposted one.
    public let origin: LimitOrigin

    /// The road carries variable limits — a smart motorway with gantry signs.
    ///
    /// OSM records *that* the limit varies, never what it currently is: gantry settings are live
    /// data no static map has. So the number here is the default, and the honest thing is to say
    /// the limit is variable rather than assert a figure the signs may be contradicting.
    public let isVariable: Bool

    public init(
        limit: RoadSpeedLimit, ref: String?, name: String?,
        origin: LimitOrigin, isVariable: Bool = false
    ) {
        self.limit = limit
        self.ref = ref
        self.name = name
        self.origin = origin
        self.isVariable = isVariable
    }

    public static let unknown = RoadInfo(
        limit: .unknown, ref: nil, name: nil, origin: .unattributed
    )

    /// How the road is referred to out loud — `ref` preferred over `name` because "A40" is shorter to
    /// hear at speed than "Western Avenue". `nil` when OSM gave us neither.
    public var roadLabel: String? { ref ?? name }

    /// Everything an announcement would mention. Comparing this — rather than the limit alone — is what
    /// makes turning from a 30 road onto a different 30 road speak, while driving the length of the A40
    /// stays silent across Overpass polls.
    public var announcement: Announcement {
        Announcement(limit: limit, label: roadLabel, origin: origin, variable: isVariable)
    }

    public struct Announcement: Sendable, Equatable {
        public let limit: RoadSpeedLimit
        public let label: String?
        public let origin: LimitOrigin
        public let variable: Bool
    }
}
