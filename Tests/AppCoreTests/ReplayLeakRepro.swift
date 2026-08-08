import AppDomain
import Foundation
import SpeedMonitorFeature
import Testing
@testable import AppCore

@Suite("Replay leak repro")
@MainActor
struct ReplayLeakRepro {
    @Test("live fixes must not land in the replay monitor")
    func liveLeak() async {
        let store = MainStore.app(world: .stub)
        let ride = Ride(
            start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60),
            endedCleanly: true,
            records: [JourneyRecord(time: Date(timeIntervalSince1970: 1),
                payload: FixPayload(lat: 51.87, lon: -0.41, mph: 30, course: 90, alt: 90, acc: 5))]
        )
        store.dispatch(.navigation(.push(.replay(ride))), source: .init(file: #file, function: #function, line: #line))
        // The exact sequence the screen produces: onAppear starts the lifted monitor, begin rolls the tape.
        store.dispatch(.replay(.monitor(.start)), source: .init(file: #file, function: #function, line: #line))
        store.dispatch(.replay(.begin), source: .init(file: #file, function: #function, line: #line))
        for _ in 0..<20 { await Task.yield() }

        // A live device fix, as the World would deliver it while parked at a desk.
        store.dispatch(
            .speedMonitor(.locationUpdate(LocationUpdate(
                speed: MPS(1.5), speedAccuracy: MPS(1), course: nil,
                latitude: Latitude(50.0), longitude: Longitude(-1.0),
                altitude: Meters(30), timestamp: Date(timeIntervalSince1970: 0),
                horizontalAccuracy: Meters(5)
            ))),
            source: .init(file: #file, function: #function, line: #line)
        )
        for _ in 0..<20 { await Task.yield() }

        let replay = store.state.path.compactMap(StackEntry.prism.replay.preview).last
        #expect(replay?.monitor.lastLocation == nil, "live fix leaked into the replay monitor")
        #expect(store.state.speedMonitor.lastLocation?.latitude == Latitude(50.0), "live monitor must keep working")
    }
}
