import FP
import FPMacros

// MARK: - Signals

/// How the head unit's presence was observed. Kept because the two differ in reliability and we do
/// not yet know which will prove trustworthy in practice — the overlay shows it so a real ride can
/// answer that without another garage session.
@Prisms
public enum ChigeeSignal: Sendable, Equatable {
    /// A BLE advertisement. Reliable while unbonded (1851 packets in one capture); after bonding it
    /// collapsed to a short burst at power-on only.
    case advertisement
    /// iOS itself holds a connection to the unit's HID service. Costs nothing to poll and does not
    /// depend on the unit still advertising — the likelier signal now that it is bonded.
    case systemConnection
}

// MARK: - Events

/// Whether the bike's ignition is on, inferred from the CarPlay head unit.
///
/// The unit is relayed by the ignition, so its radio dies with the keys. That makes it the one
/// dependable ignition signal available: it does **not** advertise with the ignition off even with
/// the phone right beside it (45s of silence observed, against a BLE advertising interval capped at
/// 10.24s — several missed windows, not a sampling artefact).
///
/// Timing measured across two sessions: **~9–17s** from key-on to first sighting, and a **~10s**
/// graceful shutdown on key-off (the unit runs a visible countdown, being battery-fed but
/// ignition-relayed) before its radio goes.
///
/// What this cannot tell you is whether the *engine* is running — only that the keys are on. For a
/// two-minute choked warm-up that distinction does not matter.
@Prisms
public enum ChigeeEvent: Sendable, Equatable {
    case present(via: ChigeeSignal)
    case absent
}
