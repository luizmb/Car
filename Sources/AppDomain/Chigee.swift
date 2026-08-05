import FP
import FPMacros

// MARK: - Events

/// Whether the bike's ignition is on, inferred from the CarPlay head unit.
///
/// The unit is relayed by the ignition, so its radio dies with the keys. That makes it the one
/// dependable ignition signal available. What it cannot tell you is whether the *engine* is running,
/// only that the keys are on — for a two-minute choked warm-up that distinction does not matter.
///
/// **Presence means our own BLE connection to the unit, and nothing else.** Two other readings were
/// tried on real rides and both misreported:
///
/// - **Advertisements.** Reliable while unbonded — 1851 packets in one garage capture — but a
///   bonded unit stops advertising, and across three rides exactly one burst was ever seen.
/// - **The system-level connection.** Reported present for thirteen minutes with the ignition off,
///   because `retrieveConnectedPeripherals` counts bonded-and-pending rather than live.
///
/// The connection, measured against Indimate's power-loss: it dropped **20s and 21s** after the keys
/// came out — the unit's own ~10s shutdown countdown plus the BLE supervision timeout — and
/// re-established *before* Indimate on restart. Key-on to first sighting runs **~9–17s**.
@Prisms
public enum ChigeeEvent: Sendable, Equatable {
    case present
    case absent
}
