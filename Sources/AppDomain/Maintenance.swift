import FP
import FPMacros
import Foundation

// MARK: - When maintenance falls due

/// The deadline's axes, and how two of them combine.
///
/// The four cases are the four answers to "when is this due": a calendar date, an odometer
/// reading, whichever of the two arrives first (a service interval — "12 months or 12,000 km"),
/// or only once both have arrived ("at least two years old *and* 20,000 km ridden").
@Prisms
public enum MaintenanceDue: Sendable, Equatable, Codable {
    case onDate(Date)
    case atOdometer(Kilometres)
    /// Whichever arrives first.
    case either(date: Date, odometer: Kilometres)
    /// Only once both have arrived.
    case both(date: Date, odometer: Kilometres)

    public var date: Date? {
        switch self {
        case let .onDate(date): date
        case .atOdometer: nil
        case let .either(date, _): date
        case let .both(date, _): date
        }
    }

    public var odometer: Kilometres? {
        switch self {
        case .onDate: nil
        case let .atOdometer(odometer): odometer
        case let .either(_, odometer): odometer
        case let .both(_, odometer): odometer
        }
    }
}

// MARK: - Recurrence

/// How the next deadline follows a completed one.
///
/// Counted **from the completion event**, not from the old deadline: a chain oiled three weeks
/// late is due again a full interval after the oiling, not a truncated one after the missed date.
/// A `nil` axis leaves that axis of the deadline where it was.
public struct MaintenanceRecurrence: Sendable, Equatable, Codable {
    public var days: Int?
    public var kilometres: Double?

    public init(days: Int? = nil, kilometres: Double? = nil) {
        self.days = days
        self.kilometres = kilometres
    }
}

// MARK: - Events

/// One occasion the work was actually done.
public struct MaintenanceEvent: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var date: Date
    /// The bike's odometer at the time, if known — what the next km deadline counts from.
    public var odometer: Kilometres?
    /// Where it happened. Captured at the moment of recording, like a refuel's forecourt —
    /// attributing a place afterwards is guesswork, so an event saved without one never gets one.
    public var latitude: Latitude?
    public var longitude: Longitude?
    public var notes: String

    public init(
        id: UUID, date: Date, odometer: Kilometres?,
        latitude: Latitude? = nil, longitude: Longitude? = nil, notes: String = ""
    ) {
        self.id = id
        self.date = date
        self.odometer = odometer
        self.latitude = latitude
        self.longitude = longitude
        self.notes = notes
    }
}

// MARK: - The item

/// One thing the bike needs doing — once, or on a rhythm.
public struct MaintenanceItem: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var title: String
    public var due: MaintenanceDue
    /// Days before the date axis at which the status turns amber.
    public var warnDaysBefore: Int?
    /// Kilometres before the odometer axis at which the status turns amber.
    public var warnKilometresBefore: Double?
    /// `nil` is a single instance: completing it closes it for good.
    public var recurrence: MaintenanceRecurrence?
    public var events: [MaintenanceEvent]
    /// A completed single instance. Kept rather than deleted — its events are history.
    public var closed: Bool

    public init(
        id: UUID, title: String, due: MaintenanceDue,
        warnDaysBefore: Int? = nil, warnKilometresBefore: Double? = nil,
        recurrence: MaintenanceRecurrence? = nil,
        events: [MaintenanceEvent] = [], closed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.warnDaysBefore = warnDaysBefore
        self.warnKilometresBefore = warnKilometresBefore
        self.recurrence = recurrence
        self.events = events
        self.closed = closed
    }
}

/// Everything maintenance, as one document — the same shape the fuel log takes, for the same
/// reason: one file, read whole, written whole, no partial states to reconcile.
public struct MaintenanceLog: Sendable, Equatable, Codable {
    public var items: [MaintenanceItem]

    public init(items: [MaintenanceItem] = []) {
        self.items = items
    }

    public static let empty = MaintenanceLog()
}

// MARK: - Status

/// Severity-ordered so a list's worst item is its `max()`.
public enum MaintenanceStatus: Int, Sendable, Equatable, Comparable {
    case ok = 0
    case warning = 1
    case due = 2

    public static func < (lhs: MaintenanceStatus, rhs: MaintenanceStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private let secondsPerDay: Double = 86_400

/// Where one item stands, given today and the bike's whereabouts on its own clock.
///
/// `odometer` is `nil` when the app cannot know it — no fill has recorded one — and an unknown
/// odometer keeps the km axis quiet rather than guessing: a phantom "chain oil due" teaches the
/// rider to ignore the real one.
///
/// The combinators follow their names exactly: `either` is the worse of the two axes (first to
/// arrive wins), `both` is the better (nothing is owed until the second arrives).
public func maintenanceStatus(
    _ item: MaintenanceItem, today: Date, odometer: Kilometres?
) -> MaintenanceStatus {
    guard !item.closed else { return .ok }

    func onDate(_ due: Date) -> MaintenanceStatus {
        guard today < due else { return .due }
        let warning = Double(item.warnDaysBefore ?? 0) * secondsPerDay
        return today.addingTimeInterval(warning) >= due ? .warning : .ok
    }
    func atOdometer(_ due: Kilometres) -> MaintenanceStatus {
        guard let odometer else { return .ok }
        guard odometer.rawValue < due.rawValue else { return .due }
        return odometer.rawValue + (item.warnKilometresBefore ?? 0) >= due.rawValue
            ? .warning : .ok
    }

    return switch item.due {
    case let .onDate(date): onDate(date)
    case let .atOdometer(km): atOdometer(km)
    case let .either(date, km): max(onDate(date), atOdometer(km))
    case let .both(date, km): min(onDate(date), atOdometer(km))
    }
}

/// The worst status across the log — the colour of the home-screen badge.
public func maintenanceStatus(
    of log: MaintenanceLog, today: Date, odometer: Kilometres?
) -> MaintenanceStatus {
    log.items.map { maintenanceStatus($0, today: today, odometer: odometer) }.max() ?? .ok
}

// MARK: - Spoken lines

/// One line per item with something to say; nothing for the healthy ones. These join the flight
/// plan's problems, so they inherit its rule: report by exception.
public func maintenanceAnnouncements(
    _ log: MaintenanceLog, today: Date, odometer: Kilometres?
) -> [String] {
    log.items.compactMap { item in
        switch maintenanceStatus(item, today: today, odometer: odometer) {
        case .ok: nil
        case .due: "\(item.title) is due"
        case .warning: warningLine(item, today: today, odometer: odometer)
        }
    }
}

/// "Chain oil due in 5 days", "due in 140 kilometres", or both joined by the combinator's own
/// word — "or" for either, "and" for both.
private func warningLine(
    _ item: MaintenanceItem, today: Date, odometer: Kilometres?
) -> String? {
    let days: String? = item.due.date.flatMap { due in
        let left = (due.timeIntervalSince(today) / secondsPerDay).rounded(.up)
        guard left > 0 else { return nil }
        return left == 1 ? "1 day" : "\(Int(left)) days"
    }
    let kilometres: String? = item.due.odometer.flatMap { due in
        guard let odometer else { return nil }
        let left = (due.rawValue - odometer.rawValue).rounded()
        guard left > 0 else { return nil }
        return "\(Int(left)) kilometres"
    }
    let joiner = MaintenanceDue.prism.both.preview(item.due) != nil ? " and " : " or "
    let parts = [days, kilometres].compactMap { $0 }
    guard !parts.isEmpty else { return nil }
    return "\(item.title) due in \(parts.joined(separator: joiner))"
}

// MARK: - Completion

/// The item after the work was done.
///
/// A single instance closes. A recurring one rolls its deadline forward **from the event** —
/// the next interval starts when the work happened, on whichever axes the recurrence names; an
/// axis the recurrence is silent about stays where it was.
public func completing(
    _ item: MaintenanceItem, with event: MaintenanceEvent
) -> MaintenanceItem {
    var next = item
    next.events.append(event)
    guard let recurrence = item.recurrence else {
        next.closed = true
        return next
    }
    func date(after old: Date) -> Date {
        recurrence.days.map { event.date.addingTimeInterval(Double($0) * secondsPerDay) } ?? old
    }
    func odometer(after old: Kilometres) -> Kilometres {
        recurrence.kilometres.map { Kilometres((event.odometer ?? old).rawValue + $0) } ?? old
    }
    next.due = switch item.due {
    case let .onDate(d): .onDate(date(after: d))
    case let .atOdometer(k): .atOdometer(odometer(after: k))
    case let .either(d, k): .either(date: date(after: d), odometer: odometer(after: k))
    case let .both(d, k): .both(date: date(after: d), odometer: odometer(after: k))
    }
    return next
}

// MARK: - The bike's odometer, reconstructed

/// The odometer now: the last fill that recorded one, plus what the app has measured since.
///
/// The trip counter resets at every fill, so the sum only holds when the *newest* fill carries a
/// reading — an older one would double- or under-count the gap between them. `nil` says the app
/// cannot know, which downstream treats as "say nothing about kilometres" rather than guessing.
public func currentOdometer(fuel: FuelLog, sinceFill: Kilometres) -> Kilometres? {
    fuel.refuelsNewestFirst.first.flatMap(\.odometer).map {
        Kilometres($0.rawValue + sinceFill.rawValue)
    }
}

// MARK: - The form's vocabulary

/// The four shapes a deadline can take, as a picker offers them. Separate from ``MaintenanceDue``
/// because a form chooses the shape before it has the values.
public enum MaintenanceAxis: String, Sendable, Equatable, CaseIterable, Codable {
    case date
    case odometer
    case either
    case both

    public var involvesDate: Bool { self != .odometer }
    public var involvesOdometer: Bool { self != .date }
}

// MARK: - Row summary

/// One line saying where an item stands — "in 12 days or 340 km", "5 days overdue", "done".
///
/// Pure over `today` so the screen shows the same arithmetic the announcements speak; `today` is
/// `nil` only before the first stamp arrives, and the answer degrades to the raw deadline.
public func maintenanceSummary(
    _ item: MaintenanceItem, today: Date?, odometer: Kilometres?
) -> String {
    guard !item.closed else { return "done" }
    let days: String? = item.due.date.map { due in
        guard let today else { return "by date" }
        let left = (due.timeIntervalSince(today) / secondsPerDay).rounded(.up)
        if left > 0 { return left == 1 ? "in 1 day" : "in \(Int(left)) days" }
        return left == 0 ? "today" : "\(Int(-left)) days overdue"
    }
    let kilometres: String? = item.due.odometer.map { due in
        guard let odometer else { return "at \(Int(due.rawValue)) km" }
        let left = (due.rawValue - odometer.rawValue).rounded()
        return left > 0 ? "in \(Int(left)) km" : "\(Int(-left)) km overdue"
    }
    let joiner = MaintenanceDue.prism.both.preview(item.due) != nil ? " and " : " or "
    return [days, kilometres].compactMap { $0 }.joined(separator: joiner)
}
