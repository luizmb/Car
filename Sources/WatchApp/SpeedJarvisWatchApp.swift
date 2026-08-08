import AppDomain
import SwiftRex
import SwiftUI
import WatchCore

/// The watch entry point, mirroring the phone's: it holds the two things nothing else may — the
/// live world and the store built from it — and does nothing else.
@main
struct SpeedJarvisWatchApp: App {
    private let store: any StoreType<WatchFeature.Action, WatchFeature.State>

    init() {
        store = WatchMain.store(world: .live)
    }

    var body: some Scene {
        WindowGroup {
            WatchFeature.view(store: store)
        }
    }
}
