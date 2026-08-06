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
        /// GPS distance since the last fill, pushed in from the trip counter. This is what the
        /// consumption maths uses; the odometer field beside it is what is being calibrated.
        public var gpsKilometres: Kilometres?

        /// The reserve tab keeps its own odometer field. Switching to reserve is not a refuel and
        /// shares nothing with one but the log it lands in, so a half-typed fill must not leak
        /// into a reserve record or vice versa.
        public var reserveOdometer: String = ""
        public var tab: FuelTab = .refuel

        /// The forecourt, resolved once when the position first arrives.
        ///
        /// Looked up on arrival rather than on save so the network round trip happens while the
        /// rider is still typing, and a slow Overpass never delays the button.
        public var station: FuelStation?

        public var log: FuelLog = .empty
        public var saveError: String?

        public init() {}

        // The parsed values, kept beside the text they came from.
        //
        // Parsing happens once per keystroke in the behaviour, where the World's `parseNumber` is
        // reachable — not here. `State` is a value and cannot ask anything how a number is written;
        // `Double(_:)` accepts only a period, which read every field as zero on a comma-decimal
        // keypad and greyed out Save with nothing on screen to explain it.
        public var litresValue: Double?
        public var priceValue: Double?
        public var odometerValue: Double?
        public var reserveOdometerValue: Double?

        /// Save is blocked until the two fields the maths cannot work without are present.
        public var isValid: Bool {
            (litresValue ?? 0) > 0 && (priceValue ?? 0) > 0
        }

        public var totalCost: Double? {
            guard let litresValue, let priceValue else { return nil }
            return litresValue * priceValue
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
        case setGPSDistance(Kilometres)
        case loaded(FuelLog)
        /// A field's text, read as a number by the World. Separate from the setter because parsing
        /// needs the environment and a reduction cannot reach it.
        case parsed(NumericField, Double?)
        /// The forecourt for the captured position. `nil` means Overpass had nothing or could not
        /// be reached — a fill with no station is worth far more than no fill.
        case stationResolved(FuelStation?)
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
        /// Written straight to the journey log, bypassing the "a journey must be running" gate.
        ///
        /// A refuel happens *between* journeys by definition: you pull in, the keys come out and
        /// journey A ends, you fill up, the keys go back in and journey B starts. Gated on riding it
        /// would land in the gap and be dropped from the one file meant to keep it — and it is the
        /// record every fuel calculation is built on. Switching to reserve is the same shape.
        public let logJourney: @Sendable (any JourneyPayloadType) -> Publisher<Void, Never>
        /// How this device writes and reads numbers. A `NumberFormatter` is not a primitive and
        /// stops at the World, so the feature gets the operation rather than the object.
        public let parseNumber: @Sendable (String) -> Result<Double, NumberError>
        /// The forecourt at a position, resolved while the rider types.
        public let fetchStation: @Sendable (Latitude, Longitude) -> Publisher<FuelStation?, Never>

        public init(
            loadFuelLog: @escaping @Sendable () -> Publisher<Result<FuelLog, FileError>, Never>,
            saveFuelLog: @escaping @Sendable (FuelLog) -> Publisher<Result<Void, FileError>, Never>,
            now: @escaping @Sendable () -> Date,
            newID: @escaping @Sendable () -> UUID,
            logJourney: @escaping @Sendable (any JourneyPayloadType) -> Publisher<Void, Never>,
            parseNumber: @escaping @Sendable (String) -> Result<Double, NumberError>,
            fetchStation: @escaping @Sendable (Latitude, Longitude) -> Publisher<FuelStation?, Never>
        ) {
            self.loadFuelLog = loadFuelLog
            self.saveFuelLog = saveFuelLog
            self.now = now
            self.newID = newID
            self.logJourney = logJourney
            self.parseNumber = parseNumber
            self.fetchStation = fetchStation
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

            case let .setLitres(value):
                return .reduce { $0.litres = value }.produce(parsing: value, as: .litres)
            case let .setPrice(value):
                return .reduce { $0.pricePerLitre = value }.produce(parsing: value, as: .price)
            case let .setOdometer(value):
                return .reduce { $0.odometer = value }.produce(parsing: value, as: .odometer)
            case let .setReserveOdometer(value):
                return .reduce { $0.reserveOdometer = value }.produce(parsing: value, as: .reserveOdometer)

            case let .stationResolved(station):
                return .reduce { $0.station = station }

            case let .parsed(field, value):
                return .reduce {
                    switch field {
                    case .litres: $0.litresValue = value
                    case .price: $0.priceValue = value
                    case .odometer: $0.odometerValue = value
                    case .reserveOdometer: $0.reserveOdometerValue = value
                    }
                }
            case let .setTab(tab):             return .reduce { $0.tab = tab }
            case let .setGrade(grade):         return .reduce { $0.grade = grade }
            case let .setFilledToBrim(value):  return .reduce { $0.filledToBrim = value }
            case let .setGPSDistance(distance):
                return .reduce { $0.gpsKilometres = distance }

            case let .setPosition(lat, lon):
                let alreadyPlaced = context.stateBefore?.latitude != nil
                return .reduce {
                    // Only the first fix — the position wanted is the forecourt, not wherever the
                    // rider happened to drift to while typing.
                    guard $0.latitude == nil else { return }
                    $0.latitude = lat
                    $0.longitude = lon
                }
                .produce { ctx in
                    // Resolved once, on the first fix, for the same reason: the station is where the
                    // pump is, and a second lookup would only ever be less right.
                    guard !alreadyPlaced else { return .empty }
                    return ctx.environment.fetchStation(lat, lon)
                        .asEffect(Action.stationResolved)
                }

            case .save:
                guard let state = context.stateBefore, state.isValid else { return .doNothing }
                return .produce { ctx in
                    let record = RefuelRecord(
                        id: ctx.environment.newID(),
                        date: ctx.environment.now(),
                        litres: Litres(state.litresValue ?? 0),
                        pricePerLitre: state.priceValue ?? 0,
                        grade: state.grade,
                        filledToBrim: state.filledToBrim,
                        odometer: state.odometerValue.map { Kilometres($0) },
                        // The first fill ever has no "since the last fill" to measure: the trip
                        // counter was reset when the app first ran, not at a forecourt, so the
                        // number is distance since installation and means nothing. Every other
                        // record's `gpsKilometres` is a real interval, and storing a different
                        // meaning in the same field on one row is a trap for whatever reads it next.
                        gpsKilometres: state.log.refuels.isEmpty ? nil : state.gpsKilometres,
                        latitude: state.latitude,
                        longitude: state.longitude,
                        station: state.station
                    )
                    var log = state.log
                    log.refuels.append(record)
                    let keep = ctx.environment.logJourney(RefuelPayload(
                        litres: record.litres.rawValue,
                        price: record.pricePerLitre,
                        odometer: record.odometer?.rawValue,
                        brim: record.filledToBrim,
                        station: record.station?.label,
                        stationID: record.station?.id
                    )) |> Effect<Action>.fireAndForget
                    return keep <> ctx.environment.saveFuelLog(log)
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
                    $0.litresValue = nil
                    $0.priceValue = nil
                    $0.odometerValue = nil
                    $0.reserveOdometerValue = nil
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
                        odometer: state.reserveOdometerValue.map { Kilometres($0) },
                        // The first fill ever has no "since the last fill" to measure: the trip
                        // counter was reset when the app first ran, not at a forecourt, so the
                        // number is distance since installation and means nothing. Every other
                        // record's `gpsKilometres` is a real interval, and storing a different
                        // meaning in the same field on one row is a trap for whatever reads it next.
                        gpsKilometres: state.log.refuels.isEmpty ? nil : state.gpsKilometres,
                        latitude: state.latitude,
                        longitude: state.longitude
                    )
                    var log = state.log
                    log.reserves.append(event)
                    let keep = ctx.environment.logJourney(
                        ReservePayload(
                            km: event.gpsKilometres?.rawValue,
                            odometer: event.odometer?.rawValue
                        )
                    ) |> Effect<Action>.fireAndForget
                    return keep <> ctx.environment.saveFuelLog(log)
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


// MARK: - Field parsing

/// Which text field a parsed number belongs to.
public enum NumericField: Sendable, Equatable {
    case litres
    case price
    case odometer
    case reserveOdometer
}

private extension Reaction<FuelFeature.Action, FuelFeature.State, FuelFeature.Environment> {
    /// Reads the text through the World and folds the result back as a `.parsed` action.
    ///
    /// A failure becomes `nil` rather than an error on screen: an empty or half-typed field is the
    /// normal state of a form, not a mistake, and Save being quietly disabled says enough.
    func produce(parsing text: String, as field: NumericField) -> Self {
        produce { ctx in
            let value: Double? = if case let .success(number) = ctx.environment.parseNumber(text) {
                number
            } else {
                nil
            }
            return Effect.just(.parsed(field, value))
        }
    }
}
