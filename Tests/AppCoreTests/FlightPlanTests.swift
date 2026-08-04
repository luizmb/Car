import AppDomain
import Foundation
import Testing
@testable import AppCore

// The briefing's whole value is that it is *short when nothing is wrong*. A rider who has to listen
// through four nominal readings stops listening, and then misses the one that mattered.

@Suite("Flight Plan")
struct FlightPlanTests {

    /// `position` is irrelevant to the composition — it reads the dictionary key — so one helper
    /// with a fixed position keeps the tests readable.
    private func reading(_ psi: Double, _ status: TyreStatus) -> TyreReading {
        TyreReading(
            position: .front,
            telemetry: TyreTelemetry(
                serial: "x", pressure: KPa(psi / 0.1450377),
                temperature: Celsius(20), isMoving: false
            ),
            status: status
        )
    }

    private var healthy: FlightPlanInputs {
        FlightPlanInputs(
            ignitionOn: true, indimateConnected: true, cardoConnected: true,
            tyres: [.front: reading(33, .ok), .rear: reading(38, .ok)],
            weather: WeatherObservation(
                temperature: Celsius(18), humidity: 60, pressure: KPa(101.3),
                windSpeed: MPS(2), windDirection: Course(180)
            ),
            road: "A40", speedLimit: "national speed limit",
            bikeMillivolts: 12_400, phoneBattery: 0.9, lowPowerMode: false, gpsAccuracy: 5
        )
    }

    @Test("everything nominal collapses to one short line")
    func nominalIsShort() {
        let briefing = composeFlightPlan(healthy)
        #expect(briefing.hasPrefix("All nominal"))
        #expect(!briefing.contains("Otherwise"))
        // Short enough to hear without tuning out.
        #expect(briefing.count < 120)
    }

    @Test("a low tyre leads, and the nominal summary is dropped")
    func problemsLead() {
        var inputs = healthy
        inputs.tyres[.front] = reading(24, .low)
        let briefing = composeFlightPlan(inputs)
        #expect(briefing.hasPrefix("front tyre low at 24 psi"))
        #expect(!briefing.contains("All nominal"))
    }

    @Test("a missing tyre reading is reported, not silently omitted")
    func missingReadingIsAProblem() {
        // These sensors sleep, so absence is a real state. Saying nothing would be
        // indistinguishable from a healthy tyre.
        var inputs = healthy
        inputs.tyres[.rear] = nil
        #expect(composeFlightPlan(inputs).contains("No rear tyre reading"))
    }

    @Test("low power mode is called out, because it silently disables background tracking")
    func lowPowerMode() {
        var inputs = healthy
        inputs.lowPowerMode = true
        #expect(composeFlightPlan(inputs).contains("Low power mode"))
    }

    @Test("a flat phone leads the briefing — it is the instrument cluster")
    func phoneBattery() {
        var inputs = healthy
        inputs.phoneBattery = 0.12
        #expect(composeFlightPlan(inputs).hasPrefix("Phone battery 12 percent"))
    }

    @Test("a disconnected Indimate produces an actionable instruction")
    func indimatePrompt() {
        var inputs = healthy
        inputs.indimateConnected = false
        // The rider's own habit — flicking an indicator with the keys on wakes the unit.
        #expect(composeFlightPlan(inputs).contains("flick an indicator"))
    }

    @Test("a low bike battery warns, a healthy one is merely stated")
    func bikeBattery() {
        var low = healthy
        low.bikeMillivolts = 11_600
        #expect(composeFlightPlan(low).contains("Bike battery 11.6 volts"))

        #expect(composeFlightPlan(healthy).contains("battery 12.4 volts"))
        #expect(composeFlightPlan(healthy).hasPrefix("All nominal"))
    }

    @Test("light wind is not mentioned, strong wind is")
    func windThreshold() {
        #expect(!composeFlightPlan(healthy).contains("wind"))
        var windy = healthy
        windy.weather = WeatherObservation(
            temperature: Celsius(18), humidity: 60, pressure: KPa(101.3),
            windSpeed: MPS(12), windDirection: Course(180)
        )
        #expect(composeFlightPlan(windy).contains("wind 12"))
    }

    @Test("several problems all appear, ordered by how badly they end a ride")
    func multipleProblems() {
        var inputs = healthy
        inputs.phoneBattery = 0.10
        inputs.tyres[.front] = reading(24, .low)
        inputs.indimateConnected = false
        let briefing = composeFlightPlan(inputs)
        #expect(briefing.hasPrefix("Phone battery"))
        #expect(briefing.contains("front tyre low"))
        #expect(briefing.contains("flick an indicator"))
        #expect(briefing.contains("Otherwise"))
    }
}
