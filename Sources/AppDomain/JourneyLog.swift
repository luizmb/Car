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
public protocol JourneyPayloadType: Codable, Sendable {
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
    public init(seconds: Int, started: Date) {
        self.seconds = seconds
        self.started = started
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

    enum CodingKeys: String, CodingKey {
        case type = "cameraType"   // `type` is taken by the discriminator on the same flat object
        case mph, atMPH
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

// MARK: - Kind lookup

public extension RecordType {
    /// Which shape this kind names. The one switch in the whole format, and the only thing that has
    /// to change when a record kind is added.
    var payloadType: any JourneyPayloadType.Type {
        switch self {
        case .journeyStart: JourneyStartPayload.self
        case .journeyEnd: JourneyEndPayload.self
        case .fix: FixPayload.self
        case .road: RoadPayload.self
        case .camera: CameraPayload.self
        case .averageZone: AverageZonePayload.self
        case .indicator: IndicatorPayload.self
        case .tyre: TyrePayload.self
        case .weather: WeatherPayload.self
        case .barometer: BarometerPayload.self
        case .activity: ActivityPayload.self
        case .device: DevicePayload.self
        case .destination: DestinationPayload.self
        case .refuel: RefuelPayload.self
        case .reserve: ReservePayload.self
        }
    }
}

// MARK: - The container

/// One line of the journey log: a timestamp, a discriminator, and the payload — **flat**.
///
/// The container codes three things and delegates the rest: it writes `t` and `type`, then asks the
/// payload to encode itself into the *same* encoder, which is what keeps the line flat rather than
/// nesting under a `payload` key. Decoding is the mirror — read `type`, look up the shape, hand the
/// decoder over.
///
/// So there is no growing switch here. `RecordType.payloadType` is the only place that enumerates
/// the shapes, and every payload owns its own coding.
///
/// Reading a whole file back:
///
/// ```swift
/// let json = "[" + lines.joined(separator: ",") + "]"
/// let records = try JourneyLog.decoder.decode([JourneyRecord].self, from: Data(json.utf8))
/// ```
public struct JourneyRecord: Codable, Sendable {
    public let time: Date
    public let type: RecordType
    public let payload: any JourneyPayloadType

    /// The discriminator comes from the payload's own type, so the two cannot disagree.
    public init<Payload: JourneyPayloadType>(time: Date, payload: Payload) {
        self.time = time
        type = Payload.recordType
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case time = "t"
        case type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(Date.self, forKey: .time)
        let kind = try container.decode(RecordType.self, forKey: .type)
        type = kind
        payload = try kind.payloadType.init(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encode(type, forKey: .type)
        try payload.encode(to: encoder)
    }
}

extension JourneyRecord: Equatable {
    public static func == (lhs: JourneyRecord, rhs: JourneyRecord) -> Bool {
        lhs.time == rhs.time && lhs.type == rhs.type && lhs.payload.isEqual(to: rhs.payload)
    }
}

// MARK: - Coders

/// ISO-8601 dates, matching the `t` field every line already carried, and stable across locales.
public enum JourneyLog {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A record's time in the same ISO-8601 form its `t` field carries — for storage that lifts
    /// the timestamp out beside the JSON, where the two must never disagree about format.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// The whole file, from its lines.
    ///
    /// Joining and wrapping is exactly as intended — and it is safe precisely *because* each line is
    /// a complete object, so a file truncated by the app being killed loses only its last line. That
    /// last line is dropped here rather than failing the whole parse, which matters because the app
    /// being killed mid-write is the normal ending, not an exception.
    public static func records(fromLines lines: [String]) -> [JourneyRecord] {
        let usable = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return [] }

        if let all = try? decoder.decode(
            [JourneyRecord].self,
            from: Data(("[" + usable.joined(separator: ",") + "]").utf8)
        ) { return all }

        // One bad line — almost always a half-written last one — should not cost the ride.
        return usable.compactMap { try? decoder.decode(JourneyRecord.self, from: Data($0.utf8)) }
    }
}
