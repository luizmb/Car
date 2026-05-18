import Foundation

enum CardinalPoint: CustomStringConvertible, RawRepresentable, Equatable, Comparable {
    case latitude(Latitude)
    var latitude: Latitude? { guard case let .latitude(latitude) = self else { return nil }; return latitude }
    case longitude(Longitude)
    var longitude: Longitude? { guard case let .longitude(longitude) = self else { return nil }; return longitude }

    var description: String {
        switch self { case let .latitude(latitude): latitude.description case let .longitude(longitude): longitude.description }
    }

    var rawValue: String {
        switch self { case let .latitude(latitude): latitude.rawValue case let .longitude(longitude): longitude.rawValue }
    }

    init?(rawValue: String) {
        guard let some = Latitude(rawValue: rawValue).map(Self.latitude) ?? Longitude(rawValue: rawValue).map(Self.longitude) else { return nil }
        self = some
    }

    static func format(numberFormatter: FloatingPointFormatStyle<Double>, globeLatitudeDegrees: Double, globeLongitudeDegrees: Double) -> String {
        Latitude.format(numberFormatter: numberFormatter, globeLatitudeDegrees: globeLatitudeDegrees)
        + ", "
        + Longitude.format(numberFormatter: numberFormatter, globeLongitudeDegrees: globeLongitudeDegrees)
    }

    var azimuth: Double {
        switch self { case let .latitude(latitude): latitude.azimuth case let .longitude(longitude): longitude.azimuth }
    }

    static func < (lhs: CardinalPoint, rhs: CardinalPoint) -> Bool {
        lhs.azimuth < rhs.azimuth
    }
}

extension CardinalPoint {
    enum Latitude: CustomStringConvertible, RawRepresentable, Equatable, Comparable {
        case north
        var north: Void? { guard case .north = self else { return nil }; return () }
        case south
        var south: Void? { guard case .south = self else { return nil }; return () }

        var description: String {
            switch self { case .north: "North" case .south: "South" }
        }

        var rawValue: String {
            switch self { case .north: "N" case .south: "S" }
        }

        init?(rawValue: String) {
            switch rawValue {
            case "N": self = .north
            case "S": self = .south
            default: return nil
            }
        }

        init(globeLatitudeDegrees: Double) {
            self = globeLatitudeDegrees > 0 ? .north : .south
        }

        static func format(numberFormatter: FloatingPointFormatStyle<Double>, globeLatitudeDegrees: Double) -> String {
            numberFormatter
            |> abs(globeLatitudeDegrees).formatted
            + "°"
            + Self.init(globeLatitudeDegrees: globeLatitudeDegrees).rawValue
        }

        var azimuth: Double { switch self { case .north: 0 case .south: 180 }}

        static func < (lhs: Latitude, rhs: Latitude) -> Bool {
            lhs.azimuth < rhs.azimuth
        }
    }
}

extension CardinalPoint {
    enum Longitude: CustomStringConvertible, RawRepresentable, Equatable, Comparable {
        case east
        var east: Void? { guard case .east = self else { return nil }; return () }
        case west
        var west: Void? { guard case .west = self else { return nil }; return () }

        var description: String {
            switch self { case .east: "East" case .west: "West" }
        }

        var rawValue: String {
            switch self { case .east: "E" case .west: "W" }
        }

        init?(rawValue: String) {
            switch rawValue {
            case "E": self = .east
            case "W": self = .west
            default: return nil
            }
        }

        init(globeLongitudeDegrees: Double) {
            self = globeLongitudeDegrees > 0 ? .east : .west
        }

        static func format(numberFormatter: FloatingPointFormatStyle<Double>, globeLongitudeDegrees: Double) -> String {
            numberFormatter
            |> abs(globeLongitudeDegrees).formatted
            + "°"
            + Self.init(globeLongitudeDegrees: globeLongitudeDegrees).rawValue
        }

        var azimuth: Double { switch self { case .east: 90 case .west: 270 }}

        static func < (lhs: Longitude, rhs: Longitude) -> Bool {
            lhs.azimuth < rhs.azimuth
        }
    }
}

extension CardinalPoint {
    struct IntercardinalDirection: CustomStringConvertible, RawRepresentable, Equatable, Comparable {
        let x: Longitude
        let y: Latitude

        var description: String {
            y.description + x.description.lowercased()
        }

        var rawValue: String {
            y.rawValue + x.rawValue
        }

        init(x: CardinalPoint.Longitude, y: CardinalPoint.Latitude) {
            self.x = x
            self.y = y
        }

        init?(rawValue: String) {
            switch rawValue {
            case "NE":
                x = .east
                y = .north
            case "NW":
                x = .west
                y = .north
            case "SE":
                x = .east
                y = .south
            case "SW":
                x = .west
                y = .south
            default: return nil
            }
        }

        var azimuth: Double {
            switch self {
            case .init(x: .east, y: .north): 45
            case .init(x: .east, y: .south): 135
            case .init(x: .west, y: .south): 225
            case .init(x: .west, y: .north): 315
            default: 0
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.azimuth < rhs.azimuth
        }
    }
}

enum CompassDirection8: CustomStringConvertible, RawRepresentable {
    case cardinal(CardinalPoint)
    var cardinal: CardinalPoint? { guard case let .cardinal(cardinal) = self else { return nil }; return cardinal }
    case intercardinal(CardinalPoint.IntercardinalDirection)
    var intercardinal: CardinalPoint.IntercardinalDirection? { guard case let .intercardinal(intercardinal) = self else { return nil }; return intercardinal }

    var description: String {
        switch self { case let .cardinal(cardinal): cardinal.description case let .intercardinal(intercardinal): intercardinal.description }
    }

    var rawValue: String {
        switch self { case let .cardinal(cardinal): cardinal.rawValue case let .intercardinal(intercardinal): intercardinal.rawValue }
    }

    init?(rawValue: String) {
        guard let some = CardinalPoint(rawValue: rawValue).map(Self.cardinal) ?? CardinalPoint.IntercardinalDirection(rawValue: rawValue).map(Self.intercardinal) else { return nil }
        self = some
    }

    init?(degrees: Double) {
        let some: CompassDirection8? = switch degrees {
        case 0..<22.5, 337.5...360: .cardinal(.latitude(.north))
        case 22.5..<67.5: .intercardinal(.init(x: .east, y: .north))
        case 67.5..<112.5: .cardinal(.longitude(.east))
        case 112.5..<157.5: .intercardinal(.init(x: .east, y: .south))
        case 157.5..<202.5: .cardinal(.latitude(.south))
        case 202.5..<247.5: .intercardinal(.init(x: .west, y: .south))
        case 247.5..<292.5: .cardinal(.longitude(.west))
        case 292.5..<337.5: .intercardinal(.init(x: .west, y: .north))
        default: nil
        }
        if let some { self = some }
        else { return nil }
    }

    var azimuth: Double {
        switch self {
        case let .cardinal(cardinal): cardinal.azimuth
        case let .intercardinal(intercardinal): intercardinal.azimuth
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.azimuth < rhs.azimuth
    }
}
