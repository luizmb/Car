import FPMacros

/// The app's route tree — a pure DTO in the domain model, so its associated values are forced to be
/// domain types / primitives (the contract for what a feature passes when it navigates).
@Prisms public enum AppRoute: Hashable, Sendable {
    case speedMonitor
}
