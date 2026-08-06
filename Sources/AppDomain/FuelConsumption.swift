import FP
import Foundation

// MARK: - Consumption

/// How much fuel the bike actually uses, measured rather than assumed.
public struct ConsumptionEstimate: Sendable, Equatable {
    public let kilometresPerLitre: Double
    /// How many brim-to-brim intervals it is based on. One is a data point; several is a figure.
    public let sampleCount: Int
    /// Averaged over the same intervals, so it reflects what was actually paid rather than today's
    /// pump price.
    public let costPerKilometre: Double?

    public var litresPer100km: Double { 100 / kilometresPerLitre }

    /// Imperial gallons — the unit UK riders actually compare in, and 20% larger than the US one.
    public var milesPerGallon: Double { kilometresPerLitre * 4.546_09 / 1.609_344 }

    public init(kilometresPerLitre: Double, sampleCount: Int, costPerKilometre: Double?) {
        self.kilometresPerLitre = kilometresPerLitre
        self.sampleCount = sampleCount
        self.costPerKilometre = costPerKilometre
    }
}

public extension FuelLog {
    /// Consumption across every brim-to-brim interval.
    ///
    /// **Total distance over total litres**, not the mean of each interval's ratio. Those differ,
    /// and the mean-of-ratios is wrong: it weights a 30 km interval the same as a 300 km one, so one
    /// short town trip can drag the figure further than a tankful of motorway. Aggregating first
    /// weights each interval by the distance it actually covered, which is what "how much fuel does
    /// this bike use" means.
    var consumption: ConsumptionEstimate? {
        let samples = consumptionSamples
        guard !samples.isEmpty else { return nil }

        let kilometres = samples.reduce(0) { $0 + $1.kilometres }
        let litres = samples.reduce(0) { $0 + $1.litres }
        guard kilometres > 0, litres > 0 else { return nil }

        let spend = samples.reduce(0) { $0 + $1.litres * $1.to.pricePerLitre }
        return ConsumptionEstimate(
            kilometresPerLitre: kilometres / litres,
            sampleCount: samples.count,
            costPerKilometre: spend > 0 ? spend / kilometres : nil
        )
    }

    /// The most recent interval on its own.
    ///
    /// Worth having beside the average: a single bad tankful is how you notice a problem — a
    /// throttle held open, a choke left out, or a carburettor drifting rich — while the lifetime
    /// average is still busy absorbing it.
    var latestConsumption: ConsumptionEstimate? {
        guard let sample = consumptionSamples.last, sample.kilometres > 0, sample.litres > 0 else {
            return nil
        }
        return ConsumptionEstimate(
            kilometresPerLitre: sample.kilometres / sample.litres,
            sampleCount: 1,
            costPerKilometre: sample.to.pricePerLitre > 0
                ? sample.litres * sample.to.pricePerLitre / sample.kilometres
                : nil
        )
    }

    /// The largest brim fill ever recorded.
    ///
    /// Evidence about the main tank only, and only from intervals where reserve was untouched —
    /// which is why ``usableBeforeReserve(spec:)`` is the figure to use rather than this one.
    var largestBrimFill: Litres? {
        brimToBrimFills.map(\.litres.rawValue).max().map { Litres($0) }
    }
}

// MARK: - Range

/// What is left, on the evidence available.
///
/// Two figures, and only the first is a target. Reaching reserve on this bike means running the
/// carburettor on the dirt at the bottom of the tank, so `kilometresToReserve` is the number the
/// rider plans around and `kilometresToDry` is the emergency margin once that has already gone
/// wrong — never something to aim at.
public struct RangeEstimate: Sendable, Equatable {
    public let litresBeforeReserve: Double
    public let kilometresToReserve: Double
    public let kilometresToDry: Double

    public init(litresBeforeReserve: Double, kilometresToReserve: Double, kilometresToDry: Double) {
        self.litresBeforeReserve = litresBeforeReserve
        self.kilometresToReserve = kilometresToReserve
        self.kilometresToDry = kilometresToDry
    }
}

public extension FuelLog {
    /// Where reserve has typically been reached, measured from each fill.
    ///
    /// This is the number the rider needs and no instrument provides: the bike has no fuel gauge and
    /// no low-fuel light, and reaching reserve is a mechanical problem rather than a warning. Each
    /// reserve event is paired with the fill before it, so the answer is in kilometres since filling.
    var typicalKilometresToReserve: Double? {
        let fills = refuels.sorted { $0.date < $1.date }
        let distances = reserves.compactMap { reserve -> Double? in
            // GPS distance since the last fill is recorded on the reserve event itself; the odometer
            // pair is the fallback for events recorded before that existed.
            if let km = reserve.gpsKilometres?.rawValue, km > 0 { return km }
            guard
                let previous = fills.last(where: { $0.date < reserve.date }),
                let from = previous.odometer?.rawValue,
                let to = reserve.odometer?.rawValue,
                to > from
            else { return nil }
            return to - from
        }
        guard !distances.isEmpty else { return nil }
        return distances.reduce(0, +) / Double(distances.count)
    }

    /// What is left after `travelled` kilometres on the current tank.
    ///
    /// Capacity comes from the spec rather than from measurement, because brim-to-brim cannot
    /// discover where the reserve tap sits — reserve is a *level*, not a rate, and the only way to
    /// measure it is to reach it, which is the thing being avoided. Consumption is measured; the
    /// tank is specified. See ``BikeSpec``.
    ///
    /// Still `nil` until consumption exists: a range figure needs both, and inventing one on a bike
    /// with no fuel gauge is worse than saying nothing.
    func range(travelled: Kilometres, spec: BikeSpec) -> RangeEstimate? {
        guard let consumption else { return nil }

        let usable = usableBeforeReserve(spec: spec).rawValue
        let used = travelled.rawValue / consumption.kilometresPerLitre
        let beforeReserve = max(0, usable - used)
        let onReserve = spec.reserveLitres.rawValue

        return RangeEstimate(
            litresBeforeReserve: beforeReserve,
            kilometresToReserve: beforeReserve * consumption.kilometresPerLitre,
            kilometresToDry: (beforeReserve + onReserve) * consumption.kilometresPerLitre
        )
    }
}

// MARK: - Spoken

/// The fuel picture, for the briefing.
///
/// Reserve distance leads when it is close, because it is the only part that is actionable: running
/// onto reserve is a repair, not an inconvenience.
public func fuelSummary(
    _ log: FuelLog,
    travelled: Kilometres,
    spec: BikeSpec,
    formatDistance: (Double) -> String
) -> String? {
    // The distance and the odometer it started from lead, because they are facts rather than
    // estimates — and on a bike with no working trip meter, "how far since I filled up" is itself
    // information the rider cannot otherwise get.
    let since = log.refuelsNewestFirst.first.flatMap(\.odometer).map {
        "\(formatDistance(travelled.rawValue)) since your last fill at \(Int($0.rawValue))."
    } ?? "\(formatDistance(travelled.rawValue)) since your last fill."

    guard let range = log.range(travelled: travelled, spec: spec) else {
        // One fill measures nothing, and saying so is more useful than a fabricated figure.
        return log.refuels.isEmpty ? nil : since + " No consumption figure yet."
    }

    if range.kilometresToReserve <= 0 {
        // Past the estimate entirely. Reserve is a repair on this bike, so this is stated as a
        // instruction rather than an observation.
        return since + " You are past the estimate — fill up before you reach reserve."
    }
    return since + " About \(formatDistance(range.kilometresToReserve)) before reserve."
}
