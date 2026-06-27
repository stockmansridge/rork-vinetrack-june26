import SwiftUI

/// Lists fuel fills grouped per vineyard machine (newest first) and lets any
/// vineyard member record a new fill. Litres/hour is derived for display only
/// from the previous fill for the same machine.
struct FuelLogView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var showAddSheet: Bool = false
    @State private var editingLog: TractorFuelLog?

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    private var vineyardTractors: [Tractor] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.tractors.filter { $0.vineyardId == vid }
    }

    private var logs: [TractorFuelLog] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.tractorFuelLogs
            .filter { $0.vineyardId == vid }
            .sorted { $0.fillDateTime > $1.fillDateTime }
    }

    /// Logs grouped by machine (preferring machineId, falling back to the
    /// legacy tractor link) in display order, each with a header label.
    private var groupedLogs: [(key: String, header: String, logs: [TractorFuelLog])] {
        var order: [String] = []
        var map: [String: [TractorFuelLog]] = [:]
        for log in logs {
            let k = store.fuelLogGroupKey(log)
            if map[k] == nil { order.append(k); map[k] = [] }
            map[k]?.append(log)
        }
        return order.map { key in
            let groupLogs = map[key] ?? []
            let header = groupLogs.first.map { groupHeader(for: $0) } ?? "Machine"
            return (key, header, groupLogs)
        }
    }

    private func groupHeader(for log: TractorFuelLog) -> String {
        if let m = store.machine(forFuelLog: log) {
            return "\(m.displayName) · \(m.machineType.displayName)"
        }
        if let tid = log.tractorId, let t = vineyardTractors.first(where: { $0.id == tid }) {
            return t.displayName
        }
        return "Unassigned machine"
    }

    var body: some View {
        List {
            if logs.isEmpty {
                Section {
                    Text("No fuel fills recorded yet. Tap + to record litres added and engine hours when you fill a vineyard machine.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(groupedLogs, id: \.key) { group in
                Section {
                    ForEach(group.logs) { log in
                        let previous = store.previousFuelLog(forMachineGroupOf: log, before: log.fillDateTime, excluding: log.id)
                        let rate = TractorFuelRateCalculator.rate(current: log, previous: previous)
                        let canEdit = canManageSetup || (log.operatorUserId != nil && log.operatorUserId == store.currentUserIdProvider?())
                        Group {
                            if canEdit {
                                Button { editingLog = log } label: { FuelLogRow(log: log, rate: rate) }
                            } else {
                                FuelLogRow(log: log, rate: rate)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if canManageSetup {
                                Button(role: .destructive) {
                                    store.deleteTractorFuelLog(log)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text(group.header)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Fuel Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            FuelFillFormSheet(log: nil)
        }
        .sheet(item: $editingLog) { item in
            FuelFillFormSheet(log: item)
        }
    }
}

struct FuelLogRow: View {
    let log: TractorFuelLog
    let rate: TractorFuelRateResult
    @Environment(\.accessControl) private var accessControl
    @Environment(MigratedDataStore.self) private var store

    /// Region-aware display formatter (AU defaults when no settings exist).
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var litresText: String {
        fmt.formatFuel(litres: log.litresAdded)
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(litresText)
                        .font(.body.weight(.semibold))
                    if log.filledToFull == true {
                        Label("Full", systemImage: "drop.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(VineyardTheme.olive)
                            .labelStyle(.titleAndIcon)
                    }
                }
                HStack(spacing: 10) {
                    Label(log.fillDateTime.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    if let hours = log.engineHours {
                        Label("\(String(format: "%.1f", hours)) hrs", systemImage: "gauge.with.needle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let name = log.operatorName, !name.isEmpty {
                    Label(name, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if (accessControl?.canViewFinancials ?? false), let cpl = log.costPerLitre {
                    Text(fmt.formatFuelCostPerUnit(perLitre: cpl))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(VineyardTheme.olive)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let lph = rate.litresPerHour {
                    Text(fmt.formatFuelRatePerHour(litresPerHour: lph))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(rate.reliability == .reliable ? VineyardTheme.olive : .orange)
                    Text(rate.reliability == .reliable ? "calculated" : "estimate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct FuelFillFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(TractorFuelLogSyncService.self) private var fuelLogSync
    @Environment(TractorSyncService.self) private var tractorSync
    @Environment(VineyardMachineSyncService.self) private var machineSync

    let log: TractorFuelLog?

    @State private var machineId: UUID?
    @State private var litresText: String = ""
    @State private var engineHoursText: String = ""
    @State private var fillDate: Date = Date()
    @State private var operatorName: String = ""
    @State private var costPerLitreText: String = ""
    @State private var totalCostText: String = ""
    @State private var filledToFull: Bool = true
    @State private var notes: String = ""

    /// After a successful save, holds the derived rate so we can show the
    /// summary + optional "use as machine default" action before dismissing.
    @State private var savedResult: TractorFuelRateResult?
    @State private var savedMachineId: UUID?
    @State private var didApplyDefault: Bool = false

    init(log: TractorFuelLog?) {
        self.log = log
        if let l = log {
            _machineId = State(initialValue: l.machineId)
            _litresText = State(initialValue: l.litresAdded > 0 ? String(format: "%.1f", l.litresAdded) : "")
            _engineHoursText = State(initialValue: l.engineHours.map { String(format: "%.1f", $0) } ?? "")
            _fillDate = State(initialValue: l.fillDateTime)
            _operatorName = State(initialValue: l.operatorName ?? "")
            _costPerLitreText = State(initialValue: l.costPerLitre.map { String(format: "%.2f", $0) } ?? "")
            _totalCostText = State(initialValue: l.totalCost.map { String(format: "%.2f", $0) } ?? "")
            _filledToFull = State(initialValue: l.filledToFull ?? true)
            _notes = State(initialValue: l.notes ?? "")
        }
    }

    /// Machines available for fuel logging: not deleted (deleted rows are
    /// removed from the store) and with fuel tracking enabled.
    private var fuelTrackingMachines: [VineyardMachine] {
        store.machines().filter { $0.fuelTrackingEnabled }
    }

    private var selectedMachine: VineyardMachine? {
        guard let mid = machineId else { return nil }
        return store.vineyardMachines.first { $0.id == mid }
    }

    private var litres: Double { Double(litresText) ?? 0 }
    private var engineHours: Double? { engineHoursText.isEmpty ? nil : Double(engineHoursText) }
    private var isValid: Bool { litres > 0 }

    var body: some View {
        NavigationStack {
            Form {
                if let result = savedResult {
                    savedSummarySection(result)
                } else {
                    formSections
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if savedResult == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(!isValid)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear {
                if log == nil, operatorName.isEmpty {
                    operatorName = auth.userName ?? ""
                }
                // Resolve a machine for legacy logs that only carry a tractorId.
                if let l = log, machineId == nil, let tid = l.tractorId {
                    machineId = store.vineyardMachines.first { $0.legacyTractorId == tid }?.id
                }
            }
        }
    }

    private var navTitle: String {
        if savedResult != nil { return "Fuel Fill Saved" }
        return log == nil ? "Record Fuel Fill" : "Edit Fuel Fill"
    }

    @ViewBuilder
    private var formSections: some View {
        Section("Machine") {
            if fuelTrackingMachines.isEmpty {
                Text("No vineyard machines with fuel tracking enabled yet. Add a vineyard machine to record fuel fills against it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Machine", selection: $machineId) {
                    Text("Select machine").tag(UUID?.none)
                    ForEach(fuelTrackingMachines) { m in
                        Text("\(m.displayName) · \(m.machineType.displayName)").tag(UUID?.some(m.id))
                    }
                }
            }
        }

        Section {
            HStack {
                TextField("e.g. 120", text: $litresText)
                    .keyboardType(.decimalPad)
                Text("L").foregroundStyle(.secondary)
            }
        } header: {
            Text("Litres Added")
        }

        Section {
            HStack {
                TextField("e.g. 1320.5", text: $engineHoursText)
                    .keyboardType(.decimalPad)
                Text("hrs").foregroundStyle(.secondary)
            }
        } header: {
            Text("Engine Hours at Fill")
        } footer: {
            Text("Fuel usage is calculated between full fills with valid meter readings.")
        }

        Section("When") {
            DatePicker("Fill date & time", selection: $fillDate)
        }

        Section("Operator") {
            TextField("Operator name", text: $operatorName)
        }

        Section {
            Toggle("Filled to full", isOn: $filledToFull)
        } footer: {
            Text("L/hr is most accurate when both this fill and the previous fill were to the same tank level (full).")
        }

        Section("Cost (optional)") {
            HStack {
                Text("$").foregroundStyle(.secondary)
                TextField("Cost per litre", text: $costPerLitreText)
                    .keyboardType(.decimalPad)
                Text("/L").foregroundStyle(.secondary)
            }
            HStack {
                Text("$").foregroundStyle(.secondary)
                TextField("Total cost", text: $totalCostText)
                    .keyboardType(.decimalPad)
            }
        }

        Section("Notes (optional)") {
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    @ViewBuilder
    private func savedSummarySection(_ result: TractorFuelRateResult) -> some View {
        Section {
            if let lph = result.litresPerHour {
                HStack {
                    Text("Fuel rate")
                    Spacer()
                    Text("\(String(format: "%.2f", lph)) L/hr")
                        .font(.headline)
                        .foregroundStyle(result.reliability == .reliable ? VineyardTheme.olive : .orange)
                }
                if let delta = result.engineHoursDelta {
                    HStack {
                        Text("Engine hours since last fill")
                        Spacer()
                        Text("\(String(format: "%.1f", delta)) hrs")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Litres per hour could not be calculated for this fill.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Calculated Rate")
        }

        if !result.warnings.isEmpty {
            Section {
                ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, w in
                    Label(warningText(w), systemImage: warningIcon(w))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }

        if let lph = result.litresPerHour,
           let mid = savedMachineId,
           let machine = store.vineyardMachines.first(where: { $0.id == mid }) {
            Section {
                if didApplyDefault {
                    Label("Updated \(machine.displayName) default to \(String(format: "%.1f", lph)) L/hr", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(VineyardTheme.olive)
                } else {
                    Button {
                        applyAsMachineDefault(lph: lph, machine: machine)
                    } label: {
                        Label("Use \(String(format: "%.1f", lph)) L/hr as machine default", systemImage: "arrow.up.circle")
                    }
                }
            } footer: {
                Text("The machine's default fuel rate is only changed if you choose to update it here.")
            }
        }
    }

    private func warningText(_ w: TractorFuelRateResult.Warning) -> String {
        switch w {
        case .missingEngineHours:
            return "Fuel log saved, but L/hr cannot be calculated without engine hours."
        case .engineHoursWentBackwards:
            return "Engine hours are lower than the previous fill — check the reading."
        case .engineHoursDeltaZero:
            return "Engine hours match the previous fill, so L/hr cannot be calculated."
        case .unrealisticRate:
            return "Calculated L/hr looks unusually high or low — double-check litres and engine hours."
        case .notFilledToFull:
            return "L/hr may be inaccurate unless both fills were to the same level."
        }
    }

    private func warningIcon(_ w: TractorFuelRateResult.Warning) -> String {
        switch w {
        case .missingEngineHours: return "gauge.with.dots.needle.bottom.0percent"
        case .engineHoursWentBackwards: return "arrow.uturn.backward"
        case .engineHoursDeltaZero: return "equal.circle"
        case .unrealisticRate: return "exclamationmark.triangle.fill"
        case .notFilledToFull: return "drop"
        }
    }

    private func save() {
        let cpl = Double(costPerLitreText)
        let total = Double(totalCostText)
        let machine = selectedMachine
        // Prefer machine_id as the link. Populate legacy tractor_id only when
        // the machine is backed by a legacy tractor, so existing trip costing
        // (which still reads trips.tractor_id) keeps working. Non-tractor
        // machines leave tractor_id nil.
        let legacyTractorId = machine?.legacyTractorId

        var entry: TractorFuelLog
        if let existing = log {
            entry = existing
            entry.machineId = machineId
            entry.tractorId = legacyTractorId
            entry.litresAdded = litres
            entry.engineHours = engineHours
            entry.fillDateTime = fillDate
            entry.operatorName = operatorName.isEmpty ? nil : operatorName
            entry.costPerLitre = cpl
            entry.totalCost = total
            entry.filledToFull = filledToFull
            entry.notes = notes.isEmpty ? nil : notes
            store.updateTractorFuelLog(entry)
        } else {
            entry = TractorFuelLog(
                tractorId: legacyTractorId,
                machineId: machineId,
                fillDateTime: fillDate,
                litresAdded: litres,
                engineHours: engineHours,
                operatorUserId: auth.userId,
                operatorName: operatorName.isEmpty ? nil : operatorName,
                costPerLitre: cpl,
                totalCost: total,
                filledToFull: filledToFull,
                notes: notes.isEmpty ? nil : notes
            )
            store.addTractorFuelLog(entry)
        }

        let previous = store.previousFuelLog(forMachineGroupOf: entry, before: entry.fillDateTime, excluding: entry.id)
        savedResult = TractorFuelRateCalculator.rate(current: entry, previous: previous)
        savedMachineId = entry.machineId

        // Push immediately so other devices and the Portal see it promptly.
        Task { await fuelLogSync.syncForSelectedVineyard() }
    }

    /// Applies the calculated L/hr as the machine's default, only on explicit
    /// user action. For legacy tractor-backed machines, also updates the
    /// underlying tractor so current trip costing behaviour is preserved.
    private func applyAsMachineDefault(lph: Double, machine: VineyardMachine) {
        var updatedMachine = machine
        updatedMachine.fuelUsageLPerHour = lph
        store.updateVineyardMachine(updatedMachine)
        Task { await machineSync.syncForSelectedVineyard() }

        if machine.machineType == .tractor,
           let tid = machine.legacyTractorId,
           var tractor = store.tractors.first(where: { $0.id == tid }) {
            tractor.fuelUsageLPerHour = lph
            store.updateTractor(tractor)
            Task { await tractorSync.syncForSelectedVineyard() }
        }
        didApplyDefault = true
    }
}
