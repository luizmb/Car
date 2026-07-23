import CoreLocation
import AppDomain
import FP
import Foundation
import SwiftRex
import SwiftUI
import SwiftRexArchitecture
import SwiftRexReactiveConcurrency
import ReactiveConcurrency

// MARK: - Road limit display model (view-layer, lives here to stay out of Domain)

/// Describes what the speed-limit sign area of the UI should render.
public enum RoadLimitDisplay: Sendable, Equatable {
    case none                                   // not yet fetched — show nothing
    case unknown                                // fetched, no maxspeed in OSM — show "?"
    case known(text: String, value: Double)     // explicit sign — show circular limit sign
    case national(text: String, value: Double)  // resolved national — NSL sign + limit sign
    case nationalOnly                           // unresolvable national — NSL sign only
}

// MARK: - Authorization lifecycle

public enum AuthorizationPhase: Sendable, Equatable {
    case unknown      // app just launched, haven't requested yet
    case requesting   // request dispatched, waiting for user response
    case granted      // authorizedAlways + fullAccuracy — monitoring can start
    case limited      // authorised but not ideal (whenInUse, reducedAccuracy, etc.)
    case denied       // denied or restricted
}

// MARK: - Feature

@Feature(strategy: .observationSimple)
public enum SpeedMonitorFeature {

    // MARK: - State

    public struct State: Sendable, Equatable {
        public var authorizationPhase: AuthorizationPhase
        public var lastLocation: LocationUpdate?
        public var currentRoadInfo: RoadInfo?   // nil = not yet fetched
        public var display: Display

        public struct Display: Sendable, Equatable {
            public var mapLatitude: Double
            public var mapLongitude: Double
            public var mapDistance: Double
            public var mapHeading: Double
            public var speedText: String
            public var speedValue: Double
            public var speedAccuracyText: String
            public var directionText: String
            public var courseAngleDegrees: Double
            public var coordinatesText: String
            public var altitudeText: String
            public var roadLimitDisplay: RoadLimitDisplay
            public var roadRef: String?
            public var roadName: String?

            public static let empty = Display(
                mapLatitude: 0, mapLongitude: 0, mapDistance: 500, mapHeading: 0,
                speedText: "0", speedValue: 0, speedAccuracyText: "",
                directionText: "Still", courseAngleDegrees: 0,
                coordinatesText: "?", altitudeText: "?",
                roadLimitDisplay: .none, roadRef: nil, roadName: nil
            )
        }
    }

    // MARK: - Action

    public enum Action: Sendable {
        // State machine
        case start                                       // onAppear → kick off auth workflow
        case authorizationChanged(AuthorizationUpdate)   // auth stream event
        case readyToMonitor                              // dispatched when granted; parts respond
        // GPS data
        case locationUpdate(LocationUpdate)
        case locationReady(LocationUpdate, State.Display)
        // Road speed
        case roadSpeedChanged(RoadInfo)
        case _noop
    }

    // MARK: - Environment

    public struct Environment: Sendable {
        public let requestAuthorization: @Sendable () -> Publisher<Void, Never>
        public let authorizationUpdates: @Sendable () -> Publisher<AuthorizationUpdate, Never>
        public let locationUpdates: @Sendable () -> Publisher<LocationUpdate, Never>
        public let subscribeToRoadSpeed: @Sendable () -> Publisher<RoadInfo, Never>
        public let speak: @Sendable (String) -> Publisher<Void, Never>
        public let announceOverLimit: @Sendable () -> Publisher<Void, Never>
        public let announceUnderLimit: @Sendable () -> Publisher<Void, Never>
        public let thresholds: [MPH]
        public let formatSpeed: @Sendable (MPH) -> String
        public let formatSpeedSpeech: @Sendable (MPH) -> String
        public let formatAltitude: @Sendable (Meters) -> String
        public let formatBearing: @Sendable (Course) -> String
        public let formatCoordinate: @Sendable (Latitude, Longitude) -> String

        public init(
            requestAuthorization: @escaping @Sendable () -> Publisher<Void, Never>,
            authorizationUpdates: @escaping @Sendable () -> Publisher<AuthorizationUpdate, Never>,
            locationUpdates:      @escaping @Sendable () -> Publisher<LocationUpdate, Never>,
            subscribeToRoadSpeed: @escaping @Sendable () -> Publisher<RoadInfo, Never>,
            speak:                @escaping @Sendable (String) -> Publisher<Void, Never>,
            announceOverLimit:    @escaping @Sendable () -> Publisher<Void, Never>,
            announceUnderLimit:   @escaping @Sendable () -> Publisher<Void, Never>,
            thresholds:           [MPH],
            formatSpeed:          @escaping @Sendable (MPH) -> String,
            formatSpeedSpeech:    @escaping @Sendable (MPH) -> String,
            formatAltitude:       @escaping @Sendable (Meters) -> String,
            formatBearing:        @escaping @Sendable (Course) -> String,
            formatCoordinate:     @escaping @Sendable (Latitude, Longitude) -> String
        ) {
            self.requestAuthorization = requestAuthorization
            self.authorizationUpdates = authorizationUpdates
            self.locationUpdates      = locationUpdates
            self.subscribeToRoadSpeed = subscribeToRoadSpeed
            self.speak                = speak
            self.announceOverLimit    = announceOverLimit
            self.announceUnderLimit   = announceUnderLimit
            self.thresholds           = thresholds
            self.formatSpeed          = formatSpeed
            self.formatSpeedSpeech    = formatSpeedSpeech
            self.formatAltitude       = formatAltitude
            self.formatBearing        = formatBearing
            self.formatCoordinate     = formatCoordinate
        }
    }

    // MARK: - ViewState / ViewAction

    public struct ViewState: Sendable, Equatable {
        // Map
        public var mapLatitude: Double
        public var mapLongitude: Double
        public var mapDistance: Double
        public var mapHeading: Double
        // Speed (text from injected formatter; value drives animation)
        public var speedText: String
        public var speedValue: Double
        public var speedAccuracyText: String
        // Direction
        public var directionText: String
        public var courseAngleDegrees: Double
        // Info bar
        public var coordinatesText: String
        public var altitudeText: String
        // Road info
        public var roadLimitDisplay: RoadLimitDisplay
        public var roadRef: String?
        public var roadName: String?

        init(display: State.Display) {
            mapLatitude         = display.mapLatitude
            mapLongitude        = display.mapLongitude
            mapDistance         = display.mapDistance
            mapHeading          = display.mapHeading
            speedText           = display.speedText
            speedValue          = display.speedValue
            speedAccuracyText   = display.speedAccuracyText
            directionText       = display.directionText
            courseAngleDegrees  = display.courseAngleDegrees
            coordinatesText     = display.coordinatesText
            altitudeText        = display.altitudeText
            roadLimitDisplay    = display.roadLimitDisplay
            roadRef             = display.roadRef
            roadName            = display.roadName
        }
    }

    public enum ViewAction: Sendable {
        case onAppear
    }

    // MARK: - Mappings (env-aware Readers)

    public static let mapState = Reader<Environment, @MainActor @Sendable (State) -> ViewState> { _ in
        { ViewState(display: $0.display) }
    }

    public static let mapAction = Reader<Environment, @Sendable (ViewAction) -> Action> { _ in
        const(.start)
    }

    // MARK: - Lifecycle

    public static func initialState(with _: Void) -> State {
        State(
            authorizationPhase: .unknown,
            lastLocation: nil,
            currentRoadInfo: nil,
            display: .empty
        )
    }

    // MARK: - Behavior

    /// Behavior = one-shot **commands** (react to actions) ∙ state-driven **subscriptions** (Subs).
    public static func behavior() -> Behavior<Action, State, Environment> {
        commands() <> supervisor()
    }

    /// Commands: pure reductions + one-shot effects fired in response to an action.
    private static func commands() -> Behavior<Action, State, Environment> {
        .handle { action, context in
            switch action {

            // ── 1. App launch — request authorization. The auth *subscription* lives in `supervisor`.
            case .start:
                guard context.stateBefore?.authorizationPhase == .unknown else { return .doNothing }
                return .reduce { $0.authorizationPhase = .requesting }
                    .produce { ctx in ctx.environment.requestAuthorization() |> asNoopEffect }

            // ── 2. Authorization status update ────────────────────────────────────
            case let .authorizationChanged(update):
                let wasGranted = context.stateBefore?.authorizationPhase == .granted
                let isGranted  = update.status == .authorizedAlways
                              && update.accuracy == .fullAccuracy
                let newPhase: AuthorizationPhase = {
                    if isGranted { return .granted }
                    switch update.status {
                    case .denied, .restricted: return .denied
                    default: return .limited
                    }
                }()
                return .reduce { $0.authorizationPhase = newPhase }
                    .produce { _ in
                        guard !wasGranted && isGranted else { return .empty }
                        return Effect<SpeedMonitorFeature.Action>.just(.readyToMonitor)
                    }

            // ── 3. Granted — show "?" while the first Overpass fetch is in flight. The location &
            //       road-speed *subscriptions* start automatically in `supervisor` (phase == .granted).
            case .readyToMonitor:
                return .reduce { $0.currentRoadInfo = .unknown }

            case let .locationUpdate(newLocation):
                let prevLocation = context.stateBefore?.lastLocation
                let roadInfo     = context.stateBefore?.currentRoadInfo
                return .produce { ctx in
                    let display = buildDisplay(newLocation, roadInfo: roadInfo, env: ctx.environment)
                    return Effect.just(.locationReady(newLocation, display))
                        <> audioEffects(
                            prev: prevLocation, new: newLocation,
                            roadInfo: roadInfo, env: ctx.environment
                        )
                }

            case let .locationReady(location, display):
                return .reduce {
                    $0.lastLocation = location
                    $0.display      = display
                }

            case let .roadSpeedChanged(info):
                let prevInfo     = context.stateBefore?.currentRoadInfo
                let lastLocation = context.stateBefore?.lastLocation
                return .reduce { $0.currentRoadInfo = info }
                    .produce { ctx in
                        let announce = (info.limit != prevInfo?.limit)
                            ? announceRoadInfo(info, env: ctx.environment)
                            : .empty
                        let refresh = lastLocation.map { loc in
                            Effect<SpeedMonitorFeature.Action>.just(.locationReady(
                                loc,
                                buildDisplay(loc, roadInfo: info, env: ctx.environment)
                            ))
                        } ?? .empty
                        return announce <> refresh
                    }

            case ._noop:
                return .doNothing
            }
        }
    }

    /// Subscriptions (Subs): the *complete* set of long-lived channels that should be alive for the
    /// current state. SwiftRex reconciles — opening `location`/`road-speed` when `authorizationPhase`
    /// becomes `.granted` and cancelling them if it ever leaves — so there's no manual
    /// `replacing(id:)` / cancellation bookkeeping.
    private static func supervisor() -> Behavior<Action, State, Environment> {
        .supervise { state in
            Supervision { env in
                var channels: [Channel<Action>] = []
                // Auth updates: from the moment we start requesting, for the app's lifetime.
                if state.authorizationPhase != .unknown {
                    channels.append(env.authorizationUpdates().asChannel(id: "auth", Action.authorizationChanged))
                }
                // Location + road speed: only while fully authorized.
                if state.authorizationPhase == .granted {
                    channels.append(env.locationUpdates().asChannel(id: "location", Action.locationUpdate))
                    channels.append(env.subscribeToRoadSpeed().asChannel(id: "road-speed", Action.roadSpeedChanged))
                }
                return channels
            }
        }
    }

    public typealias Content = SpeedMonitorView
}

// MARK: - Effect helpers

private let asNoopEffect: @Sendable (Publisher<Void, Never>) -> Effect<SpeedMonitorFeature.Action> =
    { $0.asEffect { (_: Void) in SpeedMonitorFeature.Action._noop } }


// MARK: - Audio

/// Announces the new road info when the limit changes — includes road ref/name if available.
private func announceRoadInfo(
    _ info: RoadInfo,
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    let limitText: String
    switch info.limit {
    case .unknown:          return .empty
    case .national:         limitText = "national"
    case .value(let mph):   limitText = (mph |> env.formatSpeedSpeech) + " zone"
    }
    let roadLabel = info.ref ?? info.name     // prefer ref ("A40") over name ("High Street")
    let text = roadLabel.map { "\(limitText), \($0)" } ?? limitText
    return text |> (env.speak >>> asNoopEffect)
}

/// All audio effects for a speed change: TTS up, k down, beeps — combined.
private func audioEffects(
    prev: LocationUpdate?,
    new: LocationUpdate,
    roadInfo: RoadInfo?,
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    let toMph    = Iso<MPS, MPH>.convert.get
    guard let prevMph = prev?.speed.map(toMph) else { return .empty }
    let newMph = new.speed.map(toMph) ?? MPH(0)
    let roadLimit = roadInfo?.limit ?? .unknown

    return ttsUp(prevMph: prevMph, newMph: newMph, thresholds: env.thresholds, env: env)
        <> kDown(prevMph: prevMph, newMph: newMph, roadLimit: roadLimit, thresholds: env.thresholds, env: env)
        <> beeps(prevMph: prevMph, newMph: newMph, roadLimit: roadLimit, env: env)
}

/// TTS up: fires "twenty-two", "thirty-three", etc. at threshold crossings — ALWAYS, regardless of road limit.
private func ttsUp(
    prevMph: MPH, newMph: MPH,
    thresholds: [MPH],
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    thresholds.first { prevMph < $0 && newMph >= $0 }
        .map { $0 |> (env.formatSpeedSpeech >>> env.speak >>> asNoopEffect) }
    ?? .empty
}

/// "k" down: fires when crossing back to legal (known limit) or at every threshold (national/unknown).
private func kDown(
    prevMph: MPH, newMph: MPH,
    roadLimit: RoadSpeedLimit,
    thresholds: [MPH],
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    switch roadLimit {
    case .value(let limit):
        guard prevMph >= limit && newMph < limit else { return .empty }
        return env.speak("k") |> asNoopEffect
    case .unknown, .national:
        return thresholds.first { prevMph >= $0 && newMph < $0 }
            .map { _ in env.speak("k") |> asNoopEffect }
        ?? .empty
    }
}

/// Beeps: fires at exact known limits (or national fixed limits) on crossings up and down.
private func beeps(
    prevMph: MPH, newMph: MPH,
    roadLimit: RoadSpeedLimit,
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    let beepLimits: [MPH]
    switch roadLimit {
    case .value(let limit): beepLimits = [limit]
    case .national:         beepLimits = nationalBeepLimits
    case .unknown:          return .empty
    }
    let up   = beepLimits.first { prevMph < $0 && newMph >= $0 }
        .map { _ in env.announceOverLimit()  |> asNoopEffect } ?? .empty
    let down = beepLimits.first { prevMph >= $0 && newMph < $0 }
        .map { _ in env.announceUnderLimit() |> asNoopEffect } ?? .empty
    return up <> down
}

// MARK: - Display builder

private func buildDisplay(
    _ loc: LocationUpdate,
    roadInfo: RoadInfo?,
    env: SpeedMonitorFeature.Environment
) -> SpeedMonitorFeature.State.Display {
    let toMph    = Iso<MPS, MPH>.convert.get
    let speedMph = loc.speed.map(toMph)

    let dirText: String = loc.course.map { course in
        (CompassDirection8(course: course) <&> { dir in
            dir.rawValue + " " + env.formatBearing(course)
        }) ?? "Still"
    } ?? "Still"

    let roadLimitDisplay: RoadLimitDisplay
    if let info = roadInfo {
        switch info.limit {
        case .unknown:
            roadLimitDisplay = .unknown
        case .national:
            roadLimitDisplay = .nationalOnly
        case .value(let mph):
            let text  = mph |> env.formatSpeedSpeech
            let value = mph.rawValue
            roadLimitDisplay = info.resolvedFromNational
                ? .national(text: text, value: value)
                : .known(text: text, value: value)
        }
    } else {
        roadLimitDisplay = .none
    }

    return .init(
        mapLatitude:        loc.latitude.rawValue,
        mapLongitude:       loc.longitude.rawValue,
        mapDistance:        speedMph.map { max(200, min(1250, $0.rawValue * 50)) } ?? 500,
        mapHeading:         loc.course?.rawValue ?? 0,
        speedText:          speedMph.map(env.formatSpeedSpeech) ?? "0",
        speedValue:         speedMph?.rawValue ?? 0,
        speedAccuracyText:  loc.speedAccuracy.map(toMph >>> env.formatSpeedSpeech).map("±".appending) ?? "",
        directionText:      dirText,
        courseAngleDegrees: 360 - (loc.course?.rawValue ?? 0),
        coordinatesText:    env.formatCoordinate(loc.latitude, loc.longitude),
        altitudeText:       env.formatAltitude(loc.altitude),
        roadLimitDisplay:   roadLimitDisplay,
        roadRef:            roadInfo?.ref,
        roadName:           roadInfo?.name
    )
}

// The @Feature macro generates the members but does not add the conformance.