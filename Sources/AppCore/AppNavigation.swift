import AppDomain
import FPMacros
import SwiftRex

// MARK: - Navigation action

/// The navigation vocabulary.
///
/// `push` carries a ``NavigationRequest`` — the *ask* ("open screen X"), not the screen itself. The
/// reducer turns a request into a ``StackEntry``, because some screens are built from the request's
/// payload and others from state the app already holds. Keeping the ask stateless is what lets a feature
/// dispatch tacitly (`dispatch: .action(\.navigation.push.foo)`). A request is a transient action
/// payload — never stored, so it is not a second source of truth.
///
/// `setPath` is what `NavigationStack`'s binding delivers for every interactive change — back button,
/// back-swipe, pop-to-root — so user-driven and programmatic navigation land in the same reducer.
@Prisms
public enum NavigationAction: Sendable {
    case push(NavigationRequest)
    case pop
    case popToRoot
    case setPath([AppRoute])
}

// MARK: - The navigation behavior

/// The only writer of `path`.
///
/// Every case is a plain list operation, because the list *is* the state. There is no reconciliation
/// step: nothing to seed after a push and nothing to discard after a pop, since a screen's data lives in
/// the element that was appended or removed.
func navigationBehavior() -> Behavior<AppAction, AppState, World> {
    .reduce { action, state in
        guard let navigation = AppAction.prism.navigation.preview(action) else { return }
        switch navigation {
        case .push(let request):
            state.path.append(state.entry(for: request))

        case .pop:
            guard !state.path.isEmpty else { return }
            state.path.removeLast()

        case .popToRoot:
            state.path.removeAll()

        case .setPath(let routes):
            // SwiftUI only ever shortens the path interactively. Folding to the longest matching prefix
            // is total: it cannot desynchronise, and an unexpected path simply truncates rather than
            // leaving `path` disagreeing with what is on screen.
            state.path = zip(state.path, routes)
                .prefix { $0.route == $1 }
                .map(\.0)
        }
    }
}

private extension AppState {
    /// Builds the stack entry a request asks for — by **construction**, so there is never a
    /// half-initialised screen for someone to finish assembling. Requests whose data comes from the
    /// action carry it; the rest read what the app already holds.
    func entry(for request: NavigationRequest) -> StackEntry {
        switch request {
        case .fuel: .fuel(FuelFeature.initialState(with: ()))
        }
    }
}
