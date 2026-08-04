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
    /// Raw observation sink, written straight to the ride log rather than through the store.
    /// Diagnostic volume (every advertisement, every poll) has no business driving supervision
    /// reconciliation, and the previous ride proved the store only records *transitions* — which is
    /// exactly the data that cannot distinguish "signal absent" from "never checked".
    private var log: (@Sendable (String) -> Void)?
    private var probe: CBPeripheral?
    private var pollCount = 0
    private var lastSeen: Date?
    private var reportedPresent = false
    private var hasReported = false
    private var startedAt: Date?
    private var timer: Timer?

    func start(
        _ emit: @escaping @Sendable (ChigeeEvent) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        let running = lock.withLock { () -> Bool in
            guard central == nil else { return true }
            self.emit = emit
            self.log = log
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

    private func note(_ event: String, _ fields: [String: Any] = [:]) {
        let parts = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }
        lock.withLock { log }?(([event] + parts).joined(separator: " "))
    }

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
        let n = lock.withLock { () -> Int in pollCount += 1; return pollCount }

        if let manager, manager.state == .poweredOn {
            let connected = manager.retrieveConnectedPeripherals(withServices: [Chigee.hid])
            // Every peripheral, not just the first match — a second CHIGEE-named entry would be the
            // handlebar remote, which is one of the live explanations for presence never expiring.
            let names = connected.map { "\($0.name ?? "?")|\($0.identifier.uuidString.prefix(8))|\($0.state.rawValue)" }
            let probeState = lock.withLock { probe?.state.rawValue } ?? -1
            // Logged on *every* tick, even when empty. Last time the poll left no trace at all, so
            // "the timer stopped" and "the device kept being seen" were indistinguishable.
            note("chigee-poll", [
                "n": n,
                "found": names.isEmpty ? "-" : names.joined(separator: ";"),
                "probeState": probeState
            ])
            if connected.contains(where: { ($0.name ?? "").hasPrefix(Chigee.namePrefix) }) {
                sighted(via: .systemConnection)
                return
            }
        } else {
            note("chigee-poll", ["n": n, "found": "-", "ble": "off"])
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
        note("chigee-ble-state", ["state": central.state.rawValue])
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Chigee.hid], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("chigee-probe-connected", ["id": peripheral.identifier.uuidString.prefix(8)])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let ns = error as NSError?
        note("chigee-probe-failed", [
            "id": peripheral.identifier.uuidString.prefix(8),
            "domain": ns?.domain ?? "-", "code": ns?.code ?? 0
        ])
        central.connect(peripheral, options: nil)   // stays pending; re-arm
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        // The error code is the discriminator: 6 (connectionTimeout) means the peripheral vanished,
        // 7 means it disconnected us deliberately — the difference between a power cut and
        // something else taking the link.
        let ns = error as NSError?
        note("chigee-probe-disconnected", [
            "id": peripheral.identifier.uuidString.prefix(8),
            "domain": ns?.domain ?? "-", "code": ns?.code ?? 0
        ])
        central.connect(peripheral, options: nil)   // re-arm so a reconnect is visible too
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

        // Logged unconditionally, including while parked. Whether this unit advertises with the
        // ignition off is the single observation that separates "ignition-gated" from
        // "battery-alive", and it has never been sampled for longer than 54 seconds.
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString).joined(separator: ",")
        note("chigee-adv", [
            "name": name,
            "id": peripheral.identifier.uuidString.prefix(8),
            "rssi": RSSI.intValue,
            "svc": services.isEmpty ? "-" : services,
            "connectable": advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false
        ])
        sighted(via: .advertisement)

        // A liveness probe, kept deliberately separate from presence. A pending connect reports
        // when the link *actually* dies, which polling demonstrably does not — and in the garage it
        // dropped 22s and 19s after key-off. Whether that was the ignition or the remote
        // interfering is precisely what this ride decides.
        if lock.withLock({ probe == nil }) {
            lock.withLock { probe = peripheral }
            note("chigee-probe-connecting", ["id": peripheral.identifier.uuidString.prefix(8)])
            central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - Cold publisher

func makeChigeeStream(
    central: ChigeeCentral,
    log: @escaping @Sendable (String) -> Void
) -> Publisher<ChigeeEvent, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<ChigeeEvent>.makeStream()
        central.start({ streamContinuation.yield($0) }, log: log)
        await continuation.yieldAll(stream)
        central.stop()
    }
}
