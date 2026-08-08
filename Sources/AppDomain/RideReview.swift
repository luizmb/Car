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

/// The places routes have been started to, newest first, deduplicated.
///
/// The best completion list is the places someone actually goes: home, work, the parents', the
/// usual fuel stop. Each carries the coordinates it was resolved to at the time, so choosing one
/// skips the completer round-trip entirely — it is already a resolved destination.
public func recentDestinations(from records: [JourneyRecord]) -> [AddressSuggestion] {
    var seen: Set<String> = []
    return records
        .sorted { $0.time > $1.time }
        .compactMap { record -> AddressSuggestion? in
            guard let payload = record.payload as? DestinationPayload else { return nil }
            let title = payload.name ?? String(format: "%.4f, %.4f", payload.lat, payload.lon)
            guard seen.insert(title).inserted else { return nil }
            return AddressSuggestion(
                title: title, subtitle: "",
                latitude: Latitude(payload.lat), longitude: Longitude(payload.lon)
            )
        }
}

/// The destination a ride was heading to, when one was set.
public extension Ride {
    var destination: DestinationPayload? {
        records.compactMap { $0.payload as? DestinationPayload }.last
    }
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

// MARK: - The detail, precomputed

/// One point of a ride chart.
public struct ChartPoint: Sendable, Equatable {
    public let time: Date
    public let value: Double

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

/// One stretch of indicator, as a value the screen can diff.
public struct IndicatorInterval: Sendable, Equatable {
    public let side: String
    public let start: Date
    public let end: Date

    public init(side: String, start: Date, end: Date) {
        self.side = side
        self.start = start
        self.end = end
    }
}

/// Everything the detail screen draws, computed **once** when a ride is selected.
///
/// The screen was recomputing the track (a compactMap over every record) five times per body
/// evaluation, and a body evaluation happened on every scrub tick — the lag was arithmetic, not
/// rendering. Charts additionally get downsampled series: a phone-width chart cannot show more
/// than a few hundred points anyway, and Swift Charts walks every mark it is given.
public struct RideDetail: Sendable, Equatable {
    public let track: [Coordinate]
    public let speed: [ChartPoint]
    public let altitude: [ChartPoint]
    public let gradient: [ChartPoint]
    public let indicators: [IndicatorInterval]
    /// The full-resolution fix timeline, for the scrub ball — position lookup is a binary search
    /// here, not a linear walk per drag frame.
    public let fixTimes: [Date]
    public let fixCoordinates: [Coordinate]

    public init(
        track: [Coordinate], speed: [ChartPoint], altitude: [ChartPoint],
        gradient: [ChartPoint], indicators: [IndicatorInterval],
        fixTimes: [Date], fixCoordinates: [Coordinate]
    ) {
        self.track = track
        self.speed = speed
        self.altitude = altitude
        self.gradient = gradient
        self.indicators = indicators
        self.fixTimes = fixTimes
        self.fixCoordinates = fixCoordinates
    }
}

/// Min–max bucket downsampling: each bucket contributes its extremes, in time order.
///
/// Extremes rather than averages, because the spikes are the story — a top-speed blip or a
/// pothole's gradient must survive the thinning, and averaging would file them off.
public func downsampled(_ points: [ChartPoint], buckets: Int) -> [ChartPoint] {
    guard buckets > 0, points.count > buckets * 2 else { return points }
    let size = Double(points.count) / Double(buckets)
    var kept: [ChartPoint] = []
    kept.reserveCapacity(buckets * 2)
    for bucket in 0..<buckets {
        let start = Int(Double(bucket) * size)
        let end = min(points.count, Int(Double(bucket + 1) * size))
        guard start < end else { continue }
        let slice = points[start..<end]
        guard
            let low = slice.min(by: { $0.value < $1.value }),
            let high = slice.max(by: { $0.value < $1.value })
        else { continue }
        if low == high {
            kept.append(low)
        } else {
            kept.append(contentsOf: low.time <= high.time ? [low, high] : [high, low])
        }
    }
    return kept
}

/// Cuts a ride into its precomputed detail. Pure, and the only place the heavy walks happen.
public func rideDetail(for ride: Ride, maxChartBuckets: Int = 160) -> RideDetail {
    let fixes = ride.track
    let coordinates = fixes.map {
        Coordinate(latitude: Latitude($0.fix.lat), longitude: Longitude($0.fix.lon))
    }
    let speed = fixes.compactMap { point in
        point.fix.mph.map { ChartPoint(time: point.time, value: $0) }
    }
    let altitude = fixes.compactMap { point in
        point.fix.alt.map { ChartPoint(time: point.time, value: $0) }
    }
    let gradient = ride.gradients.map { ChartPoint(time: $0.time, value: $0.percent) }
    return RideDetail(
        track: coordinates,
        speed: downsampled(speed, buckets: maxChartBuckets),
        altitude: downsampled(altitude, buckets: maxChartBuckets),
        gradient: downsampled(gradient, buckets: maxChartBuckets),
        indicators: ride.indicatorIntervals.map {
            IndicatorInterval(side: $0.side, start: $0.start, end: $0.end)
        },
        fixTimes: fixes.map(\.time),
        fixCoordinates: coordinates
    )
}

/// Where the ride was at an instant — a binary search over the precomputed timeline, so the ball
/// can follow a finger at frame rate without walking the ride.
public func trackPosition(at time: Date, times: [Date], coordinates: [Coordinate]) -> Coordinate? {
    guard let first = times.first, let firstCoord = coordinates.first,
          let last = times.last, let lastCoord = coordinates.last,
          times.count == coordinates.count
    else { return nil }
    guard time > first else { return firstCoord }
    guard time < last else { return lastCoord }

    var low = 0
    var high = times.count - 1
    while high - low > 1 {
        let mid = (low + high) / 2
        if times[safe: mid].map({ $0 <= time }) == true { low = mid } else { high = mid }
    }
    guard
        let beforeTime = times[safe: low], let afterTime = times[safe: high],
        let before = coordinates[safe: low], let after = coordinates[safe: high]
    else { return nil }
    let span = afterTime.timeIntervalSince(beforeTime)
    let fraction = span > 0 ? time.timeIntervalSince(beforeTime) / span : 0
    return Coordinate(
        latitude: Latitude(before.latitude.rawValue
            + (after.latitude.rawValue - before.latitude.rawValue) * fraction),
        longitude: Longitude(before.longitude.rawValue
            + (after.longitude.rawValue - before.longitude.rawValue) * fraction)
    )
}
