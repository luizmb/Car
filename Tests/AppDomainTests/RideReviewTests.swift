import Foundation
import Testing
@testable import AppDomain

// The review is read-only over the journey log, so its correctness is entirely "does the
// reassembly say what the log says". These build records the way the recorder does and check the
// rides that come back out.

private func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_754_500_000 + seconds)
}

private func start(_ seconds: TimeInterval) -> JourneyRecord {
    JourneyRecord(time: at(seconds), payload: JourneyStartPayload(via: "ignition"))
}

private func end(_ seconds: TimeInterval) -> JourneyRecord {
    JourneyRecord(time: at(seconds), payload: JourneyEndPayload(seconds: Int(seconds), started: at(0)))
}

private func fix(
    _ seconds: TimeInterval, lat: Double, lon: Double, mph: Double? = nil
) -> JourneyRecord {
    JourneyRecord(time: at(seconds), payload: FixPayload(
        lat: lat, lon: lon, mph: mph, course: nil, alt: 100, acc: 5
    ))
}

private func indicator(_ seconds: TimeInterval, side: String?) -> JourneyRecord {
    JourneyRecord(time: at(seconds), payload: IndicatorPayload(side: side))
}

private func road(_ seconds: TimeInterval, label: String, mph: Double?) -> JourneyRecord {
    JourneyRecord(time: at(seconds), payload: RoadPayload(
        mph: mph, origin: "signed", label: label, variable: false
    ))
}

// MARK: - Assembly

@Suite("Cutting the log into rides")
struct RideAssemblyTests {
    @Test("A start and its end bound one ride")
    func oneRide() {
        let rides = assembleRides(from: [
            start(0), fix(1, lat: 52, lon: -0.46), end(60)
        ])
        #expect(rides.count == 1)
        #expect(rides[safe: 0]?.start == at(0))
        #expect(rides[safe: 0]?.end == at(60))
        #expect(rides[safe: 0]?.endedCleanly == true)
    }

    /// The app being killed mid-ride is the *normal* ending — pulling the logs requires a
    /// force-quit — so an unclosed journey is a ride, honestly labelled, not a parse error.
    @Test("A start with no end closes at its last record and says so")
    func unclosedRide() {
        let rides = assembleRides(from: [
            start(0), fix(1, lat: 52, lon: -0.46), fix(120, lat: 52.01, lon: -0.46)
        ])
        #expect(rides.count == 1)
        #expect(rides[safe: 0]?.end == at(120))
        #expect(rides[safe: 0]?.endedCleanly == false)
    }

    @Test("A second start while one is open splits them")
    func doubleStart() {
        let rides = assembleRides(from: [
            start(0), fix(1, lat: 52, lon: -0.46),
            start(300), fix(301, lat: 52.1, lon: -0.46), end(400)
        ])
        #expect(rides.count == 2)
        #expect(rides[safe: 0]?.endedCleanly == false)
        #expect(rides[safe: 1]?.endedCleanly == true)
    }

    /// Refuels happen *between* journeys by design and bypass the journey gate, so records outside
    /// any start/end pair belong to no ride.
    @Test("Records between journeys belong to no ride")
    func orphansExcluded() {
        let rides = assembleRides(from: [
            fix(0, lat: 52, lon: -0.46),
            start(10), fix(11, lat: 52, lon: -0.46), end(60),
            fix(90, lat: 52, lon: -0.46)
        ])
        #expect(rides.count == 1)
        #expect(rides[safe: 0]?.records.count == 3)
    }

    @Test("Out-of-order lines are healed by time")
    func sortsByTime() {
        let rides = assembleRides(from: [
            end(60), fix(1, lat: 52, lon: -0.46), start(0)
        ])
        #expect(rides.count == 1)
        #expect(rides[safe: 0]?.endedCleanly == true)
    }
}

// MARK: - Statistics

@Suite("What a ride can say about itself")
struct RideStatsTests {
    private var ride: Ride {
        assembleRides(from: [
            start(0),
            fix(1, lat: 52.000, lon: -0.46, mph: 0),
            fix(2, lat: 52.001, lon: -0.46, mph: 20),
            fix(3, lat: 52.002, lon: -0.46, mph: 40),
            indicator(4, side: "left"),
            indicator(5, side: nil),
            indicator(6, side: "left"),
            indicator(7, side: "right"),
            road(8, label: "Ormsby Close", mph: 20),
            road(9, label: "Ormsby Close", mph: 20),
            road(10, label: "London Road", mph: 30),
            end(60)
        ])[safe: 0] ?? Ride(start: at(0), end: at(0), endedCleanly: false, records: [])
    }

    @Test("Distance sums consecutive fixes")
    func distance() {
        // Two hops of 0.001° latitude ≈ 111 m each.
        #expect(abs(ride.distanceMetres - 222) < 5)
    }

    /// A teleport after signal loss would add road the rider never touched.
    @Test("A gap in fixes contributes no distance")
    func gapExcluded() {
        let gappy = assembleRides(from: [
            start(0),
            fix(1, lat: 52.0, lon: -0.46),
            // Forty seconds later and a kilometre away: signal loss, not riding.
            fix(41, lat: 52.01, lon: -0.46),
            end(60)
        ])[safe: 0]
        #expect((gappy?.distanceMetres ?? -1) < 1)
    }

    @Test("Top and moving-average speeds come from the fixes")
    func speeds() {
        #expect(ride.maxMPH == 40)
        // 20 and 40 are moving; the 0 is a light and is time, not riding.
        #expect(ride.averageMovingMPH == 30)
    }

    /// A `nil` side is a cancellation — it ends a signal rather than being one.
    @Test("Indicator counts ignore cancellations")
    func indicators() {
        let counts = ride.indicatorCounts
        #expect(counts.left == 2)
        #expect(counts.right == 1)
    }

    @Test("Roads are the itinerary, not the firehose")
    func roads() {
        #expect(ride.roadsVisited.map(\.label) == ["Ormsby Close", "London Road"])
    }
}

// MARK: - GPX

@Suite("GPX export")
struct GPXTests {
    @Test("The track survives the round trip into XML")
    func containsTrack() {
        let ride = assembleRides(from: [
            start(0),
            fix(1, lat: 52.123456, lon: -0.456789),
            fix(2, lat: 52.124, lon: -0.457),
            end(60)
        ])[safe: 0] ?? Ride(start: at(0), end: at(0), endedCleanly: false, records: [])
        let xml = gpx(for: ride)
        #expect(xml.contains("<gpx version=\"1.1\""))
        #expect(xml.contains("lat=\"52.123456\""))
        #expect(xml.contains("lon=\"-0.456789\""))
        #expect(xml.contains("<ele>100.0</ele>"))
        // Two points, two stamps.
        #expect(xml.components(separatedBy: "<trkpt").count == 3)
    }

    @Test("A ride with no fixes still yields a well-formed file")
    func emptyTrack() {
        let ride = Ride(start: at(0), end: at(1), endedCleanly: true, records: [])
        let xml = gpx(for: ride)
        #expect(xml.contains("<trkseg>"))
        #expect(!xml.contains("<trkpt"))
    }
}
