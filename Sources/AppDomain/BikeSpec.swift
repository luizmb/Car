import FP
import Foundation

/// The bike's fuel figures.
///
/// Deliberately not "the manual says". There is no manual to hand, and it would be in Japanese; the
/// commonly repeated figures for a VT400 are 14 L total with 3.6 L reserve, which implies a 10.4 L
/// main tank — and that does not survive contact with the bike. From brim, it runs weak and close to
/// reserve by about **9 litres consumed**, maybe ten.
///
/// So `mainTank` starts at the *experienced* figure rather than the published one, and is allowed to
/// grow when evidence says so — see ``FuelLog/usableBeforeReserve(spec:)``. Starting low is the
/// right direction to be wrong in: it sends the rider to a pump early, whereas starting at 10.4 L
/// would promise a litre and a half that may not exist, and on this bike reaching reserve means
/// stripping the carburettor.
///
/// `total` is kept at the quoted figure because it barely matters: once you are on reserve you are
/// already in trouble and heading for the nearest station, not consulting a range estimate.
public struct BikeSpec: Sendable, Equatable {
    public let mainTankLitres: Litres
    public let totalTankLitres: Litres

    public init(mainTankLitres: Litres, totalTankLitres: Litres) {
        self.mainTankLitres = mainTankLitres
        self.totalTankLitres = totalTankLitres
    }

    public var reserveLitres: Litres {
        Litres(max(0, totalTankLitres.rawValue - mainTankLitres.rawValue))
    }

    /// Honda VT400. Main tank from the rider's own experience, total from the commonly quoted spec.
    public static let vt400 = BikeSpec(
        mainTankLitres: Litres(9),
        totalTankLitres: Litres(14)
    )
}

public extension FuelLog {
    /// How much is usable before the tap has to go to reserve.
    ///
    /// The spec figure, raised by any brim fill that proves it too low — but only from an interval
    /// where **reserve was never used**. A fill after a reserve switch includes refilling the
    /// reserve itself, so counting it would inflate the main-tank estimate on evidence that says
    /// nothing about the main tank. That error only ever runs in the direction that strands you.
    ///
    /// It never shrinks. A small fill means the rider stopped early, not that the tank got smaller.
    func usableBeforeReserve(spec: BikeSpec) -> Litres {
        let fills = refuels.sorted { $0.date < $1.date }
        let cleanFills = zip(fills, fills.dropFirst()).compactMap { previous, current -> Double? in
            guard current.filledToBrim else { return nil }
            let usedReserve = reserves.contains { $0.date > previous.date && $0.date <= current.date }
            return usedReserve ? nil : current.litres.rawValue
        }
        return Litres(max(spec.mainTankLitres.rawValue, cleanFills.max() ?? 0))
    }
}
