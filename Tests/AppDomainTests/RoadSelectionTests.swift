import Foundation
import Testing
@testable import AppDomain

// The scenario these exist for: riding east along a 30 mph road, with a motorway crossing
// perpendicularly overhead on a bridge. Both are within the search radius. The old parser took
// whichever way Overpass listed first, so it could announce "Motorway ABC, 70" and then hold 70 as
// the limit — poisoning every over/under announcement until the next road change.

@Suite("Road selection")
struct RoadSelectionTests {

    /// Roughly the junction of the A505 and the M1, but any pair of crossing roads would do.
    private let here = (Latitude(51.75), Longitude(-0.475))

    private func tags(
        name: String?, ref: String? = nil, maxspeed: String? = nil, highway: String? = "residential"
    ) -> OverpassResponse.Element.Tags {
        OverpassResponse.Element.Tags(
            maxspeed: maxspeed, name: name, ref: ref, highway: highway,
            maxspeedType: nil, maxspeedVariable: nil
        )
    }

    /// A road running east–west through `here`.
    private func eastWest(_ t: OverpassResponse.Element.Tags) -> RoadCandidate {
        RoadCandidate(tags: t, points: [
            (Latitude(51.75), Longitude(-0.480)),
            (Latitude(51.75), Longitude(-0.470))
        ])
    }

    /// A road running north–south through `here`.
    private func northSouth(_ t: OverpassResponse.Element.Tags) -> RoadCandidate {
        RoadCandidate(tags: t, points: [
            (Latitude(51.746), Longitude(-0.475)),
            (Latitude(51.754), Longitude(-0.475))
        ])
    }

    @Test("riding east under a north-south motorway picks the road, not the bridge")
    func perpendicularMotorwayRejected() {
        let road = eastWest(tags(name: "Road A", maxspeed: "30 mph"))
        let motorway = northSouth(tags(name: nil, ref: "M1", maxspeed: "70 mph", highway: "motorway"))

        // Listed motorway-first, which is exactly the ordering that used to win.
        let chosen = selectRoad(from: [motorway, road], at: here, course: Course(90))
        #expect(chosen?.tags.name == "Road A")

        let info = roadInfo(from: chosen)
        #expect(info.limit == .value(MPH(30)))
        #expect(info.roadLabel == "Road A")
    }

    @Test("the same junction, riding north, correctly picks the motorway")
    func onTheMotorwayItIsChosen() {
        // The inverse case falls out of the same rule with no special-casing: when you really are
        // on the motorway, your course matches it and it wins.
        let road = eastWest(tags(name: "Road A", maxspeed: "30 mph"))
        let motorway = northSouth(tags(name: nil, ref: "M1", maxspeed: "70 mph", highway: "motorway"))

        let chosen = selectRoad(from: [road, motorway], at: here, course: Course(0))
        #expect(chosen?.tags.ref == "M1")
        #expect(roadInfo(from: chosen).limit == .value(MPH(70)))
    }

    @Test("travelling the opposite way along a road still matches it")
    func roadsAreUndirected() {
        // A road is undirected: heading west on an east–west road is a 180° difference, which must
        // read as a perfect match rather than the worst possible one.
        let road = eastWest(tags(name: "Road A", maxspeed: "30 mph"))
        let motorway = northSouth(tags(name: nil, ref: "M1", maxspeed: "70 mph", highway: "motorway"))
        #expect(selectRoad(from: [motorway, road], at: here, course: Course(270))?.tags.name == "Road A")
    }

    @Test("with no heading, the nearest road wins")
    func stationaryFallsBackToDistance() {
        // Stationary, CoreLocation reports no course. Distance is all that is left — and guessing
        // by proximity is better than guessing by list order.
        let near = RoadCandidate(tags: tags(name: "Near"), points: [
            (Latitude(51.7500), Longitude(-0.4760)), (Latitude(51.7500), Longitude(-0.4740))
        ])
        let far = RoadCandidate(tags: tags(name: "Far"), points: [
            (Latitude(51.7520), Longitude(-0.4760)), (Latitude(51.7520), Longitude(-0.4740))
        ])
        #expect(selectRoad(from: [far, near], at: here, course: nil)?.tags.name == "Near")
    }

    @Test("a road with no maxspeed still resolves through its classification")
    func unTaggedRoadStillResolves() {
        // The reason the query no longer filters on `maxspeed`: ordinary roads often lack the tag,
        // and filtering made the motorway the *only* candidate rather than merely the wrong one.
        let road = eastWest(tags(name: "Back Lane", maxspeed: nil, highway: "residential"))
        let info = roadInfo(from: selectRoad(from: [road], at: here, course: Course(90)))
        #expect(info.roadLabel == "Back Lane")
        #expect(info.limit == .value(MPH(30)))   // resolved from `residential`
    }

    @Test("no candidate within the heading window yields unknown, not a wrong answer")
    func nothingPlausibleIsUnknown() {
        // Better to admit ignorance than to announce a road that cannot be the one you are on.
        let motorway = northSouth(tags(name: nil, ref: "M1", maxspeed: "70 mph", highway: "motorway"))
        #expect(selectRoad(from: [motorway], at: here, course: Course(90)) == nil)
        #expect(roadInfo(from: nil).limit == .unknown)
    }

    @Test("a nearer but badly aligned road loses to a further, well aligned one")
    func headingOutweighsSmallDistanceDifference() {
        let aligned = eastWest(tags(name: "Aligned"))
        let crossingCloser = RoadCandidate(tags: tags(name: "Crossing"), points: [
            (Latitude(51.7495), Longitude(-0.47505)), (Latitude(51.7505), Longitude(-0.47505))
        ])
        #expect(selectRoad(from: [crossingCloser, aligned], at: here, course: Course(90))?.tags.name == "Aligned")
    }

    @Test("bearings are measured on the nearest segment, not the whole way")
    func bearingIsLocal() {
        // An L-shaped way: it runs north–south far away, then turns east–west right beside us. Only
        // the piece alongside says anything about our direction of travel.
        let bent = RoadCandidate(tags: tags(name: "Bent"), points: [
            (Latitude(51.760), Longitude(-0.480)),
            (Latitude(51.750), Longitude(-0.480)),
            (Latitude(51.750), Longitude(-0.470))
        ])
        #expect(selectRoad(from: [bent], at: here, course: Course(90))?.tags.name == "Bent")
    }
}

@Suite("Heading maths")
struct HeadingTests {

    @Test("identical bearings differ by nothing")
    func identical() { #expect(headingDelta(90, 90) == 0) }

    @Test("opposite bearings are the same road")
    func opposite() { #expect(headingDelta(90, 270) == 0) }

    @Test("perpendicular is the maximum")
    func perpendicular() { #expect(headingDelta(0, 90) == 90) }

    @Test("wrapping across north is handled")
    func wrapping() {
        #expect(abs(headingDelta(350, 10) - 20) < 0.001)
        #expect(abs(headingDelta(10, 350) - 20) < 0.001)
    }
}

// Reproduced from a live Overpass response at 51.86967,-0.41654 — the rider's own doorstep. Opening
// the app there announced "built-up area, 30" with no road name, on a road that is signed 20 and
// called Ormsby Close. Five ways are within 40 m and only one of them is right:
//
//   51985021    residential  maxspeed=20 mph  Ormsby Close   ← the answer
//   858832685   service      —                (unnamed)
//   911763041   residential  —                Ormsby Close
//   1256332960  residential  —                Ormsby Close
//   1256332961  service      —                (unnamed)
//
// Two independent failures met here: an unnamed driveway won on distance because a stationary phone
// reports no course, and the road itself is split into three ways of which only one carries the limit.

@Suite("The doorstep case")
struct DoorstepTests {

    private let here = (Latitude(51.86967), Longitude(-0.41654))

    private func tags(
        name: String?, maxspeed: String? = nil, highway: String
    ) -> OverpassResponse.Element.Tags {
        .init(maxspeed: maxspeed, name: name, ref: nil, highway: highway,
              maxspeedType: nil, maxspeedVariable: nil)
    }

    /// A way `metres` north of the origin, running east–west.
    private func way(
        _ t: OverpassResponse.Element.Tags, metresAway: Double
    ) -> RoadCandidate {
        let lat = 51.86967 + metresAway / 111_320
        return RoadCandidate(tags: t, points: [
            (Latitude(lat), Longitude(-0.4170)),
            (Latitude(lat), Longitude(-0.4160))
        ])
    }

    /// The five ways, with the driveways deliberately closer than the road.
    private var candidates: [RoadCandidate] {
        [
            way(tags(name: nil, highway: "service"), metresAway: 4),
            way(tags(name: nil, highway: "service"), metresAway: 9),
            way(tags(name: "Ormsby Close", highway: "residential"), metresAway: 18),
            way(tags(name: "Ormsby Close", maxspeed: "20 mph", highway: "residential"), metresAway: 22),
            way(tags(name: "Ormsby Close", highway: "residential"), metresAway: 30)
        ]
    }

    @Test("parked outside the house, the road wins over the driveway")
    func roadBeatsDriveway() {
        // Stationary, so CoreLocation reports no course and there is no heading to discriminate on.
        // Without the service penalty the nearest thing — an unnamed driveway four metres away —
        // wins, and the rider is told "built-up area, 30" with no name at all.
        let chosen = selectRoad(from: candidates, at: here, course: nil)
        #expect(chosen?.tags.name == "Ormsby Close")
    }

    @Test("the limit is borrowed from the segment that carries it")
    func limitBorrowedFromSibling() {
        // Two of the three Ormsby Close ways have no maxspeed. Landing on either produced 30 — the
        // built-up default — for a road signed 20.
        let info = roadInfo(
            from: selectRoad(from: candidates, at: here, course: nil),
            among: candidates
        )
        #expect(info.roadLabel == "Ormsby Close")
        #expect(info.limit == .value(MPH(20)))
        #expect(info.origin == .signed)
    }

    @Test("a footpath is never a candidate, however close")
    func footpathIgnored() {
        // Being two metres from a pavement says nothing about which road you are on.
        let withPath = candidates + [way(tags(name: "Footpath", highway: "footway"), metresAway: 1)]
        #expect(selectRoad(from: withPath, at: here, course: nil)?.tags.name == "Ormsby Close")
    }

    @Test("a service road you are genuinely on can still be chosen")
    func servicePenaltyIsNotExclusion() {
        // The penalty must not become a ban — car parks and long driveways are real places to ride.
        let onlyService = [way(tags(name: nil, highway: "service"), metresAway: 4)]
        #expect(selectRoad(from: onlyService, at: here, course: nil) != nil)
    }

    @Test("borrowing never crosses roads")
    func noCrossRoadBorrowing() {
        // A limit taken from a different road would be worse than the default it replaced.
        let mixed = [
            way(tags(name: "Ormsby Close", highway: "residential"), metresAway: 18),
            way(tags(name: "Whitehill Avenue", maxspeed: "40 mph", highway: "residential"), metresAway: 25)
        ]
        let info = roadInfo(from: selectRoad(from: mixed, at: here, course: nil), among: mixed)
        #expect(info.roadLabel == "Ormsby Close")
        #expect(info.limit == .value(MPH(30)))   // the built-up default, not the neighbour's 40
    }
}
