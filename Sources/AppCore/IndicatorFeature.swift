import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency

// MARK: - IndicatorFeature

/// Turns the Indimate unit's BLE chatter into helmet audio: a spoken word when it connects or
/// drops, and a looping tick on the side that is engaged.
///
/// Logic-only — no view. It exists as a feature rather than a lump of `World` because the
/// connect/disconnect announcements depend on *transitions*, and a transition needs somewhere to
/// remember what came before.
public enum IndicatorFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        public var isConnected: Bool = false
        /// Which side is ticking right now. `nil` is genuinely "neither" — the unit reports that
        /// explicitly, so it is not an unknown.
        public var side: Side?
        /// Last reported supply voltage in millivolts. Not acted on; kept because the journey
        /// recorder will want it and it costs one field.
        public var millivolts: Int?

        public init() {}
    }

    // MARK: Action

    /// The feature's only input is the unit itself — there is no view and no second source — so
    /// its action space *is* the event stream. A wrapper case would be ceremony, and `IndimateEvent`
    /// already carries `@Prisms`, so app-level wiring like `.action(\.indicator.connected)` still
    /// reads naturally. Introduce a real enum here the day something else can act on this feature.
    public typealias Action = IndimateEvent

    // MARK: Environment

    public struct Environment: Sendable {
        public let indimateEvents: @Sendable () -> Publisher<IndimateEvent, Never>
        public let playIndicatorLoop: @Sendable (Side) -> Publisher<Void, Never>
        public let stopIndicatorLoop: @Sendable () -> Publisher<Void, Never>
        public let speak: @Sendable (String) -> Publisher<Void, Never>

        public init(
            indimateEvents: @escaping @Sendable () -> Publisher<IndimateEvent, Never>,
            playIndicatorLoop: @escaping @Sendable (Side) -> Publisher<Void, Never>,
            stopIndicatorLoop: @escaping @Sendable () -> Publisher<Void, Never>,
            speak: @escaping @Sendable (String) -> Publisher<Void, Never>
        ) {
            self.indimateEvents = indimateEvents
            self.playIndicatorLoop = playIndicatorLoop
            self.stopIndicatorLoop = stopIndicatorLoop
            self.speak = speak
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        commands() <> supervisor()
    }

    private static func commands() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            let before = context.stateBefore

            switch action {
            case .connected:
                guard before?.isConnected != true else { return .doNothing }
                return .reduce { $0.isConnected = true }
                    .produce { ctx in ctx.environment.speak("Indimate connected") |> Effect.fireAndForget }

            case .disconnected:
                guard before?.isConnected != false else { return .doNothing }
                // Silence the tick too: the unit vanishing mid-blink would otherwise leave it
                // ticking forever, which on a motorway is worse than useless.
                return .reduce {
                    $0.isConnected = false
                    $0.side = nil
                }
                .produce { ctx in
                    (ctx.environment.stopIndicatorLoop() |> Effect.fireAndForget)
                        <> (ctx.environment.speak("Indimate disconnected") |> Effect.fireAndForget)
                }

            case let .indicator(side):
                // The unit pushes a frame per blink phase, twice a second. Only transitions
                // matter — the loop runs at its own rate and is not synced to the real lamps.
                guard before?.side != side else { return .doNothing }
                return .reduce { $0.side = side }
                    .produce { ctx in
                        side.map { ctx.environment.playIndicatorLoop($0) |> Effect.fireAndForget }
                            ?? (ctx.environment.stopIndicatorLoop() |> Effect.fireAndForget)
                    }

            case let .voltage(millivolts):
                return .reduce { $0.millivolts = millivolts }

            case .info:
                return .doNothing
            }
        }
    }

    /// The BLE channel stays open for the app's lifetime. The unit is activity-triggered — it does
    /// not advertise at all until an indicator is first used — so there is nothing to gate this on
    /// and no point closing it early.
    private static func supervisor() -> Behavior<Action, State, Environment> {
        .supervise { _ in
            Supervision { env in
                [env.indimateEvents().asChannel(id: "indimate", id)]
            }
        }
    }
}

// `@Feature` would synthesise this, but that macro also expects a view. A logic-only feature
// declares the behaviour half of the contract by hand.
extension IndicatorFeature: HasBehavior {}
