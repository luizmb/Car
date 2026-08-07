import AppDomain
import FP
import Foundation
import ReactiveConcurrency
import SQLite3

/// Roads, limits and cameras from a file on the phone.
///
/// The primary source, with Overpass as the fallback rather than the foundation. Two consecutive
/// rides produced **no speed limits at all** because every request was refused — measured on
/// 2026-08-06 as five 429s in ten consecutive queries, with refusals taking 7–12 seconds to come
/// back while successes took one or two.
///
/// A local answer takes microseconds, needs no radio, cannot be rate-limited, and works in a valley
/// with no signal. It is also the only version of this that respects the battery plan: a road change
/// no longer means waking the cellular radio.
///
/// **Not a replacement.** The extract is a snapshot and OSM moves; Overpass still answers for
/// anything the file lacks, and remains the way the file is refreshed.
final class LocalRoadStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    /// Where the extract actually has data.
    ///
    /// Not decoration, and the reason cameras can be served from here at all: outside the extract,
    /// "no cameras near here" and "no data for here" are the same empty result. Roads do not need
    /// this — there is always a road underneath you, so an empty answer is self-evidently a miss —
    /// but an empty camera set is a perfectly ordinary correct answer, and acting on it in France
    /// would silently disarm every warning.
    ///
    /// `nil` for an extract built before the `meta` table existed. Reading that as "covers nothing"
    /// is the safe direction: roads still come from the file, and cameras go back to the network.
    private let bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?
    /// Whether this extract's cameras know which road they stand beside (v4 onwards).
    private let camerasCarryRoads: Bool
    /// Whether this extract's roads carry the `lit` tag (v5 onwards) — the difference between an
    /// untagged urban primary resolving to 30 (restricted road: lamps, no signs) and to a
    /// fictitious "national 60".
    private let roadsCarryLit: Bool

    /// The extract, if one has been put in Documents. Absent is normal and not an error — the app
    /// simply falls through to Overpass, which is what it did before this existed.
    static let filename = "roads.sqlite"

    private static var url: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    /// The extract in Documents, if the rider has put one there.
    convenience init?() { self.init(url: Self.url) }

    /// A specific file. Exists so the query logic can be tested against a fixture — everything this
    /// type decides (which road, whether a camera set can be trusted, which forecourt) is decided
    /// here rather than in the domain, so it needs to be reachable without a 500 MB file on a phone.
    init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        // Read-only: nothing in the app ever writes to it, and saying so lets SQLite skip its
        // locking machinery entirely.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        handle = db
        bounds = Self.readBounds(db)
        // Whether cameras carry their road — the v4 extract does, earlier ones do not, and asking
        // an old file for columns it lacks is an SQL error rather than an empty answer. Detected
        // once so every query afterwards knows which world it lives in.
        var statement: OpaquePointer?
        var hasRoads = false
        if sqlite3_prepare_v2(db, "SELECT road_ref FROM camera LIMIT 1", -1, &statement, nil) == SQLITE_OK {
            hasRoads = true
        }
        sqlite3_finalize(statement)
        camerasCarryRoads = hasRoads
        var litStatement: OpaquePointer?
        var hasLit = false
        if sqlite3_prepare_v2(db, "SELECT lit FROM road LIMIT 1", -1, &litStatement, nil) == SQLITE_OK {
            hasLit = true
        }
        sqlite3_finalize(litStatement)
        roadsCarryLit = hasLit
    }

    deinit { sqlite3_close(handle) }

    /// Whether the extract has data for a position, and therefore whether an empty answer from it
    /// can be believed.
    func covers(latitude: Latitude, longitude: Longitude) -> Bool {
        guard let bounds else { return false }
        return latitude.rawValue >= bounds.minLat && latitude.rawValue <= bounds.maxLat
            && longitude.rawValue >= bounds.minLon && longitude.rawValue <= bounds.maxLon
    }

    private static func readBounds(
        _ db: OpaquePointer?
    ) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        var values: [String: Double] = [:]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM meta", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let key = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                let raw = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                let value = Double(raw)
            else { continue }
            values[key] = value
        }
        guard
            let minLat = values["minlat"], let maxLat = values["maxlat"],
            let minLon = values["minlon"], let maxLon = values["maxlon"]
        else { return nil }
        return (minLat, maxLat, minLon, maxLon)
    }

    /// The road at a position, chosen by the same rules the Overpass path uses.
    ///
    /// The R-tree is queried with a small box rather than a radius: it is an index over bounding
    /// boxes, so it answers "which roads could possibly be near here" cheaply, and the precise
    /// perpendicular-distance work happens afterwards on the handful that survive.
    func road(at latitude: Latitude, longitude: Longitude, course: Course?) -> RoadInfo? {
        let candidates = self.candidates(latitude: latitude, longitude: longitude)
        guard !candidates.isEmpty else { return nil }
        let chosen = selectRoad(from: candidates, at: (latitude, longitude), course: course)
        guard chosen != nil else { return nil }
        return roadInfo(from: chosen, among: candidates)
    }

    /// Every camera and average-speed zone within `radius` metres.
    ///
    /// `nil` — not an empty set — when the position falls outside the extract, so the caller can
    /// tell "there is nothing here" from "I do not know about here" and go to the network for the
    /// second. An empty `CameraSet` from inside the bounds is a real answer and means exactly what
    /// it says.
    ///
    /// Cameras and zones are returned together for the same reason the Overpass query fetches them
    /// in one request: they are two halves of one picture, and a set where they disagree about what
    /// is currently known would announce a zone whose cameras are missing, or the reverse.
    func cameraSet(near latitude: Latitude, longitude: Longitude, radius: Meters) -> CameraSet? {
        guard covers(latitude: latitude, longitude: longitude) else { return nil }
        let box = boundingBox(latitude: latitude, longitude: longitude, radius: radius)
        return CameraSet(cameras: cameras(in: box), zones: zones(in: box))
    }

    /// The cameras standing on one particular road, near a position.
    ///
    /// The rider's design, verbatim: *"we query the database for the road we just joined for its
    /// cameras along the way"*. Which road a camera belongs to was settled at extract time by
    /// geometry — so the runtime question is a string match, not a distance one, and the slip-road
    /// cameras that share the rider's ref are excluded by the one thing that separates them: class.
    ///
    /// `nil` — not empty — when this extract predates road attachment or the position is outside
    /// it, so the caller can fall back to the radius set rather than believing a silence.
    func cameras(on key: RoadKey, near latitude: Latitude, longitude: Longitude) -> [SpeedCamera]? {
        guard camerasCarryRoads, covers(latitude: latitude, longitude: longitude) else { return nil }
        guard let classIndex = classNames.firstIndex(of: key.roadClass) else { return nil }
        // A generous reach along the road, tiny against the 50 km radius set: a journey's worth of
        // one road, refreshed every time the road changes.
        let box = boundingBox(latitude: latitude, longitude: longitude, radius: Meters(20_000))
        var found: [SpeedCamera] = []
        query(
            """
            SELECT c.id, c.kind, c.mph, c.direction, c.lat, c.lon, c.road_ref, c.road_name
            FROM camera_bbox b JOIN camera c ON c.id = b.id
            WHERE b.maxlat >= ? AND b.minlat <= ? AND b.maxlon >= ? AND b.minlon <= ?
              AND c.road_class = ?
            """,
            bind: box.rtree + [Double(classIndex)]
        ) { statement in
            // The string half of the match, done here rather than in SQL so ref-or-name fallback
            // stays in one visible place: the ref identifies a road where it exists, and plenty of
            // residential streets carry only a name.
            let ref = text(statement, 6)
            let name = text(statement, 7)
            let sameRoad: Bool = if let keyRef = key.ref, let ref {
                keyRef == ref
            } else if let keyName = key.name, let name {
                keyName == name
            } else {
                false
            }
            guard sameRoad else { return }
            found.append(SpeedCamera(
                id: Int(sqlite3_column_int64(statement, 0)),
                kind: kind(from: text(statement, 1)),
                latitude: Latitude(sqlite3_column_double(statement, 4)),
                longitude: Longitude(sqlite3_column_double(statement, 5)),
                limit: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil : MPH(Double(sqlite3_column_int(statement, 2))),
                direction: sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 3)
            ))
        }
        return found
    }

    /// The nearest petrol station within `radius` metres.
    ///
    /// Nearest rather than first, matching ``nearestStation(_:to:)``: paired forecourts either side
    /// of a road and motorway services both return several, and the one being filled from is the
    /// one underfoot.
    ///
    /// No coverage check, unlike ``cameraSet(near:longitude:radius:)``. A miss here simply falls
    /// through to the network, which is the right behaviour whether the cause is riding abroad or a
    /// forecourt that opened after the extract was built — and it costs one request, made once,
    /// while the rider is stationary at a pump.
    func station(near latitude: Latitude, longitude: Longitude, radius: Meters) -> FuelStation? {
        let box = boundingBox(latitude: latitude, longitude: longitude, radius: radius)
        var best: (FuelStation, Double)?
        query(
            """
            SELECT s.id, s.name, s.brand, s.lat, s.lon
            FROM station_bbox b JOIN station s ON s.id = b.id
            WHERE b.maxlat >= ? AND b.minlat <= ? AND b.maxlon >= ? AND b.minlon <= ?
            """,
            bind: box.rtree
        ) { statement in
            let position = (
                Latitude(sqlite3_column_double(statement, 3)),
                Longitude(sqlite3_column_double(statement, 4))
            )
            let station = FuelStation(
                id: Int(sqlite3_column_int64(statement, 0)),
                // `brand` is the tag that means the operator, and the extractor already folded
                // `operator` into it, so there is one column here where Overpass has two.
                brand: text(statement, 2),
                name: text(statement, 1)
            )
            let distance = distanceMetres(from: (latitude, longitude), to: position)
            guard distance <= radius.rawValue else { return }
            if best.map({ distance < $0.1 }) ?? true { best = (station, distance) }
        }
        return best?.0
    }

    // MARK: - Private

    private struct BoundingBox {
        let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
        /// In the order an R-tree overlap test binds them: `maxlat >= minLat`, `minlat <= maxLat`, …
        var rtree: [Double] { [minLat, maxLat, minLon, maxLon] }
        /// In the order a plain `BETWEEN` pair binds them.
        var between: [Double] { [minLat, maxLat, minLon, maxLon] }
    }

    private func boundingBox(
        latitude: Latitude, longitude: Longitude, radius: Meters
    ) -> BoundingBox {
        let pad = radius.rawValue / 111_320
        // Longitude degrees shrink toward the poles. At 52° N a degree of longitude is about 69 km
        // against 111 km of latitude, so a box padded equally in both would reach barely half as
        // far east and west as it should.
        let lonPad = pad / cos(latitude.rawValue * .pi / 180)
        return BoundingBox(
            minLat: latitude.rawValue - pad, maxLat: latitude.rawValue + pad,
            minLon: longitude.rawValue - lonPad, maxLon: longitude.rawValue + lonPad
        )
    }

    private func cameras(in box: BoundingBox) -> [SpeedCamera] {
        var found: [SpeedCamera] = []
        query(
            """
            SELECT c.id, c.kind, c.mph, c.direction, c.lat, c.lon
            FROM camera_bbox b JOIN camera c ON c.id = b.id
            WHERE b.maxlat >= ? AND b.minlat <= ? AND b.maxlon >= ? AND b.minlon <= ?
            """,
            bind: box.rtree
        ) { statement in
            found.append(SpeedCamera(
                id: Int(sqlite3_column_int64(statement, 0)),
                kind: kind(from: text(statement, 1)),
                latitude: Latitude(sqlite3_column_double(statement, 4)),
                longitude: Longitude(sqlite3_column_double(statement, 5)),
                limit: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil : MPH(Double(sqlite3_column_int(statement, 2))),
                direction: sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 3)
            ))
        }
        return found
    }

    /// Zones touching the box by either end.
    ///
    /// Either end, not just the start: a zone entered before the last fetch is one whose *exit* is
    /// the only thing still ahead, and dropping it would leave the rider inside an average check
    /// with no way to be told it had ended.
    private func zones(in box: BoundingBox) -> [AverageZone] {
        var found: [AverageZone] = []
        query(
            """
            SELECT id, mph, start_lat, start_lon, end_lat, end_lon FROM zone
            WHERE (start_lat BETWEEN ? AND ? AND start_lon BETWEEN ? AND ?)
               OR (end_lat   BETWEEN ? AND ? AND end_lon   BETWEEN ? AND ?)
            """,
            bind: box.between + box.between
        ) { statement in
            func coordinate(_ latColumn: Int32, _ lonColumn: Int32) -> Coordinate? {
                guard
                    sqlite3_column_type(statement, latColumn) != SQLITE_NULL,
                    sqlite3_column_type(statement, lonColumn) != SQLITE_NULL
                else { return nil }
                return Coordinate(
                    latitude: Latitude(sqlite3_column_double(statement, latColumn)),
                    longitude: Longitude(sqlite3_column_double(statement, lonColumn))
                )
            }
            found.append(AverageZone(
                id: Int(sqlite3_column_int64(statement, 0)),
                limit: sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil : MPH(Double(sqlite3_column_int(statement, 1))),
                start: coordinate(2, 3),
                end: coordinate(4, 5)
            ))
        }
        return found
    }

    /// Roads whose bounding box is within ~120 m. Wider than the 40 m Overpass query on purpose: a
    /// bounding box is a coarse thing, and a long diagonal road can be close to you while its box
    /// suggests otherwise.
    private func candidates(latitude: Latitude, longitude: Longitude) -> [RoadCandidate] {
        let pad = 120.0 / 111_320
        let lonPad = pad / cos(latitude.rawValue * .pi / 180)
        var candidates: [RoadCandidate] = []

        // The v5 extract carries `lit`; asking an older file for it would be an SQL error, not an
        // empty column, so the query itself has two shapes.
        let litColumn = roadsCarryLit ? ", r.lit" : ""
        query(
            """
            SELECT r.name, r.ref, r.class, r.mph, r.geom\(litColumn)
            FROM road_bbox b JOIN road r ON r.id = b.id
            WHERE b.maxlat >= ? AND b.minlat <= ? AND b.maxlon >= ? AND b.minlon <= ?
            LIMIT 200
            """,
            bind: [
                latitude.rawValue - pad, latitude.rawValue + pad,
                longitude.rawValue - lonPad, longitude.rawValue + lonPad
            ]
        ) { statement in
            guard let blob = sqlite3_column_blob(statement, 4) else { return }
            let bytes = Int(sqlite3_column_bytes(statement, 4))
            let points = decode(Data(bytes: blob, count: bytes))
            guard points.count >= 2 else { return }

            let mph: String? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : "\(sqlite3_column_int(statement, 3)) mph"
            // Stored as 1 / 0 / NULL; the domain speaks OSM's dialect, so it crosses back as
            // "yes" / "no" / absent.
            let lit: String? = !roadsCarryLit || sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : (sqlite3_column_int(statement, 5) != 0 ? "yes" : "no")

            candidates.append(RoadCandidate(
                tags: OverpassResponse.Element.Tags(
                    maxspeed: mph,
                    name: text(statement, 0),
                    ref: text(statement, 1),
                    highway: className(Int(sqlite3_column_int(statement, 2))),
                    maxspeedType: nil,
                    maxspeedVariable: nil,
                    lit: lit
                ),
                points: points
            ))
        }
        return candidates
    }

    private func query(_ sql: String, bind: [Double], each: (OpaquePointer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_double(statement, Int32(index + 1), value)
        }
        while sqlite3_step(statement) == SQLITE_ROW, let statement { each(statement) }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

// MARK: - Encoding

/// Coordinates are packed as `int32` at 1e-7 degrees — about a centimetre, far finer than GPS, and
/// half the size of the doubles a GeoPackage would store. Geometry is three quarters of the file, so
/// this is the difference between shipping it and not.
private func decode(_ data: Data) -> [(Latitude, Longitude)] {
    var points: [(Latitude, Longitude)] = []
    points.reserveCapacity(data.count / 8)
    data.withUnsafeBytes { raw in
        let count = raw.count / 8
        for index in 0..<count {
            let lat = raw.loadUnaligned(fromByteOffset: index * 8, as: Int32.self)
            let lon = raw.loadUnaligned(fromByteOffset: index * 8 + 4, as: Int32.self)
            points.append((Latitude(Double(lat) / 1e7), Longitude(Double(lon) / 1e7)))
        }
    }
    return points
}

/// The class names, in the order the extractor assigned them — sorted, so the mapping is derivable
/// rather than remembered. They must match `isRideable`, since selection depends on them.
private let classNames = [
    "living_street", "motorway", "motorway_link", "primary", "primary_link",
    "residential", "road", "secondary", "secondary_link", "service",
    "tertiary", "tertiary_link", "track", "trunk", "trunk_link", "unclassified"
]

private func className(_ index: Int) -> String? {
    classNames.indices.contains(index) ? classNames[index] : nil
}

private func kind(from raw: String?) -> CameraKind {
    switch raw {
    case "average": .average
    case "redLight": .redLight
    case "mobile": .mobile
    case "fixed": .fixed
    default: .unknown
    }
}
