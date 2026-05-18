import Combine
import CombineRex
import Foundation

public typealias SpeechDependencies = (
    speak: (String) -> Void,
    thresholds: [Measurement<UnitSpeed>]
)

public extension EffectMiddleware where InputActionType == AppCore.Action, OutputActionType == AppCore.Action, StateType == AppCore.State {
    static func speech() -> MiddlewareReader<SpeechDependencies, EffectMiddleware<InputActionType, OutputActionType, StateType, SpeechDependencies>> {
        EffectMiddleware<InputActionType, OutputActionType, StateType, SpeechDependencies>.onAction { action, _, state in
            switch action {

            case let .location(.location(oldLocation, newLocation)):
                guard let lastSpeed = oldLocation?.speed <&> zeroWhenNegative >>> metersPerSecond >>> mph else {
                    return .doNothing
                }

                return .fireAndForget { context in
                    context.dependencies.thresholds.compactMap { threshold in
                        switch (lastSpeed, newLocation.speed |> (zeroWhenNegative >>> metersPerSecond >>> mph)) {
                        case (..<threshold, ..<threshold):
                            nil
                        case (..<threshold, _):
                            threshold |> formatSpeedSpeech
                        case (_, ..<threshold):
                            "k"
                        default:
                            nil
                        }
                    }.first <&> context.dependencies.speak
                }

            case .location(.error):
                return .fireAndForget { context in
                    context.dependencies.speak("An error occurred. The app has restarted.")
                }
            case .app, .location:
                return .doNothing
            }
        }
    }
}
