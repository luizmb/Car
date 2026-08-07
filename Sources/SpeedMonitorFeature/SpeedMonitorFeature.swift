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
    /// Inferred from a built-up-area classification. Deliberately *not* `.national`: showing the NSL
    /// sign beside a 30 would be a contradiction, since that sign means 60 or 70.
    case assumed(text: String, value: Double)
    /// Smart motorway. The figure is OSM's default, not what the gantries currently read, so the
    /// sign is marked rather than presented as fact.
    case variable(text: String?, value: Double)
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
        /// Every enforcement camera within the last fetch radius, ahead or behind. Filtered per fix
        /// rather than per fetch, so a camera does not vanish because the network did.
        public var cameras: [SpeedCamera]
        /// Cameras already spoken on this approach, so a warning is given once rather than once per
        /// GPS fix. Pruned when a camera leaves the fetched set — which means riding back the other
        /// way legitimately announces it again.
        public var announcedCameraIDs: Set<Int>
        /// Average-speed zones known from the last fetch.
        public var averageZones: [AverageZone]
        /// The zone you are inside, if any. Being *inside* is the state that matters — a point
        /// warning cannot describe a measurement taken over kilometres.
        public var activeAverageZone: AverageZone?
        /// Whether the last fix was above the active zone's limit, so the reminder fires on the
        /// crossing rather than on every fix while you sit above it.
        public var wasOverAverageLimit: Bool
        public var display: Display
        /// The chosen route's shape, drawn under the rider.
        ///
        /// Held outside `Display` deliberately. `Display` is rebuilt from scratch on every fix, and
        /// a route is thousands of points even after thinning — copying and `Equatable`-comparing
        /// that once a second would become the most expensive thing the app does, to redraw a line
        /// that has not changed.
        public var routeShape: [Coordinate]

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
        /// The route to draw, already thinned. Empty clears it.
        case setRoute([Coordinate])
        case locationReady(LocationUpdate, State.Display)
        // Road speed
        case roadSpeedChanged(RoadInfo)
        /// Something suggests the road has changed — an indicator cancelling, say. A *semantic*
        /// signal, where the 300m/20s throttle is only a proxy: a turn means a new road
        /// immediately, whereas distance alone might not notice for a quarter of a mile.
        case roadMayHaveChanged
        // Cameras
        case camerasChanged(CameraSet)
        case camerasAnnounced(Set<Int>)
        /// Entering or leaving an average-speed zone. `nil` means left.
        case averageZoneChanged(AverageZone?)
        /// Crossed above or back below the active zone's limit.
        case averageZoneOverLimitChanged(Bool)
    }

    // MARK: - Environment

    public struct Environment: Sendable {
        public let requestAuthorization: @Sendable () -> Publisher<Void, Never>
        public let authorizationUpdates: @Sendable () -> Publisher<AuthorizationUpdate, Never>
        public let locationUpdates: @Sendable () -> Publisher<LocationUpdate, Never>
        public let subscribeToRoadSpeed: @Sendable () -> Publisher<RoadInfo, Never>
        public let subscribeToCameras: @Sendable () -> Publisher<CameraSet, Never>
        public let refreshRoadNow: @Sendable (Latitude, Longitude) -> Publisher<Void, Never>
        public let speak: @Sendable (String) -> Publisher<Void, Never>
        /// Queues rather than interrupts. Road announcements are informational and must not cut a
        /// threshold crossing in half — nor be cut by one.
        public let announceRoad: @Sendable (String) -> Publisher<Void, Never>
        /// Also queued. A camera warning must never cut a threshold announcement in half, nor be cut
        /// by one — and unlike a speed call it stays useful a second late.
        public let announceCamera: @Sendable (String) -> Publisher<Void, Never>
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
            subscribeToCameras:   @escaping @Sendable () -> Publisher<CameraSet, Never>,
            refreshRoadNow:       @escaping @Sendable (Latitude, Longitude) -> Publisher<Void, Never>,
            speak:                @escaping @Sendable (String) -> Publisher<Void, Never>,
            announceRoad:         @escaping @Sendable (String) -> Publisher<Void, Never>,
            announceCamera:       @escaping @Sendable (String) -> Publisher<Void, Never>,
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
            self.subscribeToCameras   = subscribeToCameras
            self.refreshRoadNow       = refreshRoadNow
            self.speak                = speak
            self.announceRoad         = announceRoad
            self.announceCamera       = announceCamera
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
        /// Carried alongside `Display` rather than inside it, because it changes once per journey
        /// while `Display` is rebuilt on every fix.
        public var routeShape: [Coordinate]
        /// Where the camera looks, how far back it sits and how far it leans.
        ///
        /// Two modes. Idle, it hovers over the rider — fine for "where am I". Following a route it
        /// drops closer, leans over, and aims at a point ahead so the rider sits low on screen with
        /// the road they are about to ride filling it, which is the only part that can still be
        /// acted on.
        public var cameraCentre: Coordinate
        public var cameraDistance: Double
        public var cameraPitch: Double
        /// Which way is up. Following a route this is the route's own direction rather than the GPS
        /// course, which is undefined when stopped and jitters at walking pace.
        public var cameraHeading: Double

        init(display: State.Display, routeShape: [Coordinate]) {
            self.routeShape     = routeShape
            let here = Coordinate(
                latitude: Latitude(display.mapLatitude), longitude: Longitude(display.mapLongitude)
            )
            if routeShape.isEmpty {
                cameraCentre   = here
                cameraDistance = display.mapDistance
                cameraPitch    = 45
                cameraHeading  = display.mapHeading
            } else {
                let along = routeBearing(shape: routeShape, from: here) ?? display.mapHeading
                cameraCentre   = coordinate(from: here, bearing: along, metres: 110)
                cameraDistance = 420
                cameraPitch    = 68
                cameraHeading  = along
            }
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
        { ViewState(display: $0.display, routeShape: $0.routeShape) }
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
            cameras: [],
            announcedCameraIDs: [],
            averageZones: [],
            activeAverageZone: nil,
            wasOverAverageLimit: false,
            display: .empty,
            routeShape: []
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
                    .produce { ctx in ctx.environment.requestAuthorization() |> Effect.fireAndForget }

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

            case let .setRoute(shape):
                return .reduce { $0.routeShape = shape }

            case let .locationUpdate(newLocation):
                let prevLocation = context.stateBefore?.lastLocation
                let roadInfo     = context.stateBefore?.currentRoadInfo
                let cameras      = context.stateBefore?.cameras ?? []
                let announced    = context.stateBefore?.announcedCameraIDs ?? []
                let zones        = context.stateBefore?.averageZones ?? []
                let activeZone   = context.stateBefore?.activeAverageZone
                let wasOver      = context.stateBefore?.wasOverAverageLimit ?? false
                return .produce { ctx in
                    let display = buildDisplay(newLocation, roadInfo: roadInfo, env: ctx.environment)
                    return Effect.just(.locationReady(newLocation, display))
                        <> audioEffects(
                            prev: prevLocation, new: newLocation,
                            roadInfo: roadInfo, env: ctx.environment
                        )
                        <> cameraEffects(
                            at: newLocation, cameras: cameras,
                            announced: announced, roadInfo: roadInfo, env: ctx.environment
                        )
                        <> averageZoneEffects(
                            at: newLocation, zones: zones, cameras: cameras,
                            active: activeZone, wasOver: wasOver, env: ctx.environment
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
                        let announce = (info.announcement != prevInfo?.announcement)
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

            case let .camerasChanged(set):
                return .reduce {
                    $0.cameras = set.cameras
                    $0.averageZones = set.zones
                    // Keep the spoken flags only for cameras still in range. Anything that has
                    // dropped out has been left behind, so approaching it again should speak again.
                    $0.announcedCameraIDs.formIntersection(Set(set.cameras.map(\.id)))
                    // A zone that has fallen out of the fetched area is behind us. This is the only
                    // exit available for zones mapped without a `to` member.
                    if let active = $0.activeAverageZone, !set.zones.contains(where: { $0.id == active.id }) {
                        $0.activeAverageZone = nil
                        $0.wasOverAverageLimit = false
                    }
                }

            case let .averageZoneOverLimitChanged(over):
                return .reduce { $0.wasOverAverageLimit = over }

            case let .averageZoneChanged(zone):
                return .reduce {
                    $0.activeAverageZone = zone
                    $0.wasOverAverageLimit = false
                }

            case let .camerasAnnounced(ids):
                return .reduce { $0.announcedCameraIDs.formUnion(ids) }

            case .roadMayHaveChanged:
                // Bring the lookup forward instead of blanking what we know.
                //
                // Blanking used to be the whole response, on the theory that the next Overpass answer
                // would replace it. It would — up to 300 m later, because that is the road manager's
                // distance filter. So every turn was followed by a third of a minute with no limit,
                // no beeps and no announcement, ending long after the turn it belonged to.
                //
                // Keeping the old road until the new one arrives is strictly better: the limit stays
                // live across the junction, and `roadSpeedChanged` still announces on any genuine
                // change because it compares announcements, not identity. A roundabout cancelling
                // the indicator repeatedly costs a few extra fixes, not a fetch storm — the 20 s
                // gate is restored the moment the forced fix lands.
                guard let here = context.stateBefore?.lastLocation else { return .doNothing }
                return .produce { ctx in
                    ctx.environment.refreshRoadNow(here.latitude, here.longitude)
                        |> Effect.fireAndForget
                }
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
                    channels.append(env.subscribeToCameras().asChannel(id: "cameras", Action.camerasChanged))
                }
                return channels
            }
        }
    }

    public typealias Content = SpeedMonitorView
}

// MARK: - Effect helpers

// MARK: - Audio

/// Announces the road: its limit, its name, or both — "thirty zone, High Street".
///
/// The limit being `.unknown` no longer silences the whole announcement. An unnamed limit and an
/// unlimited name are independently useful, so each is spoken whenever it is there; only a road with
/// neither says nothing at all.
private func announceRoadInfo(
    _ info: RoadInfo,
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    let spoken = roadAnnouncement(info, formatSpeed: env.formatSpeedSpeech)
    guard !spoken.isEmpty else { return .empty }
    return spoken |> (env.announceRoad >>> Effect.fireAndForget)
}

/// Warns about the nearest camera not yet announced on this approach.
///
/// **One per fix, nearest first.** Announcing every fresh camera at once would deliver three
/// sentences in a breath at the one moment attention is worth most; taking only the nearest lets the
/// following fixes deal with the rest, a second apart, in the order you will reach them.
///
/// The speed spoken is the one from *this* fix, so "you're at thirty-four" is true when said rather
/// than when the camera was fetched.
private func cameraEffects(
    at location: LocationUpdate,
    cameras: [SpeedCamera],
    announced: Set<Int>,
    roadInfo: RoadInfo?,
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    guard !cameras.isEmpty else { return .empty }

    let speed = location.speed ?? MPS(0)
    let ahead = camerasAhead(
        cameras,
        at: (location.latitude, location.longitude),
        course: location.course,
        speed: speed
    )
    guard let next = ahead.first(where: { !announced.contains($0.id) }) else { return .empty }

    let spoken = cameraAnnouncement(
        next,
        currentSpeed: speed |> Iso<MPS, MPH>.convert.get,
        roadInfo: roadInfo,
        formatSpeed: env.formatSpeedSpeech
    )
    return (spoken |> (env.announceCamera >>> Effect.fireAndForget))
        <> Effect.just(.camerasAnnounced([next.id]))
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
        .map { $0 |> (env.formatSpeedSpeech >>> env.speak >>> Effect.fireAndForget) }
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
        return env.speak("k") |> Effect.fireAndForget
    case .unknown, .national:
        return thresholds.first { prevMph >= $0 && newMph < $0 }
            .map { _ in env.speak("k") |> Effect.fireAndForget }
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
        .map { _ in env.announceOverLimit()  |> Effect<SpeedMonitorFeature.Action>.fireAndForget } ?? .empty
    let down = beepLimits.first { prevMph >= $0 && newMph < $0 }
        .map { _ in env.announceUnderLimit() |> Effect<SpeedMonitorFeature.Action>.fireAndForget } ?? .empty
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
            roadLimitDisplay = info.isVariable ? .variable(text: nil, value: 0) : .nationalOnly
        case .value(let mph):
            let text = mph |> env.formatSpeedSpeech
            let value = mph.rawValue
            if info.isVariable {
                roadLimitDisplay = .variable(text: text, value: value)
            } else {
                switch info.origin {
                case .signed: roadLimitDisplay = .known(text: text, value: value)
                case .builtUpArea: roadLimitDisplay = .assumed(text: text, value: value)
                case .nationalSpeedLimit: roadLimitDisplay = .national(text: text, value: value)
                case .unattributed: roadLimitDisplay = .known(text: text, value: value)
                }
            }
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
/// Entering, leaving, and going too fast inside an average-speed zone.
///
/// These are three different sentences because they answer three different questions, and the middle
/// one is the reason a point warning is not enough: inside a zone a moment above the limit is not the
/// offence — the mean between the gantries is. So the reminder fires on the *crossing*, not on every
/// fix, and says what is actually being measured.
private func averageZoneEffects(
    at location: LocationUpdate,
    zones: [AverageZone],
    cameras: [SpeedCamera],
    active: AverageZone?,
    wasOver: Bool,
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    let position = Coordinate(latitude: location.latitude, longitude: location.longitude)
    let mph = (location.speed ?? MPS(0)) |> Iso<MPS, MPH>.convert.get

    // Leaving takes precedence: if the same fix is near this zone's end and another's start, the one
    // being left is the one you are certainly in.
    if let active, averageZoneExited(active, at: position) {
        return (averageZoneEndAnnouncement(active) |> (env.announceCamera >>> Effect.fireAndForget))
            <> Effect.just(.averageZoneChanged(nil))
    }

    if let entered = averageZoneEntered(zones: zones, cameras: cameras, at: position, currentZone: active) {
        let spoken = averageZoneStartAnnouncement(entered, currentSpeed: mph, formatSpeed: env.formatSpeedSpeech)
        return (spoken |> (env.announceCamera >>> Effect.fireAndForget))
            <> Effect.just(.averageZoneChanged(entered))
    }

    guard let active, let limit = active.limit else { return .empty }
    let over = mph.rawValue > limit.rawValue
    guard over != wasOver else { return .empty }
    guard over else { return Effect.just(.averageZoneOverLimitChanged(false)) }

    let spoken = averageZoneOverLimitAnnouncement(active, currentSpeed: mph, formatSpeed: env.formatSpeedSpeech)
    return (spoken |> (env.announceCamera >>> Effect.fireAndForget))
        <> Effect.just(.averageZoneOverLimitChanged(true))
}
