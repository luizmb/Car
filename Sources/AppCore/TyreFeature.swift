import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftUI

// MARK: - TyreFeature

/// Tyre pressure and temperature from the FOBO sensors, with spoken warnings.
///
/// Entirely passive — the sensors broadcast everything in their advertisement, so nothing is ever
/// connected to. This rides on a scan already running for the head unit, which makes it the
/// cheapest safety feature available: a slow puncture announced through the helmet at speed is a
/// materially different outcome from finding it at the next petrol stop.
public enum TyreFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        /// Latest reading per wheel. Absent until a sensor is heard from — these sleep between
        /// broadcasts, so a cold start genuinely has nothing to show, which is not the same as zero.
        public var readings: [TyrePosition: TyreReading] = [:]
        public init() {}
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case reading(TyreReading)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        /// Already matched to a wheel and graded — the other bike's sensors are filtered out
        /// upstream, so the reducer needs no configuration and stays pure.
        public let tyreReadings: @Sendable () -> Publisher<TyreReading, Never>
        public let speak: @Sendable (String) -> Publisher<Void, Never>
        public let formatPressure: @Sendable (PSI) -> String
        public let formatTemperature: @Sendable (Celsius) -> String

        public init(
            tyreReadings: @escaping @Sendable () -> Publisher<TyreReading, Never>,
            speak: @escaping @Sendable (String) -> Publisher<Void, Never>,
            formatPressure: @escaping @Sendable (PSI) -> String,
            formatTemperature: @escaping @Sendable (Celsius) -> String
        ) {
            self.tyreReadings = tyreReadings
            self.speak = speak
            self.formatPressure = formatPressure
            self.formatTemperature = formatTemperature
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        commands() <> supervisor()
    }

    private static func commands() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            guard case let .reading(reading) = action else { return .doNothing }
            let position = reading.position
            let previous = context.stateBefore?.readings[position]?.status

            return .reduce { $0.readings[position] = reading }
                .produce { ctx in
                    // Speak only when the status *changes* into a problem. Repeating "front tyre
                    // low" on every broadcast for a whole ride would train the rider to ignore it.
                    guard previous != reading.status, reading.status != .ok else { return .empty }
                    let problem = reading.status == .low ? "pressure low" : "pressure high"
                    return ctx.environment.speak("\(position.spokenLabel) tyre \(problem)")
                        |> Effect.fireAndForget
                }
        }
    }

    /// Always on: the scan is passive and filtered to one service, and tyres matter whether or not
    /// the bike is running.
    private static func supervisor() -> Behavior<Action, State, Environment> {
        .supervise { _ in
            Supervision { env in
                [env.tyreReadings().asChannel(id: "tyres", Action.reading)]
            }
        }
    }
}

extension TyreFeature: HasBehavior {}

// MARK: - View

struct TyreStatusView: View {
    let viewStore: ViewStore<TyreFeature.State, TyreFeature.Action>
    let formatPressure: @Sendable (PSI) -> String
    let formatTemperature: @Sendable (Celsius) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(TyrePosition.allCases, id: \.self) { position in
                row(position)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fixedSize()
    }

    private func row(_ position: TyrePosition) -> some View {
        let reading = viewStore.state.readings[position]
        return HStack(spacing: 5) {
            Text(position.shortLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let reading {
                Text(formatPressure(reading.telemetry.psi))
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(colour(reading.status))
                Text(formatTemperature(reading.telemetry.temperature))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                // These sleep between broadcasts, so "not heard yet" is a real state and must not
                // be rendered as zero.
                Text("—")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colour(_ status: TyreStatus?) -> Color {
        switch status {
        case .low, .high: .red
        case .ok:         .green
        case nil:         .secondary
        }
    }
}

extension TyreFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        TyreStatusView(
            viewStore: ViewStore(store),
            formatPressure: environment.formatPressure,
            formatTemperature: environment.formatTemperature
        )
    }
}
