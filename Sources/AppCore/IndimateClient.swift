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
final class IndimateCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var emit: (@Sendable (IndimateEvent) -> Void)?
    private var knownIdentifier: UUID?
    private var onLearn: (@Sendable (UUID) -> Void)?

    /// Idempotent. A second concurrent subscription would otherwise build a second
    /// `CBCentralManager` and overwrite the first's emit closure — leaking a scanning manager
    /// while orphaning the subscription that is actually being read. Supervision should keep only
    /// one channel per id, but that is the assumption that failed in the road-speed stream, so it
    /// is enforced here rather than relied upon.
    func start(
        knownIdentifier: UUID?,
        onLearn: @escaping @Sendable (UUID) -> Void,
        _ emit: @escaping @Sendable (IndimateEvent) -> Void
    ) {
        lock.withLock {
            self.knownIdentifier = knownIdentifier
            self.onLearn = onLearn
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
            peripheral = nil
            central = nil
        }
    }

    private func send(_ event: IndimateEvent) {
        lock.withLock { emit }?(event)
    }

    private func scan(_ manager: CBCentralManager) {
        // A peripheral we already know: arm a pending connect straight at it. No scan, no waiting on
        // its advertising interval, and it survives the unit being powered down and back up.
        if let known = lock.withLock({ peripheral ?? knownIdentifier.flatMap {
            manager.retrievePeripherals(withIdentifiers: [$0]).first
        } }) {
            attach(known, on: manager)
            return
        }
        // Already-connected peripherals never appear in a scan, so ask for them explicitly —
        // this is what recovers the unit after a background relaunch.
        if let existing = manager.retrieveConnectedPeripherals(withServices: [Indimate.service]).first {
            attach(existing, on: manager)
            return
        }
        manager.scanForPeripherals(withServices: [Indimate.service], options: nil)
    }

    private func attach(_ device: CBPeripheral, on manager: CBCentralManager) {
        lock.withLock { peripheral = device }
        lock.withLock { onLearn }?(device.identifier)
        device.delegate = self
        // A connect request with no timeout stays pending indefinitely, so the moment the unit
        // powers up on first indicator use, iOS links it — no discovery latency on top of the
        // hardware's own gating.
        manager.connect(device, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    /// Called before `centralManagerDidUpdateState` when iOS relaunches us into an existing
    /// central. Re-adopting the peripheral is not enough: our `CBCharacteristic` objects died with
    /// the old process, so notifications would never reach us again even though the subscription is
    /// still live on the peripheral's side. Re-discovering re-attaches the callbacks.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
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
        send(.availability(central.state.availability))
        guard central.state == .poweredOn else {
            send(.disconnected)
            return
        }
        scan(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        attach(peripheral, on: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        send(.connected)
        peripheral.discoverServices([Indimate.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        scan(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        send(.disconnected)
        // Re-arm immediately. The unit drops off whenever the ignition does, and the rider may
        // turn the keys several times in one outing.
        scan(central)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        (peripheral.services ?? [])
            .filter { $0.uuid == Indimate.service }
            .forEach { peripheral.discoverCharacteristics([Indimate.state], for: $0) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        (service.characteristics ?? [])
            .filter { $0.uuid == Indimate.state }
            .forEach { peripheral.setNotifyValue(true, for: $0) }
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
    onLearn: @escaping @Sendable (UUID) -> Void
) -> Publisher<IndimateEvent, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<IndimateEvent>.makeStream()
        central.start(knownIdentifier: knownIdentifier(), onLearn: onLearn) {
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
