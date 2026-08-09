import FP
import Foundation

// MARK: - The snapshot

/// What the watch shows: the phone's truth at an instant, flattened to primitives.
///
/// The phone is the **only** source of truth — it owns the GPS, the stores, the road data and the
/// journey rule. The watch holds nothing but the last snapshot it was given and renders it, which
/// is why this is one flat value of primitives rather than a graph of domain types: it is a wire
/// picture, not a model, and either side can change its internals without the other noticing as
/// long as this shape holds.
public struct WatchSnapshot: Sendable, Equatable {
    // Instruments
    public var mph: Double?
    /// The limit figure, where one is resolvable. `nil` with `limitText` nil means no data.
    public var limitMPH: Double?
    /// What the limit sign should say — "30", "60" — already worded by the phone.
    public var limitText: String?
    /// The national-speed-limit sign applies (with or without a resolved figure).
    public var limitIsNational: Bool
    /// Inferred rather than surveyed — the watch marks it the way the phone does.
    public var limitIsAssumed: Bool
    /// Above the limit's tolerance right now — the red state, and the haptic's trigger.
    public var overLimit: Bool
    public var roadLabel: String?
    // Indicator
    /// `"left"`, `"right"`, or `nil` for cancelled.
    public var indicator: String?
    // Position, for the map
    public var latitude: Double?
    public var longitude: Double?
    public var headingDegrees: Double
    // The chosen route, thinned for the wire
    public var routeLatitudes: [Double]
    public var routeLongitudes: [Double]
    // Guidance
    public var nextTurnMetres: Double?
    // Fuel
    public var sinceFillKm: Double?
    /// What the bike's odometer should read about now — the last fill's reading plus the GPS
    /// distance since. Seeds the watch's refuel form so the crown only ever nudges.
    public var suggestedOdometerKm: Double?
    public var journeyActive: Bool
    // Sensors — the live bike, whatever the instruments page is showing
    public var weatherCelsius: Double?
    public var weatherHumidity: Double?
    public var frontTyrePSI: Double?
    public var frontTyreCelsius: Double?
    public var frontTyreWarn: Bool
    public var rearTyrePSI: Double?
    public var rearTyreCelsius: Double?
    public var rearTyreWarn: Bool
    public var altitudeMetres: Double?
    /// `nil` is honest ignorance — the head unit has not said either way.
    public var ignitionOn: Bool?
    public var indimateConnected: Bool
    public var cardoConnected: Bool
    /// A tape, not a ride: `journeyActive` drives the display, this keeps the watch from
    /// opening a ride session for a replay being watched from a sofa.
    public var replaying: Bool

    public init(
        mph: Double? = nil, limitMPH: Double? = nil, limitText: String? = nil,
        limitIsNational: Bool = false, limitIsAssumed: Bool = false, overLimit: Bool = false,
        roadLabel: String? = nil, indicator: String? = nil,
        latitude: Double? = nil, longitude: Double? = nil, headingDegrees: Double = 0,
        routeLatitudes: [Double] = [], routeLongitudes: [Double] = [],
        nextTurnMetres: Double? = nil, sinceFillKm: Double? = nil,
        suggestedOdometerKm: Double? = nil, journeyActive: Bool = false,
        weatherCelsius: Double? = nil, weatherHumidity: Double? = nil,
        frontTyrePSI: Double? = nil, frontTyreCelsius: Double? = nil, frontTyreWarn: Bool = false,
        rearTyrePSI: Double? = nil, rearTyreCelsius: Double? = nil, rearTyreWarn: Bool = false,
        altitudeMetres: Double? = nil, ignitionOn: Bool? = nil,
        indimateConnected: Bool = false, cardoConnected: Bool = false,
        replaying: Bool = false
    ) {
        self.mph = mph
        self.limitMPH = limitMPH
        self.limitText = limitText
        self.limitIsNational = limitIsNational
        self.limitIsAssumed = limitIsAssumed
        self.overLimit = overLimit
        self.roadLabel = roadLabel
        self.indicator = indicator
        self.latitude = latitude
        self.longitude = longitude
        self.headingDegrees = headingDegrees
        self.routeLatitudes = routeLatitudes
        self.routeLongitudes = routeLongitudes
        self.nextTurnMetres = nextTurnMetres
        self.sinceFillKm = sinceFillKm
        self.suggestedOdometerKm = suggestedOdometerKm
        self.journeyActive = journeyActive
        self.weatherCelsius = weatherCelsius
        self.weatherHumidity = weatherHumidity
        self.frontTyrePSI = frontTyrePSI
        self.frontTyreCelsius = frontTyreCelsius
        self.frontTyreWarn = frontTyreWarn
        self.rearTyrePSI = rearTyrePSI
        self.rearTyreCelsius = rearTyreCelsius
        self.rearTyreWarn = rearTyreWarn
        self.altitudeMetres = altitudeMetres
        self.ignitionOn = ignitionOn
        self.indimateConnected = indimateConnected
        self.cardoConnected = cardoConnected
        self.replaying = replaying
    }
}

// MARK: - The command

/// The one thing the watch may ask the phone to do: record a fill.
///
/// The watch never writes a store. It sends this ask; the phone builds the real record with
/// everything only it knows — the clock, the GPS position, the trip distance, the forecourt —
/// and saves it exactly as its own fuel screen would.
public struct WatchRefuel: Sendable, Equatable {
    public var litres: Double
    public var pricePerLitre: Double
    /// `"E5"` / `"E10"` — `FuelGrade`'s raw value, kept a string on the wire.
    public var grade: String
    public var filledToBrim: Bool
    /// The bike's own odometer as read at the pump, when the rider confirmed one.
    public var odometerKm: Double?

    public init(
        litres: Double, pricePerLitre: Double, grade: String, filledToBrim: Bool,
        odometerKm: Double? = nil
    ) {
        self.litres = litres
        self.pricePerLitre = pricePerLitre
        self.grade = grade
        self.filledToBrim = filledToBrim
        self.odometerKm = odometerKm
    }
}

// MARK: - Haptics

/// What the wrist should feel. Decided here, purely, from consecutive snapshots — the watch's
/// World only ever *plays* one of these; it never decides.
public enum WatchHaptic: Sendable, Equatable {
    case indicatorOn
    /// One tick per snapshot while an indicator stays on — the wrist's blinker relay.
    case indicatorTick
    case indicatorOff
    case overSpeed
    case backUnderLimit
}

/// How many consecutive over-limit snapshots between repeat warnings. The first buzz is the
/// message; a buzz every second after it is a nag the wrist learns to ignore.
public let overSpeedRepeatSnapshots = 5

/// The haptics owed for one snapshot arriving after another.
///
/// `consecutiveOver` is the number of over-limit snapshots *before* this one, counted by the
/// caller's state — pure inputs, so every rule here is testable without a wrist.
public func watchHaptics(
    previous: WatchSnapshot?, current: WatchSnapshot, consecutiveOver: Int
) -> [WatchHaptic] {
    var haptics: [WatchHaptic] = []

    switch (previous?.indicator, current.indicator) {
    case (nil, .some): haptics.append(.indicatorOn)
    case let (.some(before), .some(now)) where before != now: haptics.append(.indicatorOn)
    case (.some, .some): haptics.append(.indicatorTick)
    case (.some, nil): haptics.append(.indicatorOff)
    case (nil, nil): break
    }

    let wasOver = previous?.overLimit ?? false
    if current.overLimit, !wasOver {
        haptics.append(.overSpeed)
    } else if current.overLimit, consecutiveOver % overSpeedRepeatSnapshots == 0 {
        // Still over after a stretch of silence: repeat, but on a slow clock.
        haptics.append(.overSpeed)
    } else if !current.overLimit, wasOver {
        haptics.append(.backUnderLimit)
    }

    return haptics
}

// MARK: - The wire

/// Snapshot and command as primitive dictionaries — WatchConnectivity's own currency.
///
/// A hand-written codec, like the database's column mapping and for the same reason: the domain
/// value is the interface, and how it crosses a process boundary is the boundary's business.
/// Missing keys read as absent values, so the two sides can ship at different versions without
/// either crashing the other.
public enum WatchWire {
    public static func dictionary(from snapshot: WatchSnapshot) -> [String: any Sendable] {
        var wire: [String: any Sendable] = [
            "headingDegrees": snapshot.headingDegrees,
            "limitIsNational": snapshot.limitIsNational,
            "limitIsAssumed": snapshot.limitIsAssumed,
            "overLimit": snapshot.overLimit,
            "journeyActive": snapshot.journeyActive,
            "routeLatitudes": snapshot.routeLatitudes,
            "routeLongitudes": snapshot.routeLongitudes,
            "frontTyreWarn": snapshot.frontTyreWarn,
            "rearTyreWarn": snapshot.rearTyreWarn,
            "indimateConnected": snapshot.indimateConnected,
            "cardoConnected": snapshot.cardoConnected,
            "replaying": snapshot.replaying
        ]
        snapshot.mph.map { wire["mph"] = $0 }
        snapshot.limitMPH.map { wire["limitMPH"] = $0 }
        snapshot.limitText.map { wire["limitText"] = $0 }
        snapshot.roadLabel.map { wire["roadLabel"] = $0 }
        snapshot.indicator.map { wire["indicator"] = $0 }
        snapshot.latitude.map { wire["latitude"] = $0 }
        snapshot.longitude.map { wire["longitude"] = $0 }
        snapshot.nextTurnMetres.map { wire["nextTurnMetres"] = $0 }
        snapshot.sinceFillKm.map { wire["sinceFillKm"] = $0 }
        snapshot.suggestedOdometerKm.map { wire["suggestedOdometerKm"] = $0 }
        snapshot.weatherCelsius.map { wire["weatherCelsius"] = $0 }
        snapshot.weatherHumidity.map { wire["weatherHumidity"] = $0 }
        snapshot.frontTyrePSI.map { wire["frontTyrePSI"] = $0 }
        snapshot.frontTyreCelsius.map { wire["frontTyreCelsius"] = $0 }
        snapshot.rearTyrePSI.map { wire["rearTyrePSI"] = $0 }
        snapshot.rearTyreCelsius.map { wire["rearTyreCelsius"] = $0 }
        snapshot.altitudeMetres.map { wire["altitudeMetres"] = $0 }
        snapshot.ignitionOn.map { wire["ignitionOn"] = $0 }
        return wire
    }

    public static func snapshot(from wire: [String: Any]) -> WatchSnapshot {
        WatchSnapshot(
            mph: wire["mph"] as? Double,
            limitMPH: wire["limitMPH"] as? Double,
            limitText: wire["limitText"] as? String,
            limitIsNational: wire["limitIsNational"] as? Bool ?? false,
            limitIsAssumed: wire["limitIsAssumed"] as? Bool ?? false,
            overLimit: wire["overLimit"] as? Bool ?? false,
            roadLabel: wire["roadLabel"] as? String,
            indicator: wire["indicator"] as? String,
            latitude: wire["latitude"] as? Double,
            longitude: wire["longitude"] as? Double,
            headingDegrees: wire["headingDegrees"] as? Double ?? 0,
            routeLatitudes: wire["routeLatitudes"] as? [Double] ?? [],
            routeLongitudes: wire["routeLongitudes"] as? [Double] ?? [],
            nextTurnMetres: wire["nextTurnMetres"] as? Double,
            sinceFillKm: wire["sinceFillKm"] as? Double,
            suggestedOdometerKm: wire["suggestedOdometerKm"] as? Double,
            journeyActive: wire["journeyActive"] as? Bool ?? false,
            weatherCelsius: wire["weatherCelsius"] as? Double,
            weatherHumidity: wire["weatherHumidity"] as? Double,
            frontTyrePSI: wire["frontTyrePSI"] as? Double,
            frontTyreCelsius: wire["frontTyreCelsius"] as? Double,
            frontTyreWarn: wire["frontTyreWarn"] as? Bool ?? false,
            rearTyrePSI: wire["rearTyrePSI"] as? Double,
            rearTyreCelsius: wire["rearTyreCelsius"] as? Double,
            rearTyreWarn: wire["rearTyreWarn"] as? Bool ?? false,
            altitudeMetres: wire["altitudeMetres"] as? Double,
            ignitionOn: wire["ignitionOn"] as? Bool,
            indimateConnected: wire["indimateConnected"] as? Bool ?? false,
            cardoConnected: wire["cardoConnected"] as? Bool ?? false,
            replaying: wire["replaying"] as? Bool ?? false
        )
    }

    public static func dictionary(from refuel: WatchRefuel) -> [String: any Sendable] {
        var wire: [String: any Sendable] = [
            "command": "refuel",
            "litres": refuel.litres,
            "pricePerLitre": refuel.pricePerLitre,
            "grade": refuel.grade,
            "filledToBrim": refuel.filledToBrim
        ]
        refuel.odometerKm.map { wire["odometerKm"] = $0 }
        return wire
    }

    /// `nil` when the message is not a refuel — an unknown command from a newer watch is ignored,
    /// never crashed on.
    public static func refuel(from wire: [String: Any]) -> WatchRefuel? {
        guard
            wire["command"] as? String == "refuel",
            let litres = wire["litres"] as? Double,
            let price = wire["pricePerLitre"] as? Double,
            let grade = wire["grade"] as? String,
            let brim = wire["filledToBrim"] as? Bool
        else { return nil }
        return WatchRefuel(
            litres: litres, pricePerLitre: price, grade: grade, filledToBrim: brim,
            odometerKm: wire["odometerKm"] as? Double
        )
    }
}

// MARK: - Route thinning for the wire

/// At most `maxPoints` of a route survive onto the wire. The watch draws a line a few dozen
/// pixels long; three thousand coordinates over Bluetooth would be all cost and no picture.
public func watchRouteSample(
    _ shape: [Coordinate], maxPoints: Int = 60
) -> (latitudes: [Double], longitudes: [Double]) {
    guard shape.count > maxPoints, maxPoints > 1 else {
        return (shape.map(\.latitude.rawValue), shape.map(\.longitude.rawValue))
    }
    let stride = Double(shape.count - 1) / Double(maxPoints - 1)
    let sampled = (0..<maxPoints).compactMap { index in
        shape[safe: Int((Double(index) * stride).rounded())]
    }
    return (sampled.map(\.latitude.rawValue), sampled.map(\.longitude.rawValue))
}
