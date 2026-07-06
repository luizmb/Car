import AppDomain
import SpeedMonitorFeature
import SwiftRex
import SwiftRexArchitecture
import SwiftUI

// MARK: - AppRoute → View (the router)
//
// Resolves a route to a feature view via that feature's `Scope`, supplying the child's environment
// from `world`. `@ViewBuilder` unifies the per-route view types without `AnyView`.

public extension AppRoute {

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @MainActor
    static func scene(store: MainStoreType, world: World) -> some Scene {
        WindowGroup {
            root(store: store, world: world, entry: .speedMonitor)
        }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @MainActor
    private static func root(store: MainStoreType, world: World, entry: AppRoute) -> some View {
        AppRootView(path: store.path(\.navigation.path, set: { AppAction.navigation(.setPath($0)) })) {
            entry.view(in: store, world: world)
                .navigationDestination(for: AppRoute.self) { route in
                    route.view(in: store, world: world)
                }
        }
    }

    /// The view for this route, built with its environment supplied from `world`.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @MainActor @ViewBuilder
    func view(in store: MainStoreType, world: World) -> some View {
        switch self {
        case .speedMonitor:
            LiftedScope<SpeedMonitorFeature>.speedMonitor.view(from: store, world: world)
        }
    }
}
