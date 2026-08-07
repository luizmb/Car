import MapKit
import SwiftUI

public struct SpeedMonitorContent: View {
    // Map
    public let mapLatitude: Double
    public let mapLongitude: Double
    public let mapDistance: Double
    public let mapHeading: Double
    public let mapPitch: Double
    // Speed
    public let speedText: String
    public let speedValue: Double
    public let speedAccuracyText: String
    // Direction
    public let directionText: String
    public let courseAngleDegrees: Double
    // Info
    public let coordinatesText: String
    public let altitudeText: String
    // Road
    public let roadLimitDisplay: RoadLimitDisplay
    public let roadRef: String?
    public let roadName: String?
    /// The chosen route, already thinned. Empty when nothing is being navigated to.
    public let routeShape: [CLLocationCoordinate2D]

    public var body: some View {
        ZStack(alignment: .top) {
            map

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    limitSignArea
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                }
                Spacer()
            }
        }
        // The instruments float over the map rather than insetting it.
        //
        // The old arrangement was a full-width panel with a material background eating the bottom
        // quarter of the screen — a third of the map gone to show one number. On a bike the map is
        // the instrument: it is what tells you which lane and which exit.
        .overlay(alignment: .bottomTrailing) { speedBubble }
        .overlay(alignment: .bottom) { positionStrip }
        // **No `ignoresSafeArea` here.** The map has its own, which is what lets it run edge to edge;
        // putting one on the stack pushed everything else out with it — the limit sign behind the
        // Dynamic Island, the footer under the home indicator, and the road-name bubble (attached as
        // an overlay on this view from `AppRootView`) off the top of the screen entirely.
        //
        // Only the map should bleed. Everything readable stays inside the safe area, which is the
        // whole point of the safe area on a phone clamped to handlebars.
    }

    // MARK: - Map

    private var map: some View {
        Map(
            position: .constant(.camera(MapCamera(
                centerCoordinate: .init(latitude: mapLatitude, longitude: mapLongitude),
                distance: mapDistance,
                heading: mapHeading,
                pitch: mapPitch
            ))),
            interactionModes: []
        ) {
            // Under the rider marker, so the arrow is never hidden by the line it is following.
            if routeShape.count > 1 {
                MapPolyline(coordinates: routeShape)
                    .stroke(.blue.opacity(0.7), style: StrokeStyle(
                        lineWidth: 7, lineCap: .round, lineJoin: .round
                    ))
            }

            UserAnnotation {
                Image(systemName: "location.north.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
        }
        .mapControlVisibility(.hidden)
        .ignoresSafeArea()
    }

    /// "A505 - High Street", "M25", "High Street", or nil. Never shows duplicates.
    ///
    /// Public so the overlay stack can render it: it used to be a strip inside this view and
    /// collided with the status bubbles, so it now lives alongside them instead.
    public static func roadDisplayText(ref: String?, name: String?) -> String? {
        switch (ref, name) {
        case (nil, nil):                    nil
        case (let r?, nil):                 r
        case (nil, let n?):                 n
        case (let r?, let n?) where r == n: r
        case (let r?, let n?):              "\(r) - \(n)"
        }
    }

    // MARK: - Speed limit sign(s) (top-right)

    @ViewBuilder
    private var limitSignArea: some View {
        switch roadLimitDisplay {
        case .none:
            EmptyView()
        case .unknown:
            SpeedSignUnknown(size: 68)
        case .known(let text, let value):
            SpeedSignKnown(text: text, value: value, size: 68)
        case .national(let text, let value):
            HStack(spacing: 6) {
                SpeedSignNational(size: 60)
                SpeedSignKnown(text: text, value: value, size: 60)
            }
        case .nationalOnly:
            SpeedSignNational(size: 68)
        case let .assumed(text, value):
            // No NSL sign — that sign means 60 or 70, and this is the built-up default. Labelled
            // instead, so the figure is never mistaken for one read off a real sign.
            VStack(spacing: 2) {
                SpeedSignKnown(text: text, value: value, size: 60)
                Text("ASSUMED")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.gray, in: Capsule())
            }
        case let .variable(text, value):
            // Marked "VAR" because the number is OSM's default rather than what the gantries are
            // showing. Displaying it unqualified would assert something we cannot know.
            VStack(spacing: 2) {
                if let text {
                    SpeedSignKnown(text: text, value: value, size: 60)
                } else {
                    SpeedSignNational(size: 60)
                }
                Text("VAR")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.orange, in: Capsule())
            }
        }
    }

    // MARK: - Speed (bottom-right, floating)

    /// The number, in a glass bubble in the corner.
    ///
    /// Deliberately outside the safe area at the bottom. There is nothing under it to avoid — the
    /// home indicator is a line, not a control — and on a phone clamped to handlebars the corner is
    /// the easiest place for an eye to find without hunting.
    private var speedBubble: some View {
        VStack(spacing: -2) {
            Text(speedText)
                .font(.system(size: 54, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: speedValue))
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: speedValue)
            Text("mph")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.trailing, 14)
        .padding(.bottom, 2)
    }

    /// Heading, position and altitude, as small as they can usefully be.
    ///
    /// These are diagnostics, not instruments — nobody rides by their latitude. They keep their place
    /// so the data is there when something needs checking, with no background of their own, because
    /// a bar across the bottom is a bar across the map.
    private var positionStrip: some View {
        HStack(spacing: 10) {
            Text(directionText)
            Text(coordinatesText).monospacedDigit()
            Text(altitudeText)
            if !speedAccuracyText.isEmpty {
                Text(speedAccuracyText).monospacedDigit()
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .padding(.bottom, 2)
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Speed limit sign components

/// White circle, red border, animated number — explicit UK speed limit.
private struct SpeedSignKnown: View {
    let text: String
    let value: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().stroke(Color.red, lineWidth: size * 0.09)
            Text(text)
                .font(.system(size: size * 0.40, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: value)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 2)
    }
}

/// White circle with diagonal stripe — UK national speed limit sign.
private struct SpeedSignNational: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().stroke(.black, lineWidth: max(1, size * 0.025))
            RoundedRectangle(cornerRadius: size * 0.025)
                .fill(.black)
                .frame(width: size * 0.1, height: size * 0.72)
                .rotationEffect(.degrees(-45))   // "/" stripe direction
                .clipShape(Circle().inset(by: size * 0.04))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 2)
    }
}

/// White circle, faded red border, "?" — no OSM speed data.
private struct SpeedSignUnknown: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().stroke(Color.red.opacity(0.45), lineWidth: size * 0.09)
            Text("?")
                .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                .foregroundStyle(.gray)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
    }
}
