import AppCore
import AppDomain
import FP
import SwiftUI

/// The entry point holds the two things nothing else may: the live `World` and the store built from it.
/// It then hands both to ``AppFeature`` — the app's own `Feature` — and does nothing else. No routes, no
/// view construction, no logic: `AppFeature.view(store:environment:)` is the only way the root is built,
/// exactly as `Scope.view(of:from:world:)` is the only way any other screen is.
@main
struct SpeedJarvisApp: App {
    private let world = World.real
    private let store: MainStoreType

    init() {
        store = MainStore.app(world: world)
    }

    var body: some Scene {
        WindowGroup {
            AppFeature.view(store: store, environment: world)
        }
    }
}
