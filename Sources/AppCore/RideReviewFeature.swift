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
        case exportGPX
        case exported(URL?)
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
                return .reduce {
                    $0.selected = id
                    // A share sheet must never offer the previous ride's file.
                    $0.exportURL = nil
                }

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
            }
        }
    }
}

extension RideReviewFeature: HasBehavior {}
