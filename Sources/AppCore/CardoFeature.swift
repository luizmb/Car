import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftUI

// MARK: - CardoFeature

/// Whether the helmet intercom is connected — the thing everything else is heard through.
///
/// Presence comes from the **audio route**, not from BLE. The garage capture settled that: the
/// Cardo produced a clean route change at every connect and disconnect, but advertised over BLE
/// only 8 times in six minutes, far too sparsely to treat as presence.
///
/// Battery is deliberately absent. The Cardo exposes no standard Battery Service — just a custom
/// binary protocol — and reading it would mean *connecting* over BLE, which is exactly what bonded
/// the CHIGEE and changed its behaviour. Not a risk worth taking uninvited with the device every
/// announcement depends on.
public enum CardoFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        public var headset: AudioOutput?
        /// Tag `0x51`. Battery or volume — see ``CardoEvent/level(_:)``. Shown either way.
        public var level: Int?
        public var isConnected: Bool { headset != nil }
        public init() {}
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case routeChanged(AudioRoute)
        case event(CardoEvent)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let audioRouteChanges: @Sendable () -> Publisher<AudioRoute, Never>
        public let cardoEvents: @Sendable () -> Publisher<CardoEvent, Never>

        public init(
            audioRouteChanges: @escaping @Sendable () -> Publisher<AudioRoute, Never>,
            cardoEvents: @escaping @Sendable () -> Publisher<CardoEvent, Never>
        ) {
            self.audioRouteChanges = audioRouteChanges
            self.cardoEvents = cardoEvents
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        commands() <> supervisor()
    }

    private static func commands() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {
            case let .routeChanged(route):
                let headset = route.bluetoothHeadset
                // Route notifications fire for reasons that leave the headset untouched — category
                // changes, other devices coming and going — so only act on a real difference.
                guard context.stateBefore?.headset != headset else { return .doNothing }
                return .reduce { $0.headset = headset }

            case let .event(.level(value)):
                guard context.stateBefore?.level != value else { return .doNothing }
                return .reduce { $0.level = value }

            case .event(.disconnected):
                // The reading is stale the moment the link drops; showing the last one would be
                // worse than showing nothing.
                return .reduce { $0.level = nil }

            case .event(.connected), .event(.raw):
                return .doNothing
            }
        }
    }

    /// Both channels stay open. Route monitoring is a single notification observer, and the BLE
    /// scan is filtered to one custom service — cheap enough that gating it would buy nothing.
    private static func supervisor() -> Behavior<Action, State, Environment> {
        .supervise { _ in
            Supervision { env in
                [
                    env.audioRouteChanges().asChannel(id: "audio-route", Action.routeChanged),
                    env.cardoEvents().asChannel(id: "cardo-ble", Action.event)
                ]
            }
        }
    }
}

extension CardoFeature: HasBehavior {}

// MARK: - View

struct CardoStatusView: View {
    let viewStore: ViewStore<CardoFeature.State, CardoFeature.Action>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text("Cardo:")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(viewStore.state.isConnected ? "Connected" : "Disconnected")
                    .font(.caption2.bold())
                    .foregroundStyle(viewStore.state.isConnected ? .green : .red)
            }

            // Tag 0x51 — battery or volume, undecided. Both are worth seeing, so it is labelled
            // honestly rather than guessed at.
            if let level = viewStore.state.level {
                HStack(spacing: 5) {
                    Text("Level:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(level)?")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }

            // The port name, so it is obvious *which* headset took the route when something
            // unexpected grabs it — AirPods in a pocket, a car stereo, the phone speaker.
            if let name = viewStore.state.headset?.portName {
                Text(name)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fixedSize()
    }
}

extension CardoFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        CardoStatusView(viewStore: ViewStore(store))
    }
}
