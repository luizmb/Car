import AppDomain
import FP
import FPMacros
import Foundation
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
/// deleting a log file simply removes its rides.
///
/// **Granular by design too.** This screen is four charts, a map and three gestures over the same
/// state, and it taught the app two performance lessons the hard way. Everything heavy is
/// precomputed *once* — the ride's series are cut and downsampled at selection, the row and stat
/// strings are formatted in the behavior where the World's formatters live — so a scrub tick costs
/// a binary search, not a walk over every record. And the view observes per **field**
/// (`.observationGranular`): dragging the scrub invalidates the views that read `scrubTime`, not
/// the whole screen.
public enum RideReviewFeature {
    public typealias ViewState = State
    public typealias ViewAction = Action

    // MARK: Presentation values

    /// One list row, formatted where the formatters live.
    public struct RideRow: Sendable, Equatable, Identifiable {
        public let id: Date
        public let title: String
        public let subtitle: String
        public let endedCleanly: Bool

        public init(id: Date, title: String, subtitle: String, endedCleanly: Bool) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.endedCleanly = endedCleanly
        }
    }

    /// One labelled figure on the detail sheet.
    public struct RideFact: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let value: String

        public init(id: String, label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    /// Everything worded on the detail sheet, prepared beside ``RideDetail``'s numbers.
    public struct DetailWords: Sendable, Equatable {
        public var facts: [RideFact] = []
        public var roads: [RideFact] = []
        public var indicatorSummary = ""
        public var cameraWarnings: String?
        public var destination: DestinationPayload?
        public var destinationLabel: String?
        public var endedCleanly = true
        public var start = Date(timeIntervalSince1970: 0)
        public var end = Date(timeIntervalSince1970: 0)

        public init() {}
    }

    // MARK: State

    @Tracked
    public struct State: Sendable, Equatable {
        /// Newest first — the ride you just finished is the one you came to look at. Kept whole
        /// for the app-level joins (replay, ride-there-again); the *screen* reads `rows`.
        public var rides: [Ride] = []
        public var rows: [RideRow] = []
        public var isLoading: Bool = false
        /// The ride open in the detail sheet.
        public var selected: Date?
        /// The heavy numbers, cut once at selection.
        public var detail: RideDetail?
        /// The words beside them, formatted once at selection.
        public var words: DetailWords = DetailWords()
        /// Where the exported GPX landed, once it has. Cleared whenever the selection changes so a
        /// share sheet can never offer the previous ride's file.
        public var exportURL: URL?

        /// The moment the finger names on any chart — the same rule on all of them, and the ball
        /// on the map.
        public var scrubTime: Date?
        /// Seconds of ride visible in the charts; a pinch narrows it, and every chart wears it.
        public var chartWindowSeconds: Double = 3_600
        /// The window the current pinch began on. `nil` between pinches.
        public var pinchBaseSeconds: Double?
        /// The instant at the left edge of every chart's viewport.
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
        /// The rows, worded in the behavior where the formatters live.
        case rowsPrepared([RideRow])
        case select(Date?)
        /// The selected ride's numbers and words, prepared off the reducer.
        case detailPrepared(RideDetail, DetailWords)
        /// A finger over a chart named a moment, or lifted (`nil`).
        case scrub(Date?)
        /// The pinch's current magnification. The reducer owns the arithmetic.
        case chartPinchChanged(Double)
        /// A chart's viewport moved; every chart follows.
        case chartScrolled(Date)
        case chartPinchEnded
        case exportGPX
        case exported(URL?)
        /// Handled at app level — the only place that can close this screen and open the planner.
        case navigateAgain(DestinationPayload)
        /// Watch this ride again on the home screen, fed by the tape. App level too.
        case replayRide(Date)
    }

    // MARK: Environment

    public struct Environment: Sendable {
        public let loadJourneyRecords: @Sendable () -> Publisher<[JourneyRecord], Never>
        public let writeShareFile: @Sendable (String, String) -> Publisher<URL?, Never>
        public let formatDistance: @Sendable (Meters) -> String
        public let formatDuration: @Sendable (TimeInterval) -> String
        public let formatTime: @Sendable (Date) -> String
        /// For the list rows, which span days — a bare time hides which day a ride belongs to.
        public let formatDayTime: @Sendable (Date) -> String
        public let formatSpeed: @Sendable (MPH) -> String

        public init(
            loadJourneyRecords: @escaping @Sendable () -> Publisher<[JourneyRecord], Never>,
            writeShareFile: @escaping @Sendable (String, String) -> Publisher<URL?, Never>,
            formatDistance: @escaping @Sendable (Meters) -> String,
            formatDuration: @escaping @Sendable (TimeInterval) -> String,
            formatTime: @escaping @Sendable (Date) -> String,
            formatDayTime: @escaping @Sendable (Date) -> String,
            formatSpeed: @escaping @Sendable (MPH) -> String
        ) {
            self.loadJourneyRecords = loadJourneyRecords
            self.writeShareFile = writeShareFile
            self.formatDistance = formatDistance
            self.formatDuration = formatDuration
            self.formatTime = formatTime
            self.formatDayTime = formatDayTime
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
                                Action.loaded(assembleRides(from: records).reversed())
                            }
                    }

            case let .loaded(rides):
                return .reduce {
                    $0.rides = rides
                    $0.isLoading = false
                }
                .produce { ctx in
                    // Worded here because the reducer has no formatters — and once, because a
                    // list that re-words itself per scroll frame is the lag this screen had.
                    Effect.just(.rowsPrepared(rides.map { ride in
                        RideRow(
                            id: ride.id,
                            title: ctx.environment.formatDayTime(ride.start),
                            subtitle: ctx.environment.formatDuration(ride.duration) + " · "
                                + ctx.environment.formatDistance(Meters(ride.distanceMetres)),
                            endedCleanly: ride.endedCleanly
                        )
                    }))
                }

            case let .rowsPrepared(rows):
                return .reduce { $0.rows = rows }

            case let .select(id):
                let ride = context.stateBefore?.rides.first { $0.id == id }
                return .reduce { state in
                    state.selected = id
                    // A share sheet must never offer the previous ride's file.
                    state.exportURL = nil
                    state.scrubTime = nil
                    state.pinchBaseSeconds = nil
                    state.detail = nil
                    state.words = DetailWords()
                    if let ride {
                        state.chartWindowSeconds = max(60, ride.duration)
                        state.chartAnchorTime = ride.start
                    }
                }
                .produce { ctx in
                    // The one heavy pass, off the reducer: series cut and downsampled, words
                    // formatted — everything the sheet will draw, ready before it settles.
                    guard let ride else { return .empty }
                    return Effect.just(.detailPrepared(
                        rideDetail(for: ride), words(for: ride, ctx.environment)
                    ))
                }

            case let .detailPrepared(detail, words):
                return .reduce {
                    $0.detail = detail
                    $0.words = words
                }

            case let .scrub(time):
                return .reduce { $0.scrubTime = time }

            case let .chartPinchChanged(magnification):
                return .reduce {
                    let full = $0.selectedRide.map { max(60, $0.duration) } ?? 3_600
                    let base = $0.pinchBaseSeconds ?? $0.chartWindowSeconds
                    $0.pinchBaseSeconds = base
                    // Horizontal only, by construction: the window narrows, the y-axes stay put.
                    $0.chartWindowSeconds = min(full, max(30, base / max(0.1, magnification)))
                }

            case .chartPinchEnded:
                return .reduce { $0.pinchBaseSeconds = nil }

            case let .chartScrolled(anchor):
                return .reduce { $0.chartAnchorTime = anchor }

            case .exportGPX:
                guard let ride = context.stateBefore?.selectedRide else { return .doNothing }
                return .produce { ctx in
                    let name = "ride-\(Int(ride.start.timeIntervalSince1970)).gpx"
                    return ctx.environment.writeShareFile(name, gpx(for: ride))
                        .asEffect(Action.exported)
                }

            case let .exported(url):
                return .reduce { $0.exportURL = url }

            // App-level joins: close this screen, open the planner or the tape.
            case .navigateAgain, .replayRide:
                return .doNothing
            }
        }
    }

    /// The sheet's words, in one pass with the World's formatters.
    private static func words(for ride: Ride, _ env: Environment) -> DetailWords {
        var words = DetailWords()
        words.start = ride.start
        words.end = max(ride.end, ride.start.addingTimeInterval(60))
        words.endedCleanly = ride.endedCleanly

        words.facts = [
            RideFact(id: "started", label: "Started", value: env.formatDayTime(ride.start)),
            RideFact(id: "duration", label: "Duration", value: env.formatDuration(ride.duration)),
            RideFact(id: "distance", label: "Distance",
                     value: env.formatDistance(Meters(ride.distanceMetres)))
        ]
        if let average = ride.averageMovingMPH {
            words.facts.append(RideFact(
                id: "average", label: "Average moving", value: env.formatSpeed(MPH(average))
            ))
        }
        if let top = ride.maxMPH {
            words.facts.append(RideFact(id: "top", label: "Top speed", value: env.formatSpeed(MPH(top))))
        }

        words.roads = ride.roadsVisited.enumerated().map { index, road in
            RideFact(
                id: "road-\(index)", label: road.label,
                value: road.mph.map { "\(Int($0)) mph" } ?? "—"
            )
        }

        let counts = ride.indicatorCounts
        words.indicatorSummary = "\(counts.left) left, \(counts.right) right"
        if ride.cameraEventCount > 0 {
            words.cameraWarnings = "\(ride.cameraEventCount)"
        }
        words.destination = ride.destination
        words.destinationLabel = ride.destination.map {
            "Ride there again" + ($0.name.map { " · \($0)" } ?? "")
        }
        return words
    }

    public typealias Content = RideReviewView
}

extension RideReviewFeature: Feature {
    /// Hand-written where `@Feature` would have generated it: the macro's conformance resolves
    /// for probes but stays invisible to same-module generic uses — a corner worth reporting to
    /// SwiftRex. The body is exactly what the macro emits: project, wrap tracked, hand to Content.
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment _: Environment
    ) -> some View {
        RideReviewView(viewStore: TrackedViewStore(store))
    }
}
