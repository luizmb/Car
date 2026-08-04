import AppDomain
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

    var body: some View {
        Form {
            Section("This fill") {
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

                Button(role: .destructive) {
                    viewStore.dispatch(.engageReserve)
                } label: {
                    Text("Switched to reserve").frame(maxWidth: .infinity)
                }
            } footer: {
                Text("Reserve is a sharper calibration point than a brim fill — it pins consumption to the main tank's exact capacity. It is also the event this whole feature exists to prevent.")
            }

            if let error = viewStore.state.saveError {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }

            history
        }
        .navigationTitle("Fuel")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewStore.dispatch(.appeared) }
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
    private var history: some View {
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

extension FuelFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        FuelView(viewStore: ViewStore(store))
    }
}
