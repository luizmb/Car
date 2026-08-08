import Foundation
import Testing
@testable import AppDomain

// The scanner's arithmetic: a pump proves itself by its own numbers agreeing, an odometer by its
// shape, and nothing is believed from a single frame.

private func at(_ text: String, _ x: Double = 0.5, _ y: Double = 0.5) -> RecognizedText {
    RecognizedText(text: text, x: x, y: y)
}

@Suite("Reading the pump")
struct PumpReadingTests {
    @Test("The self-consistent triple is found among the noise")
    func findsTheTriple() {
        // A real forecourt frame: prices board, VAT line, and the display's three numbers.
        let frame = ["UNLEADED", "£13.72", "9.43", "1.455", "VAT No 123456", "0800 123456"].map { at($0) }
        #expect(pumpSighting(fromRecognized: frame)?.reading
                == PumpReading(litres: 9.43, pricePerLitre: 1.455))
    }

    /// Pumps show £1.849 as 184.9 or 18.49 as often as 1.849 — the product test alone decides
    /// which scale was on the glass.
    @Test("Pence and decipound price displays resolve to pounds", arguments: ["184.9", "18.49", "1.849"])
    func priceScales(display: String) {
        let frame = ["£17.44", "9.43", display].map { at($0) }
        #expect(pumpSighting(fromRecognized: frame)?.reading
                == PumpReading(litres: 9.43, pricePerLitre: 1.849))
    }

    /// A display listing several grades offers several plausible prices; only the dispensed
    /// grade's price multiplies out — and the token beside it names the grade.
    @Test("Side-by-side grade prices: the arithmetic picks one and its neighbour names it")
    func sideBySideGrades() {
        let frame = [
            at("E10", 0.2, 0.8), at("149.9", 0.35, 0.8),
            at("E5", 0.2, 0.6), at("155.9", 0.35, 0.6),
            at("B7", 0.2, 0.4), at("169.9", 0.35, 0.4),
            at("9.43", 0.5, 0.2), at("£14.70", 0.8, 0.2)
        ]
        let sighting = pumpSighting(fromRecognized: frame)
        #expect(sighting?.reading == PumpReading(litres: 9.43, pricePerLitre: 1.559))
        #expect(sighting?.grade == "E5")
    }

    @Test("A grade badge across the frame does not own the price")
    func distantGradeIsNobodys() {
        let frame = [
            at("E10", 0.05, 0.95),
            at("1.455", 0.9, 0.1), at("9.43", 0.5, 0.1), at("£13.72", 0.7, 0.1)
        ]
        #expect(pumpSighting(fromRecognized: frame)?.grade == nil)
    }

    @Test("Without the product agreeing, nothing is believed")
    func rejectsInconsistency() {
        #expect(pumpSighting(fromRecognized: ["9.43", "1.455", "99.99"].map { at($0) }) == nil)
        #expect(pumpSighting(fromRecognized: ["9.43", "1.455"].map { at($0) }) == nil)
        #expect(pumpSighting(fromRecognized: []) == nil)
    }

    @Test("Comma displays and currency signs read the same")
    func toleratesDialects() {
        let frame = ["13,72", "9,43", "1,455"].map { at($0) }
        #expect(pumpSighting(fromRecognized: frame)?.reading
                == PumpReading(litres: 9.43, pricePerLitre: 1.455))
    }
}

@Suite("Reading the odometer")
struct OdometerReadingTests {
    @Test("The mileage-shaped number wins, and the trip meter loses")
    func picksTheOdometer() {
        #expect(odometerReading(fromRecognized: ["19432", "231.4", "14:32", "0"].map { at($0) }) == 19_432)
    }

    @Test("Nothing mileage-shaped, nothing believed")
    func rejectsNonMileage() {
        #expect(odometerReading(fromRecognized: ["14:32", "88"].map { at($0) }) == nil)
        #expect(odometerReading(fromRecognized: ["19432.55"].map { at($0) }) == nil)   // odometers have no cents
    }
}

@Suite("Scan stability")
struct ScanStreakTests {
    @Test("Agreement grows the streak; disagreement starts over; a blind frame keeps it")
    func streakRules() {
        var streak = scanStreak(nil, saw: 100.0)
        #expect(streak?.count == 1)
        streak = scanStreak(streak, saw: 100.0)
        #expect(streak?.count == 2)
        streak = scanStreak(streak, saw: nil)      // OCR flicker must not reset the streak
        #expect(streak?.count == 2)
        streak = scanStreak(streak, saw: 200.0)    // a different value is a fresh start
        #expect(streak?.value == 200.0)
        #expect(streak?.count == 1)
    }
}
