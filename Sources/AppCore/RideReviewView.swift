import AppDomain
import Charts
import CoreLocation
import MapKit
import SwiftRex
import SwiftRexArchitecture
import SwiftRexSwiftUI
import SwiftUI

/// The ride list, and a detail sheet per ride.
///
/// A sheet rather than a second pushed screen: the app's routes are payload-free by design, and a
/// detail screen as a route would need the selection smuggled through navigation. The selection is
/// feature state; the sheet is its visibility.
struct RideReviewView: View {
    let viewStore: ViewStore<RideReviewFeature.State, RideReviewFeature.Action>
    let formatDistance: @Sendable (Meters) -> String
    let formatDuration: @Sendable (TimeInterval) -> String
    let formatTime: @Sendable (Date) -> String
    let formatSpeed: @Sendable (MPH) -> String

    var body: some View {
        List {
            if viewStore.state.isLoading && viewStore.state.rides.isEmpty {
                HStack {
                    ProgressView()
                    Text("Reading the journey log…").foregroundStyle(.secondary)
                }
            } else if viewStore.state.rides.isEmpty {
                Label("No rides recorded yet.", systemImage: "road.lanes")
                    .foregroundStyle(.secondary)
            }

            ForEach(viewStore.state.rides) { ride in
                Button {
                    viewStore.dispatch(.select(ride.id))
                } label: {
                    row(ride)
                }
            }
        }
        .navigationTitle("Rides")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewStore.dispatch(.appeared) }
        .sheet(item: Binding(
            get: { viewStore.state.selectedRide.map { Selected(ride: $0) } },
            set: { if $0 == nil { viewStore.dispatch(.select(nil)) } }
        )) { selected in
            RideDetailView(
                ride: selected.ride,
                viewStore: viewStore,
                formatDistance: formatDistance,
                formatDuration: formatDuration,
                formatSpeed: formatSpeed
            )
        }
    }

    /// `sheet(item:)` wants `Identifiable`; a ride already is, and the wrapper only exists so the
    /// binding's value type is local to the view.
    private struct Selected: Identifiable {
        let ride: Ride
        var id: Date { ride.id }
    }

    @ViewBuilder
    private func row(_ ride: Ride) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(ride.start.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.primary)
                if !ride.endedCleanly {
                    Image(systemName: "bolt.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("The app was killed mid-ride; the end time is the last record.")
                }
            }
            Text(
                "\(formatDuration(ride.duration)) · "
                    + formatDistance(Meters(ride.distanceMetres))
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detail

/// One ride, examined.
///
/// The map is pinned above the charts rather than being a row among them: a finger over any chart
/// names a moment, and the ball on the map answers *where that was* — which only works if the map
/// is still on screen while the charts are being touched.
///
/// The charts share one time window. Zooming any of them zooms them all and scrolling any scrolls
/// them all, because they are four views of the same ride and a reader comparing speed against
/// gradient needs the columns to line up. The map's zoom is its own — it answers "where", not
/// "when".
private struct RideDetailView: View {
    let ride: Ride
    let viewStore: ViewStore<RideReviewFeature.State, RideReviewFeature.Action>
    let formatDistance: @Sendable (Meters) -> String
    let formatDuration: @Sendable (TimeInterval) -> String
    let formatSpeed: @Sendable (MPH) -> String

    // No view state at all: the scrub, the window and the pinch anchor live in the store, arrive
    // as actions, and come back as state — so the same numbers that drive these pixels are
    // inspectable in the log and shared by every chart and the map without a second copy.

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                rideMap
                    .frame(height: 230)
                charts
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

    // MARK: Map

    private var rideMap: some View {
        let coordinates = ride.track.map {
            CLLocationCoordinate2D(latitude: $0.fix.lat, longitude: $0.fix.lon)
        }
        return Map {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let first = coordinates.first {
                Marker("Start", systemImage: "flag", coordinate: first)
                    .tint(.green)
            }
            if let last = coordinates.last, coordinates.count > 1 {
                Marker("End", systemImage: "flag.checkered", coordinate: last)
                    .tint(.red)
            }
            // The ball: where the finger's moment happened.
            if let scrubTime = viewStore.state.scrubTime, let place = ride.position(at: scrubTime) {
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

    // MARK: Charts

    private var charts: some View {
        List {
            Section("Ride") {
                LabeledContent("Started", value: ride.start.formatted(
                    date: .abbreviated, time: .shortened
                ))
                LabeledContent("Duration", value: formatDuration(ride.duration))
                LabeledContent("Distance", value: formatDistance(Meters(ride.distanceMetres)))
                if let average = ride.averageMovingMPH {
                    LabeledContent("Average moving", value: formatSpeed(MPH(average)))
                }
                if let top = ride.maxMPH {
                    LabeledContent("Top speed", value: formatSpeed(MPH(top)))
                }
                if !ride.endedCleanly {
                    Label(
                        "The app was killed mid-ride — the end time is the last record.",
                        systemImage: "bolt.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            speedChart
            altitudeChart
            gradientChart
            indicatorChart

            if ride.cameraEventCount > 0 {
                Section("Enforcement") {
                    LabeledContent("Warnings given", value: "\(ride.cameraEventCount)")
                }
            }

            let roads = ride.roadsVisited
            if !roads.isEmpty {
                Section("Roads · \(roads.count)") {
                    ForEach(Array(roads.enumerated()), id: \.offset) { _, road in
                        LabeledContent(road.label) {
                            Text(road.mph.map { "\(Int($0)) mph" } ?? "—")
                        }
                    }
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

    @ViewBuilder
    private var speedChart: some View {
        let series = ride.track.compactMap { point in
            point.fix.mph.map { (time: point.time, mph: $0) }
        }
        if series.count > 1 {
            Section("Speed · mph") {
                sharedChart {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("mph", point.mph)
                        )
                        .interpolationMethod(.monotone)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var altitudeChart: some View {
        let series = ride.track.compactMap { point in
            point.fix.alt.map { (time: point.time, metres: $0) }
        }
        if series.count > 1 {
            Section("Altitude · m") {
                sharedChart {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("m", point.metres)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.teal)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var gradientChart: some View {
        let series = ride.gradients
        if series.count > 1 {
            Section("Gradient · %") {
                sharedChart {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("%", point.percent)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.purple)
                    }
                    RuleMark(y: .value("level", 0))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var indicatorChart: some View {
        let intervals = ride.indicatorIntervals
        let counts = ride.indicatorCounts
        Section("Indicators · \(counts.left) left, \(counts.right) right") {
            if intervals.isEmpty {
                Text("No indicator use recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                sharedChart(height: 90) {
                    ForEach(Array(intervals.enumerated()), id: \.offset) { _, interval in
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

    /// One chart, wearing the shared window.
    ///
    /// Every chart gets the same visible-domain length and the same scrub selection, which is what
    /// keeps four views of one ride in step: zoom or scroll any of them and the others follow,
    /// touch any of them and the same rule appears on all — and the ball lands on the map.
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
        .chartXScale(domain: ride.start...max(ride.end, ride.start.addingTimeInterval(60)))
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: viewStore.state.chartWindowSeconds)
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

extension RideReviewFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        RideReviewView(
            viewStore: ViewStore(store),
            formatDistance: environment.formatDistance,
            formatDuration: environment.formatDuration,
            formatTime: environment.formatTime,
            formatSpeed: environment.formatSpeed
        )
    }
}
