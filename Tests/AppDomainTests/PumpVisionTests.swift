import Foundation
import Testing
@testable import AppDomain

// The scanner's arithmetic: a pump proves itself by its own numbers agreeing, an odometer by its
// shape, and nothing is believed from a single frame.

@Suite("Reading the pump")
struct PumpReadingTests {
    @Test("The self-consistent triple is found among the noise")
    func findsTheTriple() {
        // A real forecourt frame: prices board, VAT line, and the display's three numbers.
        let frame = ["UNLEADED", "E5", "£13.72", "9.43", "1.455", "VAT No 123456", "0800 123456"]
        let reading = pumpReading(fromRecognized: frame)
        #expect(reading == PumpReading(litres: 9.43, pricePerLitre: 1.455))
    }

    @Test("Without the product agreeing, nothing is believed")
    func rejectsInconsistency() {
        // Three plausible numbers that are not a pump: no assignment multiplies out.
        #expect(pumpReading(fromRecognized: ["9.43", "1.455", "99.99"]) == nil)
        #expect(pumpReading(fromRecognized: ["9.43", "1.455"]) == nil)
        #expect(pumpReading(fromRecognized: []) == nil)
    }

    @Test("Comma displays and currency signs read the same")
    func toleratesDialects() {
        let frame = ["13,72", "9,43", "1,455"]
        #expect(pumpReading(fromRecognized: frame) == PumpReading(litres: 9.43, pricePerLitre: 1.455))
    }
}

@Suite("Reading the odometer")
struct OdometerReadingTests {
    @Test("The mileage-shaped number wins, and the trip meter loses")
    func picksTheOdometer() {
        // Odometer 19432, trip meter 231.4, a clock and the speedo.
        #expect(odometerReading(fromRecognized: ["19432", "231.4", "14:32", "0"]) == 19_432)
    }

    @Test("Nothing mileage-shaped, nothing believed")
    func rejectsNonMileage() {
        #expect(odometerReading(fromRecognized: ["14:32", "88"]) == nil)
        #expect(odometerReading(fromRecognized: ["19432.55"]) == nil)   // odometers have no cents
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
