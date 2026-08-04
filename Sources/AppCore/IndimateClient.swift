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
/// **The unit is activity-triggered, not power-triggered.** It is wired so the indicator stalks
/// are its trigger, so it stays invisible — no advertising at all — until an indicator is used,
/// even with the engine running. Scanning therefore has to stay armed for the whole journey
/// rather than giving up after an initial discovery window; there is nothing to find until the
/// rider flicks a stalk, which may be five minutes in.
///
/// Scanning is filtered to the custom service UUID, which is what makes it legal in the
/// background — an unfiltered scan is foreground-only.
final class IndimateCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var emit: (@Sendable (IndimateEvent) -> Void)?

    /// Idempotent. A second concurrent subscription would otherwise build a second
    /// `CBCentralManager` and overwrite the first's emit closure — leaking a scanning manager
    /// while orphaning the subscription that is actually being read. Supervision should keep only
    /// one channel per id, but that is the assumption that failed in the road-speed stream, so it
    /// is enforced here rather than relied upon.
    func start(_ emit: @escaping @Sendable (IndimateEvent) -> Void) {
        let alreadyRunning = lock.withLock { () -> Bool in
            guard central == nil else { return true }
            self.emit = emit
            return false
        }
        guard !alreadyRunning else { return }

        let manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Indimate.restoreID]
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
        device.delegate = self
        // A connect request with no timeout stays pending indefinitely, so the moment the unit
        // powers up on first indicator use, iOS links it — no discovery latency on top of the
        // hardware's own gating.
        manager.connect(device, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restored.first.map { device in
            lock.withLock { peripheral = device }
            device.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
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

// MARK: - Cold publisher

/// A **cold** `Publisher<IndimateEvent, Never>`: nothing is scanned or connected until someone
/// subscribes, and everything is torn down when they stop.
///
/// Coldness is not optional here. The store reconciles supervision after every state change, so
/// this factory is called many times a second; an eager version would spin up a fresh
/// `CBCentralManager` on that cadence — exactly the failure that silently killed the road-speed
/// stream before it was made cold.
func makeIndimateStream(central: IndimateCentral) -> Publisher<IndimateEvent, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<IndimateEvent>.makeStream()
        central.start { streamContinuation.yield($0) }
        await continuation.yieldAll(stream)   // parks until cancelled
        central.stop()
    }
}
