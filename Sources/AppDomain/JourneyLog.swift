import Foundation

// MARK: - Record type

/// The discriminator. Its raw values *are* the file format, so they are written out explicitly and
/// must never be changed to follow a Swift rename.
public enum RecordType: String, Codable, Sendable, CaseIterable {
    case journeyStart = "journey-start"
    case journeyEnd = "journey-end"
    case fix
    case road
    case camera
    case averageZone = "average-zone"
    case indicator
    case tyre
    case weather
    case barometer
    case activity
    case device
    case refuel
    case reserve
    case destination
}

// MARK: - Payload protocol

/// A record shape that knows its own discriminator and codes itself.
///
/// The point of this protocol is that ``JourneyRecord`` never learns how any payload is encoded. It
/// reads the `type`, looks up which shape that names, and delegates — so adding a record kind means
/// adding a type and one line to the lookup, not editing an encoder and a decoder in parallel.
///
/// `isEqual(to:)` exists because an existential cannot be `Equatable`; the default implementation
/// casts, so conforming types get it for free by being `Equatable`.
public protocol JourneyPayloadType: Sendable {
    static var recordType: RecordType { get }
    func isEqual(to other: any JourneyPayloadType) -> Bool
}

public extension JourneyPayloadType where Self: Equatable {
    func isEqual(to other: any JourneyPayloadType) -> Bool { (other as? Self) == self }
}

// MARK: - Payloads

// One type per record shape. Each pins its `CodingKeys`, so renaming a Swift property cannot
// silently rewrite a year of records — which was the only real argument for hand-writing the JSON,
// and it costs one enum to keep.

public struct JourneyStartPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .journeyStart

    /// `ignition`, `indimate`, or `both` — which signal opened the journey.
    public let via: String
    public init(via: String) { self.via = via }
}

public struct JourneyEndPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .journeyEnd

    public let seconds: Int
    /// Repeated here so one line is the whole journey, even if the file rotated at UTC midnight or
    /// the app was relaunched mid-ride.
    public let started: Date
    /// Metres ridden, accumulated fix by fix while the journey ran and written down **once**,
    /// here — deliberately denormalised, because recomputing it means walking every fix of the
    /// ride and the list screen exists to *not* do that. `nil` on records written before the
    /// column existed.
    public let metres: Double?

    public init(seconds: Int, started: Date, metres: Double? = nil) {
        self.seconds = seconds
        self.started = started
        self.metres = metres
    }
}

public struct FixPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .fix

    public let lat: Double
    public let lon: Double
    public let mph: Double?
    public let course: Double?
    public let alt: Double?
    public let acc: Double?

    public init(lat: Double, lon: Double, mph: Double?, course: Double?, alt: Double?, acc: Double?) {
        self.lat = lat
        self.lon = lon
        self.mph = mph
        self.course = course
        self.alt = alt
        self.acc = acc
    }
}

public struct RoadPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .road

    public let mph: Double?
    /// `signed`, `built-up`, `national`, `unattributed`.
    public let origin: String
    public let label: String?
    public let variable: Bool

    public init(mph: Double?, origin: String, label: String?, variable: Bool) {
        self.mph = mph
        self.origin = origin
        self.label = label
        self.variable = variable
    }
}

public struct CameraPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .camera

    /// `fixed`, `average`, `red-light`, `mobile`, `unknown`.
    public let type: String
    public let mph: Double?
    /// The speed you were doing when it was announced — the reason the record is worth keeping at all.
    public let atMPH: Double

    public init(type: String, mph: Double?, atMPH: Double) {
        self.type = type
        self.mph = mph
        self.atMPH = atMPH
    }
}

public struct AverageZonePayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .averageZone

    public let entered: Bool
    public let mph: Double?
    public init(entered: Bool, mph: Double?) {
        self.entered = entered
        self.mph = mph
    }
}

public struct IndicatorPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .indicator

    /// `left`, `right`, or absent for cancelled.
    public let side: String?
    public init(side: String?) { self.side = side }
}

public struct TyrePayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .tyre

    public let position: String
    public let psi: Double
    public let celsius: Double
    public let moving: Bool

    public init(position: String, psi: Double, celsius: Double, moving: Bool) {
        self.position = position
        self.psi = psi
        self.celsius = celsius
        self.moving = moving
    }
}

public struct WeatherPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .weather

    public let celsius: Double
    public let humidity: Double
    public let kpa: Double
    public let windMPS: Double
    public let windDegrees: Double

    public init(celsius: Double, humidity: Double, kpa: Double, windMPS: Double, windDegrees: Double) {
        self.celsius = celsius
        self.humidity = humidity
        self.kpa = kpa
        self.windMPS = windMPS
        self.windDegrees = windDegrees
    }
}

public struct BarometerPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .barometer

    public let kpa: Double
    public let relativeAltitude: Double
    public init(kpa: Double, relativeAltitude: Double) {
        self.kpa = kpa
        self.relativeAltitude = relativeAltitude
    }
}

public struct ActivityPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .activity

    public let activity: String
    public let confidence: Int
    public init(activity: String, confidence: Int) {
        self.activity = activity
        self.confidence = confidence
    }
}

public struct DevicePayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .device

    /// `indimate`, `ignition`, `cardo`.
    public let device: String
    public let connected: Bool
    public init(device: String, connected: Bool) {
        self.device = device
        self.connected = connected
    }
}

/// Where a route was started to. Written at GO, so the log carries the rider's destinations and
/// the search screen can offer them back — the places someone actually goes are the best
/// completion list there is.
public struct DestinationPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .destination

    public let name: String?
    public let lat: Double
    public let lon: Double

    public init(name: String?, lat: Double, lon: Double) {
        self.name = name
        self.lat = lat
        self.lon = lon
    }
}

public struct RefuelPayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .refuel

    public let litres: Double
    public let price: Double
    public let odometer: Double?
    public let brim: Bool
    /// The forecourt, where it could be resolved — what price comparison is grouped by.
    public let station: String?
    public let stationID: Int?

    public init(
        litres: Double, price: Double, odometer: Double?, brim: Bool,
        station: String? = nil, stationID: Int? = nil
    ) {
        self.litres = litres
        self.price = price
        self.odometer = odometer
        self.brim = brim
        self.station = station
        self.stationID = stationID
    }
}

public struct ReservePayload: JourneyPayloadType, Equatable {
    public static let recordType: RecordType = .reserve

    /// GPS kilometres since the last fill. Optional because a reserve switch can happen before the
    /// app has ever had a fix, and recording zero would read as "switched to reserve immediately
    /// after filling" — a claim that would quietly ruin the consumption maths.
    public let km: Double?
    public let odometer: Double?

    public init(km: Double?, odometer: Double?) {
        self.km = km
        self.odometer = odometer
    }
}

// MARK: - The container

/// One record of the journey timeline: a timestamp, a discriminator, and the payload.
///
/// A plain value — serialisation lives at the World boundary, where each payload maps to its own
/// table's typed columns. The discriminator comes from the payload's type, so the two cannot
/// disagree.
public struct JourneyRecord: Sendable {
    public let time: Date
    public let type: RecordType
    public let payload: any JourneyPayloadType

    public init<Payload: JourneyPayloadType>(time: Date, payload: Payload) {
        self.time = time
        type = Payload.recordType
        self.payload = payload
    }
}

extension JourneyRecord: Equatable {
    public static func == (lhs: JourneyRecord, rhs: JourneyRecord) -> Bool {
        lhs.time == rhs.time && lhs.type == rhs.type && lhs.payload.isEqual(to: rhs.payload)
    }
}
