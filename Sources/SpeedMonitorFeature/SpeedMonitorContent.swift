import MapKit
import SwiftUI

public struct SpeedMonitorContent: View {
    // Map
    public let mapLatitude: Double
    public let mapLongitude: Double
    public let mapDistance: Double
    public let mapHeading: Double
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

    public var body: some View {
        ZStack(alignment: .top) {
            map

            VStack(alignment: .leading, spacing: 0) {
                roadNameStrip
                HStack {
                    Spacer()
                    limitSignArea
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                }
                Spacer()
                footerPanel
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Map

    private var map: some View {
        Map(
            position: .constant(.camera(MapCamera(
                centerCoordinate: .init(latitude: mapLatitude, longitude: mapLongitude),
                distance: mapDistance,
                heading: mapHeading,
                pitch: 45
            ))),
            interactionModes: []
        ) {
            UserAnnotation {
                Image(systemName: "location.north.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
        }
        .mapControlVisibility(.hidden)
    }

    // MARK: - Road name strip (top)

    @ViewBuilder
    private var roadNameStrip: some View {
        if let text = roadDisplayText {
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
        }
    }

    /// "A505 - High Street", "M25", "High Street", or nil. Never shows duplicates.
    private var roadDisplayText: String? {
        switch (roadRef, roadName) {
        case (nil, nil):                        return nil
        case (let r?, nil):                     return r
        case (nil, let n?):                     return n
        case (let r?, let n?) where r == n:     return r
        case (let r?, let n?):                  return "\(r) - \(n)"
        }
    }

    // MARK: - Speed limit sign(s) (top-right, below road name)

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
        }
    }

    // MARK: - Footer panel (bottom)

    private var footerPanel: some View {
        VStack(spacing: 0) {
            // Small info bar: direction · coordinates · altitude
            HStack(spacing: 8) {
                Text(directionText)
                Spacer()
                Text(coordinatesText)
                    .monospacedDigit()
                Spacer()
                Text(altitudeText)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider().opacity(0.3)

            // Speed dashboard
            speedDashboard
                .padding(.top, 12)
                .padding(.bottom, 28)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Speed dashboard (centered)

    private var speedDashboard: some View {
        VStack(spacing: 2) {
            Text(speedText)
                .font(.system(size: 90, weight: .black, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText(value: speedValue))
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: speedValue)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("mph")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            if !speedAccuracyText.isEmpty {
                Text(speedAccuracyText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
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
