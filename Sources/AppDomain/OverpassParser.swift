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

            enum CodingKeys: String, CodingKey {
                case maxspeed, name, ref, highway
                case maxspeedType = "maxspeed:type"
            }
        }
        public let tags: Tags?
    }
    public let elements: [Element]
}

// MARK: - URL builder (pure)

public func overpassRequest(latitude: Latitude, longitude: Longitude) -> URLRequest {
    let query = "[out:json][timeout:10];way(around:30,\(latitude.rawValue),\(longitude.rawValue))[\"maxspeed\"];out tags;"
    let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    // URL construction uses a fixed template with numeric rawValues — cannot fail.
    let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(escaped)")!
    return URLRequest(url: url)
}

// MARK: - Parser (pure)

public func parseRoadInfo(_ response: OverpassResponse) -> RoadInfo {
    guard let tags = response.elements.compactMap({ $0.tags }).first else {
        return .unknown
    }
    let (limit, resolvedFromNational) = parseLimitAndOrigin(
        maxspeed:     tags.maxspeed,
        highway:      tags.highway,
        maxspeedType: tags.maxspeedType
    )
    return RoadInfo(
        limit: limit,
        ref:   tags.ref,
        name:  tags.name,
        resolvedFromNational: resolvedFromNational
    )
}

// MARK: - Private helpers

/// Returns the parsed limit and whether it was resolved from a `national` tag.
private func parseLimitAndOrigin(maxspeed: String?, highway: String?, maxspeedType: String?) -> (RoadSpeedLimit, Bool) {
    guard let raw = maxspeed?.lowercased().trimmingCharacters(in: .whitespaces) else {
        return (.unknown, false)
    }
    if raw == "national" {
        let resolved = resolveNational(highway: highway, maxspeedType: maxspeedType)
        let wasResolved = resolved != .national
        return (resolved, wasResolved)
    }
    let parts = raw.components(separatedBy: " ")
    guard let value = Double(parts[0]) else { return (.unknown, false) }
    let isKph = parts.count > 1 && parts[1].hasPrefix("km")
    let mph   = isKph ? Iso<MPH, KPH>.convert.reverseGet(KPH(value)) : MPH(value)
    return (.value(mph), false)
}

/// Resolves the UK national speed limit.
/// Three tiers: 70 dual/motorway, 60 rural single carriageway, 30 urban.
/// Priority: maxspeed:type > highway classification > .national (truly ambiguous).
private func resolveNational(highway: String?, maxspeedType: String?) -> RoadSpeedLimit {
    // maxspeed:type is the most authoritative — set by mappers who know the exact context
    if let type = maxspeedType?.lowercased() {
        switch type {
        case "gb:motorway", "gb:nsl_dual":   return .value(MPH(70))
        case "gb:nsl_single":                return .value(MPH(60))
        case "gb:urban", "gb:living_street": return .value(MPH(30))
        default: break
        }
    }
    // Fall back to highway classification
    switch highway?.lowercased() {
    case "motorway", "motorway_link":
        return .value(MPH(70))
    case "trunk":
        return .value(MPH(70))   // dual carriageway
    case "primary", "primary_link",
         "secondary", "secondary_link",
         "tertiary", "tertiary_link":
        return .value(MPH(60))   // rural single carriageway
    case "residential", "unclassified",
         "living_street", "service":
        return .value(MPH(30))   // urban
    default:
        return .national         // genuinely ambiguous — beep at 30, 60 and 70
    }
}
