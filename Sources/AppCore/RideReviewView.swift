import AppDomain
import Charts
import CoreLocation
import MapKit
import SwiftRex
import SwiftRexArchitecture
import SwiftRexSwiftUI
import SwiftUI

/// The ride list, and a detail sheet per ride — bound **granularly**, and decomposed to make the
/// granularity real: SwiftUI tracks observation per `body`, so a `@ViewBuilder` helper's reads
/// accrue to its caller and only a separate view struct opens a new invalidation boundary. Each
/// piece below is therefore its own struct with its own `body` and its own narrow set of tracked
/// fields — the same `TrackedViewStore` passed down, because the granularity lives in the mirror's
/// per-field observation, not in how small a projection is.
///
/// Nothing here computes. The rows arrive worded, the series arrive cut and downsampled, the ball
/// finds its place by binary search — the screen is a reader of prepared values, which is both the
/// performance fix and the honest division of labour.
public struct RideReviewView: View {
    let viewStore: TrackedViewStore<RideReviewFeature.State, RideReviewFeature.Action>

    public var body: some View {
        List {
            if viewStore.state.isLoading && viewStore.state.rows.isEmpty {
                HStack {
                    ProgressView()
                    Text("Reading the journey log…").foregroundStyle(.secondary)
                }
            } else if viewStore.state.rows.isEmpty {
                Label("No rides recorded yet.", systemImage: "road.lanes")
                    .foregroundStyle(.secondary)
            }

            ForEach(viewStore.state.rows) { row in
                Button {
                    viewStore.dispatch(.select(row.id))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.title).foregroundStyle(.primary)
                            if !row.endedCleanly {
                                Image(systemName: "bolt.slash")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("The app was killed mid-ride; the end time is the last record.")
                            }
                        }
                        Text(row.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Rides")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewStore.dispatch(.appeared) }
        .sheet(isPresented: Binding(
            get: { viewStore.state.selected != nil },
            set: { if !$0 { viewStore.dispatch(.select(nil)) } }
        )) {
            RideDetailSheet(viewStore: viewStore)
        }
    }
}

// MARK: - Detail

/// The sheet's chrome and worded sections. Reads `words` and `exportURL`; a scrub tick or a chart
/// window change never re-evaluates this body.
private struct RideDetailSheet: View {
    let viewStore: TrackedViewStore<RideReviewFeature.State, RideReviewFeature.Action>

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RideMap(viewStore: viewStore)
                    .frame(height: 230)
                detailList
            }
            .navigationTitle("Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { viewStore.dispatch(.select(nil)) }
                }
            }
        }
    }

    private var detailList: some View {
        List {
            Section("Ride") {
                ForEach(viewStore.state.words.facts) { fact in
                    LabeledContent(fact.label, value: fact.value)
                }
                if !viewStore.state.words.endedCleanly {
                    Label(
                        "The app was killed mid-ride — the end time is the last record.",
                        systemImage: "bolt.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            RideCharts(viewStore: viewStore)

            if let warnings = viewStore.state.words.cameraWarnings {
                Section("Enforcement") {
                    LabeledContent("Warnings given", value: warnings)
                }
            }

            if !viewStore.state.words.roads.isEmpty {
                Section("Roads · \(viewStore.state.words.roads.count)") {
                    ForEach(viewStore.state.words.roads) { road in
                        LabeledContent(road.label) { Text(road.value) }
                    }
                }
            }

            Section {
                Button {
                    if let id = viewStore.state.selected {
                        viewStore.dispatch(.replayRide(id))
                    }
                } label: {
                    Label("Replay this ride", systemImage: "play.circle")
                }
            } footer: {
                Text("The home screen plays the ride back in real time, announcements included.")
            }

            if let destination = viewStore.state.words.destination,
               let label = viewStore.state.words.destinationLabel {
                Section {
                    Button {
                        viewStore.dispatch(.navigateAgain(destination))
                    } label: {
                        Label(label, systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                } footer: {
                    Text("Routes are computed fresh — same destination, today's roads.")
                }
            }

            Section {
                if let url = viewStore.state.exportURL {
                    ShareLink(item: url) {
                        Label("Share GPX", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        viewStore.dispatch(.exportGPX)
                    } label: {
                        Label("Export GPX", systemImage: "map")
                    }
                }
            } footer: {
                Text("GPX carries the track only; the journey log keeps everything else.")
            }
        }
    }
}

// MARK: - The map

/// The pinned map with the scrub ball. Its own body on purpose: it reads `detail` and
/// `scrubTime`, so a scrub tick re-renders the ball — and only the ball's map.
private struct RideMap: View {
    let viewStore: TrackedViewStore<RideReviewFeature.State, RideReviewFeature.Action>

    var body: some View {
        let detail = viewStore.state.detail
        Map {
            if let track = detail?.track, track.count > 1 {
                MapPolyline(coordinates: track.map {
                    CLLocationCoordinate2D(latitude: $0.latitude.rawValue, longitude: $0.longitude.rawValue)
                })
                .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let first = detail?.track.first {
                Marker("Start", systemImage: "flag", coordinate: CLLocationCoordinate2D(
                    latitude: first.latitude.rawValue, longitude: first.longitude.rawValue
                ))
                .tint(.green)
            }
            if let last = detail?.track.last, (detail?.track.count ?? 0) > 1 {
                Marker("End", systemImage: "flag.checkered", coordinate: CLLocationCoordinate2D(
                    latitude: last.latitude.rawValue, longitude: last.longitude.rawValue
                ))
                .tint(.red)
            }
            // The ball: where the finger's moment happened, found by binary search over the
            // precomputed timeline rather than a walk over the ride.
            if
                let detail,
                let scrubTime = viewStore.state.scrubTime,
                let place = trackPosition(
                    at: scrubTime, times: detail.fixTimes, coordinates: detail.fixCoordinates
                ) {
                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: place.latitude.rawValue, longitude: place.longitude.rawValue
                )) {
                    Circle()
                        .fill(.orange)
                        .stroke(.white, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .shadow(radius: 2)
                }
            }
        }
        .mapControlVisibility(.hidden)
    }
}

// MARK: - The charts

/// The four synced charts, in one body: they deliberately share a dependency set — window, anchor,
/// scrub — because a pinch or a scroll *must* move all four together. What keeps them cheap is the
/// data, not the boundary: each draws a few hundred downsampled points that never change while a
/// finger is on them.
private struct RideCharts: View {
    let viewStore: TrackedViewStore<RideReviewFeature.State, RideReviewFeature.Action>

    var body: some View {
        let detail = viewStore.state.detail
        Group {
            if let speed = detail?.speed, speed.count > 1 {
                Section("Speed · mph") {
                    sharedChart {
                        ForEach(Array(speed.enumerated()), id: \.offset) { _, point in
                            LineMark(x: .value("Time", point.time), y: .value("mph", point.value))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
            }
            if let altitude = detail?.altitude, altitude.count > 1 {
                Section("Altitude · m") {
                    sharedChart {
                        ForEach(Array(altitude.enumerated()), id: \.offset) { _, point in
                            LineMark(x: .value("Time", point.time), y: .value("m", point.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(.teal)
                        }
                    }
                }
            }
            if let gradient = detail?.gradient, gradient.count > 1 {
                Section("Gradient · %") {
                    sharedChart {
                        ForEach(Array(gradient.enumerated()), id: \.offset) { _, point in
                            LineMark(x: .value("Time", point.time), y: .value("%", point.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(.purple)
                        }
                        RuleMark(y: .value("level", 0))
                            .lineStyle(StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Indicators · \(viewStore.state.words.indicatorSummary)") {
                if detail?.indicators.isEmpty != false {
                    Text("No indicator use recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    sharedChart(height: 90) {
                        ForEach(Array((detail?.indicators ?? []).enumerated()), id: \.offset) { _, interval in
                            RectangleMark(
                                xStart: .value("From", interval.start),
                                xEnd: .value("To", interval.end),
                                y: .value("Side", interval.side == "left" ? "L" : "R")
                            )
                            .foregroundStyle(interval.side == "left" ? .teal : .orange)
                            .cornerRadius(3)
                        }
                    }
                }
            }
        }
    }

    /// One chart, wearing the shared window: same visible domain, same scrub rule, same gestures.
    private func sharedChart<Content: ChartContent>(
        height: CGFloat = 150,
        @ChartContentBuilder content: () -> Content
    ) -> some View {
        Chart {
            content()
            if let scrubTime = viewStore.state.scrubTime {
                RuleMark(x: .value("Here", scrubTime))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.orange)
            }
        }
        .chartXScale(domain: viewStore.state.words.start...viewStore.state.words.end)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: viewStore.state.chartWindowSeconds)
        .chartScrollPosition(x: viewStore.binding(
            .state(\.chartAnchorTime), dispatch: .action(\.chartScrolled)
        ))
        .chartXSelection(value: viewStore.binding(.state(\.scrubTime), dispatch: .action(\.scrub)))
        .frame(height: height)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    viewStore.dispatch(.chartPinchChanged(value.magnification))
                }
                .onEnded { _ in viewStore.dispatch(.chartPinchEnded) }
        )
    }
}
