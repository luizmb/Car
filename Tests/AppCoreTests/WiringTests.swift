import AppDomain
import Foundation
import Testing
import ReactiveConcurrency
import SpeedMonitorFeature
@testable import AppCore

// These exist because a whole class of regression shipped twice without anything noticing.
//
// An edit deleted every `AppScopes.*.behavior(of:)` line from `AppFeature.behavior()`. It compiled
// — a `Behavior` monoid with fewer terms is still a valid `Behavior` — and every test passed,
// because all of them covered pure functions: parsers, threshold logic, briefing composition.
// Nothing asserted the app's features were actually *connected*, so two TestFlight builds went out
// containing an app that launched and did nothing at all.
//
// The lesson is not "test more". It is that a monoid of behaviours has no arity to get wrong, so
// the compiler cannot help here and something else must.

@Suite("App wiring")
@MainActor
struct WiringTests {

    /// The store dispatches `appLaunch` on creation, and each feature reacts to actions it owns.
    /// Building a real store with a stub `World` and observing that state actually changes is the
    /// cheapest available proof that the scopes are lifted.
    @Test("every feature slice is reachable from the app store")
    func featuresAreWired() {
        let store = MainStore.app(world: .stub)

        // Indimate: an event dispatched through the app action space must reach the feature's
        // state. If the scope were missing, the action would be dropped silently.
        store.dispatch(.indicator(.event(.connected)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.indicator.isConnected)

        // Tyres, via a resolved reading.
        let reading = TyreReading(
            position: .front,
            telemetry: TyreTelemetry(serial: "x", pressure: KPa(229), temperature: Celsius(20), isMoving: false),
            status: .ok
        )
        store.dispatch(.tyres(.reading(reading)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.tyres.readings[.front] != nil)

        // CHIGEE ignition, on and off again — the off edge is the one that failed in the field,
        // leaving the ignition reading ON for the rest of the day.
        store.dispatch(.chigee(.event(.present)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.chigee.isIgnitionOn == true)
        store.dispatch(.chigee(.event(.absent)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.chigee.isIgnitionOn == false)

        // Cameras reach the speed monitor's slice.
        let camera = SpeedCamera(
            id: 42, kind: .fixed,
            latitude: Latitude(51.75), longitude: Longitude(-0.475),
            limit: MPH(30), direction: nil
        )
        store.dispatch(.speedMonitor(.camerasChanged(CameraSet(cameras: [camera], zones: []))), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.speedMonitor.cameras.map(\.id) == [42])

        // And the spoken-once bookkeeping prunes when a camera leaves the fetched set, otherwise
        // riding back the other way would stay silent for ever.
        store.dispatch(.speedMonitor(.camerasAnnounced([42])), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.speedMonitor.announcedCameraIDs == [42])
        store.dispatch(.speedMonitor(.camerasChanged(.empty)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.speedMonitor.announcedCameraIDs.isEmpty)

        // Cardo, via an audio route carrying a Bluetooth headset.
        let route = AudioRoute(outputs: [
            AudioOutput(portType: "BluetoothA2DPOutput", portName: "PT EDGE", uid: "x")
        ])
        store.dispatch(.cardo(.routeChanged(route)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.cardo.isConnected)

        // Motion.
        let sample = MotionSample(
            userAcceleration: Vector3(x: 0, y: 0, z: 0),
            gravity: Vector3(x: 0, y: 0, z: -1),
            rotationRate: Vector3(x: 0, y: 0, z: 0)
        )
        store.dispatch(.motion(.motion(sample)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.motion.motion != nil)

        // Weather.
        let observation = WeatherObservation(
            temperature: Celsius(18), humidity: 60, pressure: KPa(101.3),
            windSpeed: MPS(2), windDirection: Course(180)
        )
        store.dispatch(
            .weather(.observed(observation, Latitude(51), Longitude(0), Date(timeIntervalSince1970: 0))),
            source: .init(file: #file, function: #function, line: #line)
        )
        #expect(store.state.weather.latest != nil)
    }

    @Test("navigation pushes and pops through the app store")
    func navigationIsWired() {
        let store = MainStore.app(world: .stub)
        #expect(store.state.path.isEmpty)

        store.dispatch(.navigation(.push(.fuel)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.path.count == 1)
        #expect(store.state.routes == [.fuel])

        store.dispatch(.navigation(.pop), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.path.isEmpty)
    }

    @Test("the fuel screen's affine scope reaches state inside the path element")
    func affineScopeIsWired() {
        // The fuel screen's state lives inside a `path` element rather than as a permanent field,
        // read and written through the same prism. A broken affine scope drops edits silently.
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.fuel)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.fuel(.setLitres("12.5")), source: .init(file: #file, function: #function, line: #line))

        guard case let .fuel(state)? = store.state.path.first else {
            Issue.record("fuel entry missing from the path")
            return
        }
        #expect(state.litres == "12.5")
    }

    @Test("the route planner's affine scope reaches state inside the path element")
    func navigateScopeIsWired() {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.navigate)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.navigate(.setQuery("MK42")), source: .init(file: #file, function: #function, line: #line))

        guard case let .navigate(state)? = store.state.path.first else {
            Issue.record("route planner entry missing from the path")
            return
        }
        #expect(state.query == "MK42")
    }

    /// Position reaches the planner by fan-out from the location stream, which is affine: a fix
    /// arriving while the planner is not on the stack lands nowhere. Open it between fixes and it
    /// has no origin — for ever, if the bike is stationary and Core Location has settled, which is
    /// exactly when a rider plans a route. Seen in the simulator: four fixes all session, all
    /// before the screen existed, and the planner sat on "waiting for a GPS fix".
    @Test("opening the planner seeds it with the last known fix")
    func plannerSeedsFromLastFix() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(
            .speedMonitor(.locationUpdate(LocationUpdate(
                speed: MPS(0), speedAccuracy: MPS(1), course: nil,
                latitude: Latitude(52.13), longitude: Longitude(-0.46),
                altitude: Meters(30), timestamp: Date(timeIntervalSince1970: 0),
                horizontalAccuracy: Meters(5)
            ))),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<10 { await Task.yield() }

        // Pushed *after* the only fix, exactly as it happens when a rider stops and opens it.
        store.dispatch(.navigation(.push(.navigate)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.navigate(.appeared), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }

        guard case let .navigate(state)? = store.state.path.first else {
            Issue.record("route planner entry missing"); return
        }
        #expect(state.canRoute)
        #expect(state.latitude == Latitude(52.13))
    }

    /// Routing needs an origin, and the only one that makes sense is the bike's own position. It
    /// arrives by fan-out from the single feature that owns the location stream — a wiring line that
    /// compiles perfectly well when deleted, which is what this whole suite exists for.
    @Test("a location fix reaches the route planner")
    func positionReachesPlanner() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.navigate)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(
            .speedMonitor(.locationUpdate(LocationUpdate(
                speed: MPS(0), speedAccuracy: MPS(1), course: nil,
                latitude: Latitude(52.13), longitude: Longitude(-0.46),
                altitude: Meters(30), timestamp: Date(timeIntervalSince1970: 0),
                horizontalAccuracy: Meters(5)
            ))),
            source: .init(file: #file, function: #function, line: #line)
        )
        // The fan-out is an effect, not a reduction — the fix arrives on the next turn of the loop.
        for _ in 0..<10 { await Task.yield() }

        guard case let .navigate(state)? = store.state.path.first else {
            Issue.record("route planner entry missing from the path")
            return
        }
        #expect(state.latitude == Latitude(52.13))
        #expect(state.canRoute)
    }

    /// The planner is a pushed screen and the map is the root, so neither can see the other. The
    /// app-level join is the only thing that draws the route — and it is exactly the kind of line
    /// that compiles perfectly well when deleted.
    @Test("choosing a route draws it on the root map")
    func chosenRouteReachesTheMap() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.navigate)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.speedMonitor.routeShape.isEmpty)

        let shape = (0..<10).map {
            Coordinate(latitude: Latitude(52 + Double($0) / 1_000), longitude: Longitude(-0.46))
        }
        // `.select` only highlights; `.start` is the commitment, and it is what draws the route on
        // the home map — the one carrying the speed, the limit sign and the status bubbles.
        store.dispatch(
            .navigate(.start(RouteOption(
                name: "A421", distance: Meters(1_000), travelTime: 120,
                hasTolls: false, hasMotorways: false, steps: [], shape: shape
            ), "Bedford")),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<10 { await Task.yield() }

        #expect(store.state.speedMonitor.routeShape == shape)
        #expect(store.state.activeRoute != nil)
        // And it puts the rider back on the home map rather than leaving them on a preview of a
        // route they have already committed to.
        #expect(store.state.path.isEmpty)
    }

    /// A destination chosen before the first fix cannot be routed — the screen says "waiting for a
    /// GPS fix", and without a retry it says it for ever, because nothing else would ask again.
    /// Equally, this action arrives once a second all journey: routing on each one would be a
    /// request per second and would swap the route under a rider already following it.
    @Test("a destination chosen before the first fix routes once the fix arrives, and only once")
    func routesOnFirstFixOnly() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.navigate)), source: .init(file: #file, function: #function, line: #line))

        let destination = AddressSuggestion(
            title: "Ampthill Road", subtitle: "Bedford",
            latitude: Latitude(52.12), longitude: Longitude(-0.46)
        )

        // `.choose` only kicks off resolution — a completion is text until it is placed, and the
        // stub never resolves — so the resolved destination is supplied directly here.
        store.dispatch(.navigate(.destinationResolved(destination)), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }

        // No fix yet, so nothing could be asked.
        guard case let .navigate(before)? = store.state.path.first else {
            Issue.record("route planner entry missing"); return
        }
        #expect(before.outcome == nil)
        #expect(!before.isRouting)

        func fix(_ latitude: Double) -> AppFeature.Action {
            .navigate(.setPosition(Latitude(latitude), Longitude(-0.46)))
        }
        store.dispatch(fix(52.13), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }

        // The stub returns an empty publisher, so routing never resolves — `isRouting` staying true
        // is exactly the evidence that the request was made.
        guard case let .navigate(after)? = store.state.path.first else {
            Issue.record("route planner entry missing"); return
        }
        #expect(after.isRouting)

        // A second fix must not ask again: the guard is on the *first* one.
        store.dispatch(fix(52.14), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }
        guard case let .navigate(later)? = store.state.path.first else {
            Issue.record("route planner entry missing"); return
        }
        #expect(later.latitude == Latitude(52.14))
    }

    /// The map-browsing law, now store-owned: the gesture is an action, the auto-return is a rule
    /// over fixes, and none of it lives in a view.
    @Test("a browsed map is handed back to the bike once demonstrably riding")
    func browsedMapAutoReturns() async {
        let store = MainStore.app(world: .stub)
        let camera = BrowsedCamera(
            latitude: 52.2, longitude: -0.5, distance: 900, heading: 45, pitch: 0
        )
        store.dispatch(.speedMonitor(.mapBrowsed(camera)), source: .init(file: #file, function: #function, line: #line))
        #expect(store.state.speedMonitor.browsedCamera == camera)

        func fix(_ latitude: Double, mps: Double) -> AppFeature.Action {
            .speedMonitor(.locationUpdate(LocationUpdate(
                speed: MPS(mps), speedAccuracy: MPS(1), course: nil,
                latitude: Latitude(latitude), longitude: Longitude(-0.46),
                altitude: Meters(30), timestamp: Date(timeIntervalSince1970: 0),
                horizontalAccuracy: Meters(5)
            )))
        }

        // One fast fix is not enough — a single blip must not snatch the map back.
        store.dispatch(fix(52.130, mps: 10), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.state.speedMonitor.browsedCamera != nil)

        // The second fast fix is: demonstrably riding, the map is the bike's again.
        store.dispatch(fix(52.131, mps: 10), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.state.speedMonitor.browsedCamera == nil)
    }

    /// Stopped at the kerb, studying the junctions ahead: left alone indefinitely.
    @Test("a browsed map stays browsed while stationary")
    func browsedMapStaysWhileStopped() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(
            .speedMonitor(.mapBrowsed(BrowsedCamera(
                latitude: 52.2, longitude: -0.5, distance: 900, heading: 45, pitch: 0
            ))),
            source: .init(file: #file, function: #function, line: #line)
        )
        for tick in 0..<5 {
            store.dispatch(
                .speedMonitor(.locationUpdate(LocationUpdate(
                    speed: MPS(0), speedAccuracy: MPS(1), course: nil,
                    latitude: Latitude(52.13 + Double(tick) * 0.00001), longitude: Longitude(-0.46),
                    altitude: Meters(30), timestamp: Date(timeIntervalSince1970: 0),
                    horizontalAccuracy: Meters(5)
                ))),
                source: .init(file: #file, function: #function, line: #line)
            )
            for _ in 0..<5 { await Task.yield() }
        }
        #expect(store.state.speedMonitor.browsedCamera != nil)
    }

    /// Otherwise the planner forgets where you were going while the map carries on drawing the route
    /// there, and the only way to be rid of it is to navigate somewhere else.
    @Test("stopping rubs the route off the map")
    func clearingRemovesTheRoute() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.navigate)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(
            .navigate(.start(RouteOption(
                name: "A421", distance: Meters(1_000), travelTime: 120,
                hasTolls: false, hasMotorways: false, steps: [],
                shape: [
                    Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46)),
                    Coordinate(latitude: Latitude(52.1), longitude: Longitude(-0.46))
                ]
            ), "Bedford")),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<10 { await Task.yield() }
        #expect(!store.state.speedMonitor.routeShape.isEmpty)

        store.dispatch(.stopNavigation, source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.state.speedMonitor.routeShape.isEmpty)
        #expect(store.state.activeRoute == nil)
    }

    /// Reaching the destination must end navigation itself, not only the talking. "You have
    /// arrived" once left the route loaded — so the reroute machinery read every metre of onward
    /// riding as off-route and spent ten real minutes recalculating the way back to a destination
    /// the rider had already left.
    @Test("arrival tears navigation down like the stop button")
    func arrivalStopsNavigation() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.navigate)), source: .init(file: #file, function: #function, line: #line))
        let end = Coordinate(latitude: Latitude(52.001), longitude: Longitude(-0.46))
        store.dispatch(
            .navigate(.start(RouteOption(
                name: "A421", distance: Meters(120), travelTime: 30,
                hasTolls: false, hasMotorways: false,
                steps: [RouteStep(
                    instructions: "Arrive at the destination", distance: Meters(120), notice: nil,
                    start: end,
                    path: [Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46)), end]
                )],
                shape: [Coordinate(latitude: Latitude(52), longitude: Longitude(-0.46)), end]
            ), "Bedford")),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<10 { await Task.yield() }
        #expect(store.state.activeRoute != nil)

        // A fix on the doorstep: within arrival reach of the final manoeuvre.
        store.dispatch(
            .speedMonitor(.locationUpdate(LocationUpdate(
                speed: MPS(3), speedAccuracy: MPS(1), course: nil,
                latitude: end.latitude, longitude: end.longitude,
                altitude: Meters(30), timestamp: Date(timeIntervalSince1970: 0),
                horizontalAccuracy: Meters(5)
            ))),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<20 { await Task.yield() }

        #expect(store.state.activeRoute == nil)
        #expect(store.state.speedMonitor.routeShape.isEmpty)
        #expect(store.state.speedMonitor.nextTurn == nil)
    }
}

@Suite("Journey rule")
@MainActor
struct JourneyWiringTests {

    /// The journey decision reads post-reduction state, which means a main-actor hop — so it lands
    /// on the next turn of the loop rather than inside `dispatch`. Yielding is what makes that
    /// deterministic instead of a race the test wins by luck.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test("a journey starts when either signal appears and ends when both are gone")
    func journeyLifecycle() async {
        let store = MainStore.app(world: .stub)
        #expect(store.state.journey == .idle)

        // Indimate alone is enough to start.
        store.dispatch(.indicator(.event(.connected)), source: .init(file: #file, function: #function, line: #line))
        await settle()
        #expect(JourneyPhase.prism.active.preview(store.state.journey) != nil)

        // CHIGEE arriving changes nothing — already under way.
        store.dispatch(.chigee(.event(.present)), source: .init(file: #file, function: #function, line: #line))
        await settle()
        #expect(JourneyPhase.prism.active.preview(store.state.journey) != nil)

        // One dropping is a red flag, not an ending. This is the CHIGEE-reboot case.
        store.dispatch(.chigee(.event(.absent)), source: .init(file: #file, function: #function, line: #line))
        await settle()
        #expect(JourneyPhase.prism.active.preview(store.state.journey) != nil)

        // Both gone ends it.
        store.dispatch(.indicator(.event(.disconnected)), source: .init(file: #file, function: #function, line: #line))
        await settle()
        #expect(store.state.journey == .idle)
    }
}

@Suite("Refuel recording")
@MainActor
struct RefuelRecordingTests {

    /// Captures what reaches the journey log.
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [any JourneyPayloadType] = []
        func record(_ payload: any JourneyPayloadType) { lock.withLock { recorded.append(payload) } }
        var types: [RecordType] { lock.withLock { recorded.map { Swift.type(of: $0).recordType } } }
    }

    private func world(_ spy: Spy) -> World {
        var world = World.stub
        world = World(
            requestAuthorization: world.requestAuthorization,
            authorizationUpdates: world.authorizationUpdates,
            locationUpdates: world.locationUpdates,
            subscribeToRoadSpeed: world.subscribeToRoadSpeed,
            localRoad: world.localRoad,
            camerasOnRoad: world.camerasOnRoad,
            subscribeToCameras: world.subscribeToCameras,
            reverseGeocode: world.reverseGeocode,
            refreshRoadNow: world.refreshRoadNow,
            bluetoothAuthorization: world.bluetoothAuthorization,
            indimateEvents: world.indimateEvents,
            playIndicatorLoop: world.playIndicatorLoop,
            stopIndicatorLoop: world.stopIndicatorLoop,
            tyreReadings: world.tyreReadings,
            formatPressure: world.formatPressure,
            formatTemperature: world.formatTemperature,
            chigeeEvents: world.chigeeEvents,
            cardoEvents: world.cardoEvents,
            audioRouteChanges: world.audioRouteChanges,
            barometer: world.barometer,
            motion: world.motion,
            motionActivity: world.motionActivity,
            fetchWeather: world.fetchWeather,
            loadTripDistance: world.loadTripDistance,
            saveTripDistance: world.saveTripDistance,
            loadFuelLog: world.loadFuelLog,
            saveFuelLog: world.saveFuelLog,
            loadMaintenanceLog: world.loadMaintenanceLog,
            saveMaintenanceLog: world.saveMaintenanceLog,
            sendWatchSnapshot: world.sendWatchSnapshot,
            watchRefuels: world.watchRefuels,
            captureText: world.captureText,
            stopTextCapture: world.stopTextCapture,
            cameraPreview: world.cameraPreview,
            playback: world.playback,
            stopPlayback: world.stopPlayback,
            phoneBattery: world.phoneBattery,
            isLowPowerMode: world.isLowPowerMode,
            fetchStation: world.fetchStation,
            parseNumber: world.parseNumber,
            formatNumber: world.formatNumber,
            now: world.now,
            newID: world.newID,
            logAction: world.logAction,
            loadJourneyRecords: world.loadJourneyRecords,
            writeShareFile: world.writeShareFile,
            logJourney: { payload in
                Publisher.future { spy.record(payload) }
            },
            speak: world.speak,
            speakQueued: world.speakQueued,
            speakSequence: world.speakSequence,
            announceOverLimit: world.announceOverLimit,
            announceUnderLimit: world.announceUnderLimit,
            playRerouteTone: world.playRerouteTone,
            completeAddress: world.completeAddress,
            resolveAddress: world.resolveAddress,
            routes: world.routes,
            routesToEach: world.routesToEach,
            thresholds: world.thresholds,
            formatSpeed: world.formatSpeed,
            formatSpeedSpeech: world.formatSpeedSpeech,
            formatAltitude: world.formatAltitude,
            formatDistance: world.formatDistance,
            formatDuration: world.formatDuration,
            formatTime: world.formatTime,
            formatBearing: world.formatBearing,
            formatCoordinate: world.formatCoordinate
        )
        return world
    }

    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    @Test("a refuel is recorded even with no journey running")
    func refuelIsKeptOffJourney() async {
        // The case this exists for: you pull in, the keys come out and journey A ends, you fill up,
        // the keys go back in and journey B starts. The refuel lands in the gap — and it is the one
        // record every fuel calculation is built on.
        let spy = Spy()
        let store = MainStore.app(world: world(spy))
        #expect(store.state.journey == .idle)

        store.dispatch(.navigation(.push(.fuel)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.fuel(.setLitres("12.5")), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.fuel(.setPrice("1.49")), source: .init(file: #file, function: #function, line: #line))
        // Parsing goes through the World, so it lands a turn later — the same hop the real form has
        // between a keystroke and Save becoming enabled.
        await settle()
        store.dispatch(.fuel(.save), source: .init(file: #file, function: #function, line: #line))
        await settle()

        #expect(spy.types.contains(.refuel))
    }

    @Test("switching to reserve is recorded even with no journey running")
    func reserveIsKeptOffJourney() async {
        let spy = Spy()
        let store = MainStore.app(world: world(spy))
        store.dispatch(.navigation(.push(.fuel)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.fuel(.engageReserve), source: .init(file: #file, function: #function, line: #line))
        await settle()

        #expect(spy.types.contains(.reserve))
    }
}

@Suite("Maintenance wiring")
@MainActor
struct MaintenanceWiringTests {

    /// The badge chain: a loaded log moves the app's copy, and the status effect — which needs the
    /// clock a reducer does not have — recolours the wrench from post-reduction state.
    @Test("a loaded log recolours the home wrench")
    func statusFollowsTheLog() async {
        let store = MainStore.app(world: .stub)
        #expect(store.state.maintenanceStatus == .ok)
        // The launch-time load answers empty from the stub; let it land first so it cannot
        // overwrite the log this test is about.
        for _ in 0..<10 { await Task.yield() }

        // Due a day before the stub's epoch clock: red the moment it lands.
        let overdue = MaintenanceItem(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            title: "Valve clearances",
            due: .onDate(Date(timeIntervalSince1970: -86_400))
        )
        store.dispatch(
            .maintenanceLogLoaded(MaintenanceLog(items: [overdue])),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<10 { await Task.yield() }

        #expect(store.state.maintenanceLog.items.count == 1)
        #expect(store.state.maintenanceStatus == .due)
    }

    /// The screen cannot see the fuel log or the trip counter; the app answers its `appeared`
    /// with the reconstructed odometer. Deleting this join would compile — and every km deadline
    /// would silently stop counting.
    @Test("opening the screen hands it the reconstructed odometer")
    func screenReceivesOdometer() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(
            .fuelLogLoaded(FuelLog(refuels: [RefuelRecord(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)),
                date: Date(timeIntervalSince1970: 0), litres: Litres(9), pricePerLitre: 1.5,
                grade: .e5, filledToBrim: true, odometer: Kilometres(19_000),
                latitude: nil, longitude: nil
            )])),
            source: .init(file: #file, function: #function, line: #line)
        )
        store.dispatch(.navigation(.push(.maintenance)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.maintenance(.appeared), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }

        guard case let .maintenance(screen)? = store.state.path.first else {
            Issue.record("maintenance entry missing from the path")
            return
        }
        #expect(screen.currentOdometer == Kilometres(19_000))
        #expect(screen.today != nil)
    }

    /// The pre-ride voice: a due item must reach the briefing's problem list.
    @Test("a due item is spoken by the flight plan")
    func briefingSpeaksMaintenance() async {
        let store = MainStore.app(world: .stub)
        // Same launch-load race as above: the stub's empty answer must land before the real log.
        for _ in 0..<10 { await Task.yield() }
        store.dispatch(
            .maintenanceLogLoaded(MaintenanceLog(items: [MaintenanceItem(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3)),
                title: "Chain oil",
                due: .onDate(Date(timeIntervalSince1970: -86_400))
            )])),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<10 { await Task.yield() }

        let lines = composeFlightPlan(
            store.state.flightPlanInputs(.stub), verbosity: .exceptions
        )
        #expect(lines.contains { $0.contains("Chain oil is due") })
    }
}

@Suite("Watch link wiring")
@MainActor
struct WatchLinkWiringTests {

    /// Captures what the phone pushes to the wrist and what it writes to the journey log.
    private final class LinkSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [WatchSnapshot] = []
        private var journal: [any JourneyPayloadType] = []
        func push(_ snapshot: WatchSnapshot) { lock.withLock { snapshots.append(snapshot) } }
        func journey(_ payload: any JourneyPayloadType) { lock.withLock { journal.append(payload) } }
        var pushed: [WatchSnapshot] { lock.withLock { snapshots } }
        var journalTypes: [RecordType] { lock.withLock { journal.map { Swift.type(of: $0).recordType } } }
    }

    private func world(_ spy: LinkSpy) -> World {
        let world = World.stub
        return World(
            requestAuthorization: world.requestAuthorization,
            authorizationUpdates: world.authorizationUpdates,
            locationUpdates: world.locationUpdates,
            subscribeToRoadSpeed: world.subscribeToRoadSpeed,
            localRoad: world.localRoad,
            camerasOnRoad: world.camerasOnRoad,
            subscribeToCameras: world.subscribeToCameras,
            reverseGeocode: world.reverseGeocode,
            refreshRoadNow: world.refreshRoadNow,
            bluetoothAuthorization: world.bluetoothAuthorization,
            indimateEvents: world.indimateEvents,
            playIndicatorLoop: world.playIndicatorLoop,
            stopIndicatorLoop: world.stopIndicatorLoop,
            tyreReadings: world.tyreReadings,
            formatPressure: world.formatPressure,
            formatTemperature: world.formatTemperature,
            chigeeEvents: world.chigeeEvents,
            cardoEvents: world.cardoEvents,
            audioRouteChanges: world.audioRouteChanges,
            barometer: world.barometer,
            motion: world.motion,
            motionActivity: world.motionActivity,
            fetchWeather: world.fetchWeather,
            loadTripDistance: world.loadTripDistance,
            saveTripDistance: world.saveTripDistance,
            loadFuelLog: world.loadFuelLog,
            saveFuelLog: world.saveFuelLog,
            loadMaintenanceLog: world.loadMaintenanceLog,
            saveMaintenanceLog: world.saveMaintenanceLog,
            sendWatchSnapshot: { snapshot in
                Publisher.future { spy.push(snapshot) }
            },
            watchRefuels: world.watchRefuels,
            captureText: world.captureText,
            stopTextCapture: world.stopTextCapture,
            cameraPreview: world.cameraPreview,
            playback: world.playback,
            stopPlayback: world.stopPlayback,
            phoneBattery: world.phoneBattery,
            isLowPowerMode: world.isLowPowerMode,
            fetchStation: world.fetchStation,
            parseNumber: world.parseNumber,
            formatNumber: world.formatNumber,
            now: world.now,
            newID: world.newID,
            logAction: world.logAction,
            loadJourneyRecords: world.loadJourneyRecords,
            writeShareFile: world.writeShareFile,
            logJourney: { payload in
                Publisher.future { spy.journey(payload) }
            },
            speak: world.speak,
            speakQueued: world.speakQueued,
            speakSequence: world.speakSequence,
            announceOverLimit: world.announceOverLimit,
            announceUnderLimit: world.announceUnderLimit,
            playRerouteTone: world.playRerouteTone,
            completeAddress: world.completeAddress,
            resolveAddress: world.resolveAddress,
            routes: world.routes,
            routesToEach: world.routesToEach,
            thresholds: world.thresholds,
            formatSpeed: world.formatSpeed,
            formatSpeedSpeech: world.formatSpeedSpeech,
            formatAltitude: world.formatAltitude,
            formatDistance: world.formatDistance,
            formatDuration: world.formatDuration,
            formatTime: world.formatTime,
            formatBearing: world.formatBearing,
            formatCoordinate: world.formatCoordinate
        )
    }

    /// A fix must reach the wrist as the post-reduction truth — deleting the push join would
    /// compile and the watch would simply show "waiting for the phone" for ever.
    @Test("a fix is pushed to the wrist as a snapshot")
    func fixReachesTheWrist() async {
        let spy = LinkSpy()
        let store = MainStore.app(world: world(spy))
        store.dispatch(
            .speedMonitor(.locationUpdate(LocationUpdate(
                speed: MPS(13.4), speedAccuracy: MPS(1), course: Course(rawValue: 90),
                latitude: Latitude(51.88), longitude: Longitude(-0.42),
                altitude: Meters(90), timestamp: Date(timeIntervalSince1970: 0),
                horizontalAccuracy: Meters(5)
            ))),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<20 { await Task.yield() }

        let last = spy.pushed.last
        #expect(last != nil)
        #expect(last?.latitude == 51.88)
        #expect(last.flatMap(\.mph).map { Int($0.rounded()) } == 30)
    }

    /// The wrist's one command becomes exactly what the fuel screen writes: a journey record and
    /// a saved log — and the trip counter starts a fresh measurement.
    @Test("a watch refuel writes the same record the screen would")
    func watchRefuelWrites() async {
        let spy = LinkSpy()
        let store = MainStore.app(world: world(spy))
        store.dispatch(
            .watchRefuel(WatchRefuel(litres: 9.2, pricePerLitre: 1.47, grade: "E5", filledToBrim: true)),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<20 { await Task.yield() }

        #expect(spy.journalTypes.contains(.refuel))
    }
}

@Suite("Pump scan")
@MainActor
struct PumpScanWiringTests {

    /// The whole hunt, driven frame by frame: pump frames until the tick, odometer frames until
    /// the sheet closes itself — and the form holds the values as if they had been typed.
    @Test("a steady pump then a steady odometer fills the form and closes the camera")
    func scanFillsTheForm() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.fuel)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.fuel(.beginScan), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }

        // A pence-scale price with the E5 badge beside it, E10's price further up the display.
        let pumpFrame = [
            RecognizedText(text: "E10", x: 0.2, y: 0.8), RecognizedText(text: "139.9", x: 0.35, y: 0.8),
            RecognizedText(text: "E5", x: 0.2, y: 0.6), RecognizedText(text: "145.5", x: 0.35, y: 0.6),
            RecognizedText(text: "£13.72", x: 0.5, y: 0.3), RecognizedText(text: "9.43", x: 0.5, y: 0.2)
        ]
        for _ in 0..<scanStabilityFrames {
            store.dispatch(.fuel(.scanSaw(pumpFrame)), source: .init(file: #file, function: #function, line: #line))
            for _ in 0..<3 { await Task.yield() }
        }
        guard case let .fuel(mid)? = store.state.path.first else {
            Issue.record("fuel entry missing"); return
        }
        #expect(mid.scan?.phase == .odometer)
        #expect(mid.scan?.pump == PumpReading(litres: 9.43, pricePerLitre: 1.455))
        #expect(mid.scan?.grade == "E5")

        let odoFrame = [RecognizedText(text: "19432"), RecognizedText(text: "231.4")]
        for _ in 0..<scanStabilityFrames {
            store.dispatch(.fuel(.scanSaw(odoFrame)), source: .init(file: #file, function: #function, line: #line))
            for _ in 0..<3 { await Task.yield() }
        }
        for _ in 0..<10 { await Task.yield() }

        guard case let .fuel(done)? = store.state.path.first else {
            Issue.record("fuel entry missing"); return
        }
        #expect(done.scan == nil)
        #expect(done.litresValue == 9.43)
        #expect(done.priceValue == 1.455)
        #expect(done.odometerValue == 19_432)
        #expect(done.grade == .e5)
    }

    @Test("an unsteady reading never convinces")
    func flickerNeverConvinces() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.fuel)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.fuel(.beginScan), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<5 { await Task.yield() }

        // Alternating readings — a reflection sliding over the display.
        for index in 0..<10 {
            let frame = (index.isMultiple(of: 2)
                ? ["£13.72", "9.43", "1.455"] : ["£27.44", "18.86", "1.455"])
                .map { RecognizedText(text: $0) }
            store.dispatch(.fuel(.scanSaw(frame)), source: .init(file: #file, function: #function, line: #line))
            for _ in 0..<2 { await Task.yield() }
        }
        guard case let .fuel(state)? = store.state.path.first else {
            Issue.record("fuel entry missing"); return
        }
        #expect(state.scan?.phase == .pump)
        #expect(state.scan?.pump == nil)
    }
}

@Suite("Ride replay")
@MainActor
struct ReplayWiringTests {

    private func ride() -> Ride {
        Ride(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 60),
            endedCleanly: true,
            records: [
                JourneyRecord(time: Date(timeIntervalSince1970: 0), payload: JourneyStartPayload(via: "both")),
                JourneyRecord(
                    time: Date(timeIntervalSince1970: 1),
                    payload: FixPayload(lat: 51.87, lon: -0.41, mph: 30, course: 90, alt: 90, acc: 5)
                )
            ]
        )
    }

    /// The join from the reviews sheet to the tape: deleting it would compile, and the play
    /// button would do nothing.
    @Test("the play button closes the sheet and opens the replay carrying the ride")
    func playOpensReplay() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.rides)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.rides(.loaded([ride()])), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.rides(.replayRide(ride().id)), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }

        let replay = store.state.path.compactMap(StackEntry.prism.replay.preview).last
        #expect(replay != nil)
        #expect(replay?.ride.id == ride().id)
    }

    /// The tape's events drive the *lifted* monitor — the same behavior as the home screen,
    /// under a different prefix, invisible to journey recording and the watch link.
    @Test("a taped fix and road land in the replay's own monitor")
    func tapeDrivesTheSecondMonitor() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.replay(ride()))), source: .init(file: #file, function: #function, line: #line))

        let update = LocationUpdate(
            speed: MPS(13.4), speedAccuracy: nil, course: Course(rawValue: 90),
            latitude: Latitude(51.87), longitude: Longitude(-0.41),
            altitude: Meters(90), timestamp: Date(timeIntervalSince1970: 1),
            horizontalAccuracy: Meters(5)
        )
        store.dispatch(
            .replay(.event(ReplayStep(delay: 0, position: 0, event: .fix(update)))),
            source: .init(file: #file, function: #function, line: #line)
        )
        store.dispatch(
            .replay(.event(ReplayStep(delay: 1, position: 1, event: .road(RoadInfo(
                limit: .value(MPH(30)), ref: nil, name: "A505", origin: .signed
            ))))),
            source: .init(file: #file, function: #function, line: #line)
        )
        store.dispatch(
            .replay(.event(ReplayStep(delay: 1, position: 2, event: .indicator("left")))),
            source: .init(file: #file, function: #function, line: #line)
        )
        // The display rebuilds per fix, exactly as it does live — the road shows from the next
        // fix onward, and on the tape fixes arrive every second.
        store.dispatch(
            .replay(.event(ReplayStep(delay: 1, position: 3, event: .fix(update)))),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<15 { await Task.yield() }

        let replay = store.state.path.compactMap(StackEntry.prism.replay.preview).last
        #expect(replay?.monitor.lastLocation?.latitude == Latitude(51.87))
        #expect(replay?.monitor.display.roadName == "A505")
        #expect(replay?.indicator == .left)
        #expect(replay?.position == 3)   // the HUD's counter follows the tape
        // And the *live* monitor never saw any of it.
        #expect(store.state.speedMonitor.lastLocation == nil)
    }

    @Test("stop pops the screen; the tape ends with it")
    func stopPops() async {
        let store = MainStore.app(world: .stub)
        store.dispatch(.navigation(.push(.replay(ride()))), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.replay(.cancel), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<10 { await Task.yield() }
        #expect(store.state.path.compactMap(StackEntry.prism.replay.preview).isEmpty)
    }
}
