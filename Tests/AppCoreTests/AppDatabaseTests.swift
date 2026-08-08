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

/// One representative payload per record type, every optional populated — the write mapping and
/// the read mapping are hand-written inverses, and this is what holds them together. A new
/// `RecordType` without a sample fails to compile the switch; a payload field without a column
/// fails the equality below.
private func sample(_ type: RecordType) -> any JourneyPayloadType {
    switch type {
    case .journeyStart: JourneyStartPayload(via: "both")
    case .journeyEnd: JourneyEndPayload(seconds: 900, started: Date(timeIntervalSince1970: 1_000))
    case .fix: FixPayload(lat: 51.87, lon: -0.41, mph: 31.5, course: 182, alt: 91.2, acc: 4.5)
    case .road: RoadPayload(mph: 30, origin: "signed", label: "A505", variable: true)
    case .camera: CameraPayload(type: "fixed", mph: 40, atMPH: 43.2)
    case .averageZone: AverageZonePayload(entered: true, mph: 50)
    case .indicator: IndicatorPayload(side: "left")
    case .tyre: TyrePayload(position: "front", psi: 33.1, celsius: 21.4, moving: true)
    case .weather: WeatherPayload(celsius: 19, humidity: 54, kpa: 100.4, windMPS: 1.5, windDegrees: 108)
    case .barometer: BarometerPayload(kpa: 100.1, relativeAltitude: 12.5)
    case .activity: ActivityPayload(activity: "automotive", confidence: 2)
    case .device: DevicePayload(device: "indimate", connected: true)
    case .destination: DestinationPayload(name: "Home", lat: 51.869, lon: -0.416)
    case .refuel: RefuelPayload(litres: 9.2, price: 1.49, odometer: 19_420, brim: true,
                                station: "Shell", stationID: 42)
    case .reserve: ReservePayload(km: 231.4, odometer: 19_650)
    }
}

@Suite("App database journey timeline")
struct AppDatabaseJourneyTests {
    /// Every record type, written to its table and read back identical. This is the drift alarm:
    /// a payload that grows a field without its column — or a mapper that misorders two columns —
    /// fails here, not in a year of records.
    @Test("Every record type round-trips its table", arguments: RecordType.allCases)
    func roundTripsEveryType(type: RecordType) throws {
        let db = try makeDatabase()
        let written = JourneyRecord(time: Date(timeIntervalSince1970: 500), payload: sample(type))
        db.append(written)

        let records = db.journeyRecords()
        #expect(records.count == 1)
        #expect(records.first?.time == written.time)
        #expect(records.first.map { $0.payload.isEqual(to: written.payload) } == true)
    }

    /// Optionals must survive as NULL, not as zero — a fix with no speed is not a fix at 0 mph.
    @Test("Absent optionals come back absent")
    func nullFidelity() throws {
        let db = try makeDatabase()
        db.append(JourneyRecord(
            time: Date(timeIntervalSince1970: 10),
            payload: FixPayload(lat: 52, lon: -0.4, mph: nil, course: nil, alt: nil, acc: nil)
        ))
        db.append(JourneyRecord(
            time: Date(timeIntervalSince1970: 11),
            payload: IndicatorPayload(side: nil)
        ))

        let records = db.journeyRecords()
        #expect((records.first?.payload as? FixPayload)?.mph == nil)
        #expect((records.last?.payload as? IndicatorPayload)?.side == nil)
    }

    @Test("The timeline comes back time-ordered across tables")
    func orderedAcrossTables() throws {
        let db = try makeDatabase()
        db.append(JourneyRecord(
            time: Date(timeIntervalSince1970: 300),
            payload: RoadPayload(mph: 30, origin: "signed", label: "A505", variable: false)
        ))
        db.append(JourneyRecord(
            time: Date(timeIntervalSince1970: 100),
            payload: JourneyStartPayload(via: "ignition")
        ))
        db.append(JourneyRecord(
            time: Date(timeIntervalSince1970: 200),
            payload: FixPayload(lat: 52, lon: -0.4, mph: 30, course: nil, alt: nil, acc: nil)
        ))

        let types = db.journeyRecords().map(\.type)
        #expect(types == [.journeyStart, .fix, .road])
    }

    /// The app's normal ending is being killed; the database's promise is that reopening finds
    /// everything that was ever appended — and that re-ensuring the schema on open changes nothing.
    @Test("A reopened database still holds its rows")
    func survivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appdb-\(UUID().uuidString).sqlite")
        do {
            let db = try #require(AppDatabase(url: url))
            db.append(JourneyRecord(
                time: Date(timeIntervalSince1970: 42), payload: JourneyStartPayload(via: "both")
            ))
            db.saveTripDistance(500)
        }
        let reopened = try #require(AppDatabase(url: url))
        #expect(reopened.journeyRecords().count == 1)
        #expect(reopened.tripDistance() == 500)
    }
}

@Suite("App database fuel store")
struct AppDatabaseFuelTests {
    private func fill(
        seconds: Double, station: FuelStation? = nil, odometer: Double? = nil
    ) -> RefuelRecord {
        RefuelRecord(
            id: UUID(), date: Date(timeIntervalSince1970: seconds),
            litres: Litres(9.2), pricePerLitre: 1.49, grade: .e5, filledToBrim: true,
            odometer: odometer.map { Kilometres($0) }, gpsKilometres: Kilometres(231.4),
            latitude: Latitude(51.87), longitude: Longitude(-0.41), station: station
        )
    }

    @Test("The whole log round-trips through the normalised tables")
    func roundTrip() throws {
        let db = try makeDatabase()
        let shell = FuelStation(id: 42, brand: "Shell", name: "Shell Luton")
        let log = FuelLog(
            refuels: [fill(seconds: 100, station: shell, odometer: 19_000),
                      fill(seconds: 200, station: shell)],
            reserves: [ReserveEvent(
                id: UUID(), date: Date(timeIntervalSince1970: 150),
                odometer: Kilometres(19_200), gpsKilometres: Kilometres(210),
                latitude: Latitude(51.9), longitude: Longitude(-0.42)
            )]
        )
        db.save(log)
        #expect(db.fuelLog() == log)
    }

    /// Two fills at the same forecourt are one station row — the dimension the foreign key
    /// points at, and the whole reason the station is not repeated per fill.
    @Test("Saving replaces the store whole")
    func saveReplaces() throws {
        let db = try makeDatabase()
        db.save(FuelLog(refuels: [fill(seconds: 100)], reserves: []))
        let second = FuelLog(refuels: [fill(seconds: 300)], reserves: [])
        db.save(second)
        #expect(db.fuelLog() == second)
    }

    @Test("An empty database is an empty log, not a missing one")
    func emptyIsEmpty() throws {
        let db = try makeDatabase()
        #expect(db.fuelLog() == .empty)
    }
}

@Suite("App database maintenance store")
struct AppDatabaseMaintenanceTests {
    @Test("Every due shape survives its columns")
    func dueShapes() throws {
        let db = try makeDatabase()
        let date = Date(timeIntervalSince1970: 86_400 * 100)
        let dues: [MaintenanceDue] = [
            .onDate(date),
            .atOdometer(Kilometres(20_000)),
            .either(date: date, odometer: Kilometres(20_000)),
            .both(date: date, odometer: Kilometres(20_000))
        ]
        let log = MaintenanceLog(items: dues.map { due in
            MaintenanceItem(
                id: UUID(), title: "Chain oil", due: due,
                warnDaysBefore: 5, warnKilometresBefore: 300,
                recurrence: MaintenanceRecurrence(days: 30, kilometres: 1_000)
            )
        })
        db.save(log)
        #expect(Set(db.maintenanceLog().items.map(\.id)) == Set(log.items.map(\.id)))
        for item in log.items {
            #expect(db.maintenanceLog().items.first { $0.id == item.id } == item)
        }
    }

    @Test("Events ride under their item and come back date-ordered")
    func eventsCascade() throws {
        let db = try makeDatabase()
        let item = MaintenanceItem(
            id: UUID(), title: "Valve clearances",
            due: .atOdometer(Kilometres(24_000)),
            events: [
                MaintenanceEvent(id: UUID(), date: Date(timeIntervalSince1970: 200),
                                 odometer: Kilometres(16_000), notes: "second"),
                MaintenanceEvent(id: UUID(), date: Date(timeIntervalSince1970: 100),
                                 odometer: Kilometres(8_000),
                                 latitude: Latitude(51.8), longitude: Longitude(-0.4),
                                 notes: "first")
            ]
        )
        db.save(MaintenanceLog(items: [item]))
        let read = db.maintenanceLog().items.first
        #expect(read?.events.map(\.notes) == ["first", "second"])

        // Deleting the item takes its events with it: the cascade, exercised through a
        // replacing save that no longer contains the item.
        db.save(MaintenanceLog(items: []))
        #expect(db.maintenanceLog().items.isEmpty)
        let fresh = MaintenanceItem(id: UUID(), title: "Chain", due: .atOdometer(Kilometres(1)))
        db.save(MaintenanceLog(items: [fresh]))
        #expect(db.maintenanceLog().items.first?.events.isEmpty == true)
    }
}

@Suite("App database trip counter")
struct AppDatabaseTripTests {
    @Test("The counter is one row: absent, then replaced")
    func tripLifecycle() throws {
        let db = try makeDatabase()
        #expect(db.tripDistance() == nil)
        db.saveTripDistance(1_234.5)
        db.saveTripDistance(2_000)
        #expect(db.tripDistance() == 2_000)
    }
}

@Suite("App database rides list")
struct AppDatabaseRideListTests {
    @Test("The list is three columns off the journey table, and the window loads one ride")
    func summariesAndWindow() throws {
        let db = try makeDatabase()
        let start = Date(timeIntervalSince1970: 1_000)
        db.append(JourneyRecord(time: start, payload: JourneyStartPayload(via: "both")))
        db.append(JourneyRecord(
            time: start.addingTimeInterval(60),
            payload: FixPayload(lat: 52, lon: -0.4, mph: 30, course: nil, alt: nil, acc: nil)
        ))
        db.append(JourneyRecord(
            time: start.addingTimeInterval(600),
            payload: JourneyEndPayload(seconds: 600, started: start, metres: 4_200)
        ))
        // A later journey whose records must stay out of the first one's window.
        let later = start.addingTimeInterval(10_000)
        db.append(JourneyRecord(time: later, payload: JourneyStartPayload(via: "ignition")))
        db.append(JourneyRecord(
            time: later.addingTimeInterval(30),
            payload: FixPayload(lat: 53, lon: -0.4, mph: 20, course: nil, alt: nil, acc: nil)
        ))

        let summaries = db.rideSummaries()
        #expect(summaries.count == 2)
        #expect(summaries.first?.endedCleanly == false)   // newest first: the open one
        #expect(summaries.last?.metres == 4_200)
        #expect(summaries.last?.seconds == 600)

        let window = db.rideRecords(from: start, seconds: 600)
        #expect(window.count == 3)   // start, fix, end — not the later journey's records
        #expect(window.first?.type == .journeyStart)
        #expect(window.last?.type == .journeyEnd)

        // The open ride's window runs to the next journey's start.
        let openWindow = db.rideRecords(from: later, seconds: nil)
        #expect(openWindow.contains { ($0.payload as? FixPayload)?.lat == 53 })
        #expect(!openWindow.contains { ($0.payload as? FixPayload)?.lat == 52 })
    }
}
