import AppDomain
import MapKit
import SwiftRex
import SwiftRexSwiftUI
import SwiftUI

// MARK: - Root

/// Three vertical pages: glance, context, errand. Fully store-driven — the page selection, every
/// form field and every number on screen comes from state, so the views hold nothing at all.
public struct WatchRootView: View {
    let viewStore: ViewStore<WatchFeature.State, WatchFeature.Action>

    public var body: some View {
        TabView(selection: viewStore.binding(
            .state(\.tab), dispatch: .action(\.tabChanged)
        )) {
            InstrumentsView(viewStore: viewStore)
                .tag(WatchFeature.Tab.instruments)
            SensorsView(viewStore: viewStore)
                .tag(WatchFeature.Tab.sensors)
            RefuelView(viewStore: viewStore)
                .tag(WatchFeature.Tab.refuel)
            WatchMapView(viewStore: viewStore)
                .tag(WatchFeature.Tab.map)
        }
        .pagedVertically()
        .onAppear { viewStore.dispatch(.appeared) }
    }
}

private extension View {
    /// The watch pages vertically — the crown scrolls between screens. Everywhere else (the iOS
    /// test build of this target) the plain style compiles instead.
    @ViewBuilder
    func pagedVertically() -> some View {
        #if os(watchOS)
        tabViewStyle(.verticalPage)
        #else
        self
        #endif
    }
}

// MARK: - Instruments

/// The glance: speed huge, limit beside it, indicator arrows, road underneath.
///
/// Over the limit the speed itself turns red — on a wrist there is no room for a second element
/// to carry the warning, and the number is where the eye already is.
struct InstrumentsView: View {
    let viewStore: ViewStore<WatchFeature.State, WatchFeature.Action>

    var body: some View {
        let snapshot = viewStore.state.snapshot
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                indicatorArrow("arrow.turn.up.left", lit: snapshot?.indicator == "left")
                VStack(spacing: -4) {
                    // The em dash placeholder at black weight renders as featureless pills;
                    // lighter and smaller, it reads as the "no reading" it means.
                    Text(snapshot?.mph.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(
                            size: snapshot?.mph == nil ? 40 : 54,
                            weight: snapshot?.mph == nil ? .medium : .black,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .foregroundStyle(
                            snapshot?.overLimit == true ? .red
                                : snapshot?.mph == nil ? .secondary : .primary
                        )
                    Text("mph")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                indicatorArrow("arrow.turn.up.right", lit: snapshot?.indicator == "right")
            }

            HStack(spacing: 6) {
                limitSign(snapshot)
                if let road = snapshot?.roadLabel {
                    Text(road)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                if let turn = snapshot?.nextTurnMetres {
                    Label("\(Int(turn)) m", systemImage: "arrow.triangle.turn.up.right.diamond")
                        .font(.system(size: 11))
                }
                if let sinceFill = snapshot?.sinceFillKm {
                    Label(String(format: "%.0f km", sinceFill), systemImage: "fuelpump")
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Circle()
                    .fill(viewStore.state.phoneReachable ? .green : .orange)
                    .frame(width: 6, height: 6)
                Text(statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        guard viewStore.state.snapshot != nil else { return "waiting for the phone" }
        guard viewStore.state.phoneReachable else { return "last known" }
        return viewStore.state.snapshot?.journeyActive == true ? "riding" : "parked"
    }

    private func indicatorArrow(_ symbol: String, lit: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(lit ? .green : Color.secondary.opacity(0.25))
    }

    @ViewBuilder
    private func limitSign(_ snapshot: WatchSnapshot?) -> some View {
        if let text = snapshot?.limitText {
            ZStack {
                Circle().fill(.white)
                Circle().stroke(snapshot?.limitIsAssumed == true ? Color.gray : .red, lineWidth: 3)
                Text(text)
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
            }
            .frame(width: 34, height: 34)
        } else if snapshot?.limitIsNational == true {
            ZStack {
                Circle().fill(.white)
                Rectangle().fill(.black)
                    .frame(width: 3, height: 24)
                    .rotationEffect(.degrees(-45))
                    .clipShape(Circle().inset(by: 1))
            }
            .frame(width: 34, height: 34)
        }
    }
}

// MARK: - Map

/// The context: where the bike is, which way it faces, and the chosen route's line — the phone's
/// camera framing, re-rendered on the wrist. No interaction: the map on a watch is a picture.
struct WatchMapView: View {
    let viewStore: ViewStore<WatchFeature.State, WatchFeature.Action>

    var body: some View {
        let snapshot = viewStore.state.snapshot
        if let lat = snapshot?.latitude, let lon = snapshot?.longitude {
            Map(position: .constant(.camera(MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                distance: 800,
                heading: snapshot?.headingDegrees ?? 0
            )))) {
                let route = routeCoordinates(snapshot)
                if route.count > 1 {
                    MapPolyline(coordinates: route)
                        .stroke(.blue.opacity(0.8), style: StrokeStyle(
                            lineWidth: 4, lineCap: .round, lineJoin: .round
                        ))
                }
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
            }
            .ignoresSafeArea()
        } else {
            VStack(spacing: 6) {
                Image(systemName: "location.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No fix from the phone yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func routeCoordinates(_ snapshot: WatchSnapshot?) -> [CLLocationCoordinate2D] {
        guard let snapshot else { return [] }
        return Swift.zip(snapshot.routeLatitudes, snapshot.routeLongitudes)
            .map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
    }
}

// MARK: - Sensors

/// The bike's vitals, one glance: weather, both tyres, altitude, and which of the garage's
/// devices are actually talking. Everything here is the phone's snapshot — the wrist measures
/// nothing — and a missing figure shows as a dash, never a zero.
struct SensorsView: View {
    let viewStore: ViewStore<WatchFeature.State, WatchFeature.Action>

    private var snapshot: WatchSnapshot? { viewStore.state.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                reading(
                    "cloud.sun.fill",
                    snapshot?.weatherCelsius.map { celsius in
                        let humidity = snapshot?.weatherHumidity.map { " · \(Int($0))%" } ?? ""
                        return String(format: "%.0f°C", celsius) + humidity
                    } ?? "—"
                )
                tyre("F", psi: snapshot?.frontTyrePSI, celsius: snapshot?.frontTyreCelsius,
                     warn: snapshot?.frontTyreWarn == true)
                tyre("R", psi: snapshot?.rearTyrePSI, celsius: snapshot?.rearTyreCelsius,
                     warn: snapshot?.rearTyreWarn == true)
                reading(
                    "mountain.2.fill",
                    snapshot?.altitudeMetres.map { String(format: "%.0f m", $0) } ?? "—"
                )
                device("Ignition", state: snapshot?.ignitionOn)
                device("Indimate", state: snapshot?.indimateConnected)
                device("Cardo", state: snapshot?.cardoConnected)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reading(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private func tyre(_ wheel: String, psi: Double?, celsius: Double?, warn: Bool) -> some View {
        HStack(spacing: 6) {
            Text(wheel)
                .font(.footnote.weight(.black))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(psi.map { String(format: "%.1f psi", $0) } ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(warn ? .orange : .primary)
            if let celsius {
                Text(String(format: "%.0f°", celsius))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func device(_ name: String, state: Bool?) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state == true ? Color.green : state == false ? Color.gray : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
                .frame(width: 22)
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(state == true ? .primary : .secondary)
        }
    }
}

// MARK: - Refuel

/// The errand: log a fill without taking a glove off for the phone.
///
/// Digit windows, not text: tap a window and the crown turns it; tap it again — or leave the
/// tab — and the crown goes back to paging. Every window spans at most 0–99, because two
/// balanced spins beat one long one: price is pump-style ("18.49" is £1.849, three pound
/// decimals from two windows) and the odometer is three windows seeded from the phone's own
/// estimate, so the crown only ever nudges the tail. The watch sends the ask; the phone builds
/// the real record with its clock, its GPS, its trip counter and its forecourt lookup.
struct RefuelView: View {
    let viewStore: ViewStore<WatchFeature.State, WatchFeature.Action>
    // Focus is hardware routing, not app state: the store owns *which* window is being edited
    // (`refuelFocus`); this only tells watchOS the crown belongs to this view while any window
    // is selected. SwiftUI offers no other handle on crown ownership.
    @FocusState private var crownCaptured: Bool

    private var draft: WatchFeature.RefuelDraft { viewStore.state.refuel }
    private var focus: WatchFeature.RefuelSegment? { viewStore.state.refuelFocus }

    var body: some View {
        #if os(watchOS)
        picker
            .focusable(true)
            .focused($crownCaptured)
            .digitalCrownRotation(
                crown,
                from: crownRange.lowerBound, through: crownRange.upperBound, by: 1,
                sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true
            )
            .onChange(of: crownCaptured) { _, captured in
                if !captured { viewStore.dispatch(.refuelFocused(nil)) }
            }
        #else
        picker
        #endif
    }

    private var picker: some View {
        ScrollView {
            VStack(spacing: 5) {
                row(unit: "L") {
                    window(String(draft.litresInt), .litresInt)
                    dot
                    window(String(format: "%02d", draft.litresDec), .litresDec)
                }
                row(unit: "") {
                    window(String(draft.priceInt), .priceInt)
                    dot
                    window(String(format: "%02d", draft.priceDec), .priceDec)
                }
                caption(String(format: "£%.3f per litre", draft.pricePerLitre))
                row(unit: "km") {
                    window(String(draft.odoKm), .odo)
                }
                caption(draft.odometerKm != nil ? "odometer" : "odometer not read")

                HStack(spacing: 6) {
                    gradeButton("E5")
                    gradeButton("E10")
                }

                Toggle("To the brim", isOn: Binding(
                    get: { viewStore.state.refuel.filledToBrim },
                    set: { brim in
                        var next = viewStore.state.refuel
                        next.filledToBrim = brim
                        viewStore.dispatch(.refuelEdited(next))
                    }
                ))
                .font(.footnote)

                Button {
                    viewStore.dispatch(.submitRefuel)
                } label: {
                    if viewStore.state.refuelSending {
                        ProgressView()
                    } else {
                        Label("Record fill", systemImage: "fuelpump.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewStore.state.refuelSending)

                if let delivered = viewStore.state.refuelDelivered {
                    Label(
                        delivered ? "Sent to the phone" : "Could not send",
                        systemImage: delivered ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(delivered ? .green : .orange)
                }
            }
        }
    }

    // MARK: The windows

    private func window(_ text: String, _ segment: WatchFeature.RefuelSegment) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(focus == segment ? Color.green.opacity(0.25) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(focus == segment ? Color.green : Color.clear, lineWidth: 1.5)
            )
            .onTapGesture {
                if focus == segment {
                    viewStore.dispatch(.refuelFocused(nil))
                    crownCaptured = false
                } else {
                    viewStore.dispatch(.refuelFocused(segment))
                    crownCaptured = true
                }
            }
    }

    private func row(unit: String, @ViewBuilder windows: () -> some View) -> some View {
        HStack(spacing: 3) {
            windows()
            if !unit.isEmpty {
                Text(unit).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var dot: some View {
        Text(".").font(.system(size: 17, weight: .bold, design: .rounded))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    // MARK: The crown

    private var crownRange: ClosedRange<Double> {
        switch focus {
        case .litresInt: 0...15
        case .priceInt: 5...30
        case .odo: 0...999_999
        default: 0...99
        }
    }

    private var crown: Binding<Double> {
        Binding(
            get: {
                let draft = viewStore.state.refuel
                let value: Int = switch viewStore.state.refuelFocus {
                case .litresInt: draft.litresInt
                case .litresDec: draft.litresDec
                case .priceInt: draft.priceInt
                case .priceDec: draft.priceDec
                case .odo: draft.odoKm
                case nil: 0
                }
                return Double(value)
            },
            set: { raw in
                guard let segment = viewStore.state.refuelFocus else { return }
                var next = viewStore.state.refuel
                let value = Int(raw.rounded())
                switch segment {
                case .litresInt: next.litresInt = max(0, min(15, value))
                case .litresDec: next.litresDec = max(0, min(99, value))
                case .priceInt: next.priceInt = max(5, min(30, value))
                case .priceDec: next.priceDec = max(0, min(99, value))
                case .odo:
                    next.odoKm = max(0, min(999_999, value))
                    // A touched odometer is the rider's reading; the phone's estimate stands down.
                    next.odoSeeded = true
                }
                if next != viewStore.state.refuel { viewStore.dispatch(.refuelEdited(next)) }
            }
        )
    }

    private func gradeButton(_ grade: String) -> some View {
        Button(grade) {
            var next = viewStore.state.refuel
            next.grade = grade
            viewStore.dispatch(.refuelEdited(next))
        }
        .buttonStyle(.bordered)
        .tint(viewStore.state.refuel.grade == grade ? .green : .gray)
        .font(.footnote)
    }
}

// MARK: - Factory

extension WatchFeature {
    /// The entry point's one call, mirroring the phone's `AppFeature.view(store:environment:)`.
    @MainActor
    public static func view(
        store: any StoreType<Action, State>
    ) -> some View {
        WatchRootView(viewStore: ViewStore(store))
    }
}
