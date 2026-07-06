import AppCore
import FP
import SwiftUI

@main
struct SpeedJarvisApp: App {
    private let world = World.real
    private let store: MainStoreType

    init() {
        store = MainStore.app(world: world)
    }

    var body: some Scene {
        AppRoute.scene(store: store, world: world)
    }
}
