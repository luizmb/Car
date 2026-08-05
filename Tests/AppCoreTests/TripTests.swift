import AppDomain
import Foundation
import Testing
@testable import AppCore

// Distance accuracy feeds straight into fuel consumption, and every gate here exists because
// unfiltered GPS over-reads — always in the same direction, never down.

@Suite("Trip distance gating")
struct TripGatingTests {

    private func fix(
        lat: Double, lon: Double, speed: Double?, accuracy: Double?
    ) -> LocationUpdate {
        LocationUpdate(
            speed: speed.map { MPS($0) }, speedAccuracy: nil, course: nil,
            latitude: Latitude(lat), longitude: Longitude(lon), altitude: Meters(0),
            timestamp: Date(timeIntervalSince1970: 0),
            horizontalAccuracy: accuracy.map { Meters($0) }
        )
    }

    private func state(lat: Double, lon: Double) -> TripFeature.State {
        var s = TripFeature.State()
        s.lastLatitude = Latitude(lat)
        s.lastLongitude = Longitude(lon)
        return s
    }

    @Test("a normal moving fix accumulates roughly the right distance")
    func accumulatesWhileMoving() {
        // ~0.001° of latitude ≈ 111 m.
        let step = TripFeature.accumulableStep(
            from: state(lat: 51.750, lon: -0.475),
            to: fix(lat: 51.751, lon: -0.475, speed: 15, accuracy: 5)
        )
        #expect(abs(step - 111) < 3)
    }

    @Test("a stationary receiver contributes nothing")
    func parkedContributesNothing() {
        // The measured drift on a real ride was ~80 m per journey while parked. Small, but it only
        // ever inflates, and it lands in the fuel maths as distance never travelled.
        #expect(TripFeature.accumulableStep(
            from: state(lat: 51.750, lon: -0.475),
            to: fix(lat: 51.7501, lon: -0.4751, speed: 0.2, accuracy: 5)
        ) == 0)
    }

    @Test("a poor fix is ignored outright")
    func poorAccuracyIgnored() {
        // Urban canyons and tunnels produce fixes accurate to hundreds of metres. Integrating those
        // is worse than leaving a gap.
        #expect(TripFeature.accumulableStep(
            from: state(lat: 51.750, lon: -0.475),
            to: fix(lat: 51.751, lon: -0.475, speed: 15, accuracy: 120)
        ) == 0)
        // A fix CoreLocation reports as invalid has no accuracy at all.
        #expect(TripFeature.accumulableStep(
            from: state(lat: 51.750, lon: -0.475),
            to: fix(lat: 51.751, lon: -0.475, speed: 15, accuracy: nil)
        ) == 0)
    }

    @Test("a teleport after a signal gap is discarded, not counted")
    func teleportDiscarded() {
        // Emerging from a tunnel produces one huge step. Counting it would credit the tunnel twice:
        // once as the jump, and once as the distance actually ridden through it.
        #expect(TripFeature.accumulableStep(
            from: state(lat: 51.750, lon: -0.475),
            to: fix(lat: 51.800, lon: -0.475, speed: 25, accuracy: 5)
        ) == 0)
    }

    @Test("the first fix of a session accumulates nothing")
    func firstFixHasNoPrevious() {
        // No previous position means no step — distance from nowhere is not zero, it is undefined.
        #expect(TripFeature.accumulableStep(
            from: TripFeature.State(),
            to: fix(lat: 51.751, lon: -0.475, speed: 15, accuracy: 5)
        ) == 0)
    }

    @Test("kilometres are metres divided by a thousand")
    func kilometres() {
        var s = TripFeature.State()
        s.metresSinceFill = 17_695
        #expect(abs(s.kilometresSinceFill.rawValue - 17.695) < 0.001)
    }
}
