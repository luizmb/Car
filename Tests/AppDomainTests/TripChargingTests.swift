import Foundation
import Testing
@testable import AppDomain

@Suite("Charging system")
struct ChargingTests {

    @Test("resting bands")
    func resting() {
        #expect(chargingState(volts: 12.6, engineRunning: false) == .resting)
        #expect(chargingState(volts: 11.8, engineRunning: false) == .restingLow)
    }

    @Test("running and charging normally")
    func charging() {
        #expect(chargingState(volts: 14.1, engineRunning: true) == .charging)
        #expect(chargingState(volts: 13.8, engineRunning: true) == .charging)
    }

    @Test("running but the voltage never rose — regulator or stator")
    func notCharging() {
        // The failure that strands you. A battery reading 12.4 at rest looks perfectly healthy;
        // the fault is only visible because it stayed there with the engine running.
        #expect(chargingState(volts: 12.4, engineRunning: true) == .notCharging)
        #expect(chargingState(volts: 12.4, engineRunning: false) == .resting)
    }

    @Test("overcharging is a regulator failure in the other direction")
    func overcharging() {
        #expect(chargingState(volts: 15.4, engineRunning: true) == .overcharging)
        // Above the ceiling it is a fault regardless of whether the engine is thought to be running.
        #expect(chargingState(volts: 15.4, engineRunning: false) == .overcharging)
    }

    @Test("only faults are spoken")
    func spokenWarnings() {
        #expect(ChargingState.resting.spokenWarning == nil)
        #expect(ChargingState.charging.spokenWarning == nil)
        #expect(ChargingState.restingLow.spokenWarning != nil)
        #expect(ChargingState.notCharging.spokenWarning != nil)
        #expect(ChargingState.overcharging.spokenWarning != nil)
    }

    @Test("volts come from the hex reading")
    func voltsFromHex() {
        // 0x3091 = 12433 mV. The captured garage sample, which is a resting battery.
        #expect(abs((BatteryReading(raw: "3091").volts ?? 0) - 12.433) < 0.001)
        #expect(BatteryReading(raw: "zz").volts == nil)
    }
}
