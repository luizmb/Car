import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftUI

// MARK: - MotionFeature

/// Barometer, inertial motion, and iOS's activity classification.
///
/// Its real job today is **collection**: everything it receives becomes an action, and every action
/// reaches the ride log, so a real ride produces the raw material for working out offline what is
/// actually inferable from a phone in a jacket pocket. The on-screen values are a side effect of
/// that, not the point.
///
/// Nothing here is interpreted beyond rotation-invariant scalars. Lean, braking and cornering all
/// need fusing with GPS to separate — and that decision belongs offline, against real data, not in
/// an app that has to keep working at 70mph.
public enum MotionFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        public var barometer: BarometricSample?
        public var motion: MotionSample?
        public var activity: MotionActivitySample?

        /// Peak `effort` seen this session, in g. A crude high-water mark for how hard the ride
        /// has been — worth keeping because the peak is exactly what a 4 Hz sample stream loses
        /// once each sample scrolls past.
        public var peakEffort: Double = 0

        public init() {}
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case barometer(BarometricSample)
        case motion(MotionSample)
        case activity(MotionActivitySample)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let barometer: @Sendable () -> Publisher<BarometricSample, Never>
        public let motion: @Sendable () -> Publisher<MotionSample, Never>
        public let activity: @Sendable () -> Publisher<MotionActivitySample, Never>

        public init(
            barometer: @escaping @Sendable () -> Publisher<BarometricSample, Never>,
            motion: @escaping @Sendable () -> Publisher<MotionSample, Never>,
            activity: @escaping @Sendable () -> Publisher<MotionActivitySample, Never>
        ) {
            self.barometer = barometer
            self.motion = motion
            self.activity = activity
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        commands() <> supervisor()
    }

    private static func commands() -> Behavior<Action, State, Environment> {
        .reduce { action, state in
            switch action {
            case let .barometer(sample):
                state.barometer = sample
            case let .motion(sample):
                state.motion = sample
                state.peakEffort = max(state.peakEffort, sample.effort)
            case let .activity(sample):
                state.activity = sample
            }
        }
    }

    private static func supervisor() -> Behavior<Action, State, Environment> {
        .supervise { _ in
            Supervision { env in
                [
                    env.barometer().asChannel(id: "barometer", Action.barometer),
                    env.motion().asChannel(id: "motion", Action.motion),
                    env.activity().asChannel(id: "activity", Action.activity)
                ]
            }
        }
    }
}

extension MotionFeature: HasBehavior {}

// MARK: - View

struct MotionStatusView: View {
    let viewStore: ViewStore<MotionFeature.State, MotionFeature.Action>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let barometer = viewStore.state.barometer {
                row("Air:", String(format: "%.1f kPa", barometer.pressure.rawValue), .primary)
            }
            if let motion = viewStore.state.motion {
                // Labelled "lean?" rather than "lean" on purpose: the derivation assumes a steady
                // turn, so braking and bumps inflate it. It is a candidate to validate offline
                // against GPS-derived lateral acceleration, not a number to trust yet.
                let lean = motion.leanEstimate.map { String(format: "%.0f°?", $0) } ?? "—"
                row("Lean:", lean, .primary)
                row("Peak g:", String(format: "%.2f", viewStore.state.peakEffort), .secondary)
            }
            if let activity = viewStore.state.activity {
                row("Motion:", "\(activity.activity) (\(activity.confidence))", .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fixedSize()
    }

    private func row(_ label: String, _ value: String, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(colour)
        }
    }
}

extension MotionFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        MotionStatusView(viewStore: ViewStore(store))
    }
}
