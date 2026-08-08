import AppDomain
import Foundation
import SQLite3

/// Everything the app persists, in one SQLite file — as a proper relational schema.
///
/// One database instead of a drawer of JSON files: one thing to pull from the phone, one thing to
/// back up, one place to point a query at. **Not** the roads extract — that is a read-only snapshot
/// of the world, replaced wholesale; this is the app's own record, written a row at a time.
///
/// The journey timeline is **one table per record type**, with typed columns matching the payload
/// fields — `SELECT avg(mph) FROM fix` works on the phone's own file, no JSON parsing anywhere.
/// Every journey table carries `t` (ISO-8601, lexicographically ordered) so the timeline can be
/// reassembled across tables. The read-whole, write-whole values — fuel log, maintenance log,
/// trip distance — stay named JSON documents, because the app treats them as documents and rows
/// would only add a mapping layer for nothing.
///
/// The mapping between payload structs and columns is hand-written here, at the World boundary
/// where ugly conversions belong, and is held honest by an exhaustive round-trip test over every
/// `RecordType` — a payload changed without its mapping fails the suite, not a year of records.
///
/// There is deliberately no versioned migration machinery. The schema below is ensured on every
/// open: tables are created if missing and columns added if missing — deterministic, idempotent,
/// and enough for the only evolution payloads actually undergo, which is growing a field.
final class AppDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let timestamps = ISO8601DateFormatter()

    static let filename = "speedjarvis.sqlite"

    private static var url: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    convenience init?() { self.init(url: Self.url) }

    init?(url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        handle = db
        timestamps.timeZone = TimeZone(secondsFromGMT: 0)
        // WAL keeps a fix-per-second writer from ever blocking a reader, and survives the app's
        // normal ending — being killed mid-anything — with the main file intact.
        sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS document (
                name TEXT PRIMARY KEY,
                json TEXT NOT NULL
            );
            """, nil, nil, nil)
        ensureJourneySchema()
    }

    deinit { sqlite3_close(handle) }

    // MARK: - The journey schema

    /// Every journey table's payload columns, by record type. `id` and `t` are implicit on all.
    ///
    /// Column names are the payloads' own coding keys, so a row reads like the record it stores —
    /// including `camera`'s historical `cameraType`, which the flat JSON format needed and renaming
    /// now would only make old and new records disagree.
    private static let journeySchema: [RecordType: [(name: String, type: String)]] = [
        .journeyStart: [("via", "TEXT")],
        .journeyEnd: [("seconds", "INTEGER"), ("started", "TEXT")],
        .fix: [("lat", "REAL"), ("lon", "REAL"), ("mph", "REAL"),
               ("course", "REAL"), ("alt", "REAL"), ("acc", "REAL")],
        .road: [("mph", "REAL"), ("origin", "TEXT"), ("label", "TEXT"), ("variable", "INTEGER")],
        .camera: [("cameraType", "TEXT"), ("mph", "REAL"), ("atMPH", "REAL")],
        .averageZone: [("entered", "INTEGER"), ("mph", "REAL")],
        .indicator: [("side", "TEXT")],
        .tyre: [("position", "TEXT"), ("psi", "REAL"), ("celsius", "REAL"), ("moving", "INTEGER")],
        .weather: [("celsius", "REAL"), ("humidity", "REAL"), ("kpa", "REAL"),
                   ("windMPS", "REAL"), ("windDegrees", "REAL")],
        .barometer: [("kpa", "REAL"), ("relativeAltitude", "REAL")],
        .activity: [("activity", "TEXT"), ("confidence", "INTEGER")],
        .device: [("device", "TEXT"), ("connected", "INTEGER")],
        .destination: [("name", "TEXT"), ("lat", "REAL"), ("lon", "REAL")],
        .refuel: [("litres", "REAL"), ("price", "REAL"), ("odometer", "REAL"),
                  ("brim", "INTEGER"), ("station", "TEXT"), ("stationID", "INTEGER")],
        .reserve: [("km", "REAL"), ("odometer", "REAL")]
    ]

    /// `average-zone` the type, `average_zone` the table — SQL identifiers do not hyphenate.
    private static func table(_ type: RecordType) -> String {
        type.rawValue.replacingOccurrences(of: "-", with: "_")
    }

    /// Creates missing tables and adds missing columns. Idempotent by construction: it compares
    /// what exists against the schema above and only ever adds. This is the entire story of schema
    /// evolution — a payload that grows a field grows a nullable column here, and old rows answer
    /// NULL for it, which is the truth.
    private func ensureJourneySchema() {
        for type in RecordType.allCases {
            let table = Self.table(type)
            let columns = Self.journeySchema[type] ?? []
            let definitions = columns.map { ", \($0.name) \($0.type)" }.joined()
            sqlite3_exec(handle, """
                CREATE TABLE IF NOT EXISTS \(table) (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, t TEXT NOT NULL\(definitions)
                );
                CREATE INDEX IF NOT EXISTS \(table)_time ON \(table)(t);
                """, nil, nil, nil)

            var existing: Set<String> = []
            query("PRAGMA table_info(\(table))") { statement in
                sqlite3_column_text(statement, 1).map { existing.insert(String(cString: $0)) }
            }
            for column in columns where !existing.contains(column.name) {
                sqlite3_exec(
                    handle, "ALTER TABLE \(table) ADD COLUMN \(column.name) \(column.type)",
                    nil, nil, nil
                )
            }
        }
    }

    // MARK: - Writing the timeline

    /// One record into its own table. A payload type without a branch here is caught by the
    /// exhaustive round-trip test, not discovered missing from a year of records.
    func append(_ record: JourneyRecord) {
        let t = SQLValue.text(timestamps.string(from: record.time))
        switch record.payload {
        case let p as JourneyStartPayload:
            insert(.journeyStart, [t, .text(p.via)])
        case let p as JourneyEndPayload:
            insert(.journeyEnd, [t, .integer(p.seconds), .text(timestamps.string(from: p.started))])
        case let p as FixPayload:
            insert(.fix, [t, .real(p.lat), .real(p.lon), .real(p.mph),
                          .real(p.course), .real(p.alt), .real(p.acc)])
        case let p as RoadPayload:
            insert(.road, [t, .real(p.mph), .text(p.origin), .text(p.label), .bool(p.variable)])
        case let p as CameraPayload:
            insert(.camera, [t, .text(p.type), .real(p.mph), .real(p.atMPH)])
        case let p as AverageZonePayload:
            insert(.averageZone, [t, .bool(p.entered), .real(p.mph)])
        case let p as IndicatorPayload:
            insert(.indicator, [t, .text(p.side)])
        case let p as TyrePayload:
            insert(.tyre, [t, .text(p.position), .real(p.psi), .real(p.celsius), .bool(p.moving)])
        case let p as WeatherPayload:
            insert(.weather, [t, .real(p.celsius), .real(p.humidity), .real(p.kpa),
                              .real(p.windMPS), .real(p.windDegrees)])
        case let p as BarometerPayload:
            insert(.barometer, [t, .real(p.kpa), .real(p.relativeAltitude)])
        case let p as ActivityPayload:
            insert(.activity, [t, .text(p.activity), .integer(p.confidence)])
        case let p as DevicePayload:
            insert(.device, [t, .text(p.device), .bool(p.connected)])
        case let p as DestinationPayload:
            insert(.destination, [t, .text(p.name), .real(p.lat), .real(p.lon)])
        case let p as RefuelPayload:
            insert(.refuel, [t, .real(p.litres), .real(p.price), .real(p.odometer),
                             .bool(p.brim), .text(p.station), .integer(p.stationID)])
        case let p as ReservePayload:
            insert(.reserve, [t, .real(p.km), .real(p.odometer)])
        default:
            return
        }
    }

    private func insert(_ type: RecordType, _ values: [SQLValue]) {
        let columns = ["t"] + (Self.journeySchema[type] ?? []).map(\.name)
        let sql = "INSERT INTO \(Self.table(type)) (\(columns.joined(separator: ", ")))"
            + " VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))"
        query(sql, bind: values) { _ in }
    }

    // MARK: - Reading the timeline

    /// The whole timeline, reassembled across the tables and ordered by time — the same promise
    /// the dated files kept by sorting their names, now kept by sorting the union.
    func journeyRecords() -> [JourneyRecord] {
        var records: [JourneyRecord] = []
        for type in RecordType.allCases {
            let columns = (Self.journeySchema[type] ?? []).map(\.name).joined(separator: ", ")
            query("SELECT t\(columns.isEmpty ? "" : ", " + columns) FROM \(Self.table(type))") {
                statement in
                guard
                    let stamp = text(statement, 0),
                    let time = timestamps.date(from: stamp),
                    let payload = payload(of: type, from: statement)
                else { return }
                records.append(JourneyRecord(time: time, payload: payload))
            }
        }
        return records.sorted { $0.time < $1.time }
    }

    /// Columns back into the payload struct — the inverse of `append`, held to it by the same
    /// exhaustive test. Column 0 is always `t`; payload columns start at 1 in schema order.
    private func payload(
        of type: RecordType, from s: OpaquePointer
    ) -> (any JourneyPayloadType)? {
        switch type {
        case .journeyStart:
            JourneyStartPayload(via: text(s, 1) ?? "")
        case .journeyEnd:
            text(s, 2).flatMap { timestamps.date(from: $0) }.map {
                JourneyEndPayload(seconds: integer(s, 1) ?? 0, started: $0)
            }
        case .fix:
            FixPayload(lat: real(s, 1) ?? 0, lon: real(s, 2) ?? 0, mph: real(s, 3),
                       course: real(s, 4), alt: real(s, 5), acc: real(s, 6))
        case .road:
            RoadPayload(mph: real(s, 1), origin: text(s, 2) ?? "",
                        label: text(s, 3), variable: bool(s, 4))
        case .camera:
            CameraPayload(type: text(s, 1) ?? "", mph: real(s, 2), atMPH: real(s, 3) ?? 0)
        case .averageZone:
            AverageZonePayload(entered: bool(s, 1), mph: real(s, 2))
        case .indicator:
            IndicatorPayload(side: text(s, 1))
        case .tyre:
            TyrePayload(position: text(s, 1) ?? "", psi: real(s, 2) ?? 0,
                        celsius: real(s, 3) ?? 0, moving: bool(s, 4))
        case .weather:
            WeatherPayload(celsius: real(s, 1) ?? 0, humidity: real(s, 2) ?? 0,
                           kpa: real(s, 3) ?? 0, windMPS: real(s, 4) ?? 0,
                           windDegrees: real(s, 5) ?? 0)
        case .barometer:
            BarometerPayload(kpa: real(s, 1) ?? 0, relativeAltitude: real(s, 2) ?? 0)
        case .activity:
            ActivityPayload(activity: text(s, 1) ?? "", confidence: integer(s, 2) ?? 0)
        case .device:
            DevicePayload(device: text(s, 1) ?? "", connected: bool(s, 2))
        case .destination:
            DestinationPayload(name: text(s, 1), lat: real(s, 2) ?? 0, lon: real(s, 3) ?? 0)
        case .refuel:
            RefuelPayload(litres: real(s, 1) ?? 0, price: real(s, 2) ?? 0, odometer: real(s, 3),
                          brim: bool(s, 4), station: text(s, 5), stationID: integer(s, 6))
        case .reserve:
            ReservePayload(km: real(s, 1), odometer: real(s, 2))
        }
    }

    // MARK: - Documents

    func document(_ name: String) -> String? {
        var json: String?
        query("SELECT json FROM document WHERE name = ?", bind: [.text(name)]) { statement in
            json = text(statement, 0)
        }
        return json
    }

    /// Whole-document replacement — the same semantics the atomic file write had.
    func saveDocument(_ name: String, json: String) {
        query(
            "INSERT OR REPLACE INTO document (name, json) VALUES (?, ?)",
            bind: [.text(name), .text(json)]
        ) { _ in }
    }

    // MARK: - Plumbing

    /// A bindable value, `nil`s included — so an optional payload field is a NULL column, which is
    /// the truth, rather than a sentinel.
    private enum SQLValue {
        case string(String)
        case double(Double)
        case int(Int)
        case null

        static func text(_ value: String?) -> SQLValue { value.map { .string($0) } ?? .null }
        static func real(_ value: Double?) -> SQLValue { value.map { .double($0) } ?? .null }
        static func integer(_ value: Int?) -> SQLValue { value.map { .int($0) } ?? .null }
        static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
    }

    /// SQLite must copy bound text before the statement finalises; passing this destructor says so.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func query(_ sql: String, bind: [SQLValue] = [], each: (OpaquePointer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let .string(string): sqlite3_bind_text(statement, position, string, -1, Self.transient)
            case let .double(double): sqlite3_bind_double(statement, position, double)
            case let .int(int): sqlite3_bind_int64(statement, position, Int64(int))
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW, let statement { each(statement) }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func real(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, column)
    }

    private func integer(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, column))
    }

    private func bool(_ statement: OpaquePointer, _ column: Int32) -> Bool {
        sqlite3_column_int64(statement, column) != 0
    }
}

// MARK: - Document names

/// The names documents live under. An enum of constants rather than stringly call sites, for the
/// same reason the JSONL filenames were.
enum AppDocument {
    static let fuelLog = "fuel-log"
    static let maintenanceLog = "maintenance-log"
    static let tripDistance = "trip-distance"
}
