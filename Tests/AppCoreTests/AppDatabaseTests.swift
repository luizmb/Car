import AppDomain
import Foundation
import Testing
@testable import AppCore

// The database now holds the only durable record of every ride and every fill. These tests open
// real files and run the real SQL, because the failure that matters — a row written but never
// read back, an ordering that scrambles a ride — is invisible to anything mocked.

private func makeDatabase() throws -> AppDatabase {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("appdb-\(UUID().uuidString).sqlite")
    return try #require(AppDatabase(url: url))
}

@Suite("App database documents")
struct AppDatabaseDocumentTests {
    @Test("A document round-trips whole")
    func documentRoundTrip() throws {
        let db = try makeDatabase()
        db.saveDocument("fuel-log", json: #"{"litres": 9.5}"#)
        #expect(db.document("fuel-log") == #"{"litres": 9.5}"#)
    }

    @Test("Saving replaces, never appends")
    func saveReplaces() throws {
        let db = try makeDatabase()
        db.saveDocument("trip-distance", json: "100")
        db.saveDocument("trip-distance", json: "250")
        #expect(db.document("trip-distance") == "250")
    }

    @Test("An absent document is nil, not empty")
    func absentIsNil() throws {
        let db = try makeDatabase()
        #expect(db.document("maintenance-log") == nil)
    }

    /// The reader wrappers keep the file-era error vocabulary: absent row → `.notFound` (the
    /// normal first run), undecodable row → `.malformed` (a shape change, never silently empty).
    @Test("The document reader distinguishes absent from malformed")
    func readerErrors() async throws {
        let db = try makeDatabase()
        var result = await makeDocumentReader(FuelLog.self, name: "fuel-log", database: db).firstValue()
        #expect(result == .failure(.notFound))

        db.saveDocument("fuel-log", json: "not json at all")
        result = await makeDocumentReader(FuelLog.self, name: "fuel-log", database: db).firstValue()
        guard case .failure(.malformed) = result else {
            Issue.record("a shape change must be loud, got \(String(describing: result))")
            return
        }
    }
}

@Suite("App database journey timeline")
struct AppDatabaseJourneyTests {
    @Test("Rows come back in insertion order, decoded by the same parser as the files")
    func journeyRoundTrip() throws {
        let db = try makeDatabase()
        let times = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)]
        for (index, time) in times.enumerated() {
            let record = JourneyRecord(
                time: time,
                payload: FixPayload(lat: 52.0 + Double(index), lon: -0.4, mph: 30, course: nil, alt: 90, acc: 5)
            )
            let json = String(decoding: (try? JourneyLog.encoder.encode(record)) ?? Data(), as: UTF8.self)
            db.appendJourney(time: JourneyLog.timestamp(time), type: "fix", json: json)
        }

        let records = JourneyLog.records(fromLines: db.journeyLines())
        #expect(records.map(\.time) == times)
        #expect((records.first?.payload as? FixPayload)?.lat == 52.0)
    }

    /// The app's normal ending is being killed; the database's promise is that reopening finds
    /// everything that was ever appended.
    @Test("A reopened database still holds its rows")
    func survivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appdb-\(UUID().uuidString).sqlite")
        do {
            let db = try #require(AppDatabase(url: url))
            db.appendJourney(time: "2026-08-08T10:00:00Z", type: "fix", json: #"{"t":"2026-08-08T10:00:00Z","type":"fix"}"#)
            db.saveDocument("fuel-log", json: "{}")
        }
        let reopened = try #require(AppDatabase(url: url))
        #expect(reopened.journeyLines().count == 1)
        #expect(reopened.document("fuel-log") == "{}")
    }

    @Test("One undecodable row costs itself, not the ride")
    func badRowIsDropped() throws {
        let db = try makeDatabase()
        let record = JourneyRecord(
            time: Date(timeIntervalSince1970: 100),
            payload: FixPayload(lat: 52, lon: -0.4, mph: 30, course: nil, alt: 90, acc: 5)
        )
        let json = String(decoding: (try? JourneyLog.encoder.encode(record)) ?? Data(), as: UTF8.self)
        db.appendJourney(time: JourneyLog.timestamp(record.time), type: "fix", json: json)
        db.appendJourney(time: "2026-08-08T10:00:01Z", type: "fix", json: "{\"half\":")

        #expect(JourneyLog.records(fromLines: db.journeyLines()).count == 1)
    }
}
