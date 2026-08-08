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

/// An event and how long after the *previous* one it belongs — the tape, cut into waits.
public struct ReplayStep: Sendable, Equatable {
    public let delay: TimeInterval
    public let event: ReplayEvent

    public init(delay: TimeInterval, event: ReplayEvent) {
        self.delay = delay
        self.event = event
    }
}

// MARK: - Cutting the tape

/// The ride's records as a schedule, real time, first event immediate.
///
/// Only the replayable kinds survive: fixes, indicators, roads. Barometer, tyres, weather and the
/// journey markers describe the ride but do not drive the screen being replayed. Delays are the
/// records' own spacing — a five-minute wait at a junction replays as five minutes, because the
/// point is to watch the journey as it was, not a highlights reel.
public func replaySchedule(for records: [JourneyRecord]) -> [ReplayStep] {
    let ordered = records.sorted { $0.time < $1.time }
    var steps: [ReplayStep] = []
    var previous: Date?

    for record in ordered {
        guard let event = replayEvent(for: record.payload) else { continue }
        let delay = previous.map { record.time.timeIntervalSince($0) } ?? 0
        steps.append(ReplayStep(delay: max(0, delay), event: event))
        previous = record.time
    }
    if !steps.isEmpty {
        steps.append(ReplayStep(delay: 1, event: .finished))
    }
    return steps
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
