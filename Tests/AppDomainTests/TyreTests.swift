import Foundation
import Testing
@testable import AppDomain

// Every payload here was captured from the four real FOBO sensors and cross-checked against the
// FOBO app's own readings, so these assert observed behaviour rather than a guessed protocol.

@Suite("FOBO TPMS parsing")
struct TyreParsingTests {

    private func payload(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).compactMap {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            let j = hex.index(i, offsetBy: 2)
            return UInt8(hex[i..<j], radix: 16)
        })
    }

    /// serial, payload, expected kPa, expected psi, what the app showed
    private static let captured: [(String, String, Double, Double, Double)] = [
        ("097d12", "0015 8809 7d12 1e43 00e5", 229, 33.21, 33.2),   // Milky Way front
        ("09845f", "0015 8809 845f 1e45 0106", 262, 38.00, 37.6),   // Milky Way rear
        ("0aee60", "0015 880a ee60 19c1 0078", 120, 17.40, 17.5),   // Suzy front
        ("0aefae", "0015 880a efae 1740 0094", 148, 21.47, 21.5)    // Suzy rear
    ]

    @Test("pressure decodes to the value the FOBO app shows")
    func pressureMatchesApp() {
        for (serial, hex, kpa, psi, appPsi) in Self.captured {
            guard let t = parseTyreAdvertisement(payload(hex.replacingOccurrences(of: " ", with: ""))) else {
                Issue.record("\(serial) did not parse")
                return
            }
            #expect(t.serial == serial)
            #expect(t.pressure.rawValue == kpa)
            #expect(abs(t.psi.rawValue - psi) < 0.05)
            // Three of four land within 0.1 psi. The rear was compared against a reading taken an
            // hour and three quarters later, so a small bleed is expected — hence the wider bound.
            #expect(abs(t.psi.rawValue - appPsi) < 0.5)
        }
    }

    @Test("temperature is byte 6, in whole degrees C")
    func temperature() {
        // Milky Way had been running during the capture and read 30°C; Suzy sat cold at 25 and 23.
        let expected = ["097d12": 30.0, "09845f": 30.0, "0aee60": 25.0, "0aefae": 23.0]
        for (serial, hex, _, _, _) in Self.captured {
            let t = parseTyreAdvertisement(payload(hex.replacingOccurrences(of: " ", with: "")))
            #expect(t?.temperature.rawValue == expected[serial])
        }
    }

    @Test("bit 15 of the pressure field is motion, not pressure")
    func motionFlagIsMasked() {
        // Captured on the first real ride: 0x80E8. Unmasked it reads 33,000 kPa = 4,786 psi, which
        // is both nonsense and above the maximum, so it spoke a false "pressure high".
        guard let moving = parseTyreAdvertisement(payload("00158809" + "7d12" + "1e" + "43" + "80e8")) else {
            Issue.record("moving payload did not parse")
            return
        }
        #expect(moving.isMoving)
        #expect(moving.pressure.rawValue == 232)              // 0x00e8
        #expect(abs(moving.psi.rawValue - 33.65) < 0.05)      // a plausible warm tyre

        // The same sensor stationary, as captured in the garage.
        guard let parked = parseTyreAdvertisement(payload("001588097d121e4300e5")) else {
            Issue.record("parked payload did not parse")
            return
        }
        #expect(parked.isMoving == false)
        #expect(parked.pressure.rawValue == 229)
    }

    @Test("the flag never corrupts a legitimate high pressure byte")
    func flagDoesNotEatPressureBits() {
        // 0x8113 from the ride: flag set over 0x0113 = 275 kPa, whose high byte is a real 0x01.
        let t = parseTyreAdvertisement(payload("0015880984" + "5f" + "1e" + "45" + "8113"))
        #expect(t?.isMoving == true)
        #expect(t?.pressure.rawValue == 275)
        #expect(abs((t?.psi.rawValue ?? 0) - 39.89) < 0.05)
    }

    @Test("a payload without the FOBO header is rejected rather than misread")
    func rejectsForeignPayloads() {
        #expect(parseTyreAdvertisement(payload("00158809")) == nil)          // too short
        #expect(parseTyreAdvertisement(payload("0102030405060708090a")) == nil) // wrong header
        #expect(parseTyreAdvertisement(Data()) == nil)
    }
}

@Suite("Tyre thresholds")
struct TyreThresholdTests {

    // Milky Way's bands, as configured in the FOBO app.
    private let front = TyreThresholds(minimum: PSI(29), recommended: PSI(31), maximum: PSI(39))
    private let rear = TyreThresholds(minimum: PSI(33), recommended: PSI(36), maximum: PSI(45))

    @Test("real captured pressures are in band")
    func capturedAreOk() {
        #expect(tyreStatus(PSI(33.21), thresholds: front) == .ok)
        #expect(tyreStatus(PSI(38.00), thresholds: rear) == .ok)
    }

    @Test("below minimum is low, above maximum is high")
    func outOfBand() {
        #expect(tyreStatus(PSI(28.9), thresholds: front) == .low)
        #expect(tyreStatus(PSI(39.1), thresholds: front) == .high)
        #expect(tyreStatus(PSI(32.9), thresholds: rear) == .low)
        #expect(tyreStatus(PSI(45.1), thresholds: rear) == .high)
    }

    @Test("the other bike's soft tyres would warn against these bands")
    func suzyWouldWarn() {
        // 17.4 and 21.5 psi — genuinely low, and a useful sanity check that the bands bite.
        #expect(tyreStatus(PSI(17.40), thresholds: front) == .low)
        #expect(tyreStatus(PSI(21.47), thresholds: rear) == .low)
    }

    @Test("only this bike's serials resolve; the other bike is discarded")
    func resolvesOwnSensorsOnly() {
        let sensors = [
            TyreSensor(serial: "097d12", position: .front),
            TyreSensor(serial: "09845f", position: .rear)
        ]
        let bands: [TyrePosition: TyreThresholds] = [.front: front, .rear: rear]
        let mine = TyreTelemetry(serial: "097d12", pressure: KPa(229), temperature: Celsius(30), isMoving: false)
        let theirs = TyreTelemetry(serial: "0aee60", pressure: KPa(120), temperature: Celsius(25), isMoving: false)

        #expect(resolveTyreReading(mine, sensors: sensors, thresholds: bands)?.position == .front)
        #expect(resolveTyreReading(theirs, sensors: sensors, thresholds: bands) == nil)
    }
}
