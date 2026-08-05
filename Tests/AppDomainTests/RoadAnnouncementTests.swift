import Foundation
import Testing
@testable import AppDomain

// The complaint these come from, verbatim: "Sometimes it says '30 zone', sometimes 'National speed'
// (without saying how much), sometimes 'National speed 30', sometimes speaks the road name,
// sometimes not."
//
// Every one of those was a different OSM tagging situation, and the app was right to behave
// differently — but it described two quite different inferences with the same phrase, and the phrase
// it chose was false in one of them. These pin the wording so the variation is legible rather than
// arbitrary.

@Suite("Road announcements")
struct RoadAnnouncementTests {

    /// The real formatter's shape: a bare integer, as spoken.
    private let speak: (MPH) -> String = { String(Int($0.rawValue)) }

    private func info(
        limit: RoadSpeedLimit, origin: LimitOrigin,
        name: String? = nil, ref: String? = nil, variable: Bool = false
    ) -> RoadInfo {
        RoadInfo(limit: limit, ref: ref, name: name, origin: origin, isVariable: variable)
    }

    @Test("a surveyed sign is stated plainly")
    func signed() {
        #expect(roadAnnouncement(
            info(limit: .value(MPH(30)), origin: .signed, name: "High Street"),
            formatSpeed: speak
        ) == "30 zone, High Street")
    }

    @Test("a residential 30 is a built-up default, never the national speed limit")
    func builtUpArea() {
        // The bug. "National speed limit" means 60 or 70 and has its own sign; saying it on a
        // housing estate is not imprecise, it is wrong, and obviously so to the rider.
        #expect(roadAnnouncement(
            info(limit: .value(MPH(30)), origin: .builtUpArea, name: "Back Lane"),
            formatSpeed: speak
        ) == "built-up area, 30, Back Lane")
    }

    @Test("an inferred 60 is the national speed limit, and says so with the figure")
    func nationalWithFigure() {
        // What the rider asked for: "road a, national speed, 60mph".
        #expect(roadAnnouncement(
            info(limit: .value(MPH(60)), origin: .nationalSpeedLimit, ref: "A505"),
            formatSpeed: speak
        ) == "national speed limit, 60, A505")
    }

    @Test("an unresolvable national limit gives no figure rather than a wrong one")
    func nationalWithoutFigure() {
        #expect(roadAnnouncement(
            info(limit: .national, origin: .unattributed, name: "Some Road"),
            formatSpeed: speak
        ) == "national speed limit, Some Road")
    }

    @Test("a variable limit speaks the number and flags it")
    func variable() {
        // The gantries win, but a figure still has to exist for the over/under announcements.
        #expect(roadAnnouncement(
            info(limit: .value(MPH(70)), origin: .signed, ref: "M25", variable: true),
            formatSpeed: speak
        ) == "70, variable, M25")
    }

    @Test("a named road with no limit still gets announced")
    func nameOnly() {
        #expect(roadAnnouncement(
            info(limit: .unknown, origin: .unattributed, name: "Back Lane"),
            formatSpeed: speak
        ) == "Back Lane")
    }

    @Test("a limit on an unnamed road still gets announced")
    func limitOnly() {
        #expect(roadAnnouncement(
            info(limit: .value(MPH(40)), origin: .signed),
            formatSpeed: speak
        ) == "40 zone")
    }

    @Test("with neither, nothing is said")
    func silence() {
        #expect(roadAnnouncement(
            info(limit: .unknown, origin: .unattributed),
            formatSpeed: speak
        ).isEmpty)
    }

    @Test("the ref is preferred to the name — shorter to hear at speed")
    func refWinsOverName() {
        #expect(roadAnnouncement(
            info(limit: .value(MPH(70)), origin: .nationalSpeedLimit, name: "Western Avenue", ref: "A40"),
            formatSpeed: speak
        ) == "national speed limit, 70, A40")
    }
}
