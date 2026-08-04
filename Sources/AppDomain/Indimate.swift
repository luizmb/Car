import FP
import FPMacros
import Foundation

// MARK: - Side

/// Which indicator is engaged. Deliberately not `Optional<Side>` at the domain level — "neither"
/// is a real state the hardware reports, not an absence of information.
@Prisms
public enum Side: Sendable, Equatable, Hashable, CaseIterable {
    case left
    case right
}

// MARK: - Bluetooth availability

/// Whether Bluetooth can be used at all, independent of any particular device.
///
/// Deliberately a domain enum rather than `CBManagerState`, so the reason a feature is unavailable
/// can be reasoned about (and spoken) without dragging CoreBluetooth into the domain.
///
/// There is no "request Bluetooth permission" API on iOS — constructing a `CBCentralManager` *is*
/// the request. So permission handling is really a decision about *when* to construct one, which
/// makes this a state a feature has to hold rather than a call it can make.
@Prisms
public enum BluetoothAvailability: Sendable, Equatable {
    /// Not asked yet, or asked and still waiting for the first state callback.
    case unknown
    case ready
    case unauthorized
    case poweredOff
    /// No BLE hardware, or the OS refuses. Not recoverable, so nothing should retry.
    case unsupported
}

public extension BluetoothAvailability {
    /// What to say out loud when this changes. `nil` where speaking would be noise — the interface
    /// is audio-only, so a silent failure is indistinguishable from a working system.
    var spokenProblem: String? {
        switch self {
        case .ready, .unknown: nil
        case .unauthorized:    "Bluetooth denied. Indicators unavailable."
        case .poweredOff:      "Bluetooth is off. Indicators unavailable."
        case .unsupported:     "Bluetooth unavailable."
        }
    }
}

// MARK: - Indimate events

/// What the Indimate unit tells us. `indicator(nil)` means both lamps are off — which is distinct
/// from `disconnected`, where we simply have no idea.
@Prisms
public enum IndimateEvent: Sendable, Equatable {
    /// Reported by the central itself rather than the unit — whether we may scan at all.
    case availability(BluetoothAvailability)
    case connected
    case disconnected
    case indicator(Side?)
    /// Supply voltage in millivolts, reported periodically on the same characteristic.
    case voltage(Int)
    /// Firmware string, serial, and anything else the unit volunteers. Kept so the raw recorder
    /// can log it without the parser having to understand it.
    case info(String)
}

// MARK: - Payload parsing

/// Decodes one notification from Indimate's characteristic `A2D203AD-D749-42C1-9325-C6641AFCDB08`.
///
/// The unit speaks **ASCII**, not binary — reverse-engineered from a garage session on 2026-08-04
/// and matched against twelve hand-marked indicator events with no mismatches.
///
/// Four-digit payloads are `[left engaged][right engaged][left lamp][right lamp]`. The first two
/// digits say which stalk is on; the last two are the blink phase, flipping roughly twice a second
/// as the relay clicks. We only care about the first two: the app's tick loop runs at its own rate
/// and is deliberately not synchronised to the real lamps.
///
/// | Payload | Meaning              |
/// |---------|----------------------|
/// | `1010`  | left, lamp lit       |
/// | `1000`  | left, lamp dark      |
/// | `0101`  | right, lamp lit      |
/// | `0100`  | right, lamp dark     |
/// | `0000`  | neither              |
/// | `B3091` | 3091 mV              |
public func parseIndimatePayload(_ data: Data) -> IndimateEvent? {
    guard let text = String(data: data, encoding: .ascii)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
    else { return nil }

    if let voltage = text.first == "B" ? Int(text.dropFirst()) : nil {
        return .voltage(voltage)
    }

    if text.count == 4, text.allSatisfy({ $0 == "0" || $0 == "1" }) {
        let digits = Array(text)
        // Both engaged at once would be hazard lights; the unit has no wiring for it, and the
        // sound can only be one side, so left wins rather than inventing a third state.
        switch (digits[0], digits[1]) {
        case ("1", _): return .indicator(.left)
        case (_, "1"): return .indicator(.right)
        default:       return .indicator(nil)
        }
    }

    return .info(text)
}
