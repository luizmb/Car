import FP
import FPMacros
import Foundation

// MARK: - Units

public enum LitresTag {}
public typealias Litres = Newtype<LitresTag, Double>

public enum KilometresTag {}
public typealias Kilometres = Newtype<KilometresTag, Double>

// MARK: - Fuel grade

/// E5 is the preferred grade; E10 only when nothing else is available.
///
/// Recorded because it plausibly matters: E10 carries more ethanol, which has lower energy density,
/// so a tank of it should give slightly worse economy. Whether that shows up above the noise is a
/// question for the data, not for an assumption — but it cannot be answered at all unless it is
/// logged from the first fill.
@Prisms
public enum FuelGrade: String, Sendable, Equatable, CaseIterable, Codable {
    case e5 = "E5"
    case e10 = "E10"

    public var label: String { rawValue }
}

/// Switching to reserve is not a refuel — different data, different meaning, different moment —
/// so the two are separate tabs rather than a destructive button on a form about something else.
@Prisms
public enum FuelTab: String, Sendable, Equatable, CaseIterable, Codable {
    case refuel = "Refuel"
    case reserve = "Reserve"
    /// The consumption history — the reason the other two tabs collect what they collect.
    case stats = "Stats"

    public var label: String { rawValue }
}

/// How the stats tab shows its legs.
public enum ConsumptionDisplay: String, Sendable, Equatable, CaseIterable {
    case table = "Table"
    case chart = "Chart"

    public var label: String { rawValue }
}

// MARK: - Refuel record

/// One visit to a pump.
///
/// Date and position are captured automatically, which is not merely convenience: position
/// identifies the *station*, and stations differ in price and — if a tank is contaminated or a pump
/// mis-calibrated — in what you actually receive. A consumption outlier traceable to one forecourt
/// is a finding; the same outlier with no location is noise.
public struct RefuelRecord: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let date: Date
    public let litres: Litres
    public let pricePerLitre: Double
    public let grade: FuelGrade

    /// **Critical to the maths.** Brim-to-brim only measures consumption if *both* ends are to the
    /// same level. A partial fill silently breaks the equation, so it has to be recorded rather
    /// than assumed — even though it is true almost every time.
    public let filledToBrim: Bool

    /// GPS distance since the previous fill, measured by the app.
    ///
    /// The figure consumption is computed from. Recorded alongside the odometer rather than
    /// instead of it, so the two can be compared and the odometer's drift measured over time.
    public let gpsKilometres: Kilometres?

    /// The bike's own odometer, recorded for comparison only.
    ///
    /// Never an input to any calculation. It is a slowly-converging calibration measurement: the
    /// display shows whole kilometres, so a single fill carries ±1 km of quantisation, and only
    /// across many fills does a real bias separate from that noise.
    public let odometer: Kilometres?

    /// Where the pump was. `nil` if there was no fix — better an honest gap than a guess.
    public let latitude: Latitude?
    public let longitude: Longitude?

    /// Where it was filled, resolved at the moment of recording.
    ///
    /// Optional because Overpass may be slow or unreachable on a forecourt, and a fill with no
    /// station is worth more than no fill. But it can only be captured *now* — attributing a
    /// coordinate to a station afterwards means clustering by hand, so a fill saved without it never
    /// gets one.
    public let station: FuelStation?

    public init(
        id: UUID, date: Date, litres: Litres, pricePerLitre: Double, grade: FuelGrade,
        filledToBrim: Bool, odometer: Kilometres?, gpsKilometres: Kilometres? = nil,
        latitude: Latitude?, longitude: Longitude?, station: FuelStation? = nil
    ) {
        self.id = id
        self.date = date
        self.litres = litres
        self.pricePerLitre = pricePerLitre
        self.grade = grade
        self.filledToBrim = filledToBrim
        self.odometer = odometer
        self.gpsKilometres = gpsKilometres
        self.latitude = latitude
        self.longitude = longitude
        self.station = station
    }

    public var totalCost: Double { litres.rawValue * pricePerLitre }
}

// MARK: - Reserve

/// The moment the main tank ran dry and the reserve was opened.
///
/// A *better* calibration point than a brim fill: it pins the exact volume consumed to the main
/// tank's capacity, with no dependence on how carefully the last fill was topped off. Also the
/// event this whole feature exists to prevent — every one of these damages the carburettor.
public struct ReserveEvent: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let date: Date
    /// The bike's own reading, for the odometer-drift comparison.
    public let odometer: Kilometres?
    /// Distance measured by the app since the last fill.
    ///
    /// Recorded *alongside* the odometer rather than instead of it. This is the number the fuel
    /// maths will actually use — the odometer shows whole kilometres and is the thing being
    /// calibrated, not the thing to calibrate against.
    public let gpsKilometres: Kilometres?
    public let latitude: Latitude?
    public let longitude: Longitude?

    public init(
        id: UUID, date: Date, odometer: Kilometres?, gpsKilometres: Kilometres? = nil,
        latitude: Latitude?, longitude: Longitude?
    ) {
        self.id = id
        self.date = date
        self.odometer = odometer
        self.gpsKilometres = gpsKilometres
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Log

/// Everything recorded about fuel, as one persisted document.
public struct FuelLog: Sendable, Equatable, Codable {
    public var refuels: [RefuelRecord]
    public var reserves: [ReserveEvent]

    public init(refuels: [RefuelRecord] = [], reserves: [ReserveEvent] = []) {
        self.refuels = refuels
        self.reserves = reserves
    }

    public static let empty = FuelLog()
}

public extension FuelLog {
    /// Most recent first — how a human wants to read a list, and how the maths wants to walk it.
    var refuelsNewestFirst: [RefuelRecord] { refuels.sorted { $0.date > $1.date } }

    /// Litres between two consecutive brim fills is a consumption measurement; anything involving a
    /// partial fill is not, and is excluded rather than approximated.
    var brimToBrimFills: [RefuelRecord] { refuels.filter(\.filledToBrim).sorted { $0.date < $1.date } }

    /// Odometer distance between consecutive brim fills, paired with the litres that filled it.
    ///
    /// This is the training set for the consumption model. It stays empty until there are two brim
    /// fills with odometer readings — which is correct: one fill measures nothing.
    var consumptionSamples: [(kilometres: Double, litres: Double, to: RefuelRecord)] {
        zip(brimToBrimFills, brimToBrimFills.dropFirst()).compactMap { previous, current in
            // GPS first: it is continuous, whereas the odometer shows whole kilometres and carries
            // ±1 km of quantisation per fill. The odometer is the fallback for fills recorded
            // before distance tracking existed.
            if let gps = current.gpsKilometres?.rawValue, gps > 0 {
                return (gps, current.litres.rawValue, current)
            }
            guard
                let from = previous.odometer?.rawValue,
                let to = current.odometer?.rawValue,
                to > from
            else { return nil }
            return (to - from, current.litres.rawValue, current)
        }
    }
}
