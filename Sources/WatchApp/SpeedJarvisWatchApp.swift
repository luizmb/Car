import AppDomain
import SwiftRex
import SwiftUI
import WatchCore
import WatchKit

/// The watch entry point, mirroring the phone's: it holds the two things nothing else may — the
/// live world and the store built from it — and does nothing else.
@main
struct SpeedJarvisWatchApp: App {
    // The delegate exists for one callback: watchOS handing over the workout configuration when
    // the phone launches this app at journey start.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
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
