import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftUI

// MARK: - ChigeeFeature

/// Ignition state, inferred from the CarPlay head unit.
///
/// The unit is relayed by the ignition, so its radio dies with the keys — which makes it the only
/// dependable bike-on signal on this bike. Indimate cannot serve: it is triggered by the indicator
/// stalks, not by power, so it stays invisible until the rider first indicates. The Cardo cannot
/// either: it is a helmet, and helmets get worn without the bike running.
///
/// This says nothing about the *engine*. With a two-minute choked warm-up, that distinction does
/// not matter for anything we do with it.
public enum ChigeeFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        /// `nil` until the first observation — genuinely unknown, as distinct from off.
        public var isIgnitionOn: Bool?
        public init() {}
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case event(ChigeeEvent)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let chigeeEvents: @Sendable () -> Publisher<ChigeeEvent, Never>

        public init(chigeeEvents: @escaping @Sendable () -> Publisher<ChigeeEvent, Never>) {
            self.chigeeEvents = chigeeEvents
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        commands() <> supervisor()
    }

    private static func commands() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            guard case let .event(event) = action else { return .doNothing }
            switch event {
            case .present:
                guard context.stateBefore?.isIgnitionOn != true else { return .doNothing }
                return .reduce { $0.isIgnitionOn = true }
            case .absent:
                guard context.stateBefore?.isIgnitionOn != false else { return .doNothing }
                return .reduce { $0.isIgnitionOn = false }
            }
        }
    }

    /// Always on — this is what everything else will eventually be gated on, so it cannot itself
    /// be gated on anything.
    private static func supervisor() -> Behavior<Action, State, Environment> {
        .supervise { _ in
            Supervision { env in
                [env.chigeeEvents().asChannel(id: "chigee", Action.event)]
            }
        }
    }
}

extension ChigeeFeature: HasBehavior {}

// MARK: - View

struct ChigeeStatusView: View {
    let viewStore: ViewStore<ChigeeFeature.State, ChigeeFeature.Action>

    var body: some View {
        HStack(spacing: 5) {
            Text("Ignition:")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(colour)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fixedSize()
    }

    private var label: String {
        switch viewStore.state.isIgnitionOn {
        case .some(true):  "ON"
        case .some(false): "OFF"
        case nil:          "Unknown"
        }
    }

    private var colour: Color {
        switch viewStore.state.isIgnitionOn {
        case .some(true):  .green
        case .some(false): .red
        case nil:          .secondary
        }
    }
}

extension ChigeeFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        ChigeeStatusView(viewStore: ViewStore(store))
    }
}
