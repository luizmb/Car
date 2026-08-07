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

    /// The extract, if one has been put in Documents. Absent is normal and not an error — the app
    /// simply falls through to Overpass, which is what it did before this existed.
    static let filename = "roads.sqlite"

    private static var url: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    init?() {
        guard FileManager.default.fileExists(atPath: Self.url.path) else { return nil }
        var db: OpaquePointer?
        // Read-only: nothing in the app ever writes to it, and saying so lets SQLite skip its
        // locking machinery entirely.
        guard sqlite3_open_v2(Self.url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        handle = db
    }

    deinit { sqlite3_close(handle) }

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

    /// Cameras within `radius` metres.
    func cameras(near latitude: Latitude, longitude: Longitude, radius: Meters) -> [SpeedCamera] {
        let degrees = radius.rawValue / 111_320
        var found: [SpeedCamera] = []
        query(
            "SELECT id, kind, mph, lat, lon FROM camera WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?",
            bind: [
                latitude.rawValue - degrees, latitude.rawValue + degrees,
                longitude.rawValue - degrees / cos(latitude.rawValue * .pi / 180),
                longitude.rawValue + degrees / cos(latitude.rawValue * .pi / 180)
            ]
        ) { statement in
            found.append(SpeedCamera(
                id: Int(sqlite3_column_int64(statement, 0)),
                kind: kind(from: text(statement, 1)),
                latitude: Latitude(sqlite3_column_double(statement, 3)),
                longitude: Longitude(sqlite3_column_double(statement, 4)),
                limit: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil : MPH(Double(sqlite3_column_int(statement, 2))),
                direction: nil
            ))
        }
        return found
    }

    // MARK: - Private

    /// Roads whose bounding box is within ~120 m. Wider than the 40 m Overpass query on purpose: a
    /// bounding box is a coarse thing, and a long diagonal road can be close to you while its box
    /// suggests otherwise.
    private func candidates(latitude: Latitude, longitude: Longitude) -> [RoadCandidate] {
        let pad = 120.0 / 111_320
        let lonPad = pad / cos(latitude.rawValue * .pi / 180)
        var candidates: [RoadCandidate] = []

        query(
            """
            SELECT r.name, r.ref, r.class, r.mph, r.geom
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

            candidates.append(RoadCandidate(
                tags: OverpassResponse.Element.Tags(
                    maxspeed: mph,
                    name: text(statement, 0),
                    ref: text(statement, 1),
                    highway: className(Int(sqlite3_column_int(statement, 2))),
                    maxspeedType: nil,
                    maxspeedVariable: nil
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
