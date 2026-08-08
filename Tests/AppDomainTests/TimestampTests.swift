import Foundation
import Testing
@testable import AppDomain

@Suite("The timeline's clock")
struct TimestampTests {
    /// The hand parser must agree with Foundation's across decades — including every leap-year
    /// shape — because a timestamp that drifts a day corrupts every ride assembled from it.
    @Test("Agrees with ISO8601DateFormatter across sixty years")
    func agreesWithFoundation() {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // Every 97 hours from 1970 to ~2037: crosses month ends, leap days, year boundaries.
        var probe = Date(timeIntervalSince1970: 0)
        while probe.timeIntervalSince1970 < 2_100_000_000 {
            let text = formatter.string(from: probe)
            #expect(parseTimestamp(text) == probe, "mismatch at \(text)")
            probe = probe.addingTimeInterval(97 * 3_600 + 61)
        }
    }

    @Test("Fractional seconds parse at any precision")
    func fractions() {
        #expect(parseTimestamp("2026-08-08T15:34:39.5Z")
                == Date(timeIntervalSince1970: 1_786_203_279.5))
        #expect(parseTimestamp("2026-08-08T15:34:39.250Z")?.timeIntervalSince1970 == 1_786_203_279.25)
    }

    @Test("Garbage is nil, never a wrong date")
    func garbage() {
        #expect(parseTimestamp("") == nil)
        #expect(parseTimestamp("2026-08-08 15:34:39") == nil)     // space, no Z
        #expect(parseTimestamp("2026-13-08T15:34:39Z") == nil)    // month 13
        #expect(parseTimestamp("2026-08-08T15:34:39") == nil)     // missing Z
        #expect(parseTimestamp("not a date at all!!") == nil)
    }

    @Test("The leap day itself")
    func leapDay() {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let text = "2024-02-29T12:00:00Z"
        #expect(parseTimestamp(text) == formatter.date(from: text))
    }
}
