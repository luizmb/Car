import Foundation
import Testing
@testable import AppDomain

// A fill logged without a station can never be given one afterwards — you would be clustering
// coordinates by hand — so this has to work at the moment of recording or not at all.

@Suite("Petrol stations")
struct FuelStationTests {

    private let pump = (Latitude(51.75), Longitude(-0.475))

    private func element(
        _ id: Int, metresNorth: Double, brand: String? = nil, name: String? = nil,
        operatorName: String? = nil, asArea: Bool = false
    ) -> OverpassStationResponse.Element {
        let lat = 51.75 + metresNorth / 111_320
        return .init(
            id: id,
            lat: asArea ? nil : lat,
            lon: asArea ? nil : -0.475,
            center: asArea ? .init(lat: lat, lon: -0.475) : nil,
            tags: .init(brand: brand, name: name, operator: operatorName)
        )
    }

    @Test("the nearest forecourt wins")
    func nearest() {
        // Paired forecourts either side of a road, or motorway services, return several. The one
        // being filled from is the one underfoot.
        let response = OverpassStationResponse(elements: [
            element(1, metresNorth: 120, brand: "BP"),
            element(2, metresNorth: 15, brand: "Shell")
        ])
        #expect(nearestStation(response, to: pump)?.brand == "Shell")
    }

    @Test("a forecourt mapped as an area is found by its centre")
    func areaMapped() {
        let response = OverpassStationResponse(elements: [element(3, metresNorth: 20, brand: "Esso", asArea: true)])
        #expect(nearestStation(response, to: pump)?.id == 3)
    }

    @Test("operator is the fallback when brand is missing")
    func operatorFallback() {
        let response = OverpassStationResponse(elements: [
            element(4, metresNorth: 10, name: "Ormsby Service Station", operatorName: "Jet")
        ])
        #expect(nearestStation(response, to: pump)?.brand == "Jet")
    }

    @Test("brand leads the label, because that is what prices are compared between")
    func labelPrefersBrand() {
        #expect(FuelStation(id: 1, brand: "Shell", name: "Ormsby Service Station").label == "Shell")
        #expect(FuelStation(id: 1, brand: nil, name: "Ormsby Service Station").label == "Ormsby Service Station")
        #expect(FuelStation(id: 1, brand: nil, name: nil).label == nil)
    }

    @Test("nothing nearby is nothing, not a guess")
    func empty() {
        // A wrong attribution is worse than none: it would pool two forecourts' prices together.
        #expect(nearestStation(OverpassStationResponse(elements: []), to: pump) == nil)
    }

    @Test("an element with no position at all is skipped")
    func noPosition() {
        let response = OverpassStationResponse(elements: [
            .init(id: 5, lat: nil, lon: nil, center: nil, tags: .init(brand: "Ghost", name: nil, operator: nil)),
            element(6, metresNorth: 50, brand: "Real")
        ])
        #expect(nearestStation(response, to: pump)?.brand == "Real")
    }
}
