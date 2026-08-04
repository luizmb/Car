import FP
import FPMacros
import Foundation

// MARK: - Position

@Prisms
public enum TyrePosition: Sendable, Equatable, Hashable, CaseIterable {
    case front
    case rear
}

public extension TyrePosition {
    var shortLabel: String {
        switch self {
        case .front: "F"
        case .rear:  "R"
        }
    }

    var spokenLabel: String {
        switch self {
        case .front: "front"
        case .rear:  "rear"
        }
    }
}

// MARK: - Sensor identity

/// Ties a physical sensor to a wheel.
///
/// Keyed on the **serial from the payload**, not on `CBPeripheral.identifier`. The identifier is
/// assigned per app installation and would be invalidated by a reinstall; the serial is broadcast
/// by the sensor itself and is therefore stable forever. It also lets a second bike's sensors —
/// present in the same garage, on the same scan — be ignored by construction rather than by
/// guessing from signal strength, which measured anywhere from −99 to −59 dBm on one sensor.
public struct TyreSensor: Sendable, Equatable, Hashable {
    /// Lowercase hex of the three serial bytes, e.g. `"097d12"`.
    public let serial: String
    public let position: TyrePosition

    public init(serial: String, position: TyrePosition) {
        self.serial = serial
        self.position = position
    }
}

// MARK: - Thresholds

/// The pressure band for one wheel, as configured in the FOBO app.
public struct TyreThresholds: Sendable, Equatable {
    public let minimum: PSI
    public let recommended: PSI
    public let maximum: PSI

    public init(minimum: PSI, recommended: PSI, maximum: PSI) {
        self.minimum = minimum
        self.recommended = recommended
        self.maximum = maximum
    }
}

@Prisms
public enum TyreStatus: Sendable, Equatable {
    case ok
    case low
    case high
}

public func tyreStatus(_ pressure: PSI, thresholds: TyreThresholds) -> TyreStatus {
    if pressure < thresholds.minimum { return .low }
    if pressure > thresholds.maximum { return .high }
    return .ok
}

// MARK: - Telemetry

/// One decoded advertisement from a FOBO sensor.
public struct TyreTelemetry: Sendable, Equatable {
    public let serial: String
    public let pressure: KPa
    public let temperature: Celsius
    /// Byte 7, undecoded. The obvious reading — battery percentage — does not survive the
    /// evidence: the FOBO app showed one bike's pair full and the other's half, yet the values were
    /// 69/67 and 193/64, and 64 cannot be "half" while 67 is "full". Surfaced raw rather than
    /// guessed at, so it can be watched against the app's own battery indicator over time. It is
    /// the last undecoded field in the payload.
    public let statusByte: Int
    /// Bit 15 of the pressure field: the wheel is turning.
    ///
    /// A **hardware** motion signal, and more trustworthy than GPS for the purpose. A stationary
    /// GPS receiver random-walks, which silently inflates accumulated distance — and distance error
    /// feeds directly into fuel consumption. A bit that says the wheel is physically rotating gates
    /// that cleanly, and it also survives tunnels and urban canyons where GPS does not.
    public let isMoving: Bool

    public init(
        serial: String, pressure: KPa, temperature: Celsius,
        isMoving: Bool, statusByte: Int = 0
    ) {
        self.serial = serial
        self.pressure = pressure
        self.temperature = temperature
        self.isMoving = isMoving
        self.statusByte = statusByte
    }

    public var psi: PSI { Iso<KPa, PSI>.convert.get(pressure) }
}

// MARK: - Resolved reading

/// A broadcast that has been matched to one of *this* bike's wheels and graded against its band.
///
/// Resolving before the reading reaches the feature keeps the reducer pure: deciding which wheel a
/// serial belongs to needs configuration, and a reducer has no access to the environment.
public struct TyreReading: Sendable, Equatable {
    public let position: TyrePosition
    public let telemetry: TyreTelemetry
    public let status: TyreStatus

    public init(position: TyrePosition, telemetry: TyreTelemetry, status: TyreStatus) {
        self.position = position
        self.telemetry = telemetry
        self.status = status
    }
}

/// Matches a broadcast to a wheel, or discards it. Returns `nil` for the other bike's sensors,
/// which share the garage and the scan.
public func resolveTyreReading(
    _ telemetry: TyreTelemetry,
    sensors: [TyreSensor],
    thresholds: [TyrePosition: TyreThresholds]
) -> TyreReading? {
    guard let sensor = sensors.first(where: { $0.serial == telemetry.serial }) else { return nil }
    let status = thresholds[sensor.position]
        .map { tyreStatus(telemetry.psi, thresholds: $0) } ?? .ok
    return TyreReading(position: sensor.position, telemetry: telemetry, status: status)
}

// MARK: - Parsing

/// Decodes the ten-byte service-data payload FOBO sensors broadcast under UUID `0126`.
///
/// Reverse-engineered from a garage capture and verified against the FOBO app across **all four**
/// sensors on two bikes:
///
/// | payload | kPa | psi | app said |
/// |---|---|---|---|
/// | `…00 e5` | 229 | 33.21 | 33,2 |
/// | `…00 78` | 120 | 17.40 | 17,5 |
/// | `…00 94` | 148 | 21.47 | 21,5 |
/// | `…01 06` | 262 | 38.00 | 37,6 |
///
/// Three land within 0.1 psi; the fourth was compared against a reading an hour and three quarters
/// later, so a small bleed is expected rather than error.
///
/// ```
/// byte:  0  1  2 | 3  4  5 | 6    | 7 | 8  9
///        00 15 88| serial  | °C   | ? | kPa (big-endian)
/// ```
///
/// Byte 7 is **not** battery, despite looking like a percentage: the app showed one bike's pair
/// full and the other's half, yet the values were 69/67 and 193/64 — `64` and `67` cannot be
/// opposite states. Left undecoded rather than guessed at.
///
/// **No connection is needed**, which matters: these sensors run tiny cells and sleep between
/// broadcasts, so they are only ever seen passively.
public func parseTyreAdvertisement(_ data: Data) -> TyreTelemetry? {
    let bytes = [UInt8](data)
    // The three-byte header is the only thing distinguishing a real payload from a truncated or
    // unrelated one, so it is checked rather than assumed.
    guard bytes.count >= 10, bytes[0] == 0x00, bytes[1] == 0x15, bytes[2] == 0x88 else { return nil }

    let serial = bytes[3...5].map { String(format: "%02x", $0) }.joined()
    let raw = Int(bytes[8]) << 8 | Int(bytes[9])

    // Bit 15 is a motion flag, not pressure. Every garage capture was of a stationary bike, so it
    // read 0 and went unnoticed — the first ride reported 33,000 kPa (4,786 psi), which is `0x80E8`
    // with the flag set over a perfectly ordinary 232 kPa. Left unmasked it also trips a spoken
    // "pressure high" warning, which is worse than a wrong number on screen.
    let isMoving = raw & 0x8000 != 0
    let kilopascals = raw & 0x7FFF

    return TyreTelemetry(
        serial: serial,
        pressure: KPa(Double(kilopascals)),
        temperature: Celsius(Double(bytes[6])),
        isMoving: isMoving,
        statusByte: Int(bytes[7])
    )
}
