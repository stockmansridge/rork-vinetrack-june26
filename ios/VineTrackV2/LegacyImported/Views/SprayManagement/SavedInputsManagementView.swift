import SwiftUI

/// Owner/manager-only management UI for the shared Saved Inputs library
/// (seed, fertiliser, compost, biological, soil amendment, other).
///
/// Cost-per-unit fields are gated by `accessControl.canViewFinancials` so
/// supervisors/operators never see pricing data, in line with the costing
/// access rules.
struct SavedInputsManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SavedInputSyncService.self) private var savedInputSync
    @Environment(\.accessControl) private var accessControl
    @State private var showAddSheet: Bool = false
    @State private var editingInput: SavedInput?
    @State private var searchText: String = ""

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    private var inputs: [SavedInput] {
        guard let vid = store.selectedVineyardId else { return [] }
        let all = store.savedInputs.filter { $0.vineyardId == vid }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return all
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) ||
                      ($0.supplier ?? "").localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                if inputs.isEmpty {
                    Text(canManageSetup
                         ? "No saved inputs yet. Tap “Add Input” to create one."
                         : "No saved inputs yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(inputs) { input in
                        Group {
                            if canManageSetup {
                                Button { editingInput = input } label: { row(input) }
                            } else {
                                row(input, showChevron: false)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if canManageSetup {
                                Button(role: .destructive) {
                                    store.deleteSavedInput(input)
                                    Task { await savedInputSync.syncForSelectedVineyard() }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                if canManageSetup {
                    Button { showAddSheet = true } label: {
                        Label("Add Input", systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Inputs")
            } footer: {
                if canManageSetup {
                    Text("Reusable inputs (seed, fertiliser, compost, biological, soil amendment, other) used across seeding and spreading trips. Cost per unit is used to estimate trip input cost.")
                } else if !canViewFinancials {
                    Text("Setup data is managed by vineyard owners and managers. Pricing is visible to owners and managers only.")
                } else {
                    Text("Setup data is managed by vineyard owners and managers.")
                }
            }
        }
        .navigationTitle("Saved Inputs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search inputs")
        .refreshable { await savedInputSync.syncForSelectedVineyard() }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            Task { await savedInputSync.syncForSelectedVineyard() }
        }) {
            SavedInputFormSheet(input: nil)
        }
        .sheet(item: $editingInput, onDismiss: {
            Task { await savedInputSync.syncForSelectedVineyard() }
        }) { input in
            SavedInputFormSheet(input: input)
        }
    }

    @ViewBuilder
    private func row(_ input: SavedInput, showChevron: Bool = true) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(input.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Text(input.inputType.displayName)
                    Text("·")
                    Text("Unit: \(input.unit.displayName)")
                    if canViewFinancials, let cpu = input.costPerUnit, cpu > 0 {
                        Text("·")
                        Text(String(format: "$%.2f / %@", cpu, input.unit.displayName))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct SavedInputFormSheet: View {
    let input: SavedInput?
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var inputType: SavedInputType = .other
    @State private var unit: SavedInputUnit = .kg
    @State private var costString: String = ""
    @State private var supplier: String = ""
    @State private var notes: String = ""

    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }
    private var isEditing: Bool { input != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Input name", text: $name)
                    Picker("Type", selection: $inputType) {
                        ForEach(SavedInputType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    Picker("Unit", selection: $unit) {
                        ForEach(SavedInputUnit.allCases, id: \.self) { u in
                            Text(u.displayName).tag(u)
                        }
                    }
                }
                if canViewFinancials {
                    Section {
                        HStack {
                            Text("$").foregroundStyle(.secondary)
                            TextField("Cost per \(unit.displayName)", text: $costString)
                                .keyboardType(.decimalPad)
                            Text("/ \(unit.displayName)").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Cost (owner/manager only)")
                    } footer: {
                        Text("Leave blank if not yet known — trip input cost will show as unavailable rather than $0.")
                    }
                }
                Section("Supplier & Notes") {
                    TextField("Supplier (optional)", text: $supplier)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(isEditing ? "Edit Input" : "Add Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let input else { return }
                name = input.name
                inputType = input.inputType
                unit = input.unit
                if let cpu = input.costPerUnit, cpu > 0 {
                    costString = String(format: "%.2f", cpu)
                }
                supplier = input.supplier ?? ""
                notes = input.notes ?? ""
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let cpu: Double? = {
            // Only owner/manager can edit cost; preserve existing value otherwise.
            if canViewFinancials {
                let trimmed = costString.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return Double(trimmed)
            }
            return input?.costPerUnit
        }()
        let supplierValue: String? = {
            let trimmed = supplier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let notesValue: String? = {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        if var existing = input {
            existing.name = trimmedName
            existing.inputType = inputType
            existing.unit = unit
            existing.costPerUnit = cpu
            existing.supplier = supplierValue
            existing.notes = notesValue
            store.updateSavedInput(existing)
        } else {
            let new = SavedInput(
                vineyardId: store.selectedVineyardId ?? UUID(),
                name: trimmedName,
                inputType: inputType,
                unit: unit,
                costPerUnit: cpu,
                supplier: supplierValue,
                notes: notesValue
            )
            store.addSavedInput(new)
        }
        dismiss()
    }
}
