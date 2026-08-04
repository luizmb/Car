import Foundation
import Testing
@testable import AppDomain

@Suite("Weather")
struct WeatherTests {

    private let mild = WeatherObservation(
        temperature: Celsius(15), humidity: 0, pressure: KPa(101.325),
        windSpeed: MPS(10), windDirection: Course(0)
    )

    @Test("dry air at standard conditions is the textbook 1.225 kg/m³")
    func standardDensity() {
        #expect(abs(mild.airDensity - 1.225) < 0.002)
    }

    @Test("humid air is lighter than dry air at the same temperature and pressure")
    func humidityLowersDensity() {
        // Counter-intuitive but real: water vapour (18 g/mol) displaces nitrogen and oxygen
        // (~29 g/mol). Ignoring it under-states the effect on a warm damp day.
        let dry = WeatherObservation(
            temperature: Celsius(25), humidity: 0, pressure: KPa(101.325),
            windSpeed: MPS(0), windDirection: Course(0)
        )
        let humid = WeatherObservation(
            temperature: Celsius(25), humidity: 95, pressure: KPa(101.325),
            windSpeed: MPS(0), windDirection: Course(0)
        )
        #expect(humid.airDensity < dry.airDensity)
    }

    @Test("a wind from ahead is a headwind, from behind a tailwind")
    func headwindSign() {
        // Wind from the north (0°), rider heading north (0°) — straight into it.
        #expect(abs(mild.headwind(course: Course(0)).rawValue - 10) < 0.001)
        // Same wind, rider heading south — pushed along.
        #expect(abs(mild.headwind(course: Course(180)).rawValue + 10) < 0.001)
        // Crosswind contributes nothing along the direction of travel.
        #expect(abs(mild.headwind(course: Course(90)).rawValue) < 0.001)
    }

    @Test("airspeed is what drag responds to, not ground speed")
    func airspeed() {
        // 20 m/s into a 10 m/s headwind is 30 m/s of air — which is why bucketing consumption by
        // airspeed folds wind in without adding a dimension to the model.
        #expect(abs(mild.airspeed(groundSpeed: MPS(20), course: Course(0)).rawValue - 30) < 0.001)
        #expect(abs(mild.airspeed(groundSpeed: MPS(20), course: Course(180)).rawValue - 10) < 0.001)
    }

    @Test("a partial response yields nothing rather than a fabricated default")
    func partialResponseRejected() {
        // A substituted 15°C would silently poison the consumption model; a gap is merely a gap.
        let partial = OpenMeteoResponse(current: .init(
            temperature2m: 12, relativeHumidity2m: nil,
            surfacePressure: 1010, windSpeed10m: 3, windDirection10m: 180
        ))
        #expect(parseWeather(partial) == nil)
        #expect(parseWeather(OpenMeteoResponse(current: nil)) == nil)
    }

    @Test("hectopascals are converted to kilopascals")
    func pressureUnits() {
        let response = OpenMeteoResponse(current: .init(
            temperature2m: 12, relativeHumidity2m: 80,
            surfacePressure: 1013.25, windSpeed10m: 3, windDirection10m: 180
        ))
        #expect(abs((parseWeather(response)?.pressure.rawValue ?? 0) - 101.325) < 0.001)
    }
}

@Suite("Fuel log")
struct FuelLogTests {

    private func fill(
        _ litres: Double, odometer: Double?, brim: Bool = true, at day: Int
    ) -> RefuelRecord {
        RefuelRecord(
            id: UUID(), date: Date(timeIntervalSince1970: Double(day) * 86400),
            litres: Litres(litres), pricePerLitre: 1.5, grade: .e5,
            filledToBrim: brim, odometer: odometer.map { Kilometres($0) },
            latitude: nil, longitude: nil
        )
    }

    @Test("one fill measures nothing")
    func singleFillYieldsNoSample() {
        // Consumption is the gap *between* two brim fills, so a lone record must produce no
        // sample rather than a figure derived from a single point.
        let log = FuelLog(refuels: [fill(12, odometer: 22100, at: 1)])
        #expect(log.consumptionSamples.isEmpty)
    }

    @Test("two brim fills give distance and litres")
    func twoFillsGiveASample() {
        let log = FuelLog(refuels: [
            fill(12, odometer: 22100, at: 1),
            fill(10, odometer: 22350, at: 5)
        ])
        let samples = log.consumptionSamples
        #expect(samples.count == 1)
        #expect(samples[0].kilometres == 250)
        #expect(samples[0].litres == 10)
    }

    @Test("partial fills are excluded, not approximated")
    func partialFillsExcluded() {
        // Brim-to-brim only measures consumption if both ends are to the same level. Including a
        // partial fill would produce a plausible-looking but wrong number.
        let log = FuelLog(refuels: [
            fill(12, odometer: 22100, at: 1),
            fill(5, odometer: 22200, brim: false, at: 3),
            fill(10, odometer: 22350, at: 5)
        ])
        let samples = log.consumptionSamples
        #expect(samples.count == 1)
        #expect(samples[0].kilometres == 250)
    }

    @Test("a fill with no odometer reading produces no sample")
    func missingOdometerSkipped() {
        let log = FuelLog(refuels: [
            fill(12, odometer: nil, at: 1),
            fill(10, odometer: 22350, at: 5)
        ])
        #expect(log.consumptionSamples.isEmpty)
    }

    @Test("total cost is litres times price")
    func totalCost() {
        #expect(abs(fill(12.5, odometer: nil, at: 1).totalCost - 18.75) < 0.001)
    }

    @Test("a refuel record survives a round trip through JSON")
    func codableRoundTrip() throws {
        // The log is the only durable record of every fill; a schema that cannot round-trip would
        // lose the whole history on the first decode change.
        let original = FuelLog(
            refuels: [fill(12, odometer: 22100, at: 1)],
            reserves: [ReserveEvent(
                id: UUID(), date: Date(timeIntervalSince1970: 200_000),
                odometer: Kilometres(22090), gpsKilometres: Kilometres(248.5),
                latitude: Latitude(51.7), longitude: Longitude(-0.4)
            )]
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(FuelLog.self, from: try encoder.encode(original))
        #expect(restored == original)
    }
}
