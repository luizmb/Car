import AVFoundation
import AppDomain
import Foundation
import ReactiveConcurrency

/// Bridges `AVAudioSession` route changes into a stream, emitting the current route immediately on
/// subscribe so a late subscriber is not left blind until the next physical connect.
///
/// **Cold**, like every other factory in `World`: supervision re-runs after each state change, so
/// an eager version would register an observer several times a second. The observer is removed when
/// the subscription ends.
///
/// Deliberately never touches `setActive` — the session is activated once at startup and must stay
/// that way, or both the speech and the indicator tick go silent for the rest of a backgrounded ride.
func makeAudioRouteStream() -> Publisher<AudioRoute, Never> {
    Publisher { continuation in
        let (stream, streamContinuation) = AsyncStream<AudioRoute>.makeStream()

        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            streamContinuation.yield(AVAudioSession.sharedInstance().currentRoute.domain)
        }

        // Seed with the route as it stands, so state is correct before anything changes.
        streamContinuation.yield(AVAudioSession.sharedInstance().currentRoute.domain)

        await continuation.yieldAll(stream)   // parks until cancelled

        NotificationCenter.default.removeObserver(observer)
    }
}

private extension AVAudioSessionRouteDescription {
    var domain: AudioRoute {
        AudioRoute(outputs: outputs.map {
            AudioOutput(portType: $0.portType.rawValue, portName: $0.portName, uid: $0.uid)
        })
    }
}
