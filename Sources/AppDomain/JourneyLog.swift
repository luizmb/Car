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
}

// MARK: - Payloads

// One type per record shape. Each pins its `CodingKeys`, so renaming a Swift property cannot
// silently rewrite a year of records — which was the only real argument for hand-writing the JSON,
// and it costs one enum to keep.

public struct JourneyStartPayload: Codable, Sendable, Equatable {
    /// `ignition`, `indimate`, or `both` — which signal opened the journey.
    public let via: String
    public init(via: String) { self.via = via }
}

public struct JourneyEndPayload: Codable, Sendable, Equatable {
    public let seconds: Int
    /// Repeated here so one line is the whole journey, even if the file rotated at UTC midnight or
    /// the app was relaunched mid-ride.
    public let started: Date
    public init(seconds: Int, started: Date) {
        self.seconds = seconds
        self.started = started
    }
}

public struct FixPayload: Codable, Sendable, Equatable {
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

public struct RoadPayload: Codable, Sendable, Equatable {
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

public struct CameraPayload: Codable, Sendable, Equatable {
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

public struct AverageZonePayload: Codable, Sendable, Equatable {
    public let entered: Bool
    public let mph: Double?
    public init(entered: Bool, mph: Double?) {
        self.entered = entered
        self.mph = mph
    }
}

public struct IndicatorPayload: Codable, Sendable, Equatable {
    /// `left`, `right`, or absent for cancelled.
    public let side: String?
    public init(side: String?) { self.side = side }
}

public struct TyrePayload: Codable, Sendable, Equatable {
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

public struct WeatherPayload: Codable, Sendable, Equatable {
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

public struct BarometerPayload: Codable, Sendable, Equatable {
    public let kpa: Double
    public let relativeAltitude: Double
    public init(kpa: Double, relativeAltitude: Double) {
        self.kpa = kpa
        self.relativeAltitude = relativeAltitude
    }
}

public struct ActivityPayload: Codable, Sendable, Equatable {
    public let activity: String
    public let confidence: Int
    public init(activity: String, confidence: Int) {
        self.activity = activity
        self.confidence = confidence
    }
}

public struct DevicePayload: Codable, Sendable, Equatable {
    /// `indimate`, `ignition`, `cardo`.
    public let device: String
    public let connected: Bool
    public init(device: String, connected: Bool) {
        self.device = device
        self.connected = connected
    }
}

public struct RefuelPayload: Codable, Sendable, Equatable {
    public let litres: Double
    public let price: Double
    public let odometer: Double?
    public let brim: Bool

    public init(litres: Double, price: Double, odometer: Double?, brim: Bool) {
        self.litres = litres
        self.price = price
        self.odometer = odometer
        self.brim = brim
    }
}

public struct ReservePayload: Codable, Sendable, Equatable {
    public let km: Double
    public init(km: Double) { self.km = km }
}

// MARK: - The polymorphic payload

/// Every shape a record can take.
///
/// A closed set rather than an erased `any Codable`: the point is not to hide the type but to
/// enumerate the possibilities, so a consumer can switch exhaustively and the compiler will complain
/// when a new kind is added.
public enum JourneyPayload: Sendable, Equatable {
    case journeyStart(JourneyStartPayload)
    case journeyEnd(JourneyEndPayload)
    case fix(FixPayload)
    case road(RoadPayload)
    case camera(CameraPayload)
    case averageZone(AverageZonePayload)
    case indicator(IndicatorPayload)
    case tyre(TyrePayload)
    case weather(WeatherPayload)
    case barometer(BarometerPayload)
    case activity(ActivityPayload)
    case device(DevicePayload)
    case refuel(RefuelPayload)
    case reserve(ReservePayload)

    public var type: RecordType {
        switch self {
        case .journeyStart: .journeyStart
        case .journeyEnd: .journeyEnd
        case .fix: .fix
        case .road: .road
        case .camera: .camera
        case .averageZone: .averageZone
        case .indicator: .indicator
        case .tyre: .tyre
        case .weather: .weather
        case .barometer: .barometer
        case .activity: .activity
        case .device: .device
        case .refuel: .refuel
        case .reserve: .reserve
        }
    }
}

// MARK: - The container

/// One line of the journey log: a timestamp, a discriminator, and the payload — **flat**.
///
/// Flat rather than nested under a `payload` key. The payload is decoded from the *same* decoder as
/// the envelope, which is what lets `{"t":…,"type":"fix","lat":…}` round-trip while still being one
/// `Codable` type. Nesting would cost every consumer an extra hop for the life of the format and buy
/// nothing.
///
/// This is what makes the JSONL readable back: the file is a sequence of these, so
///
/// ```swift
/// let json = "[" + lines.joined(separator: ",") + "]"
/// let records = try decoder.decode([JourneyRecord].self, from: Data(json.utf8))
/// ```
///
/// works, and gives a heterogeneous array without any type erasure — `JourneyPayload` enumerates
/// the possibilities rather than hiding them.
public struct JourneyRecord: Codable, Sendable, Equatable {
    public let time: Date
    public let payload: JourneyPayload

    public init(time: Date, payload: JourneyPayload) {
        self.time = time
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case time = "t"
        case type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(Date.self, forKey: .time)
        let type = try container.decode(RecordType.self, forKey: .type)
        // Decoding the payload from the same decoder is what keeps the line flat.
        payload = switch type {
        case .journeyStart: .journeyStart(try JourneyStartPayload(from: decoder))
        case .journeyEnd: .journeyEnd(try JourneyEndPayload(from: decoder))
        case .fix: .fix(try FixPayload(from: decoder))
        case .road: .road(try RoadPayload(from: decoder))
        case .camera: .camera(try CameraPayload(from: decoder))
        case .averageZone: .averageZone(try AverageZonePayload(from: decoder))
        case .indicator: .indicator(try IndicatorPayload(from: decoder))
        case .tyre: .tyre(try TyrePayload(from: decoder))
        case .weather: .weather(try WeatherPayload(from: decoder))
        case .barometer: .barometer(try BarometerPayload(from: decoder))
        case .activity: .activity(try ActivityPayload(from: decoder))
        case .device: .device(try DevicePayload(from: decoder))
        case .refuel: .refuel(try RefuelPayload(from: decoder))
        case .reserve: .reserve(try ReservePayload(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encode(payload.type, forKey: .type)
        switch payload {
        case let .journeyStart(value): try value.encode(to: encoder)
        case let .journeyEnd(value): try value.encode(to: encoder)
        case let .fix(value): try value.encode(to: encoder)
        case let .road(value): try value.encode(to: encoder)
        case let .camera(value): try value.encode(to: encoder)
        case let .averageZone(value): try value.encode(to: encoder)
        case let .indicator(value): try value.encode(to: encoder)
        case let .tyre(value): try value.encode(to: encoder)
        case let .weather(value): try value.encode(to: encoder)
        case let .barometer(value): try value.encode(to: encoder)
        case let .activity(value): try value.encode(to: encoder)
        case let .device(value): try value.encode(to: encoder)
        case let .refuel(value): try value.encode(to: encoder)
        case let .reserve(value): try value.encode(to: encoder)
        }
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
