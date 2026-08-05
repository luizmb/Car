import AppDomain
import CoreBluetooth
import FP
import Foundation
import ReactiveConcurrency

private enum Chigee {
    /// Standard HID. Generic — stray keyboards match it too — so sightings are also filtered by name.
    static var hid: CBUUID { CBUUID(string: "1812") }
    static let namePrefix = "CHIGEE"
    static let restoreID = "lu.ios.speed-jarvis.chigee"
}

// MARK: - Monitor

/// Ignition state, from the head unit's BLE **connection**.
///
/// Measured against Indimate's power-loss across a real ride: the link dropped **20s and 21s** after
/// the keys came out — the unit's own 10s shutdown plus the BLE supervision timeout — and
/// re-established *before* Indimate on restart. That is the signal.
///
/// Three earlier approaches failed, and it is worth recording why, because each looked reasonable:
///
/// - **Advertisements.** A bonded unit stops advertising. Across three rides it was seen exactly
///   once, at the first power-on before iOS re-bonded.
/// - **`retrieveConnectedPeripherals` polling.** Reported the unit connected for 13 minutes with the
///   ignition off — it evidently counts bonded-and-pending, not live.
/// - **A `Timer` driving that poll.** Never fired at all: `Timer.scheduledTimer` schedules on the
///   *current* run loop, and this starts inside a cold publisher's `Task` on a background thread
///   which has none. Fifty thousand log lines contained not one tick.
///
/// So: a **pending connect**, issued to a known identifier rather than waiting for an advertisement
/// that will never come, with `didConnect`/`didDisconnect` as the ignition edges.
final class ChigeeCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var emit: (@Sendable (ChigeeEvent) -> Void)?
    private var log: (@Sendable (String) -> Void)?
    private var knownIdentifier: UUID?
    private var onLearn: (@Sendable (UUID) -> Void)?

    func start(
        knownIdentifier: UUID?,
        emit: @escaping @Sendable (ChigeeEvent) -> Void,
        log: @escaping @Sendable (String) -> Void,
        onLearn: @escaping @Sendable (UUID) -> Void
    ) {
        let running = lock.withLock { () -> Bool in
            guard central == nil else { return true }
            self.emit = emit
            self.log = log
            self.knownIdentifier = knownIdentifier
            self.onLearn = onLearn
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
        lock.withLock { central = manager }
    }

    func stop() {
        let (manager, device) = lock.withLock { (central, peripheral) }
        manager?.stopScan()
        device.map { manager?.cancelPeripheralConnection($0) }
        lock.withLock {
            emit = nil
            log = nil
            peripheral = nil
            central = nil
        }
    }

    private func send(_ event: ChigeeEvent) { lock.withLock { emit }?(event) }

    private func note(_ event: String, _ fields: [String: Any] = [:]) {
        let parts = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }
        lock.withLock { log }?(([event] + parts).joined(separator: " "))
    }

    /// Adopts a peripheral and leaves a connect request pending indefinitely.
    ///
    /// The pending connect is the whole mechanism: iOS holds it open and links the moment the unit
    /// powers up, with no scanning and no battery cost. Re-armed after every disconnect, so one key
    /// cycle does not end the monitoring — which is exactly what stopped rides 2 and 3 dead.
    ///
    /// Presence is *never* inferred from `CBPeripheral.state` here, only from `didConnect`. A
    /// peripheral handed back by `retrieveConnectedPeripherals` can report itself connected while the
    /// ignition is off — that is the trap that once held the ignition on for thirteen minutes in an
    /// empty car park. `connect()` on an already-linked peripheral calls back promptly anyway, so
    /// there is nothing to gain from trusting the flag.
    private func arm(_ device: CBPeripheral, on manager: CBCentralManager) {
        lock.withLock { peripheral = device }
        note("chigee-arm", [
            "id": device.identifier.uuidString.prefix(8),
            "state": device.state.rawValue
        ])
        manager.connect(device, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restored.first.map { device in lock.withLock { peripheral = device } }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        note("chigee-ble-state", ["state": central.state.rawValue])
        guard central.state == .poweredOn else {
            send(.absent)
            return
        }

        // 1. Known from a previous run: arm a pending connect straight away, rather than waiting for
        //    an advertisement that a bonded unit will never send. Rides 2 and 3 waited for one all
        //    the way home and logged nothing at all.
        if let known = lock.withLock({ knownIdentifier }),
           let device = central.retrievePeripherals(withIdentifiers: [known]).first {
            arm(device, on: central)
            return
        }

        // 2. Bonded but not yet remembered — the upgrade path from the advertisement-only build.
        if let existing = central.retrieveConnectedPeripherals(withServices: [Chigee.hid])
            .first(where: { ($0.name ?? "").hasPrefix(Chigee.namePrefix) }) {
            lock.withLock { onLearn }?(existing.identifier)
            arm(existing, on: central)
            return
        }

        // 3. First run or a reinstall: scan, purely to learn the identifier once.
        central.scanForPeripherals(withServices: [Chigee.hid], options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? ""
        guard name.hasPrefix(Chigee.namePrefix) else { return }

        note("chigee-adv", [
            "name": name,
            "id": peripheral.identifier.uuidString.prefix(8),
            "rssi": RSSI.intValue
        ])
        // Remember it: a bonded unit will not advertise again, so this may be the only chance to
        // learn the identifier that lets future launches connect directly.
        lock.withLock { onLearn }?(peripheral.identifier)
        guard lock.withLock({ self.peripheral == nil }) else { return }
        central.stopScan()   // the identifier is all the scan was for
        arm(peripheral, on: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("chigee-connected", ["id": peripheral.identifier.uuidString.prefix(8)])
        send(.present)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let ns = error as NSError?
        note("chigee-connect-failed", ["domain": ns?.domain ?? "-", "code": ns?.code ?? 0])
        central.connect(peripheral, options: nil)   // stays pending
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        // Code 6 (connectionTimeout) is the unit vanishing — the ignition going off. Code 7 is the
        // peripheral disconnecting us deliberately. Both mean it is gone; the code is recorded
        // because the distinction may matter later.
        let ns = error as NSError?
        note("chigee-disconnected", ["domain": ns?.domain ?? "-", "code": ns?.code ?? 0])
        send(.absent)
        // Re-arm immediately — the keys may well be turned again in a minute.
        central.connect(peripheral, options: nil)
    }
}

// MARK: - Remembering the unit

/// The head unit's peripheral identifier, kept across launches.
///
/// Without it there is no way to reach a bonded unit at all: it stops advertising once paired, so a
/// scan will never see it again. The identifier is therefore learned from the one advertisement
/// burst at first pairing and written down immediately, because there may never be another.
///
/// A plain text file rather than `UserDefaults`, to sit alongside the fuel and trip logs where it can
/// be deleted from the Files app if the unit is ever replaced.
enum ChigeePeripheralStore {
    static let filename = "chigee-peripheral.txt"

    /// The identifier captured in the 2026-08-04 garage session.
    ///
    /// Seeded because the store is otherwise unfillable in practice, and two rides proved it. The
    /// only ways to learn an identifier are an advertisement or `retrieveConnectedPeripherals`; a
    /// bonded unit never advertises, and the retrieve call is filtered on the HID service, which iOS
    /// restricts for third-party apps. So the file stayed empty, no pending connect was ever armed,
    /// and both rides logged a single `chigee-ble-state` line and nothing else — a mechanism built
    /// correctly and never given the one value it needed.
    ///
    /// `CBPeripheral` identifiers are stable per phone, and this was recorded on the same phone, so
    /// it should still resolve. If the unit is ever replaced, delete `chigee-peripheral.txt` and the
    /// scan path will learn the new one.
    static let knownFromGarage = UUID(uuidString: "730B2168-081A-A4FB-76A4-6BF86A73B790")

    private static var url: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    static func load() -> UUID? {
        (try? String(contentsOf: url, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(UUID.init(uuidString:))
            ?? knownFromGarage
    }

    static func save(_ identifier: UUID) {
        try? identifier.uuidString.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Cold publisher

func makeChigeeStream(
    central: ChigeeCentral,
    knownIdentifier: UUID?,
    log: @escaping @Sendable (String) -> Void,
    onLearn: @escaping @Sendable (UUID) -> Void
) -> Publisher<ChigeeEvent, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<ChigeeEvent>.makeStream()
        central.start(
            knownIdentifier: knownIdentifier,
            emit: { streamContinuation.yield($0) },
            log: log,
            onLearn: onLearn
        )
        await continuation.yieldAll(stream)
        central.stop()
    }
}
