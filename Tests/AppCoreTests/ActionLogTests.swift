import Foundation
import Testing
@testable import AppCore

// The filing is UTC-day based, and the rider is a night owl in GMT — so the boundary lands mid-ride
// often enough that getting it wrong would be noticed. These pin the arithmetic rather than the file
// IO, since the arithmetic is the part with an answer that can be wrong.

/// A clock the test can wind forward. Locked because `ActionLogBox` takes a `@Sendable` closure and
/// may read it from any thread; a plain captured `var` is not safe to hand across that boundary.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

@Suite("Ride log filing")
struct ActionLogFilingTests {

    /// A directory of this test's own. Swift Testing runs tests in parallel, and two of these write
    /// the same day's file — sharing Documents meant one deleted the file another was reading.
    private func scratch() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ride-log-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("the epoch is day zero")
    func epoch() {
        #expect(utcDayIndex(Date(timeIntervalSince1970: 0)) == 0)
        #expect(utcDayStamp(0) == "1970-01-01")
    }

    @Test("a day runs from midnight UTC to the last second before the next")
    func dayBoundaries() {
        let start = utcDayIndex(date("2026-08-05T00:00:00Z"))
        #expect(utcDayIndex(date("2026-08-05T23:59:59Z")) == start)
        #expect(utcDayIndex(date("2026-08-06T00:00:00Z")) == start + 1)
        #expect(utcDayStamp(start) == "2026-08-05")
    }

    @Test("a ride across midnight lands in two files")
    func nightRideStraddles() {
        // Left home at 23:40, home again at 00:20. One journey, two files — accepted deliberately,
        // because a journey is two timestamps and the filing system does not define it.
        let out = utcDayIndex(date("2026-08-05T23:40:00Z"))
        let back = utcDayIndex(date("2026-08-06T00:20:00Z"))
        #expect(out != back)
        #expect(utcDayStamp(out) == "2026-08-05")
        #expect(utcDayStamp(back) == "2026-08-06")
    }

    @Test("the boundary is UTC, so BST shifts it to 01:00 local")
    func britishSummerTimeShiftsTheRoll() {
        // Riding at 00:30 BST is still 23:30 UTC — the same file as the evening before. This is the
        // asked-for behaviour, not an oversight, and it is the case most likely to look like a bug.
        #expect(utcDayIndex(date("2026-08-05T23:30:00Z")) == utcDayIndex(date("2026-08-05T12:00:00Z")))
    }

    @Test("dates before the epoch do not round the wrong way")
    func negativeDaysFloor() {
        // Truncation toward zero would put 1969-12-31 in day 0 alongside 1970-01-01. Only reachable
        // via a bad clock, but a silently merged file is a nasty way to find that out.
        #expect(utcDayIndex(date("1969-12-31T23:59:59Z")) == -1)
        #expect(utcDayStamp(-1) == "1969-12-31")
    }

    @Test("appending twice in a day keeps both lines in one file")
    func appendsAccumulate() throws {
        let directory = scratch()
        let clock = TestClock(date("2026-08-05T10:00:00Z"))
        let log = ActionLogBox(directory: directory, prefix: "debug", now: { clock.now })
        log.append("first")
        clock.now = date("2026-08-05T10:00:01Z")
        log.append("second")

        let url = try #require(log.url)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines.suffix(2).allSatisfy { $0.contains("2026-08-05T10:00:0") })
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("crossing midnight while running rolls to a new file")
    func rollsWhileRunning() throws {
        // The app stays alive across midnight — for a night rider that is the normal case, not an
        // edge one, so the roll cannot happen only at launch.
        let directory = scratch()
        let clock = TestClock(date("2026-08-05T23:59:59Z"))
        let log = ActionLogBox(directory: directory, prefix: "debug", now: { clock.now })
        log.append("before")
        let first = try #require(log.url)

        clock.now = date("2026-08-06T00:00:00Z")
        log.append("after")
        let second = try #require(log.url)

        #expect(first != second)
        #expect(first.lastPathComponent == "debug-2026-08-05.jsonl")
        #expect(second.lastPathComponent == "debug-2026-08-06.jsonl")
        try? FileManager.default.removeItem(at: directory)
    }
}
