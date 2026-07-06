import FP
import FPMacros
import Foundation

@Prisms public enum CardinalDirection: CustomStringConvertible, RawRepresentable, Equatable {
    case hemisphere(CardinalDirection.Hemisphere)
    case meridian(CardinalDirection.Meridian)

    public var description: String {
        switch self {
        case let .hemisphere(h): h.description
        case let .meridian(m):   m.description
        }
    }

    public var rawValue: String {
        switch self {
        case let .hemisphere(h): h.rawValue
        case let .meridian(m):   m.rawValue
        }
    }

    public init?(rawValue: String) {
        if let h = Hemisphere(rawValue: rawValue) { self = .hemisphere(h); return }
        if let m = Meridian(rawValue: rawValue)   { self = .meridian(m);   return }
        return nil
    }

    public static func format(
        numberFormatter: FloatingPointFormatStyle<Double>,
        latitude: Latitude,
        longitude: Longitude
    ) -> String {
        Hemisphere.format(numberFormatter: numberFormatter, latitude: latitude)
        + ", "
        + Meridian.format(numberFormatter: numberFormatter, longitude: longitude)
    }
}

// MARK: - Hemisphere (N / S)

extension CardinalDirection {
    @Prisms     public enum Hemisphere: CustomStringConvertible, RawRepresentable, Equatable, Comparable {
        case north
        case south

        public var description: String { switch self { case .north: "North"; case .south: "South" } }
        public var rawValue: String    { switch self { case .north: "N";     case .south: "S"     } }

        public init?(rawValue: String) {
            switch rawValue {
            case "N": self = .north
            case "S": self = .south
            default: return nil
            }
        }

        public init(_ latitude: Latitude) {
            self = latitude.rawValue > 0 ? .north : .south
        }

        public static func format(
            numberFormatter: FloatingPointFormatStyle<Double>,
            latitude: Latitude
        ) -> String {
            abs(latitude.rawValue).formatted(numberFormatter) + "°" + Self(latitude).rawValue
        }

        /// Position along the N/S axis: north pole (+90°) or south pole (-90°).
        public var azimuth: Latitude { switch self { case .north: Latitude(90); case .south: Latitude(-90) } }

        public static func < (lhs: Hemisphere, rhs: Hemisphere) -> Bool { lhs.azimuth < rhs.azimuth }
    }
}

// MARK: - Meridian (E / W)

extension CardinalDirection {
    @Prisms     public enum Meridian: CustomStringConvertible, RawRepresentable, Equatable, Comparable {
        case east
        case west

        public var description: String { switch self { case .east: "East"; case .west: "West" } }
        public var rawValue: String    { switch self { case .east: "E";    case .west: "W"    } }

        public init?(rawValue: String) {
            switch rawValue {
            case "E": self = .east
            case "W": self = .west
            default: return nil
            }
        }

        public init(_ longitude: Longitude) {
            self = longitude.rawValue > 0 ? .east : .west
        }

        public static func format(
            numberFormatter: FloatingPointFormatStyle<Double>,
            longitude: Longitude
        ) -> String {
            abs(longitude.rawValue).formatted(numberFormatter) + "°" + Self(longitude).rawValue
        }

        /// Position along the E/W axis: eastern hemisphere (+90°) or western hemisphere (-90°).
        public var azimuth: Longitude { switch self { case .east: Longitude(90); case .west: Longitude(-90) } }

        public static func < (lhs: Meridian, rhs: Meridian) -> Bool { lhs.azimuth < rhs.azimuth }
    }
}

// MARK: - IntercardinalDirection (NE / NW / SE / SW)

extension CardinalDirection {
    public struct IntercardinalDirection: CustomStringConvertible, RawRepresentable, Equatable {
        public let x: Meridian
        public let y: Hemisphere

        public var description: String { y.description + x.description.lowercased() }
        public var rawValue: String    { y.rawValue + x.rawValue }

        public init(x: Meridian, y: Hemisphere) { self.x = x; self.y = y }

        public init?(rawValue: String) {
            switch rawValue {
            case "NE": self.init(x: .east, y: .north)
            case "NW": self.init(x: .west, y: .north)
            case "SE": self.init(x: .east, y: .south)
            case "SW": self.init(x: .west, y: .south)
            default: return nil
            }
        }
    }
}

// MARK: - CompassDirection8

@Prisms public enum CompassDirection8: CustomStringConvertible, RawRepresentable, Equatable {
    case cardinal(CardinalDirection)
    case intercardinal(CardinalDirection.IntercardinalDirection)

    public var description: String {
        switch self {
        case let .cardinal(c):      c.description
        case let .intercardinal(i): i.description
        }
    }

    public var rawValue: String {
        switch self {
        case let .cardinal(c):      c.rawValue
        case let .intercardinal(i): i.rawValue
        }
    }

    public init?(rawValue: String) {
        if let c = CardinalDirection(rawValue: rawValue)                        { self = .cardinal(c);      return }
        if let i = CardinalDirection.IntercardinalDirection(rawValue: rawValue) { self = .intercardinal(i); return }
        return nil
    }

    public init?(course: Course) {
        switch course.rawValue {
        case 0..<22.5, 337.5...360: self = .cardinal(.hemisphere(.north))
        case 22.5..<67.5:           self = .intercardinal(.init(x: .east, y: .north))
        case 67.5..<112.5:          self = .cardinal(.meridian(.east))
        case 112.5..<157.5:         self = .intercardinal(.init(x: .east, y: .south))
        case 157.5..<202.5:         self = .cardinal(.hemisphere(.south))
        case 202.5..<247.5:         self = .intercardinal(.init(x: .west, y: .south))
        case 247.5..<292.5:         self = .cardinal(.meridian(.west))
        case 292.5..<337.5:         self = .intercardinal(.init(x: .west, y: .north))
        default: return nil
        }
    }
}

// MARK: - Coordinate newtype extensions

public extension Latitude {
    /// The N/S hemisphere for this latitude coordinate.
    var hemisphere: CardinalDirection.Hemisphere { .init(self) }
}

public extension Longitude {
    /// The E/W meridian side for this longitude coordinate.
    var meridian: CardinalDirection.Meridian { .init(self) }
}
