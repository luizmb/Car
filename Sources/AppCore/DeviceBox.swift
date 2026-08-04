import Foundation
import UIKit

/// Caches device battery state.
///
/// `UIDevice` is main-actor isolated, but `World`'s closures are `@Sendable` and may run anywhere.
/// Rather than hop to the main actor on every read — inside a Flight Plan composition, no less —
/// the value is sampled on a slow timer and read from a lock. Battery percentage changes over
/// minutes; a sixty-second-old reading is indistinguishable from a live one.
final class DeviceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _batteryLevel: Double?

    init() {
        Task { @MainActor [weak self] in
            UIDevice.current.isBatteryMonitoringEnabled = true
            self?.sample()
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in self?.sample() }
            }
        }
    }

    @MainActor
    private func sample() {
        let level = UIDevice.current.batteryLevel
        // -1 means "unavailable", which is emphatically not "empty".
        lock.withLock { _batteryLevel = level < 0 ? nil : Double(level) }
    }

    var batteryLevel: Double? { lock.withLock { _batteryLevel } }
}
