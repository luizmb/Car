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
            phoneBattery: world.phoneBattery,
            isLowPowerMode: world.isLowPowerMode,
            fetchStation: world.fetchStation,
            parseNumber: world.parseNumber,
            formatNumber: world.formatNumber,
            now: world.now,
            newID: world.newID,
            logAction: world.logAction,
            logJourney: { payload in
                Publisher.future { spy.record(payload) }
            },
            speak: world.speak,
            speakQueued: world.speakQueued,
            speakSequence: world.speakSequence,
            announceOverLimit: world.announceOverLimit,
            announceUnderLimit: world.announceUnderLimit,
            thresholds: world.thresholds,
            formatSpeed: world.formatSpeed,
            formatSpeedSpeech: world.formatSpeedSpeech,
            formatAltitude: world.formatAltitude,
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
