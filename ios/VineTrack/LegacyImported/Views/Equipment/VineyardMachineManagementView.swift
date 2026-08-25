import SwiftUI

/// Manages `vineyard_machines` for the selected vineyard — letting owners and
/// managers add ATVs, side-by-sides, harvesters, utility vehicles and other
/// machines that can appear in the Fuel Log picker.
///
/// Tractors are NOT managed here. A tractor-backed machine (one with a
/// `legacyTractorId`) is hidden from this list entirely and edited under
/// Equipment → Tractors, so a tractor appears to the user in exactly one
/// place even though a machine row exists underneath it for the Fuel Log and
/// legacy costing. `canEdit(_:)` keeps the read-only rule as a backstop in
/// case a tractor-backed row ever reaches the list.
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
                    Text("Add ATVs, side-by-sides, harvesters, utility vehicles and other powered vineyard machines. Machines with fuel tracking on appear in the Fuel Log. Tractors are added under Equipment → Tractors.")
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
                         ? "Add your ATVs, side-by-sides, harvesters and other machines to track their fuel use. Tractors are added under Equipment → Tractors."
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
                if let identifier = equipmentIdentifierSubtitle(serialNumber: machine.serialNumber, vinNumber: machine.vinNumber) {
                    Text(identifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
    @State private var serialNumber: String = ""
    @State private var vinNumber: String = ""
    @State private var saveError: String?

    init(machine: VineyardMachine?) {
        self.machine = machine
        if let m = machine {
            _name = State(initialValue: m.name)
            _machineType = State(initialValue: m.machineType)
            _fuelTrackingEnabled = State(initialValue: m.fuelTrackingEnabled)
            _availableForJobCosting = State(initialValue: m.availableForJobCosting)
            _fuelUsage = State(initialValue: m.hasFuelUsageRate ? String(format: "%.1f", m.fuelUsageLPerHour) : "")
            _notes = State(initialValue: m.notes ?? "")
            _serialNumber = State(initialValue: m.serialNumber ?? "")
            _vinNumber = State(initialValue: m.vinNumber ?? "")
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Machine types offered in the picker. Tractor is not creatable here —
    /// see `VineyardMachineType.pickerCases(editing:)`.
    private var availableTypes: [VineyardMachineType] {
        VineyardMachineType.pickerCases(editing: machine?.machineType)
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
                        ForEach(availableTypes, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                } header: {
                    Text("Machine Type")
                } footer: {
                    Text("Adding a tractor? Use Equipment → Tractors so it appears under Tractors and can be used for trip costing.")
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

                Section("Identification (optional)") {
                    TextField("Serial number", text: $serialNumber)
                        .autocorrectionDisabled()
                    TextField("VIN number", text: $vinNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
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
                        // Only dismiss on a real save — a rejected write must
                        // never look like it succeeded.
                        if save() { dismiss() }
                    }
                    .disabled(!isValid)
                }
            }
            .alert("Can't save machine", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    @discardableResult
    private func save() -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let usage = Double(fuelUsage.trimmingCharacters(in: .whitespaces)) ?? 0
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSerial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVin = vinNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = trimmedSerial.isEmpty ? nil : trimmedSerial
        let vin = trimmedVin.isEmpty ? nil : trimmedVin
        let saved: Bool
        if var existing = machine {
            existing.name = trimmedName
            existing.machineType = machineType
            existing.fuelTrackingEnabled = fuelTrackingEnabled
            existing.availableForJobCosting = availableForJobCosting
            existing.fuelUsageLPerHour = usage
            existing.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            existing.serialNumber = serial
            existing.vinNumber = vin
            saved = store.updateVineyardMachine(existing)
        } else {
            // Never create a legacy tractor link for natively-created machines.
            saved = store.addVineyardMachine(VineyardMachine(
                name: trimmedName,
                machineType: machineType,
                fuelTrackingEnabled: fuelTrackingEnabled,
                availableForJobCosting: availableForJobCosting,
                fuelUsageLPerHour: usage,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                serialNumber: serial,
                vinNumber: vin
            ))
        }

        guard saved else {
            saveError = machineType == .tractor
                ? "Tractors are added under Equipment → Tractors so they appear on the Tractors screen and can be used for trip costing. Choose a different machine type, or add this as a tractor instead."
                : "This machine couldn't be saved. Check that a vineyard is selected and try again."
            return false
        }

        // Push immediately so other devices and the Fuel Log picker stay current.
        Task { await machineSync.syncForSelectedVineyard() }
        return true
    }
}
