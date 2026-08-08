import FP
import Foundation

// MARK: - What a replay is made of

/// One thing the ride did, ready to happen again.
///
/// These are the *inputs* the app once received, not the outputs it produced: fixes and indicator
/// events go back in through the same behavior that handled them live, and everything else —
/// the map following, the speed announcements, the over-limit beeps — emerges again rather than
/// being played back. Roads are the one recorded *derivation* that is replayed, because looking
/// them up live from a desk would answer with the desk's road; the record is the historical truth
/// of what the rider was told.
public enum ReplayEvent: Sendable, Equatable {
    case fix(LocationUpdate)
    /// `"left"`, `"right"`, or `nil` for cancelled.
    case indicator(String?)
    case road(RoadInfo)
    /// The ride's end — the screen's cue that the tape ran out.
    case finished
}

/// An event, how long after the *previous* one it belongs, and where on the tape it sits — so
/// the screen can show a position ticking and a stopped bike reads as a red light, not a hang.
public struct ReplayStep: Sendable, Equatable {
    public let delay: TimeInterval
    /// Seconds from the tape's start (after trimming) — what the HUD counts.
    public let position: TimeInterval
    public let event: ReplayEvent

    public init(delay: TimeInterval, position: TimeInterval, event: ReplayEvent) {
        self.delay = delay
        self.position = position
        self.event = event
    }
}

/// A rider is moving above this; below it the tape is parked footage.
private let replayMovingMPS = 1.5
/// Seconds of stillness kept either side of the motion, so the pull-away has a run-up.
private let replayLeadSeconds: TimeInterval = 5

// MARK: - Cutting the tape

/// The ride's records as a schedule, real time, first event immediate.
///
/// Only the replayable kinds survive: fixes, indicators, roads. Barometer, tyres, weather and the
/// journey markers describe the ride but do not drive the screen being replayed. Delays are the
/// records' own spacing — a red light replays as a red light, because the point is to watch the
/// journey as it was, not a highlights reel.
///
/// The parked **bookends** are the one exception: a ride's record often opens with minutes of
/// standing still before the pull-away, and replaying that verbatim is footage of a wall — a real
/// rider watched two and a half minutes of zeroes and reasonably called it broken. The tape starts
/// a few seconds before the first movement and ends a few seconds after the last; every stop *in*
/// the ride stays real.
public func replaySchedule(for records: [JourneyRecord]) -> [ReplayStep] {
    let ordered = records.sorted { $0.time < $1.time }

    let movingTimes = ordered.compactMap { record -> Date? in
        guard
            let fix = record.payload as? FixPayload,
            let mph = fix.mph,
            Iso<MPS, MPH>.convert.reverseGet(MPH(mph)).rawValue >= replayMovingMPS
        else { return nil }
        return record.time
    }
    // A ride that never moves keeps its whole (short) tape rather than becoming nothing.
    let window: (Date, Date)? = zip(movingTimes.first, movingTimes.last).map {
        ($0.addingTimeInterval(-replayLeadSeconds), $1.addingTimeInterval(replayLeadSeconds))
    }

    var steps: [ReplayStep] = []
    var start: Date?
    var previous: Date?

    for record in ordered {
        if let (from, to) = window, record.time < from || record.time > to { continue }
        guard let event = replayEvent(for: record.payload) else { continue }
        let delay = previous.map { record.time.timeIntervalSince($0) } ?? 0
        let tapeStart = start ?? record.time
        start = tapeStart
        steps.append(ReplayStep(
            delay: max(0, delay),
            position: record.time.timeIntervalSince(tapeStart),
            event: event
        ))
        previous = record.time
    }
    if let last = steps.last {
        steps.append(ReplayStep(delay: 1, position: last.position + 1, event: .finished))
    }
    return steps
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    a.flatMap { justA in b.map { (justA, $0) } }
}

private func replayEvent(for payload: any JourneyPayloadType) -> ReplayEvent? {
    switch payload {
    case let fix as FixPayload:
        .fix(LocationUpdate(
            speed: fix.mph.map { Iso<MPS, MPH>.convert.reverseGet(MPH($0)) },
            speedAccuracy: nil,
            course: fix.course.map { Course(rawValue: $0) },
            latitude: Latitude(fix.lat),
            longitude: Longitude(fix.lon),
            altitude: Meters(fix.alt ?? 0),
            timestamp: Date(timeIntervalSince1970: 0),
            horizontalAccuracy: fix.acc.map { Meters($0) }
        ))
    case let indicator as IndicatorPayload:
        .indicator(indicator.side)
    case let road as RoadPayload:
        .road(roadInfo(fromRecorded: road))
    default:
        nil
    }
}

/// A recorded road line back into the value the monitor was handed live.
///
/// The record keeps one label where the live value had ref and name; it comes back as the name,
/// with no class — which quietly disables road-matched camera lookups during replay, exactly
/// right for a screen that is a film, not a warning system.
func roadInfo(fromRecorded road: RoadPayload) -> RoadInfo {
    let origin: LimitOrigin = switch road.origin {
    case "signed": .signed
    case "built-up": .builtUpArea
    case "national": .nationalSpeedLimit
    default: .unattributed
    }
    return RoadInfo(
        limit: road.mph.map { .value(MPH($0)) }
            ?? (origin == .nationalSpeedLimit ? .national : .unknown),
        ref: nil,
        name: road.label,
        origin: origin,
        isVariable: road.variable
    )
}
