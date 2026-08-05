import Testing
@testable import AppDomain

// MARK: - Announcement identity

// The announcement identity decides whether the app speaks when Overpass answers. It used to compare
// `limit` alone, so turning onto a differently-named road with the same limit stayed silent — which is
// why the street was never announced. These pin the corrected contract.

@Suite("RoadInfo announcement")
struct RoadInfoAnnouncementTests {

    private func info(
        limit: RoadSpeedLimit = .value(MPH(30)),
        ref: String? = nil,
        name: String? = nil
    ) -> RoadInfo {
        RoadInfo(limit: limit, ref: ref, name: name, origin: .signed)
    }

    @Test("ref wins over name — 'A40' is quicker to hear than 'Western Avenue'")
    func refPreferredOverName() {
        #expect(info(ref: "A40", name: "Western Avenue").roadLabel == "A40")
    }

    @Test("name is used when there is no ref")
    func nameUsedWithoutRef() {
        #expect(info(name: "High Street").roadLabel == "High Street")
    }

    @Test("a road OSM named neither way has no label")
    func noLabelWhenNeitherTagPresent() {
        #expect(info().roadLabel == nil)
    }

    @Test("same limit, different road — must announce")
    func sameLimitDifferentRoadDiffers() {
        #expect(info(name: "High Street").announcement != info(name: "Oxford Road").announcement)
    }

    @Test("same road, different limit — must announce")
    func sameRoadDifferentLimitDiffers() {
        let before = info(limit: .value(MPH(30)), name: "High Street")
        let after = info(limit: .value(MPH(40)), name: "High Street")
        #expect(before.announcement != after.announcement)
    }

    @Test("same road, same limit — must stay silent across repeated Overpass polls")
    func unchangedRoadIsSilent() {
        let before = info(limit: .value(MPH(30)), ref: "A40", name: "Western Avenue")
        let after = info(limit: .value(MPH(30)), ref: "A40", name: "Western Avenue")
        #expect(before.announcement == after.announcement)
    }

    @Test("a change confined to the unspoken tag does not re-announce")
    func labelDerivationDrivesEquality() {
        // `ref` wins, so dropping a name the rider never heard must not re-announce the road.
        #expect(info(ref: "A40", name: "Western Avenue").announcement == info(ref: "A40").announcement)
    }
}

// MARK: - Overpass parsing

@Suite("Overpass parsing")
struct OverpassParsingTests {

    private let here = (Latitude(51.75), Longitude(-0.475))
    /// Travelling east, matching the east–west geometry below, so selection always has a valid
    /// candidate and these tests stay about *tag* parsing rather than road choice.
    private let course = Course(90)

    /// One east–west way with the given tags — built directly rather than through JSON, so the test
    /// exercises the parser rather than the decoder.
    private func response(
        maxspeed: String? = nil,
        name: String? = nil,
        ref: String? = nil,
        highway: String? = nil,
        maxspeedType: String? = nil,
        maxspeedVariable: String? = nil
    ) -> OverpassResponse {
        OverpassResponse(elements: [
            OverpassResponse.Element(tags: OverpassResponse.Element.Tags(
                maxspeed: maxspeed,
                name: name,
                ref: ref,
                highway: highway,
                maxspeedType: maxspeedType,
                maxspeedVariable: maxspeedVariable
            ),
            geometry: [
                .init(lat: 51.75, lon: -0.480),
                .init(lat: 51.75, lon: -0.470)
            ])
        ])
    }

    @Test("an explicit mph limit is taken at face value")
    func explicitMph() {
        let parsed = parseRoadInfo(response(maxspeed: "30 mph", name: "High Street"), at: here, course: course)
        #expect(parsed.limit == .value(MPH(30)))
        #expect(parsed.roadLabel == "High Street")
        #expect(parsed.origin == .signed)
    }

    @Test("a km/h limit is converted to mph")
    func kphConverted() {
        guard case .value(let mph) = parseRoadInfo(response(maxspeed: "80 km/h"), at: here, course: course).limit else {
            Issue.record("expected a resolved value")
            return
        }
        #expect(abs(mph.rawValue - 49.71) < 0.05)
    }

    @Test("maxspeed:type outranks highway classification when resolving national")
    func maxspeedTypeWins() {
        let parsed = parseRoadInfo(response(
            maxspeed: "national",
            highway: "motorway",
            maxspeedType: "gb:nsl_single"
        ), at: here, course: course)
        #expect(parsed.limit == .value(MPH(60)))
        #expect(parsed.origin == .nationalSpeedLimit)
    }

    @Test("highway classification resolves national when maxspeed:type is absent")
    func highwayResolvesNational() {
        let parsed = parseRoadInfo(response(maxspeed: "national", highway: "residential"), at: here, course: course)
        #expect(parsed.limit == .value(MPH(30)))
        // A residential 30 is the built-up-area default, *not* the national speed limit — which
        // means 60 or 70. Announcing "national speed, 30" in a housing estate was flatly wrong.
        #expect(parsed.origin == .builtUpArea)
    }

    @Test("a national limit with nothing to resolve it stays ambiguous")
    func unresolvableNationalStaysNational() {
        let parsed = parseRoadInfo(response(maxspeed: "national"), at: here, course: course)
        #expect(parsed.limit == .national)
        #expect(parsed.origin == .unattributed)
    }

    @Test("no elements at all means unknown, not a guess")
    func emptyResponseIsUnknown() {
        #expect(parseRoadInfo(OverpassResponse(elements: []), at: here, course: course).limit == .unknown)
    }

    @Test("an untagged way is subject to the national limit, not unknown")
    func untaggedIsNationalNotUnknown() {
        // Deliberate change. An absent `maxspeed` does not mean "no limit" — in the UK the road is
        // subject to the national limit for its class. With no classification either, the class is
        // ambiguous, so `.national` is the honest answer: limited, but by an amount we cannot name.
        // Returning `.unknown` here previously discarded the over/under announcements entirely.
        let parsed = parseRoadInfo(response(name: "Back Lane"), at: here, course: course)
        #expect(parsed.limit == .national)
        #expect(parsed.roadLabel == "Back Lane")
    }

    @Test("an untagged residential road resolves to 30, attributed to the built-up default")
    func untaggedResidentialResolves() {
        let parsed = parseRoadInfo(
            response(name: "Back Lane", highway: "residential"), at: here, course: course
        )
        #expect(parsed.limit == .value(MPH(30)))
        // Attributed so the announcement can say "built-up area, 30" — inferred from the road's
        // class, and distinguishable from both a surveyed sign and the national speed limit.
        #expect(parsed.origin == .builtUpArea)
    }

    @Test("a smart motorway is flagged as variable")
    func variableLimitDetected() {
        // OSM records *that* the limit varies, never what the gantries currently show. Asserting
        // the default figure would be worse than saying it varies.
        let parsed = parseRoadInfo(
            response(maxspeed: "70 mph", highway: "motorway", maxspeedVariable: "yes"),
            at: here, course: course
        )
        #expect(parsed.isVariable)
    }
}
