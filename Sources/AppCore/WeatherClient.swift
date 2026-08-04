import AppDomain
import Core
import FP
import Foundation
import NetworkClient
import ReactiveConcurrency

/// One Open-Meteo lookup.
///
/// Failure drops the event rather than substituting a default, for the same reason the Overpass
/// client does: a fabricated 15 °C would silently poison the consumption model, whereas a gap is
/// merely a gap. Retries twice first, since a transient failure on a bike is usually just signal.
func makeWeatherFetch(
    httpClient: HTTPClient,
    decoder: DataDecoder<OpenMeteoResponse>
) -> @Sendable (Latitude, Longitude) -> Publisher<WeatherObservation, Never> {
    { latitude, longitude in
        httpClient(openMeteoRequest(latitude: latitude, longitude: longitude))
            .validateStatusCode()
            .decode(using: decoder)
            .retry(2)
            .catch { _ in Publisher<OpenMeteoResponse, Never>.empty() }
            .compactMap(parseWeather)
    }
}
