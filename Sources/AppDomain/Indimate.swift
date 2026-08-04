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

// MARK: - Bluetooth authorization

/// Whether the user has been asked for Bluetooth yet, and what they said.
///
/// Distinct from ``BluetoothAvailability``: that describes whether the radio can be *used* right
/// now, this describes whether a **system dialog is still pending**. The distinction is what makes
/// background relaunch work — once this is anything but `notDetermined`, constructing a central can
/// no longer put a prompt on screen, so it is safe to do at launch with no UI involved.
@Prisms
public enum BluetoothAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case allowed
}

public extension BluetoothAuthorization {
    /// True once asking can no longer produce a dialog — so ordering against the location prompt
    /// stops mattering and the central may be built immediately, including on a background launch.
    var isDecided: Bool { self != .notDetermined }
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
    /// Supply voltage, reported periodically on the same characteristic. Carries the raw text
    /// because the encoding is not yet settled — see ``BatteryReading``.
    case voltage(BatteryReading)
    /// Firmware string, serial, and anything else the unit volunteers. Kept so the raw recorder
    /// can log it without the parser having to understand it.
    case info(String)
}

// MARK: - Battery reading

/// A `B####` payload, kept in every interpretation we cannot yet rule out.
///
/// The encoding is genuinely undetermined. Every sample so far is digits-only, which is consistent
/// with *both* readings, so neither can be eliminated:
///
/// - **Hex** — `0x3091` = 12433 mV = 12.43 V. Needs no scale factor at all, and all four captured
///   samples land in 12.34–12.55 V, textbook resting lead-acid. A 12 V system lives in
///   `0x3000...0x3FFF`, so engine-off naturally keeps the digits numeric.
/// - **Decimal** — 3091 mV is not a 12 V battery directly, but ×4 gives 12.36 V, equally plausible
///   for a divider.
///
/// **The engine settles it.** Running, a bike sits near 13.5–14.4 V; as hex that is `0x34BC`–`0x3840`,
/// so a *letter* would appear in the payload. Decimal has no way to produce one. Until then both are
/// carried and the raw text is preserved, so nothing is lost to a guess — and, importantly, a reading
/// containing `A`–`F` no longer fails to parse and vanish exactly when it becomes interesting.
public struct BatteryReading: Sendable, Equatable {
    /// The payload with its `B` prefix stripped, e.g. `"3091"` or `"34BC"`.
    public let raw: String
    /// Interpreted as hexadecimal millivolts — the stronger hypothesis.
    public let hexMillivolts: Int?
    /// Interpreted as decimal millivolts, unscaled.
    public let decimalMillivolts: Int?

    public init(raw: String) {
        self.raw = raw
        hexMillivolts = Int(raw, radix: 16)
        decimalMillivolts = Int(raw, radix: 10)
    }

    /// True once the payload contains a hex-only digit, which decimal cannot produce — the
    /// observation that decides the encoding.
    public var provesHex: Bool {
        raw.uppercased().contains { "ABCDEF".contains($0) }
    }
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

    // Accept any `B`-prefixed payload, not just decimal-parsable ones: once the engine runs the
    // value may contain hex letters, and rejecting those would drop the reading precisely when it
    // starts mattering.
    if text.first == "B", text.count > 1 {
        let body = String(text.dropFirst())
        let reading = BatteryReading(raw: body)
        if reading.hexMillivolts != nil || reading.decimalMillivolts != nil {
            return .voltage(reading)
        }
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
