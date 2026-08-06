import Foundation
import Testing
@testable import AppDomain

// The journey log is a *file format*, not a debug dump — it is meant to still parse in a year, after
// the Swift types producing it have been renamed several times. So the field names and shapes are
// asserted here rather than left to whatever `Codable` would derive.

@Suite("Journey log records")
struct JourneyLogTests {

    private let t0 = Date(timeIntervalSince1970: 1_785_974_492)

    private func parsed(_ event: JourneyEvent) -> [String: Any] {
        let data = Data(event.json.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @Test("every record is valid JSON on its own line")
    func validJSON() {
        // One object per line rather than an array: the app is killed mid-ride routinely, and an
        // array would leave an unclosed bracket and a file no parser will touch.
        let events: [JourneyEvent] = [
            .journeyStart(via: "ignition"),
            .journeyEnd(seconds: 1_140, started: t0),
            .fix(latitude: 51.869674, longitude: -0.416538, speedMPH: 24.3,
                 courseDegrees: 123.8, altitudeMetres: 157.3, accuracyMetres: 4.9),
            .road(limitMPH: 20, origin: "signed", label: "Ormsby Close", variable: false),
            .camera(kind: "fixed", limitMPH: 30, speedMPH: 34),
            .averageZone(entered: true, limitMPH: 50),
            .indicator(side: "left"),
            .tyre(position: "front", psi: 32.5, celsius: 28, moving: true),
            .weather(celsius: 18, humidity: 60, pressureKPa: 101.3, windMPS: 2, windDegrees: 180),
            .barometer(pressureKPa: 99.783, relativeAltitude: 4.2),
            .activity("automotive", confidence: 2),
            .device("ignition", connected: true),
            .refuel(litres: 12.5, price: 1.49, odometer: 26_031, brim: true),
            .reserve(kilometresFromGPS: 184.2)
        ]
        for event in events {
            let object = parsed(event)
            #expect(!object.isEmpty, "not valid JSON: \(event.json)")
            #expect(object["kind"] is String, "no kind in: \(event.json)")
        }
    }

    @Test("a fix keeps the fields the map and the fuel model need")
    func fixShape() {
        let object = parsed(.fix(latitude: 51.869674, longitude: -0.416538, speedMPH: 24.3,
                                 courseDegrees: 123.8, altitudeMetres: 157.3, accuracyMetres: 4.9))
        #expect(object["kind"] as? String == "fix")
        // Six decimal places is about 10 cm — enough for a track, and seventeen is noise.
        #expect(object["lat"] as? Double == 51.869674)
        #expect(object["mph"] as? Double == 24.3)
    }

    @Test("absent values are null, not omitted and not zero")
    func nullsArePresent() {
        // A missing speed is not a speed of zero, and a consumer should not have to guess which of
        // those a missing key meant.
        let object = parsed(.fix(latitude: 1, longitude: 2, speedMPH: nil, courseDegrees: nil,
                                 altitudeMetres: nil, accuracyMetres: nil))
        #expect(object["mph"] is NSNull)
        #expect(object["course"] is NSNull)
    }

    @Test("the end record carries the start time, so one line is the whole journey")
    func endCarriesStart() {
        let object = parsed(.journeyEnd(seconds: 1_140, started: t0))
        #expect(object["seconds"] as? Int == 1_140)
        #expect(object["started"] as? String == "2026-08-06T00:01:32Z")
    }

    @Test("text is escaped rather than breaking the line")
    func escaping() {
        // Road names come from OSM and are not sanitised. A quote in one must not corrupt the file.
        let object = parsed(.road(limitMPH: 30, origin: "signed", label: "St \"Mary\"s Lane", variable: false))
        #expect(object["label"] as? String == "St \"Mary\"s Lane")
    }
}
