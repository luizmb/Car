import AppDomain
import Foundation
import SQLite3
import Testing
@testable import AppCore

// The store decides whether a warning happens at all, and it decides it from a file nobody reads.
// A wrong answer here is silent by construction: no crash, no log line, just a ride where nothing
// was said. So these tests build real extracts — the same schema `extract.py` writes — and ask the
// real queries.

// MARK: - Fixtures

/// Writes a throwaway extract and hands back its URL.
///
/// `bounds` is `nil` for the shape of an extract built before the `meta` table existed, which is a
/// case that has to keep working: one is on the rider's phone right now.
private func makeExtract(
    bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?
        = (51.0, 53.0, -1.0, 1.0),
    cameras: [(id: Int, kind: String, mph: Int?, direction: Double?, lat: Double, lon: Double)] = [],
    zones: [(id: Int, mph: Int?, start: (Double, Double)?, end: (Double, Double)?)] = [],
    stations: [(id: Int, name: String?, brand: String?, lat: Double, lon: Double)] = []
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("extract-\(UUID().uuidString).sqlite")

    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }

    func run(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        if status != SQLITE_OK, let error {
            Issue.record("SQL failed: \(String(cString: error))")
            sqlite3_free(error)
        }
    }

    run("""
        CREATE TABLE road (id INTEGER PRIMARY KEY, name TEXT, ref TEXT, class INTEGER, mph INTEGER,
                           minlat REAL, maxlat REAL, minlon REAL, maxlon REAL, geom BLOB);
        CREATE TABLE camera (id INTEGER PRIMARY KEY, kind TEXT, mph INTEGER, direction REAL,
                             lat REAL, lon REAL);
        CREATE TABLE zone (id INTEGER PRIMARY KEY, mph INTEGER,
                           start_lat REAL, start_lon REAL, end_lat REAL, end_lon REAL);
        CREATE TABLE station (id INTEGER PRIMARY KEY, name TEXT, brand TEXT, lat REAL, lon REAL);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE VIRTUAL TABLE road_bbox USING rtree(id, minlat, maxlat, minlon, maxlon);
        CREATE VIRTUAL TABLE camera_bbox USING rtree(id, minlat, maxlat, minlon, maxlon);
        CREATE VIRTUAL TABLE station_bbox USING rtree(id, minlat, maxlat, minlon, maxlon);
        """)

    if let bounds {
        run("""
            INSERT INTO meta (key, value) VALUES
              ('minlat','\(bounds.minLat)'), ('maxlat','\(bounds.maxLat)'),
              ('minlon','\(bounds.minLon)'), ('maxlon','\(bounds.maxLon)');
            """)
    }

    for camera in cameras {
        let mph = camera.mph.map { "\($0)" } ?? "NULL"
        let direction = camera.direction.map { "\($0)" } ?? "NULL"
        let (id, kind, lat, lon) = (camera.id, camera.kind, camera.lat, camera.lon)
        run("""
            INSERT INTO camera (id, kind, mph, direction, lat, lon)
              VALUES (\(id), '\(kind)', \(mph), \(direction), \(lat), \(lon));
            INSERT INTO camera_bbox VALUES (\(id), \(lat), \(lat), \(lon), \(lon));
            """)
    }

    for zone in zones {
        let mph = zone.mph.map { "\($0)" } ?? "NULL"
        let startLat = zone.start.map { "\($0.0)" } ?? "NULL"
        let startLon = zone.start.map { "\($0.1)" } ?? "NULL"
        let endLat = zone.end.map { "\($0.0)" } ?? "NULL"
        let endLon = zone.end.map { "\($0.1)" } ?? "NULL"
        run("""
            INSERT INTO zone (id, mph, start_lat, start_lon, end_lat, end_lon)
              VALUES (\(zone.id), \(mph), \(startLat), \(startLon), \(endLat), \(endLon));
            """)
    }

    for station in stations {
        let name = station.name.map { "'\($0)'" } ?? "NULL"
        let brand = station.brand.map { "'\($0)'" } ?? "NULL"
        let (id, lat, lon) = (station.id, station.lat, station.lon)
        run("""
            INSERT INTO station (id, name, brand, lat, lon)
              VALUES (\(id), \(name), \(brand), \(lat), \(lon));
            INSERT INTO station_bbox VALUES (\(id), \(lat), \(lat), \(lon), \(lon));
            """)
    }

    return url
}

// A point comfortably inside the fixture's bounds, and one nowhere near them.
private let bedford = (Latitude(52.13), Longitude(-0.46))
private let calais = (Latitude(50.95), Longitude(1.85))

// MARK: - Coverage

@Suite("Local extract coverage")
struct LocalExtractCoverageTests {
    @Test("A position inside the extract is covered")
    func covered() throws {
        let store = try #require(LocalRoadStore(url: makeExtract()))
        #expect(store.covers(latitude: bedford.0, longitude: bedford.1))
    }

    @Test("A position outside the extract is not covered")
    func notCovered() throws {
        let store = try #require(LocalRoadStore(url: makeExtract()))
        #expect(!store.covers(latitude: calais.0, longitude: calais.1))
    }

    /// The extract already on the phone has no `meta` table. It must degrade to "covers nothing"
    /// rather than to "covers everywhere" — the second would answer France from an English file and
    /// report no cameras at all.
    @Test("An extract with no bounds covers nothing")
    func noMeta() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(bounds: nil)))
        #expect(!store.covers(latitude: bedford.0, longitude: bedford.1))
        #expect(store.cameraSet(near: bedford.0, longitude: bedford.1, radius: Meters(50_000)) == nil)
    }
}

// MARK: - Cameras

@Suite("Cameras from the extract")
struct LocalCameraTests {
    /// The distinction the whole coverage check exists for: outside the extract the answer is `nil`,
    /// which sends the caller to the network. Returning an empty set here would silently disarm
    /// every warning for a whole ride abroad.
    @Test("Outside the extract the answer is unknown, not empty")
    func outsideIsNil() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(
            cameras: [(1, "fixed", 30, nil, 52.13, -0.46)]
        )))
        #expect(store.cameraSet(near: calais.0, longitude: calais.1, radius: Meters(50_000)) == nil)
    }

    /// The other half of it: inside the extract, nothing nearby is a real answer and is used as one.
    @Test("Inside the extract an empty result is an answer")
    func insideIsEmpty() throws {
        let store = try #require(LocalRoadStore(url: makeExtract()))
        let found = store.cameraSet(near: bedford.0, longitude: bedford.1, radius: Meters(1_000))
        #expect(found == CameraSet.empty)
    }

    @Test("Cameras within the radius come back with their kind, limit and direction")
    func cameraFields() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(
            cameras: [(42, "average", 50, 135.0, 52.13, -0.46)]
        )))
        let found = try #require(store.cameraSet(
            near: bedford.0, longitude: bedford.1, radius: Meters(1_000)
        ))
        let camera = try #require(found.cameras.first)
        #expect(found.cameras.count == 1)
        #expect(camera.id == 42)
        #expect(camera.kind == .average)
        #expect(camera.limit == MPH(50))
        #expect(camera.direction == 135)
    }

    /// Most cameras carry neither, and a missing `maxspeed` must arrive as "unknown" rather than as
    /// zero — a camera announced as a 0 mph limit is worse than one announced with no limit at all.
    @Test("A camera with no limit or direction reads as absent, not zero")
    func nullColumns() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(
            cameras: [(7, "fixed", nil, nil, 52.13, -0.46)]
        )))
        let camera = try #require(store.cameraSet(
            near: bedford.0, longitude: bedford.1, radius: Meters(1_000)
        )?.cameras.first)
        #expect(camera.limit == nil)
        #expect(camera.direction == nil)
    }

    @Test("A camera beyond the radius is left out")
    func outsideRadius() throws {
        // Roughly 11 km north.
        let store = try #require(LocalRoadStore(url: makeExtract(
            cameras: [(1, "fixed", 30, nil, 52.23, -0.46)]
        )))
        let near = store.cameraSet(near: bedford.0, longitude: bedford.1, radius: Meters(1_000))
        #expect(near?.cameras.isEmpty == true)
        let far = store.cameraSet(near: bedford.0, longitude: bedford.1, radius: Meters(50_000))
        #expect(far?.cameras.count == 1)
    }

    /// Longitude degrees shrink toward the poles, so a box padded equally in both directions reaches
    /// barely half as far east at this latitude as it does north.
    @Test("The radius reaches as far east as it does north")
    func longitudeScaling() throws {
        // ~7 km east of Bedford at 52° N, which is inside 10 km but outside an unscaled 10/111 degrees.
        let store = try #require(LocalRoadStore(url: makeExtract(
            cameras: [(1, "fixed", 30, nil, 52.13, -0.36)]
        )))
        let found = store.cameraSet(near: bedford.0, longitude: bedford.1, radius: Meters(10_000))
        #expect(found?.cameras.count == 1)
    }
}

// MARK: - Zones

@Suite("Average-speed zones from the extract")
struct LocalZoneTests {
    @Test("A zone comes back with both ends")
    func bothEnds() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(
            zones: [(99, 50, (52.13, -0.46), (52.14, -0.47))]
        )))
        let zone = try #require(store.cameraSet(
            near: bedford.0, longitude: bedford.1, radius: Meters(5_000)
        )?.zones.first)
        #expect(zone.id == 99)
        #expect(zone.limit == MPH(50))
        #expect(zone.start == Coordinate(latitude: Latitude(52.13), longitude: Longitude(-0.46)))
        #expect(zone.end == Coordinate(latitude: Latitude(52.14), longitude: Longitude(-0.47)))
    }

    /// Some zones are mapped as a bag of devices with no `from`/`to` at all. An absent end must stay
    /// absent: `averageZoneExited` never exits on geometry alone without one, and inventing a
    /// boundary would announce the end of a check the rider is still inside.
    @Test("A zone with no end keeps it absent rather than inventing one")
    func missingEnd() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(
            zones: [(99, 50, (52.13, -0.46), nil)]
        )))
        let zone = try #require(store.cameraSet(
            near: bedford.0, longitude: bedford.1, radius: Meters(5_000)
        )?.zones.first)
        #expect(zone.start != nil)
        #expect(zone.end == nil)
        #expect(!averageZoneExited(zone, at: Coordinate(
            latitude: Latitude(52.13), longitude: Longitude(-0.46)
        )))
    }

    /// A zone entered before the last fetch is one whose exit is the only thing still ahead. Matching
    /// on the start alone would drop it and leave the rider inside an average check with no way to
    /// be told it had ended.
    @Test("A zone is found by either end")
    func matchedByEnd() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(
            // Starts ~11 km away, ends next to the rider.
            zones: [(99, 50, (52.23, -0.46), (52.13, -0.46))]
        )))
        let found = store.cameraSet(near: bedford.0, longitude: bedford.1, radius: Meters(2_000))
        #expect(found?.zones.count == 1)
    }
}

// MARK: - Stations

@Suite("Petrol stations from the extract")
struct LocalStationTests {
    @Test("The nearest station wins, not the first")
    func nearest() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(stations: [
            (1, "Far Garage", "BP", 52.1310, -0.4600),
            (2, "Near Garage", "Shell", 52.1300, -0.4600)
        ])))
        let station = try #require(store.station(
            near: bedford.0, longitude: bedford.1, radius: Meters(150)
        ))
        #expect(station.id == 2)
        #expect(station.brand == "Shell")
        #expect(station.label == "Shell")
    }

    /// Unlike cameras, a miss is not authoritative — it falls through to the network, which is right
    /// whether the cause is riding abroad or a forecourt that opened after the extract was built.
    @Test("Nothing within the radius returns nothing to fall through on")
    func noneNearby() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(stations: [
            (1, "Miles Away", "BP", 52.23, -0.46)
        ])))
        #expect(store.station(near: bedford.0, longitude: bedford.1, radius: Meters(150)) == nil)
    }

    /// Independents often carry a name and no brand. `label` prefers the brand because "Shell"
    /// identifies a price and "Ormsby Service Station" identifies a building.
    @Test("A station with no brand still identifies itself")
    func nameOnly() throws {
        let store = try #require(LocalRoadStore(url: makeExtract(stations: [
            (3, "Ormsby Service Station", nil, 52.13, -0.46)
        ])))
        let station = try #require(store.station(
            near: bedford.0, longitude: bedford.1, radius: Meters(150)
        ))
        #expect(station.brand == nil)
        #expect(station.label == "Ormsby Service Station")
    }
}
