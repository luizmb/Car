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
    /// Distance since the last fill and what is left before reserve, already worded.
    ///
    /// **Always spoken, even under `.exceptions`.** Every other line here is reported only when it
    /// is wrong, because a healthy tyre needs no mention. Fuel is the opposite: this bike has no
    /// gauge, no low-fuel light and a reserve that means stripping the carburettor, so the rider
    /// sets off in the dark about it *every single time*. Being told is the normal case, not the
    /// exception — it is the reason the fuel feature exists at all.
    public var fuel: String?
    /// Maintenance lines with something to say — already report-by-exception at the source, so a
    /// healthy schedule contributes nothing here rather than a reassurance nobody asked for.
    public var maintenance: [String]

    public init(
        ignitionOn: Bool? = nil, indimateConnected: Bool = false, cardoConnected: Bool = false,
        tyres: [TyrePosition: TyreReading] = [:], weather: WeatherObservation? = nil,
        road: String? = nil, speedLimit: String? = nil, bikeMillivolts: Int? = nil,
        phoneBattery: Double? = nil, lowPowerMode: Bool = false, gpsAccuracy: Double? = nil,
        fuel: String? = nil, maintenance: [String] = []
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
        self.fuel = fuel
        self.gpsAccuracy = gpsAccuracy
        self.maintenance = maintenance
    }
}

// MARK: - Verbosity

public enum FlightPlanVerbosity: Sendable, Equatable {
    /// Problems in full, then one line if all is well. The automatic pre-ride briefing.
    case exceptions
    /// Every provider speaks, including the ones with nothing to report.
    ///
    /// This is a **diagnostic**, not a nicer briefing. Under `.exceptions` a provider that is
    /// silently broken — weather never fetched, a sensor never wired — is indistinguishable from
    /// one with nothing to say. Here every source says something or explicitly says it has no data,
    /// so silence identifies exactly which link is dead.
    case full
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
public func composeFlightPlan(
    _ inputs: FlightPlanInputs,
    verbosity: FlightPlanVerbosity = .exceptions
) -> [String] {
    verbosity == .full ? fullReport(inputs) : exceptionReport(inputs)
}

/// Returned as segments rather than one string so the speech layer can pause between them. A
/// continuous forty-second sentence is far harder to follow through a helmet than the same words
/// with a beat between each source.
private func exceptionReport(_ inputs: FlightPlanInputs) -> [String] {
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
            problems.append(
                "\(position.spokenLabel) tyre \(reading.status == .low ? "low" : "high") at \(psi(reading)) psi"
            )
        }
    }

    if !inputs.indimateConnected {
        problems.append("Indimate not connected, flick an indicator")
    }
    if let accuracy = inputs.gpsAccuracy, accuracy > 20 {
        problems.append("GPS accuracy \(Int(accuracy)) metres")
    }
    if let millivolts = inputs.bikeMillivolts, millivolts < 12_000 {
        problems.append("Bike battery \(volts(millivolts)) volts")
    }
    // After the ride-enders, before the facts: a chain that needs oil ends no ride today, but it
    // is the kind of thing a rider fixes only if told while still in the garage.
    problems.append(contentsOf: inputs.maintenance)

    // ---- Facts, only the ones worth hearing ----

    let pressures = TyrePosition.allCases.compactMap { position -> String? in
        guard let reading = inputs.tyres[position], reading.status == .ok else { return nil }
        return "\(position.spokenLabel) \(psi(reading))"
    }
    if !pressures.isEmpty { facts.append("tyres " + pressures.joined(separator: ", ")) }

    if let millivolts = inputs.bikeMillivolts, millivolts >= 12_000 {
        facts.append("battery \(volts(millivolts)) volts")
    }
    if let weather = inputs.weather {
        facts.append("\(Int(weather.temperature.rawValue.rounded())) degrees")
        if weather.windSpeed.rawValue >= 5 {
            facts.append("wind \(Int(weather.windSpeed.rawValue.rounded())) metres per second")
        }
    }
    inputs.speedLimit.map { facts.append($0) }
    inputs.road.map { facts.append("on \($0)") }

    // Fuel is a segment of its own rather than another fact, so it gets a beat to itself instead of
    // being buried mid-list — and it survives both paths, which no other fact does.
    let fuel = inputs.fuel.map { [$0] } ?? []

    if problems.isEmpty {
        return [(["All nominal"] + facts).joined(separator: ", ") + "."] + fuel
    }
    return problems.map { $0 + "." }
        + (facts.isEmpty ? [] : ["Otherwise " + facts.joined(separator: ", ") + "."])
        + fuel
}

/// One segment per provider, each stating a value **or** explicitly stating it has none.
///
/// The explicit "no data" lines are the point. A provider that has quietly failed produces the same
/// silence as one working perfectly under `.exceptions`; here it names itself.
private func fullReport(_ inputs: FlightPlanInputs) -> [String] {
    var segments: [String] = []

    switch inputs.ignitionOn {
    case .some(true):  segments.append("Ignition on.")
    case .some(false): segments.append("Ignition off.")
    case nil:          segments.append("Ignition unknown.")
    }

    segments.append(inputs.indimateConnected ? "Indimate connected." : "Indimate not connected.")
    segments.append(inputs.cardoConnected ? "Cardo connected." : "Cardo not connected.")

    for position in TyrePosition.allCases {
        guard let reading = inputs.tyres[position] else {
            segments.append("No \(position.spokenLabel) tyre reading.")
            continue
        }
        let state = reading.status == .ok ? "" : reading.status == .low ? ", low" : ", high"
        segments.append(
            "\(position.spokenLabel.capitalized) tyre \(psi(reading)) psi, "
            + "\(Int(reading.telemetry.temperature.rawValue.rounded())) degrees\(state)."
        )
    }

    if let millivolts = inputs.bikeMillivolts {
        segments.append("Bike battery \(volts(millivolts)) volts.")
    } else {
        segments.append("No bike battery reading.")
    }

    if let weather = inputs.weather {
        segments.append(
            "Air \(Int(weather.temperature.rawValue.rounded())) degrees, "
            + "\(Int(weather.humidity.rounded())) percent humidity, "
            + "density \(String(format: "%.2f", weather.airDensity))."
        )
        segments.append(
            "Wind \(Int(weather.windSpeed.rawValue.rounded())) metres per second "
            + "from \(Int(weather.windDirection.rawValue.rounded())) degrees."
        )
    } else {
        segments.append("No weather data.")
    }

    if let road = inputs.road {
        segments.append("Road \(road)\(inputs.speedLimit.map { ", \($0)" } ?? "").")
    } else if let limit = inputs.speedLimit {
        segments.append("\(limit), road unknown.")
    } else {
        segments.append("No road data.")
    }

    if let accuracy = inputs.gpsAccuracy {
        segments.append("GPS accurate to \(Int(accuracy)) metres.")
    } else {
        segments.append("No GPS accuracy reading.")
    }

    // The diagnostic promise: every source says something, so a silently broken provider names
    // itself by its absence.
    if inputs.maintenance.isEmpty {
        segments.append("No maintenance due.")
    } else {
        segments.append(contentsOf: inputs.maintenance.map { $0 + "." })
    }

    if let battery = inputs.phoneBattery {
        segments.append("Phone battery \(Int(battery * 100)) percent.")
    } else {
        segments.append("No phone battery reading.")
    }
    if inputs.lowPowerMode { segments.append("Low power mode is on.") }

    segments.append(inputs.fuel ?? "Fuel: nothing recorded yet.")
    return segments
}

private func psi(_ reading: TyreReading) -> Int {
    Int(Iso<KPa, PSI>.convert.get(reading.telemetry.pressure).rawValue.rounded())
}

private func volts(_ millivolts: Int) -> String {
    String(format: "%.1f", Double(millivolts) / 1000)
}
