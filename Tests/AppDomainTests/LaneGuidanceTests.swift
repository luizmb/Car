import Foundation
import Testing
@testable import AppDomain

// The paint is the ground truth and the route decides which side of it the rider belongs on.
// These tests pin both halves: the turn:lanes grammar, and the sentence — or the silence — each
// combination of paint and route produces.

private let here = Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46))

/// A manoeuvre `metres` ahead of `here`, measured on the ground. No path, so the distance
/// machinery falls back to the straight line — which is exactly the figure the test controls.
private func step(_ text: String, ahead metres: Double) -> RouteStep {
    RouteStep(
        instructions: text, distance: Meters(metres), notice: nil,
        start: Coordinate(latitude: Latitude(52 + metres / 111_320), longitude: Longitude(-0.46))
    )
}

private func metresText(_ distance: Meters) -> String {
    "\(Int(distance.rawValue.rounded())) metres"
}

private func advice(
    paint: String,
    splitAt: Double,
    steps: [RouteStep],
    stepIndex: Int = 0,
    speed: Double = 30
) -> String? {
    laneAdvice(
        steps: steps, stepIndex: stepIndex, at: here, heading: nil, speed: MPS(speed),
        context: LaneWayContext(splitWayID: 7, turnLanes: paint, splitDistance: Meters(splitAt)),
        formatDistance: metresText
    )
}

@Suite("Reading the paint")
struct TurnLanesParserTests {
    @Test("Lanes split on pipes, arrows on semicolons")
    func grammar() {
        #expect(parseTurnLanes("slight_left|through|through") == [[.slightLeft], [.through], [.through]])
        #expect(parseTurnLanes("through|through;right") == [[.through], [.through, .right]])
    }

    @Test("An empty slot is a real lane with no marking")
    func emptyLane() {
        #expect(parseTurnLanes("|merge_to_left") == [[.unmarked], [.mergeLeft]])
    }

    @Test("A token the parser has not met survives as unknown")
    func unknownToken() {
        #expect(parseTurnLanes("through|sideways") == [[.through], [.unknown]])
    }
}

@Suite("Lane advice")
struct LaneAdviceTests {
    /// The scenario the feature exists for: three lanes, the left one peels off, the route keeps
    /// on the road.
    @Test("An exit-only left lane puts a continuing rider in the right two")
    func keepOnRoad() {
        let text = advice(
            paint: "slight_left|through|through", splitAt: 300,
            steps: [step("Turn left onto High Street", ahead: 5_000)]
        )
        #expect(text == "Use the right two lanes to keep on the road in 300 metres")
    }

    @Test("The same paint tells an exiting rider to use the left lane")
    func exitLeft() {
        let text = advice(
            paint: "slight_left|through|through", splitAt: 300,
            steps: [step("Take the exit onto A505", ahead: 300)]
        )
        #expect(text?.hasPrefix("Use the left lane to exit in") == true)
    }

    @Test("A right-turn lane is named for the turn, not the exit")
    func turnRight() {
        let text = advice(
            paint: "through|through;right", splitAt: 300,
            steps: [step("Turn right onto London Road", ahead: 300)]
        )
        #expect(text?.hasPrefix("Use the right lane to turn right in") == true)
    }

    @Test("Turn lanes on both edges leave the middle to a continuing rider")
    func middle() {
        let text = advice(
            paint: "left|through|right", splitAt: 300,
            steps: [step("Turn left onto High Street", ahead: 5_000)]
        )
        #expect(text == "Use the middle lane to keep on the road in 300 metres")
    }

    @Test("Past the last manoeuvre the road continues and so does the advice")
    func pastLastStep() {
        let text = advice(
            paint: "slight_left|through|through", splitAt: 300,
            steps: [step("Take the exit onto A505", ahead: 300)], stepIndex: 1
        )
        #expect(text == "Use the right two lanes to keep on the road in 300 metres")
    }

    @Test("A roundabout fork is the clock face's job")
    func roundabout() {
        let text = advice(
            paint: "left|through|through", splitAt: 300,
            steps: [step("At the roundabout, take the first exit", ahead: 300)]
        )
        #expect(text == nil)
    }

    @Test("A lane that only merges is closed by the road, not by advice")
    func mergeOnly() {
        let text = advice(
            paint: "|merge_to_left", splitAt: 300,
            steps: [step("Turn left onto High Street", ahead: 5_000)]
        )
        #expect(text == nil)
    }

    @Test("Paint with no fork says nothing")
    func noFork() {
        let text = advice(
            paint: "through|through", splitAt: 300,
            steps: [step("Turn left onto High Street", ahead: 5_000)]
        )
        #expect(text == nil)
    }

    @Test("A fork beyond the advice window waits its turn")
    func beyondWindow() {
        let text = advice(
            paint: "slight_left|through|through", splitAt: 600,
            steps: [step("Turn left onto High Street", ahead: 5_000)], speed: 10
        )
        #expect(text == nil)
    }

    @Test("A manoeuvre before the fork silences the fork")
    func turnsOffFirst() {
        let text = advice(
            paint: "slight_left|through|through", splitAt: 400,
            steps: [step("Turn left onto High Street", ahead: 100)]
        )
        #expect(text == nil)
    }

    /// The window scales with speed: fifteen seconds of travel, floored and capped.
    @Test("The advice window is fifteen seconds of road")
    func window() {
        #expect(laneAdviceWindow(speed: MPS(10)) == Meters(250))
        #expect(laneAdviceWindow(speed: MPS(30)) == Meters(450))
        #expect(laneAdviceWindow(speed: MPS(80)) == Meters(800))
    }
}
