import FP
import FPMacros
import Foundation

// MARK: - Signals

/// The two independent witnesses to the ignition being on.
///
/// Both are BLE devices fed by the bike's electrics, and both fail in their own way — Indimate has
/// been unplugged and has an unreliable reconnect, CHIGEE crashes and reboots mid-ride. Neither is
/// trusted alone, which is what the asymmetric rule below is for.
public struct JourneySignals: Sendable, Equatable {
    /// Indimate connected. Prompt on the off edge — measured ~20s ahead of CHIGEE every time.
    public let indimate: Bool
    /// CHIGEE connected, i.e. the head unit has power.
    public let ignition: Bool

    public init(indimate: Bool, ignition: Bool) {
        self.indimate = indimate
        self.ignition = ignition
    }

    public var any: Bool { indimate || ignition }
    public var none: Bool { !any }
}

// MARK: - Phase

@Prisms
public enum JourneyPhase: Sendable, Equatable {
    case idle
    case active(since: Date)
}

// MARK: - The rule

/// Whether a journey begins or ends, given the signals now.
///
/// **Asymmetric on purpose**, and the asymmetry is the whole design:
///
/// - **Starting is a disjunction.** Either device connecting begins the journey. Taking the earlier
///   of two independent signals is strictly better than either alone, which covers Indimate's
///   unreliable on-edge — it has taken 84 seconds to reconnect after a key cycle — without needing
///   it to be fixed.
/// - **Ending is a conjunction.** Both must be down. One dropping is a red flag, not an ending: a
///   CHIGEE reboot mid-ride must not close a journey the rider is still on.
///
/// Killing the engine on the side stand with the electrics live leaves both connected, so it stays
/// one journey. That is deliberate: the rider does it routinely, and a restart forty seconds later
/// is not a cold start and needs no choke, so *ignition* cycles proxy what the fuel model wants
/// better than engine cycles would.
///
/// Returns `nil` when nothing changes, so a caller can announce only on the edge.
public func journeyTransition(
    from phase: JourneyPhase,
    signals: JourneySignals,
    now: Date
) -> JourneyPhase? {
    switch phase {
    case .idle:
        signals.any ? .active(since: now) : nil
    case .active:
        signals.none ? .idle : nil
    }
}

// MARK: - Announcement

/// Spoken when the journey rule fires, so the decision is audible rather than inferred later from a
/// log. Which signal opened it is named, because the two are not equally trustworthy and knowing
/// which one spoke first is the difference between "working" and "working by luck".
public func journeyStartAnnouncement(_ signals: JourneySignals) -> String {
    let via: String = if signals.indimate && signals.ignition {
        "both signals"
    } else if signals.ignition {
        "ignition"
    } else {
        "Indimate"
    }
    return "Journey started, on \(via)."
}

/// Spoken when both signals have gone. The duration is included because it is the one part that
/// cannot be checked later without opening a log, and a wildly wrong figure is the fastest way to
/// notice the rule misfired.
public func journeyEndAnnouncement(since start: Date, now: Date) -> String {
    let seconds = now.timeIntervalSince(start)
    // Checked before rounding: half a minute rounds *up* to one, and "one minute" for a
    // thirty-second journey is exactly the sort of small lie that makes the rest untrustworthy.
    guard seconds >= 60 else { return "Journey finished, under a minute." }
    let minutes = Int((seconds / 60).rounded())
    return minutes == 1
        ? "Journey finished, one minute."
        : "Journey finished, \(minutes) minutes."
}

// MARK: - Ride-log marker

/// ISO-8601 in UTC, matching the `t` field the ride log stamps on every line.
///
/// Explicitly UTC rather than `Calendar.current`: the log is filed by UTC day and read on a Mac in
/// another time zone, so a local-time string embedded in a UTC line would be a trap.
func utcTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

/// A greppable line for the ride log, distinct from the action dump.
///
/// Every action is already logged via `String(describing:)`, so the journey transition is *in* there
/// — buried among tens of thousands of GPS and motion lines, in a shape that changes whenever a type
/// does. This is the stable, findable form:
///
/// ```
/// journey-start via=ignition
/// journey-end seconds=1140 started=2026-08-06T20:21:32Z
/// ```
///
/// The start time is carried on the end line on purpose: a journey is two timestamps, and having
/// both on one line means the record survives even if the beginning of the file is lost or the app
/// was relaunched mid-ride.
public func journeyMarker(
    from previous: JourneyPhase,
    to next: JourneyPhase,
    signals: JourneySignals,
    now: Date
) -> String? {
    switch (previous, next) {
    case (.idle, .active):
        let via = if signals.indimate && signals.ignition {
            "both"
        } else if signals.ignition {
            "ignition"
        } else {
            "indimate"
        }
        return "journey-start via=\(via)"
    case let (.active(since), .idle):
        let seconds = Int(now.timeIntervalSince(since).rounded())
        return "journey-end seconds=\(seconds) started=\(utcTimestamp(since))"
    default:
        return nil
    }
}
