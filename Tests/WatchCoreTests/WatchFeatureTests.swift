import AppDomain
import Foundation
import ReactiveConcurrency
import SwiftRex
import Testing
@testable import WatchCore

// The watch presents; these tests pin the presenting. The store is real, the world is closures,
// and the haptic player is a spy — because the thing that matters most on a wrist, the buzz, is
// exactly the thing a screenshot cannot show.

private final class HapticSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var played: [WatchHaptic] = []
    func play(_ haptic: WatchHaptic) { lock.withLock { played.append(haptic) } }
    var all: [WatchHaptic] { lock.withLock { played } }
}

@MainActor
private func makeStore(
    haptics: HapticSpy = HapticSpy(),
    sendResult: Bool = true
) -> any StoreType<WatchFeature.Action, WatchFeature.State> {
    WatchMain.store(world: WatchFeature.Environment(
        snapshots: { .empty() },
        reachability: { .empty() },
        sendRefuel: { _ in .just(sendResult) },
        playHaptic: { haptic in
            haptics.play(haptic)
            return .just(())
        }
    ))
}

@Suite("Watch presentation")
@MainActor
struct WatchPresentationTests {
    @Test("A snapshot lands whole")
    func snapshotLands() async {
        let store = makeStore()
        let snapshot = WatchSnapshot(mph: 31, limitText: "30", overLimit: true, roadLabel: "A505")
        store.dispatch(.snapshotArrived(snapshot), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }
        #expect(store.state.snapshot == snapshot)
        #expect(store.state.consecutiveOver == 1)
    }

    @Test("The indicator coming on buzzes the wrist, staying on ticks it")
    func indicatorHaptics() async {
        let spy = HapticSpy()
        let store = makeStore(haptics: spy)
        store.dispatch(.snapshotArrived(WatchSnapshot(indicator: "left")), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }
        store.dispatch(.snapshotArrived(WatchSnapshot(indicator: "left")), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }
        store.dispatch(.snapshotArrived(WatchSnapshot()), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }
        #expect(spy.all == [.indicatorOn, .indicatorTick, .indicatorOff])
    }

    @Test("Going over the limit buzzes once, not every second")
    func overSpeedHaptics() async {
        let spy = HapticSpy()
        let store = makeStore(haptics: spy)
        for _ in 0..<3 {
            store.dispatch(.snapshotArrived(WatchSnapshot(overLimit: true)), source: .init(file: #file, function: #function, line: #line))
            for _ in 0..<5 { await Task.yield() }
        }
        store.dispatch(.snapshotArrived(WatchSnapshot(overLimit: false)), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }
        #expect(spy.all == [.overSpeed, .backUnderLimit])
    }

    @Test("Submitting a refuel sends the draft and reports the outcome")
    func refuelRoundTrip() async {
        let store = makeStore()
        var draft = WatchFeature.RefuelDraft()
        draft.litres = 8.5
        draft.filledToBrim = false
        store.dispatch(.refuelEdited(draft), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.submitRefuel, source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.state.refuelDelivered == true)
        #expect(!store.state.refuelSending)
    }

    @Test("Leaving the refuel tab retires its outcome banner")
    func bannerRetires() async {
        let store = makeStore()
        store.dispatch(.submitRefuel, source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.state.refuelDelivered == true)
        store.dispatch(.tabChanged(.instruments), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.refuelDelivered == nil)
    }
}
