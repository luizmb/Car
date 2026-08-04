import FP
import FPMacros
import Foundation

// MARK: - Cardo events

/// What the intercom pushes over its custom BLE characteristic.
///
/// The protocol is tag-prefixed binary, partially decoded from the garage capture:
/// `42 07 "PT EDGE"` is the device name, `43 0A "ES5259A282"` a serial. Nothing resembling a
/// standard Battery Service exists, so everything here is reverse-engineered.
@Prisms
public enum CardoEvent: Sendable, Equatable {
    case connected
    case disconnected
    /// Tag `0x51`, one byte. Observed as 75 and then 50 — which are exactly two of the five levels
    /// the intercom announces aloud (Full / 75 / 50 / 25 / Critical), making battery the leading
    /// reading. Volume is the rival explanation, since those are equally plausible volume steps and
    /// the two observations were only 13s apart. Displayed either way: both are worth knowing.
    case level(Int)
    /// Everything not yet decoded, kept so a spike session can work from real traffic rather than
    /// having to re-capture it.
    case raw(tag: Int, bytes: [Int])
}

// MARK: - Parsing

/// Decodes one notification from the Cardo's `CD007F82-…` characteristic.
public func parseCardoPayload(_ data: Data) -> CardoEvent? {
    let bytes = [UInt8](data)
    guard let tag = bytes.first else { return nil }

    if tag == 0x51, bytes.count >= 2 {
        return .level(Int(bytes[1]))
    }

    return .raw(tag: Int(tag), bytes: bytes.dropFirst().map(Int.init))
}
