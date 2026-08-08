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
        // Positions count from the tape's own start, for the HUD.
        #expect(steps[safe: 0]?.position == 0)
        #expect(steps[safe: 2]?.position == 5)

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

    /// A real rider watched two and a half minutes of recorded stillness and reasonably called
    /// it broken — the parked bookends go; the red light in the middle stays.
    @Test("Parked bookends are trimmed; stops inside the ride are kept")
    func bookendsTrimmed() {
        var records: [JourneyRecord] = []
        // Two minutes parked, then movement, a 30-second stop, movement, a minute parked.
        for second in stride(from: 0.0, to: 120, by: 10) {
            records.append(record(FixPayload(lat: 52, lon: -0.4, mph: 0, course: nil, alt: nil, acc: nil), at: second))
        }
        records.append(record(FixPayload(lat: 52, lon: -0.4, mph: 20, course: nil, alt: nil, acc: nil), at: 120))
        records.append(record(FixPayload(lat: 52.01, lon: -0.4, mph: 0, course: nil, alt: nil, acc: nil), at: 130))
        records.append(record(FixPayload(lat: 52.01, lon: -0.4, mph: 25, course: nil, alt: nil, acc: nil), at: 160))
        for second in stride(from: 170.0, to: 230, by: 10) {
            records.append(record(FixPayload(lat: 52.02, lon: -0.4, mph: 0, course: nil, alt: nil, acc: nil), at: second))
        }

        let steps = replaySchedule(for: records)
        guard case let .fix(first)? = steps.first?.event else {
            Issue.record("expected a fix first"); return
        }
        // The tape opens at the pull-away, not two minutes early — with this fixture's sparse
        // parked fixes, the first surviving record is the moving one itself.
        #expect((first.speed?.rawValue ?? 0) > 8)
        #expect(steps.first?.delay == 0)
        // …keeps the mid-ride stop (the 130s and 160s fixes are 30 tape-seconds apart)…
        let delays = steps.map(\.delay)
        #expect(delays.contains(30))
        // …and ends just after the last movement rather than a minute later.
        #expect(steps.last?.position ?? 0 <= 56)   // 160+5 − 115+… ≈ 50s of tape + finished
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
