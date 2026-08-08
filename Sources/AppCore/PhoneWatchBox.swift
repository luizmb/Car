import AppDomain
import Foundation
import ReactiveConcurrency
import WatchConnectivity

/// The phone's half of the wrist link.
///
/// Everything WatchConnectivity lives inside this box; nothing past `World` knows the framework
/// exists. Outbound, the latest snapshot goes out two ways at once: `updateApplicationContext`
/// (latest-only, delivered whenever the watch wakes — the resting pulse) and `sendMessage` when
/// the counterpart is live (the 1 Hz riding feed). Inbound, refuel commands arrive as messages or
/// queued user-info transfers — the second is what makes a fill logged with the phone asleep in a
/// jacket pocket still land — and surface as one stream of domain values.
///
/// `@unchecked Sendable` for the same reason the other delegate boxes are: WCSession calls back on
/// its own queue, and the lock is the discipline.
final class PhoneWatchBox: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: (WatchRefuel) -> Void] = [:]

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ snapshot: WatchSnapshot) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let wire = WatchWire.dictionary(from: snapshot)
        // The context write can throw only for non-property-list content, which the wire codec
        // rules out by construction; a failure here is not actionable and must not be fatal.
        try? WCSession.default.updateApplicationContext(wire)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(wire, replyHandler: nil, errorHandler: nil)
        }
    }

    /// Refuel asks from the wrist, as a cold stream — subscribing registers a listener; the
    /// publisher parks until cancelled, exactly as the audio-route bridge does.
    var refuels: Publisher<WatchRefuel, Never> {
        Publisher { [weak self] continuation in
            guard let self else { return }
            let (stream, streamContinuation) = AsyncStream<WatchRefuel>.makeStream()
            let id = UUID()
            self.lock.withLock { self.listeners[id] = { streamContinuation.yield($0) } }
            await continuation.yieldAll(stream)   // parks until cancelled
            self.lock.withLock { _ = self.listeners.removeValue(forKey: id) }
        }
    }

    private func deliver(_ wire: [String: Any]) {
        guard let refuel = WatchWire.refuel(from: wire) else { return }
        let current = lock.withLock { Array(listeners.values) }
        for listener in current { listener(refuel) }
    }
}

extension PhoneWatchBox: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A watch being switched deactivates the session; reactivating is what re-links the new one.
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo)
    }
}
