import Foundation

/// Why a typed number could not be read, or a number could not be written.
///
/// A specific failure type rather than an optional: "empty" is the normal state of a form the rider
/// has not finished typing into, and "unparseable" is a mistake worth distinguishing from it — the
/// first should leave Save quietly disabled, the second could eventually explain itself.
public enum NumberError: Error, Sendable, Equatable {
    case empty
    case unparseable(String)
    case unformattable(Double)
}

// MARK: - Why this is two closures and not an `Iso`
//
// An `Iso<String, Double>` would be a lie: neither direction is total. Parsing fails on "abc" and on
// an empty field, and the round trip does not return what it was given — "8,120" formats back as
// "8,12", and "1,9950" as "1,995". An `Iso` promises a lossless bijection, and this is a pair of
// partial functions that happen to point in opposite directions.

/// Parses a number typed by a human, whichever separator their keyboard offered.
///
/// `Double("8,12")` is `nil`. `Double(String)` is locale-*invariant* and accepts only a period —
/// which is correct for parsing files and wrong for parsing people. On a comma-decimal locale the
/// numeric keypad offers a comma, so the rider types `8,12` and `1,995`, every field silently
/// evaluates to zero, and the Save button greys out with nothing to explain why.
///
/// Deliberately not `NumberFormatter` with `Locale.current`: that is ambient state, and it would
/// also *reject* a period typed by someone whose keyboard offered one. Accepting both is strictly
/// more forgiving than being right about the locale.
///
/// **The rule:** the last separator is the decimal point; any earlier ones are grouping and are
/// discarded. That reads `8,12` and `8.12` as 8.12, `1.234,56` and `1,234.56` as 1234.56.
///
/// The ambiguity it cannot resolve is a grouped integer — `22,200` means twenty-two thousand to a
/// British reader and 22.2 to a French one. There is no context here to settle it, which is why
/// whole-number fields use ``parseWholeNumber(_:)`` instead of this.
public func parseDecimal(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    let separators: Set<Character> = [",", "."]
    guard let lastSeparator = trimmed.lastIndex(where: { separators.contains($0) }) else {
        return Double(trimmed)
    }

    let whole = trimmed[..<lastSeparator].filter { !separators.contains($0) }
    let fraction = trimmed[trimmed.index(after: lastSeparator)...]
    // A trailing separator is someone mid-type — "8," is 8, not a parse failure, so the button does
    // not flicker off between the comma and the digit after it.
    guard !fraction.isEmpty else { return Double(whole) }
    return Double(whole + "." + fraction)
}

/// Parses a whole number, treating every separator as grouping.
///
/// For the odometer, which reads in whole kilometres. `22,200` and `22.200` are both twenty-two
/// thousand two hundred here — the interpretation ``parseDecimal(_:)`` deliberately refuses to
/// guess at, and which is unambiguous only because this field cannot have a fractional part.
public func parseWholeNumber(_ text: String) -> Double? {
    let digits = text.trimmingCharacters(in: .whitespaces)
        .filter { $0.isNumber || $0 == "-" }
    return digits.isEmpty ? nil : Double(digits)
}
