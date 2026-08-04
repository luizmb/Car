import AppDomain
import CoreBluetooth
import FP
import Foundation
import ReactiveConcurrency

private enum Fobo {
    /// Advertised service UUID — what the background scan filters on.
    static var service: CBUUID { CBUUID(string: "FAF0") }
    /// The key the telemetry is published under in the advertisement's service data.
    static var telemetry: CBUUID { CBUUID(string: "0126") }
    static let restoreID = "lu.ios.speed-jarvis.tyres"
}

/// Watches for FOBO TPMS advertisements. **Never connects.**
///
/// Connecting would be actively harmful here: the sensors run coin cells and sleep between
/// broadcasts, and everything we need is already in the advertisement. Passive scanning also means
/// a second bike's sensors in the same garage cost nothing — they are decoded and then dropped by
/// serial, in the feature.
///
/// Cold, like every other `World` factory: the scan starts on subscribe and stops when it ends.
final class TyreCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var emit: (@Sendable (TyreTelemetry) -> Void)?

    func start(_ emit: @escaping @Sendable (TyreTelemetry) -> Void) {
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
                CBCentralManagerOptionRestoreIdentifierKey: Fobo.restoreID,
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
        )
        lock.withLock { central = manager }
    }

    func stop() {
        let manager = lock.withLock { central }
        manager?.stopScan()
        lock.withLock {
            emit = nil
            central = nil
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Nothing to restore: no connections are ever made.
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Fobo.service], options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
            let payload = serviceData[Fobo.telemetry],
            let telemetry = parseTyreAdvertisement(payload)
        else { return }
        lock.withLock { emit }?(telemetry)
    }
}

func makeTyreStream(central: TyreCentral) -> Publisher<TyreTelemetry, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<TyreTelemetry>.makeStream()
        central.start { streamContinuation.yield($0) }
        await continuation.yieldAll(stream)
        central.stop()
    }
}
