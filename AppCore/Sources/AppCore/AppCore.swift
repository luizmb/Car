import AppLifecycleMiddleware
import AVFoundation
import BridgeMiddlewareCombine
import CombineRex
import CoreLocation
import Foundation
import LoggerMiddleware
import SwiftRexMacros

struct World {
    let location: LocationDependencies
    let speech: SpeechDependencies

    static func live() -> World {
        let synthesizer = AVSpeechSynthesizer()
        let locationManager = CLLocationManager()

        return World(
            location: LocationDependencies(
                requestAuthorization: { [weak locationManager] always in
                    guard let locationManager else { return }

                    switch (always, locationManager.authorizationStatus) {
                    case (_, .authorizedAlways),
                        (false, .authorizedWhenInUse):
                        break
                    case (true, _):
                        locationManager.requestAlwaysAuthorization()
                    case (false, _):
                        locationManager.requestWhenInUseAuthorization()
                    }
                },
                monitor: {
                    locationManager.publisher
                },
                startUpdatingLocation: { [weak locationManager] in
                    guard let locationManager else { return }

                    locationManager.startUpdatingLocation()
                }
            ),
            speech: SpeechDependencies(
                speak: { text in
                    let utterance = AVSpeechUtterance(string: text)
                    utterance.voice = AVSpeechSynthesisVoice(language: "en-GB" )
                    utterance.rate = 0.65

                    synthesizer.stopSpeaking(at: .immediate)
                    synthesizer.speak(utterance)
                    print("Speaking \(text)")
                },
                thresholds: [
                    110.0, 99, 88, 77, 66, 55, 44, 33, 22, 11
                ].map(UnitSpeed.milesPerHour |> flip(Measurement.init(value:unit:)))
            )
        )
    }
}

public enum AppCore {}

public extension AppCore {
    struct State: Equatable {
        var app: AppLifecycle
        var location: CoreLocationState

        public static var initialState = Self(
            app: .backgroundInactive,
            location: .init()
        )
    }

    @Prism
    enum Action {
        case app(AppLifecycleAction)
        case location(CoreLocationAction)
    }

    class Store: ReduxStoreBase<Action, State> {
        public init() {
            super.init(
                subject: .combine(
                    initialValue: .initialState
                ),
                reducer: reducer(),
                middleware: middleware(world: .live())
            )
            dispatch(.app(.start))
        }
    }
}

private extension AppCore {
    static func reducer() -> Reducer<Action, State> {
        Reducer.coreLocation.lift(action: \.location, state: \.location)
        <> Reducer.lifecycle.lift(action: \.app, state: \.app)
    }

    static func middleware(world: World) -> AnyMiddleware<Action, Action, State> {
        (
            EffectMiddleware<CoreLocationAction, CoreLocationAction, CoreLocationState, CLLocationManager>
                .coreLocation()
                .lift(inputAction: \.location, outputAction: Action.location, state: \.location)
                .inject(world.location)

            <>
            AppLifecycleMiddleware()
                .lift(inputAction: \.app, outputAction: Action.app, state: ignore)

            <>
            BridgeMiddleware()
                .bridge(
                    on: \.app?.start,
                    dispatch: const(Action.location(.authorizationRequest(always: true)))
                )
                .bridge(
                    on: \.location?.error,
                    dispatch: const(Action.location(.authorizationRequest(always: true)))
                )

            <>
            EffectMiddleware<Action, Action, State, SpeechDependencies>
                .speech()
                .inject(world.speech)
        )
        .logger(stateDiffTransform: .recursive(prefixLines: "🚀", stateName: "s", filters: nil), queue: .global(qos: .utility))
        .eraseToAnyMiddleware()
    }
}
