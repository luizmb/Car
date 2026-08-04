import AppDomain
import CoreFP
import SpeedMonitorFeature
import SwiftRex
import SwiftRexArchitecture
import SwiftUI

// MARK: - AppRouter

/// Turns a route into a screen — **the boundary the `World` stops at**.
///
/// ``AppFeature`` constructs one (it is the only thing holding the `World`) and hands it to the root
/// view. The view can therefore render a destination without ever naming `World`, naming a feature type,
/// or knowing how a child is built: it knows `AppRoute` and gets back an opaque `View`.
///
/// Every screen is built from the **same** ``AppScopes`` declaration that drives the behavior fold, so a
/// screen's action prism, its slice of state, and its environment narrowing are stated once and cannot
/// drift apart between the two uses.
///
/// Nothing is cached. `destination(for:)` runs per visible route, projecting the child's store and
/// narrowing `World` on the spot — a screen off the stack has no store, no view and no environment.
@MainActor
public struct AppRouter {
    private let store: MainStoreType
    private let world: World

    init(store: MainStoreType, world: World) {
        self.store = store
        self.world = world
    }

    /// The root screen — always on screen, so a total lift rather than an affine one.
    ///
    /// The indicator pill is composed here rather than built into the speed screen: they are
    /// sibling features in app state, and neither should have to know the other exists. When
    /// CHIGEE gets the same treatment it stacks alongside without either view changing.
    ///
    /// It floats over the map rather than insetting it, so the map keeps its full height.
    public func root() -> some View {
        AppScopes.speedMonitor.view(of: SpeedMonitorFeature.self, from: store, world: world)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    AppScopes.indicator.view(of: IndicatorFeature.self, from: store, world: world)
                    AppScopes.cardo.view(of: CardoFeature.self, from: store, world: world)
                }
                .padding(.leading, 12)
                .padding(.top, 6)
            }
    }

    /// The screen for `route`. `@ViewBuilder` keeps the concrete per-route types without `AnyView`.
    ///
    /// Unreachable rather than unimplemented: ``AppRoute`` is uninhabited while the speed monitor is the
    /// only screen, so nothing can be pushed to ask for a destination. The first real screen turns this
    /// into `switch route { case .foo: AppScopes.foo.pushedView(of: FooFeature.self, from: store, world: world) }`
    /// and everything below is already in place to serve it.
    @ViewBuilder
    public func destination(for route: AppRoute) -> some View {
        EmptyView()
    }
}

// MARK: - Building a view from an affine scope

/// The affine counterpart of `Relay.Scope.view(of:from:world:)`, which needs a *total* state lane and so
/// cannot build a screen that lives in a stack element.
///
/// `transpose()` holds the last value steady while SwiftUI animates the pop, so a screen never blanks on
/// its way out; the outer `nil` then tears it down once the element is gone.
extension Relay.Scope where
    ActionStrategy: Relay.ActionAxis.EmbedsProtocol,
    StateStrategy: Relay.StateAxis.WritesProtocol,
    EnvironmentStrategy: Relay.EnvironmentAxis.NarrowsProtocol,
    ActionStrategy.Global == Action,
    StateStrategy.Global == State,
    EnvironmentStrategy.Global == Environment {
    @MainActor @ViewBuilder
    func pushedView<F: ViewFactory>(
        of _: F.Type,
        from store: any StoreType<Action, State>,
        world: Environment
    ) -> some View
    where F.Action == ActionStrategy.Local, F.State == StateStrategy.Local, F.Environment == EnvironmentStrategy.Local {
        if let screen = store.projection(action: action.review, state: state.preview).transpose() {
            F.view(store: screen, environment: environment.narrow(world))
        }
    }
}

// MARK: - The affine focus a pushed screen lives behind
//
// Both halves go through the same prism, so a read and a write can never disagree about which element
// they mean. `replacing` only ever overwrites an element that is already there — it cannot append, so a
// child behavior can never conjure a screen navigation did not push.
//
// A pushed screen's scope is declared in `AppScopes` as:
//     .state(preview: topmost(StackEntry.prism.foo), set: replacing(StackEntry.prism.foo))

func topmost<S>(_ prism: Prism<StackEntry, S>) -> @Sendable (AppState) -> S? {
    { $0.path.compactMap(prism.preview).last }
}

func replacing<S>(_ prism: Prism<StackEntry, S>) -> @Sendable (AppState, S) -> AppState {
    { state, screen in
        guard let index = state.path.lastIndex(where: { prism.preview($0) != nil }) else { return state }
        var updated = state
        updated.path[index] = prism.review(screen)
        return updated
    }
}
