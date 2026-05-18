import Combine
import CombineRex
import CoreLocation
import SwiftRexMacros

// MARK: - ACTION
@Prism
public enum CoreLocationAction {
    case authorizationRequest(always: Bool)
    case authorizationResponse(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization, background: Bool)
    case location(from: CLLocation?, to: CLLocation)
    case error(Error)
}

// MARK: - STATE
public struct CoreLocationState: Equatable {
    public fileprivate(set) var requestingAuthorization: Bool = false
    public fileprivate(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    public fileprivate(set) var accuracyAuthorization: CLAccuracyAuthorization = .reducedAccuracy
    public fileprivate(set) var allowsBackground: Bool = false
    public fileprivate(set) var lastLocation: CLLocation?
    public fileprivate(set) var isInErrorState: Bool = false
}

// MARK: - REDUCERS
public extension Reducer where ActionType == CoreLocationAction, StateType == CoreLocationState {
    static let coreLocation = Reducer.reduce { action, state in
        switch action {
        case let .authorizationRequest(always):
            state.requestingAuthorization = true
            state.authorizationStatus = .notDetermined
            state.accuracyAuthorization = .reducedAccuracy
            state.allowsBackground = false
            state.isInErrorState = false
        case let .authorizationResponse(status, accuracy, background):
            state.requestingAuthorization = false
            state.authorizationStatus = status
            state.accuracyAuthorization = accuracy
            state.allowsBackground = background
            state.isInErrorState = false
        case let .location(_, newLocation):
            state.requestingAuthorization = false
            state.lastLocation = newLocation
            state.isInErrorState = false
        case .error:
            state.isInErrorState = true
            state.requestingAuthorization = false
        }
    }
}

public typealias LocationDependencies = (
    requestAuthorization: (_ always: Bool) -> Void,
    monitor: () -> any Publisher<CoreLocationPublisher.Event, Error>,
    startUpdatingLocation: () -> Void
)

// MARK: - MIDDLEWARE
public extension EffectMiddleware where InputActionType == CoreLocationAction, OutputActionType == CoreLocationAction, StateType == CoreLocationState {
    static func coreLocation() -> MiddlewareReader<LocationDependencies, EffectMiddleware<InputActionType, OutputActionType, StateType, LocationDependencies>> {
        EffectMiddleware<CoreLocationAction, CoreLocationAction, CoreLocationState, LocationDependencies>.onAction { action, _, state in
            switch action {
            case let .authorizationRequest(always):
                Effect(token: "CLLocation") { context in
                    let requestAuthorization = context.dependencies.requestAuthorization

                    return context.dependencies
                        .monitor()
                        .eraseToAnyPublisher()
                        .map { event in
                            switch event {
                            case let .authorizationStatus(status, accuracy, background):
                                DispatchedAction(.authorizationResponse(status: status, accuracy: accuracy, background: background))
                            case let .location(location):
                                DispatchedAction(.location(from: state().lastLocation, to: location))
                            }
                        }
                        .catch(CoreLocationAction.error >>> flip(DispatchedAction<CoreLocationAction>.init(_:dispatcher:))(.here()) >>> Just.init)
                        .handleEvents(
                            receiveSubscription: const(requestAuthorization(always))
                        )
                }

            case let .authorizationResponse(status, _, _) where [.authorizedWhenInUse, .authorizedAlways].contains(status):
                .fireAndForget { context in
                    context.dependencies.startUpdatingLocation()
                }

            case .authorizationResponse, .location, .error:
                .doNothing
            }
        }
    }
}
