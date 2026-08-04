import AppDomain
import CoreBluetooth
import FP
import Foundation
import ReactiveConcurrency

// MARK: - Identifiers

private enum Chigee {
    /// Standard HID. Generic — stray keyboards match it too — so sightings are also filtered by
    /// name, which is why the name match matters rather than being cosmetic.
    static var hid: CBUUID { CBUUID(string: "1812") }
    static let namePrefix = "CHIGEE"
    static let restoreID = "lu.ios.speed-jarvis.chigee"

    /// How long without a sighting before ignition is called off.
    ///
    /// The unit's own shutdown is ~10s (a visible countdown, since it is battery-fed but
    /// ignition-relayed). Background scanning is throttled on top of that, and advertising after
    /// bonding is a short burst rather than continuous — so the window has to absorb a long quiet
    /// stretch from a unit that is still very much powered. 45s errs toward a late "off" rather
    /// than a flapping one, which is the cheaper mistake: a spurious off would end a journey
    /// mid-ride.
    static let absenceGrace: TimeInterval = 45
}

// MARK: - Monitor

/// Watches for the head unit **without ever connecting to it**.
///
/// Connecting is precisely what broke the signal last time: after one connection the unit bonded
/// and its advertising collapsed from 1851 packets in a capture to a 1–2 packet burst at power-on.
/// Our own connections were also unstable — three drops in two minutes — most likely contending
/// with iOS over the HID link. So this only ever observes:
///
/// 1. **Advertisements**, filtered to the HID service so the scan stays legal in the background.
/// 2. **`retrieveConnectedPeripherals`**, which reports what *iOS* has connected. Free to poll, and
///    unaffected by the unit having stopped advertising — the likelier of the two now that it is
///    bonded.
///
/// Either sighting means ignition on. Absence is only declared after a grace period, because a
/// silent unit is not necessarily a dead one.
final class ChigeeCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var emit: (@Sendable (ChigeeEvent) -> Void)?
    private var lastSeen: Date?
    private var reportedPresent = false
    private var hasReported = false
    private var startedAt: Date?
    private var timer: Timer?

    func start(_ emit: @escaping @Sendable (ChigeeEvent) -> Void) {
        let running = lock.withLock { () -> Bool in
            guard central == nil else { return true }
            self.emit = emit
            return false
        }
        guard !running else { return }

        let manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Chigee.restoreID,
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
        )
        let poll = Timer.scheduledTimer(
            withTimeInterval: 2, repeats: true
        ) { [weak self] _ in self?.tick() }

        lock.withLock {
            central = manager
            timer = poll
            startedAt = Date()
        }
    }

    func stop() {
        let manager = lock.withLock { central }
        manager?.stopScan()
        lock.withLock {
            timer?.invalidate()
            timer = nil
            emit = nil
            central = nil
            lastSeen = nil
            reportedPresent = false
        }
    }

    // MARK: Presence bookkeeping

    private func sighted(via signal: ChigeeSignal) {
        let shouldReport = lock.withLock { () -> Bool in
            lastSeen = Date()
            guard !reportedPresent else { return false }
            reportedPresent = true
            hasReported = true
            return true
        }
        if shouldReport { lock.withLock { emit }?(.present(via: signal)) }
    }

    /// Polls the system's own connections, then expires presence once the grace period lapses.
    private func tick() {
        let manager = lock.withLock { central }
        if let manager, manager.state == .poweredOn {
            let connected = manager.retrieveConnectedPeripherals(withServices: [Chigee.hid])
            if connected.contains(where: { ($0.name ?? "").hasPrefix(Chigee.namePrefix) }) {
                sighted(via: .systemConnection)
                return
            }
        }

        let shouldReportAbsent = lock.withLock { () -> Bool in
            let now = Date()
            // Presence went stale.
            if reportedPresent, let seen = lastSeen, now.timeIntervalSince(seen) > Chigee.absenceGrace {
                reportedPresent = false
                hasReported = true
                return true
            }
            // Never saw anything at all since starting. Without this the UI sits on "Unknown"
            // forever whenever the app opens away from the bike — which is most of the time.
            // Silence for the whole grace period is a real answer: the ignition is off.
            if !hasReported, let started = startedAt,
               now.timeIntervalSince(started) > Chigee.absenceGrace {
                hasReported = true
                return true
            }
            return false
        }
        if shouldReportAbsent { lock.withLock { emit }?(.absent) }
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Nothing to re-adopt: we never connect, so there is no peripheral state to restore.
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Chigee.hid], options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Deliberately no `stopScan` and no `connect`. The scan stays armed for the whole session
        // because a bonded unit only emits a brief burst at power-on, and connecting is what
        // suppressed that advertising in the first place.
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? ""
        guard name.hasPrefix(Chigee.namePrefix) else { return }
        sighted(via: .advertisement)
    }
}

// MARK: - Cold publisher

func makeChigeeStream(central: ChigeeCentral) -> Publisher<ChigeeEvent, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<ChigeeEvent>.makeStream()
        central.start { streamContinuation.yield($0) }
        await continuation.yieldAll(stream)
        central.stop()
    }
}
