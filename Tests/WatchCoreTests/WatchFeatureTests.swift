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
        draft.litresInt = 8
        draft.litresDec = 50
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

// MARK: - The digit windows

@Suite("Refuel digit windows")
@MainActor
struct RefuelDraftTests {
    /// The design in one line: "18.49" on the windows is £1.849 at the pump.
    @Test("Price is held pump-style, three pound-decimals from two windows")
    func pumpStylePrice() {
        var draft = WatchFeature.RefuelDraft()
        draft.priceInt = 18
        draft.priceDec = 49
        #expect(draft.pricePerLitre == 1.849)
    }

    @Test("Litres compose from the two windows and stay inside the tank")
    func litresCompose() {
        var draft = WatchFeature.RefuelDraft()
        draft.litresInt = 8
        draft.litresDec = 50
        #expect(draft.litres == 8.5)
        draft.litresInt = 0
        draft.litresDec = 0
        // An empty pick still means a fill happened; the floor is the smallest honest one.
        #expect(draft.litres == 0.25)
    }

    @Test("The odometer is one big number; zero means not read")
    func odometerWindow() {
        var draft = WatchFeature.RefuelDraft()
        #expect(draft.odometerKm == nil)
        draft.seedOdometer(km: 38_412)
        #expect(draft.odoKm == 38_412)
        #expect(draft.odometerKm == 38_412)
        #expect(draft.command.odometerKm == 38_412)
    }

    @Test("A snapshot's estimate seeds the odometer once, and never over a touched value")
    func estimateSeedsOnce() async {
        let store = makeStore()
        var snapshot = WatchSnapshot()
        snapshot.suggestedOdometerKm = 38_412
        store.dispatch(.snapshotArrived(snapshot), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }
        #expect(store.state.refuel.odometerKm == 38_412)

        // The rider corrects the reading; the next snapshot must not undo it.
        var edited = store.state.refuel
        edited.odoKm = 38_415
        store.dispatch(.refuelEdited(edited), source: .init(file: #file, function: #function, line: #line))
        var later = WatchSnapshot()
        later.suggestedOdometerKm = 38_499
        store.dispatch(.snapshotArrived(later), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }
        #expect(store.state.refuel.odometerKm == 38_415)
    }

    @Test("Leaving the refuel tab hands the crown back to paging")
    func focusClears() {
        let store = makeStore()
        store.dispatch(.refuelFocused(.priceDec), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.refuelFocus == .priceDec)
        store.dispatch(.tabChanged(.map), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.refuelFocus == nil)
    }
}
