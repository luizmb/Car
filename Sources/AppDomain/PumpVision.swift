import FP
import Foundation

// MARK: - What the camera sees

/// One piece of recognized text and where it sat in the frame, in normalized coordinates.
///
/// The position is what lets the domain say "the grade label *next to* the winning price" — a
/// flat list of strings knows that E5 and E10 were both on screen but not which one owned the
/// number that did the arithmetic.
public struct RecognizedText: Sendable, Equatable {
    public let text: String
    /// Centre of the text's bounding box, 0…1 in the frame's own space. Only relative geometry
    /// is ever used for *matching*, so the orientation convention does not matter as long as it
    /// is consistent within a frame; the size exists so a screen can draw a box around the words
    /// it believed.
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(text: String, x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

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

/// A reading together with the grade label that sat nearest its price — when one did.
///
/// Separate from ``PumpReading`` so the stability streak compares only the numbers: the grade
/// label flickering in and out of OCR must not reset five good frames of arithmetic.
public struct PumpSighting: Sendable, Equatable {
    public let reading: PumpReading
    /// `"E5"`, `"E10"`, `"B7"`… — the token nearest the winning price, or `nil`.
    public let grade: String?
    /// Where the believed values sat — litres, price, total — so the screen can put a box
    /// around exactly the words that convinced the arithmetic.
    public let boxes: [RecognizedText]

    public init(reading: PumpReading, grade: String? = nil, boxes: [RecognizedText] = []) {
        self.reading = reading
        self.grade = grade
        self.boxes = boxes
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

/// The grade labels a pump wears. Exact tokens, matched case-insensitively — OCR either read
/// the badge or it did not, and "correcting" near-misses would invent grades.
private let gradeTokens: Set<String> = ["E5", "E10", "B7", "B10", "E85", "HVO"]

/// Finds the pump's reading in one frame — or `nil`, which is most frames.
///
/// The trick is that a pump shows **three** numbers that must agree: litres, price per litre, and
/// their product, the total. OCR does not know which is which, but arithmetic does: the one
/// assignment of three plausible numbers where litres × price ≈ total *is* the display. Requiring
/// the triple to check out is what makes a phone number on a sticker, a time of day or the price
/// board across the forecourt unable to masquerade as a reading.
///
/// Two forecourt realities the arithmetic absorbs:
/// - **Pence and decipounds.** Pumps show £1.849 as `184.9` or `18.49` as often as `1.849`, so
///   every number contributes itself, itself÷10 and itself÷100 as price candidates — and the
///   product test alone decides which scale was on the glass.
/// - **Prices side by side.** A display listing E10, E5 and B7 offers several plausible prices,
///   but only the dispensed grade's price multiplies litres into the total. The winner's
///   *position* then names the grade: the grade token nearest the winning price owns it.
public func pumpSighting(fromRecognized texts: [RecognizedText]) -> PumpSighting? {
    let numbers = texts.compactMap { item in scanNumber(item.text).map { (value: $0, at: item) } }
    guard numbers.count >= 3 else { return nil }

    let litreCandidates = numbers.filter { $0.value >= 0.5 && $0.value <= 80 }
    let totalCandidates = numbers.filter { $0.value >= 1 && $0.value <= 200 }
    // Every plausible reading of every number as a price in pounds, remembering where it sat.
    // Rounded to a tenth of a penny — the finest a pump prints — so 184.9 ÷ 100 is exactly the
    // 1.849 a later frame's 1.849 will equal, and the stability streak can actually accumulate.
    let priceCandidates = numbers.flatMap { number in
        [number.value, number.value / 10, number.value / 100].compactMap { scaled -> (value: Double, at: RecognizedText)? in
            let rounded = (scaled * 10_000).rounded() / 10_000
            return rounded >= 0.8 && rounded <= 2.5 ? (rounded, number.at) : nil
        }
    }

    var best: (reading: PumpReading, boxes: [RecognizedText], error: Double)?
    for litres in litreCandidates {
        for price in priceCandidates where price.at != litres.at {
            for total in totalCandidates where total.at != litres.at && total.at != price.at {
                let expected = litres.value * price.value
                guard expected > 0 else { continue }
                let error = abs(expected - total.value) / expected
                // A pump's own arithmetic is exact; the slack is for OCR dropping a trailing digit.
                guard error <= 0.02 else { continue }
                if best.map({ error < $0.error }) ?? true {
                    best = (
                        PumpReading(litres: litres.value, pricePerLitre: price.value),
                        [litres.at, price.at, total.at],
                        error
                    )
                }
            }
        }
    }
    guard let best, let priceBox = best.boxes[safe: 1] else { return nil }
    return PumpSighting(
        reading: best.reading,
        grade: grade(nearest: priceBox, in: texts),
        boxes: best.boxes
    )
}

/// The grade token closest to the winning price — within a reach that means "on the same row or
/// the one beside it", not "somewhere on the forecourt".
private func grade(nearest price: RecognizedText, in texts: [RecognizedText]) -> String? {
    texts
        .filter { gradeTokens.contains($0.text.trimmingCharacters(in: .whitespaces).uppercased()) }
        .map { token -> (String, Double) in
            let dx = token.x - price.x
            let dy = token.y - price.y
            return (token.text.uppercased(), (dx * dx + dy * dy).squareRoot())
        }
        .filter { $0.1 <= 0.35 }
        .min { $0.1 < $1.1 }?
        .0
}

// MARK: - The odometer

/// Finds the odometer in one frame's recognized strings — the mileage-shaped number, not the
/// clock, not the trip meter's tenths.
///
/// An odometer is a large integer: at least three digits (a bike with under 100 km on it is being
/// filmed in a showroom), at most six (no VT400 survives a million), no fractional part beyond
/// the trip meter's single tenth. Among candidates the *largest* wins — where a display shows
/// both odometer and trip meter, the odometer is the bigger number by construction.
public func odometerReading(fromRecognized texts: [RecognizedText]) -> Double? {
    odometerSighting(fromRecognized: texts)?.value
}

/// The odometer with the words that carried it, for the screen's box.
public func odometerSighting(
    fromRecognized texts: [RecognizedText]
) -> (value: Double, at: RecognizedText)? {
    texts
        .compactMap { item in scanNumber(item.text).map { (value: $0, at: item) } }
        .filter { candidate in
            candidate.value >= 100 && candidate.value < 1_000_000
                && (candidate.value * 10).rounded() == candidate.value * 10   // whole, or one tenth
        }
        .max { $0.value < $1.value }
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
