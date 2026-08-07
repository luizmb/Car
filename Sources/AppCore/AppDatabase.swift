import AppDomain
import Foundation
import SQLite3

/// Everything the app persists, in one SQLite file.
///
/// One database instead of a drawer of JSON files: one thing to pull from the phone, one thing to
/// back up, one place to point a query at. **Not** the roads extract — that is a read-only snapshot
/// of the world, replaced wholesale; this is the app's own record, written a row at a time.
///
/// Two tables carry two shapes of data. `journey` is the append-only timeline — each row is
/// exactly the JSON line the JSONL files used to hold, so the reader (`JourneyLog.records`) and
/// the writer share one encoding and cannot drift; `t` and `type` are lifted out as columns purely
/// so offline queries can filter without parsing JSON. `document` holds the read-whole,
/// write-whole values — the fuel log, the maintenance log, the trip distance — as named JSON,
/// because the app treats them as documents and rows would only add a mapping layer for nothing.
///
/// There is deliberately no migration machinery: the schema is created on first open and that is
/// the only version there is.
final class AppDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

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
        // WAL keeps a fix-per-second writer from ever blocking a reader, and survives the app's
        // normal ending — being killed mid-anything — with the main file intact.
        sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS journey (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                t TEXT NOT NULL,
                type TEXT NOT NULL,
                json TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS journey_time ON journey(t);
            CREATE TABLE IF NOT EXISTS document (
                name TEXT PRIMARY KEY,
                json TEXT NOT NULL
            );
            """, nil, nil, nil)
    }

    deinit { sqlite3_close(handle) }

    // MARK: - Journey timeline

    /// Appends one record, already encoded as its canonical JSON line.
    func appendJourney(time: String, type: String, json: String) {
        run("INSERT INTO journey (t, type, json) VALUES (?, ?, ?)", bind: [time, type, json])
    }

    /// Every record's JSON, in insertion order — which is chronological, the same promise the
    /// dated files kept by sorting their names.
    func journeyLines() -> [String] {
        var lines: [String] = []
        query("SELECT json FROM journey ORDER BY id") { statement in
            sqlite3_column_text(statement, 0).map { lines.append(String(cString: $0)) }
        }
        return lines
    }

    // MARK: - Documents

    func document(_ name: String) -> String? {
        var json: String?
        query("SELECT json FROM document WHERE name = ?", bind: [name]) { statement in
            json = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
        return json
    }

    /// Whole-document replacement — the same semantics the atomic file write had.
    func saveDocument(_ name: String, json: String) {
        run("INSERT OR REPLACE INTO document (name, json) VALUES (?, ?)", bind: [name, json])
    }

    // MARK: - Plumbing

    /// SQLite must copy bound text before the statement finalises; passing this destructor says so.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func run(_ sql: String, bind: [String]) {
        query(sql, bind: bind) { _ in }
    }

    private func query(_ sql: String, bind: [String] = [], each: (OpaquePointer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }
        while sqlite3_step(statement) == SQLITE_ROW, let statement { each(statement) }
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
