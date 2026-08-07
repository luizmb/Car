import AppDomain
import SwiftRex
import SwiftRexArchitecture
import SwiftRexSwiftUI
import SwiftUI

/// The maintenance list, and the two forms it opens.
///
/// No view state: the drafts live in the store, every keystroke is an action, and the sheets are
/// the visibility of those drafts — the same shape the ride review takes with its selection.
struct MaintenanceView: View {
    let viewStore: ViewStore<MaintenanceFeature.State, MaintenanceFeature.Action>

    var body: some View {
        List {
            if viewStore.state.isLoading && viewStore.state.items.isEmpty {
                HStack {
                    ProgressView()
                    Text("Reading the maintenance log…").foregroundStyle(.secondary)
                }
            } else if viewStore.state.items.isEmpty {
                Label("Nothing scheduled yet.", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
            }

            if let odometer = viewStore.state.currentOdometer {
                Section {
                    LabeledContent("Odometer, reconstructed", value: "\(Int(odometer.rawValue)) km")
                } footer: {
                    Text("Last recorded fill plus what the app has measured since.")
                }
            }

            ForEach(viewStore.state.items) { item in
                row(item)
                    .swipeActions {
                        Button(role: .destructive) {
                            viewStore.dispatch(.delete(item.id))
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewStore.dispatch(.newDraft)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear { viewStore.dispatch(.appeared) }
        .sheet(isPresented: Binding(
            get: { viewStore.state.draft != nil },
            set: { if !$0 { viewStore.dispatch(.draftEdited(nil)) } }
        )) {
            if let draft = viewStore.state.draft {
                MaintenanceDraftSheet(viewStore: viewStore, snapshot: draft)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewStore.state.eventDraft != nil },
            set: { if !$0 { viewStore.dispatch(.eventEdited(nil)) } }
        )) {
            if let draft = viewStore.state.eventDraft {
                MaintenanceEventSheet(viewStore: viewStore, snapshot: draft)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: MaintenanceItem) -> some View {
        let status = viewStore.state.today.map {
            maintenanceStatus(item, today: $0, odometer: viewStore.state.currentOdometer)
        } ?? .ok
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(of: status))
                    .frame(width: 10, height: 10)
                Text(item.title)
                if item.recurrence != nil {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !item.closed {
                    Button("Done…") {
                        viewStore.dispatch(.beginEvent(item.id))
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
            Text(maintenanceSummary(
                item, today: viewStore.state.today, odometer: viewStore.state.currentOdometer
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            if let last = item.events.last {
                Text("last done: \(last.notes.isEmpty ? eventStamp(last) : last.notes)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func eventStamp(_ event: MaintenanceEvent) -> String {
        event.odometer.map { "at \(Int($0.rawValue)) km" } ?? "recorded"
    }

    private func color(of status: MaintenanceStatus) -> Color {
        switch status {
        case .ok: .green
        case .warning: .yellow
        case .due: .red
        }
    }
}

// MARK: - The creation form

private struct MaintenanceDraftSheet: View {
    let viewStore: ViewStore<MaintenanceFeature.State, MaintenanceFeature.Action>
    /// The value the sheet was opened with — the binding's fallback for the frame where the store
    /// clears the draft and the sheet is still animating away.
    let snapshot: MaintenanceFeature.Draft

    private var draft: Binding<MaintenanceFeature.Draft> {
        Binding(
            get: { viewStore.state.draft ?? snapshot },
            set: { viewStore.dispatch(.draftEdited($0)) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: draft.title)
                    Toggle("Repeats", isOn: draft.periodic)
                    Picker("Due by", selection: draft.axis) {
                        Text("Date").tag(MaintenanceAxis.date)
                        Text("Odometer").tag(MaintenanceAxis.odometer)
                        Text("First of both").tag(MaintenanceAxis.either)
                        Text("Last of both").tag(MaintenanceAxis.both)
                    }
                }

                if draft.wrappedValue.axis.involvesDate {
                    Section(draft.wrappedValue.periodic ? "Next date" : "Date") {
                        DatePicker(
                            "Due", selection: draft.dueDate, displayedComponents: .date
                        )
                        TextField("Warn how many days before", text: draft.warnDays)
                            .keyboardType(.numberPad)
                    }
                }

                if draft.wrappedValue.axis.involvesOdometer {
                    Section(draft.wrappedValue.periodic ? "Next odometer" : "Odometer") {
                        TextField("Due at km", text: draft.dueOdometer)
                            .keyboardType(.decimalPad)
                        TextField("Warn how many km before", text: draft.warnKilometres)
                            .keyboardType(.decimalPad)
                    }
                }

                if draft.wrappedValue.periodic {
                    Section {
                        if draft.wrappedValue.axis.involvesDate {
                            TextField("Every how many days", text: draft.recurDays)
                                .keyboardType(.numberPad)
                        }
                        if draft.wrappedValue.axis.involvesOdometer {
                            TextField("Every how many km", text: draft.recurKilometres)
                                .keyboardType(.decimalPad)
                        }
                    } header: {
                        Text("Repeats every")
                    } footer: {
                        Text("Counted from each completion, not from the missed deadline.")
                    }
                }
            }
            .navigationTitle(draft.wrappedValue.periodic ? "Periodic maintenance" : "One-off maintenance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewStore.dispatch(.draftEdited(nil)) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { viewStore.dispatch(.saveDraft) }
                }
            }
        }
    }
}

// MARK: - The completion form

private struct MaintenanceEventSheet: View {
    let viewStore: ViewStore<MaintenanceFeature.State, MaintenanceFeature.Action>
    let snapshot: MaintenanceFeature.EventDraft

    private var draft: Binding<MaintenanceFeature.EventDraft> {
        Binding(
            get: { viewStore.state.eventDraft ?? snapshot },
            set: { viewStore.dispatch(.eventEdited($0)) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("When", selection: draft.date)
                    TextField("Odometer, km", text: draft.odometer)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: draft.notes, axis: .vertical)
                } footer: {
                    if draft.wrappedValue.latitude != nil {
                        Text("The place is stamped from the last GPS fix.")
                    } else {
                        Text("No GPS fix to stamp — the event is saved without a place.")
                    }
                }
            }
            .navigationTitle("Work done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewStore.dispatch(.eventEdited(nil)) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { viewStore.dispatch(.saveEvent) }
                }
            }
        }
    }
}

extension MaintenanceFeature: ViewFactory {
    @MainActor
    public static func view(
        store: any StoreType<Action, State>,
        environment _: Environment
    ) -> some View {
        MaintenanceView(viewStore: ViewStore(store))
    }
}
