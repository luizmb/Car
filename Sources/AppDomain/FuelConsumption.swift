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

    /// Usable tank capacity, inferred from the largest brim fill ever recorded.
    ///
    /// A lower bound, not the manufacturer's figure: it is how much went in after the tank was run
    /// down the furthest so far, so it can only grow as the bike is run lower. That is the right
    /// direction to be wrong in — it under-promises range rather than stranding the rider.
    var observedTankCapacity: Litres? {
        brimToBrimFills.map(\.litres.rawValue).max().map { Litres($0) }
    }
}

// MARK: - Range

/// What is left, on the evidence available.
public struct RangeEstimate: Sendable, Equatable {
    public let litresRemaining: Double
    public let kilometresRemaining: Double
    /// Distance to the point the rider has historically switched to reserve — the figure that
    /// actually matters on this bike, since using reserve damages the carburettor.
    public let kilometresToReserve: Double?

    public init(litresRemaining: Double, kilometresRemaining: Double, kilometresToReserve: Double?) {
        self.litresRemaining = litresRemaining
        self.kilometresRemaining = kilometresRemaining
        self.kilometresToReserve = kilometresToReserve
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
    /// Needs a consumption figure and a capacity, so it returns `nil` until two brim fills exist.
    /// Returning nothing is the honest answer there — a guess about remaining fuel on a bike with a
    /// carburettor-damaging reserve is worse than silence.
    func range(travelled: Kilometres) -> RangeEstimate? {
        guard
            let consumption = consumption,
            let capacity = observedTankCapacity
        else { return nil }

        let used = travelled.rawValue / consumption.kilometresPerLitre
        let remaining = max(0, capacity.rawValue - used)
        return RangeEstimate(
            litresRemaining: remaining,
            kilometresRemaining: remaining * consumption.kilometresPerLitre,
            kilometresToReserve: typicalKilometresToReserve.map { max(0, $0 - travelled.rawValue) }
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
    formatDistance: (Double) -> String
) -> String? {
    guard let range = log.range(travelled: travelled) else {
        // One fill measures nothing, and saying so is more useful than a fabricated figure.
        return log.brimToBrimFills.count == 1
            ? "Fuel: one fill recorded, so no consumption figure yet."
            : nil
    }

    if let toReserve = range.kilometresToReserve, toReserve < 30 {
        return toReserve <= 0
            ? "Fuel: past your usual reserve point — expect reserve any time."
            : "Fuel: about \(formatDistance(toReserve)) before your usual reserve point."
    }
    return "Fuel: about \(formatDistance(range.kilometresRemaining)) left in the tank."
}
