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
            detail(selected.ride)
        }
    }

    /// `sheet(item:)` wants `Identifiable`; a ride already is, and the wrapper only exists so the
    /// binding's value type is local to the view.
    private struct Selected: Identifiable {
        let ride: Ride
        var id: Date { ride.id }
    }

    // MARK: - List row

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

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ ride: Ride) -> some View {
        NavigationStack {
            List {
                Section {
                    rideMap(ride)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                }

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

                speedChart(ride)

                Section("Indicators") {
                    let counts = ride.indicatorCounts
                    LabeledContent("Left", value: "\(counts.left)")
                    LabeledContent("Right", value: "\(counts.right)")
                }

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
            .navigationTitle("Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { viewStore.dispatch(.select(nil)) }
                }
            }
        }
    }

    private func rideMap(_ ride: Ride) -> some View {
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
        }
        .mapControlVisibility(.hidden)
    }

    /// Speed over the ride, as a line. The one chart that answers "what was that ride like" at a
    /// glance — where the town was, where the open road was, where the lights were.
    @ViewBuilder
    private func speedChart(_ ride: Ride) -> some View {
        let series = ride.track.compactMap { point in
            point.fix.mph.map { (time: point.time, mph: $0) }
        }
        if series.count > 1 {
            Section("Speed") {
                Chart(Array(series.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("mph", point.mph)
                    )
                    .interpolationMethod(.monotone)
                }
                .frame(height: 140)
                .chartYAxisLabel("mph")
            }
        }
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
