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

    /// The four screens, in usefulness order: glance, the bike's vitals, the errand — and the
    /// map last, because it swallows every gesture and paging out of it costs the most exactly
    /// where a wrong page costs the most. Last means it neighbours only one other screen.
    public enum Tab: String, Sendable, Equatable, CaseIterable {
        case instruments
        case sensors
        case refuel
        case map
    }

    /// The refuel form as a value — digit windows, not free numbers, because the crown picks
    /// them. Litres and price split into 0–99 windows: two balanced spins beat one long one,
    /// and price is held pump-style — "18.49" for £1.849 — so three pound-decimals cost exactly
    /// two windows. The odometer is deliberately NOT split: it arrives pre-filled with the
    /// phone's estimate, so the crown only ever nudges a big number that is already nearly right.
    public struct RefuelDraft: Sendable, Equatable {
        public var litresInt: Int = 9
        public var litresDec: Int = 0
        public var priceInt: Int = 14
        public var priceDec: Int = 50
        public var odoKm: Int = 0
        /// Set once the odometer has been seeded from the phone's estimate or touched by the
        /// rider — either way, later snapshots must not overwrite it.
        public var odoSeeded: Bool = false
        public var grade: String = "E5"
        public var filledToBrim: Bool = true

        public init() {}

        // Composed from whole hundredths/thousandths in one division, so "18.49" comes out as
        // the double nearest £1.849 — not as an accumulation of two roundings.
        public var litres: Double { min(15, max(0.25, Double(litresInt * 100 + litresDec) / 100)) }
        public var pricePerLitre: Double { Double(priceInt * 100 + priceDec) / 1_000 }
        /// Zero is "not read", not a reading — the bike has six figures on the clock either way.
        public var odometerKm: Double? { odoKm == 0 ? nil : Double(odoKm) }

        public mutating func seedOdometer(km: Double) {
            odoKm = max(0, min(999_999, Int(km.rounded())))
            odoSeeded = true
        }

        public var command: WatchRefuel {
            WatchRefuel(
                litres: litres, pricePerLitre: pricePerLitre,
                grade: grade, filledToBrim: filledToBrim,
                odometerKm: odometerKm
            )
        }
    }

    /// Which digit window the crown is turning. `nil` hands the crown back to tab paging.
    public enum RefuelSegment: Sendable, Equatable {
        case litresInt, litresDec, priceInt, priceDec, odo
    }

    public struct State: Sendable, Equatable {
        /// The last truth the phone sent. `nil` until the first snapshot lands — the "waiting for
        /// the phone" state every launch begins in.
        public var snapshot: WatchSnapshot?
        public var phoneReachable: Bool = false
        public var tab: Tab = .instruments
        public var refuel: RefuelDraft = RefuelDraft()
        /// The digit window the crown currently owns, if any.
        public var refuelFocus: RefuelSegment?
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
        case refuelFocused(RefuelSegment?)
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
                    // The odometer starts at the phone's estimate — last fill's reading plus the
                    // GPS distance since — so the crown only ever nudges the tail digits. Once,
                    // and never over a value the rider has touched.
                    if let estimate = snapshot.suggestedOdometerKm, !$0.refuel.odoSeeded {
                        $0.refuel.seedOdometer(km: estimate)
                    }
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
                    // Leaving the refuel screen retires its outcome banner and hands the crown
                    // back to paging; coming back starts clean.
                    if tab != .refuel {
                        $0.refuelDelivered = nil
                        $0.refuelFocus = nil
                    }
                }

            case let .refuelEdited(draft):
                return .reduce { $0.refuel = draft }

            case let .refuelFocused(segment):
                return .reduce { $0.refuelFocus = segment }

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
