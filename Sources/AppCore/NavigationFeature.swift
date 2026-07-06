import CoreFP
import AppDomain
import FPMacros
import SwiftRex
import SwiftRexArchitecture

// MARK: - NavigationFeature

/// Owns exactly one concern: the navigation stack path (`[AppRoute]`). Logic-only (no view),
/// lifted into the app store in `AppFeature.swift`. Nav *logic* — belongs in AppCore, not the domain.
public enum NavigationFeature {

    public struct State: Sendable, Equatable {
        public var path: [AppRoute] = []
        public init() {}
    }

    @Prisms
    public enum Action: Sendable {
        case push(AppRoute)
        case setPath([AppRoute])
    }

    public typealias Environment = Void

    public static func initialState(with _: Void) -> State { .init() }

    public static func behavior() -> Behavior<Action, State, Void> {
        .handle { action, _ in
            switch action {
            case .push(let route):   .reduce { $0.path.append(route) }
            case .setPath(let path): .reduce { $0.path = path }
            }
        }
    }
}
