import SwiftUI

/// Add/edit form for a manual machine/tractor/equipment work line under a
/// Work Task. Mirrors the maintenance equipment picker pattern
/// (`equipmentSource` + `equipmentRefId` + `equipmentNameSnapshot`) so the
/// stable link is captured when an asset is selected, while free text is
/// preserved when the user types a name. Used when no GPS Trip exists.
struct AddEditWorkTaskMachineLineView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(WorkTaskMachineLineSyncService.self) private var machineLineSync
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let workTaskId: UUID
    let vineyardId: UUID
    let existingLine: WorkTaskMachineLine?

    @State private var workDate: Date = Date()
    @State private var equipmentName: String = ""
    @State private var equipmentSource: String?
    @State private var equipmentRefId: UUID?
    @State private var entrySource: EntrySource = .manual
    @State private var durationText: String = ""
    @State private var engineHoursText: String = ""
    @State private var fuelLitresText: String = ""
    @State private var fuelCostText: String = ""
    @State private var hourlyRateText: String = ""
    @State private var totalCostText: String = ""
    @State private var notes: String = ""
    @State private var showDelete: Bool = false
    /// Suppresses the free-text detach in the name field's onChange while we
    /// set the name programmatically from a picker selection or when editing.
    @State private var suppressNameChange: Bool = false

    init(workTaskId: UUID, vineyardId: UUID, existingLine: WorkTaskMachineLine? = nil) {
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.existingLine = existingLine
    }

    private var isEditing: Bool { existingLine != nil }
    private var canDelete: Bool { accessControl?.canDelete ?? false }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var currencySymbol: String {
        fmt.formatCurrency(0)
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.,"))
            .first(where: { !$0.isEmpty }) ?? "$"
    }

    /// User-facing labels for the four allowed entry_source values.
    enum EntrySource: String, CaseIterable, Identifiable {
        case manual
        case missedTrip = "missed_trip"
        case tripFailed = "trip_failed"
        case correction

        var id: String { rawValue }

        var label: String {
            switch self {
            case .manual: return "Manual entry"
            case .missedTrip: return "Missed trip"
            case .tripFailed: return "Trip failed"
            case .correction: return "Correction"
            }
        }
    }

    private var vineyardMachineItems: [VineyardMachine] {
        store.machines().filter { $0.legacyTractorId == nil }
    }

    private var otherEquipmentItems: [EquipmentItem] {
        store.equipmentItems
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Parses a decimal field, returning nil for empty/invalid/non-finite input.
    private func parsedOptional(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private var trimmedName: String {
        equipmentName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// At least one of duration or engine hours must be present.
    private var hasTimeValue: Bool {
        parsedOptional(durationText) != nil || parsedOptional(engineHoursText) != nil
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && hasTimeValue
    }

    var body: some View {
        NavigationStack {
            Form {
                equipmentSection
                detailsSection
                if canViewFinancials {
                    costSection
                }
                Section("Notes") {
                    TextField("Optional notes…", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                if isEditing && canDelete {
                    Section {
                        Button(role: .destructive) {
                            showDelete = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("Delete Machine Work", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Machine Work" : "Add Machine Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!isValid)
                }
            }
            .alert("Delete Machine Work", isPresented: $showDelete) {
                Button("Delete", role: .destructive) {
                    if let line = existingLine {
                        store.deleteWorkTaskMachineLine(line.id)
                        Task { await machineLineSync.syncForSelectedVineyard() }
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this machine work entry?")
            }
            .onAppear(perform: loadIfEditing)
        }
    }

    private var equipmentSection: some View {
        Section {
            Menu {
                if !store.tractors.isEmpty {
                    Section("Tractors") {
                        ForEach(store.tractors) { tractor in
                            Button(tractor.displayName) {
                                select(name: tractor.displayName, source: "tractor", refId: tractor.id)
                            }
                        }
                    }
                }
                if !vineyardMachineItems.isEmpty {
                    Section("Vineyard Machines") {
                        ForEach(vineyardMachineItems) { machine in
                            Button("\(machine.displayName) · \(machine.machineType.displayName)") {
                                select(name: machine.displayName, source: "vineyard_machine", refId: machine.id)
                            }
                        }
                    }
                }
                if !store.sprayEquipment.isEmpty {
                    Section("Spray Equipment") {
                        ForEach(store.sprayEquipment) { eq in
                            Button(eq.name) {
                                select(name: eq.name, source: "spray_equipment", refId: eq.id)
                            }
                        }
                    }
                }
                if !otherEquipmentItems.isEmpty {
                    Section("Other Equipment & Assets") {
                        ForEach(otherEquipmentItems) { item in
                            Button(item.displayName) {
                                select(name: item.displayName, source: "equipment_item", refId: item.id)
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Equipment")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(equipmentName.isEmpty ? "Select" : equipmentName)
                        .foregroundStyle(equipmentName.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Or type equipment name", text: $equipmentName)
                .onChange(of: equipmentName) { _, _ in
                    if suppressNameChange {
                        suppressNameChange = false
                        return
                    }
                    // Manual edits detach the stable link → treat as free text.
                    equipmentSource = nil
                    equipmentRefId = nil
                }
        } header: {
            Text("Equipment")
        } footer: {
            Text("Pick a machine to keep a stable link, or type a name for a one-off entry.")
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            DatePicker("Work Date", selection: $workDate, displayedComponents: .date)

            Picker("Entry Source", selection: $entrySource) {
                ForEach(EntrySource.allCases) { src in
                    Text(src.label).tag(src)
                }
            }

            HStack {
                Text("Duration (hours)")
                Spacer()
                TextField("0", text: $durationText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }

            HStack {
                Text("Engine Hours Used")
                Spacer()
                TextField("0", text: $engineHoursText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }

            HStack {
                Text("Fuel (\(fmt.fuelUnitAbbreviation))")
                Spacer()
                TextField("Optional", text: $fuelLitresText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        }
    }

    private var costSection: some View {
        Section("Cost") {
            HStack {
                Text("Fuel Cost")
                Spacer()
                Text(currencySymbol).foregroundStyle(.secondary)
                TextField("Optional", text: $fuelCostText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            HStack {
                Text("Hourly Machine Rate")
                Spacer()
                Text(currencySymbol).foregroundStyle(.secondary)
                TextField("Optional", text: $hourlyRateText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            HStack {
                Text("Total Machine Cost")
                Spacer()
                Text(currencySymbol).foregroundStyle(.secondary)
                TextField("Optional", text: $totalCostText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        }
    }

    private func select(name: String, source: String, refId: UUID) {
        suppressNameChange = (name != equipmentName)
        equipmentName = name
        equipmentSource = source
        equipmentRefId = refId
    }

    private func loadIfEditing() {
        guard let line = existingLine else { return }
        workDate = line.workDate
        suppressNameChange = !line.equipmentNameSnapshot.isEmpty
        equipmentName = line.equipmentNameSnapshot
        equipmentSource = (line.equipmentSource == "free_text") ? nil : line.equipmentSource
        equipmentRefId = line.equipmentRefId
        entrySource = EntrySource(rawValue: line.entrySource) ?? .manual
        if let d = line.durationHours, d > 0 { durationText = String(format: "%.2f", d) }
        if let e = line.engineHoursUsed, e > 0 { engineHoursText = String(format: "%.2f", e) }
        if let f = line.fuelLitres, f > 0 { fuelLitresText = String(format: "%.2f", f) }
        if let fc = line.fuelCost, fc > 0 { fuelCostText = String(format: "%.2f", fc) }
        if let hr = line.hourlyMachineRate, hr > 0 { hourlyRateText = String(format: "%.2f", hr) }
        if let tc = line.totalMachineCost, tc > 0 { totalCostText = String(format: "%.2f", tc) }
        notes = line.notes
    }

    private func save() {
        guard isValid else { return }

        var line = existingLine ?? WorkTaskMachineLine(workTaskId: workTaskId, vineyardId: vineyardId)
        line.workTaskId = workTaskId
        line.vineyardId = vineyardId
        line.workDate = workDate
        line.equipmentNameSnapshot = trimmedName

        // Persist the stable link only when an asset was selected; otherwise
        // classify as free_text. The name snapshot is always preserved.
        if let refId = equipmentRefId, let source = equipmentSource, source != "free_text" {
            line.equipmentSource = source
            line.equipmentRefId = refId
        } else {
            line.equipmentSource = "free_text"
            line.equipmentRefId = nil
        }

        line.entrySource = entrySource.rawValue
        line.durationHours = parsedOptional(durationText)
        line.engineHoursUsed = parsedOptional(engineHoursText)
        line.fuelLitres = parsedOptional(fuelLitresText)
        line.fuelCost = parsedOptional(fuelCostText)
        line.hourlyMachineRate = parsedOptional(hourlyRateText)
        line.totalMachineCost = parsedOptional(totalCostText)
        line.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if isEditing {
            store.updateWorkTaskMachineLine(line)
        } else {
            store.addWorkTaskMachineLine(line)
        }
        Task { await machineLineSync.syncForSelectedVineyard() }
        dismiss()
    }
}
