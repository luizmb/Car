import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftUI

// MARK: - TripFeature

/// Distance travelled since the last fill, measured by GPS.
///
/// This is the number the fuel maths will use. The bike's odometer is the thing being *calibrated*,
/// not the thing to calibrate against — it shows whole kilometres and carries ±1 km of quantisation
/// per fill.
///
/// Accumulation is gated, because unfiltered GPS over-reads badly. A stationary receiver
/// random-walks, and every metre of that drift would land in the fuel maths as distance never
/// travelled. The measured drift on a real ride was ~80 m per journey, which is small but
/// systematically in one direction — it only ever inflates.
public enum TripFeature {

    /// Fixes worse than this are ignored outright. Urban canyons and tunnels produce fixes with
    /// accuracy in the hundreds of metres, and integrating those is worse than having a gap.
    static let accuracyLimit: Double = 25

    /// Below this the bike is parked and the receiver is wandering, not moving.
    static let movingThreshold: Double = 1.0   // m/s ≈ 2.2 mph

    /// A single step longer than this is a teleport — a fix arriving after a signal gap — not
    /// distance covered in one second. Counting it would credit the whole tunnel twice.
    static let maxStep: Double = 250

    /// Persist after this much new distance. Writing on every fix would be a file write per second;
    /// never writing would lose the tank's distance on every relaunch.
    static let persistEvery: Double = 250

    // MARK: State

    public struct State: Sendable, Equatable {
        public var metresSinceFill: Double = 0
        public var lastLatitude: Latitude?
        public var lastLongitude: Longitude?
        /// Distance at the last persist, so the writer knows when it has drifted far enough to
        /// bother.
        public var persistedAt: Double = 0
        public var loaded = false

        public init() {}

        public var kilometresSinceFill: Kilometres { Kilometres(metresSinceFill / 1000) }
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case appeared
        case loaded(Double)
        case located(LocationUpdate)
        /// A fill or reserve switch happened — the tank is a fresh measurement from here.
        case reset
        case persisted
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let loadTripDistance: @Sendable () -> Publisher<Result<Double, FileError>, Never>
        public let saveTripDistance: @Sendable (Double) -> Publisher<Result<Void, FileError>, Never>

        public init(
            loadTripDistance: @escaping @Sendable () -> Publisher<Result<Double, FileError>, Never>,
            saveTripDistance: @escaping @Sendable (Double) -> Publisher<Result<Void, FileError>, Never>
        ) {
            self.loadTripDistance = loadTripDistance
            self.saveTripDistance = saveTripDistance
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {
            case .appeared:
                return .produce { ctx in
                    ctx.environment.loadTripDistance()
                        .asEffect { (result: Result<Double, FileError>) in
                            // Nothing saved is the normal first-run state, and zero is the right
                            // answer for it.
                            Action.loaded((try? result.get()) ?? 0)
                        }
                }

            case let .loaded(metres):
                return .reduce {
                    $0.metresSinceFill = metres
                    $0.persistedAt = metres
                    $0.loaded = true
                }

            case let .located(update):
                guard let state = context.stateBefore else { return .doNothing }
                let step = accumulableStep(from: state, to: update)
                guard step > 0 else {
                    // Still worth remembering where we are, or the next step would be measured
                    // from a stale position and count the whole gap.
                    return .reduce {
                        $0.lastLatitude = update.latitude
                        $0.lastLongitude = update.longitude
                    }
                }
                let total = state.metresSinceFill + step
                return .reduce {
                    $0.metresSinceFill = total
                    $0.lastLatitude = update.latitude
                    $0.lastLongitude = update.longitude
                }
                .produce { ctx in
                    guard total - state.persistedAt >= persistEvery else { return .empty }
                    return ctx.environment.saveTripDistance(total)
                        .asEffect { (_: Result<Void, FileError>) in Action.persisted }
                }

            case .persisted:
                return .reduce { $0.persistedAt = $0.metresSinceFill }

            case .reset:
                return .reduce {
                    $0.metresSinceFill = 0
                    $0.persistedAt = 0
                }
                .produce { ctx in
                    ctx.environment.saveTripDistance(0)
                        .asEffect { (_: Result<Void, FileError>) in Action.persisted }
                }
            }
        }
    }

    /// Metres to add for this fix, or zero if it fails any gate. Pure, so every rule is testable
    /// without a bike or a satellite.
    static func accumulableStep(from state: State, to update: LocationUpdate) -> Double {
        guard
            let previousLatitude = state.lastLatitude,
            let previousLongitude = state.lastLongitude,
            let accuracy = update.horizontalAccuracy, accuracy.rawValue <= accuracyLimit,
            let speed = update.speed, speed.rawValue >= movingThreshold
        else { return 0 }

        let metres = haversine(previousLatitude, previousLongitude, update.latitude, update.longitude)
        return metres <= maxStep ? metres : 0
    }
}

extension TripFeature: HasBehavior {}

// MARK: - View

struct TripStatusView: View {
    let viewStore: ViewStore<TripFeature.State, TripFeature.Action>

    var body: some View {
        HStack(spacing: 5) {
            Text("Tank:").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(String(format: "%.1f km", viewStore.state.kilometresSinceFill.rawValue))
                .font(.caption2.bold().monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .onAppear { viewStore.dispatch(.appeared) }
    }
}

extension TripFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        TripStatusView(viewStore: ViewStore(store))
    }
}
