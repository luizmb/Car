import AppDomain
import SwiftRex
import SwiftRexArchitecture
import SwiftRexSwiftUI
import SwiftUI

/// Pick a destination, pick a route.
///
/// Used stationary, before setting off — which is why it is an ordinary readable screen rather than
/// the oversized-target treatment the fuel form gets. Once riding, the rider should not be looking
/// at this at all.
struct RoutePlannerView: View {
    let viewStore: ViewStore<NavigationFeature.State, NavigationFeature.Action>
    /// The same two closures the behaviour speaks with, handed to the view rather than reimplemented
    /// in it. A private `String(format: "%.0f miles")` here would be a second opinion about units and
    /// locale — one the World already holds, and one that would drift the moment either changed.
    let formatDistance: @Sendable (Meters) -> String
    let formatDuration: @Sendable (TimeInterval) -> String

    var body: some View {
        Form {
            destinationSection
            preferencesSection
            resultsSection
        }
        .navigationTitle("Navigate")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewStore.dispatch(.appeared) }
    }

    // MARK: - Destination

    @ViewBuilder
    private var destinationSection: some View {
        Section("Destination") {
            HStack {
                TextField(
                    "Address or postcode",
                    text: viewStore.binding(.state(\.query), dispatch: .action(\.setQuery))
                )
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { viewStore.dispatch(.search) }

                if viewStore.state.isSearching {
                    ProgressView()
                } else if !viewStore.state.query.isEmpty {
                    Button {
                        viewStore.dispatch(.clear)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            // Search is explicit rather than per-keystroke: Apple throttles address lookups, and a
            // request per character earns that throttle within one postcode.
            Button("Search") { viewStore.dispatch(.search) }
                .disabled(viewStore.state.query.trimmingCharacters(in: .whitespaces).isEmpty)

            ForEach(viewStore.state.suggestions) { suggestion in
                Button {
                    viewStore.dispatch(.choose(suggestion))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                            .foregroundStyle(.primary)
                        if !suggestion.subtitle.isEmpty {
                            Text(suggestion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Preferences

    @ViewBuilder
    private var preferencesSection: some View {
        Section {
            Toggle(
                "Avoid motorways",
                isOn: viewStore.binding(
                    .state(\.preferences.avoidMotorways), dispatch: .action(\.setAvoidMotorways)
                )
            )
            Toggle(
                "Avoid tolls",
                isOn: viewStore.binding(
                    .state(\.preferences.avoidTolls), dispatch: .action(\.setAvoidTolls)
                )
            )
        } footer: {
            // Says what the switches actually do, because it is not what they do in other apps.
            Text("Routes that use these are hidden, not just discouraged.")
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if viewStore.state.isRouting {
            Section {
                HStack {
                    ProgressView()
                    Text("Finding routes…").foregroundStyle(.secondary)
                }
            }
        } else if let outcome = viewStore.state.outcome {
            switch outcome {
            case let .routes(routes) where !routes.isEmpty:
                Section("\(routes.count) route\(routes.count == 1 ? "" : "s")") {
                    ForEach(routes) { route in
                        routeRow(route)
                    }
                }
            case .routes:
                message("No route found.", icon: "questionmark.circle")
            case let .excludedByPreferences(preferences):
                // The distinction the outcome type exists for: routes were found, and the rider's
                // own exclusions are what emptied the list. Saying only "no route" would be a lie
                // they could not act on.
                message(noRouteAnnouncement(preferences), icon: "exclamationmark.triangle")
            case let .failed(error):
                message(routeErrorMessage(error), icon: "exclamationmark.triangle")
            }
        } else if viewStore.state.destination != nil && !viewStore.state.canRoute {
            message("Waiting for a GPS fix…", icon: "location")
        }
    }

    @ViewBuilder
    private func routeRow(_ route: RouteOption) -> some View {
        let isChosen = viewStore.state.chosen?.id == route.id
        Button {
            viewStore.dispatch(.select(route))
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(formatDuration(route.travelTime))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(routeDetail(route))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private func routeDetail(_ route: RouteOption) -> String {
        let distance = formatDistance(route.distance)
        return route.name.isEmpty ? distance : "\(distance) · via \(route.name)"
    }

    @ViewBuilder
    private func message(_ text: String, icon: String) -> some View {
        Section {
            Label(text, systemImage: icon)
                .foregroundStyle(.secondary)
        }
    }
}

extension NavigationFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        RoutePlannerView(
            viewStore: ViewStore(store),
            formatDistance: environment.formatDistance,
            formatDuration: environment.formatDuration
        )
    }
}
