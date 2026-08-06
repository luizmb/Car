import AppDomain
import CoreBluetooth
import FP
import Foundation
import ReactiveConcurrency

// MARK: - Identifiers
//
// From the garage capture. The intercom advertises one custom service and pushes tag-prefixed
// binary on a notify characteristic; there is no standard Battery Service anywhere in its GATT.

private enum Cardo {
    static var service: CBUUID { CBUUID(string: "CD007F83-8B0B-11E6-AE22-56B6B6499611") }
    static var notify: CBUUID { CBUUID(string: "CD007F82-8B0B-11E6-AE22-56B6B6499611") }
    static let restoreID = "lu.ios.speed-jarvis.cardo"
}

// MARK: - Central

/// Reads the intercom's telemetry.
///
/// Connection is unavoidable: the advertisement's manufacturer data was byte-identical across every
/// packet in both garage sessions (`06a1d0dcbf`, 40 minutes apart), so it carries nothing. The
/// interesting values only exist on the notify characteristic.
///
/// Connecting here is safe in a way it was not for the CHIGEE. There, advertising *was* our presence
/// signal and bonding suppressed it; here presence comes from the audio route instead, so the
/// intercom's advertising habits do not matter. The vendor's own app also holds a BLE connection
/// while audio streams, so the device plainly tolerates it.
final class CardoCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var emit: (@Sendable (CardoEvent) -> Void)?
    private var log: (@Sendable (String) -> Void)?

    /// Idempotent, for the same reason `IndimateCentral.start` is: a second subscription would
    /// otherwise leak a scanning manager and orphan the live one.
    func start(
        log: @escaping @Sendable (String) -> Void,
        _ emit: @escaping @Sendable (CardoEvent) -> Void
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
                CBCentralManagerOptionRestoreIdentifierKey: Cardo.restoreID,
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

    private func note(_ line: String) { lock.withLock { log }?(line) }

    private func send(_ event: CardoEvent) { lock.withLock { emit }?(event) }

    private func scan(_ manager: CBCentralManager) {
        if let existing = manager.retrieveConnectedPeripherals(withServices: [Cardo.service]).first {
            attach(existing, on: manager)
            return
        }
        manager.scanForPeripherals(withServices: [Cardo.service], options: nil)
    }

    private func attach(_ device: CBPeripheral, on manager: CBCentralManager) {
        lock.withLock { peripheral = device }
        device.delegate = self
        manager.connect(device, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let device = restored.first else { return }
        lock.withLock { peripheral = device }
        device.delegate = self
        if device.state == .connected {
            send(.connected)
            device.discoverServices([Cardo.service])
        } else {
            central.connect(device, options: nil)
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
        peripheral.discoverServices([Cardo.service])
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
        scan(central)
    }

    // MARK: CBPeripheralDelegate

    /// Discovers **everything**, not just the one characteristic we already knew about.
    ///
    /// Read-only reconnaissance. The question is whether this unit exposes a *writable* channel
    /// alongside the notify one — nothing public documents its protocol, and until now the client
    /// asked for exactly one characteristic by UUID, so a whole control surface could have been
    /// sitting there unseen. The same allow-list-of-one hid things on Indimate.
    ///
    /// Nothing is written. Guessing opcodes at a helmet intercom's control channel is a different
    /// risk class from guessing at a connection — unknown writes can land on firmware-update or
    /// factory-reset paths, and this is the device every announcement comes out of.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let services = peripheral.services ?? []
        note("cardo-services count=\(services.count)")
        for service in services {
            note("cardo-service uuid=\(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        for characteristic in service.characteristics ?? [] {
            note("cardo-char svc=\(service.uuid.uuidString) uuid=\(characteristic.uuid.uuidString) props=\(propertyNames(characteristic.properties))")
            // Subscribe only to what pushes. Reading arbitrary characteristics is harmless, but
            // subscribing to the wrong thing produces a firehose we would then have to filter.
            if characteristic.uuid == Cardo.notify {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        characteristic.value.flatMap(parseCardoPayload).map(send)
    }
}

/// The properties a characteristic advertises, spelled out — `write` and `writeWithoutResponse` are
/// the ones this exercise exists to find.
private func propertyNames(_ p: CBCharacteristicProperties) -> String {
    var names: [String] = []
    if p.contains(.read) { names.append("read") }
    if p.contains(.write) { names.append("write") }
    if p.contains(.writeWithoutResponse) { names.append("writeNoResp") }
    if p.contains(.notify) { names.append("notify") }
    if p.contains(.indicate) { names.append("indicate") }
    if p.contains(.broadcast) { names.append("broadcast") }
    if p.contains(.authenticatedSignedWrites) { names.append("signedWrite") }
    if p.contains(.extendedProperties) { names.append("extended") }
    return names.isEmpty ? "none" : names.joined(separator: "|")
}

// MARK: - Cold publisher

func makeCardoStream(
    central: CardoCentral,
    log: @escaping @Sendable (String) -> Void
) -> Publisher<CardoEvent, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<CardoEvent>.makeStream()
        central.start(log: log) { streamContinuation.yield($0) }
        await continuation.yieldAll(stream)
        central.stop()
    }
}
