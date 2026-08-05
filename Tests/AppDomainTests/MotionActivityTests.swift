import Foundation
import Testing
@testable import AppDomain

// Counts below are from the 2026-08-05 ride: 77 activity samples, of which 17 carried confidence 0
// and 6 were the walk to and from the bike.

@Suite("Motion activity filtering")
struct MotionActivityFilterTests {

    private func sample(_ activity: MotionActivity, _ confidence: Int) -> MotionActivitySample {
        MotionActivitySample(activity: activity, confidence: confidence)
    }

    @Test("confidence 0 is discarded whatever it claims")
    func lowConfidenceDropped() {
        // It flapped between automotive and stationary inside the same second with the bike parked,
        // so a confident-sounding label at confidence 0 is worse than no label.
        #expect(!sample(.automotive, 0).isWorthRecording)
        #expect(!sample(.stationary, 0).isWorthRecording)
        #expect(!sample(.cycling, 0).isWorthRecording)
    }

    @Test("pedestrian activities describe the rider, not the bike")
    func pedestrianDropped() {
        #expect(!sample(.walking, 2).isWorthRecording)
        #expect(!sample(.running, 2).isWorthRecording)
    }

    @Test("both vehicular labels are kept, because iOS cannot decide which a motorcycle is")
    func vehicularKept() {
        // The same ride was called `automotive` 41 times and `cycling` twice. Keeping only one would
        // silently drop whichever the classifier happened to pick.
        #expect(sample(.automotive, 2).isWorthRecording)
        #expect(sample(.cycling, 2).isWorthRecording)
        #expect(sample(.automotive, 1).isWorthRecording)
    }

    @Test("stationary and unknown survive — they are how the engine stopping shows up")
    func stoppedStatesKept() {
        // At the destination the classifier went automotive → unknown/stationary within 6s of the
        // engine dying. Dropping these would remove the only prompt edge it detects.
        #expect(sample(.stationary, 2).isWorthRecording)
        #expect(sample(.unknown, 2).isWorthRecording)
    }
}
