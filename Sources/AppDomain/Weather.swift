import FP
import FPMacros
import Foundation

// MARK: - Observation

/// Conditions at a point in space and time.
///
/// Every field is here because it drives fuel consumption on a carburetted bike, not because it is
/// interesting to display. Temperature and pressure give **air density**, which is the actual causal
/// driver of how rich a carb runs; wind gives the headwind component, which sets true airspeed and
/// therefore drag.
public struct WeatherObservation: Sendable, Equatable {
    public let temperature: Celsius
    /// Relative humidity, 0–100. Lowers density further, since water vapour is lighter than air.
    public let humidity: Double
    public let pressure: KPa
    public let windSpeed: MPS
    /// Meteorological convention: the direction the wind blows **from**, degrees clockwise from north.
    public let windDirection: Course

    public init(
        temperature: Celsius, humidity: Double, pressure: KPa,
        windSpeed: MPS, windDirection: Course
    ) {
        self.temperature = temperature
        self.humidity = humidity
        self.pressure = pressure
        self.windSpeed = windSpeed
        self.windDirection = windDirection
    }
}

// MARK: - Derived quantities

public extension WeatherObservation {
    /// Air density in kg/m³, humidity included.
    ///
    /// Dry air alone is `p / (R·T)`; moist air is lighter, because a water molecule (18 g/mol)
    /// displaces the nitrogen and oxygen it replaces (~29 g/mol). Ignoring humidity would
    /// under-state the effect on a warm damp day, which in Britain is most of them.
    var airDensity: Double {
        let kelvin = temperature.rawValue + 273.15
        // Saturation vapour pressure, Tetens' approximation, in hPa.
        let saturation = 6.1078 * pow(10, (7.5 * temperature.rawValue) / (237.3 + temperature.rawValue))
        let vapourPressure = saturation * (humidity / 100) * 100        // → Pa
        let totalPressure = pressure.rawValue * 1000                     // kPa → Pa
        let dryPressure = totalPressure - vapourPressure
        return dryPressure / (287.058 * kelvin) + vapourPressure / (461.495 * kelvin)
    }

    /// The headwind component along a heading, in m/s. Positive is a headwind, negative a tailwind.
    ///
    /// Wind direction is where the wind comes *from*, so a wind from the north hitting a
    /// northbound rider is a headwind — hence `cos(windDirection − course)` with no sign flip.
    ///
    /// This is what makes wind usable without adding a dimension to the model: combined with ground
    /// speed it gives **airspeed**, and bucketing consumption by airspeed instead of ground speed
    /// folds wind into the structure that already exists.
    func headwind(course: Course) -> MPS {
        let radians = (windDirection.rawValue - course.rawValue) * .pi / 180
        return MPS(windSpeed.rawValue * cos(radians))
    }

    /// Ground speed plus headwind — the speed the air sees, which is what drag actually responds to.
    func airspeed(groundSpeed: MPS, course: Course) -> MPS {
        MPS(groundSpeed.rawValue + headwind(course: course).rawValue)
    }
}

// MARK: - Open-Meteo

/// Builds the request. Open-Meteo needs no API key and no account, which is why it was chosen over
/// WeatherKit — and, more importantly, it has a historical archive, so weather can be backfilled
/// onto rides recorded before this existed.
public func openMeteoRequest(latitude: Latitude, longitude: Longitude) -> URLRequest {
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    components.queryItems = [
        .init(name: "latitude", value: String(latitude.rawValue)),
        .init(name: "longitude", value: String(longitude.rawValue)),
        .init(name: "current", value: "temperature_2m,relative_humidity_2m,surface_pressure,wind_speed_10m,wind_direction_10m"),
        // Metres per second rather than the default km/h, so it composes with MPS directly.
        .init(name: "wind_speed_unit", value: "ms")
    ]
    // Fixed template over numeric values — cannot fail to parse.
    return URLRequest(url: components.url!)
}

public struct OpenMeteoResponse: Decodable, Sendable {
    public struct Current: Decodable, Sendable {
        public let temperature2m: Double?
        public let relativeHumidity2m: Double?
        public let surfacePressure: Double?
        public let windSpeed10m: Double?
        public let windDirection10m: Double?

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case relativeHumidity2m = "relative_humidity_2m"
            case surfacePressure = "surface_pressure"
            case windSpeed10m = "wind_speed_10m"
            case windDirection10m = "wind_direction_10m"
        }
    }
    public let current: Current?
}

/// Returns `nil` rather than substituting defaults for missing fields. A fabricated 15 °C would
/// silently poison the consumption model; an absent observation is merely a gap.
public func parseWeather(_ response: OpenMeteoResponse) -> WeatherObservation? {
    guard
        let c = response.current,
        let temperature = c.temperature2m,
        let humidity = c.relativeHumidity2m,
        let pressure = c.surfacePressure,
        let windSpeed = c.windSpeed10m,
        let windDirection = c.windDirection10m
    else { return nil }

    return WeatherObservation(
        temperature: Celsius(temperature),
        humidity: humidity,
        // Open-Meteo reports hPa; 1 hPa = 0.1 kPa.
        pressure: KPa(pressure / 10),
        windSpeed: MPS(windSpeed),
        windDirection: Course(windDirection)
    )
}
