import Foundation
import UIKit

/// Caches device battery state.
///
/// `UIDevice` is main-actor isolated, but `World`'s closures are `@Sendable` and may run anywhere.
/// Rather than hop to the main actor on every read — inside a Flight Plan composition, no less — the
/// value is cached and read from a lock.
///
/// **Event-driven, not polled.** This used to sample on a sixty-second `Timer`, which was wrong in
/// three ways at once: it never fired for the first minute after launch, it kept firing forever
/// because nothing ever invalidated it, and it did work on a schedule when iOS already volunteers
/// the answer. `batteryLevelDidChangeNotification` arrives on every 1% step, so the cache is now
/// both fresher and cheaper — and there is no timer to leak, or to keep running while the app sits
/// in a pocket doing nothing.
///
/// Deliberately *not* `Publisher.timer(every:clock:)` either. A cadence that exists only to refresh
/// a cache is not domain timing and has nothing to inject or test; the right answer was to delete
/// the schedule rather than to abstract it.
final class DeviceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _batteryLevel: Double?
    private var observers: [NSObjectProtocol] = []

    init() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            UIDevice.current.isBatteryMonitoringEnabled = true
            sample()
            // Both notifications matter: level for the percentage, state for the moment a charger is
            // connected, which moves the level immediately.
            let names: [Notification.Name] = [
                UIDevice.batteryLevelDidChangeNotification,
                UIDevice.batteryStateDidChangeNotification
            ]
            let tokens = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sample() }
                }
            }
            lock.withLock { observers = tokens }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    @MainActor
    private func sample() {
        let level = UIDevice.current.batteryLevel
        // -1 means "unavailable", which is emphatically not "empty".
        lock.withLock { _batteryLevel = level < 0 ? nil : Double(level) }
    }

    var batteryLevel: Double? { lock.withLock { _batteryLevel } }
}
