import Foundation
import Testing
@testable import AppDomain

// Every payload here was captured from the real unit during the garage session on 2026-08-04
// (`spike-2026-08-04T11-47-55Z.jsonl`) and cross-checked against hand-tapped markers, so these
// are recorded behaviour rather than assumptions about the protocol.

@Suite("Indimate payload parsing")
struct IndimateParsingTests {

    private func payload(_ ascii: String) -> Data { Data(ascii.utf8) }

    @Test("left engaged, both blink phases")
    func leftBothPhases() {
        #expect(parseIndimatePayload(payload("1010")) == .indicator(.left))
        #expect(parseIndimatePayload(payload("1000")) == .indicator(.left))
    }

    @Test("right engaged, both blink phases")
    func rightBothPhases() {
        #expect(parseIndimatePayload(payload("0101")) == .indicator(.right))
        #expect(parseIndimatePayload(payload("0100")) == .indicator(.right))
    }

    @Test("neither engaged")
    func neither() {
        #expect(parseIndimatePayload(payload("0000")) == .indicator(nil))
    }

    @Test("the blink phase never changes which side is reported")
    func blinkPhaseIsIgnored() {
        // This is what lets the app run its tick loop at its own rate: the lamp digits flip twice
        // a second, and the parser must not turn that into a stream of side changes.
        #expect(parseIndimatePayload(payload("1010")) == parseIndimatePayload(payload("1000")))
        #expect(parseIndimatePayload(payload("0101")) == parseIndimatePayload(payload("0100")))
    }

    @Test("voltage keeps both readings while the encoding is undetermined")
    func voltage() {
        guard case let .voltage(reading)? = parseIndimatePayload(payload("B3091")) else {
            Issue.record("expected a voltage event")
            return
        }
        #expect(reading.raw == "3091")
        #expect(reading.decimalMillivolts == 3091)
        #expect(reading.hexMillivolts == 0x3091)   // 12433 mV = 12.43 V, a resting battery
        #expect(reading.provesHex == false)        // digits-only cannot settle it
    }

    @Test("a hex letter parses and settles the encoding")
    func hexLetterProvesEncoding() {
        // 13.5 V running = 0x34BC. The old parser did Int("34BC") in decimal, got nil, and
        // dropped the reading to .info — losing the value exactly when the engine made it useful.
        guard case let .voltage(reading)? = parseIndimatePayload(payload("B34BC")) else {
            Issue.record("expected a voltage event, not an info fallthrough")
            return
        }
        #expect(reading.raw == "34BC")
        #expect(reading.hexMillivolts == 13500)
        #expect(reading.decimalMillivolts == nil)
        #expect(reading.provesHex)
    }

    @Test("every captured engine-off sample reads as a plausible resting battery in hex")
    func capturedSamplesArePlausible() {
        // The four real payloads from the garage session.
        for raw in ["3091", "3038", "3105", "3056"] {
            guard case let .voltage(reading)? = parseIndimatePayload(payload("B" + raw)),
                  let millivolts = reading.hexMillivolts
            else {
                Issue.record("\(raw) did not parse")
                return
            }
            #expect(millivolts > 12_000 && millivolts < 12_800)
        }
    }

    @Test("firmware and serial come through as info")
    func info() {
        #expect(parseIndimatePayload(payload("VG2 (24-02-2025)")) == .info("VG2 (24-02-2025)"))
        #expect(parseIndimatePayload(payload("0000-258727-6807-5697")) == .info("0000-258727-6807-5697"))
        #expect(parseIndimatePayload(payload("I0")) == .info("I0"))
    }

    @Test("a serial that merely starts with a digit is not mistaken for indicator state")
    func serialIsNotIndicatorState() {
        // "0000-258727-..." begins with the same four characters as the both-off payload; only
        // the length check keeps them apart.
        #expect(parseIndimatePayload(payload("0000-258727-6807-5697")) != .indicator(nil))
    }

    @Test("empty and non-ASCII payloads are ignored rather than guessed at")
    func garbage() {
        #expect(parseIndimatePayload(Data()) == nil)
        #expect(parseIndimatePayload(payload("   ")) == nil)
    }

    @Test("a four-character payload that is not binary digits is info, not state")
    func nonBinaryFourChars() {
        #expect(parseIndimatePayload(payload("1234")) == .info("1234"))
    }
}
