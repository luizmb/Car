import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftRexSwiftUI
import SwiftUI

// MARK: - FuelFeature

/// Recording a visit to the pump.
///
/// Manual entry for now; the photograph-and-extract path comes later. What matters is that the
/// **schema** is right from the first fill, because a field not captured today can never be
/// backfilled — which is why brim, grade and odometer are all here despite none of them being used
/// by any calculation yet.
public enum FuelFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        // Typed as text rather than numbers: a half-typed "12." is not a Double, and a form that
        // fights the keyboard is a form you resent at a petrol station in the rain.
        public var litres: String = ""
        public var pricePerLitre: String = ""
        public var odometer: String = ""
        public var grade: FuelGrade = .e5
        /// Default true — it is true almost every time, and getting it wrong silently breaks the
        /// brim-to-brim maths rather than producing an obvious error.
        public var filledToBrim: Bool = true

        /// Captured when the screen opens, not when it is saved — the rider may be standing at the
        /// pump when they open it and sitting on the bike when they finish.
        public var latitude: Latitude?
        public var longitude: Longitude?

        /// The reserve tab keeps its own odometer field. Switching to reserve is not a refuel and
        /// shares nothing with one but the log it lands in, so a half-typed fill must not leak
        /// into a reserve record or vice versa.
        public var reserveOdometer: String = ""
        public var tab: FuelTab = .refuel

        public var log: FuelLog = .empty
        public var saveError: String?

        public init() {}

        /// Save is blocked until the two fields the maths cannot work without are present.
        public var isValid: Bool {
            (Double(litres) ?? 0) > 0 && (Double(pricePerLitre) ?? 0) > 0
        }

        public var totalCost: Double? {
            guard let l = Double(litres), let p = Double(pricePerLitre) else { return nil }
            return l * p
        }
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case appeared
        case setTab(FuelTab)
        case setReserveOdometer(String)
        case setLitres(String)
        case setPrice(String)
        case setOdometer(String)
        case setGrade(FuelGrade)
        case setFilledToBrim(Bool)
        case setPosition(Latitude, Longitude)
        case loaded(FuelLog)
        case save
        case saved
        case saveFailed(String)
        /// The main tank just ran dry. Logged separately because it is a *better* calibration point
        /// than a brim fill — it pins consumption to the main tank's exact capacity.
        case engageReserve
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let loadFuelLog: @Sendable () -> Publisher<Result<FuelLog, FileError>, Never>
        public let saveFuelLog: @Sendable (FuelLog) -> Publisher<Result<Void, FileError>, Never>
        public let now: @Sendable () -> Date
        public let newID: @Sendable () -> UUID

        public init(
            loadFuelLog: @escaping @Sendable () -> Publisher<Result<FuelLog, FileError>, Never>,
            saveFuelLog: @escaping @Sendable (FuelLog) -> Publisher<Result<Void, FileError>, Never>,
            now: @escaping @Sendable () -> Date,
            newID: @escaping @Sendable () -> UUID
        ) {
            self.loadFuelLog = loadFuelLog
            self.saveFuelLog = saveFuelLog
            self.now = now
            self.newID = newID
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {
            case .appeared:
                return .produce { ctx in
                    // A missing file is the normal first-run state, not an error worth reporting;
                    // only a *malformed* one deserves attention, and even then an empty log lets the
                    // rider record today's fill rather than blocking them.
                    ctx.environment.loadFuelLog()
                        .asEffect { (result: Result<FuelLog, FileError>) in
                            Action.loaded((try? result.get()) ?? .empty)
                        }
                }

            case let .loaded(log):
                return .reduce { $0.log = log }

            case let .setLitres(value):        return .reduce { $0.litres = value }
            case let .setPrice(value):         return .reduce { $0.pricePerLitre = value }
            case let .setOdometer(value):      return .reduce { $0.odometer = value }
            case let .setReserveOdometer(value): return .reduce { $0.reserveOdometer = value }
            case let .setTab(tab):             return .reduce { $0.tab = tab }
            case let .setGrade(grade):         return .reduce { $0.grade = grade }
            case let .setFilledToBrim(value):  return .reduce { $0.filledToBrim = value }
            case let .setPosition(lat, lon):
                return .reduce {
                    // Only the first fix — the position wanted is the forecourt, not wherever the
                    // rider happened to drift to while typing.
                    guard $0.latitude == nil else { return }
                    $0.latitude = lat
                    $0.longitude = lon
                }

            case .save:
                guard let state = context.stateBefore, state.isValid else { return .doNothing }
                return .produce { ctx in
                    let record = RefuelRecord(
                        id: ctx.environment.newID(),
                        date: ctx.environment.now(),
                        litres: Litres(Double(state.litres) ?? 0),
                        pricePerLitre: Double(state.pricePerLitre) ?? 0,
                        grade: state.grade,
                        filledToBrim: state.filledToBrim,
                        odometer: Double(state.odometer).map { Kilometres($0) },
                        latitude: state.latitude,
                        longitude: state.longitude
                    )
                    var log = state.log
                    log.refuels.append(record)
                    return ctx.environment.saveFuelLog(log)
                        .asEffect { (result: Result<Void, FileError>) in
                            switch result {
                            case .success:            Action.saved
                            case let .failure(error): Action.saveFailed(String(describing: error))
                            }
                        }
                }

            case .saved:
                return .reduce {
                    // Clear the forms but keep the log, so another entry can follow immediately
                    // and the history stays on screen as confirmation it landed.
                    $0.litres = ""
                    $0.pricePerLitre = ""
                    $0.odometer = ""
                    $0.reserveOdometer = ""
                    $0.saveError = nil
                }
                .produce { ctx in
                    ctx.environment.loadFuelLog()
                        .asEffect { (result: Result<FuelLog, FileError>) in
                            Action.loaded((try? result.get()) ?? .empty)
                        }
                }

            case let .saveFailed(message):
                return .reduce { $0.saveError = message }

            case .engageReserve:
                guard let state = context.stateBefore else { return .doNothing }
                return .produce { ctx in
                    let event = ReserveEvent(
                        id: ctx.environment.newID(),
                        date: ctx.environment.now(),
                        odometer: Double(state.reserveOdometer).map { Kilometres($0) },
                        gpsKilometres: nil,
                        latitude: state.latitude,
                        longitude: state.longitude
                    )
                    var log = state.log
                    log.reserves.append(event)
                    return ctx.environment.saveFuelLog(log)
                        .asEffect { (result: Result<Void, FileError>) in
                            switch result {
                            case .success:            Action.saved
                            case let .failure(error): Action.saveFailed(String(describing: error))
                            }
                        }
                }
            }
        }
    }
}

extension FuelFeature: HasBehavior {}
