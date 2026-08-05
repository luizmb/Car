import FP
import Foundation

// MARK: - Local projection

/// A position in metres relative to an origin.
///
/// Over tens of metres an equirectangular projection is accurate to well under a centimetre, so the
/// spherical trigonometry that great-circle maths would need buys nothing here and obscures the
/// geometry.
struct LocalPoint: Equatable {
    let x: Double   // metres east
    let y: Double   // metres north
}

func project(_ latitude: Latitude, _ longitude: Longitude, origin: (Latitude, Longitude)) -> LocalPoint {
    let earthRadius = 6_371_000.0
    let originLatitudeRadians = origin.0.rawValue * .pi / 180
    return LocalPoint(
        x: (longitude.rawValue - origin.1.rawValue) * .pi / 180 * earthRadius * cos(originLatitudeRadians),
        y: (latitude.rawValue - origin.0.rawValue) * .pi / 180 * earthRadius
    )
}

// MARK: - Candidate

/// One road returned by Overpass, with the geometry needed to judge whether you are on it.
public struct RoadCandidate: Sendable, Equatable {
    public let tags: OverpassResponse.Element.Tags
    /// The way's shape. Empty when Overpass returned no geometry, in which case only the tags can
    /// be used and the candidate is a poor one.
    public let points: [(Latitude, Longitude)]

    public init(tags: OverpassResponse.Element.Tags, points: [(Latitude, Longitude)]) {
        self.tags = tags
        self.points = points
    }

    public static func == (lhs: RoadCandidate, rhs: RoadCandidate) -> Bool {
        lhs.tags.name == rhs.tags.name && lhs.tags.ref == rhs.tags.ref
            && lhs.points.count == rhs.points.count
    }
}

// MARK: - Geometry

/// Perpendicular distance in metres from a point to a segment, plus that segment's bearing.
///
/// The *nearest segment's* bearing, not the whole way's: a way can wander for a kilometre, and only
/// the piece beside you says anything about which direction you are travelling.
func nearestSegment(
    to origin: (Latitude, Longitude),
    on points: [(Latitude, Longitude)]
) -> (distance: Double, bearing: Double)? {
    guard points.count >= 2 else {
        // A single node has a distance but no direction — usable as a last resort, never as
        // evidence about heading.
        guard let only = points.first else { return nil }
        let p = project(only.0, only.1, origin: origin)
        return ((p.x * p.x + p.y * p.y).squareRoot(), .nan)
    }

    var best: (distance: Double, bearing: Double)?
    let projected = points.map { project($0.0, $0.1, origin: origin) }

    for (a, b) in zip(projected, projected.dropFirst()) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        // Degenerate segment — duplicated node.
        guard lengthSquared > 0 else { continue }

        // Projection of the origin (0,0) onto the segment, clamped to its ends.
        let t = max(0, min(1, -(a.x * dx + a.y * dy) / lengthSquared))
        let closestX = a.x + t * dx
        let closestY = a.y + t * dy
        let distance = (closestX * closestX + closestY * closestY).squareRoot()

        var bearing = atan2(dx, dy) * 180 / .pi
        if bearing < 0 { bearing += 360 }

        if best == nil || distance < best!.distance {
            best = (distance, bearing)
        }
    }
    return best
}

/// Smallest angle between two bearings, treating a road as undirected.
///
/// Modulo 180 rather than 360: travelling north on a north–south road and travelling south on it
/// are both "on that road", so a 180° difference is a perfect match, not the worst possible one.
func headingDelta(_ a: Double, _ b: Double) -> Double {
    var delta = abs(a - b).truncatingRemainder(dividingBy: 180)
    if delta > 90 { delta = 180 - delta }
    return delta
}

// MARK: - Selection

/// Chooses the road you are actually on.
///
/// The problem this solves: a motorway crossing overhead on a bridge sits within the search radius,
/// and the previous implementation simply took whichever way Overpass listed first. Riding a 30 mph
/// road under an M-way therefore announced the motorway and held 70 mph as the limit — poisoning
/// every over/under announcement until the next road change.
///
/// Heading is the discriminator. A road perpendicular to your direction of travel is not one you
/// can be on; a road parallel to it almost certainly is. That also handles the inverse case
/// correctly with no special-casing: when you are *on* the motorway, your course matches it and it
/// wins on the same rule.
///
/// - Parameter course: direction of travel. `nil` when stationary or when CoreLocation reports the
///   course as invalid, in which case selection falls back to distance alone — the best that can be
///   done without knowing which way you face.
public func selectRoad(
    from candidates: [RoadCandidate],
    at position: (Latitude, Longitude),
    course: Course?
) -> RoadCandidate? {
    /// Beyond this a road cannot be the one you are travelling along.
    let headingLimit: Double = 50
    /// Metres of penalty per degree off. Tuned so a 20° misalignment costs about as much as being
    /// 20 m further away — enough for heading to break ties, not enough to pick a distant road.
    let degreeCost: Double = 1.0

    let scored = candidates.compactMap { candidate -> (RoadCandidate, Double)? in
        guard let segment = nearestSegment(to: position, on: candidate.points) else {
            return nil
        }
        guard let course, !segment.bearing.isNaN else {
            // No heading available: nearest wins.
            return (candidate, segment.distance)
        }
        let delta = headingDelta(segment.bearing, course.rawValue)
        guard delta <= headingLimit else { return nil }
        return (candidate, segment.distance + delta * degreeCost)
    }

    return scored.min { $0.1 < $1.1 }?.0
}

/// Builds `RoadInfo` from the chosen candidate.
public func roadInfo(from candidate: RoadCandidate?) -> RoadInfo {
    guard let tags = candidate?.tags else { return .unknown }
    let (limit, resolvedFromNational) = parseLimitAndOrigin(
        maxspeed: tags.maxspeed, highway: tags.highway, maxspeedType: tags.maxspeedType
    )
    return RoadInfo(
        limit: limit, ref: tags.ref, name: tags.name,
        resolvedFromNational: resolvedFromNational,
        isVariable: (tags.maxspeedVariable?.lowercased()).map { $0 != "no" } ?? false
    )
}
