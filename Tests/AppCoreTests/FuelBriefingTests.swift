import AppDomain
import Foundation
import Testing
@testable import AppCore

@Suite("Fuel in the briefing")
struct FuelBriefingTests {

    @Test("fuel is spoken even when everything is nominal")
    func alwaysPresent() {
        // Every other line in the exception report appears only when something is wrong, because a
        // healthy tyre needs no mention. Fuel is the opposite: no gauge, no low-fuel light, and a
        // reserve that means stripping the carburettor — so the rider sets off in the dark about it
        // every single time, and being told is the normal case.
        let nominal = FlightPlanInputs(
            indimateConnected: true, cardoConnected: true,
            phoneBattery: 0.9, gpsAccuracy: 5,
            fuel: "120 kilometres since your last fill at 22160. About 60 kilometres before reserve."
        )
        let spoken = composeFlightPlan(nominal, verbosity: .exceptions)
        #expect(spoken.contains { $0.contains("before reserve") })
    }

    @Test("fuel survives a briefing full of problems too")
    func survivesProblems() {
        // The path where everything else is shouting is exactly the one where a quiet fact would
        // otherwise be dropped.
        let bad = FlightPlanInputs(
            phoneBattery: 0.1, lowPowerMode: true,
            fuel: "200 kilometres since your last fill. Fill up before you reach reserve."
        )
        let spoken = composeFlightPlan(bad, verbosity: .exceptions)
        #expect(spoken.contains { $0.contains("Fill up before you reach reserve") })
    }

    @Test("the full report names fuel even when there is nothing recorded")
    func fullReportSaysNothingRecorded() {
        // A provider that has quietly failed is indistinguishable from a healthy one under
        // exceptions; the full report is where each one has to name itself.
        let spoken = composeFlightPlan(FlightPlanInputs(), verbosity: .full)
        #expect(spoken.contains { $0.contains("Fuel") })
    }
}
