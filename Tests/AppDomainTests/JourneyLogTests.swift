import Foundation
import Testing
@testable import AppDomain

// The journey log is a file format meant to still parse in a year, after the Swift types producing
// it have been renamed several times. What makes that testable — and what the hand-written JSON it
// replaced could never do — is that the *writer and the reader are the same type*, so a round trip
// is a real assertion rather than a restatement of the encoder.

@Suite("Journey log format")
struct JourneyLogTests {

    private let t0 = Date(timeIntervalSince1970: 1_785_974_492)

    private var everyShape: [JourneyPayload] {
        [
            .journeyStart(.init(via: "ignition")),
            .journeyEnd(.init(seconds: 1_140, started: t0)),
            .fix(.init(lat: 51.869674, lon: -0.416538, mph: 24.3, course: 123.8, alt: 157.3, acc: 4.9)),
            .fix(.init(lat: 51.869674, lon: -0.416538, mph: nil, course: nil, alt: nil, acc: nil)),
            .road(.init(mph: 20, origin: "signed", label: "Ormsby Close", variable: false)),
            .road(.init(mph: nil, origin: "unattributed", label: nil, variable: false)),
            .camera(.init(type: "fixed", mph: 30, atMPH: 34)),
            .averageZone(.init(entered: true, mph: 50)),
            .indicator(.init(side: "left")),
            .indicator(.init(side: nil)),
            .tyre(.init(position: "front", psi: 32.5, celsius: 28, moving: true)),
            .weather(.init(celsius: 18, humidity: 60, kpa: 101.3, windMPS: 2, windDegrees: 180)),
            .barometer(.init(kpa: 99.783, relativeAltitude: 4.2)),
            .activity(.init(activity: "automotive", confidence: 2)),
            .device(.init(device: "ignition", connected: true)),
            .refuel(.init(litres: 12.5, price: 1.49, odometer: 26_031, brim: true)),
            .reserve(.init(km: 184.2))
        ]
    }

    private func line(_ payload: JourneyPayload) throws -> String {
        let data = try JourneyLog.encoder.encode(JourneyRecord(time: t0, payload: payload))
        return String(decoding: data, as: UTF8.self)
    }

    @Test("every shape survives a round trip")
    func roundTrip() throws {
        for payload in everyShape {
            let decoded = try JourneyLog.decoder.decode(
                JourneyRecord.self, from: Data(try line(payload).utf8)
            )
            #expect(decoded.payload == payload)
            #expect(decoded.time == t0)
        }
    }

    @Test("every record type is exercised")
    func exhaustive() {
        // If a new RecordType is added without a sample above, this fails rather than the format
        // quietly gaining an untested shape.
        let covered = Set(everyShape.map(\.type))
        #expect(covered == Set(RecordType.allCases))
    }

    @Test("the lines are flat, not nested under a payload key")
    func flatShape() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(try line(.fix(.init(lat: 51.869674, lon: -0.416538, mph: 24.3,
                                           course: 123.8, alt: 157.3, acc: 4.9))).utf8)
        ) as? [String: Any]
        #expect(object?["type"] as? String == "fix")
        #expect(object?["lat"] as? Double == 51.869674)
        #expect(object?["payload"] == nil, "the payload should be inline, not nested")
    }

    @Test("a whole file decodes as one polymorphic array")
    func wholeFile() throws {
        // The point of the container: join the lines with commas, wrap in brackets, decode once.
        let lines = try everyShape.map(line)
        let records = JourneyLog.records(fromLines: lines)
        #expect(records.count == everyShape.count)
        #expect(records.map(\.payload) == everyShape)
    }

    @Test("a truncated last line costs only that line")
    func truncatedTail() throws {
        // The app being killed mid-write is the normal ending, not an exception — the rider force-
        // quits from the task switcher. Losing the whole ride to a half-written line would be absurd.
        var lines = try everyShape.map(line)
        lines.append(String(lines[0].dropLast(12)))
        let records = JourneyLog.records(fromLines: lines)
        #expect(records.count == everyShape.count)
    }

    @Test("blank lines are ignored")
    func blankLines() throws {
        let lines = try [line(.reserve(.init(km: 1))), "", "   "]
        #expect(JourneyLog.records(fromLines: lines).count == 1)
    }

    @Test("absent values decode as absent, not as zero")
    func nullsRoundTrip() throws {
        // A missing speed is not a speed of zero, and a consumer must not have to guess which a
        // missing key meant.
        let decoded = try JourneyLog.decoder.decode(
            JourneyRecord.self,
            from: Data(try line(.fix(.init(lat: 1, lon: 2, mph: nil, course: nil, alt: nil, acc: nil))).utf8)
        )
        guard case let .fix(fix) = decoded.payload else { Issue.record("wrong shape"); return }
        #expect(fix.mph == nil)
        #expect(fix.acc == nil)
    }

    @Test("road names from OSM cannot break the line")
    func escaping() throws {
        // OSM text is not sanitised, and a quote in a road name must not corrupt the file.
        let payload = JourneyPayload.road(.init(mph: 30, origin: "signed",
                                                label: "St \"Mary\"s Lane", variable: false))
        let decoded = try JourneyLog.decoder.decode(
            JourneyRecord.self, from: Data(try line(payload).utf8)
        )
        #expect(decoded.payload == payload)
    }

    @Test("the discriminator values are the ones written down")
    func stableDiscriminators() {
        // These strings are the file format. A Swift rename must never move them.
        #expect(RecordType.journeyStart.rawValue == "journey-start")
        #expect(RecordType.averageZone.rawValue == "average-zone")
        #expect(RecordType.fix.rawValue == "fix")
    }
}
