import AppDomain
import CoreLocation
import MapKit
import SwiftRex
import SwiftRexArchitecture
import SwiftRexSwiftUI
import SwiftUI

/// Pick a destination, then pick a route off the map.
///
/// Two screens in one, because they are two different jobs. Finding an address is typing and
/// reading, so it gets the whole screen. Choosing between routes is *comparing shapes* — which one
/// goes through town, which one loops round — and a list of times and distances cannot answer that.
/// So once there is a destination the map takes over and the options become a bottom sheet, the way
/// every navigation app does it, because it is the only arrangement where the thing being chosen is
/// visible while you choose it.
struct RoutePlannerView: View {
    let viewStore: ViewStore<NavigationFeature.State, NavigationFeature.Action>
    /// The same closures the behaviour speaks with, handed to the view rather than reimplemented in
    /// it. A private `String(format: "%.0f miles")` here would be a second opinion about units and
    /// locale — one the World already holds, and one that would drift the moment either changed.
    let formatDistance: @Sendable (Meters) -> String
    let formatDuration: @Sendable (TimeInterval) -> String
    let formatTime: @Sendable (Date) -> String
    let now: @Sendable () -> Date

    var body: some View {
        Group {
            if viewStore.state.destination == nil {
                searchScreen
            } else {
                mapScreen
            }
        }
        .navigationTitle(viewStore.state.destination == nil ? "Where to?" : "Routes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewStore.dispatch(.appeared) }
    }

    // MARK: - Finding somewhere

    private var searchScreen: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(
                        "Address or postcode",
                        text: viewStore.binding(.state(\.query), dispatch: .action(\.setQuery))
                    )
                    // `.words`, not `.characters`. One field takes both a postcode and a street, and
                    // forcing capitals suits only the postcode — "AMPTHILL ROAD" is awkward to type
                    // and read, while "mk42 9az" matches perfectly well.
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)

                    if viewStore.state.isSearching { ProgressView() }
                }
            }

            // Where this rider actually goes, offered before they type. Each entry already
            // carries the coordinates it resolved to at the time, so choosing one skips the
            // completer and the geocoder entirely.
            if viewStore.state.query.isEmpty, viewStore.state.suggestions.isEmpty,
               !viewStore.state.recentDestinations.isEmpty {
                Section("Recent") {
                    ForEach(viewStore.state.recentDestinations) { recent in
                        Button {
                            viewStore.dispatch(.destinationResolved(recent))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text(recent.title).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }

            // No Search button. Completions are what Apple Maps' own suggestion list uses — cheap,
            // and they arrive as you type, which is what makes a street name give more than the one
            // result a full search resolves it to.
            ForEach(viewStore.state.suggestions) { suggestion in
                Button {
                    viewStore.dispatch(.choose(suggestion))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).foregroundStyle(.primary)
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
    }

    // MARK: - Choosing a route

    private var mapScreen: some View {
        routeMap
            .ignoresSafeArea(edges: .bottom)
            .sheet(isPresented: .constant(true)) {
                routeSheet
                    // No `.large`. The map is the point of this screen, and a sheet that can be
                    // pulled over all of it defeats the comparison it exists to support.
                    .presentationDetents([.height(260), .medium])
                    // Scrolling the list must scroll the list, not grow the sheet — which is what
                    // was swallowing the map as soon as there were more routes than fitted.
                    .presentationContentInteraction(.scrolls)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    // Dismissing would leave a map with no way back to the options.
                    .interactiveDismissDisabled()
            }
    }

    /// Every candidate drawn at once, the chosen one on top and in colour.
    ///
    /// Drawn together rather than one at a time because the comparison *is* the overlap: what
    /// distinguishes two routes is where they diverge, and that is only visible with both on screen.
    private var routeMap: some View {
        Map(position: .constant(.automatic)) {
            // Unchosen first, so the chosen one is drawn over them rather than under.
            ForEach(viewStore.state.routes.filter { $0.id != viewStore.state.chosen?.id }) { route in
                MapPolyline(coordinates: route.shape.map(\.clCoordinate))
                    .stroke(.gray.opacity(0.6), style: StrokeStyle(
                        lineWidth: 6, lineCap: .round, lineJoin: .round
                    ))
            }
            ForEach(viewStore.state.routes.filter { $0.id == viewStore.state.chosen?.id }) { route in
                MapPolyline(coordinates: route.shape.map(\.clCoordinate))
                    .stroke(.blue, style: StrokeStyle(
                        lineWidth: 8, lineCap: .round, lineJoin: .round
                    ))
            }

            // The badges are the comparison. A list of times cannot say *which line* is the 20
            // minute one, and that is the only question being asked on this screen.
            ForEach(Array(viewStore.state.routes.enumerated()), id: \.element.id) { index, route in
                if let anchor = badgeAnchor(route, index: index, of: viewStore.state.routes.count) {
                    Annotation("", coordinate: anchor.clCoordinate) {
                        routeBadgeLabel(route)
                    }
                }
            }

            if let destination = viewStore.state.destination?.coordinate {
                Marker(
                    viewStore.state.destination?.title ?? "Destination",
                    coordinate: destination.clCoordinate
                )
                .tint(.red)
            }

            UserAnnotation()
        }
        .mapControlVisibility(.hidden)
    }

    /// Tappable, because the badge is where the eye already is when comparing two lines.
    @ViewBuilder
    private func routeBadgeLabel(_ route: RouteOption) -> some View {
        let isChosen = route.id == viewStore.state.chosen?.id
        Button {
            viewStore.dispatch(.select(route))
        } label: {
            VStack(spacing: 0) {
                Text(formatDuration(route.travelTime))
                    .font(.subheadline.weight(.semibold))
                if let badge = routeBadge(route, among: viewStore.state.routes) {
                    Text(badge).font(.caption2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isChosen ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(isChosen ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var routeSheet: some View {
        NavigationStack {
            List {
                if viewStore.state.isRouting {
                    HStack {
                        ProgressView()
                        Text("Finding routes…").foregroundStyle(.secondary)
                    }
                } else if let outcome = viewStore.state.outcome {
                    outcomeSection(outcome)
                } else if !viewStore.state.canRoute {
                    Label("Waiting for a GPS fix…", systemImage: "location")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(
                        "Avoid motorways",
                        isOn: viewStore.binding(
                            .state(\.preferences.avoidMotorways),
                            dispatch: .action(\.setAvoidMotorways)
                        )
                    )
                    Toggle(
                        "Avoid tolls",
                        isOn: viewStore.binding(
                            .state(\.preferences.avoidTolls),
                            dispatch: .action(\.setAvoidTolls)
                        )
                    )
                } footer: {
                    // Says what the switches do, because it is not what they do in other apps.
                    Text("Routes that use these are hidden, not just discouraged.")
                }
            }
            .navigationTitle(viewStore.state.destination?.title ?? "Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Change") { viewStore.dispatch(.clear) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Every row carries its own GO, so there is nothing left for a toolbar button
                    // to do that is not already one tap closer to the route it applies to.
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeSection(_ outcome: RouteSearchOutcome) -> some View {
        switch outcome {
        case let .routes(routes) where !routes.isEmpty:
            Section("\(routes.count) route\(routes.count == 1 ? "" : "s")") {
                ForEach(routes) { route in
                    routeRow(route)
                }
            }
        case .routes:
            Label("No route found.", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case let .excludedByPreferences(preferences):
            // The distinction the outcome type exists for: routes were found, and the rider's own
            // exclusions emptied the list. Saying only "no route" would be a lie they cannot act on.
            Label(noRouteAnnouncement(preferences), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case let .failed(error):
            Label(routeErrorMessage(error), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func routeRow(_ route: RouteOption) -> some View {
        let isChosen = viewStore.state.chosen?.id == route.id
        HStack(alignment: .center) {
            Button {
                viewStore.dispatch(.select(route))
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(formatDuration(route.travelTime))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isChosen ? Color.accentColor : .primary)
                    Text(routeDetail(route))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let badge = routeBadge(route, among: viewStore.state.routes) {
                        Text(badge).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Per row rather than one button in the toolbar: choosing and going are the same
            // gesture when you already know which one you want, and a rider in gloves should not
            // have to tap twice in two different places.
            Button {
                viewStore.dispatch(.start(route, viewStore.state.destination?.title))
            } label: {
                Text("GO").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    /// "05:47 ETA · 17 miles · via A421". The arrival time first, because that is the number a
    /// rider is actually deciding on when they are due somewhere.
    private func routeDetail(_ route: RouteOption) -> String {
        let eta = formatTime(now().addingTimeInterval(route.travelTime))
        let parts = [
            "\(eta) ETA",
            formatDistance(route.distance),
            route.name.isEmpty ? nil : "via \(route.name)"
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

private extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude.rawValue, longitude: longitude.rawValue)
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
            formatDuration: environment.formatDuration,
            formatTime: environment.formatTime,
            now: environment.now
        )
    }
}
