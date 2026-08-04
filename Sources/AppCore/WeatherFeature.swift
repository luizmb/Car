import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftUI

// MARK: - WeatherFeature

/// Conditions, refreshed as you ride.
///
/// Refetches on **either** an hour elapsing *or* 25 km travelled. Time alone is not enough — a long
/// ride crosses real weather gradients faster than the clock does, and the fuel model is fed by
/// conditions along the route rather than conditions at the start.
public enum WeatherFeature {

    /// Distance that triggers a refetch regardless of the clock.
    static let refreshDistance: Double = 25_000   // metres

    // MARK: State

    public struct State: Sendable, Equatable {
        public var latest: WeatherObservation?
        /// Where the last successful fetch was made, so distance-triggered refresh can be measured.
        public var fetchedAt: Latitude?
        public var fetchedAtLongitude: Longitude?
        public var lastFetchTime: Date?
        public init() {}
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        /// Position moved. Carries the time so the reducer stays pure — no ambient clock.
        case located(Latitude, Longitude, Date)
        case observed(WeatherObservation, Latitude, Longitude, Date)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let fetchWeather: @Sendable (Latitude, Longitude) -> Publisher<WeatherObservation, Never>

        public init(
            fetchWeather: @escaping @Sendable (Latitude, Longitude) -> Publisher<WeatherObservation, Never>
        ) {
            self.fetchWeather = fetchWeather
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {
            case let .located(latitude, longitude, now):
                let state = context.stateBefore
                guard shouldFetch(state: state, latitude: latitude, longitude: longitude, now: now) else {
                    return .doNothing
                }
                return .produce { ctx in
                    ctx.environment.fetchWeather(latitude, longitude)
                        .asEffect { Action.observed($0, latitude, longitude, now) }
                }

            case let .observed(observation, latitude, longitude, now):
                return .reduce {
                    $0.latest = observation
                    $0.fetchedAt = latitude
                    $0.fetchedAtLongitude = longitude
                    $0.lastFetchTime = now
                }
            }
        }
    }

    /// Pure, so the refresh policy is testable without a network or a clock.
    static func shouldFetch(
        state: State?, latitude: Latitude, longitude: Longitude, now: Date
    ) -> Bool {
        guard
            let state,
            let last = state.lastFetchTime,
            let previousLatitude = state.fetchedAt,
            let previousLongitude = state.fetchedAtLongitude
        else { return true }   // nothing yet — always fetch

        if now.timeIntervalSince(last) >= 3600 { return true }

        let metres = haversine(
            previousLatitude, previousLongitude, latitude, longitude
        )
        return metres >= refreshDistance
    }
}

extension WeatherFeature: HasBehavior {}

/// Great-circle distance in metres.
func haversine(_ lat1: Latitude, _ lon1: Longitude, _ lat2: Latitude, _ lon2: Longitude) -> Double {
    let earthRadius = 6_371_000.0
    let phi1 = lat1.rawValue * .pi / 180
    let phi2 = lat2.rawValue * .pi / 180
    let deltaPhi = (lat2.rawValue - lat1.rawValue) * .pi / 180
    let deltaLambda = (lon2.rawValue - lon1.rawValue) * .pi / 180
    let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
        + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
    return 2 * earthRadius * asin(min(1, a.squareRoot()))
}

// MARK: - View

struct WeatherStatusView: View {
    let viewStore: ViewStore<WeatherFeature.State, WeatherFeature.Action>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let w = viewStore.state.latest {
                row("Air:", String(format: "%.0f°C  %.0f%%  %.0f hPa", w.temperature.rawValue, w.humidity, w.pressure.rawValue * 10))
                // Density is the number that actually matters to a carb, so it is shown rather
                // than left implicit in the three inputs above.
                row("Density:", String(format: "%.3f kg/m³", w.airDensity))
                row("Wind:", String(format: "%.1f m/s from %.0f°", w.windSpeed.rawValue, w.windDirection.rawValue))
            } else {
                row("Weather:", "—")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fixedSize()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption2.bold().monospacedDigit())
        }
    }
}

extension WeatherFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        WeatherStatusView(viewStore: ViewStore(store))
    }
}
