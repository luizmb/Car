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
    private let log: @Sendable (String) -> Void
    // The link's last reported condition, so the log records changes rather than a line per
    // snapshot — a healthy ride writes a handful of lines, a broken one writes the reason.
    private var lastHealth: String?
    private var sent = 0

    init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
        super.init()
        guard WCSession.isSupported() else {
            log("watch-link unsupported on this device")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ snapshot: WatchSnapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            note(health: "inactive state=\(session.activationState.rawValue)")
            return
        }
        let wire = WatchWire.dictionary(from: snapshot)
        // Every failure here used to be swallowed — a wrist showing zeros with a phone that
        // believed it was sending, and no line anywhere saying otherwise. The conditions are
        // cheap to read and the log only speaks when one of them moves.
        var context = "ok"
        do {
            try session.updateApplicationContext(wire)
        } catch {
            context = error.localizedDescription
        }
        if session.isReachable {
            session.sendMessage(wire, replyHandler: nil) { [log] error in
                log("watch-link message failed: \(error.localizedDescription)")
            }
        }
        note(health: "paired=\(session.isPaired)"
            + " installed=\(session.isWatchAppInstalled)"
            + " reachable=\(session.isReachable)"
            + " context=\(context)")
    }

    /// One line per change of condition, plus a heartbeat so a pulled log proves sends happened
    /// at all — absence of the link's lines is itself the diagnosis then.
    private func note(health: String) {
        let line: String? = lock.withLock {
            sent += 1
            defer { lastHealth = health }
            return health != lastHealth || sent % 600 == 1 ? "watch-link \(health) sent=\(sent)" : nil
        }
        line.map(log)
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
    ) {
        log("watch-link activated state=\(activationState.rawValue)"
            + (error.map { " error=\($0.localizedDescription)" } ?? ""))
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        log("watch-link inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // A watch being switched deactivates the session; reactivating is what re-links the new one.
        log("watch-link deactivated, reactivating")
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo)
    }
}
