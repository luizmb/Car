import FP
import Foundation

/// Where a fill happened, as a place rather than a pair of coordinates.
///
/// Resolved **at the moment of recording** and stored on the record, not looked up later from the
/// position. That is deliberate and it is the whole reason this exists: a fill logged without a
/// station can never be attributed to one afterwards without clustering coordinates by hand, and
/// price comparison is the feature that needs it.
public struct FuelStation: Sendable, Equatable, Codable {
    /// The OSM element id, so two fills at the same forecourt agree they are the same place even if
    /// the name is spelled differently on different days.
    public let id: Int
    /// The operator — `Shell`, `BP`, `Tesco`. What a rider compares prices between.
    public let brand: String?
    public let name: String?

    public init(id: Int, brand: String?, name: String?) {
        self.id = id
        self.brand = brand
        self.name = name
    }

    /// What to show in a list. Brand first, because "Shell" identifies a price and "Ormsby Service
    /// Station" identifies a building.
    public var label: String? { brand ?? name }
}

// MARK: - Overpass

/// Petrol stations within `radius` metres.
///
/// A tight radius on purpose. Unlike the camera query, which casts wide because missing a camera
/// costs a fine, this one runs while the rider is standing *at* the pump — so anything more than a
/// street away is a different station, and a wrong attribution is worse than none.
///
/// `out center tags` because forecourts are mapped as both nodes and areas, and the centre of the
/// area is close enough when you are already inside it.
public func overpassStationRequest(
    latitude: Latitude, longitude: Longitude, radius: Meters = Meters(150)
) -> URLRequest {
    let around = "around:\(Int(radius.rawValue)),\(latitude.rawValue),\(longitude.rawValue)"
    let query = """
    [out:json][timeout:10];(\
    node(\(around))["amenity"="fuel"];\
    way(\(around))["amenity"="fuel"];\
    );out center tags;
    """
    let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(escaped)")!
    return URLRequest(url: url)
}

public struct OverpassStationResponse: Decodable, Sendable {
    public struct Element: Decodable, Sendable {
        public struct Center: Decodable, Sendable {
            public let lat: Double
            public let lon: Double
        }
        public struct Tags: Decodable, Sendable {
            public let brand: String?
            public let name: String?
            public let `operator`: String?

            enum CodingKeys: String, CodingKey {
                case brand, name
                case `operator` = "operator"
            }
        }
        public let id: Int
        public let lat: Double?
        public let lon: Double?
        public let center: Center?
        public let tags: Tags?
    }
    public let elements: [Element]
}

/// The nearest station to where the rider is standing.
///
/// Nearest rather than first: motorway services and paired forecourts either side of a road both
/// return several, and the one being filled from is the one underfoot.
public func nearestStation(
    _ response: OverpassStationResponse,
    to position: (Latitude, Longitude)
) -> FuelStation? {
    response.elements
        .compactMap { element -> (FuelStation, Double)? in
            guard
                let lat = element.lat ?? element.center?.lat,
                let lon = element.lon ?? element.center?.lon
            else { return nil }
            let station = FuelStation(
                id: element.id,
                // `brand` is the tag that means the operator; `operator` is the fallback, and plenty
                // of independents carry only a name.
                brand: element.tags?.brand ?? element.tags?.operator,
                name: element.tags?.name
            )
            let distance = distanceMetres(from: position, to: (Latitude(lat), Longitude(lon)))
            return (station, distance)
        }
        .min { $0.1 < $1.1 }?
        .0
}
