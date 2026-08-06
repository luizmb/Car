import Foundation
import Testing
@testable import AppDomain

// The rule is asymmetric on purpose and the asymmetry is the design, so it is pinned here rather
// than left to be re-derived from the wiring.

@Suite("Journey boundaries")
struct JourneyTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func signals(_ indimate: Bool, _ ignition: Bool) -> JourneySignals {
        JourneySignals(indimate: indimate, ignition: ignition)
    }

    @Test("either signal alone starts a journey")
    func startsOnEither() {
        // A disjunction, so an unreliable on-edge on one device costs nothing while the other works.
        #expect(journeyTransition(from: .idle, signals: signals(true, false), now: t0) == .active(since: t0))
        #expect(journeyTransition(from: .idle, signals: signals(false, true), now: t0) == .active(since: t0))
        #expect(journeyTransition(from: .idle, signals: signals(true, true), now: t0) == .active(since: t0))
    }

    @Test("neither signal means no journey")
    func staysIdle() {
        #expect(journeyTransition(from: .idle, signals: signals(false, false), now: t0) == nil)
    }

    @Test("one signal dropping does not end a journey")
    func oneDropIsNotAnEnding() {
        // The case this exists for: CHIGEE crashes and reboots mid-ride. Ending the journey there
        // would split one ride into two and lose the middle.
        let active = JourneyPhase.active(since: t0)
        #expect(journeyTransition(from: active, signals: signals(true, false), now: t0) == nil)
        #expect(journeyTransition(from: active, signals: signals(false, true), now: t0) == nil)
    }

    @Test("both gone ends it")
    func bothGoneEnds() {
        #expect(journeyTransition(from: .active(since: t0), signals: signals(false, false), now: t0) == .idle)
    }

    @Test("no transition is reported when nothing changed")
    func noSpuriousEdges() {
        // The caller announces on the edge, so a rule that reported "still active" every second
        // would talk continuously.
        #expect(journeyTransition(from: .active(since: t0), signals: signals(true, true), now: t0) == nil)
    }

    @Test("the start announcement names which signal opened it")
    func startWording() {
        // The two are not equally trustworthy; knowing which spoke first is the difference between
        // working and working by luck.
        #expect(journeyStartAnnouncement(signals(false, true)) == "Journey started, on ignition.")
        #expect(journeyStartAnnouncement(signals(true, false)) == "Journey started, on Indimate.")
        #expect(journeyStartAnnouncement(signals(true, true)) == "Journey started, on both signals.")
    }

    @Test("the end announcement carries the duration")
    func endWording() {
        // A wildly wrong figure is the fastest way to notice the rule misfired, and it is the one
        // part that cannot be checked later without opening a log.
        #expect(journeyEndAnnouncement(since: t0, now: t0.addingTimeInterval(30)) == "Journey finished, under a minute.")
        #expect(journeyEndAnnouncement(since: t0, now: t0.addingTimeInterval(60)) == "Journey finished, one minute.")
        #expect(journeyEndAnnouncement(since: t0, now: t0.addingTimeInterval(1_140)) == "Journey finished, 19 minutes.")
    }
}
