import AppDomain
import CoreBluetooth
import FP
import Foundation
import ReactiveConcurrency

// MARK: - Identifiers
//
// Reverse-engineered in a garage session on 2026-08-04 (see the spike analysis). The unit
// advertises a custom service and pushes ASCII state on a single notify characteristic.

private enum Indimate {
    // Computed rather than stored: `CBUUID` is a non-Sendable ObjC class, so a `static let` is a
    // shared-mutable-state error under strict concurrency. Construction is trivial.
    static var service: CBUUID { CBUUID(string: "E33DAA84-3121-403C-979E-ED641406F40C") }
    static var state: CBUUID { CBUUID(string: "A2D203AD-D749-42C1-9325-C6641AFCDB08") }
    /// Restoration key so iOS can relaunch us into the same central when the unit appears.
    static let restoreID = "lu.ios.speed-jarvis.indimate"
}

// MARK: - Central

/// Bridges CoreBluetooth's delegate callbacks into a stream of ``IndimateEvent``.
///
/// **It tracks the ignition, and the reconnect used to be our fault.** The long-held belief that
/// this unit is activity-triggered — invisible until a stalk is flicked — was wrong, or at least
/// stale: it predates the rider rewiring its power to the ignition. On the 2026-08-05 ride it
/// connected **14 seconds before the first indication** and dropped promptly on key-off, ~20s ahead
/// of CHIGEE every time.
///
/// What did look like activity-triggering was this: on disconnect the client called `scan()`, which
/// threw away the peripheral it already knew and started a fresh scan. Scanning is at the mercy of
/// the unit's advertising interval — slow when it has been idle, fast once something wakes it — and
/// of iOS's own scan duty cycling. So after a key cycle it took **84 seconds** to come back, and
/// indicating appeared to summon it because indicating wakes it into fast advertising.
///
/// It now re-arms a pending `connect()` on the known peripheral instead, which iOS services on the
/// first advertisement packet with no duty-cycle penalty. The identifier is persisted for the same
/// reason it is for CHIGEE: so a cold start can arm without scanning at all.
///
/// Scanning is filtered to the custom service UUID, which is what makes it legal in the
/// background — an unfiltered scan is foreground-only.
///
/// **The remembered identifier is a hint, never the only door (2026-11).** From 8 Sep the unit
/// stopped connecting on every ride while the Indimate's own app still reached it, with no app
/// change in between. The old flow armed a pending connect on the remembered identifier and then
/// never scanned again — so if iOS ever issued the unit a new identifier (a re-pair through the
/// vendor app, an OS update), the connect waited on a ghost forever and logged nothing. Now the
/// known identifier is armed *and* a service-filtered scan runs alongside it; an advertisement from
/// a different identifier replaces the ghost and is written down. Every step is logged as
/// `indimate-*`, like `chigee-*`, because the September silence was undiagnosable without it.
final class IndimateCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var emit: (@Sendable (IndimateEvent) -> Void)?
    private var log: (@Sendable (String) -> Void)?
    private var knownIdentifier: UUID?
    private var onLearn: (@Sendable (UUID) -> Void)?

    /// Idempotent. A second concurrent subscription would otherwise build a second
    /// `CBCentralManager` and overwrite the first's emit closure — leaking a scanning manager
    /// while orphaning the subscription that is actually being read. Supervision should keep only
    /// one channel per id, but that is the assumption that failed in the road-speed stream, so it
    /// is enforced here rather than relied upon.
    func start(
        knownIdentifier: UUID?,
        log: @escaping @Sendable (String) -> Void,
        onLearn: @escaping @Sendable (UUID) -> Void,
        _ emit: @escaping @Sendable (IndimateEvent) -> Void
    ) {
        lock.withLock {
            self.knownIdentifier = knownIdentifier
            self.onLearn = onLearn
            self.log = log
        }
        let alreadyRunning = lock.withLock { () -> Bool in
            guard central == nil else { return true }
            self.emit = emit
            return false
        }
        guard !alreadyRunning else { return }

        let manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Indimate.restoreID,
                // Without this, iOS pops its own "Turn On Bluetooth" alert. With state
                // restoration we can be relaunched in the background, so that alert could land
                // mid-ride. We report `.poweredOff` and speak it instead.
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

    private func send(_ event: IndimateEvent) {
        lock.withLock { emit }?(event)
    }

    private func note(_ event: String, _ fields: [String: Any] = [:]) {
        let parts = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        lock.withLock { log }?(([event] + parts).joined(separator: " "))
    }

    private func noteError(_ event: String, _ error: (any Error)?, _ fields: [String: Any] = [:]) {
        let ns = error as NSError?
        note(event, fields.merging(["domain": ns?.domain ?? "-", "code": ns?.code ?? 0]) { $1 })
    }

    /// Arms whatever we can reach, then scans regardless.
    ///
    /// 1. The peripheral already adopted this session, or the remembered identifier.
    /// 2. A link iOS already holds — the vendor app's, for one: iOS shares it, and the unit may not
    ///    advertise at all while connected.
    /// 3. A service-filtered scan, *always* — it is the only path that can notice the remembered
    ///    identifier has gone stale. Filtered, so it is legal in the background.
    private func search(_ manager: CBCentralManager) {
        let adopted = lock.withLock { peripheral }
        let known = lock.withLock { knownIdentifier }
        if let device = adopted {
            arm(device, on: manager, reason: "adopted")
        } else if let id = known {
            if let device = manager.retrievePeripherals(withIdentifiers: [id]).first {
                arm(device, on: manager, reason: "known")
            } else {
                note("indimate-known-unresolved", ["id": id.uuidString.prefix(8)])
            }
        } else {
            note("indimate-no-identifier")
        }

        let linked = manager.retrieveConnectedPeripherals(withServices: [Indimate.service])
        note("indimate-system-links", ["count": linked.count])
        if let existing = linked.first, existing.identifier != lock.withLock({ peripheral?.identifier }) {
            adopt(existing, on: manager, reason: "system-link")
        }

        note("indimate-scanning")
        manager.scanForPeripherals(withServices: [Indimate.service], options: nil)
    }

    /// Switches to a different peripheral than the one armed, cancelling the old pending connect.
    private func adopt(_ device: CBPeripheral, on manager: CBCentralManager, reason: String) {
        let previous = lock.withLock { peripheral }
        if let previous, previous.identifier != device.identifier {
            note("indimate-id-changed", [
                "from": previous.identifier.uuidString.prefix(8),
                "to": device.identifier.uuidString.prefix(8)
            ])
            manager.cancelPeripheralConnection(previous)
        }
        arm(device, on: manager, reason: reason)
    }

    private func arm(_ device: CBPeripheral, on manager: CBCentralManager, reason: String) {
        lock.withLock { peripheral = device }
        lock.withLock { onLearn }?(device.identifier)
        device.delegate = self
        note("indimate-arm", [
            "id": device.identifier.uuidString.prefix(8),
            "state": device.state.rawValue,
            "via": reason
        ])
        // A connect request with no timeout stays pending indefinitely, so the moment the unit
        // powers up iOS links it — no discovery latency on top of the hardware's own gating.
        manager.connect(device, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    /// Called before `centralManagerDidUpdateState` when iOS relaunches us into an existing
    /// central. Re-adopting the peripheral is not enough: our `CBCharacteristic` objects died with
    /// the old process, so notifications would never reach us again even though the subscription is
    /// still live on the peripheral's side. Re-discovering re-attaches the callbacks.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        note("indimate-restore", [
            "count": restored.count,
            "state": restored.first?.state.rawValue ?? -1
        ])
        guard let device = restored.first else { return }
        lock.withLock { peripheral = device }
        device.delegate = self

        if device.state == .connected {
            send(.connected)
            device.discoverServices([Indimate.service])
        } else {
            // Still pending from before we were killed — re-assert it so the connect survives.
            central.connect(device, options: nil)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        note("indimate-ble-state", ["state": central.state.rawValue])
        send(.availability(central.state.availability))
        guard central.state == .poweredOn else {
            send(.disconnected)
            return
        }
        search(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        note("indimate-adv", [
            "id": peripheral.identifier.uuidString.prefix(8),
            "name": peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "-",
            "rssi": RSSI.intValue
        ])
        central.stopScan()
        let armed = lock.withLock { self.peripheral }
        // The armed one advertising means its pending connect is about to land; anything else
        // means the remembered identifier is a ghost.
        guard armed?.identifier != peripheral.identifier else { return }
        adopt(peripheral, on: central, reason: "scan")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("indimate-connected", ["id": peripheral.identifier.uuidString.prefix(8)])
        central.stopScan()
        send(.connected)
        peripheral.discoverServices([Indimate.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        noteError("indimate-connect-failed", error, ["id": peripheral.identifier.uuidString.prefix(8)])
        search(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        noteError("indimate-disconnected", error, ["id": peripheral.identifier.uuidString.prefix(8)])
        send(.disconnected)
        // Re-arm immediately. The unit drops off whenever the ignition does, and the rider may
        // turn the keys several times in one outing.
        search(central)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let services = peripheral.services ?? []
        noteError("indimate-services", error, ["count": services.count])
        services
            .filter { $0.uuid == Indimate.service }
            .forEach { peripheral.discoverCharacteristics([Indimate.state], for: $0) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        let characteristics = service.characteristics ?? []
        noteError("indimate-chars", error, ["count": characteristics.count])
        characteristics
            .filter { $0.uuid == Indimate.state }
            .forEach { peripheral.setNotifyValue(true, for: $0) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        noteError("indimate-notify", error, ["on": characteristic.isNotifying])
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        characteristic.value
            .flatMap(parseIndimatePayload)
            .map(send)
    }
}

extension CBManagerAuthorization {
    var domain: BluetoothAuthorization {
        switch self {
        case .allowedAlways: .allowed
        case .denied:        .denied
        case .restricted:    .restricted
        case .notDetermined: .notDetermined
        @unknown default:    .notDetermined
        }
    }
}

private extension CBManagerState {
    /// `.resetting` is transient — the stack is coming back, so reporting a problem would make us
    /// announce a failure that resolves itself a moment later.
    var availability: BluetoothAvailability {
        switch self {
        case .poweredOn:    .ready
        case .poweredOff:   .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported:  .unsupported
        case .resetting, .unknown: .unknown
        @unknown default:   .unknown
        }
    }
}

// MARK: - Cold publisher

/// A **cold** `Publisher<IndimateEvent, Never>`: nothing is scanned or connected until someone
/// subscribes, and everything is torn down when they stop.
///
/// Coldness is not optional here. The store reconciles supervision after every state change, so
/// this factory is called many times a second; an eager version would spin up a fresh
/// `CBCentralManager` on that cadence — exactly the failure that silently killed the road-speed
/// stream before it was made cold.
/// - Parameter knownIdentifier: a closure, evaluated on subscribe rather than on description —
///   supervision calls this factory after every state change, and an eager read would be a disk hit
///   several times a second.
func makeIndimateStream(
    central: IndimateCentral,
    knownIdentifier: @escaping @Sendable () -> UUID?,
    log: @escaping @Sendable (String) -> Void,
    onLearn: @escaping @Sendable (UUID) -> Void
) -> Publisher<IndimateEvent, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<IndimateEvent>.makeStream()
        central.start(knownIdentifier: knownIdentifier(), log: log, onLearn: onLearn) {
            streamContinuation.yield($0)
        }
        await continuation.yieldAll(stream)   // parks until cancelled
        central.stop()
    }
}


// MARK: - Remembering the unit

/// The Indimate's peripheral identifier, kept across launches.
///
/// Same shape as ``ChigeePeripheralStore``, and for a milder version of the same reason: this unit
/// does still advertise, so a scan can find it — but only on its own schedule, which after an idle
/// period is slow enough to have cost 84 seconds on a real key cycle. A remembered identifier lets a
/// cold start arm a pending connect instead of waiting for one.
enum IndimatePeripheralStore {
    static let filename = "indimate-peripheral.txt"

    private static var url: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    static func load() -> UUID? {
        (try? String(contentsOf: url, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(UUID.init(uuidString:))
    }

    static func save(_ identifier: UUID) {
        try? identifier.uuidString.write(to: url, atomically: true, encoding: .utf8)
    }
}
