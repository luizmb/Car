import Foundation
import Testing
@testable import AppDomain

// From a real screenshot: the rider's numeric keypad offers a comma as the decimal key, so the form
// held "8,12" litres at "1,995" a litre — and Save was greyed out with nothing on screen to say why,
// because `Double("8,12")` is nil and every field silently read as zero.

@Suite("Typed numbers")
struct DecimalInputTests {

    @Test("a comma decimal is accepted")
    func commaDecimal() {
        #expect(parseDecimal("8,12") == 8.12)
        #expect(parseDecimal("1,995") == 1.995)
    }

    @Test("a period decimal still works")
    func periodDecimal() {
        // Accepting both is strictly more forgiving than being right about the locale — and the
        // locale is not even reliable, since the keyboard may not match it.
        #expect(parseDecimal("8.12") == 8.12)
        #expect(parseDecimal("1.995") == 1.995)
    }

    @Test("plain integers parse")
    func integers() {
        #expect(parseDecimal("22200") == 22_200)
        #expect(parseDecimal("8") == 8)
    }

    @Test("the last separator is the decimal point, earlier ones are grouping")
    func mixedSeparators() {
        #expect(parseDecimal("1.234,56") == 1234.56)
        #expect(parseDecimal("1,234.56") == 1234.56)
    }

    @Test("a trailing separator is someone mid-type, not a failure")
    func trailingSeparator() {
        // Otherwise Save flickers off between the comma and the digit after it.
        #expect(parseDecimal("8,") == 8)
        #expect(parseDecimal("8.") == 8)
    }

    @Test("empty and nonsense give nothing")
    func rejects() {
        #expect(parseDecimal("") == nil)
        #expect(parseDecimal("   ") == nil)
        #expect(parseDecimal("abc") == nil)
    }

    @Test("the odometer treats every separator as grouping")
    func wholeNumbers() {
        // `22,200` is twenty-two thousand to a British reader and 22.2 to a French one. There is no
        // context to settle that — except that this field cannot have a fractional part, which
        // settles it.
        #expect(parseWholeNumber("22200") == 22_200)
        #expect(parseWholeNumber("22,200") == 22_200)
        #expect(parseWholeNumber("22.200") == 22_200)
        #expect(parseWholeNumber("") == nil)
    }
}
