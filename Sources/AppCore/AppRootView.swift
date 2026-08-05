import AppDomain
import SwiftRex
import SwiftRexArchitecture
import SpeedMonitorFeature
import SwiftRexSwiftUI
import SwiftUI

/// The app shell — a `NavigationStack` over the store's path.
///
/// It knows exactly two things: a ``ViewStore`` and an ``AppRouter``. No `World`, no feature types, no
/// idea how a child screen is assembled — it asks the router for a destination and renders it. Both are
/// handed in at construction by ``AppFeature``, which is the only place holding the `World`.
///
/// The view store is what makes the stack work at all. A bare `Store` is not `@Observable`, so a root
/// view holding one renders once and then never again — the failure that broke navigation in
/// PookiePayslip. Going through ``ViewStore`` (the same machinery every other screen's view uses) means
/// that is no longer expressible here.
///
/// Holding the router rather than reading it from `@Environment` is deliberate: it is deterministic
/// across sheet and cover boundaries, exactly where SwiftUI's environment propagation is not.
public struct AppRootView: View, Routable {
    let viewStore: ViewStore<AppState, AppAction>
    public let router: AppRouter

    init(viewStore: ViewStore<AppState, AppAction>, router: AppRouter) {
        self.viewStore = viewStore
        self.router = router
    }

    public var body: some View {
        NavigationStack(
            path: viewStore.binding(.state(\.routes), dispatch: .action(\.navigation.setPath))
        ) {
            router.root()
                // Hidden on the root so the map runs edge to edge. The road name used to be a
                // strip inside the speed screen and collided with the status bubbles; it is now
                // one of them. Pushed screens keep their bar, and their back button with it.
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: AppRoute.self) { route in
                    router.destination(for: route)
                }
                // One column, one overlay. Two top-leading overlays with the same padding — the
                // road name here and the status bubbles inside `root()` — drew on top of each
                // other, so the ignition bubble and the road name occupied the same pixels.
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        roadBubble
                        router.statusBubbles()
                    }
                    .padding(.leading, 12)
                    .padding(.top, 6)
                }
                // The first thing to actually use the navigation machinery — until now every
                // route enum was uninhabited.
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 10) {
                        // Two plain buttons rather than tap/long-press on one. A
                        // `simultaneousGesture(LongPressGesture())` attached to a Button competes
                        // with the button's own tap recognition and can swallow it outright —
                        // which is exactly what happened: the full report did nothing on tap.
                        Button {
                            viewStore.dispatch(.speakFlightPlan(.full))
                        } label: {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .font(.title3)
                                .padding(14)
                                .glassEffect(.regular, in: .circle)
                        }

                        Button {
                            viewStore.dispatch(.speakFlightPlan(.exceptions))
                        } label: {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.title3)
                                .padding(14)
                                .glassEffect(.regular, in: .circle)
                        }

                        Button {
                            viewStore.dispatch(.navigation(.push(.fuel)))
                        } label: {
                            Image(systemName: "fuelpump.fill")
                                .font(.title3)
                                .padding(14)
                                .glassEffect(.regular, in: .circle)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 190)
                }
        }
    }

    /// Road and limit, as a bubble alongside the other status overlays.
    ///
    /// It used to be a strip inside the speed screen, where it collided with the status bubbles
    /// overlaid on top of it. Moving it here makes it one of them, and lets the map run edge to edge.
    @ViewBuilder
    private var roadBubble: some View {
        let display = viewStore.state.speedMonitor.display
        if let road = SpeedMonitorContent.roadDisplayText(ref: display.roadRef, name: display.roadName) {
            Text(road)
                .font(.caption2.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .fixedSize()
        }
    }
}
