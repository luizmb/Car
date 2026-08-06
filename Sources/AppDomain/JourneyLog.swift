import Foundation

/// A record worth keeping.
///
/// The ride log has so far been `String(describing:)` of every dispatched action — brilliant for a
/// first ride, useless as a record. It changes shape whenever a Swift type does, it needs a bespoke
/// parser, and 42% of it is raw motion samples nobody will ever read.
///
/// This is the other half of the split: a typed, stable record of the things that will still matter
/// in a year, written **only while a journey is active**. The firehose continues into its own debug
/// file, where it costs nothing but disk.
///
/// One object per line rather than a JSON array, deliberately. The app is killed mid-ride routinely
/// — by iOS, or by the rider at the end — and an array would leave an unclosed bracket and a file
/// that no parser will touch. Every line here stands alone, so a truncated file loses the last line
/// and nothing else.
public enum JourneyEvent: Sendable, Equatable {
    case journeyStart(via: String)
    case journeyEnd(seconds: Int, started: Date)
    case fix(latitude: Double, longitude: Double, speedMPH: Double?, courseDegrees: Double?,
             altitudeMetres: Double?, accuracyMetres: Double?)
    case road(limitMPH: Double?, origin: String, label: String?, variable: Bool)
    case camera(kind: String, limitMPH: Double?, speedMPH: Double)
    case averageZone(entered: Bool, limitMPH: Double?)
    case indicator(side: String?)
    case tyre(position: String, psi: Double, celsius: Double, moving: Bool)
    case weather(celsius: Double, humidity: Double, pressureKPa: Double,
                 windMPS: Double, windDegrees: Double)
    case barometer(pressureKPa: Double, relativeAltitude: Double)
    case activity(String, confidence: Int)
    case device(String, connected: Bool)
    case refuel(litres: Double, price: Double, odometer: Double?, brim: Bool)
    case reserve(kilometresFromGPS: Double)
}

// MARK: - Encoding

public extension JourneyEvent {
    /// The record as JSON, ready to be written as one line.
    ///
    /// Hand-rolled rather than `Codable`: the output is a *file format* that outlives the types
    /// producing it, so the field names should be chosen and visible here, not derived from whatever
    /// a property happens to be called this month. Renaming a Swift property must not silently
    /// rewrite a year of records.
    var json: String {
        switch self {
        case let .journeyStart(via):
            object(["kind": .string("journey-start"), "via": .string(via)])
        case let .journeyEnd(seconds, started):
            object([
                "kind": .string("journey-end"),
                "seconds": .int(seconds),
                "started": .string(utcTimestamp(started))
            ])
        case let .fix(lat, lon, speed, course, altitude, accuracy):
            object([
                "kind": .string("fix"),
                "lat": .double(lat, places: 6),
                "lon": .double(lon, places: 6),
                "mph": speed.map { .double($0, places: 1) } ?? .null,
                "course": course.map { .double($0, places: 1) } ?? .null,
                "alt": altitude.map { .double($0, places: 1) } ?? .null,
                "acc": accuracy.map { .double($0, places: 1) } ?? .null
            ])
        case let .road(limit, origin, label, variable):
            object([
                "kind": .string("road"),
                "mph": limit.map { .double($0, places: 0) } ?? .null,
                "origin": .string(origin),
                "label": label.map(JSONValue.string) ?? .null,
                "variable": .bool(variable)
            ])
        case let .camera(kind, limit, speed):
            object([
                "kind": .string("camera"),
                "type": .string(kind),
                "mph": limit.map { .double($0, places: 0) } ?? .null,
                "atMPH": .double(speed, places: 1)
            ])
        case let .averageZone(entered, limit):
            object([
                "kind": .string("average-zone"),
                "entered": .bool(entered),
                "mph": limit.map { .double($0, places: 0) } ?? .null
            ])
        case let .indicator(side):
            object(["kind": .string("indicator"), "side": side.map(JSONValue.string) ?? .null])
        case let .tyre(position, psi, celsius, moving):
            object([
                "kind": .string("tyre"),
                "position": .string(position),
                "psi": .double(psi, places: 1),
                "c": .double(celsius, places: 0),
                "moving": .bool(moving)
            ])
        case let .weather(celsius, humidity, pressure, wind, windDegrees):
            object([
                "kind": .string("weather"),
                "c": .double(celsius, places: 1),
                "humidity": .double(humidity, places: 0),
                "kpa": .double(pressure, places: 2),
                "windMPS": .double(wind, places: 1),
                "windDeg": .double(windDegrees, places: 0)
            ])
        case let .barometer(pressure, relative):
            object([
                "kind": .string("barometer"),
                "kpa": .double(pressure, places: 3),
                "relAlt": .double(relative, places: 2)
            ])
        case let .activity(name, confidence):
            object([
                "kind": .string("activity"),
                "activity": .string(name),
                "confidence": .int(confidence)
            ])
        case let .device(name, connected):
            object([
                "kind": .string("device"),
                "device": .string(name),
                "connected": .bool(connected)
            ])
        case let .refuel(litres, price, odometer, brim):
            object([
                "kind": .string("refuel"),
                "litres": .double(litres, places: 2),
                "price": .double(price, places: 2),
                "odometer": odometer.map { .double($0, places: 0) } ?? .null,
                "brim": .bool(brim)
            ])
        case let .reserve(kilometres):
            object(["kind": .string("reserve"), "km": .double(kilometres, places: 2)])
        }
    }
}

// MARK: - A very small JSON writer

/// Enough JSON to write one flat object, and no more.
///
/// `JSONSerialization` would do this, but it returns `Data?` and sorts nothing predictably, and
/// `JSONEncoder` would tie the file format to the property names. Rounding at the point of writing
/// also keeps the file readable: six decimal places of latitude is ~10 cm, and seventeen is noise.
enum JSONValue {
    case string(String)
    case double(Double, places: Int)
    case int(Int)
    case bool(Bool)
    case null

    var literal: String {
        switch self {
        case let .string(text): "\"\(escape(text))\""
        case let .double(value, places): String(format: "%.\(places)f", value)
        case let .int(value): String(value)
        case let .bool(value): value ? "true" : "false"
        case .null: "null"
        }
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

/// Keys are emitted in a fixed order — `kind` first — so the file diffs and reads sensibly rather
/// than depending on dictionary iteration order.
func object(_ fields: [String: JSONValue]) -> String {
    let ordered = ["kind"] + fields.keys.filter { $0 != "kind" }.sorted()
    let body = ordered.compactMap { key in
        fields[key].map { "\"\(key)\":\($0.literal)" }
    }
    return "{" + body.joined(separator: ",") + "}"
}
