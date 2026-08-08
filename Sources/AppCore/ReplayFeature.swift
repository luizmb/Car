import AppDomain
import FP
import FPMacros
import Foundation
import ReactiveConcurrency
import SpeedMonitorFeature
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency

// MARK: - ReplayFeature

/// A recorded ride, watched on the home screen as if it were being ridden.
///
/// The design is the user's, verbatim: *same behavior, different Environment*. The replay screen
/// hosts a second ``SpeedMonitorFeature`` — the very same behavior that runs the live home map —
/// whose environment has its live inputs unplugged: no GPS, no road fetcher, no camera radius.
/// The tape supplies what the World used to: fixes and indicator events go back in as the same
/// actions the live streams would have produced, recorded roads stand in for lookups (a desk's
/// lookup would answer with the desk's road), and everything else — the following camera, the
/// speed announcements, the over-limit beeps — *emerges* from the behavior rather than being
/// played back.
public enum ReplayFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        /// The ride being replayed — the tape.
        public let ride: Ride
        /// The second monitor: same feature as the home screen, fed by the tape.
        public var monitor: SpeedMonitorFeature.State
        /// The replayed blinker, for the overlay arrows.
        public var indicator: Side?
        /// The tape ran out. The screen stays — the rider may want to look at where it ended —
        /// until they leave.
        public var finished: Bool = false
        public var started: Bool = false
        /// Where the tape is and how long it runs — the HUD's ticking proof that a stopped bike
        /// is a red light, not a hang.
        public var position: TimeInterval = 0
        public var duration: TimeInterval = 0

        public init(ride: Ride) {
            self.ride = ride
            monitor = SpeedMonitorFeature.initialState(with: ())
        }
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        /// The screen appeared; roll the tape.
        case begin
        /// One step of the tape, on time, knowing where on the tape it sits.
        case event(ReplayStep)
        /// The lifted second monitor — the same actions the live one handles.
        case monitor(SpeedMonitorFeature.Action)
        case ended
        /// The stop button. Back-swiping works too; both stop the tape.
        case cancel
    }
}

// MARK: - The behavior, at app level

/// Everything replay, composed into the app behavior.
///
/// The lifted monitor lives under ``AppScopes/replayMonitor`` — an affine scope into the stack
/// entry — which is what isolates a replay completely: app-level wiring listens for
/// `.speedMonitor(...)` actions, and the tape's copies arrive as `.replay(.monitor(...))`,
/// invisible to journey recording, the watch link, the trip counter and the flight plan.
func replayBehavior() -> Behavior<AppAction, AppState, World> {

    AppScopes.replayMonitor.behavior(of: SpeedMonitorFeature.self)

    // Roll the tape: the schedule is cut purely from the ride's records; the World only waits.
    <> Behavior<AppAction, AppState, World>.handle { action, context in
        guard
            AppAction.prism.replay.preview(action)
                .flatMap(ReplayFeature.Action.prism.begin.preview) != nil,
            let entry = context.stateBefore?.path.compactMap(StackEntry.prism.replay.preview).last,
            !entry.started
        else { return .doNothing }
        let schedule = replaySchedule(for: entry.ride.records)
        let duration = schedule.last?.position ?? 0
        // The whole journey's line, under the moving rider — where you have been and where you
        // are going, exactly what the ride's own track holds.
        let track = simplified(entry.ride.track.map {
            Coordinate(latitude: Latitude($0.fix.lat), longitude: Longitude($0.fix.lon))
        })
        return .reduce {
            $0.updateReplay {
                $0.started = true
                $0.duration = duration
            }
        }
        .produce { ctx in
            Effect.just(.replay(.monitor(.setRoute(track))))
                <> ctx.environment.playback(schedule).asEffect { AppAction.replay(.event($0)) }
        }
    }

    // Each step becomes exactly the action the live World would have produced — and moves the
    // tape counter, which is the screen's proof of life during recorded stillness.
    <> Behavior<AppAction, AppState, World>.handle { action, _ in
        guard
            let step = AppAction.prism.replay.preview(action)
                .flatMap(ReplayFeature.Action.prism.event.preview)
        else { return .doNothing }
        switch step.event {
        case let .fix(update):
            return .reduce { $0.updateReplay { $0.position = step.position } }
                .produce { _ in Effect.just(.replay(.monitor(.locationUpdate(update)))) }
        case let .road(info):
            return .reduce { $0.updateReplay { $0.position = step.position } }
                .produce { _ in Effect.just(.replay(.monitor(.roadSpeedChanged(info)))) }
        case let .indicator(side):
            let mapped: Side? = side.map { $0 == "left" ? .left : .right }
            return .reduce {
                $0.updateReplay { replay in
                    replay.position = step.position
                    replay.indicator = mapped
                }
            }
            // The Indimate's click, exactly as the live feature plays it — a replay without the
            // relay's tick is a silent film of a talkie.
            .produce { ctx in
                (mapped.map(ctx.environment.playIndicatorLoop)
                    ?? ctx.environment.stopIndicatorLoop())
                    |> Effect.fireAndForget
            }
        case .finished:
            return .produce { ctx in
                (ctx.environment.stopIndicatorLoop() |> Effect.fireAndForget)
                    <> Effect.just(.replay(.ended))
            }
        }
    }

    <> Behavior<AppAction, AppState, World>.reduce { action, state in
        guard
            AppAction.prism.replay.preview(action)
                .flatMap(ReplayFeature.Action.prism.ended.preview) != nil
        else { return }
        state.updateReplay { $0.finished = true }
    }

    // The stop button: kill the tape, leave the screen.
    <> Behavior<AppAction, AppState, World>.handle { action, _ in
        guard
            AppAction.prism.replay.preview(action)
                .flatMap(ReplayFeature.Action.prism.cancel.preview) != nil
        else { return .doNothing }
        return .produce { ctx in
            (ctx.environment.stopPlayback() |> Effect.fireAndForget)
                <> (ctx.environment.stopIndicatorLoop() |> Effect.fireAndForget)
                <> Effect.just(.navigation(.pop))
        }
    }

    // The tape must never outlive its screen. Back-swipe, back button, pop-to-root — any
    // navigation that removes the replay entry stops the playback, or a cancelled screen would
    // keep speaking a ride nobody is watching.
    <> Behavior<AppAction, AppState, World>.handle { action, context in
        guard
            AppAction.prism.navigation.preview(action) != nil,
            context.stateBefore?.path.contains(where: {
                StackEntry.prism.replay.preview($0) != nil
            }) == true
        else { return .doNothing }
        return .produce { ctx in
            ctx.readLiveState()
                .compactMap { state -> AppAction? in
                    let stillThere = state.path.contains {
                        StackEntry.prism.replay.preview($0) != nil
                    }
                    return stillThere ? nil : .replayScreenGone
                }
                .asEffect()
        }
    }

    <> Behavior<AppAction, AppState, World>.handle { action, _ in
        guard AppAction.prism.replayScreenGone.preview(action) != nil else { return .doNothing }
        return .produce { ctx in
            (ctx.environment.stopPlayback() |> Effect.fireAndForget)
                <> (ctx.environment.stopIndicatorLoop() |> Effect.fireAndForget)
        }
    }

    // "Replay this ride" on the detail sheet: close the sheet, open the tape.
    <> Behavior<AppAction, AppState, World>.handle { action, context in
        guard
            let rides = AppAction.prism.rides.preview(action),
            let rideID = RideReviewFeature.Action.prism.replayRide.preview(rides),
            let ride = context.stateBefore?.path
                .compactMap(StackEntry.prism.rides.preview).last?.detailRide,
            ride.id == rideID
        else { return .doNothing }
        return .produce { _ in
            Effect.just(.rides(.select(nil)))
                <> Effect.just(.navigation(.push(.replay(ride))))
        }
    }
}

private extension AppState {
    /// Writes through to the replay entry on the stack, wherever it sits.
    mutating func updateReplay(_ change: (inout ReplayFeature.State) -> Void) {
        path = path.map { entry in
            guard var replay = StackEntry.prism.replay.preview(entry) else { return entry }
            change(&replay)
            return .replay(replay)
        }
    }
}

// MARK: - The tape deck

/// Waits and yields — the only side-effect a replay needs.
///
/// One tape at a time: starting a playback stops any previous one, and `stop()` is the
/// deterministic end the cancel button and the pop-detection both press. The waits happen here,
/// behind the World, because a reducer has no clock and must never sleep.
final class ReplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func play(_ steps: [ReplayStep]) -> Publisher<ReplayStep, Never> {
        Publisher { [weak self] continuation in
            guard let self else { return }
            let mine = self.lock.withLock {
                self.generation += 1
                return self.generation
            }
            for step in steps {
                if step.delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
                }
                guard self.lock.withLock({ self.generation == mine }) else { return }
                continuation.yield(step)
            }
        }
    }

    func stop() {
        lock.withLock { generation += 1 }
    }
}
