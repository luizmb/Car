import AppDomain
import SpeedMonitorFeature
import SwiftRex
import SwiftRexArchitecture
import SwiftRexSwiftUI
import SwiftUI

/// The tape on screen: the second monitor — the same view the home screen shows — with a replay
/// badge over it, the ride's blinker as arrows, and a stop button.
///
/// Everything moving here is the lifted monitor doing exactly what it does live; this view only
/// adds the frame that says "this is a film": the badge, the arrows the Indimate once produced,
/// the finished banner when the tape runs out, and the way off.
struct ReplayView: View {
    let store: MainStoreType
    let world: World
    private let viewStore: ViewStore<AppState, AppAction>

    init(store: MainStoreType, world: World) {
        self.store = store
        self.world = world
        viewStore = ViewStore(store)
    }

    private var replay: ReplayFeature.State? {
        viewStore.state.path.compactMap(StackEntry.prism.replay.preview).last
    }

    var body: some View {
        ZStack {
            AppScopes.replayMonitor.pushedView(of: SpeedMonitorFeature.self, from: store, world: world)
        }
        .overlay(alignment: .top) {
            HStack(spacing: 10) {
                // An empty tape says so. A ride with nothing recorded — an interrupted journey
                // that never got a fix — used to play as a dead screen with a 00:00 counter,
                // indistinguishable from every real failure.
                Label(
                    replay?.started == true && replay?.duration == 0 ? "NOTHING RECORDED"
                        : replay?.finished == true ? "REPLAY ENDED" : "REPLAY",
                    systemImage: replay?.started == true && replay?.duration == 0 ? "exclamationmark.circle"
                        : replay?.finished == true ? "checkmark.circle" : "play.circle.fill"
                )
                .font(.caption.weight(.black))
                .foregroundStyle(replay?.started == true && replay?.duration == 0 ? .red
                    : replay?.finished == true ? .green : .orange)

                // The tape counter: recorded stillness ticks, a hang does not.
                Text("\(stamp(replay?.position ?? 0)) / \(stamp(replay?.duration ?? 0))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                indicatorArrows
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 4)
        }
        .overlay(alignment: .topLeading) {
            // The road bubble, as the home screen wears it — the replayed road, not the desk's.
            if let road = SpeedMonitorContent.roadDisplayText(
                ref: replay?.monitor.display.roadRef, name: replay?.monitor.display.roadName
            ) {
                Text(road)
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.leading, 12)
                    .padding(.top, 40)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                viewStore.dispatch(.replay(.cancel))
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .padding(.bottom, 64)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { viewStore.dispatch(.replay(.begin)) }
    }

    private func stamp(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    /// The ride's blinker, as it blinked. Solid rather than animated — the record has edges, and
    /// re-inventing the flash cadence would be decoration on top of data.
    private var indicatorArrows: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.left.fill")
                .foregroundStyle(replay?.indicator == .left ? .green : Color.secondary.opacity(0.3))
            Image(systemName: "arrowshape.right.fill")
                .foregroundStyle(replay?.indicator == .right ? .green : Color.secondary.opacity(0.3))
        }
        .font(.caption)
    }
}
