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

            /// Public so the on-device extract can build candidates without going through JSON.
            /// The local store answers the same question from a file, and reusing this type means
            /// selection runs identical code either way rather than a parallel implementation that
            /// can drift.
            public init(
                maxspeed: String?, name: String?, ref: String?, highway: String?,
                maxspeedType: String? = nil, maxspeedVariable: String? = nil
            ) {
                self.maxspeed = maxspeed
                self.name = name
                self.ref = ref
                self.highway = highway
                self.maxspeedType = maxspeedType
                self.maxspeedVariable = maxspeedVariable
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

// MARK: - Endpoints

/// Which Overpass server a query goes to.
///
/// Overpass rate-limits **per IP across all queries**, so one expensive query can have every other
/// request from the same phone refused — which is exactly what happened on 2026-08-06. The road
/// lookup had run happily on cellular for a month; the day the camera query shipped, the road
/// resolved once at launch and then never again for an hour, and a station lookup on a completely
/// unrelated code path failed too.
///
/// Splitting the hosts is what makes that impossible rather than unlikely: the camera query can trip
/// a limiter as often as it likes and the road lookup, which everything else depends on, is
/// unaffected.
public struct OverpassEndpoint: Sendable, Equatable {
    /// Full interpreter URLs, tried in order.
    ///
    /// URLs rather than hostnames because mirrors do not agree on the path — Mail.ru's sits under
    /// `/osm/tools/overpass/api/interpreter`, not `/api/interpreter`.
    ///
    /// More than one because a single host is a single point of failure, and both of its failure
    /// modes turned up in one afternoon: `overpass-api.de` first rate-limited us with 429s, then
    /// stopped accepting connections at all — from an unrelated machine as well as from the phone.
    ///
    /// **A mirror must serve the planet.** `overpass.osm.ch` was tried and is the *Swiss* regional
    /// instance: it answers a UK query with HTTP 200 and zero elements, which reads downstream as
    /// "no road here" rather than as a failure. A status code is not evidence that a mirror has your
    /// data, and checking one without the other is how that got shipped.
    public let urls: [String]

    public init(urls: [String]) { self.urls = urls }

    /// Identifies the app to Overpass, with a way to reach whoever is responsible for it — which is
    /// the point of the header, not the string itself.
    static let userAgent = "SpeedJarvis/1.0 (+https://github.com/luizmb/Car) motorcycle-speed-assistant"

    static let canonical = "https://overpass-api.de/api/interpreter"
    /// Andy Townsend's Britain-and-Ireland instance. **IPv6 only**, which is why it looked dead from
    /// an IPv4-only machine — the AAAA record resolves fine and the host was never down.
    static let britain = "https://overpass.atownsend.org.uk/api/interpreter"

    /// Roads and stations.
    ///
    /// One URL, not a chain. `overpass.private.coffee` was tried as a second mirror and does not
    /// refuse: it **hangs for thirty seconds** before timing out, so a failing first attempt meant
    /// the rider waited over half a minute before anything at all happened. A fallback that slow is
    /// worse than none, because the useful fallback — asking Apple for the street name — was stuck
    /// behind it.
    ///
    /// `overpass-api.de` is itself DNS round-robin over two servers (`gall` and `lambert`) with
    /// independent rate limits, and the project asks that they not be addressed individually except
    /// to work around one being broken. So: use the round-robin name, fail fast, and fall back to a
    /// different *kind* of answer rather than to another Overpass.
    /// The canonical endpoint first, Britain second.
    ///
    /// Britain was tried first on the theory that a regional instance would be faster. It was not:
    /// it failed on every attempt, on both Wi-Fi and cellular, because neither routes IPv6. Ordering
    /// an endpoint first because it *ought* to be better, when the evidence says it never answers,
    /// costs a DNS lookup and a connection attempt on every single road change — which means waking
    /// the radio, on an app whose entire battery strategy is about not doing that.
    ///
    /// It stays second because it would be the better source the day IPv6 appears, and second costs
    /// nothing until the first has already failed.
    public static let primary = OverpassEndpoint(urls: [canonical, britain])

    /// Cameras stay on the canonical endpoint.
    ///
    /// Deliberately *not* the Britain instance: it is one person's server with a usage policy I have
    /// not read, and the camera query is the heavy one — a 3 km radius pulling relation geometry
    /// every kilometre. Putting our expensive traffic on someone's personal machine while taking the
    /// cheap query for ourselves would be poor manners.
    public static let cameras = OverpassEndpoint(urls: [canonical])

    /// Percent-encoded, with a template that cannot fail to parse.
    public func request(_ query: String, hostIndex: Int = 0) -> URLRequest {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let base = urls[min(hostIndex, urls.count - 1)]
        var request = URLRequest(url: URL(string: "\(base)?data=\(escaped)")!)
        // Six seconds, not the default sixty. A road name that arrives a minute later is useless —
        // by then the rider is on a different road — and every second spent waiting is a second the
        // Apple fallback is not being asked.
        request.timeoutInterval = 6
        // Overpass asks that apps identify themselves, and the default `URLSession` agent does not.
        // Beyond being what they ask for, it is in our interest: identified traffic can be accounted
        // to *this app* rather than to whatever else shares the phone's address — and on a carrier
        // that address is shared with thousands of other subscribers.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}

// MARK: - URL builder (pure)

public func overpassRequest(
    latitude: Latitude, longitude: Longitude,
    endpoint: OverpassEndpoint = .primary,
    hostIndex: Int = 0
) -> URLRequest {
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
    return endpoint.request(query, hostIndex: hostIndex)
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
    return roadInfo(from: selectRoad(from: candidates, at: position, course: course), among: candidates)
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
    guard let mph = parseMaxspeedMPH(raw) else { return (.unknown, .unattributed) }
    return (.value(mph), .signed)
}

/// An OSM `maxspeed` value as mph — `"30 mph"`, `"30"`, `"80 km/h"`.
///
/// Shared with the speed-camera parser, where an enforcement relation carries its own `maxspeed`
/// that may differ from the road's. `nil` for `national` and anything unparseable, since those need
/// classification context this function does not have.
func parseMaxspeedMPH(_ raw: String?) -> MPH? {
    guard
        let raw = raw?.lowercased().trimmingCharacters(in: .whitespaces),
        !raw.isEmpty
    else { return nil }

    let parts = raw.components(separatedBy: " ")
    guard let value = Double(parts[0]) else { return nil }
    // OSM's default unit is km/h; mph is always explicit, which is why the check is for "km" rather
    // than for "mph".
    let isKph = parts.count > 1 && parts[1].hasPrefix("km")
    return isKph ? Iso<MPH, KPH>.convert.reverseGet(KPH(value)) : MPH(value)
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
