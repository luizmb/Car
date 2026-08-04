import AppDomain
import FP
import Foundation

// MARK: - Inputs

/// Everything the briefing can speak about, gathered into one value so the composition is pure and
/// testable without a bike.
public struct FlightPlanInputs: Sendable, Equatable {
    public var ignitionOn: Bool?
    public var indimateConnected: Bool
    public var cardoConnected: Bool
    public var tyres: [TyrePosition: TyreReading]
    public var weather: WeatherObservation?
    public var road: String?
    public var speedLimit: String?
    public var bikeMillivolts: Int?
    /// 0–1. The phone *is* the instrument cluster, so setting off at 15% matters more than anything
    /// else in the briefing.
    public var phoneBattery: Double?
    public var lowPowerMode: Bool
    /// Horizontal accuracy in metres. The speedometer is the app's whole purpose; a bad fix means
    /// it will not work.
    public var gpsAccuracy: Double?

    public init(
        ignitionOn: Bool? = nil, indimateConnected: Bool = false, cardoConnected: Bool = false,
        tyres: [TyrePosition: TyreReading] = [:], weather: WeatherObservation? = nil,
        road: String? = nil, speedLimit: String? = nil, bikeMillivolts: Int? = nil,
        phoneBattery: Double? = nil, lowPowerMode: Bool = false, gpsAccuracy: Double? = nil
    ) {
        self.ignitionOn = ignitionOn
        self.indimateConnected = indimateConnected
        self.cardoConnected = cardoConnected
        self.tyres = tyres
        self.weather = weather
        self.road = road
        self.speedLimit = speedLimit
        self.bikeMillivolts = bikeMillivolts
        self.phoneBattery = phoneBattery
        self.lowPowerMode = lowPowerMode
        self.gpsAccuracy = gpsAccuracy
    }
}

// MARK: - Composition

/// Builds the spoken pre-ride briefing.
///
/// **Report by exception.** Problems first and in full, then a single line for everything nominal.
/// Reading every field aloud produces a forty-second monologue the rider learns to ignore — the
/// same failure mode as repeating a tyre warning on every broadcast. Three seconds when all is
/// well; as long as it takes when it is not.
///
/// It lands during the two-minute choked warm-up, so there is time — but time available is not a
/// reason to use it.
public func composeFlightPlan(_ inputs: FlightPlanInputs) -> String {
    var problems: [String] = []
    var facts: [String] = []

    // ---- Problems, roughly in order of how badly they end a ride ----

    if let battery = inputs.phoneBattery, battery < 0.25 {
        problems.append("Phone battery \(Int(battery * 100)) percent")
    }
    if inputs.lowPowerMode {
        // Not cosmetic: Low Power Mode throttles the background work location and Bluetooth
        // depend on, so it can silently disable most of the app mid-ride.
        problems.append("Low power mode is on, background tracking may stop")
    }

    for position in TyrePosition.allCases {
        guard let reading = inputs.tyres[position] else {
            // Absent is not fine. These sensors sleep, so "no reading" is a real state and saying
            // nothing would be indistinguishable from a healthy tyre.
            problems.append("No \(position.spokenLabel) tyre reading")
            continue
        }
        if reading.status != .ok {
            let psi = Iso<KPa, PSI>.convert.get(reading.telemetry.pressure).rawValue
            problems.append(
                "\(position.spokenLabel) tyre \(reading.status == .low ? "low" : "high") at \(Int(psi.rounded())) psi"
            )
        }
    }

    if !inputs.indimateConnected {
        // Actionable, and the rider's own habit: flicking an indicator with the keys on wakes it.
        problems.append("Indimate not connected, flick an indicator")
    }
    if let accuracy = inputs.gpsAccuracy, accuracy > 20 {
        problems.append("GPS accuracy \(Int(accuracy)) metres")
    }
    if let millivolts = inputs.bikeMillivolts, millivolts < 12_000 {
        problems.append("Bike battery \(String(format: "%.1f", Double(millivolts) / 1000)) volts")
    }

    // ---- Facts, only the ones worth hearing ----

    let pressures = TyrePosition.allCases.compactMap { position -> String? in
        guard let reading = inputs.tyres[position], reading.status == .ok else { return nil }
        let psi = Iso<KPa, PSI>.convert.get(reading.telemetry.pressure).rawValue
        return "\(position.spokenLabel) \(Int(psi.rounded()))"
    }
    if !pressures.isEmpty { facts.append("tyres " + pressures.joined(separator: ", ")) }

    if let millivolts = inputs.bikeMillivolts, millivolts >= 12_000 {
        facts.append("battery \(String(format: "%.1f", Double(millivolts) / 1000)) volts")
    }
    if let weather = inputs.weather {
        facts.append("\(Int(weather.temperature.rawValue.rounded())) degrees")
        // Only when it is strong enough to change how the bike behaves.
        if weather.windSpeed.rawValue >= 5 {
            facts.append("wind \(Int(weather.windSpeed.rawValue.rounded())) metres per second")
        }
    }
    inputs.speedLimit.map { facts.append($0) }
    inputs.road.map { facts.append("on \($0)") }

    if problems.isEmpty {
        return (["All nominal"] + facts).joined(separator: ", ") + "."
    }
    return (problems + (facts.isEmpty ? [] : ["Otherwise"] + facts)).joined(separator: ", ") + "."
}
