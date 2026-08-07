import FP
import FPMacros
import Foundation

// MARK: - A ride, reassembled

/// One journey, rebuilt from the journey log's records.
///
/// The log was designed for exactly this — typed, discriminated, one complete object per line — so
/// a ride is nothing but the records between a start marker and its end, and every statistic below
/// is derived rather than stored. Nothing here can disagree with the log, because nothing here is a
/// second copy of it.
public struct Ride: Sendable, Equatable, Identifiable {
    /// The start instant identifies the ride: two journeys cannot begin at the same moment.
    public var id: Date { start }
    public let start: Date
    public let end: Date
    /// Whether the log actually recorded an end, or the app died mid-ride and the last record
    /// stands in. Shown rather than hidden: a rider looking at a 4-hour "ride" deserves to know
    /// the clock is a guess.
    public let endedCleanly: Bool
    public let records: [JourneyRecord]

    public init(start: Date, end: Date, endedCleanly: Bool, records: [JourneyRecord]) {
        self.start = start
        self.end = end
        self.endedCleanly = endedCleanly
        self.records = records
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// The GPS track, in order. The one series almost every statistic hangs off.
    public var track: [(time: Date, fix: FixPayload)] {
        records.compactMap { record in
            (record.payload as? FixPayload).map { (record.time, $0) }
        }
    }

    /// Metres actually ridden, summed fix to fix.
    ///
    /// Consecutive fixes only: summing straight lines over a gap would cut corners the rider rode,
    /// and a teleport after signal loss would add road they never touched. A pair further apart
    /// than 30 seconds contributes nothing, matching the trip counter's own rule.
    public var distanceMetres: Double {
        let fixes = track
        guard fixes.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<fixes.count {
            guard
                let a = fixes[safe: index - 1], let b = fixes[safe: index],
                b.time.timeIntervalSince(a.time) <= 30
            else { continue }
            total += distanceMetres(from: (Latitude(a.fix.lat), Longitude(a.fix.lon)),
                                    to: (Latitude(b.fix.lat), Longitude(b.fix.lon)))
        }
        return total
    }

    public var maxMPH: Double? {
        track.compactMap(\.fix.mph).max()
    }

    /// Mean speed while actually moving. Sitting at lights is time, not riding.
    public var averageMovingMPH: Double? {
        let moving = track.compactMap(\.fix.mph).filter { $0 > 2 }
        guard !moving.isEmpty else { return nil }
        return moving.reduce(0, +) / Double(moving.count)
    }

    /// Indicator uses, from the Indimate's own events. `nil` sides are cancellations and count as
    /// neither — they end a signal rather than being one.
    public var indicatorCounts: (left: Int, right: Int) {
        let sides = records.compactMap { ($0.payload as? IndicatorPayload)?.side }
        return (sides.filter { $0 == "left" }.count, sides.filter { $0 == "right" }.count)
    }

    /// The roads ridden, in first-seen order, with the limit each carried.
    ///
    /// Deduplicated on the label rather than kept as raw records: the detector re-reports the same
    /// road constantly, and a review screen wants the itinerary, not the firehose.
    public var roadsVisited: [(label: String, mph: Double?)] {
        var seen: Set<String> = []
        return records.compactMap { record -> (String, Double?)? in
            guard
                let road = record.payload as? RoadPayload,
                let label = road.label,
                seen.insert(label).inserted
            else { return nil }
            return (label, road.mph)
        }
    }

    /// Camera and average-zone warnings given during the ride.
    public var cameraEventCount: Int {
        records.filter { $0.type == .camera || $0.type == .averageZone }.count
    }

    private func distanceMetres(
        from a: (Latitude, Longitude), to b: (Latitude, Longitude)
    ) -> Double {
        AppDomain.distanceMetres(from: a, to: b)
    }
}

public extension Ride {
    /// The stretches where an indicator was actually on.
    ///
    /// Rebuilt from the events rather than stored: a `left`/`right` payload opens a stretch, the
    /// next event closes it — a cancellation, the opposite side, or the same side again (the unit
    /// re-reports). A stretch still open at the ride's end closes there, because the Indimate
    /// disconnecting eats the cancel and an indicator cannot outlive the ride it was part of.
    var indicatorIntervals: [(side: String, start: Date, end: Date)] {
        var intervals: [(String, Date, Date)] = []
        var open: (side: String, start: Date)?
        for record in records {
            guard let payload = record.payload as? IndicatorPayload else { continue }
            if let current = open {
                intervals.append((current.side, current.start, record.time))
                open = nil
            }
            if let side = payload.side {
                open = (side, record.time)
            }
        }
        if let current = open {
            intervals.append((current.side, current.start, end))
        }
        return intervals
    }

    /// Road gradient over the ride, in percent, from consecutive fixes.
    ///
    /// Only pairs that measure something: at least five metres apart horizontally (altitude noise
    /// over a shorter base reads as a cliff), within thirty seconds (a gap is signal loss, not
    /// road), and both carrying an altitude. Clamped to ±25% — Britain has no public road steeper,
    /// so anything beyond it is GPS altitude doing what GPS altitude does.
    var gradients: [(time: Date, percent: Double)] {
        let fixes = track
        guard fixes.count > 1 else { return [] }
        var series: [(Date, Double)] = []
        for index in 1..<fixes.count {
            guard
                let a = fixes[safe: index - 1], let b = fixes[safe: index],
                let altA = a.fix.alt, let altB = b.fix.alt,
                b.time.timeIntervalSince(a.time) <= 30
            else { continue }
            let run = AppDomain.distanceMetres(
                from: (Latitude(a.fix.lat), Longitude(a.fix.lon)),
                to: (Latitude(b.fix.lat), Longitude(b.fix.lon))
            )
            guard run >= 5 else { continue }
            let percent = (altB - altA) / run * 100
            series.append((b.time, max(-25, min(25, percent))))
        }
        return series
    }

    /// Where the bike was at an instant, interpolated between the fixes either side.
    ///
    /// What the scrub ball runs on: a finger over a chart names a time, and this names the place.
    /// Linear between neighbours — a second apart, the road curves less than GPS wanders — and
    /// clamped to the track's ends rather than extrapolated beyond them.
    func position(at time: Date) -> Coordinate? {
        let fixes = track
        guard let first = fixes.first, let last = fixes.last else { return nil }
        guard time > first.time else {
            return Coordinate(latitude: Latitude(first.fix.lat), longitude: Longitude(first.fix.lon))
        }
        guard time < last.time else {
            return Coordinate(latitude: Latitude(last.fix.lat), longitude: Longitude(last.fix.lon))
        }
        for index in 1..<fixes.count {
            guard let a = fixes[safe: index - 1], let b = fixes[safe: index] else { continue }
            guard time <= b.time else { continue }
            let span = b.time.timeIntervalSince(a.time)
            let fraction = span > 0 ? time.timeIntervalSince(a.time) / span : 0
            return Coordinate(
                latitude: Latitude(a.fix.lat + (b.fix.lat - a.fix.lat) * fraction),
                longitude: Longitude(a.fix.lon + (b.fix.lon - a.fix.lon) * fraction)
            )
        }
        return Coordinate(latitude: Latitude(last.fix.lat), longitude: Longitude(last.fix.lon))
    }
}

// MARK: - Cutting the log into rides

/// Groups a log's records into rides.
///
/// A `journey-start` opens a ride; its `journey-end` closes it. A start with no end — the app was
/// killed mid-ride, which is the normal ending for a phone being force-quit to pull logs — closes
/// at its last record and says so. Records outside any journey (refuels happen *between* journeys
/// by design) belong to no ride and are left out.
public func assembleRides(from records: [JourneyRecord]) -> [Ride] {
    let ordered = records.sorted { $0.time < $1.time }
    var rides: [Ride] = []
    var current: [JourneyRecord] = []
    var open = false

    func close(cleanly: Bool) {
        guard open, let first = current.first, let last = current.last else { return }
        rides.append(Ride(
            start: first.time, end: last.time, endedCleanly: cleanly, records: current
        ))
        current = []
        open = false
    }

    for record in ordered {
        switch record.type {
        case .journeyStart:
            // A second start while one is open is the killed-app case seen from the other side.
            close(cleanly: false)
            open = true
            current = [record]
        case .journeyEnd:
            current.append(record)
            close(cleanly: true)
        default:
            guard open else { continue }
            current.append(record)
        }
    }
    close(cleanly: false)
    return rides
}

// MARK: - GPX

/// The ride's track as GPX 1.1 — the lingua franca every mapping tool imports.
///
/// Track points only, deliberately: waypoint-per-road-change or per-camera would make the file a
/// curiosity other tools choke on, and the typed log remains the record of everything else.
public func gpx(for ride: Ride, creator: String = "SpeedJarvis") -> String {
    let formatter = ISO8601DateFormatter()
    let points = ride.track.map { point -> String in
        let ele = point.fix.alt.map { "<ele>\(String(format: "%.1f", $0))</ele>" } ?? ""
        return "      <trkpt lat=\"\(point.fix.lat)\" lon=\"\(point.fix.lon)\">"
            + ele
            + "<time>\(formatter.string(from: point.time))</time></trkpt>"
    }
    .joined(separator: "\n")

    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="\(creator)" xmlns="http://www.topografix.com/GPX/1/1">
      <trk>
        <name>\(formatter.string(from: ride.start))</name>
        <trkseg>
    \(points)
        </trkseg>
      </trk>
    </gpx>
    """
}
