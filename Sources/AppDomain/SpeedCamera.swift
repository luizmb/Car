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
/// `out center tags` gives nodes their `lat`/`lon` and ways/relations a `center`, so one decode
/// handles all of them.
public func overpassCameraRequest(
    latitude: Latitude, longitude: Longitude, radius: Meters
) -> URLRequest {
    let r = Int(radius.rawValue)
    let around = "around:\(r),\(latitude.rawValue),\(longitude.rawValue)"
    let query = """
    [out:json][timeout:25];(\
    node(\(around))["highway"="speed_camera"];\
    node(\(around))["enforcement"];\
    way(\(around))["highway"="speed_camera"];\
    relation(\(around))["type"="enforcement"];\
    );out center tags;
    """
    let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    // Fixed template over numeric rawValues — cannot fail.
    let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(escaped)")!
    return URLRequest(url: url)
}

public struct OverpassCameraResponse: Decodable, Sendable {
    public struct Element: Decodable, Sendable {
        public struct Center: Decodable, Sendable {
            public let lat: Double
            public let lon: Double
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
        public let tags: Tags?
    }
    public let elements: [Element]
}

public func parseCameras(_ response: OverpassCameraResponse) -> [SpeedCamera] {
    response.elements.compactMap { element -> SpeedCamera? in
        // A relation with no `center` has no position we can use; a camera without a position cannot
        // be warned about, so it is dropped rather than guessed at.
        guard
            let latitude = element.lat ?? element.center?.lat,
            let longitude = element.lon ?? element.center?.lon,
            let tags = element.tags,
            let kind = cameraKind(from: tags)
        else { return nil }

        return SpeedCamera(
            id: element.id,
            kind: kind,
            latitude: Latitude(latitude),
            longitude: Longitude(longitude),
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
func bearing(from origin: (Latitude, Longitude), to target: (Latitude, Longitude)) -> Double {
    let point = project(target.0, target.1, origin: origin)
    var degrees = atan2(point.x, point.y) * 180 / .pi
    if degrees < 0 { degrees += 360 }
    return degrees
}

func distanceMetres(from origin: (Latitude, Longitude), to target: (Latitude, Longitude)) -> Double {
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

    guard let limit = camera.limit else { return "\(noun) ahead, \(you)." }

    let over = currentSpeed.rawValue > limit.rawValue
    let spokenLimit = formatSpeed(limit)
    return over
        ? "\(noun) ahead, \(spokenLimit), \(you), slow down."
        : "\(noun) ahead, \(spokenLimit), \(you)."
}
