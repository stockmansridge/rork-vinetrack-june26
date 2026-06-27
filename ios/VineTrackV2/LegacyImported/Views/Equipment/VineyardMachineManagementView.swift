import SwiftUI

/// Manages `vineyard_machines` for the selected vineyard — letting owners and
/// managers add ATVs, side-by-sides, harvesters, utility vehicles and other
/// machines that can appear in the Fuel Log picker.
///
/// Tractor-backed machines (those with a `legacyTractorId`) are shown read-only
/// here and edited from the existing Tractors section, so the legacy Tractor
/// model and trip costing remain untouched (see `canEdit(_:)`).
struct VineyardMachineManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(VineyardMachineSyncService.self) private var machineSync
    @Environment(\.accessControl) private var accessControl

    @State private var showAddSheet: Bool = false
    @State private var editingMachine: VineyardMachine?

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    /// Tractor-backed machines stay read-only here — manage them in Tractors.
    private func isLegacyTractor(_ m: VineyardMachine) -> Bool { m.legacyTractorId != nil }
    private func canEdit(_ m: VineyardMachine) -> Bool { canManageSetup && !isLegacyTractor(m) }

    /// Active machines for the current vineyard, sorted by display name.
    ///
    /// Tractor-backed machines (those with a `legacyTractorId`) are hidden here —
    /// they are managed under the top-level Tractors section. The underlying
    /// `vineyard_machines` rows still exist so the Fuel Log / Trip pickers and
    /// legacy costing keep working.
    private var machines: [VineyardMachine] {
        store.machines().filter { $0.legacyTractorId == nil }
    }

    var body: some View {
        List {
            Section {
                ForEach(machines) { machine in
                    Group {
                        if canEdit(machine) {
                            Button { editingMachine = machine } label: { VineyardMachineRow(machine: machine) }
                        } else {
                            VineyardMachineRow(machine: machine)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if canEdit(machine) {
                            Button(role: .destructive) {
                                archive(machine)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Label("Vineyard Machines", systemImage: "gearshape.2.fill")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                    Spacer()
                    if canManageSetup {
                        Button {
                            showAddSheet = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.body)
                        }
                    }
                }
            } footer: {
                if canManageSetup {
                    Text("Add ATVs, side-by-sides, harvesters, utility vehicles and other powered vineyard machines. Machines with fuel tracking on appear in the Fuel Log.")
                } else {
                    Text("Vineyard machines are managed by vineyard owners and managers.")
                }
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle("Vineyard Machines")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if machines.isEmpty {
                ContentUnavailableView {
                    Label("No Vineyard Machines", systemImage: "gearshape.2")
                } description: {
                    Text(canManageSetup
                         ? "Add your ATVs, side-by-sides, harvesters and other machines to track their fuel use."
                         : "No vineyard machines have been added yet.")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            VineyardMachineFormSheet(machine: nil)
        }
        .sheet(item: $editingMachine) { item in
            VineyardMachineFormSheet(machine: item)
        }
    }

    private func archive(_ machine: VineyardMachine) {
        store.deleteVineyardMachine(machine)
        Task { await machineSync.syncForSelectedVineyard() }
    }
}

struct VineyardMachineRow: View {
    let machine: VineyardMachine

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(machine.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(machine.machineType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    statusBadge(
                        machine.fuelTrackingEnabled ? "Fuel tracking" : "Fuel off",
                        systemImage: machine.fuelTrackingEnabled ? "fuelpump.fill" : "fuelpump",
                        active: machine.fuelTrackingEnabled
                    )
                    statusBadge(
                        machine.availableForJobCosting ? "Job costing" : "No costing",
                        systemImage: "dollarsign.circle",
                        active: machine.availableForJobCosting
                    )
                    if machine.hasFuelUsageRate {
                        Text("\(String(format: "%.1f", machine.fuelUsageLPerHour)) L/hr")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if machine.legacyTractorId != nil {
                    Text("Managed in Tractors")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if machine.legacyTractorId == nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func statusBadge(_ text: String, systemImage: String, active: Bool) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(active ? VineyardTheme.olive : .secondary)
    }
}

struct VineyardMachineFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(VineyardMachineSyncService.self) private var machineSync

    let machine: VineyardMachine?

    @State private var name: String = ""
    @State private var machineType: VineyardMachineType = .atv
    @State private var fuelTrackingEnabled: Bool = true
    @State private var availableForJobCosting: Bool = true
    @State private var fuelUsage: String = ""
    @State private var notes: String = ""

    init(machine: VineyardMachine?) {
        self.machine = machine
        if let m = machine {
            _name = State(initialValue: m.name)
            _machineType = State(initialValue: m.machineType)
            _fuelTrackingEnabled = State(initialValue: m.fuelTrackingEnabled)
            _availableForJobCosting = State(initialValue: m.availableForJobCosting)
            _fuelUsage = State(initialValue: m.hasFuelUsageRate ? String(format: "%.1f", m.fuelUsageLPerHour) : "")
            _notes = State(initialValue: m.notes ?? "")
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Polaris Ranger", text: $name)
                } header: {
                    Text("Name")
                }

                Section {
                    Picker("Machine", selection: $machineType) {
                        ForEach(VineyardMachineType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                } header: {
                    Text("Machine Type")
                }

                Section {
                    Toggle("Fuel tracking enabled", isOn: $fuelTrackingEnabled)
                    Toggle("Available for job costing", isOn: $availableForJobCosting)
                } footer: {
                    Text("Machines with fuel tracking on appear in the Fuel Log picker. Job costing controls whether this machine can be used later when costing trips.")
                }

                Section {
                    TextField("Optional — e.g. 6.5", text: $fuelUsage)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Default Fuel Usage (L/hr)")
                } footer: {
                    Text("Leave blank if not set. Fuel usage is calculated between full fills with valid meter readings; this default is only used when you deliberately set it.")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle(machine == nil ? "New Machine" : "Edit Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let usage = Double(fuelUsage.trimmingCharacters(in: .whitespaces)) ?? 0
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing = machine {
            existing.name = trimmedName
            existing.machineType = machineType
            existing.fuelTrackingEnabled = fuelTrackingEnabled
            existing.availableForJobCosting = availableForJobCosting
            existing.fuelUsageLPerHour = usage
            existing.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            store.updateVineyardMachine(existing)
        } else {
            // Never create a legacy tractor link for natively-created machines.
            store.addVineyardMachine(VineyardMachine(
                name: trimmedName,
                machineType: machineType,
                fuelTrackingEnabled: fuelTrackingEnabled,
                availableForJobCosting: availableForJobCosting,
                fuelUsageLPerHour: usage,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            ))
        }
        // Push immediately so other devices and the Fuel Log picker stay current.
        Task { await machineSync.syncForSelectedVineyard() }
    }
}
