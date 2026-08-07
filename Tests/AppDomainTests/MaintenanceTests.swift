import Foundation
import Testing
@testable import AppDomain

// The status machine decides whether a rider is told about a chain before it snaps. Every rule
// here is a promise the form makes: "warn me 5 days before" must mean five days, "last of both"
// must stay quiet until the second axis arrives, and an odometer the app cannot know must keep
// the km axis silent rather than guessing.

private let day: TimeInterval = 86_400
private func on(_ days: Double) -> Date { Date(timeIntervalSince1970: days * day) }
private func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID()
}

private func item(
    due: MaintenanceDue,
    warnDays: Int? = nil, warnKm: Double? = nil,
    recurrence: MaintenanceRecurrence? = nil,
    closed: Bool = false
) -> MaintenanceItem {
    MaintenanceItem(
        id: id(1), title: "Chain oil", due: due,
        warnDaysBefore: warnDays, warnKilometresBefore: warnKm,
        recurrence: recurrence, closed: closed
    )
}

@Suite("Maintenance status")
struct MaintenanceStatusTests {
    @Test("Before the warning window, nothing")
    func quietFarOut() {
        let chain = item(due: .onDate(on(100)), warnDays: 5)
        #expect(maintenanceStatus(chain, today: on(90), odometer: nil) == .ok)
    }

    @Test("Inside the warning window, amber; past the date, red")
    func dateEdges() {
        let chain = item(due: .onDate(on(100)), warnDays: 5)
        #expect(maintenanceStatus(chain, today: on(95), odometer: nil) == .warning)
        #expect(maintenanceStatus(chain, today: on(100), odometer: nil) == .due)
        #expect(maintenanceStatus(chain, today: on(101), odometer: nil) == .due)
    }

    @Test("The odometer axis mirrors the date axis")
    func odometerEdges() {
        let chain = item(due: .atOdometer(Kilometres(20_000)), warnKm: 500)
        #expect(maintenanceStatus(chain, today: on(0), odometer: Kilometres(19_000)) == .ok)
        #expect(maintenanceStatus(chain, today: on(0), odometer: Kilometres(19_500)) == .warning)
        #expect(maintenanceStatus(chain, today: on(0), odometer: Kilometres(20_000)) == .due)
    }

    /// A phantom "chain oil due" teaches the rider to ignore the real one.
    @Test("An unknowable odometer keeps the km axis silent")
    func unknownOdometerIsQuiet() {
        let chain = item(due: .atOdometer(Kilometres(20_000)), warnKm: 500)
        #expect(maintenanceStatus(chain, today: on(0), odometer: nil) == .ok)
    }

    @Test("Either is a race: the first axis to arrive wins")
    func eitherRaces() {
        let service = item(
            due: .either(date: on(100), odometer: Kilometres(20_000)), warnDays: 5, warnKm: 500
        )
        // Date far, km due: due.
        #expect(maintenanceStatus(service, today: on(50), odometer: Kilometres(20_100)) == .due)
        // Date in warning, km far: warning.
        #expect(maintenanceStatus(service, today: on(96), odometer: Kilometres(10_000)) == .warning)
    }

    @Test("Both is a conjunction: nothing is owed until the second arrives")
    func bothConjoins() {
        let age = item(
            due: .both(date: on(100), odometer: Kilometres(20_000)), warnDays: 5, warnKm: 500
        )
        // Date long past, km far short: still nothing.
        #expect(maintenanceStatus(age, today: on(200), odometer: Kilometres(10_000)) == .ok)
        // Date past, km in its warning window: the *lesser* of the two — warning.
        #expect(maintenanceStatus(age, today: on(200), odometer: Kilometres(19_700)) == .warning)
        // Both past: due.
        #expect(maintenanceStatus(age, today: on(200), odometer: Kilometres(20_001)) == .due)
    }

    @Test("A closed item never speaks again")
    func closedIsSilent() {
        let done = item(due: .onDate(on(0)), closed: true)
        #expect(maintenanceStatus(done, today: on(500), odometer: nil) == .ok)
    }

    @Test("The log's colour is its worst item's")
    func worstWins() {
        let log = MaintenanceLog(items: [
            item(due: .onDate(on(500))),
            item(due: .onDate(on(1)))
        ])
        #expect(maintenanceStatus(of: log, today: on(100), odometer: nil) == .due)
        #expect(maintenanceStatus(of: .empty, today: on(100), odometer: nil) == .ok)
    }
}

@Suite("Maintenance announcements")
struct MaintenanceAnnouncementTests {
    @Test("Due is stated flatly; healthy items say nothing")
    func dueLine() {
        let log = MaintenanceLog(items: [
            item(due: .onDate(on(10))),
            item(due: .onDate(on(900)))
        ])
        #expect(maintenanceAnnouncements(log, today: on(50), odometer: nil) == ["Chain oil is due"])
    }

    @Test("A warning names the remaining distance on whichever axes can speak")
    func warningLineWording() {
        let dated = item(due: .onDate(on(100)), warnDays: 5)
        #expect(
            maintenanceAnnouncements(MaintenanceLog(items: [dated]), today: on(97), odometer: nil)
                == ["Chain oil due in 3 days"]
        )
        let raced = item(
            due: .either(date: on(100), odometer: Kilometres(20_000)), warnDays: 5, warnKm: 500
        )
        #expect(
            maintenanceAnnouncements(
                MaintenanceLog(items: [raced]), today: on(97), odometer: Kilometres(19_900)
            ) == ["Chain oil due in 3 days or 100 kilometres"]
        )
    }

    @Test("Both joins with and")
    func bothJoinsWithAnd() {
        let age = item(
            due: .both(date: on(100), odometer: Kilometres(20_000)), warnDays: 5, warnKm: 500
        )
        #expect(
            maintenanceAnnouncements(
                MaintenanceLog(items: [age]), today: on(98), odometer: Kilometres(19_800)
            ) == ["Chain oil due in 2 days and 200 kilometres"]
        )
    }
}

@Suite("Completing maintenance")
struct MaintenanceCompletionTests {
    private func event(day: Double, odo: Double?) -> MaintenanceEvent {
        MaintenanceEvent(id: id(9), date: on(day), odometer: odo.map { Kilometres($0) })
    }

    @Test("A single instance closes and keeps its history")
    func oneShotCloses() {
        let done = completing(item(due: .onDate(on(100))), with: event(day: 90, odo: 18_000))
        #expect(done.closed)
        #expect(done.events.count == 1)
    }

    /// A chain oiled three weeks late is due a full interval after the oiling, not a truncated
    /// one after the missed date.
    @Test("A periodic item rolls forward from the event, not the deadline")
    func periodicRollsFromEvent() {
        let chain = item(
            due: .either(date: on(100), odometer: Kilometres(20_000)),
            recurrence: MaintenanceRecurrence(days: 30, kilometres: 1_000)
        )
        let rolled = completing(chain, with: event(day: 120, odo: 20_400))
        #expect(!rolled.closed)
        #expect(rolled.due.date == on(150))
        #expect(rolled.due.odometer == Kilometres(21_400))
    }

    @Test("An axis the recurrence is silent about stays where it was")
    func silentAxisStays() {
        let mot = item(
            due: .either(date: on(100), odometer: Kilometres(20_000)),
            recurrence: MaintenanceRecurrence(days: 365)
        )
        let rolled = completing(mot, with: event(day: 100, odo: 19_000))
        #expect(rolled.due.date == on(465))
        #expect(rolled.due.odometer == Kilometres(20_000))
    }

    @Test("An event without an odometer rolls the km axis from the old deadline")
    func eventWithoutOdometer() {
        let chain = item(
            due: .atOdometer(Kilometres(20_000)),
            recurrence: MaintenanceRecurrence(kilometres: 1_000)
        )
        let rolled = completing(chain, with: event(day: 100, odo: nil))
        #expect(rolled.due.odometer == Kilometres(21_000))
    }
}

@Suite("The reconstructed odometer")
struct CurrentOdometerTests {
    private func fill(day: Double, odo: Double?) -> RefuelRecord {
        RefuelRecord(
            id: id(Int(day)), date: on(day), litres: Litres(9), pricePerLitre: 1.5,
            grade: .e5, filledToBrim: true, odometer: odo.map { Kilometres($0) },
            latitude: nil, longitude: nil
        )
    }

    @Test("The newest fill's odometer plus the trip since it")
    func addsTripToNewestFill() {
        let log = FuelLog(refuels: [fill(day: 1, odo: 19_000), fill(day: 5, odo: 19_300)])
        #expect(
            currentOdometer(fuel: log, sinceFill: Kilometres(120)) == Kilometres(19_420)
        )
    }

    /// The trip counter resets at every fill, so an older fill's reading cannot anchor it —
    /// the gap between the two fills would go uncounted.
    @Test("A newest fill without a reading means the odometer is unknowable")
    func newestWithoutReadingIsNil() {
        let log = FuelLog(refuels: [fill(day: 1, odo: 19_000), fill(day: 5, odo: nil)])
        #expect(currentOdometer(fuel: log, sinceFill: Kilometres(120)) == nil)
        #expect(currentOdometer(fuel: .empty, sinceFill: Kilometres(120)) == nil)
    }
}

@Suite("Maintenance summaries")
struct MaintenanceSummaryTests {
    @Test("Rows speak the same arithmetic the announcements do")
    func rowWording() {
        let service = item(due: .either(date: on(100), odometer: Kilometres(20_000)))
        #expect(
            maintenanceSummary(service, today: on(97), odometer: Kilometres(19_900))
                == "in 3 days or in 100 km"
        )
        #expect(
            maintenanceSummary(item(due: .onDate(on(100))), today: on(103), odometer: nil)
                == "3 days overdue"
        )
        #expect(maintenanceSummary(item(due: .onDate(on(1)), closed: true), today: on(2), odometer: nil) == "done")
    }

    @Test("An unknown odometer states the raw deadline instead of a countdown")
    func unknownOdometerShowsDeadline() {
        let chain = item(due: .atOdometer(Kilometres(20_000)))
        #expect(maintenanceSummary(chain, today: on(0), odometer: nil) == "at 20000 km")
    }
}
