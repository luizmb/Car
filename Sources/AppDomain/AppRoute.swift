import FPMacros

// MARK: - AppRoute

/// The identity of a screen on the navigation stack — **payload-free on purpose**.
///
/// `NavigationStack` keys its destinations by the path element's *value*, so a payload here would make
/// "the same screen showing different data" a different destination: SwiftUI would tear the screen down
/// and re-push it whenever that data changed. What a screen currently shows belongs to its own feature
/// state; a route only says *which* screen.
///
/// SpeedJarvis has no destinations yet — the speed monitor is the **root**, and a root is not something
/// you can push, so it is deliberately absent (exactly as the calendar is in PookiePayslip). The enum is
/// therefore uninhabited by design rather than by accident: until a second screen exists, "navigated
/// somewhere" is unrepresentable. The fuel screen is the first real destination.
@Prisms
public enum AppRoute: Hashable, Sendable {
    case fuel
    case navigate
    case rides
    case maintenance
}

// MARK: - NavigationRequest

/// An ask to navigate — carrying whatever the destination needs in order to be built.
///
/// It is a transient action payload, never stored: the navigation reducer turns it into the `StackEntry`
/// that goes on the stack. Keeping the ask separate from the screen is what lets a feature dispatch
/// tacitly (`dispatch: .action(\.navigation.push.someScreen)`) while a screen that must be built from
/// state the app already holds — which no action payload could supply — still works the same way.
@Prisms
public enum NavigationRequest: Sendable, Equatable {
    /// Carries no payload: the fuel screen builds itself from persisted state, not from the ask.
    case fuel
    /// Likewise — the route planner starts empty and takes its origin from the location stream.
    case navigate
    /// And likewise again: the review screen reads the journey log itself.
    case rides
    /// Likewise: the maintenance screen reads its own log and asks the app for the odometer.
    case maintenance
}
