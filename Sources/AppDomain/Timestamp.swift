import Foundation

// MARK: - The timeline's own clock

/// Parses the database's own timestamp dialect — `2026-08-08T15:34:39Z`, optionally with a
/// fractional second — by arithmetic alone.
///
/// `ISO8601DateFormatter` costs tens of microseconds per call, which is invisible on one date and
/// two full seconds on a timeline of forty thousand — the rides list took longer to open than the
/// rides took to ride. This format is not "some ISO 8601": it is the exact string this app writes,
/// so parsing it is integer extraction and the days-from-civil calendar identity, with no locale,
/// no time zone database and no `Calendar` anywhere near it.
public func parseTimestamp(_ text: String) -> Date? {
    let bytes = Array(text.utf8)
    guard bytes.count >= 20 else { return nil }

    func digit(_ index: Int) -> Int? {
        guard let byte = bytes[safe: index], byte >= 48, byte <= 57 else { return nil }
        return Int(byte - 48)
    }
    func number(_ range: ClosedRange<Int>) -> Int? {
        var value = 0
        for index in range {
            guard let digit = digit(index) else { return nil }
            value = value * 10 + digit
        }
        return value
    }
    func separator(_ index: Int, _ ascii: UInt8) -> Bool {
        bytes[safe: index] == ascii
    }

    guard
        let year = number(0...3), separator(4, 45),      // -
        let month = number(5...6), separator(7, 45),     // -
        let day = number(8...9), separator(10, 84),      // T
        let hour = number(11...12), separator(13, 58),   // :
        let minute = number(14...15), separator(16, 58), // :
        let second = number(17...18),
        month >= 1, month <= 12, day >= 1, day <= 31,
        hour <= 23, minute <= 59, second <= 60
    else { return nil }

    // Days from civil (Howard Hinnant's algorithm): exact over the whole proleptic Gregorian
    // calendar, leap years included, in a handful of integer operations.
    let adjustedYear = month <= 2 ? year - 1 : year
    let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
    let yearOfEra = adjustedYear - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    let daysSinceEpoch = era * 146_097 + dayOfEra - 719_468

    var interval = Double(daysSinceEpoch) * 86_400
        + Double(hour) * 3_600 + Double(minute) * 60 + Double(second)

    // The tail: `Z`, or `.fffZ` at any precision.
    if separator(19, 46) {   // .
        var fraction = 0.0
        var scale = 0.1
        var index = 20
        while let digit = digit(index) {
            fraction += Double(digit) * scale
            scale /= 10
            index += 1
        }
        guard index > 20, separator(index, 90) else { return nil }   // Z
        interval += fraction
    } else if !separator(19, 90) {   // Z
        return nil
    }

    return Date(timeIntervalSince1970: interval)
}
