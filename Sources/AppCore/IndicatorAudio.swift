import AVFoundation
import AppDomain
import Foundation

/// The looping indicator tick.
///
/// Deliberately its own `AVAudioPlayer`, separate from the `AVSpeechSynthesizer` that reads out
/// speeds. That separation is the whole requirement: `stopSpeaking(at:)` acts only on the
/// synthesiser, so an announcement can never cut the ticking, and the ticking can never delay an
/// announcement. Both feed the same session and mix, so Music, Apple Maps, the indicator and the
/// speed readout can all sound at once — which is what happens on a real bike.
///
/// Nothing here ever calls `setActive(false)`. That is the one call that would silence both, and
/// with the app backgrounded for a whole ride it would not obviously come back.
final class IndicatorAudioBox: @unchecked Sendable {
    private let lock = NSLock()
    private var players: [Side: AVAudioPlayer] = [:]
    private var current: Side?

    init() {
        // Preloaded and prepared up front: the first tick has to be instant, and a ride is not
        // the moment to be decoding a WAV off disk.
        Side.allCases.forEach { side in
            guard
                let url = Bundle.module.url(forResource: side.assetName, withExtension: "wav"),
                let player = try? AVAudioPlayer(contentsOf: url)
            else { return }
            player.numberOfLoops = -1        // gapless: the asset is exactly one tick-tock cycle
            // The asset is already normalised to -0.5 dBFS (the source was an unusable -32), so
            // playing it at unity would sit on top of the speed announcements — and those are the
            // app's actual job. 0.7 keeps the tick clearly present while leaving speech room to
            // cut through. First thing to tune by ear on a real ride, with wind noise involved.
            player.volume = 0.7
            player.prepareToPlay()
            players[side] = player
        }
    }

    /// Starts (or switches to) the tick for `side`. Idempotent — re-asserting the side already
    /// playing is a no-op rather than a restart, so a stream of repeated `1010`/`1000` blink
    /// frames doesn't retrigger the loop on every packet.
    func play(_ side: Side) {
        lock.withLock {
            guard current != side else { return }
            current.flatMap { players[$0] }?.stop()
            let player = players[side]
            player?.currentTime = 0
            player?.play()
            current = side
        }
    }

    func stop() {
        lock.withLock {
            current.flatMap { players[$0] }?.stop()
            current = nil
        }
    }
}

private extension Side {
    var assetName: String {
        switch self {
        case .left:  "indicator_left"
        case .right: "indicator_right"
        }
    }
}
