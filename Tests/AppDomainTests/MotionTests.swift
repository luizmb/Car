import Foundation
import Testing
@testable import AppDomain

@Suite("Motion derivations")
struct MotionDerivationTests {

    private func sample(user: Vector3 = .init(x: 0, y: 0, z: 0),
                        gravity: Vector3,
                        rotation: Vector3 = .init(x: 0, y: 0, z: 0)) -> MotionSample {
        MotionSample(userAcceleration: user, gravity: gravity, rotationRate: rotation)
    }

    @Test("upright and still reads as no lean")
    func uprightIsZeroLean() {
        // 1 g total, whichever way the phone happens to be facing.
        let lean = sample(gravity: .init(x: 0, y: 0, z: -1)).leanEstimate
        #expect(lean != nil)
        #expect(abs(lean! - 0) < 0.5)
    }

    @Test("lean is invariant to how the phone sits in the pocket")
    func leanIsOrientationInvariant() {
        // The same 1.41 g resultant, expressed along three different device axes. All must agree,
        // because that invariance is the entire reason this derivation is usable at all.
        let magnitude = 2.0.squareRoot()
        let orientations = [
            Vector3(x: magnitude, y: 0, z: 0),
            Vector3(x: 0, y: magnitude, z: 0),
            Vector3(x: 0, y: 0, z: -magnitude),
            Vector3(x: 1, y: 1, z: 0)
        ]
        let leans = orientations.compactMap { sample(gravity: $0).leanEstimate }
        #expect(leans.count == orientations.count)
        // acos(1/1.414) = 45°
        for lean in leans { #expect(abs(lean - 45) < 0.5) }
    }

    @Test("a 45 degree lean means 1.41 g, which is the textbook figure")
    func fortyFiveDegrees() {
        let lean = sample(gravity: .init(x: 0, y: 0, z: -2.0.squareRoot())).leanEstimate
        #expect(abs(lean! - 45) < 0.5)
    }

    @Test("below 1 g yields no lean rather than a bogus one")
    func crestGivesNoLean() {
        // Going over a crest unloads the suspension; there is no lean to infer, and inventing one
        // would be worse than admitting ignorance.
        #expect(sample(gravity: .init(x: 0, y: 0, z: -0.8)).leanEstimate == nil)
    }

    @Test("effort ignores gravity, total force includes it")
    func effortVersusTotalForce() {
        let s = sample(
            user: .init(x: 0.3, y: 0, z: 0),
            gravity: .init(x: 0, y: 0, z: -1)
        )
        #expect(abs(s.effort - 0.3) < 0.001)
        // Perpendicular contributions add in quadrature: sqrt(0.09 + 1) = 1.044
        #expect(abs(s.totalForce - 1.0440) < 0.001)
    }

    @Test("rotation speed is a magnitude, so pocket tumbling does not change it")
    func rotationSpeed() {
        let s = sample(gravity: .init(x: 0, y: 0, z: -1), rotation: .init(x: 3, y: 4, z: 0))
        #expect(abs(s.rotationSpeed - 5) < 0.001)
    }
}

@Suite("Air density")
struct AirDensityTests {

    @Test("standard sea level conditions give the textbook 1.225 kg/m³")
    func standardConditions() {
        #expect(abs(airDensity(pressure: KPa(101.325), temperature: Celsius(15)) - 1.225) < 0.001)
    }

    @Test("hot air is thinner, which is what richens a carburettor")
    func hotAirIsThinner() {
        let cold = airDensity(pressure: KPa(101.325), temperature: Celsius(0))
        let hot = airDensity(pressure: KPa(101.325), temperature: Celsius(35))
        #expect(hot < cold)
        // ~12% less dense across that range — a first-order effect, not a rounding error, which is
        // the whole argument for measuring pressure locally rather than interpolating it.
        #expect(abs((cold - hot) / cold - 0.12) < 0.02)
    }

    @Test("low pressure is thinner at fixed temperature")
    func lowPressureIsThinner() {
        let high = airDensity(pressure: KPa(103), temperature: Celsius(15))
        let low = airDensity(pressure: KPa(95), temperature: Celsius(15))
        #expect(low < high)
    }
}
