import AppDomain
import FP
import FPMacros
import Foundation
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftRexSwiftUI
import SwiftUI

// MARK: - MaintenanceFeature

/// What the bike needs doing, and when.
///
/// Two kinds of deadline — a calendar date and an odometer reading — and two ways to combine them,
/// because that is how service schedules are actually written: "12 months or 12,000 km" is a race,
/// "two years and 20,000 km" is a conjunction. The odometer the km axis runs on is reconstructed,
/// not read: the last fill that recorded one plus what the app has measured since — the app is the
/// only instrument this bike has.
public enum MaintenanceFeature {

    // MARK: Drafts

    /// The creation form, whole, as one value. Every keystroke comes through the store — the form
    /// *is* this struct, and the sheet renders whatever it says.
    public struct Draft: Sendable, Equatable {
        public var title = ""
        /// `false` is a single instance; `true` adds the recurrence fields and renames the
        /// deadline "next".
        public var periodic = false
        public var axis: MaintenanceAxis = .date
        public var dueDate: Date
        public var dueOdometer = ""
        public var warnDays = ""
        public var warnKilometres = ""
        public var recurDays = ""
        public var recurKilometres = ""

        public init(dueDate: Date) {
            self.dueDate = dueDate
        }
    }

    /// The "work was done" form. Seeded with now, the reconstructed odometer and the last fix —
    /// all editable except the place, which is captured or absent, like a refuel's forecourt.
    public struct EventDraft: Sendable, Equatable {
        public var itemID: UUID
        public var date: Date
        public var odometer: String
        public var notes = ""
        public var latitude: Latitude?
        public var longitude: Longitude?

        public init(
            itemID: UUID, date: Date, odometer: String,
            latitude: Latitude? = nil, longitude: Longitude? = nil
        ) {
            self.itemID = itemID
            self.date = date
            self.odometer = odometer
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    // MARK: State

    public struct State: Sendable, Equatable {
        public var items: [MaintenanceItem] = []
        public var isLoading = false
        /// Stamped on appearance so the rows can say "in 12 days" without the view asking a clock.
        public var today: Date?
        /// The bike's odometer as reconstructed by the app — `nil` when no fill has recorded one.
        public var currentOdometer: Kilometres?
        /// The last GPS fix, for stamping onto an event.
        public var lastKnown: Coordinate?
        public var draft: Draft?
        public var eventDraft: EventDraft?

        public init() {}
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case appeared
        case todayIs(Date)
        /// The app answers what only it knows: the reconstructed odometer and the last fix.
        case contextResolved(Kilometres?, Coordinate?)
        case loaded(MaintenanceLog)
        case newDraft
        case draftEdited(Draft?)
        case saveDraft
        case delete(UUID)
        case beginEvent(UUID)
        case eventEdited(EventDraft?)
        case saveEvent
        /// The log as it now stands on disk. Also observed at app level, which keeps its own copy
        /// for the briefing and the home badge.
        case persisted(MaintenanceLog)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let load: @Sendable () -> Publisher<Result<MaintenanceLog, FileError>, Never>
        public let save: @Sendable (MaintenanceLog) -> Publisher<Result<Void, FileError>, Never>
        public let now: @Sendable () -> Date
        public let newID: @Sendable () -> UUID
        public let parseNumber: @Sendable (String) -> Result<Double, NumberError>

        public init(
            load: @escaping @Sendable () -> Publisher<Result<MaintenanceLog, FileError>, Never>,
            save: @escaping @Sendable (MaintenanceLog) -> Publisher<Result<Void, FileError>, Never>,
            now: @escaping @Sendable () -> Date,
            newID: @escaping @Sendable () -> UUID,
            parseNumber: @escaping @Sendable (String) -> Result<Double, NumberError>
        ) {
            self.load = load
            self.save = save
            self.now = now
            self.newID = newID
            self.parseNumber = parseNumber
        }

        func number(_ text: String) -> Double? {
            text.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : try? parseNumber(text).get()
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {
            case .appeared:
                return .reduce { $0.isLoading = true }
                    .produce { ctx in
                        Effect.just(.todayIs(ctx.environment.now()))
                            <> ctx.environment.load().asEffect {
                                (result: Result<MaintenanceLog, FileError>) in
                                Action.loaded((try? result.get()) ?? .empty)
                            }
                    }

            case let .todayIs(date):
                return .reduce { $0.today = date }

            case let .contextResolved(odometer, place):
                return .reduce {
                    $0.currentOdometer = odometer
                    $0.lastKnown = place
                }

            case let .loaded(log):
                return .reduce {
                    $0.items = log.items
                    $0.isLoading = false
                }

            case .newDraft:
                // The seed needs a clock, which reducers do not have — so the draft is minted in
                // an effect and arrives like any other edit.
                return .produce { ctx in
                    Effect.just(.draftEdited(Draft(dueDate: ctx.environment.now())))
                }

            case let .draftEdited(draft):
                return .reduce { $0.draft = draft }

            case .saveDraft:
                guard let state = context.stateBefore, let draft = state.draft
                else { return .doNothing }
                let items = state.items
                return .produce { ctx in
                    guard let item = item(from: draft, id: ctx.environment.newID(), ctx.environment)
                    else { return .empty }
                    let log = MaintenanceLog(items: items + [item])
                    return ctx.environment.save(log).asEffect { (_: Result<Void, FileError>) in Action.persisted(log) }
                }

            case let .delete(id):
                guard let items = context.stateBefore?.items else { return .doNothing }
                let log = MaintenanceLog(items: items.filter { $0.id != id })
                return .produce { ctx in
                    ctx.environment.save(log).asEffect { (_: Result<Void, FileError>) in Action.persisted(log) }
                }

            case let .beginEvent(id):
                guard let state = context.stateBefore else { return .doNothing }
                return .produce { ctx in
                    Effect.just(.eventEdited(EventDraft(
                        itemID: id,
                        date: ctx.environment.now(),
                        odometer: state.currentOdometer.map { String(Int($0.rawValue)) } ?? "",
                        latitude: state.lastKnown?.latitude,
                        longitude: state.lastKnown?.longitude
                    )))
                }

            case let .eventEdited(draft):
                return .reduce { $0.eventDraft = draft }

            case .saveEvent:
                guard
                    let state = context.stateBefore,
                    let draft = state.eventDraft,
                    state.items.contains(where: { $0.id == draft.itemID })
                else { return .doNothing }
                let items = state.items
                return .produce { ctx in
                    let event = MaintenanceEvent(
                        id: ctx.environment.newID(),
                        date: draft.date,
                        odometer: ctx.environment.number(draft.odometer).map { Kilometres($0) },
                        latitude: draft.latitude,
                        longitude: draft.longitude,
                        notes: draft.notes
                    )
                    let log = MaintenanceLog(items: items.map {
                        $0.id == draft.itemID ? completing($0, with: event) : $0
                    })
                    return ctx.environment.save(log).asEffect { (_: Result<Void, FileError>) in Action.persisted(log) }
                }

            case let .persisted(log):
                return .reduce {
                    $0.items = log.items
                    $0.draft = nil
                    $0.eventDraft = nil
                }
            }
        }
    }
}

extension MaintenanceFeature: HasBehavior {}

// MARK: - Draft → item

/// The form, validated into a value — or `nil`, which the Save button's enablement mirrors.
///
/// The rules are the form's own promises: a title, a value for every axis the shape names, and a
/// periodic item must actually recur on something.
func item(
    from draft: MaintenanceFeature.Draft, id: UUID, _ environment: MaintenanceFeature.Environment
) -> MaintenanceItem? {
    let title = draft.title.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }

    let odometer = environment.number(draft.dueOdometer).map { Kilometres($0) }
    let due: MaintenanceDue? = switch draft.axis {
    case .date: .onDate(draft.dueDate)
    case .odometer: odometer.map(MaintenanceDue.atOdometer)
    case .either: odometer.map { .either(date: draft.dueDate, odometer: $0) }
    case .both: odometer.map { .both(date: draft.dueDate, odometer: $0) }
    }
    guard let due else { return nil }

    let recurrence: MaintenanceRecurrence? = draft.periodic
        ? MaintenanceRecurrence(
            days: environment.number(draft.recurDays).map { Int($0) },
            kilometres: environment.number(draft.recurKilometres)
        )
        : nil
    if draft.periodic, recurrence?.days == nil, recurrence?.kilometres == nil { return nil }

    return MaintenanceItem(
        id: id,
        title: title,
        due: due,
        warnDaysBefore: environment.number(draft.warnDays).map { Int($0) },
        warnKilometresBefore: environment.number(draft.warnKilometres),
        recurrence: recurrence
    )
}
