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

/// Where the rider has dragged the map to — the camera as values, not as a UI handle.
///
/// `MapCameraPosition` is a SwiftUI artifact and has no business in a store; these five numbers
/// are what it actually says. Holding them here is what lets the map's browsing obey the same law
/// as everything else: the gesture is an event, the store decides, the view renders the answer.
public struct BrowsedCamera: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var distance: Double
    public var heading: Double
    public var pitch: Double

    public init(latitude: Double, longitude: Double, distance: Double, heading: Double, pitch: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.distance = distance
        self.heading = heading
        self.pitch = pitch
    }
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
        /// The cameras on the road being ridden, when the extract can answer that question.
        ///
        /// The rider's design: query by the road just joined, discard on the next road. `nil` means
        /// the question could not be answered — old extract, abroad — and the radius set above
        /// stays authoritative. An **empty** array is an answer: this road has no cameras, and
        /// nothing from a slip road or a crossing street can leak in to say otherwise.
        public var roadCameras: [SpeedCamera]?
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
        /// Distance to the next manoeuvre, when following a route.
        public var nextTurn: Meters?
        /// Where the rider has dragged the map, or `nil` while it follows the bike. Store state,
        /// not view state: the recentre button, the auto-return rule and the rendering all read
        /// the same value, and the browse gesture arrives as an action like every other event.
        public var browsedCamera: BrowsedCamera?
        /// Fixes since the rider last touched the map. The auto-return clock, in the only ticks
        /// the domain has: two fixes with the bike moving and the map is the bike's again.
        public var fixesSinceMapTouch: Int

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
        /// How far to the next manoeuvre, or `nil` when not following one. Drives the camera only —
        /// the instruction itself belongs to the banner.
        case setNextTurn(Meters?)
        /// The rider dragged, zoomed or rotated the map to here.
        case mapBrowsed(BrowsedCamera)
        /// The map goes back to the bike — the recentre button, or the auto-return rule.
        case mapFollowResumed
        case locationReady(LocationUpdate, State.Display)
        // Road speed
        case roadSpeedChanged(RoadInfo)
        /// Something suggests the road has changed — an indicator cancelling, say. A *semantic*
        /// signal, where the 300m/20s throttle is only a proxy: a turn means a new road
        /// immediately, whereas distance alone might not notice for a quarter of a mile.
        case roadMayHaveChanged
        // Cameras
        case camerasChanged(CameraSet)
        /// The cameras on the road just joined, or `nil` when the extract cannot say.
        case roadCamerasChanged([SpeedCamera]?)
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
        /// The cameras on one road, from the extract. `nil` when it cannot answer.
        public let camerasOnRoad: @Sendable (RoadKey, Latitude, Longitude) -> Publisher<[SpeedCamera]?, Never>
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
            camerasOnRoad:        @escaping @Sendable (RoadKey, Latitude, Longitude) -> Publisher<[SpeedCamera]?, Never>,
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
            self.camerasOnRoad        = camerasOnRoad
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
        public var browsedCamera: BrowsedCamera?
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

        init(
            display: State.Display, routeShape: [Coordinate], nextTurn: Meters?,
            browsedCamera: BrowsedCamera?
        ) {
            self.browsedCamera  = browsedCamera
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
                // Along the route — but only while actually on it.
                //
                // `routeBearing` takes the nearest vertex and looks ahead from there, which is the
                // right answer on the line and a meaningless one off it: the nearest vertex to a
                // rider who has left the route can be behind them, or on a different leg entirely,
                // and the map then points confidently the wrong way. Seen on a replayed ride that
                // spent most of its length off-route — the rotation was simply wrong.
                //
                // Off the line, the direction of travel is the only thing that is true.
                let onRoute = distanceToRoute(shape: routeShape, from: here) <= offRouteMetres
                let along = (onRoute ? routeBearing(shape: routeShape, from: here) : nil)
                    .flatMap { bearing -> Double? in
                        // And discard it if it points backwards. A route that goes out and comes
                        // home runs along the same roads twice, so the nearest vertex can belong to
                        // the *other* leg and the map then faces the way the rider has come. Beyond
                        // a right angle and a half from the direction of travel, the match is
                        // wrong rather than the rider turning.
                        guard display.speedValue > 3 else { return bearing }
                        var apart = abs(bearing - display.mapHeading)
                            .truncatingRemainder(dividingBy: 360)
                        if apart > 180 { apart = 360 - apart }
                        return apart <= 135 ? bearing : nil
                    }
                    ?? display.mapHeading
                cameraDistance = navigationCameraDistance(
                    speed: MPS(display.speedValue * 0.44704), nextTurn: nextTurn
                )
                // The rider sits low on screen, and how far ahead the camera looks scales with how
                // far it can see — a fixed offset puts them in the middle again when zoomed out.
                cameraCentre   = coordinate(from: here, bearing: along, metres: cameraDistance * 0.26)
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
        case mapBrowsed(BrowsedCamera)
        case mapRecentre
    }

    // MARK: - Mappings (env-aware Readers)

    public static let mapState = Reader<Environment, @MainActor @Sendable (State) -> ViewState> { _ in
        { ViewState(
            display: $0.display, routeShape: $0.routeShape, nextTurn: $0.nextTurn,
            browsedCamera: $0.browsedCamera
        ) }
    }

    public static let mapAction = Reader<Environment, @Sendable (ViewAction) -> Action> { _ in
        { viewAction in
            switch viewAction {
            case .onAppear: .start
            case let .mapBrowsed(camera): .mapBrowsed(camera)
            case .mapRecentre: .mapFollowResumed
            }
        }
    }

    // MARK: - Lifecycle

    public static func initialState(with _: Void) -> State {
        State(
            authorizationPhase: .unknown,
            lastLocation: nil,
            currentRoadInfo: nil,
            cameras: [],
            roadCameras: nil,
            announcedCameraIDs: [],
            averageZones: [],
            activeAverageZone: nil,
            wasOverAverageLimit: false,
            display: .empty,
            routeShape: [],
            nextTurn: nil,
            browsedCamera: nil,
            fixesSinceMapTouch: 0
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

            case let .setNextTurn(distance):
                return .reduce { $0.nextTurn = distance }

            case let .mapBrowsed(camera):
                return .reduce {
                    $0.browsedCamera = camera
                    $0.fixesSinceMapTouch = 0
                }

            case .mapFollowResumed:
                return .reduce {
                    $0.browsedCamera = nil
                    $0.fixesSinceMapTouch = 0
                }

            case let .locationUpdate(newLocation):
                // The auto-return rule: a browsed map is handed back to the bike once the rider is
                // demonstrably riding again — two fixes after the last touch, above 5 mph. Stopped
                // at the kerb studying the next junctions they are left alone indefinitely; moving,
                // a map showing somewhere else is a map showing the wrong thing. Counted in fixes
                // because a fix a second is the only clock the domain has.
                let browsing = context.stateBefore?.browsedCamera != nil
                let touchedFixes = (context.stateBefore?.fixesSinceMapTouch ?? 0) + 1
                let resume = browsing
                    && touchedFixes >= 2
                    && (newLocation.speed?.rawValue ?? 0) > 2.24

                let prevLocation = context.stateBefore?.lastLocation
                let roadInfo     = context.stateBefore?.currentRoadInfo
                let cameras      = context.stateBefore?.cameras ?? []
                let announced    = context.stateBefore?.announcedCameraIDs ?? []
                let zones        = context.stateBefore?.averageZones ?? []
                let activeZone   = context.stateBefore?.activeAverageZone
                let wasOver      = context.stateBefore?.wasOverAverageLimit ?? false
                let routeShape   = context.stateBefore?.routeShape ?? []
                let roadCameras  = context.stateBefore?.roadCameras
                return .reduce {
                    if $0.browsedCamera != nil { $0.fixesSinceMapTouch += 1 }
                }
                .produce { ctx in
                    let handBack: Effect<SpeedMonitorFeature.Action> = resume
                        ? .just(.mapFollowResumed)
                        : .empty
                    let display = buildDisplay(
                        previous: prevLocation, to: newLocation,
                        roadInfo: roadInfo, env: ctx.environment
                    )
                    return handBack
                        <> Effect.just(.locationReady(newLocation, display))
                        <> audioEffects(
                            prev: prevLocation, new: newLocation,
                            roadInfo: roadInfo, env: ctx.environment
                        )
                        <> cameraEffects(
                            at: newLocation, cameras: cameras, roadCameras: roadCameras,
                            announced: announced, roadInfo: roadInfo, routeShape: routeShape,
                            env: ctx.environment
                        )
                        <> averageZoneEffects(
                            at: newLocation,
                            // Same filter the cameras get, and for the same reason: a zone is
                            // entered when its start is within 250 m, which in a town reaches
                            // roads the rider is nowhere near.
                            zones: plausible(
                                onRoute(nearby(zones, of: newLocation), shape: routeShape),
                                onRoadLimited: roadLimitFor(roadInfo)
                            ),
                            cameras: cameras,
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
                                buildDisplay(
                                    // The same fix, rebuilt because the road changed rather than
                                    // because the bike moved — so there is no delta, and
                                    // `travelHeading` keeps whatever the fix already knows.
                                    previous: loc, to: loc,
                                    roadInfo: info, env: ctx.environment
                                )
                            ))
                        } ?? .empty
                        // The road changed hands — ask the extract which cameras stand on the new
                        // one, and discard the old road's set either way. Asked only on an actual
                        // change of identity: road detection re-fires constantly for the same
                        // road, and the answer cannot differ.
                        let roadCameras: Effect<SpeedMonitorFeature.Action>
                        if info.key != prevInfo?.key {
                            if let key = info.key, let loc = lastLocation {
                                roadCameras = ctx.environment
                                    .camerasOnRoad(key, loc.latitude, loc.longitude)
                                    .asEffect(Action.roadCamerasChanged)
                            } else {
                                // No identity — geocoder fallback, or an unnamed way. The radius
                                // set is all there is, and saying so beats holding the previous
                                // road's cameras against a road they are not on.
                                roadCameras = .just(.roadCamerasChanged(nil))
                            }
                        } else {
                            roadCameras = .empty
                        }
                        return announce <> refresh <> roadCameras
                    }

            case let .roadCamerasChanged(cameras):
                return .reduce { $0.roadCameras = cameras }

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
    roadCameras: [SpeedCamera]?,
    announced: Set<Int>,
    roadInfo: RoadInfo?,
    routeShape: [Coordinate],
    env: SpeedMonitorFeature.Environment
) -> Effect<SpeedMonitorFeature.Action> {
    guard !(roadCameras ?? cameras).isEmpty else { return .empty }

    let speed = location.speed ?? MPS(0)
    // **Cheap filter first.** `onRoute` measures every camera against every segment of the route,
    // so running it over the whole set was 264 cameras times 20,000 points — five million distance
    // calculations a second, which froze the app outright. `camerasAhead` is a bounded cone and a
    // lookahead, and cuts the set to a handful before the expensive test runs.
    //
    // While following a route, only cameras actually *on* it count: the ±100° cone is deliberately
    // permissive, and at a roundabout that means every camera on every arm — six announced in
    // forty-three seconds on one ride, plus a 70 mph camera on a motorway crossing perpendicular.
    // The road's own limit, where it is known — a camera claiming to enforce a much higher speed
    // is watching a different road.
    // The road-matched set when the extract answered; the radius set plus heuristics otherwise.
    // The heuristics — route corridor, limit plausibility — exist to compensate for the radius set
    // not knowing which road anything is on. A road-matched camera answered that at extract time,
    // by geometry, and heuristics on top would only reintroduce the false negatives they trade in:
    // the same-limit slip-road camera is excluded here by class, not guessed at by limit.
    let ahead: [SpeedCamera]
    if let roadCameras {
        ahead = camerasAhead(
            roadCameras,
            at: (location.latitude, location.longitude),
            course: location.course,
            speed: speed
        )
        .filter { facingCompatible($0, course: location.course) }
    } else {
        ahead = plausible(
            onRoute(
                camerasAhead(
                    cameras,
                    at: (location.latitude, location.longitude),
                    course: location.course,
                    speed: speed
                ),
                shape: routeShape
            ),
            onRoadLimited: roadLimitFor(roadInfo)
        )
        .filter { facingCompatible($0, course: location.course) }
    }
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
        // Queued, not interrupting. `speak` stops whatever is playing, and crossing a threshold on
        // the way out of a junction is exactly when a road announcement is mid-sentence: "forty
        // z—" cut off by "eleven" was heard on a real ride. A number half a second late is worth
        // far more than a limit the rider never hears.
        .map { $0 |> (env.formatSpeedSpeech >>> env.announceRoad >>> Effect.fireAndForget) }
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

/// Which way the bike is actually going.
///
/// `CLLocation.course` first, since that is what the receiver computed — but it is `nil` far more
/// often than expected: eighteen fixes out of a replayed ride reported none, and the old fallback
/// was zero, which is north. A map that snaps north every few seconds while riding south is worse
/// than one that lags.
///
/// So the fallback is the bearing between the last two positions, which is what course over ground
/// *is*. Below three metres of movement it keeps the previous answer rather than amplifying the
/// noise in a stationary fix into a spinning map.
func travelHeading(from previous: LocationUpdate?, to current: LocationUpdate) -> Double {
    if let course = current.course { return course.rawValue }
    guard let previous else { return 0 }
    let from = (previous.latitude, previous.longitude)
    let to = (current.latitude, current.longitude)
    guard distanceMetres(from: from, to: to) >= 3 else {
        return previous.course?.rawValue ?? 0
    }
    return bearing(from: from, to: to)
}

private func buildDisplay(
    previous: LocationUpdate?,
    to loc: LocationUpdate,
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
        mapHeading:         travelHeading(from: previous, to: loc),
        speedText:          speedMph.map(env.formatSpeedSpeech) ?? "0",
        speedValue:         speedMph?.rawValue ?? 0,
        speedAccuracyText:  loc.speedAccuracy.map(toMph >>> env.formatSpeedSpeech).map("±".appending) ?? "",
        directionText:      dirText,
        courseAngleDegrees: 360 - travelHeading(from: previous, to: loc),
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
/// Zones whose ends are anywhere near the rider, by straight line.
///
/// A cheap sieve before the expensive one. `onRoute` walks the whole route polyline per zone, so it
/// must not be handed the national set — the same mistake that froze the app on cameras.
private func nearby(_ zones: [AverageZone], of location: LocationUpdate) -> [AverageZone] {
    let here = (location.latitude, location.longitude)
    return zones.filter { zone in
        [zone.start, zone.end].compactMap { $0 }.contains {
            distanceMetres(from: here, to: $0.pair) < 3_000
        }
    }
}

/// The road's signed limit, where OSM has one.
func roadLimitFor(_ roadInfo: RoadInfo?) -> MPH? {
    if case let .value(mph) = roadInfo?.limit { return mph }
    return nil
}

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
