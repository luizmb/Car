import AppDomain
import SwiftRex
import SwiftRexArchitecture
import SwiftRexSwiftUI
import SwiftUI

// MARK: - View

/// A one-line status strip: whether the Indimate unit is talking to us, and which way you are
/// indicating.
///
/// Deliberately its own feature view rather than fields bolted onto the speed screen — the two are
/// siblings in app state, and the router composes them. When CHIGEE gets the same treatment it
/// slots in beside this one without either knowing about the other.
struct IndicatorStatusView: View {
    let viewStore: ViewStore<IndicatorFeature.State, IndicatorFeature.Action>

    /// Matches the audio loop's 0.698s cycle, so the strip and the ticking feel like one thing —
    /// even though neither is synced to the bike's actual relay.
    @State private var blinking = false

    var body: some View {
        HStack(spacing: 8) {
            Text("Indimate:")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(status.label)
                .font(.caption2.bold())
                .foregroundStyle(status.colour)

            // Raw payload plus the hex reading, because the encoding is not settled. Read as hex
            // the samples so far give 12.34-12.55 V with no scale factor, which is what a resting
            // battery looks like. A letter appearing here proves hex outright — see BatteryReading.
            if let battery = viewStore.state.battery {
                Text(batteryLabel(battery))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(battery.provesHex ? .green : .secondary)
            }

            Spacer(minLength: 8)

            if let side = viewStore.state.side {
                Text(side.arrowLabel)
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.green)
                    .opacity(blinking ? 1 : 0.15)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.349).repeatForever(autoreverses: true)) {
                            blinking = true
                        }
                    }
                    .onDisappear { blinking = false }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// `3091 12.43V?` — the raw payload and what it means read as hex. The question mark stays
    /// until a hex letter appears and settles it.
    private func batteryLabel(_ battery: BatteryReading) -> String {
        guard let millivolts = battery.hexMillivolts else { return battery.raw }
        let volts = String(format: "%.2f", Double(millivolts) / 1000)
        return "\(battery.raw) \(volts)V\(battery.provesHex ? "" : "?")"
    }

    // Bluetooth problems outrank the connection state: "Disconnected" when the radio is off is
    // technically true and completely unhelpful.
    private var status: (label: String, colour: Color) {
        switch viewStore.state.bluetooth {
        case .unauthorized: ("Bluetooth denied", .orange)
        case .poweredOff:   ("Bluetooth off", .orange)
        case .unsupported:  ("Unavailable", .orange)
        case .unknown, .ready:
            viewStore.state.isConnected ? ("Connected", .green) : ("Disconnected", .red)
        }
    }
}

private extension Side {
    var arrowLabel: String {
        switch self {
        case .left:  "\u{00AB} Left"
        case .right: "Right \u{00BB}"
        }
    }
}

// MARK: - ViewFactory

// Promotes the feature from logic-only to a full `Feature`, so the same `AppScopes.indicator`
// declaration that folds its behavior can also build its view — one statement of the wiring, used
// twice, with no way for the two to drift apart.
extension IndicatorFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment: Environment
    ) -> some View {
        IndicatorStatusView(viewStore: ViewStore(store))
    }
}
