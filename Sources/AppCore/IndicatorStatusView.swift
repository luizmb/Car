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
        VStack(alignment: .leading, spacing: 3) {
            row("Indimate:", status.label, status.colour)

            // Read as hex the captured samples give 12.34-12.55 V with no scale factor, which is
            // what a resting battery looks like — but every sample so far is digits-only, so the
            // encoding is unproven. The trailing "?" says so, and disappears (green) the moment a
            // hex-only digit settles it. See BatteryReading.
            row("Battery:", batteryLabel, batteryColour)

            // Only while actually indicating — the row is absent, not dimmed, so the pill shrinks
            // back to two lines when you are going straight.
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
        .animation(.easeInOut(duration: 0.2), value: viewStore.state.side == nil)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fixedSize()
    }

    private func row(_ label: String, _ value: String, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(colour)
        }
    }

    /// `Unknown` until the unit reports, then `12.43V?` — the question mark dropping once a hex
    /// digit proves the encoding. Falls back to the raw payload if it parses as neither, so an
    /// unexpected format is visible rather than swallowed.
    private var batteryLabel: String {
        guard let battery = viewStore.state.battery else { return "Unknown" }
        guard let millivolts = battery.hexMillivolts else { return battery.raw }
        let volts = String(format: "%.2f", Double(millivolts) / 1000)
        return "\(volts)V\(battery.provesHex ? "" : "?")"
    }

    private var batteryColour: Color {
        guard let battery = viewStore.state.battery else { return .secondary }
        return battery.provesHex ? .green : .primary
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
