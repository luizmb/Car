import AppDomain
import Charts
import QuartzCore
import SwiftRex
import SwiftRexArchitecture
import SwiftRexSwiftUI
import SwiftUI

/// The refuel form.
///
/// Designed for gloves-off, one-handed use at a pump in the rain: decimal keypads, large targets,
/// and only two fields that block saving. Everything else is optional or pre-filled, because a form
/// that refuses to save is a form that loses the record entirely.
struct FuelView: View {
    let viewStore: ViewStore<FuelFeature.State, FuelFeature.Action>
    /// The viewfinder, handed down from the World through the factory — the only view-layer
    /// plumbing the scanner needs.
    let cameraPreview: @MainActor @Sendable () -> CALayer?

    var body: some View {
        Form {
            Picker("", selection: viewStore.binding(.state(\.tab), dispatch: .action(\.setTab))) {
                ForEach(FuelTab.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            // Each tab carries its own history. Switching to reserve is not a refuel and shares
            // nothing with one but the log it lands in, so showing both lists under both tabs made
            // the screen twice as long as either job needed and buried the one you came for.
            switch viewStore.state.tab {
            case .refuel:
                refuelTab
                refuelHistory
            case .reserve:
                reserveTab
                reserveHistory
            case .stats:
                statsTab
            }
        }
        .navigationTitle("Fuel")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewStore.dispatch(.appeared) }
        .fullScreenCover(isPresented: Binding(
            get: { viewStore.state.scan != nil },
            set: { if !$0 { viewStore.dispatch(.cancelScan) } }
        )) {
            ScanSheet(viewStore: viewStore, cameraPreview: cameraPreview)
        }
    }

    // MARK: - Refuel

    @ViewBuilder
    private var refuelTab: some View {
        Group {
            Section("This fill") {
                Button {
                    viewStore.dispatch(.beginScan)
                } label: {
                    Label("Scan pump and odometer", systemImage: "camera.viewfinder")
                }

                field("Litres", text: viewStore.binding(.state(\.litres), dispatch: .action(\.setLitres)))
                field("£ / litre", text: viewStore.binding(.state(\.pricePerLitre), dispatch: .action(\.setPrice)))

                if let total = viewStore.state.totalCost {
                    LabeledContent("Total", value: String(format: "£%.2f", total))
                        .font(.body.monospacedDigit())
                }

                Picker("Grade", selection: viewStore.binding(.state(\.grade), dispatch: .action(\.setGrade))) {
                    ForEach(FuelGrade.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                // Default on. Brim-to-brim is the only pair of fills that measures anything, so
                // the common case must be the effortless one.
                Toggle("Filled to the brim", isOn: viewStore.binding(
                    .state(\.filledToBrim), dispatch: .action(\.setFilledToBrim)
                ))
            }

            Section {
                field("Bike odometer (km)", text: viewStore.binding(.state(\.odometer), dispatch: .action(\.setOdometer)))
            } header: {
                Text("Odometer")
            } footer: {
                Text("Recorded for comparison only — never used in any calculation. The display shows whole kilometres, so a single fill carries ±1 km; only across many fills does a real bias separate from that noise.")
            }

            Section {
                Button {
                    viewStore.dispatch(.save)
                } label: {
                    Text("Save fill").frame(maxWidth: .infinity)
                }
                .disabled(!viewStore.state.isValid)
            }

            errorSection
        }
    }

    // MARK: - Reserve

    /// Its own tab, not a button on the refuel form. Switching to reserve is a different event
    /// entirely — it records that the main tank ran dry, which is the thing this feature exists to
    /// prevent, and it shares no fields with a fill.
    @ViewBuilder
    private var reserveTab: some View {
        Group {
            Section {
                field("Bike odometer (km)", text: viewStore.binding(
                    .state(\.reserveOdometer), dispatch: .action(\.setReserveOdometer)
                ))
                LabeledContent("Date", value: "recorded automatically")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Position", value: viewStore.state.latitude == nil ? "waiting for GPS" : "captured")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Switched to reserve")
            } footer: {
                Text("A sharper calibration point than a brim fill: it pins consumption to the main tank's exact capacity, with no dependence on how carefully the last fill was topped off. Distance is recorded from both GPS and the bike's odometer — GPS is what the maths uses, the odometer is what is being calibrated.")
            }

            Section {
                Button(role: .destructive) {
                    viewStore.dispatch(.engageReserve)
                } label: {
                    Text("Record reserve switch").frame(maxWidth: .infinity)
                }
            }

            errorSection
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewStore.state.saveError {
            Section { Text(error).foregroundStyle(.red).font(.caption) }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
        }
    }

    @ViewBuilder
    private var refuelHistory: some View {
        let log = viewStore.state.log
        if !log.refuels.isEmpty {
            Section("Previous fills") {
                ForEach(log.refuelsNewestFirst.prefix(10)) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(String(format: "%.2f L", record.litres.rawValue)).bold()
                            Text(record.grade.label)
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                            Spacer()
                            Text(String(format: "£%.2f", record.totalCost))
                        }
                        .font(.subheadline.monospacedDigit())
                        HStack(spacing: 6) {
                            Text(record.date, format: .dateTime.day().month().hour().minute())
                            if !record.filledToBrim { Text("partial").foregroundStyle(.orange) }
                            if let odometer = record.odometer {
                                Text(String(format: "%.0f km", odometer.rawValue))
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }

    }

    @ViewBuilder
    private var reserveHistory: some View {
        let log = viewStore.state.log
        if !log.reserves.isEmpty {
            Section("Reserve switches") {
                ForEach(log.reserves.sorted { $0.date > $1.date }) { event in
                    HStack {
                        Text(event.date, format: .dateTime.day().month().hour().minute())
                        Spacer()
                        if let odometer = event.odometer {
                            Text(String(format: "%.0f km", odometer.rawValue))
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }

        // Only appears once there are two brim fills with odometer readings — one fill measures
        // nothing, and showing a figure derived from a single point would be a lie.
        let samples = log.consumptionSamples
        if !samples.isEmpty {
            Section("Measured consumption") {
                ForEach(Array(samples.enumerated().reversed()), id: \.offset) { _, sample in
                    let kmPerLitre = sample.kilometres / sample.litres
                    LabeledContent(
                        String(format: "%.0f km on %.2f L", sample.kilometres, sample.litres),
                        value: String(format: "%.1f km/L  ·  %.1f mpg", kmPerLitre, kmPerLitre * 2.8248)
                    )
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }
}

// MARK: - Consumption history

private extension FuelView {
    /// Consumption leg by leg — the reason the other two tabs collect what they collect.
    ///
    /// A leg closes where consumption becomes computable: a brim fill or a reserve switch. The
    /// average drawn through them is total distance over total litres, weighted by distance, so a
    /// short town hop cannot drag the baseline the way a mean-of-ratios would let it.
    @ViewBuilder
    var statsTab: some View {
        let legs = viewStore.state.log.consumptionLegs(spec: .vt400)
        let average = averageKilometresPerLitre(legs)

        Section {
            Picker("", selection: viewStore.binding(
                .state(\.consumptionDisplay), dispatch: .action(\.setConsumptionDisplay)
            )) {
                ForEach(ConsumptionDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
        }

        if legs.isEmpty {
            Section {
                Label(
                    "Consumption needs two brim fills, or a reserve switch. Keep filling to the brim.",
                    systemImage: "fuelpump"
                )
                .foregroundStyle(.secondary)
                .font(.callout)
            }
        } else {
            switch viewStore.state.consumptionDisplay {
            case .chart: consumptionChart(legs, average: average)
            case .table: consumptionTable(legs, average: average)
            }
        }
    }

    @ViewBuilder
    func consumptionChart(_ legs: [ConsumptionLeg], average: Double?) -> some View {
        Section("mpg per leg") {
            Chart {
                ForEach(legs) { leg in
                    LineMark(
                        x: .value("Date", leg.date),
                        y: .value("mpg", leg.milesPerGallon)
                    )
                    .interpolationMethod(.monotone)
                    PointMark(
                        x: .value("Date", leg.date),
                        y: .value("mpg", leg.milesPerGallon)
                    )
                    // A reserve-ended leg is the better calibration point — pinned to the tank's
                    // actual bottom rather than a brim judged by eye — and worth distinguishing.
                    .foregroundStyle(leg.endedBy == .reserve ? Color.orange : Color.blue)
                }
                if let average {
                    let mpg = average * 4.546_09 / 1.609_344
                    RuleMark(y: .value("Average", mpg))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("avg \(String(format: "%.0f", mpg)) mpg")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(height: 200)
        }
    }

    @ViewBuilder
    func consumptionTable(_ legs: [ConsumptionLeg], average: Double?) -> some View {
        Section {
            // Newest first: the leg you just closed is the one you came to check.
            ForEach(legs.reversed()) { leg in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leg.date.formatted(date: .abbreviated, time: .omitted))
                        Text(
                            "\(String(format: "%.0f", leg.kilometres)) km · "
                                + "\(String(format: "%.1f", leg.litres)) L · "
                                + (leg.endedBy == .reserve ? "to reserve" : "brim to brim")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(String(format: "%.0f", leg.milesPerGallon)) mpg")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(leg.endedBy == .reserve ? .orange : .primary)
                }
            }
        } header: {
            Text("Legs · \(legs.count)")
        } footer: {
            if let average {
                Text(String(
                    format: "Average %.0f mpg · %.1f km/L · %.1f L/100km — weighted by distance.",
                    average * 4.546_09 / 1.609_344, average, 100 / average
                ))
            }
        }
    }
}

extension FuelFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        FuelView(viewStore: ViewStore(store), cameraPreview: environment.cameraPreview)
    }
}

// MARK: - The scan sheet

/// The camera, full screen, with the hunt's progress over it.
///
/// Two phases in fill order: film the pump display until the tick (litres and price prove
/// themselves by arithmetic — the two numbers and their product must agree across several
/// consecutive frames), then swing to the odometer; when it holds steady too, the sheet closes
/// itself and the form is already filled. Cancelling at any point costs nothing.
private struct ScanSheet: View {
    let viewStore: ViewStore<FuelFeature.State, FuelFeature.Action>
    let cameraPreview: @MainActor @Sendable () -> CALayer?

    var body: some View {
        ZStack {
            CameraPreviewHost(provider: cameraPreview)
                .ignoresSafeArea()

            // The happy boxes: one around each value the arithmetic believed, exactly where it
            // sits on the glass — the user's proof the scanner has the right display.
            GeometryReader { geometry in
                ForEach(Array((viewStore.state.scan?.highlights ?? []).enumerated()), id: \.offset) {
                    _, box in
                    let frame = screenRect(for: box, in: geometry.size)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.green, lineWidth: 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.15))
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                instruction
                    .padding(.top, 24)
                Spacer()
                Button(role: .cancel) {
                    viewStore.dispatch(.cancelScan)
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
            }
        }
        .background(.black)
    }

    @ViewBuilder
    private var instruction: some View {
        let scan = viewStore.state.scan
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                phaseBadge(
                    done: scan?.pump != nil,
                    active: scan?.phase == .pump,
                    label: "Pump"
                )
                phaseBadge(
                    done: false,
                    active: scan?.phase == .odometer,
                    label: "Odometer"
                )
            }

            Text(scan?.phase == .odometer
                 ? "Now film the odometer"
                 : "Film the pump display — litres and price")
                .font(.headline)
                .foregroundStyle(.white)

            if let pump = scan?.pump {
                Text(String(format: "%.2f L @ %.3f", pump.litres, pump.pricePerLitre)
                     + (scan?.grade.map { "  \($0)" } ?? ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
            }
            // The hunt's heartbeat: dots fill as consecutive frames agree, so holding steady
            // visibly *does something* even before the tick.
            let hits = scan?.phase == .odometer ? (scan?.odometerHits ?? 0) : (scan?.pumpHits ?? 0)
            HStack(spacing: 5) {
                ForEach(0..<scanStabilityFrames, id: \.self) { index in
                    Circle()
                        .fill(index < hits ? Color.green : Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Vision's normalized box (origin bottom-left, upright-image space) onto the screen, through
    /// the same aspect-fill the preview layer applies: scale to cover, centre, crop. The camera
    /// feed is 720×1280 upright; a highlight a few points adrift is invisible around a word, so
    /// the constant aspect is fine where a resolvable session handle would be plumbing for nothing.
    private func screenRect(for box: RecognizedText, in size: CGSize) -> CGRect {
        let image = CGSize(width: 720, height: 1_280)
        let scale = max(size.width / image.width, size.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let offsetX = (size.width - shown.width) / 2
        let offsetY = (size.height - shown.height) / 2
        let width = box.width * shown.width
        let height = box.height * shown.height
        return CGRect(
            x: offsetX + (box.x - box.width / 2) * shown.width,
            y: offsetY + (1 - box.y - box.height / 2) * shown.height,
            width: max(width, 24),
            height: max(height, 16)
        )
    }

    private func phaseBadge(done: Bool, active: Bool, label: String) -> some View {
        Label(label, systemImage: done ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(done ? .green : active ? .white : .gray)
    }
}

// MARK: - The viewfinder host

/// Hosts the World's preview layer inside SwiftUI.
///
/// The session starts asynchronously after the permission dialog, so the layer may not exist on
/// first render; every update retries the attach, and updates arrive with every analysed frame's
/// action, which makes the retry loop free.
private struct CameraPreviewHost: UIViewRepresentable {
    let provider: @MainActor @Sendable () -> CALayer?

    func makeUIView(context _: Context) -> PreviewHostView {
        PreviewHostView(provider: provider)
    }

    func updateUIView(_ view: PreviewHostView, context _: Context) {
        view.attachIfNeeded()
    }
}

final class PreviewHostView: UIView {
    private let provider: @MainActor @Sendable () -> CALayer?
    private var attached: CALayer?

    init(provider: @escaping @MainActor @Sendable () -> CALayer?) {
        self.provider = provider
        super.init(frame: .zero)
    }

    required init?(coder _: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachIfNeeded()
        attached?.frame = bounds
    }

    func attachIfNeeded() {
        guard attached == nil, let preview = provider() else { return }
        layer.addSublayer(preview)
        preview.frame = bounds
        attached = preview
    }
}
