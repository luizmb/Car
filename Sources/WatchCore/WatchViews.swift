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
            WatchMapView(viewStore: viewStore)
                .tag(WatchFeature.Tab.map)
            RefuelView(viewStore: viewStore)
                .tag(WatchFeature.Tab.refuel)
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

// MARK: - Refuel

/// The errand: log a fill without taking a glove off for the phone.
///
/// Steps, not text: litres by quarter, price by pence. The watch sends the ask; the phone builds
/// the real record with its clock, its GPS, its trip counter and its forecourt lookup — the watch
/// only ever learns whether the ask was handed over.
struct RefuelView: View {
    let viewStore: ViewStore<WatchFeature.State, WatchFeature.Action>

    private var draft: Binding<WatchFeature.RefuelDraft> {
        Binding(
            get: { viewStore.state.refuel },
            set: { viewStore.dispatch(.refuelEdited($0)) }
        )
    }

    private func stepperRow(
        label: String, down: @escaping () -> Void, up: @escaping () -> Void
    ) -> some View {
        HStack {
            Button(action: down) { Image(systemName: "minus") }
                .buttonStyle(.bordered)
            Text(label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            Button(action: up) { Image(systemName: "plus") }
                .buttonStyle(.bordered)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                stepperRow(
                    label: String(format: "%.2f L", viewStore.state.refuel.litres),
                    down: { adjust(litres: -0.25) },
                    up: { adjust(litres: 0.25) }
                )
                stepperRow(
                    label: String(format: "£%.2f/L", viewStore.state.refuel.pricePerLitre),
                    down: { adjust(price: -0.01) },
                    up: { adjust(price: 0.01) }
                )

                HStack(spacing: 6) {
                    gradeButton("E5")
                    gradeButton("E10")
                }

                Toggle("To the brim", isOn: draft.filledToBrim)
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

    private func adjust(litres: Double = 0, price: Double = 0) {
        var next = viewStore.state.refuel
        next.litres = min(15, max(0.25, next.litres + litres))
        next.pricePerLitre = min(3, max(0.5, next.pricePerLitre + price))
        viewStore.dispatch(.refuelEdited(next))
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
