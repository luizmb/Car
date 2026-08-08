import AppDomain
import Foundation

/// The UTC day a timestamp falls in, as a count of days since the epoch.
///
/// Integer division rather than `Calendar`: Unix time has no leap seconds, so a UTC day is exactly
/// 86,400 seconds and the arithmetic is exact. It also keeps `Calendar.current` — and with it the
/// device's locale and time zone — out of a decision that must not depend on either.
func utcDayIndex(_ date: Date) -> Int {
    Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
}

/// `2026-08-05` for a given UTC day index.
func utcDayStamp(_ dayIndex: Int) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withFullDate]
    return formatter.string(from: Date(timeIntervalSince1970: Double(dayIndex) * 86_400))
}

/// Appends lines to a JSONL file, one file per UTC day.
///
/// Only the **debug** firehose lives here now — `String(describing:)` of every action, on or off
/// journey: brilliant for a first ride, useless as a record, and deleted weekly. The journey
/// timeline that once shared this type lives in the app database as typed rows.
///
/// Crude on purpose. In a Redux app every observation already passes through the store as an action,
/// so dumping actions captures GPS, road info, Indimate, Cardo, CHIGEE and tyre readings in one
/// stroke, in true interleaved order, with no per-source plumbing.
///
/// Actions are recorded via `String(describing:)` rather than `Codable`. That is a deliberate trade:
/// no conformances to write, nothing to keep in step as types change, and the output is still
/// perfectly parseable offline.
///
/// **A day, not a launch.** Files were previously cut per app launch, which fragmented a single ride
/// across however many times iOS happened to kill and restore the app — boundaries that correspond
/// to nothing in the world. A UTC day is at least a boundary that means something, and it makes the
/// directory listing readable at a glance.
///
/// It is deliberately *not* a boundary that journeys respect. A journey is two timestamps, and a late
/// ride home will straddle two files — so any reader must be prepared to span them. That is the
/// cheaper half of the trade: journeys are a view over the timeline, and the timeline's filing
/// system was never meant to define them.
///
/// UTC rather than local time, as asked. Note the consequence during British Summer Time: the roll
/// happens at 01:00 local, not midnight.
///
/// Written with `O_APPEND` and flushed per line: the app spends whole journeys backgrounded and can
/// be killed at any moment, so buffering would risk losing exactly the ride you cared about. Reopened
/// rather than truncated on relaunch, since a day's file usually already exists.
final class ActionLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let now: @Sendable () -> Date
    private let timestampFormatter: ISO8601DateFormatter
    private var handle: FileHandle?
    private var dayIndex: Int?
    private var _url: URL?

    var url: URL? { lock.withLock { _url } }

    /// The directory is injected rather than looked up, for the same reason the clock is: two
    /// instances pointed at the shared Documents folder fight over the same day's file.
    private let prefix: String

    init(directory: URL, prefix: String, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.prefix = prefix
        self.now = now
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.timestampFormatter = formatter
    }

    /// A free-text line, wrapped as `{"t":…,"a":…}`. The debug log's shape.
    func append(_ action: String) {
        let date = now()
        let line: [String: Any] = [
            "t": timestampFormatter.string(from: date),
            "a": action
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return }
        write(text, at: date)
    }

    private func write(_ text: String, at date: Date) {
        lock.withLock {
            rollIfNeeded(to: utcDayIndex(date))
            handle?.write(Data((text + "\n").utf8))
        }
    }

    /// Opens today's file, closing yesterday's. Called on every line, because the app can and does
    /// stay alive across midnight — which for a night rider is precisely when it matters.
    private func rollIfNeeded(to today: Int) {
        guard dayIndex != today else { return }

        try? handle?.close()

        let file = directory.appendingPathComponent("\(prefix)-\(utcDayStamp(today)).jsonl")

        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let opened = try? FileHandle(forWritingTo: file)
        // Appending, not overwriting — a relaunch on the same day must continue the file rather than
        // erase the morning's ride.
        _ = try? opened?.seekToEnd()

        handle = opened
        dayIndex = today
        _url = file
    }
}
