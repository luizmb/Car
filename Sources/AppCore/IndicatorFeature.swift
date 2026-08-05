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
        /// Whether we have decided to ask for Bluetooth yet. The supervisor is gated on this, and
        /// since constructing a `CBCentralManager` *is* the permission request, this flag is
        /// precisely "have we shown the dialog". It stays false until location has been resolved,
        /// so the two system prompts arrive one at a time and in order of importance.
        public var hasStarted: Bool = false
        public var bluetooth: BluetoothAvailability = .unknown
        public var isConnected: Bool = false
        /// Which side is ticking right now. `nil` is genuinely "neither" — the unit reports that
        /// explicitly, so it is not an unknown.
        public var side: Side?
        /// Last reported supply voltage, in every interpretation still in play. Not acted on yet —
        /// kept because the journey recorder will want it, and because a charging fault on a bike
        /// with no warning light is worth surfacing once the encoding is settled.
        public var battery: BatteryReading?
        /// Last charging state announced, so a fault is spoken on the transition rather than on
        /// every voltage report — the same rule as the tyre warnings.
        public var announcedCharging: ChargingState?

        public init() {}
    }

    // MARK: Action

    /// Two input sources, so this is a real enum rather than an alias for `IndimateEvent`: the unit
    /// pushes `event`s, and the app tells us when it is our turn to ask for Bluetooth.
    @Prisms
    public enum Action: Sendable {
        /// Every launch, foreground or background. If Bluetooth has already been decided there is
        /// no dialog left to order, so the central is built immediately — which is the only reason
        /// a background relaunch works: iOS restores us with no UI, so nothing else would ever
        /// trigger `start`.
        case launch
        /// Location has been resolved — now it is Bluetooth's turn to ask. Constructing the central
        /// *is* the request, so this is what actually puts the dialog on screen.
        case start
        case event(IndimateEvent)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let bluetoothAuthorization: @Sendable () -> BluetoothAuthorization
        public let indimateEvents: @Sendable () -> Publisher<IndimateEvent, Never>
        public let playIndicatorLoop: @Sendable (Side) -> Publisher<Void, Never>
        public let stopIndicatorLoop: @Sendable () -> Publisher<Void, Never>
        public let speak: @Sendable (String) -> Publisher<Void, Never>

        public init(
            bluetoothAuthorization: @escaping @Sendable () -> BluetoothAuthorization,
            indimateEvents: @escaping @Sendable () -> Publisher<IndimateEvent, Never>,
            playIndicatorLoop: @escaping @Sendable (Side) -> Publisher<Void, Never>,
            stopIndicatorLoop: @escaping @Sendable () -> Publisher<Void, Never>,
            speak: @escaping @Sendable (String) -> Publisher<Void, Never>
        ) {
            self.bluetoothAuthorization = bluetoothAuthorization
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
            case .launch:
                // Reading authorization cannot raise a dialog, so this is safe on a background
                // launch. If it is already decided we go straight to `start`; if not, we stay put
                // and let the location chain order the prompts.
                guard before?.hasStarted != true else { return .doNothing }
                return .produce { ctx in
                    ctx.environment.bluetoothAuthorization().isDecided
                        ? Effect.just(.start)
                        : .empty
                }

            case .start:
                // Idempotent — the trigger is a location transition, which can recur.
                guard before?.hasStarted != true else { return .doNothing }
                return .reduce { $0.hasStarted = true }

            case let .event(.availability(availability)):
                guard before?.bluetooth != availability else { return .doNothing }
                return .reduce { $0.bluetooth = availability }
                    .produce { ctx in
                        // Say why it is not working. In an audio-only interface, silence is
                        // indistinguishable from everything being fine.
                        availability.spokenProblem
                            .map { ctx.environment.speak($0) |> Effect.fireAndForget }
                            ?? .empty
                    }

            case .event(.connected):
                guard before?.isConnected != true else { return .doNothing }
                return .reduce { $0.isConnected = true }
                    .produce { ctx in ctx.environment.speak("Indimate connected") |> Effect.fireAndForget }

            case .event(.disconnected):
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

            case let .event(.indicator(side)):
                // The unit pushes a frame per blink phase, twice a second. Only transitions
                // matter — the loop runs at its own rate and is not synced to the real lamps.
                guard before?.side != side else { return .doNothing }
                return .reduce { $0.side = side }
                    .produce { ctx in
                        side.map { ctx.environment.playIndicatorLoop($0) |> Effect.fireAndForget }
                            ?? (ctx.environment.stopIndicatorLoop() |> Effect.fireAndForget)
                    }

            case let .event(.voltage(reading)):
                // `engineRunning` is not directly observable on this bike. Wheels turning is the
                // best available proxy, and it is supplied from outside so this stays pure; until
                // the trip counter feeds it, resting is assumed, which errs toward silence.
                guard let volts = reading.volts else { return .reduce { $0.battery = reading } }
                let state = chargingState(volts: volts, engineRunning: false)
                let previous = before?.announcedCharging
                return .reduce {
                    $0.battery = reading
                    $0.announcedCharging = state
                }
                .produce { ctx in
                    guard previous != state, let warning = state.spokenWarning else { return .empty }
                    return ctx.environment.speak(warning) |> Effect.fireAndForget
                }

            case .event(.info):
                return .doNothing
            }
        }
    }

    /// Gated on `hasStarted`, which is the entire permission workflow: subscribing constructs the
    /// `CBCentralManager`, and constructing it *is* the system prompt. Leaving this ungated would
    /// fire the Bluetooth dialog at store creation — ahead of the location dialog, which matters
    /// far more to an app whose job is reading out speed.
    ///
    /// `.unsupported` closes the channel for good: there is no BLE hardware to wait for, so
    /// retrying would only burn battery. `.poweredOff` and `.unauthorized` deliberately keep it
    /// open, since both can be resolved from Settings without relaunching.
    ///
    /// Once open it stays open for the journey. The unit is activity-triggered — invisible until
    /// an indicator is first used — so there is nothing earlier to wait for.
    private static func supervisor() -> Behavior<Action, State, Environment> {
        .supervise { state in
            Supervision { env in
                guard state.hasStarted, state.bluetooth != .unsupported else { return [] }
                return [env.indimateEvents().asChannel(id: "indimate", Action.event)]
            }
        }
    }
}

// `@Feature` would synthesise this, but that macro also expects a view. A logic-only feature
// declares the behaviour half of the contract by hand.
extension IndicatorFeature: HasBehavior {}
