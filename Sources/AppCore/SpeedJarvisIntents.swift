import AppDomain
import AppIntents
import Foundation
import SpeedMonitorFeature

// MARK: - Shared snapshot
//
// App Intents are constructed by the system, not by us, so they cannot be handed a store. This is
// the seam: `AppFeature` publishes a plain value here whenever state changes, and intents read it.
//
// A snapshot rather than a live store reference on purpose — an intent may run while the app is
// suspended or freshly relaunched, and a stale-but-timestamped answer is far better than a crash or
// a hang. The rider hears "I don't have a reading" instead of silence.

public final class IntentSnapshot: @unchecked Sendable {
    public static let shared = IntentSnapshot()

    private let lock = NSLock()
    private var _speed: String?
    private var _limit: String?
    private var _road: String?
    private var _tyres: [TyrePosition: (psi: String, status: TyreStatus)] = [:]
    private var _ignition: Bool?
    private var _indimate = false

    public func update(
        speed: String?, limit: String?, road: String?,
        tyres: [TyrePosition: (psi: String, status: TyreStatus)],
        ignition: Bool?, indimate: Bool
    ) {
        lock.withLock {
            _speed = speed; _limit = limit; _road = road
            _tyres = tyres; _ignition = ignition; _indimate = indimate
        }
    }

    var speed: String? { lock.withLock { _speed } }
    var limit: String? { lock.withLock { _limit } }
    var road: String? { lock.withLock { _road } }
    var tyres: [TyrePosition: (psi: String, status: TyreStatus)] { lock.withLock { _tyres } }
    var ignition: Bool? { lock.withLock { _ignition } }
    var indimate: Bool { lock.withLock { _indimate } }
}

// MARK: - Intents

/// "Hey Siri, what's my speed" — answered through the helmet without touching anything.
///
/// Voice suits this bike better than buttons for anything phrased as a *question*: no gloves off,
/// no looking down, and the Cardo already has a microphone. Buttons remain the better fit for
/// commands, which is what the planned companion hardware is for.
public struct CurrentSpeedIntent: AppIntent {
    public static let title: LocalizedStringResource = "Current speed"
    public static let description = IntentDescription("How fast you are going right now.")
    /// No UI, no unlock — the whole point is that it works with the phone in a pocket.
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let speed = IntentSnapshot.shared.speed else {
            return .result(dialog: "No speed reading yet.")
        }
        return .result(dialog: IntentDialog(stringLiteral: "\(speed) miles per hour."))
    }
}

/// "Hey Siri, what's the speed limit"
public struct SpeedLimitIntent: AppIntent {
    public static let title: LocalizedStringResource = "Speed limit"
    public static let description = IntentDescription("The limit on the road you are on.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = IntentSnapshot.shared
        guard let limit = snapshot.limit else {
            return .result(dialog: "I don't know the limit here.")
        }
        let road = snapshot.road.map { " on \($0)" } ?? ""
        return .result(dialog: IntentDialog(stringLiteral: "\(limit)\(road)."))
    }
}

/// "Hey Siri, check my tyres"
public struct TyreCheckIntent: AppIntent {
    public static let title: LocalizedStringResource = "Check tyres"
    public static let description = IntentDescription("Pressure for both tyres.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let tyres = IntentSnapshot.shared.tyres
        guard !tyres.isEmpty else {
            return .result(dialog: "No tyre readings yet.")
        }
        // Problems first, then the numbers — the same report-by-exception rule as Flight Plan.
        // A rider who has to listen through four nominal readings stops listening.
        let problems = TyrePosition.allCases.compactMap { position -> String? in
            guard let t = tyres[position], t.status != .ok else { return nil }
            return "\(position.spokenLabel) \(t.status == .low ? "low" : "high") at \(t.psi)"
        }
        if !problems.isEmpty {
            return .result(dialog: IntentDialog(stringLiteral: problems.joined(separator: ", ") + "."))
        }
        let readings = TyrePosition.allCases.compactMap { position -> String? in
            tyres[position].map { "\(position.spokenLabel) \($0.psi)" }
        }
        return .result(dialog: IntentDialog(stringLiteral: "Both fine. " + readings.joined(separator: ", ") + "."))
    }
}

/// "Hey Siri, bike status" — the abbreviated Flight Plan, on demand.
public struct BikeStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Bike status"
    public static let description = IntentDescription("Everything the app currently knows.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = IntentSnapshot.shared
        var parts: [String] = []

        // Exceptions first, as above.
        let faults = TyrePosition.allCases.compactMap { position -> String? in
            guard let t = snapshot.tyres[position], t.status != .ok else { return nil }
            return "\(position.spokenLabel) tyre \(t.status == .low ? "low" : "high")"
        }
        parts += faults
        if !snapshot.indimate { parts.append("Indimate not connected") }

        if parts.isEmpty { parts.append("All nominal") }
        snapshot.speed.map { parts.append("\($0) miles per hour") }
        snapshot.limit.map { parts.append("limit \($0)") }
        snapshot.road.map { parts.append("on \($0)") }

        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: ", ") + "."))
    }
}

// MARK: - Shortcuts

public struct SpeedJarvisShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CurrentSpeedIntent(),
            phrases: ["What's my speed in \(.applicationName)", "\(.applicationName) speed"],
            shortTitle: "Speed",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: SpeedLimitIntent(),
            phrases: ["What's the speed limit in \(.applicationName)", "\(.applicationName) limit"],
            shortTitle: "Limit",
            systemImageName: "signpost.right"
        )
        AppShortcut(
            intent: TyreCheckIntent(),
            phrases: ["Check my tyres in \(.applicationName)", "\(.applicationName) tyres"],
            shortTitle: "Tyres",
            systemImageName: "circle.circle"
        )
        AppShortcut(
            intent: FullReportIntent(),
            phrases: ["Full report in \(.applicationName)", "\(.applicationName) full report"],
            shortTitle: "Full report",
            systemImageName: "list.bullet.rectangle.portrait"
        )
        AppShortcut(
            intent: BikeStatusIntent(),
            phrases: ["Bike status in \(.applicationName)", "\(.applicationName) status"],
            shortTitle: "Status",
            systemImageName: "checklist"
        )
    }
}

// MARK: - Spoken limit

extension RoadLimitDisplay {
    /// The limit as a phrase, or `nil` where there is nothing worth saying. `.none` means not yet
    /// fetched and `.unknown` means OSM has no data — both are "I don't know", and neither should
    /// be dressed up as an answer.
    var spokenLimit: String? {
        switch self {
        case .none, .unknown: nil
        case .nationalOnly: "national speed limit"
        case let .known(text, _): "\(text) miles per hour"
        case let .national(text, _): "national speed limit, \(text)"
        case let .assumed(text, _): "assumed \(text), built-up area"
        case let .variable(text, _): text.map { "\($0), variable" } ?? "variable limit"
        }
    }
}

// MARK: - Briefing on demand

/// "Hey Siri, full report in SpeedJarvis" — every provider speaks, including the silent ones.
///
/// Deliberately separate from ``BikeStatusIntent``, which reports by exception. This one exists to
/// expose providers that have quietly stopped working: under an exception report a dead source and
/// a healthy one are indistinguishable, because both say nothing.
public struct FullReportIntent: AppIntent {
    public static let title: LocalizedStringResource = "Full report"
    public static let description = IntentDescription("Every reading, including the ones with no data.")
    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        FlightPlanRequest.shared.request(.full)
        return .result(dialog: "Reading full report.")
    }
}

/// The seam between an intent and the store.
///
/// An intent cannot dispatch, so it records a request here and `AppFeature` drains it. Coalesced to
/// a single pending value rather than queued: two taps in quick succession should produce one
/// briefing, not two overlapping ones.
public final class FlightPlanRequest: @unchecked Sendable {
    public static let shared = FlightPlanRequest()
    private let lock = NSLock()
    private var pending: FlightPlanVerbosity?

    public func request(_ verbosity: FlightPlanVerbosity) {
        lock.withLock { pending = verbosity }
    }

    public func take() -> FlightPlanVerbosity? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }
}
