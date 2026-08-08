import AppDomain
import FP
import FPMacros
import Foundation
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftRexSwiftUI

// MARK: - WatchFeature

/// The whole watch app: one feature, three screens, zero authority.
///
/// The phone is the source of truth; the watch holds the last ``WatchSnapshot`` it was handed and
/// renders it. Every rule here is about *presentation* of that snapshot — which haptic the wrist
/// owes for the change since the previous one, which tab is up, what the refuel form currently
/// says — and the one thing the watch may ask for, a fill, goes back as a command for the phone
/// to execute against its own stores.
public enum WatchFeature {

    // MARK: State

    /// The three screens, in ride order: glance, context, errand.
    public enum Tab: String, Sendable, Equatable, CaseIterable {
        case instruments
        case map
        case refuel
    }

    /// The refuel form as a value. Steps rather than free text: a watch has no keyboard worth
    /// using at a pump, and a fill is always within a litre of the last one anyway.
    public struct RefuelDraft: Sendable, Equatable {
        public var litres: Double = 9.0
        public var pricePerLitre: Double = 1.45
        public var grade: String = "E5"
        public var filledToBrim: Bool = true

        public init() {}

        public var command: WatchRefuel {
            WatchRefuel(
                litres: litres, pricePerLitre: pricePerLitre,
                grade: grade, filledToBrim: filledToBrim
            )
        }
    }

    public struct State: Sendable, Equatable {
        /// The last truth the phone sent. `nil` until the first snapshot lands — the "waiting for
        /// the phone" state every launch begins in.
        public var snapshot: WatchSnapshot?
        public var phoneReachable: Bool = false
        public var tab: Tab = .instruments
        public var refuel: RefuelDraft = RefuelDraft()
        /// Whether a refuel command is in flight, and the outcome of the last one. `nil` = idle.
        public var refuelSending: Bool = false
        public var refuelDelivered: Bool?
        /// Over-limit snapshots in a row *before* the current one — the repeat-haptic clock.
        public var consecutiveOver: Int = 0

        public init() {}
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case appeared
        case snapshotArrived(WatchSnapshot)
        case reachabilityChanged(Bool)
        case tabChanged(Tab)
        case refuelEdited(RefuelDraft)
        case submitRefuel
        case refuelSent(Bool)
    }

    // MARK: Environment

    /// The watch's World: four closures and a clock's worth of nothing. Snapshots in, reachability
    /// in, one command out, and a haptic player — the only side-effects a display needs.
    public struct Environment: Sendable {
        public let snapshots: @Sendable () -> Publisher<WatchSnapshot, Never>
        public let reachability: @Sendable () -> Publisher<Bool, Never>
        /// `true` when the command was handed to the transport with delivery guaranteed —
        /// immediately when the phone is live, queued when it is not.
        public let sendRefuel: @Sendable (WatchRefuel) -> Publisher<Bool, Never>
        public let playHaptic: @Sendable (WatchHaptic) -> Publisher<Void, Never>

        public init(
            snapshots: @escaping @Sendable () -> Publisher<WatchSnapshot, Never>,
            reachability: @escaping @Sendable () -> Publisher<Bool, Never>,
            sendRefuel: @escaping @Sendable (WatchRefuel) -> Publisher<Bool, Never>,
            playHaptic: @escaping @Sendable (WatchHaptic) -> Publisher<Void, Never>
        ) {
            self.snapshots = snapshots
            self.reachability = reachability
            self.sendRefuel = sendRefuel
            self.playHaptic = playHaptic
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {
            case .appeared:
                return .produce { ctx in
                    ctx.environment.snapshots().asEffect(Action.snapshotArrived)
                        <> ctx.environment.reachability().asEffect(Action.reachabilityChanged)
                }

            case let .snapshotArrived(snapshot):
                let previous = context.stateBefore?.snapshot
                let over = context.stateBefore?.consecutiveOver ?? 0
                // Decided purely, played as an effect: the reducer never touches the wrist.
                let owed = watchHaptics(
                    previous: previous, current: snapshot, consecutiveOver: over
                )
                return .reduce {
                    $0.snapshot = snapshot
                    $0.consecutiveOver = snapshot.overLimit ? over + 1 : 0
                }
                .produce { ctx in
                    owed.map { ctx.environment.playHaptic($0) |> Effect<Action>.fireAndForget }
                        .reduce(.empty, <>)
                }

            case let .reachabilityChanged(reachable):
                return .reduce { $0.phoneReachable = reachable }

            case let .tabChanged(tab):
                return .reduce {
                    $0.tab = tab
                    // Leaving the refuel screen retires its outcome banner; coming back starts clean.
                    if tab != .refuel { $0.refuelDelivered = nil }
                }

            case let .refuelEdited(draft):
                return .reduce { $0.refuel = draft }

            case .submitRefuel:
                guard
                    let draft = context.stateBefore?.refuel,
                    context.stateBefore?.refuelSending != true
                else { return .doNothing }
                return .reduce {
                    $0.refuelSending = true
                    $0.refuelDelivered = nil
                }
                .produce { ctx in
                    ctx.environment.sendRefuel(draft.command).asEffect(Action.refuelSent)
                }

            case let .refuelSent(delivered):
                return .reduce {
                    $0.refuelSending = false
                    $0.refuelDelivered = delivered
                }
            }
        }
    }
}

extension WatchFeature: HasBehavior {}

// MARK: - The store

public enum WatchMain {
    /// The one place a watch store is built — the entry point's only job, mirroring the phone.
    @MainActor
    public static func store(
        world: WatchFeature.Environment
    ) -> any StoreType<WatchFeature.Action, WatchFeature.State> {
        Store(
            initial: WatchFeature.State(),
            behavior: WatchFeature.behavior(),
            environment: world
        )
    }
}
