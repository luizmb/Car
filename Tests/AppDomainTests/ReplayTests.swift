import Foundation
import Testing
@testable import AppDomain

// The tape is cut purely: what survives, in what order, and how long apart. Everything else
// about a replay is the live behavior doing what it always does.

private func record(_ payload: any JourneyPayloadType, at seconds: Double) -> JourneyRecord {
    JourneyRecord(time: Date(timeIntervalSince1970: seconds), payload: payload)
}

@Suite("Cutting the tape")
struct ReplayScheduleTests {
    @Test("Fixes, indicators and roads survive with their own spacing; the rest is left out")
    func scheduleShape() {
        let steps = replaySchedule(for: [
            record(JourneyStartPayload(via: "both"), at: 0),
            record(FixPayload(lat: 52, lon: -0.4, mph: 30, course: 90, alt: 90, acc: 5), at: 1),
            record(BarometerPayload(kpa: 100, relativeAltitude: 0), at: 1.5),
            record(IndicatorPayload(side: "left"), at: 3),
            record(RoadPayload(mph: 30, origin: "signed", label: "A505", variable: false), at: 6),
            record(JourneyEndPayload(seconds: 6, started: Date(timeIntervalSince1970: 0)), at: 6)
        ])

        #expect(steps.count == 4)   // fix, indicator, road, finished
        #expect(steps[safe: 0]?.delay == 0)     // the first event plays immediately
        #expect(steps[safe: 1]?.delay == 2)     // 3s − 1s
        #expect(steps[safe: 2]?.delay == 3)     // 6s − 3s
        #expect(steps[safe: 3]?.event == .finished)

        guard case let .fix(update)? = steps[safe: 0]?.event else {
            Issue.record("first step should be the fix"); return
        }
        #expect(update.latitude == Latitude(52))
        #expect(update.speed.map { Int($0.rawValue.rounded()) } == 13)   // 30 mph as m/s
    }

    @Test("Out-of-order records replay in time order, and an empty ride is an empty tape")
    func orderingAndEmpty() {
        let steps = replaySchedule(for: [
            record(FixPayload(lat: 52.1, lon: -0.4, mph: nil, course: nil, alt: nil, acc: nil), at: 10),
            record(FixPayload(lat: 52.0, lon: -0.4, mph: nil, course: nil, alt: nil, acc: nil), at: 5)
        ])
        guard case let .fix(first)? = steps[safe: 0]?.event else {
            Issue.record("expected a fix first"); return
        }
        #expect(first.latitude == Latitude(52.0))
        #expect(replaySchedule(for: []).isEmpty)
    }

    @Test("A recorded road comes back as the value the monitor was handed live")
    func roadReconstruction() {
        let signed = roadInfo(fromRecorded: RoadPayload(mph: 30, origin: "signed", label: "A505", variable: false))
        #expect(signed.limit == .value(MPH(30)))
        #expect(signed.origin == .signed)
        #expect(signed.name == "A505")

        let national = roadInfo(fromRecorded: RoadPayload(mph: nil, origin: "national", label: nil, variable: false))
        #expect(national.limit == .national)
        #expect(national.origin == .nationalSpeedLimit)
    }
}
