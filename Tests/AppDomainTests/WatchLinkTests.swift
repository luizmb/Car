import Foundation
import Testing
@testable import AppDomain

@Suite("Watch haptic rules")
struct WatchHapticTests {
    @Test("An indicator turning on, staying on, and turning off")
    func indicatorLifecycle() {
        let off = WatchSnapshot()
        let left = WatchSnapshot(indicator: "left")
        #expect(watchHaptics(previous: nil, current: left, consecutiveOver: 0) == [.indicatorOn])
        #expect(watchHaptics(previous: left, current: left, consecutiveOver: 0) == [.indicatorTick])
        #expect(watchHaptics(previous: left, current: off, consecutiveOver: 0) == [.indicatorOff])
    }

    @Test("Switching sides is a fresh on, not a tick")
    func sideSwitch() {
        let left = WatchSnapshot(indicator: "left")
        let right = WatchSnapshot(indicator: "right")
        #expect(watchHaptics(previous: left, current: right, consecutiveOver: 0) == [.indicatorOn])
    }

    @Test("Over the limit buzzes on the crossing and then only on the slow clock")
    func overSpeedCadence() {
        let over = WatchSnapshot(overLimit: true)
        let under = WatchSnapshot(overLimit: false)
        #expect(watchHaptics(previous: under, current: over, consecutiveOver: 0) == [.overSpeed])
        #expect(watchHaptics(previous: over, current: over, consecutiveOver: 1) == [])
        #expect(watchHaptics(previous: over, current: over, consecutiveOver: overSpeedRepeatSnapshots) == [.overSpeed])
        #expect(watchHaptics(previous: over, current: under, consecutiveOver: 6) == [.backUnderLimit])
    }
}

@Suite("Watch wire codec")
struct WatchWireTests {
    @Test("A full snapshot survives the dictionary round trip")
    func snapshotRoundTrip() {
        let snapshot = WatchSnapshot(
            mph: 31.5, limitMPH: 30, limitText: "30", limitIsNational: false,
            limitIsAssumed: true, overLimit: true, roadLabel: "A505", indicator: "right",
            latitude: 51.88, longitude: -0.42, headingDegrees: 182,
            routeLatitudes: [51.88, 51.89], routeLongitudes: [-0.42, -0.43],
            nextTurnMetres: 240, sinceFillKm: 143.2, journeyActive: true
        )
        #expect(WatchWire.snapshot(from: WatchWire.dictionary(from: snapshot)) == snapshot)
    }

    @Test("An empty snapshot survives too — absent keys read as absent values")
    func emptySnapshotRoundTrip() {
        let empty = WatchSnapshot()
        #expect(WatchWire.snapshot(from: WatchWire.dictionary(from: empty)) == empty)
    }

    @Test("A refuel command survives, and an unknown command reads as nothing")
    func refuelRoundTrip() {
        let refuel = WatchRefuel(litres: 9.25, pricePerLitre: 1.47, grade: "E10", filledToBrim: false)
        #expect(WatchWire.refuel(from: WatchWire.dictionary(from: refuel)) == refuel)
        #expect(WatchWire.refuel(from: ["command": "selfdestruct"]) == nil)
    }
}

@Suite("Watch route sampling")
struct WatchRouteSampleTests {
    @Test("A short route passes through untouched; a long one keeps its ends")
    func sampling() {
        let short = (0..<10).map { Coordinate(latitude: Latitude(52 + Double($0) / 100), longitude: Longitude(-0.4)) }
        let sampled = watchRouteSample(short)
        #expect(sampled.latitudes.count == 10)

        let long = (0..<3_000).map { Coordinate(latitude: Latitude(52 + Double($0) / 10_000), longitude: Longitude(-0.4)) }
        let thinned = watchRouteSample(long)
        #expect(thinned.latitudes.count == 60)
        #expect(thinned.latitudes.first == 52)
        #expect(thinned.latitudes.last == long.last?.latitude.rawValue)
    }
}
