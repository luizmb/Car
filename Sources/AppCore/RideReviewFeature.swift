import AppDomain
import FP
import FPMacros
import ReactiveConcurrency
import SwiftRex
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import SwiftRexSwiftUI
import SwiftUI

// MARK: - RideReviewFeature

/// Looking back at rides.
///
/// Read-only by design: everything on these screens is reassembled from the journey log on each
/// visit, and nothing is ever written back — so the screens cannot drift from the record, and
/// deleting a log file simply removes its rides. The log's schema was built for this moment;
/// the feature is the first thing to spend that investment.
public enum RideReviewFeature {

    // MARK: State

    public struct State: Sendable, Equatable {
        /// Newest first — the ride you just finished is the one you came to look at.
        public var rides: [Ride] = []
        public var isLoading: Bool = false
        /// The ride open in the detail sheet.
        public var selected: Date?
        /// Where the exported GPX landed, once it has. Cleared whenever the selection changes so a
        /// share sheet can never offer the previous ride's file.
        public var exportURL: URL?

        /// The moment the finger names on any chart — the same rule on all of them, and the ball
        /// on the map. Store state rather than view state: every UI event lands here, so the scrub
        /// is inspectable, loggable, and one source of truth across four charts and a map.
        public var scrubTime: Date?
        /// Seconds of ride visible in the charts. Reset to the whole ride on selection; a pinch
        /// narrows it, and every chart wears the same window.
        public var chartWindowSeconds: Double = 3_600
        /// The window the current pinch began on, so zoom is relative to it rather than
        /// compounding per frame. `nil` between pinches.
        public var pinchBaseSeconds: Double?
        /// The instant at the left edge of every chart's viewport. One value, four charts: scroll
        /// any of them and the rest follow, because comparing speed against gradient needs the
        /// columns to line up.
        public var chartAnchorTime: Date = Date(timeIntervalSince1970: 0)

        public init() {}

        public var selectedRide: Ride? {
            selected.flatMap { id in rides.first { $0.id == id } }
        }
    }

    // MARK: Action

    @Prisms
    public enum Action: Sendable {
        case appeared
        case loaded([Ride])
        case select(Date?)
        /// A finger over a chart named a moment, or lifted (`nil`).
        case scrub(Date?)
        /// The pinch's current magnification. The reducer owns the arithmetic, so the view carries
        /// no zoom state of its own.
        case chartPinchChanged(Double)
        /// A chart's viewport moved; every chart follows.
        case chartScrolled(Date)
        case chartPinchEnded
        case exportGPX
        case exported(URL?)
        /// Ride to this destination again. MapKit cannot replay a route's steps — directions are
        /// computed fresh for current traffic — but the *destination* replays perfectly, and it is
        /// the part the rider means. Handled at app level, which is the only place that can close
        /// this screen and open the planner.
        case navigateAgain(DestinationPayload)
        /// Watch this ride again on the home screen, fed by the tape. Handled at app level — the
        /// only place that can close this screen and open the replay.
        case replayRide(Date)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let loadJourneyRecords: @Sendable () -> Publisher<[JourneyRecord], Never>
        public let writeShareFile: @Sendable (String, String) -> Publisher<URL?, Never>
        public let formatDistance: @Sendable (Meters) -> String
        public let formatDuration: @Sendable (TimeInterval) -> String
        public let formatTime: @Sendable (Date) -> String
        public let formatSpeed: @Sendable (MPH) -> String

        public init(
            loadJourneyRecords: @escaping @Sendable () -> Publisher<[JourneyRecord], Never>,
            writeShareFile: @escaping @Sendable (String, String) -> Publisher<URL?, Never>,
            formatDistance: @escaping @Sendable (Meters) -> String,
            formatDuration: @escaping @Sendable (TimeInterval) -> String,
            formatTime: @escaping @Sendable (Date) -> String,
            formatSpeed: @escaping @Sendable (MPH) -> String
        ) {
            self.loadJourneyRecords = loadJourneyRecords
            self.writeShareFile = writeShareFile
            self.formatDistance = formatDistance
            self.formatDuration = formatDuration
            self.formatTime = formatTime
            self.formatSpeed = formatSpeed
        }
    }

    public static func initialState(with _: Void) -> State { .init() }

    // MARK: Behavior

    public static func behavior() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {
            case .appeared:
                return .reduce { $0.isLoading = true }
                    .produce { ctx in
                        ctx.environment.loadJourneyRecords()
                            .asEffect { records in
                                // Assembled here, on each visit, from the log as it is now —
                                // never cached, so a pulled or deleted file is simply reflected.
                                Action.loaded(assembleRides(from: records).reversed())
                            }
                    }

            case let .loaded(rides):
                return .reduce {
                    $0.rides = rides
                    $0.isLoading = false
                }

            case let .select(id):
                return .reduce { state in
                    state.selected = id
                    // A share sheet must never offer the previous ride's file.
                    state.exportURL = nil
                    state.scrubTime = nil
                    state.pinchBaseSeconds = nil
                    // The window opens on the whole ride; the floor keeps a 30-second hop from
                    // producing a chart too narrow to hold a single axis label.
                    if let id, let ride = state.rides.first(where: { $0.id == id }) {
                        state.chartWindowSeconds = max(60, ride.duration)
                        state.chartAnchorTime = ride.start
                    }
                }

            case let .scrub(time):
                return .reduce { $0.scrubTime = time }

            case let .chartPinchChanged(magnification):
                return .reduce {
                    let full = $0.selectedRide.map { max(60, $0.duration) } ?? 3_600
                    let base = $0.pinchBaseSeconds ?? $0.chartWindowSeconds
                    $0.pinchBaseSeconds = base
                    // Horizontal only, by construction: the window narrows, the y-axes stay put.
                    // Clamped between half a minute and the whole ride.
                    $0.chartWindowSeconds = min(full, max(30, base / max(0.1, magnification)))
                }

            case .chartPinchEnded:
                return .reduce { $0.pinchBaseSeconds = nil }

            case let .chartScrolled(anchor):
                return .reduce { $0.chartAnchorTime = anchor }

            case .exportGPX:
                guard let ride = context.stateBefore?.selectedRide else { return .doNothing }
                return .produce { ctx in
                    // The filename is the start instant — unambiguous, sortable, and safe for a
                    // filesystem because ISO-8601 basic contains no separators worth escaping.
                    let name = "ride-\(Int(ride.start.timeIntervalSince1970)).gpx"
                    return ctx.environment.writeShareFile(name, gpx(for: ride))
                        .asEffect(Action.exported)
                }

            case let .exported(url):
                return .reduce { $0.exportURL = url }

            // App-level: closes this screen, opens the planner, hands it the destination.
            case .navigateAgain:
                return .doNothing

            // App-level too: closes this screen and rolls the tape.
            case .replayRide:
                return .doNothing
            }
        }
    }
}

extension RideReviewFeature: HasBehavior {}
