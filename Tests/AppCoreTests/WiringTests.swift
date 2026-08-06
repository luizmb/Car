import AppDomain
import Foundation
import Testing
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
