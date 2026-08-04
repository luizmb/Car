import AppDomain
import SwiftRex
import SwiftRexArchitecture
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
                .navigationDestination(for: AppRoute.self) { route in
                    router.destination(for: route)
                }
                // The first thing to actually use the navigation machinery — until now every
                // route enum was uninhabited.
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 10) {
                        // Full briefing on demand. Tap speaks every provider including the silent
                        // ones, which is how a quietly-broken source identifies itself; long-press
                        // gives the short exception report for comparison.
                        Button {
                            viewStore.dispatch(.speakFlightPlan(.full))
                        } label: {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .font(.title3)
                                .padding(14)
                                .glassEffect(.regular, in: .circle)
                        }
                        .simultaneousGesture(LongPressGesture().onEnded { _ in
                            viewStore.dispatch(.speakFlightPlan(.exceptions))
                        })

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
}
