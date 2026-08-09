import AppDomain
import Foundation
import HealthKit
import ReactiveConcurrency
import WatchConnectivity
import WatchCore
import WatchKit

// MARK: - The watch's live world

extension WatchFeature.Environment {
    /// The real thing: WatchConnectivity behind the snapshot and command closures, WatchKit
    /// behind the haptic player, and nothing else — the watch has no stores, no clock of record
    /// and no authority, so its world is four closures wide.
    static var live: WatchFeature.Environment {
        let box = WatchSessionBox()
        return WatchFeature.Environment(
            snapshots: { box.snapshots },
            reachability: { box.reachability },
            sendRefuel: { refuel in
                Publisher.future { box.send(refuel) }
            },
            playHaptic: { haptic in
                Publisher.future {
                    DispatchQueue.main.async {
                        WKInterfaceDevice.current().play(haptic.wkType)
                    }
                }
            },
            beginRideSession: { Publisher.future { RideRuntimeBox.shared.begin() } },
            endRideSession: { Publisher.future { RideRuntimeBox.shared.end() } }
        )
    }
}

private extension WatchHaptic {
    /// The domain's vocabulary onto WatchKit's. Chosen by feel: direction taps for the blinker,
    /// the failure buzz for speed — the one that must cut through a motorway — and the gentle
    /// click for the once-a-second tick.
    var wkType: WKHapticType {
        switch self {
        case .indicatorOn: .directionUp
        case .indicatorTick: .click
        case .indicatorOff: .directionDown
        case .overSpeed: .failure
        case .backUnderLimit: .success
        }
    }
}

// MARK: - The session box

/// The watch's half of the link — the mirror of the phone's `PhoneWatchBox`.
///
/// Snapshots arrive two ways and merge into one stream: live messages while both sides are awake,
/// and the application context — which the system keeps and hands over even when this app wakes
/// hours later, so the instruments open on the last known truth rather than a blank face.
/// Outbound, a refuel goes as a message when the phone is live and as a queued user-info transfer
/// when it is not; the transfer survives launches on both sides, which is what makes a fill
/// logged with the phone asleep in a jacket pocket still land.
final class WatchSessionBox: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotListeners: [UUID: (WatchSnapshot) -> Void] = [:]
    private var reachabilityListeners: [UUID: (Bool) -> Void] = [:]

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var snapshots: Publisher<WatchSnapshot, Never> {
        Publisher { [weak self] continuation in
            guard let self else { return }
            let (stream, streamContinuation) = AsyncStream<WatchSnapshot>.makeStream()
            let id = UUID()
            self.lock.withLock { self.snapshotListeners[id] = { streamContinuation.yield($0) } }
            // Seed with whatever context the system already holds, so a fresh launch shows the
            // last known truth instead of waiting for the phone to speak again.
            let stored = WCSession.default.receivedApplicationContext
            if !stored.isEmpty { streamContinuation.yield(WatchWire.snapshot(from: stored)) }
            await continuation.yieldAll(stream)   // parks until cancelled
            self.lock.withLock { _ = self.snapshotListeners.removeValue(forKey: id) }
        }
    }

    var reachability: Publisher<Bool, Never> {
        Publisher { [weak self] continuation in
            guard let self else { return }
            let (stream, streamContinuation) = AsyncStream<Bool>.makeStream()
            let id = UUID()
            self.lock.withLock { self.reachabilityListeners[id] = { streamContinuation.yield($0) } }
            streamContinuation.yield(WCSession.default.isReachable)
            await continuation.yieldAll(stream)   // parks until cancelled
            self.lock.withLock { _ = self.reachabilityListeners.removeValue(forKey: id) }
        }
    }

    /// `true` means handed to a transport that guarantees delivery — immediately over the live
    /// message channel, or queued as a user-info transfer that survives both apps being killed.
    func send(_ refuel: WatchRefuel) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            return false
        }
        let wire = WatchWire.dictionary(from: refuel)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(wire, replyHandler: nil, errorHandler: nil)
        } else {
            WCSession.default.transferUserInfo(wire)
        }
        return true
    }

    private func deliver(_ wire: [String: Any]) {
        let snapshot = WatchWire.snapshot(from: wire)
        let listeners = lock.withLock { Array(snapshotListeners.values) }
        for listener in listeners { listener(snapshot) }
    }
}

extension WatchSessionBox: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let listeners = lock.withLock { Array(reachabilityListeners.values) }
        for listener in listeners { listener(session.isReachable) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let listeners = lock.withLock { Array(reachabilityListeners.values) }
        for listener in listeners { listener(session.isReachable) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }
}

// MARK: - The ride's runtime shell

/// A workout session used for its runtime and nothing else.
///
/// Running one gives the watch app what a ride actually needs — it stays live in the
/// background, owns the wrist-raise ahead of Apple Maps, and its haptics fire with the screen
/// off. The session is **ended and discarded** at journey close: no builder, no samples, no
/// `finishWorkout`, so Health never hears about it and the rings stay honest.
///
/// A shared instance rather than a World-owned one because two doors lead here: the store's own
/// journey edges, and watchOS handing over the configuration when the *phone* launches the app
/// at journey start. Both must find the same session, and `begin` is idempotent for exactly
/// that collision.
final class RideRuntimeBox: NSObject, @unchecked Sendable {
    static let shared = RideRuntimeBox()

    private let lock = NSLock()
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?

    func begin() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard lock.withLock({ session == nil }) else { return }
        // Share authorization for the workout type is the session's entry fee, asked once on
        // first use. Nothing is ever written; denying it only costs the runtime perks.
        store.requestAuthorization(
            toShare: [HKObjectType.workoutType()], read: []
        ) { [weak self] granted, _ in
            guard granted, let self else { return }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .outdoor
            guard let fresh = try? HKWorkoutSession(
                healthStore: self.store, configuration: configuration
            ) else { return }
            let alreadyRunning = self.lock.withLock { () -> Bool in
                guard self.session == nil else { return true }
                self.session = fresh
                return false
            }
            guard !alreadyRunning else { return }
            fresh.startActivity(with: Date())
        }
    }

    func end() {
        let current = lock.withLock { () -> HKWorkoutSession? in
            defer { session = nil }
            return session
        }
        current?.end()
    }
}

// MARK: - The phone's wake-up call

/// watchOS hands the workout configuration here when the phone's `startWatchApp` launches us at
/// journey start — the app may be waking straight into the background, so the session opens
/// immediately rather than waiting for a snapshot to arrive and say the journey is on.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        RideRuntimeBox.shared.begin()
    }
}
