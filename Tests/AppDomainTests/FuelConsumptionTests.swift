import Foundation
import Testing
@testable import AppDomain

// The bike has no fuel gauge, no low-fuel light, and a reserve tank whose use damages the
// carburettor. Every number here is one no instrument on the bike provides.

@Suite("Fuel consumption")
struct FuelConsumptionTests {

    private func fill(
        _ day: Int, litres: Double, price: Double = 1.50,
        km: Double?, brim: Bool = true
    ) -> RefuelRecord {
        RefuelRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", day))")!,
            date: Date(timeIntervalSince1970: Double(day) * 86_400),
            litres: Litres(litres),
            pricePerLitre: price,
            grade: .e5,
            filledToBrim: brim,
            odometer: nil,
            gpsKilometres: km.map { Kilometres($0) },
            latitude: nil,
            longitude: nil
        )
    }

    @Test("one fill measures nothing")
    func singleFill() {
        // Brim-to-brim needs two ends. A single fill tells you what went in, not what it covered.
        let log = FuelLog(refuels: [fill(1, litres: 10, km: nil)])
        #expect(log.consumption == nil)
    }

    @Test("two brim fills give a figure")
    func twoFills() {
        // The second fill's litres are what the distance since the first one cost.
        let log = FuelLog(refuels: [
            fill(1, litres: 10, km: nil),
            fill(2, litres: 8, km: 160)
        ])
        #expect(log.consumption?.kilometresPerLitre == 20)
        #expect(log.consumption?.sampleCount == 1)
    }

    @Test("intervals are weighted by distance, not averaged as ratios")
    func aggregateNotMeanOfRatios() {
        // 300 km on 10 L, then 30 km on 3 L. Mean of ratios is (30 + 10) / 2 = 20 km/L, which lets
        // one short town trip drag the figure as hard as a tankful of motorway. Total over total is
        // 330 / 13 = 25.4, which is what the bike actually did.
        let log = FuelLog(refuels: [
            fill(1, litres: 10, km: nil),
            fill(2, litres: 10, km: 300),
            fill(3, litres: 3, km: 30)
        ])
        #expect(abs((log.consumption?.kilometresPerLitre ?? 0) - 330.0 / 13.0) < 0.001)
        #expect(log.consumption?.sampleCount == 2)
    }

    @Test("a partial fill is excluded, not approximated")
    func partialFillsExcluded() {
        // Brim-to-brim only measures anything if both ends are to the same level.
        let log = FuelLog(refuels: [
            fill(1, litres: 10, km: nil),
            fill(2, litres: 5, km: 100, brim: false),
            fill(3, litres: 10, km: 200)
        ])
        #expect(log.consumption?.sampleCount == 1)
        #expect(log.consumption?.kilometresPerLitre == 20)
    }

    @Test("a standstill fill contributes nothing")
    func zeroDistanceIgnored() {
        // Exactly the test records logged on the doorstep: zero kilometres between fills is not a
        // measurement of infinite economy, it is not a measurement.
        let log = FuelLog(refuels: [
            fill(1, litres: 10, km: nil),
            fill(2, litres: 8, km: 0)
        ])
        #expect(log.consumption == nil)
    }

    @Test("the units riders actually compare in")
    func unitConversions() {
        let estimate = ConsumptionEstimate(kilometresPerLitre: 20, sampleCount: 1, costPerKilometre: nil)
        #expect(abs(estimate.litresPer100km - 5) < 0.001)
        // Imperial gallons — 20% larger than the US one, and the only figure a UK rider quotes.
        #expect(abs(estimate.milesPerGallon - 56.5) < 0.1)
    }

    @Test("cost per kilometre uses what was paid, not today's price")
    func costPerKilometre() {
        let log = FuelLog(refuels: [
            fill(1, litres: 10, price: 1.00, km: nil),
            fill(2, litres: 10, price: 2.00, km: 200)
        ])
        // 10 L at £2.00 covered 200 km.
        #expect(abs((log.consumption?.costPerKilometre ?? 0) - 0.10) < 0.001)
    }

    @Test("the latest interval is reported separately from the average")
    func latestSeparate() {
        // How you notice a problem: a choke left out shows in the last tankful long before the
        // lifetime average has finished absorbing it.
        let log = FuelLog(refuels: [
            fill(1, litres: 10, km: nil),
            fill(2, litres: 10, km: 300),
            fill(3, litres: 10, km: 100)
        ])
        #expect(log.latestConsumption?.kilometresPerLitre == 10)
        #expect(abs((log.consumption?.kilometresPerLitre ?? 0) - 20) < 0.001)
    }

    @Test("capacity is the largest brim fill seen, and only grows")
    func capacityIsALowerBound() {
        // Under-promising range is the right direction to be wrong in: it sends you to a pump early
        // rather than leaving you on reserve, which on this bike is a repair.
        let log = FuelLog(refuels: [
            fill(1, litres: 9, km: nil),
            fill(2, litres: 11.4, km: 200),
            fill(3, litres: 8, km: 150)
        ])
        #expect(log.observedTankCapacity == Litres(11.4))
    }

    @Test("no range estimate until there is something to base it on")
    func noRangeWithoutEvidence() {
        // A fabricated range on a bike whose reserve damages the carburettor is worse than silence.
        #expect(FuelLog(refuels: [fill(1, litres: 10, km: nil)]).range(travelled: Kilometres(50)) == nil)
    }

    @Test("range counts down as the tank is used")
    func rangeCountsDown() {
        let log = FuelLog(refuels: [
            fill(1, litres: 10, km: nil),
            fill(2, litres: 10, km: 200)     // 20 km/L, capacity 10 L
        ])
        let range = log.range(travelled: Kilometres(100))
        #expect(abs((range?.litresRemaining ?? 0) - 5) < 0.001)
        #expect(abs((range?.kilometresRemaining ?? 0) - 100) < 0.001)
    }

    @Test("range never goes negative")
    func rangeFloorsAtZero() {
        let log = FuelLog(refuels: [fill(1, litres: 10, km: nil), fill(2, litres: 10, km: 200)])
        #expect(log.range(travelled: Kilometres(500))?.kilometresRemaining == 0)
    }
}

@Suite("Reserve prediction")
struct ReserveTests {

    private func reserve(_ day: Int, km: Double?) -> ReserveEvent {
        ReserveEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000001\(String(format: "%02d", day))")!,
            date: Date(timeIntervalSince1970: Double(day) * 86_400),
            odometer: nil,
            gpsKilometres: km.map { Kilometres($0) },
            latitude: nil,
            longitude: nil
        )
    }

    @Test("the typical reserve point is the average of what has happened")
    func typicalDistance() {
        // The number the rider needs and no instrument gives: on this bike reaching reserve is a
        // mechanical problem, so knowing when it usually arrives is the whole point.
        let log = FuelLog(reserves: [reserve(1, km: 180), reserve(2, km: 200)])
        #expect(log.typicalKilometresToReserve == 190)
    }

    @Test("nothing recorded means no prediction")
    func noReserves() {
        #expect(FuelLog().typicalKilometresToReserve == nil)
    }

    @Test("a zero-distance reserve event is ignored")
    func zeroIgnored() {
        // The doorstep test again: switching to reserve having ridden nowhere says nothing.
        #expect(FuelLog(reserves: [reserve(1, km: 0)]).typicalKilometresToReserve == nil)
    }
}
