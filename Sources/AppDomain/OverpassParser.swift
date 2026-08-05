import Foundation
import FP

// MARK: - Overpass API response model

public struct OverpassResponse: Decodable, Sendable {
    public struct Element: Decodable, Sendable {
        public struct Tags: Decodable, Sendable {
            public let maxspeed: String?
            public let name: String?
            public let ref: String?
            public let highway: String?
            public let maxspeedType: String?    // OSM key: "maxspeed:type"
            /// OSM key `maxspeed:variable` — smart motorways with gantry signs.
            public let maxspeedVariable: String?

            enum CodingKeys: String, CodingKey {
                case maxspeed, name, ref, highway
                case maxspeedType = "maxspeed:type"
                case maxspeedVariable = "maxspeed:variable"
            }
        }
        public let tags: Tags?
        /// Way shape, present because the query asks for `geom`. Needed to work out which road you
        /// are actually on rather than which one Overpass happened to list first.
        public let geometry: [Point]?

        public struct Point: Decodable, Sendable {
            public let lat: Double
            public let lon: Double
        }
    }
    public let elements: [Element]
}

// MARK: - URL builder (pure)

public func overpassRequest(latitude: Latitude, longitude: Longitude) -> URLRequest {
    // Asks for every `highway` way, not only those tagged `maxspeed`.
    //
    // Filtering on `maxspeed` was actively harmful: ordinary UK roads frequently carry no such tag,
    // so a motorway crossing overhead could be the *only* candidate returned. It was not being
    // preferred over the road below — it was the only thing there. A road with no explicit limit
    // still resolves through `highway` classification.
    //
    // `out geom` brings each way's shape, which is what makes it possible to tell a road you are
    // travelling along from one passing perpendicularly above it. 40 m rather than 30 because
    // selection is now discriminating: a wider net with real filtering beats a narrow one with none.
    let query = "[out:json][timeout:10];way(around:40,\(latitude.rawValue),\(longitude.rawValue))[\"highway\"];out tags geom;"
    let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    // URL construction uses a fixed template with numeric rawValues — cannot fail.
    let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(escaped)")!
    return URLRequest(url: url)
}

// MARK: - Parser (pure)

/// Picks the road you are on and describes it.
///
/// Position and course are needed because the answer genuinely depends on them: several roads can
/// sit within the search radius, and only your direction of travel distinguishes the one beneath
/// your wheels from the one on the bridge above.
public func parseRoadInfo(
    _ response: OverpassResponse,
    at position: (Latitude, Longitude),
    course: Course?
) -> RoadInfo {
    let candidates = response.elements.compactMap { element -> RoadCandidate? in
        guard let tags = element.tags else { return nil }
        return RoadCandidate(
            tags: tags,
            points: (element.geometry ?? []).map { (Latitude($0.lat), Longitude($0.lon)) }
        )
    }
    return roadInfo(from: selectRoad(from: candidates, at: position, course: course))
}

// MARK: - Private helpers

/// Returns the parsed limit together with how it was arrived at.
func parseLimitAndOrigin(
    maxspeed: String?, highway: String?, maxspeedType: String?
) -> (RoadSpeedLimit, LimitOrigin) {
    guard let raw = maxspeed?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
        // No explicit tag does not mean no limit. In the UK an untagged road is subject to the
        // default for its class, and that class is known — so resolve it rather than reporting
        // `.unknown` and losing the over/under announcements entirely.
        return resolveUntagged(highway: highway, maxspeedType: maxspeedType)
    }
    if raw == "national" {
        return resolveUntagged(highway: highway, maxspeedType: maxspeedType)
    }
    let parts = raw.components(separatedBy: " ")
    guard let value = Double(parts[0]) else { return (.unknown, .unattributed) }
    let isKph = parts.count > 1 && parts[1].hasPrefix("km")
    let mph = isKph ? Iso<MPH, KPH>.convert.reverseGet(KPH(value)) : MPH(value)
    return (.value(mph), .signed)
}

/// Resolves the limit for a road with no usable `maxspeed`, and says which default was applied.
///
/// Three tiers: 70 dual/motorway, 60 rural single carriageway, 30 built-up. The first two are the
/// *national speed limit*; the third is not, and keeping them apart is the whole point of returning
/// an origin rather than a boolean — see `LimitOrigin`.
///
/// Priority: `maxspeed:type` > `highway` classification > `.national` (truly ambiguous).
private func resolveUntagged(
    highway: String?, maxspeedType: String?
) -> (RoadSpeedLimit, LimitOrigin) {
    // maxspeed:type is the most authoritative — set by mappers who know the exact context.
    if let type = maxspeedType?.lowercased() {
        switch type {
        case "gb:motorway", "gb:nsl_dual": return (.value(MPH(70)), .nationalSpeedLimit)
        case "gb:nsl_single": return (.value(MPH(60)), .nationalSpeedLimit)
        case "gb:urban", "gb:living_street": return (.value(MPH(30)), .builtUpArea)
        default: break
        }
    }
    let resolved: (RoadSpeedLimit, LimitOrigin) = switch highway?.lowercased() {
    case "motorway", "motorway_link":
        (.value(MPH(70)), .nationalSpeedLimit)
    case "trunk":
        (.value(MPH(70)), .nationalSpeedLimit)   // dual carriageway
    case "primary", "primary_link",
         "secondary", "secondary_link",
         "tertiary", "tertiary_link":
        (.value(MPH(60)), .nationalSpeedLimit)   // rural single carriageway
    case "residential", "unclassified",
         "living_street", "service":
        (.value(MPH(30)), .builtUpArea)
    default:
        (.national, .unattributed)               // genuinely ambiguous — beep at 30, 60 and 70
    }
    return resolved
}
