import FP
import FPMacros
import Foundation

// MARK: - Kinds

/// What sort of enforcement device it is. They warrant different words: an average-speed zone is not
/// something you can react to at a point, and a red-light camera says nothing about your speed.
@Prisms
public enum CameraKind: Sendable, Equatable {
    case fixed
    /// SPECS/VECTOR gantries. Common on UK roadworks and A-roads, and the one kind a point warning
    /// genuinely cannot cover — see ``cameraAnnouncement``.
    case average
    case redLight
    /// A known mobile-van site. Mapped inconsistently, so absence means nothing at all.
    case mobile
    /// Tagged as enforcement but of a sort we do not recognise. Announced anyway — an unfamiliar tag
    /// is a reason to be vaguer, not a reason to stay silent.
    case unknown
}

// MARK: - Camera

public struct SpeedCamera: Sendable, Equatable, Identifiable {
    /// The OSM element id. Stable across fetches, which is what lets a camera be announced once per
    /// approach rather than once per GPS fix.
    public let id: Int
    public let kind: CameraKind
    public let latitude: Latitude
    public let longitude: Longitude
    /// The limit this device enforces, where OSM says so. Often absent, and often *different* from
    /// the road's general limit, which is the whole reason it is worth carrying separately.
    public let limit: MPH?
    /// Compass bearing the camera faces, where resolvable.
    ///
    /// Recorded but deliberately **not** used to filter. A camera tagged as facing the other way may
    /// still be on your carriageway, `direction` is absent or relative on a great many of them, and a
    /// missed camera costs far more than a redundant sentence.
    public let direction: Double?

    public init(
        id: Int, kind: CameraKind,
        latitude: Latitude, longitude: Longitude,
        limit: MPH?, direction: Double?
    ) {
        self.id = id
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.limit = limit
        self.direction = direction
    }
}

// MARK: - Overpass

/// Everything enforcement-related within `radius` metres.
///
/// Four element shapes, because OSM tags cameras four ways and picking one would silently lose the
/// rest:
///
/// - `highway=speed_camera` nodes — the plain fixed camera
/// - `enforcement=*` nodes — devices tagged directly
/// - `type=enforcement` relations — the richer form, and the one that carries its own `maxspeed`
/// - `highway=speed_camera` ways — rare, but they exist (gantries mapped as structures)
///
/// `out geom` rather than `out center`, because an `average_speed` relation's **members** are the
/// point: the `from` and `to` roles are what say where a zone begins and ends, and a bare centre
/// cannot tell you that you have left one.
public func overpassCameraRequest(
    latitude: Latitude, longitude: Longitude, radius: Meters,
    endpoint: OverpassEndpoint = .cameras,
    hostIndex: Int = 0
) -> URLRequest? {
    let r = Int(radius.rawValue)
    let around = "around:\(r),\(latitude.rawValue),\(longitude.rawValue)"
    let query = """
    [out:json][timeout:25];(\
    node(\(around))["highway"="speed_camera"];\
    node(\(around))["enforcement"];\
    way(\(around))["highway"="speed_camera"];\
    relation(\(around))["type"="enforcement"];\
    );out geom;
    """
    return endpoint.request(query, hostIndex: hostIndex)
}

public struct OverpassCameraResponse: Decodable, Sendable {
    public struct Element: Decodable, Sendable {
        public struct Center: Decodable, Sendable {
            public let lat: Double
            public let lon: Double
        }
        /// A relation member. `role` is what matters — `from` and `to` bound an average-speed zone,
        /// `device` marks the cameras themselves.
        public struct Member: Decodable, Sendable {
            public let type: String?
            public let role: String?
            public let lat: Double?
            public let lon: Double?
            public let geometry: [Center]?

            /// Where the member is. A way contributes its first point, which for a `from`/`to` role
            /// is the end of the road segment the zone starts or stops at.
            public var position: Coordinate? {
                if let lat, let lon { return Coordinate(latitude: Latitude(lat), longitude: Longitude(lon)) }
                guard let point = geometry?.first else { return nil }
                return Coordinate(latitude: Latitude(point.lat), longitude: Longitude(point.lon))
            }
        }
        public struct Tags: Decodable, Sendable {
            public let highway: String?
            public let enforcement: String?
            public let maxspeed: String?
            public let direction: String?
            public let speedCamera: String?
            public let device: String?

            enum CodingKeys: String, CodingKey {
                case highway, enforcement, maxspeed, direction, device
                case speedCamera = "speed_camera"
            }
        }
        public let id: Int
        public let lat: Double?
        public let lon: Double?
        public let center: Center?
        public let geometry: [Center]?
        public let members: [Member]?
        public let tags: Tags?

        /// A single position for the element, however it was mapped.
        public var position: Coordinate? {
            if let lat, let lon { return Coordinate(latitude: Latitude(lat), longitude: Longitude(lon)) }
            if let center { return Coordinate(latitude: Latitude(center.lat), longitude: Longitude(center.lon)) }
            if let point = geometry?.first {
                return Coordinate(latitude: Latitude(point.lat), longitude: Longitude(point.lon))
            }
            // A relation: take a device if one is named, otherwise anything with a position.
            let devices = members?.filter { $0.role == "device" } ?? []
            return (devices.first ?? members?.first { $0.position != nil })?.position
        }
    }
    public let elements: [Element]
}

// MARK: - Coordinate

public struct Coordinate: Sendable, Equatable {
    public let latitude: Latitude
    public let longitude: Longitude

    public init(latitude: Latitude, longitude: Longitude) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var pair: (Latitude, Longitude) { (latitude, longitude) }
}

// MARK: - Average-speed zones

/// A stretch between two gantries, where your **mean** speed is what is measured.
///
/// A point warning is the wrong shape for these: you can be under the limit at both cameras and
/// still be fined, and being told about them once tells you nothing about how you are doing. So the
/// zone is modelled as something you are inside or outside of, with a beginning and an end.
public struct AverageZone: Sendable, Equatable, Identifiable {
    public let id: Int
    public let limit: MPH?
    /// Where the zone begins and ends, from the relation's `from` and `to` members. Either may be
    /// absent — plenty of zones are mapped with only devices — in which case entry falls back to the
    /// first camera and exit to leaving the fetched area entirely.
    public let start: Coordinate?
    public let end: Coordinate?

    public init(id: Int, limit: MPH?, start: Coordinate?, end: Coordinate?) {
        self.id = id
        self.limit = limit
        self.start = start
        self.end = end
    }
}

public func parseAverageZones(_ response: OverpassCameraResponse) -> [AverageZone] {
    response.elements.compactMap { element -> AverageZone? in
        guard
            let tags = element.tags,
            tags.enforcement?.lowercased() == "average_speed"
        else { return nil }

        let members = element.members ?? []
        return AverageZone(
            id: element.id,
            limit: parseMaxspeedMPH(tags.maxspeed),
            start: members.first { $0.role == "from" }?.position,
            end: members.first { $0.role == "to" }?.position
        )
    }
}

/// Everything one fetch produced. Cameras and zones come from the same query and are stored
/// together, so they can never disagree about what is currently known.
public struct CameraSet: Sendable, Equatable {
    public let cameras: [SpeedCamera]
    public let zones: [AverageZone]

    public init(cameras: [SpeedCamera], zones: [AverageZone]) {
        self.cameras = cameras
        self.zones = zones
    }

    public static let empty = CameraSet(cameras: [], zones: [])
}

public func parseCameraSet(_ response: OverpassCameraResponse) -> CameraSet {
    CameraSet(cameras: parseCameras(response), zones: parseAverageZones(response))
}

public func parseCameras(_ response: OverpassCameraResponse) -> [SpeedCamera] {
    response.elements.compactMap { element -> SpeedCamera? in
        // A camera without a position cannot be warned about, so it is dropped rather than guessed at.
        guard
            let position = element.position,
            let tags = element.tags,
            let kind = cameraKind(from: tags)
        else { return nil }

        return SpeedCamera(
            id: element.id,
            kind: kind,
            latitude: position.latitude,
            longitude: position.longitude,
            limit: parseMaxspeedMPH(tags.maxspeed),
            direction: parseDirection(tags.direction)
        )
    }
}

/// `nil` when the element is not an enforcement device at all — the query is broad enough to catch
/// the occasional unrelated node.
func cameraKind(from tags: OverpassCameraResponse.Element.Tags) -> CameraKind? {
    let mobile = (tags.speedCamera?.lowercased() == "mobile")
        || (tags.device?.lowercased() == "mobile")

    switch tags.enforcement?.lowercased() {
    case "average_speed": return .average
    case "traffic_signals": return .redLight
    case "maxspeed", "speed": return mobile ? .mobile : .fixed
    case .some: return .unknown   // an enforcement device of some other sort — still worth saying
    case nil: break
    }

    guard tags.highway?.lowercased() == "speed_camera" else { return nil }
    return mobile ? .mobile : .fixed
}

/// Compass degrees, from either a number or a cardinal abbreviation.
///
/// `forward`/`backward` are relative to a way we did not fetch, so they resolve to `nil` — unknown,
/// which is treated identically to absent since direction never excludes anything.
func parseDirection(_ raw: String?) -> Double? {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
        return nil
    }
    if let degrees = Double(raw) { return degrees.truncatingRemainder(dividingBy: 360) }
    let compass: [String: Double] = [
        "n": 0, "nne": 22.5, "ne": 45, "ene": 67.5,
        "e": 90, "ese": 112.5, "se": 135, "sse": 157.5,
        "s": 180, "ssw": 202.5, "sw": 225, "wsw": 247.5,
        "w": 270, "wnw": 292.5, "nw": 315, "nnw": 337.5
    ]
    return compass[raw]
}

// MARK: - Geometry

/// Initial bearing from one point to another, in compass degrees.
public func bearing(from origin: (Latitude, Longitude), to target: (Latitude, Longitude)) -> Double {
    let point = project(target.0, target.1, origin: origin)
    var degrees = atan2(point.x, point.y) * 180 / .pi
    if degrees < 0 { degrees += 360 }
    return degrees
}

/// Public because the road fetcher needs it too, to tell one junction from the same junction.
public func distanceMetres(
    from origin: (Latitude, Longitude), to target: (Latitude, Longitude)
) -> Double {
    let point = project(target.0, target.1, origin: origin)
    return (point.x * point.x + point.y * point.y).squareRoot()
}

// MARK: - Selection

/// How far ahead to look, as a function of how fast you are going.
///
/// Time rather than distance: 200 m is a comfortable fifteen seconds at 30 mph and a panicky five at
/// 70, so a fixed distance gives the least warning exactly where the most is needed. Clamped at both
/// ends — a floor so a camera is still called while crawling, a ceiling so a motorway does not
/// announce something a minute and a half away.
public func lookaheadDistance(
    speed: MPS,
    seconds: Double = 20,
    minimum: Meters = Meters(200),
    maximum: Meters = Meters(1_200)
) -> Meters {
    Meters(min(maximum.rawValue, max(minimum.rawValue, speed.rawValue * seconds)))
}

/// The cameras worth mentioning, nearest first.
///
/// **Deliberately permissive.** The cost of a camera we failed to mention is a fine; the cost of one
/// mentioned needlessly is a short sentence. So:
///
/// - the heading cone is wide (±`coneDegrees`, default 100°), which excludes only what is genuinely
///   behind you rather than demanding alignment
/// - a camera's own `direction` tag never excludes it — see ``SpeedCamera/direction``
/// - with no course at all (stationary, or CoreLocation reporting it invalid) *everything* within
///   range is returned, since nothing can be ruled out
public func camerasAhead(
    _ cameras: [SpeedCamera],
    at position: (Latitude, Longitude),
    course: Course?,
    speed: MPS,
    coneDegrees: Double = 100
) -> [SpeedCamera] {
    let reach = lookaheadDistance(speed: speed).rawValue

    return cameras
        .compactMap { camera -> (SpeedCamera, Double)? in
            let distance = distanceMetres(from: position, to: (camera.latitude, camera.longitude))
            guard distance <= reach else { return nil }
            guard let course else { return (camera, distance) }

            let toCamera = bearing(from: position, to: (camera.latitude, camera.longitude))
            var delta = abs(toCamera - course.rawValue).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta = 360 - delta }
            guard delta <= coneDegrees else { return nil }
            return (camera, distance)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
}

/// How far off the route a camera can be and still be about the road being ridden.
///
/// A carriageway is a few metres wide and a mapped camera sits beside it, so 35 m keeps the ones
/// that watch this road and drops the ones on the next arm of the roundabout.
public let cameraOnRouteMetres: Double = 35

/// The cameras that are on the route, when there is a route.
///
/// With no route this is everything — the bearing cone is all there is to go on, and being
/// permissive is the right error when a missed camera costs a fine.
public func onRoute(_ cameras: [SpeedCamera], shape: [Coordinate]) -> [SpeedCamera] {
    guard shape.count > 1 else { return cameras }
    return cameras.filter {
        distanceToRoute(
            shape: shape,
            from: Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        ) <= cameraOnRouteMetres
    }
}

/// The zones that belong to the route being ridden.
///
/// Zones needed this as much as cameras did and did not have it: an average-speed check is entered
/// when its start is within 250 m, and 250 m in a town reaches several other roads. Heard on a
/// replayed ride as "average speed check, 50" while on a 30 mph street — the zone was real, and on
/// a road the rider was not on.
///
/// A zone counts if **either end** is on the route: entering one is the start, and a zone entered
/// before the route was joined still has its exit ahead.
public func onRoute(_ zones: [AverageZone], shape: [Coordinate]) -> [AverageZone] {
    guard shape.count > 1 else { return zones }
    return zones.filter { zone in
        [zone.start, zone.end].compactMap { $0 }.contains {
            distanceToRoute(shape: shape, from: $0) <= cameraOnRouteMetres
        }
    }
}

/// How much faster than the road a camera may claim before it is judged to be watching a different
/// one.
///
/// Ten, so a camera enforcing the same limit or a slightly rounded version of it survives.
public let cameraLimitToleranceMPH: Double = 10

/// Cameras plausibly about the road being ridden.
///
/// Proximity cannot settle this on its own. Six cameras were announced on a 30 mph stretch of the
/// A1081 — all real, all in OSM, all tagged 50 — and every one of them sits five to eight metres
/// from a `trunk_link`: the M1 slip roads running alongside. At a junction every road is within a
/// few tens of metres of every other, so no distance threshold separates them.
///
/// The limit does. A camera **enforcing a higher speed than the road underneath** is watching a
/// faster road; that is what a slip road beside a 30 is.
///
/// Deliberately one-directional. A camera claiming a *lower* limit than the road is exactly what
/// roadworks look like, and those are ours — so they are kept. Suppressing a real camera costs a
/// fine, which is why this only ever discards the case that cannot be ours.
public func plausible(_ cameras: [SpeedCamera], onRoadLimited roadLimit: MPH?) -> [SpeedCamera] {
    guard let roadLimit else { return cameras }
    return cameras.filter { camera in
        guard let limit = camera.limit else { return true }
        return limit.rawValue <= roadLimit.rawValue + cameraLimitToleranceMPH
    }
}

/// Zones plausibly about the road being ridden.
///
/// Same argument as ``plausible(_:onRoadLimited:)`` and the same asymmetry: an average-speed check
/// claiming 50 while the road underneath is signed 30 is watching the dual carriageway alongside,
/// not this street. A zone claiming *less* than the road is roadworks, and that is ours.
public func plausible(_ zones: [AverageZone], onRoadLimited roadLimit: MPH?) -> [AverageZone] {
    guard let roadLimit else { return zones }
    return zones.filter { zone in
        guard let limit = zone.limit else { return true }
        return limit.rawValue <= roadLimit.rawValue + cameraLimitToleranceMPH
    }
}

// MARK: - Announcement

/// What to say about a camera.
///
/// The current speed is always spoken, over the limit or not — asked for explicitly, and right:
/// hearing "thirty, you're at twenty-eight" is the reassurance that stops you glancing at the phone,
/// which is the whole point of an audio-first app on a bike with no working instruments.
///
/// An average-speed zone gets different wording because a point warning genuinely does not apply:
/// what matters is your mean between the gantries, so the honest phrasing tells you a zone has begun
/// rather than implying a single measurement.
public func cameraAnnouncement(
    _ camera: SpeedCamera,
    currentSpeed: MPH,
    roadInfo: RoadInfo? = nil,
    formatSpeed: (MPH) -> String
) -> String {
    let noun: String = switch camera.kind {
    case .fixed: "Speed camera"
    case .average: "Average speed check"
    case .redLight: "Red light camera"
    case .mobile: "Mobile camera site"
    case .unknown: "Camera"
    }

    let you = "you're at \(formatSpeed(currentSpeed))"

    // Most cameras carry no `maxspeed` of their own — smart-motorway gantries especially, since the
    // limit they enforce is whatever the signs currently read. Falling back to the road's limit is
    // better than saying nothing, but it must not be stated as though the camera said it.
    let roadLimit: MPH? = if case let .value(mph) = roadInfo?.limit { mph } else { nil }
    let variable = camera.limit == nil && (roadInfo?.isVariable ?? false)

    guard let limit = camera.limit ?? roadLimit else {
        // No figure anywhere. The camera is still announced — that was the explicit requirement, and
        // an unknown limit is a reason to say less, not to stay silent.
        return "\(noun) ahead, \(you)."
    }

    let spokenLimit = formatSpeed(limit)
    guard !variable else {
        // The gantries win. The number is OSM's default, so it is offered as a hint rather than
        // asserted, and no instruction is given against a limit we cannot read.
        return "\(noun) ahead, variable limit, normally \(spokenLimit), \(you)."
    }

    return currentSpeed.rawValue > limit.rawValue
        ? "\(noun) ahead, \(spokenLimit), \(you), slow down."
        : "\(noun) ahead, \(spokenLimit), \(you)."
}

// MARK: - Zone transitions

/// How close to a gantry counts as reaching it.
///
/// Generous, because fixes arrive about once a second: at 70 mph that is 31 m of travel per fix, so
/// a tight window could be stepped straight over between two fixes and the transition missed
/// entirely. Missing the *end* of a zone is the worse failure — it would leave you being warned
/// about an average you are no longer accumulating.
let zoneBoundaryMetres: Double = 250

/// The zone you have just entered, if any.
///
/// Falls back to the cameras themselves when the relation has no `from` member, which is common —
/// plenty of zones are mapped as devices only. In that case the first camera of the zone is the
/// beginning, which is the best available answer and errs toward warning early.
public func averageZoneEntered(
    zones: [AverageZone],
    cameras: [SpeedCamera],
    at position: Coordinate,
    currentZone: AverageZone?
) -> AverageZone? {
    zones.first { zone in
        guard zone.id != currentZone?.id else { return false }
        if let start = zone.start {
            return distanceMetres(from: position.pair, to: start.pair) <= zoneBoundaryMetres
        }
        return cameras.contains { camera in
            camera.kind == .average
                && distanceMetres(from: position.pair, to: (camera.latitude, camera.longitude)) <= zoneBoundaryMetres
        }
    }
}

/// Whether the active zone has been left.
///
/// With no `to` member there is nothing to measure against, so the zone is never exited on geometry
/// alone — the feature drops it when the zone falls out of the fetched set instead. Announcing an
/// end we cannot see would be worse than staying quiet about it.
public func averageZoneExited(_ zone: AverageZone, at position: Coordinate) -> Bool {
    guard let end = zone.end else { return false }
    return distanceMetres(from: position.pair, to: end.pair) <= zoneBoundaryMetres
}

// MARK: - Zone announcements

public func averageZoneStartAnnouncement(
    _ zone: AverageZone,
    currentSpeed: MPH,
    formatSpeed: (MPH) -> String
) -> String {
    let you = "you're at \(formatSpeed(currentSpeed))"
    guard let limit = zone.limit else { return "Average speed check begins, \(you)." }
    return "Average speed check begins, \(formatSpeed(limit)), \(you)."
}

public func averageZoneEndAnnouncement(_ zone: AverageZone) -> String {
    "Average speed check ends."
}

/// Spoken when you cross above the limit *inside* a zone.
///
/// Deliberately different from the ordinary over-limit call. In an average-speed zone a moment above
/// the limit is not itself the problem — the mean between the gantries is — so the wording says what
/// is actually being measured rather than implying a single reading has caught you.
public func averageZoneOverLimitAnnouncement(
    _ zone: AverageZone,
    currentSpeed: MPH,
    formatSpeed: (MPH) -> String
) -> String {
    let you = "you're at \(formatSpeed(currentSpeed))"
    guard let limit = zone.limit else { return "Still in the average speed check, \(you)." }
    return "Average speed check, \(formatSpeed(limit)), \(you), your average is what counts."
}
