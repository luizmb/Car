import MapKit
import SwiftUI

public struct SpeedMonitorContent: View {
    // Map
    public let mapLatitude: Double
    public let mapLongitude: Double
    public let mapDistance: Double
    public let mapHeading: Double
    public let mapPitch: Double
    /// Where the rider actually is — distinct from the camera centre, which looks *ahead* of the
    /// rider while navigating. The marker is drawn from state rather than MapKit's device dot,
    /// which is what lets a replayed ride carry its rider along the tape instead of pinning the
    /// blue dot to the desk the phone is sitting on.
    public let riderLatitude: Double
    public let riderLongitude: Double
    public let riderCourseDegrees: Double
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
    /// Where the rider has dragged the map, or `nil` while it follows the bike. Comes from the
    /// store like everything else here; this view holds no state at all.
    public let browsedCamera: BrowsedCamera?
    /// The browse gesture, as an event on its way to the store.
    public let onMapBrowsed: (BrowsedCamera) -> Void
    public let onRecentre: () -> Void

    public var body: some View {
        ZStack(alignment: .top) {
            map

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    limitSignArea
                        .padding(.trailing, 16)
                        // Below the guidance banner while navigating, rather than beside it. Side by
                        // side, the banner had to stop short of the trailing edge and the two read
                        // as one crowded strip; the sign is the more important of the two and gets
                        // its own line.
                        .padding(.top, isNavigating ? 84 : 8)
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
        .overlay(alignment: .bottomLeading) { recentreButton }
        // **No `ignoresSafeArea` here.** The map has its own, which is what lets it run edge to edge;
        // putting one on the stack pushed everything else out with it — the limit sign behind the
        // Dynamic Island, the footer under the home indicator, and the road-name bubble (attached as
        // an overlay on this view from `AppRootView`) off the top of the screen entirely.
        //
        // Only the map should bleed. Everything readable stays inside the safe area, which is the
        // whole point of the safe area on a phone clamped to handlebars.
    }

    // MARK: - Map

    private var isNavigating: Bool { routeShape.count > 1 }

    private var followingCamera: MapCameraPosition {
        .camera(MapCamera(
            centerCoordinate: .init(latitude: mapLatitude, longitude: mapLongitude),
            distance: mapDistance,
            heading: mapHeading,
            pitch: mapPitch
        ))
    }

    /// The map's camera, spoken redux.
    ///
    /// Reading renders whatever the store says — the browsed camera while the rider holds the map,
    /// the followed one otherwise. Writing *is* the browse gesture: SwiftUI hands back a
    /// user-positioned camera, its five numbers go up as an event, and the store's answer comes
    /// back down through `get`. No view state, no timer, no gesture bookkeeping — the auto-return
    /// lives in the feature, counted in fixes, where it can be tested without a finger.
    private var cameraBinding: Binding<MapCameraPosition> {
        Binding(
            get: {
                guard let browsed = browsedCamera else { return followingCamera }
                return .camera(MapCamera(
                    centerCoordinate: .init(latitude: browsed.latitude, longitude: browsed.longitude),
                    distance: browsed.distance,
                    heading: browsed.heading,
                    pitch: browsed.pitch
                ))
            },
            set: { position in
                // Programmatic moves echo back through this setter too; only the rider's own
                // interaction is an event.
                guard position.positionedByUser else { return }
                if let camera = position.camera {
                    onMapBrowsed(BrowsedCamera(
                        latitude: camera.centerCoordinate.latitude,
                        longitude: camera.centerCoordinate.longitude,
                        distance: camera.distance,
                        heading: camera.heading,
                        pitch: camera.pitch
                    ))
                } else if let region = position.region {
                    // Some interactions come back as a region rather than a camera; its span is
                    // the same fact in different clothes.
                    onMapBrowsed(BrowsedCamera(
                        latitude: region.center.latitude,
                        longitude: region.center.longitude,
                        distance: region.span.latitudeDelta * 111_320 * 1.2,
                        heading: 0,
                        pitch: 0
                    ))
                }
            }
        )
    }

    /// Everything the camera is made of, as one animatable identity. When any of it moves, the
    /// implicit animation below glides the map there instead of teleporting.
    private struct CameraFrame: Equatable {
        let latitude: Double
        let longitude: Double
        let distance: Double
        let heading: Double
        let pitch: Double
        let riderLatitude: Double
        let riderLongitude: Double
    }

    private var cameraFrame: CameraFrame {
        CameraFrame(
            latitude: mapLatitude, longitude: mapLongitude, distance: mapDistance,
            heading: mapHeading, pitch: mapPitch,
            riderLatitude: riderLatitude, riderLongitude: riderLongitude
        )
    }

    private var map: some View {
        Map(position: cameraBinding, interactionModes: .all) {
            // Under the rider marker, so the arrow is never hidden by the line it is following.
            if routeShape.count > 1 {
                MapPolyline(coordinates: routeShape)
                    .stroke(.blue.opacity(0.7), style: StrokeStyle(
                        lineWidth: 7, lineCap: .round, lineJoin: .round
                    ))
            }

            Annotation("", coordinate: .init(latitude: riderLatitude, longitude: riderLongitude)) {
                Image(systemName: "location.north.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    // Screen-aligned annotations do not turn with the camera; pointing the arrow
                    // along the course therefore means subtracting the camera's own heading.
                    .rotationEffect(.degrees(riderCourseDegrees - mapHeading))
            }
        }
        .mapControlVisibility(.hidden)
        // Fixes arrive once a second, live and on the tape alike, and a camera that teleports
        // between them is a slideshow. A linear glide of one fix interval turns the jumps into
        // motion — linear rather than eased, because the bike between two fixes genuinely moves
        // at constant speed and easing would make it surge. Suspended while the rider holds the
        // map: an animation must never fight a finger.
        .animation(browsedCamera == nil ? .linear(duration: 0.95) : nil, value: cameraFrame)
        .ignoresSafeArea()
    }

    /// Back to the followed camera, now.
    ///
    /// The automatic return only fires above 5 mph, which is right — a rider stopped and studying
    /// the next few junctions should be left alone. But that leaves someone stationary with a map
    /// panned to the next county and no way home, which is exactly the state this button exists
    /// for. It appears only while the store says the map is being held.
    @ViewBuilder
    private var recentreButton: some View {
        if browsedCamera != nil {
            Button {
                onRecentre()
            } label: {
                Image(systemName: isNavigating ? "location.north.line.fill" : "location.fill")
                    .font(.title3)
                    .padding(12)
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .padding(.bottom, 22)
            .transition(.opacity)
        }
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
            SpeedSignUnknown(size: 56)
        case .known(let text, let value):
            SpeedSignKnown(text: text, value: value, size: 56)
        case .national(let text, let value):
            HStack(spacing: 6) {
                SpeedSignNational(size: 50)
                SpeedSignKnown(text: text, value: value, size: 50)
            }
        case .nationalOnly:
            SpeedSignNational(size: 56)
        case let .assumed(text, value):
            // No NSL sign — that sign means 60 or 70, and this is the built-up default. Labelled
            // instead, so the figure is never mistaken for one read off a real sign.
            VStack(spacing: 2) {
                SpeedSignKnown(text: text, value: value, size: 50)
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
                    SpeedSignKnown(text: text, value: value, size: 50)
                } else {
                    SpeedSignNational(size: 50)
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
                .font(.system(size: 32, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: speedValue))
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: speedValue)
            Text("mph")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
