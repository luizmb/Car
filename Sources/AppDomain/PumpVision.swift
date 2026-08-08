import FP
import Foundation

// MARK: - What the camera is looking for

/// One pump display, read: the two numbers the fuel form needs.
public struct PumpReading: Sendable, Equatable {
    public let litres: Double
    public let pricePerLitre: Double

    public init(litres: Double, pricePerLitre: Double) {
        self.litres = litres
        self.pricePerLitre = pricePerLitre
    }
}

// MARK: - Reading numbers out of OCR noise

/// A number as a pump or odometer displays it and OCR mangles it.
///
/// Tolerant on purpose: currency signs, unit suffixes, a comma where the locale writes one, and
/// the stray letters OCR sprinkles into seven-segment digits are all stripped before parsing.
/// Deliberately *not* the World's locale parser — a pump's display has its own dialect and it is
/// the same dialect in every country the bike will see.
public func scanNumber(_ raw: String) -> Double? {
    // A colon means a clock, and stripping it would turn 14:32 into a plausible odometer.
    guard !raw.contains(":") else { return nil }
    let cleaned = raw
        .replacingOccurrences(of: ",", with: ".")
        .filter { $0.isNumber || $0 == "." }
    guard !cleaned.isEmpty, cleaned.filter({ $0 == "." }).count <= 1 else { return nil }
    return Double(cleaned)
}

// MARK: - The pump

/// Finds the pump's reading in one frame's recognized strings — or `nil`, which is most frames.
///
/// The trick is that a pump shows **three** numbers that must agree: litres, price per litre, and
/// their product, the total. OCR does not know which is which, but arithmetic does: the one
/// assignment of three plausible numbers where litres × price ≈ total *is* the display. Requiring
/// the triple to check out is what makes a phone number on a sticker, a time of day or the price
/// board across the forecourt unable to masquerade as a reading.
public func pumpReading(fromRecognized texts: [String]) -> PumpReading? {
    let numbers = texts.compactMap(scanNumber)
    guard numbers.count >= 3 else { return nil }

    let litreCandidates = numbers.filter { $0 >= 0.5 && $0 <= 80 }
    let priceCandidates = numbers.filter { $0 >= 0.8 && $0 <= 2.5 }
    let totalCandidates = numbers.filter { $0 >= 1 && $0 <= 200 }

    var best: (reading: PumpReading, error: Double)?
    for litres in litreCandidates {
        for price in priceCandidates where price != litres {
            for total in totalCandidates where total != litres && total != price {
                let expected = litres * price
                guard expected > 0 else { continue }
                let error = abs(expected - total) / expected
                // A pump's own arithmetic is exact; the slack is for OCR dropping a trailing digit.
                guard error <= 0.02 else { continue }
                if best.map({ error < $0.error }) ?? true {
                    best = (PumpReading(litres: litres, pricePerLitre: price), error)
                }
            }
        }
    }
    return best?.reading
}

// MARK: - The odometer

/// Finds the odometer in one frame's recognized strings — the mileage-shaped number, not the
/// clock, not the trip meter's tenths.
///
/// An odometer is a large integer: at least three digits (a bike with under 100 km on it is being
/// filmed in a showroom), at most six (no VT400 survives a million), no fractional part beyond
/// the trip meter's single tenth. Among candidates the *largest* wins — where a display shows
/// both odometer and trip meter, the odometer is the bigger number by construction.
public func odometerReading(fromRecognized texts: [String]) -> Double? {
    texts
        .compactMap(scanNumber)
        .filter { value in
            value >= 100 && value < 1_000_000
                && (value * 10).rounded() == value * 10   // whole, or one tenth at most
        }
        .max()
}

// MARK: - Stability

/// The scanner's patience: the same value read from this many consecutive frames before it is
/// believed. One frame of OCR is a guess; five agreeing frames are a reading.
public let scanStabilityFrames = 5

/// One step of the stability fold: the streak grows while the candidate agrees with what the
/// streak holds, and starts over when it disagrees or the frame saw nothing.
public func scanStreak<Value: Equatable>(
    _ streak: (value: Value, count: Int)?, saw candidate: Value?
) -> (value: Value, count: Int)? {
    guard let candidate else { return streak }
    guard let streak, streak.value == candidate else { return (candidate, 1) }
    return (streak.value, streak.count + 1)
}
