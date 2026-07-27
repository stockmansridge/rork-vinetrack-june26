import SwiftUI
import Supabase

// MARK: - Irrigation Setup (Systems / Valves / Block Connections / Details / Status)

struct IrrigationSetupView: View {
    enum SetupSection: String, CaseIterable, Identifiable {
        case systems = "Systems"
        case valves = "Valves"
        case connections = "Blocks"
        case details = "Details"
        case status = "Status"
        var id: String { rawValue }
    }

    @Environment(MigratedDataStore.self) private var store

    @State private var section: SetupSection
    private let onChanged: () -> Void

    @State private var systems: [IrrigationSystem] = []
    @State private var valves: [IrrigationValve] = []
    @State private var status: IrrigationSetupStatus?
    @State private var errorMessage: String?
    @State private var showAddSystem = false
    @State private var showAddValve = false
    @State private var editingSystem: IrrigationSystem?
    @State private var editingValve: IrrigationValve?
    @State private var connectionValveId: UUID?

    private let repository = SupabaseIrrigationRepository.shared

    init(initialSection: SetupSection = .systems, onChanged: @escaping () -> Void = {}) {
        _section = State(initialValue: initialSection)
        self.onChanged = onChanged
    }

    private var vineyardId: UUID? { store.selectedVineyardId }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(SetupSection.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            switch section {
            case .systems: systemsList
            case .valves: valvesList
            case .connections: connectionsSection
            case .details: IrrigationDetailsSection()
            case .status: statusSection
            }
        }
        .navigationTitle("Irrigation Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: vineyardId) { await reload() }
        .sheet(isPresented: $showAddSystem) {
            IrrigationSystemForm(system: nil) { await reload() }
        }
        .sheet(item: $editingSystem) { system in
            IrrigationSystemForm(system: system) { await reload() }
        }
        .sheet(isPresented: $showAddValve) {
            IrrigationValveForm(valve: nil, systems: systems.filter { $0.isActive }) { await reload() }
        }
        .sheet(item: $editingValve) { valve in
            IrrigationValveForm(valve: valve, systems: systems.filter { $0.isActive }) { await reload() }
        }
    }

    private func reload() async {
        guard let vineyardId else { return }
        errorMessage = nil
        do {
            async let systemsTask = repository.listSystems(vineyardId: vineyardId, includeInactive: true)
            async let valvesTask = repository.listValves(vineyardId: vineyardId, includeInactive: true)
            async let statusTask = repository.setupStatus(vineyardId: vineyardId)
            systems = try await systemsTask
            valves = try await valvesTask
            status = try await statusTask
            onChanged()
        } catch {
            errorMessage = "Setup could not be loaded. \(error.localizedDescription)"
        }
    }

    // MARK: Systems

    private var systemsList: some View {
        List {
            ForEach(systems) { system in
                Button {
                    editingSystem = system
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(system.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(system.isActive ? .primary : .secondary)
                            if let source = system.waterSource, !source.isEmpty {
                                Text(source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !system.isActive {
                            Text("Inactive")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Section {
                Button {
                    showAddSystem = true
                } label: {
                    Label("Add Irrigation System", systemImage: "plus.circle.fill")
                }
            }
        }
    }

    // MARK: Valves

    private var valvesList: some View {
        List {
            ForEach(valves) { valve in
                Button {
                    editingValve = valve
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(valve.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(valve.isActive ? .primary : .secondary)
                            Text("\(valve.systemName ?? "System") · \(configurationSummary(for: valve.id))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let flow = valve.configuredFlowLitresPerHour {
                            Text(String(format: "%.0f L/h", flow))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.cyan)
                        } else {
                            Text("No flow")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Section {
                Button {
                    showAddValve = true
                } label: {
                    Label("Add Irrigation Valve", systemImage: "plus.circle.fill")
                }
                .disabled(systems.filter { $0.isActive }.isEmpty)
                if systems.filter({ $0.isActive }).isEmpty {
                    Text("Create an irrigation system first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Connections

    private func valveStatus(for valveId: UUID) -> IrrigationSetupStatus.ValveStatus? {
        status?.valves.first(where: { $0.valveId == valveId })
    }

    /// "Rows · 20 rows · 1 block · 100%", "Manual % · 1 block · 100%" or "Not configured".
    private func configurationSummary(for valveId: UUID) -> String {
        valveStatus(for: valveId)?.configurationSummary ?? "Not configured"
    }

    private var connectionsSection: some View {
        Group {
            let activeValves = valves.filter { $0.isActive }
            if activeValves.isEmpty {
                ContentUnavailableView("No Valves", systemImage: "circle.grid.cross",
                                       description: Text("Add a valve before assigning blocks."))
            } else {
                List {
                    Section {
                        Text("Each valve shows its saved connection method and readiness. Select a valve to configure its connections.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("Configured valves") {
                        ForEach(activeValves) { valve in
                            NavigationLink {
                                IrrigationValveBlocksEditor(valve: valve) { await reload() }
                            } label: {
                                let vs = valveStatus(for: valve.id)
                                let ready = vs?.allocationOk ?? false
                                HStack(spacing: 10) {
                                    Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .foregroundStyle(ready ? .green : .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(valve.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(configurationSummary(for: valve.id))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(ready
                                         ? "Ready to record"
                                         : ((vs?.blockCount ?? 0) == 0 ? "Configure connections" : "Setup required"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(ready ? .green : .orange)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        List {
            if let status {
                Section("Required") {
                    statusRow("Growing season", true,
                              detail: "Vintage \(String(status.season.currentVintageYear))")
                    statusRow("Active blocks", status.required.blocksOk,
                              detail: "\(status.required.activeBlockCount)")
                    statusRow("Irrigation systems", status.required.systemsOk,
                              detail: "\(status.required.activeSystemCount)")
                    statusRow("Valves", status.required.valvesOk,
                              detail: "\(status.required.activeValveCount)")
                    statusRow("Valves fully allocated", status.required.allocationsOk,
                              detail: "\(status.required.fullyAllocatedValveCount) of \(status.required.activeValveCount)")
                }
                Section("Per valve") {
                    ForEach(status.valves) { valve in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(valve.valveName)
                                    .font(.subheadline)
                                Text(valve.configurationSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(valve.allocationOk ? "Ready" : (valve.blockCount == 0 ? "Not configured" : "\(String(format: "%.1f", valve.allocationTotal))%"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(valve.allocationOk ? .green : .orange)
                            Image(systemName: valve.hasConfiguredFlow ? "drop.fill" : "drop")
                                .font(.caption)
                                .foregroundStyle(valve.hasConfiguredFlow ? .cyan : .secondary)
                        }
                    }
                }
                Section("Recommended data coverage") {
                    coverageRow("Block area", status.recommended.blocksWithArea, status.recommended.totalActiveBlocks)
                    coverageRow("Vine count", status.recommended.blocksWithVineCount, status.recommended.totalActiveBlocks)
                    coverageRow("Dripper output", status.recommended.blocksWithDripperOutput, status.recommended.totalActiveBlocks)
                    coverageRow("Dripper spacing", status.recommended.blocksWithDripperSpacing, status.recommended.totalActiveBlocks)
                    coverageRow("Irrigation efficiency", status.recommended.blocksWithEfficiency, status.recommended.totalActiveBlocks)
                }
            } else {
                ProgressView()
            }
        }
    }

    private func statusRow(_ title: String, _ ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func coverageRow(_ title: String, _ done: Int, _ total: Int) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text("\(done)/\(total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(total > 0 && done >= total ? .green : .secondary)
        }
    }
}

// MARK: - System form

private struct IrrigationSystemForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let system: IrrigationSystem?
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var waterSource = ""
    @State private var notes = ""
    @State private var isActive = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let repository = SupabaseIrrigationRepository.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("System") {
                    TextField("Name (e.g. Main Vineyard Irrigation)", text: $name)
                    TextField("Water source (e.g. Main Dam)", text: $waterSource)
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if system != nil {
                    Section {
                        Toggle("Active", isOn: $isActive)
                        Text("Systems used by historical records should be made inactive rather than deleted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(system == nil ? "New System" : "Edit System")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .onAppear {
                if let system {
                    name = system.name
                    waterSource = system.waterSource ?? ""
                    notes = system.notes ?? ""
                    isActive = system.isActive
                }
            }
        }
    }

    private func save() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let system {
                _ = try await repository.updateSystem(
                    id: system.id, name: name,
                    waterSource: waterSource.isEmpty ? nil : waterSource,
                    notes: notes.isEmpty ? nil : notes,
                    isActive: isActive)
            } else {
                _ = try await repository.createSystem(
                    vineyardId: vineyardId, name: name,
                    waterSource: waterSource.isEmpty ? nil : waterSource,
                    notes: notes.isEmpty ? nil : notes)
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = friendlyIrrigationError(error)
        }
    }
}

// MARK: - Valve form

private struct IrrigationValveForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let valve: IrrigationValve?
    let systems: [IrrigationSystem]
    let onSaved: () async -> Void

    @State private var systemId: UUID?
    @State private var name = ""
    @State private var valveNumber = ""
    @State private var configuredFlow = ""
    @State private var measuredFlow = ""
    @State private var notes = ""
    @State private var isActive = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let repository = SupabaseIrrigationRepository.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Valve") {
                    if valve == nil {
                        Picker("Irrigation system", selection: $systemId) {
                            Text("Select…").tag(UUID?.none)
                            ForEach(systems) { system in
                                Text(system.name).tag(UUID?.some(system.id))
                            }
                        }
                    }
                    TextField("Valve name (e.g. Valve 3 — River Blocks)", text: $name)
                    TextField("Valve number (optional)", text: $valveNumber)
                }
                Section("Flow") {
                    TextField("Configured flow (L/h)", text: $configuredFlow)
                        .keyboardType(.decimalPad)
                    TextField("Measured flow (L/h, optional)", text: $measuredFlow)
                        .keyboardType(.decimalPad)
                    Text("The configured flow is used for duration-based water calculations. A measured flow is informational until you save it as the configured value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if valve != nil {
                    Section {
                        Toggle("Active", isOn: $isActive)
                        Text("Valves used by historical sessions should be made inactive rather than deleted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(valve == nil ? "New Valve" : "Edit Valve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (valve == nil && systemId == nil) || isSaving)
                }
            }
            .onAppear {
                if let valve {
                    systemId = valve.irrigationSystemId
                    name = valve.name
                    valveNumber = valve.valveNumber ?? ""
                    if let flow = valve.configuredFlowLitresPerHour {
                        configuredFlow = String(format: "%g", flow)
                    }
                    if let flow = valve.measuredFlowLitresPerHour {
                        measuredFlow = String(format: "%g", flow)
                    }
                    notes = valve.notes ?? ""
                    isActive = valve.isActive
                } else if systems.count == 1 {
                    systemId = systems.first?.id
                }
            }
        }
    }

    private func save() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let configured = Double(configuredFlow.replacingOccurrences(of: ",", with: "."))
        let measured = Double(measuredFlow.replacingOccurrences(of: ",", with: "."))
        do {
            if let valve {
                _ = try await repository.updateValve(
                    id: valve.id, name: name,
                    valveNumber: valveNumber.isEmpty ? nil : valveNumber,
                    configuredFlow: configured, measuredFlow: measured,
                    notes: notes.isEmpty ? nil : notes, isActive: isActive)
            } else if let systemId {
                _ = try await repository.createValve(
                    vineyardId: vineyardId, systemId: systemId, name: name,
                    valveNumber: valveNumber.isEmpty ? nil : valveNumber,
                    configuredFlow: configured, measuredFlow: measured,
                    notes: notes.isEmpty ? nil : notes)
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = friendlyIrrigationError(error)
        }
    }
}

// MARK: - Valve → block allocation editor (Manual % / Rows)

struct IrrigationValveBlocksEditor: View {
    enum AllocationMode: String, CaseIterable, Identifiable {
        case manual = "Manual %"
        case rows = "Rows"
        var id: String { rawValue }
    }

    struct AllocationRow: Identifiable {
        let id = UUID()
        var blockId: UUID?
        var percentage: String
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let valve: IrrigationValve
    let onSaved: () async -> Void

    @State private var mode: AllocationMode = .manual
    @State private var rows: [AllocationRow] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    // Rows mode state
    @State private var availableRows: [IrrigationAvailableRow] = []
    @State private var selectedRowIds: Set<UUID> = []
    @State private var expandedBlocks: Set<UUID> = []
    @State private var rowSearch = ""
    @State private var serverResult: IrrigationValveRowsResult?

    // Saved state — kept strictly separate from the local draft so the UI can
    // always distinguish "Current saved configuration" from "Unsaved preview".
    @State private var savedLinks: [IrrigationValveRowLink] = []
    @State private var savedBlocks: [IrrigationValveBlock] = []
    @State private var showClearConfirm = false

    private let repository = SupabaseIrrigationRepository.shared

    private var total: Double {
        rows.reduce(0) { $0 + (Double($1.percentage.replacingOccurrences(of: ",", with: ".")) ?? 0) }
    }
    private var totalOk: Bool { abs(total - 100) <= 0.05 && !rows.isEmpty }

    private var selectedRows: [IrrigationAvailableRow] {
        availableRows.filter { selectedRowIds.contains($0.rowId) }
    }

    private var savedRowIds: Set<UUID> { Set(savedLinks.compactMap(\.rowId)) }

    private var hasUnsavedRowChanges: Bool { selectedRowIds != savedRowIds }

    private var rowsByBlock: [(blockId: UUID, blockName: String, rows: [IrrigationAvailableRow])] {
        var order: [UUID] = []
        var grouped: [UUID: (String, [IrrigationAvailableRow])] = [:]
        for row in availableRows {
            if grouped[row.blockId] == nil {
                grouped[row.blockId] = (row.blockName, [])
                order.append(row.blockId)
            }
            grouped[row.blockId]?.1.append(row)
        }
        return order.compactMap { id in
            guard let entry = grouped[id] else { return nil }
            return (id, entry.0, entry.1)
        }
    }

    var body: some View {
        List {
            Section {
                Text(mode == .manual
                     ? "Connect \(valve.name) to the blocks it waters. Active allocations must total 100%."
                     : "Select the exact vineyard rows \(valve.name) supplies. VineTrack derives the blocks and water split from your selection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Allocation Method", selection: $mode) {
                    ForEach(AllocationMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            if mode == .rows {
                rowsSections
            } else {
            Section("Blocks") {
                ForEach($rows) { $row in
                    HStack {
                        Picker("Block", selection: $row.blockId) {
                            Text("Select…").tag(UUID?.none)
                            ForEach(store.paddocks, id: \.id) { paddock in
                                Text(paddock.name).tag(UUID?.some(paddock.id))
                            }
                        }
                        .labelsHidden()
                        Spacer()
                        TextField("%", text: $row.percentage)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { rows.remove(atOffsets: $0) }

                Button {
                    let remaining = max(0, 100 - total)
                    rows.append(AllocationRow(blockId: nil, percentage: remaining > 0 ? String(format: "%g", remaining) : ""))
                } label: {
                    Label("Add Block", systemImage: "plus.circle.fill")
                }
            }

            Section {
                HStack {
                    Text("Allocated")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.2f%%", total))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(totalOk ? .green : (total > 100 ? .red : .orange))
                }
                if !totalOk && !rows.isEmpty {
                    Text(total > 100 ? "Allocations exceed 100%." : "Allocations must total exactly 100%.")
                        .font(.caption)
                        .foregroundStyle(total > 100 ? .red : .orange)
                }
            }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Section {
                if mode == .rows && selectedRowIds.isEmpty && !availableRows.isEmpty {
                    Text("Select at least one row before saving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(mode == .rows ? "Save Row Connections" : "Save Block Connections")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(isSaving || (mode == .manual
                    ? ((!totalOk && !rows.isEmpty) || rows.contains { $0.blockId == nil })
                    : selectedRowIds.isEmpty))

                if mode == .rows && !savedRowIds.isEmpty {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("Clear saved connections")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isSaving)
                }
            }
        }
        .navigationTitle(valve.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(
            "Clear saved connections?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear saved connections", role: .destructive) {
                Task { await clearSavedConnections() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This valve will no longer have any connected rows and cannot record irrigation until it is configured again.")
        }
    }

    // MARK: Rows mode sections

    @ViewBuilder
    private var rowsSections: some View {
        if availableRows.isEmpty {
            Section {
                Text(isLoading
                     ? "Loading vineyard rows…"
                     : "No vineyard rows are configured. Map rows for your blocks in Vineyard Blocks before using row-based allocation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            if availableRows.count > 30 {
                Section {
                    TextField("Search rows (e.g. 12)", text: $rowSearch)
                        .textInputAutocapitalization(.never)
                }
            }

            ForEach(rowsByBlock, id: \.blockId) { group in
                let visible = group.rows.filter {
                    rowSearch.isEmpty || $0.displayLabel.localizedCaseInsensitiveContains(rowSearch)
                }
                let selectedCount = group.rows.filter { selectedRowIds.contains($0.rowId) }.count
                Section {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedBlocks.contains(group.blockId) || !rowSearch.isEmpty },
                        set: { expanded in
                            if expanded { expandedBlocks.insert(group.blockId) }
                            else { expandedBlocks.remove(group.blockId) }
                        }
                    )) {
                        HStack {
                            Button("Select All") {
                                selectedRowIds.formUnion(group.rows.map(\.rowId))
                                serverResult = nil
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            Button("Clear") {
                                selectedRowIds.subtract(group.rows.map(\.rowId))
                                serverResult = nil
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            Spacer()
                        }
                        ForEach(visible) { row in
                            rowToggle(row)
                        }
                    } label: {
                        HStack {
                            Text(group.blockName)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(selectedCount) of \(group.rows.count) rows")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selectedCount > 0 ? .cyan : .secondary)
                        }
                    }
                }
            }

            rowsSummarySection
        }
    }

    private func rowToggle(_ row: IrrigationAvailableRow) -> some View {
        let isSelected = selectedRowIds.contains(row.rowId)
        let otherValves = (row.connectedValveNames ?? []).filter { $0 != valve.name }
        return Button {
            if isSelected { selectedRowIds.remove(row.rowId) } else { selectedRowIds.insert(row.rowId) }
            serverResult = nil
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? .cyan : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayLabel)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if !otherValves.isEmpty {
                        Text("Also: \(otherValves.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if let length = row.rowLengthMetres {
                    Text(String(format: "%.0f m", length))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Length unavailable")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Rows summary (saved vs draft)

    private struct RowSummaryBlock: Identifiable {
        let blockId: UUID
        let blockName: String
        let selectedNumbers: [Int]
        let totalRows: Int
        /// Share of the VALVE's water — the server-authoritative allocation
        /// percentage (or the provisional preview while editing).
        let share: Double?
        var id: UUID { blockId }
        /// Proportion of THIS BLOCK's rows selected — display only, never sent
        /// to the server as an allocation percentage.
        var coveragePercent: Double? {
            totalRows > 0 ? Double(selectedNumbers.count) / Double(totalRows) * 100 : nil
        }
    }

    /// Saved configurations derive rows from `list_irrigation_valve_rows`;
    /// unsaved edits derive them from the local selection. Exact selection is
    /// NEVER inferred from `row_start`/`row_end`.
    private var rowSummaryBlocks: [RowSummaryBlock] {
        let totals: [UUID: (name: String, total: Int)] = rowsByBlock.reduce(into: [:]) {
            $0[$1.blockId] = ($1.blockName, $1.rows.count)
        }
        if hasUnsavedRowChanges || savedLinks.isEmpty {
            let provisional = IrrigationRowWeighting.allocate(rows: selectedRows)
            let shares = Dictionary(uniqueKeysWithValues: provisional.blocks.map { ($0.blockId, $0.percentage) })
            var grouped: [UUID: (name: String, numbers: [Int])] = [:]
            for row in selectedRows {
                var entry = grouped[row.blockId] ?? (row.blockName, [])
                entry.numbers.append(row.rowNumber)
                grouped[row.blockId] = entry
            }
            return grouped
                .map { RowSummaryBlock(blockId: $0.key, blockName: $0.value.name,
                                       selectedNumbers: $0.value.numbers,
                                       totalRows: totals[$0.key]?.total ?? 0,
                                       share: shares[$0.key]) }
                .sorted { $0.blockName < $1.blockName }
        }
        let shares: [UUID: Double] = savedBlocks.reduce(into: [:]) { dict, block in
            if block.allocationMethod == "rows", let pct = block.allocationPercentage {
                dict[block.blockId] = pct
            }
        }
        var grouped: [UUID: (name: String, numbers: [Int])] = [:]
        for link in savedLinks {
            var entry = grouped[link.blockId] ?? (link.blockName ?? totals[link.blockId]?.name ?? "Block", [])
            entry.numbers.append(link.rowNumber)
            grouped[link.blockId] = entry
        }
        return grouped
            .map { RowSummaryBlock(blockId: $0.key, blockName: $0.value.name,
                                   selectedNumbers: $0.value.numbers,
                                   totalRows: totals[$0.key]?.total ?? 0,
                                   share: shares[$0.key]) }
            .sorted { $0.blockName < $1.blockName }
    }

    private var displayBasisRaw: String? {
        if hasUnsavedRowChanges {
            return selectedRows.isEmpty ? nil : IrrigationRowWeighting.basis(for: selectedRows).rawValue
        }
        return serverResult?.weightingBasis
            ?? savedLinks.first?.weightingBasis
            ?? (selectedRows.isEmpty ? nil : IrrigationRowWeighting.basis(for: selectedRows).rawValue)
    }

    /// Backend-derived totals only — never presented unless every row/block
    /// carries the value (per-row vines/emitters are not configured today).
    private var summaryVineTotal: Int? {
        if hasUnsavedRowChanges || savedLinks.isEmpty {
            guard !selectedRows.isEmpty, selectedRows.allSatisfy({ ($0.vineCount ?? 0) > 0 }) else { return nil }
            return selectedRows.reduce(0) { $0 + ($1.vineCount ?? 0) }
        }
        let rowsBlocks = savedBlocks.filter { $0.allocationMethod == "rows" }
        guard !rowsBlocks.isEmpty, rowsBlocks.allSatisfy({ $0.servicedVineCount != nil }) else { return nil }
        return rowsBlocks.reduce(0) { $0 + ($1.servicedVineCount ?? 0) }
    }

    private var summaryEmitterTotal: Int? {
        if hasUnsavedRowChanges || savedLinks.isEmpty {
            guard !selectedRows.isEmpty, selectedRows.allSatisfy({ ($0.emitterCount ?? 0) > 0 }) else { return nil }
            return selectedRows.reduce(0) { $0 + ($1.emitterCount ?? 0) }
        }
        let rowsBlocks = savedBlocks.filter { $0.allocationMethod == "rows" }
        guard !rowsBlocks.isEmpty, rowsBlocks.allSatisfy({ $0.servicedEmitterCount != nil }) else { return nil }
        return rowsBlocks.reduce(0) { $0 + ($1.servicedEmitterCount ?? 0) }
    }

    private var summaryRowsMissingLength: Int {
        if hasUnsavedRowChanges || savedLinks.isEmpty {
            return selectedRows.filter { $0.rowLengthMetres == nil }.count
        }
        return savedLinks.filter { $0.rowLengthMetres == nil }.count
    }

    @ViewBuilder
    private var rowsSummarySection: some View {
        let dirty = hasUnsavedRowChanges
        let blocks = rowSummaryBlocks
        Section(dirty ? "Unsaved preview" : "Current saved configuration") {
            if !savedRowIds.isEmpty {
                LabeledContent("Saved", value: "\(savedRowIds.count) row\(savedRowIds.count == 1 ? "" : "s")")
            }
            if dirty {
                LabeledContent("Draft", value: "\(selectedRows.count) row\(selectedRows.count == 1 ? "" : "s") selected")
            }
            if dirty && selectedRows.isEmpty && !savedRowIds.isEmpty {
                Text("All rows have been removed from the draft. The saved configuration remains active until you save.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let raw = displayBasisRaw {
                LabeledContent("Allocation basis",
                               value: IrrigationRowWeighting.Basis(rawValue: raw)?.label ?? raw)
            }

            ForEach(blocks) { block in
                VStack(alignment: .leading, spacing: 4) {
                    Text(block.blockName)
                        .font(.subheadline.weight(.semibold))
                    LabeledContent("Rows") {
                        Text("\(block.selectedNumbers.count) / \(block.totalRows) rows")
                    }
                    if !block.selectedNumbers.isEmpty {
                        Text("Rows \(IrrigationRowWeighting.rangeSummary(block.selectedNumbers))")
                            .foregroundStyle(.secondary)
                    }
                    if let coverage = block.coveragePercent {
                        LabeledContent("Block coverage") {
                            Text(String(format: "%.1f%%", coverage))
                        }
                    }
                    LabeledContent(dirty ? "Share of valve water (preview)" : "Share of valve water") {
                        Text(block.share.map { String(format: "%.1f%%", $0) } ?? "—")
                    }
                }
                .font(.caption)
            }

            if !blocks.isEmpty {
                LabeledContent("Vines (selected rows)",
                               value: summaryVineTotal.map(String.init) ?? "Not available")
                LabeledContent("Emitters (selected rows)",
                               value: summaryEmitterTotal.map(String.init) ?? "Not available")
                if summaryVineTotal == nil || summaryEmitterTotal == nil {
                    Text(displayBasisRaw == "row_length"
                         ? "Row length is currently used to calculate the block water split. Per-row vine and emitter counts are not available."
                         : "Per-row vine and emitter counts have not been configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if summaryRowsMissingLength > 0 {
                    Text("\(summaryRowsMissingLength) selected row\(summaryRowsMissingLength == 1 ? " does" : "s do") not have complete mapped start and end points, so their length is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if displayBasisRaw == "equal_rows" {
                    Text("Allocation is estimated by selected row count because complete row lengths are unavailable.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let warnings = serverResult?.warnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func load() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let existingTask = repository.listValveBlocks(vineyardId: vineyardId, valveId: valve.id)
            async let availableTask = repository.listAvailableRows(vineyardId: vineyardId)
            async let linksTask = repository.listValveRows(vineyardId: vineyardId, valveId: valve.id)
            let existing = try await existingTask
            availableRows = try await availableTask
            let links = try await linksTask

            rows = existing.map {
                AllocationRow(blockId: $0.blockId,
                              percentage: $0.allocationPercentage.map { String(format: "%g", $0) } ?? "")
            }
            savedBlocks = existing
            savedLinks = links
            selectedRowIds = Set(links.compactMap(\.rowId))
            if existing.contains(where: { $0.allocationMethod == "rows" }) {
                mode = .rows
                expandedBlocks = Set(links.map(\.blockId))
            }
        } catch {
            errorMessage = friendlyIrrigationError(error)
        }
    }

    private func save() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if mode == .rows {
                guard !selectedRowIds.isEmpty else {
                    errorMessage = "Select at least one row before saving."
                    return
                }
                // The backend response carries the AUTHORITATIVE percentages.
                let result = try await repository.setValveRows(
                    vineyardId: vineyardId, valveId: valve.id, rowIds: Array(selectedRowIds))
                serverResult = result
                savedBlocks = result.blocks
                savedLinks = (try? await repository.listValveRows(vineyardId: vineyardId, valveId: valve.id)) ?? savedLinks
                await onSaved()
                if result.warnings.isEmpty {
                    dismiss()
                }
            } else {
                let inputs: [IrrigationValveBlockInput] = rows.compactMap { row in
                    guard let blockId = row.blockId,
                          let pct = Double(row.percentage.replacingOccurrences(of: ",", with: ".")) else { return nil }
                    return IrrigationValveBlockInput(
                        blockId: blockId, allocationPercentage: pct,
                        servicedAreaM2: nil, servicedVineCount: nil, servicedEmitterCount: nil)
                }
                _ = try await repository.setValveBlocks(vineyardId: vineyardId, valveId: valve.id, blocks: inputs)
                await onSaved()
                dismiss()
            }
        } catch {
            errorMessage = friendlyIrrigationError(error)
        }
    }

    /// Removes the SAVED row configuration via the shared RPC (empty selection
    /// disconnects the valve) — never silently converts an empty draft into a
    /// saved setup.
    private func clearSavedConnections() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await repository.setValveRows(vineyardId: vineyardId, valveId: valve.id, rowIds: [])
            savedLinks = []
            savedBlocks = []
            selectedRowIds = []
            serverResult = nil
            await onSaved()
        } catch {
            errorMessage = friendlyIrrigationError(error)
        }
    }
}

// MARK: - Irrigation details (per-block dripper & efficiency, shared fields)

private struct IrrigationDetailsSection: View {
    @Environment(MigratedDataStore.self) private var store

    var body: some View {
        List {
            Section {
                Text("Dripper output, dripper spacing and irrigation efficiency are shared block details used for expected water delivery and effective water calculations. Block area, vine counts and spacing are managed in Vineyard Blocks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Blocks") {
                ForEach(store.paddocks, id: \.id) { paddock in
                    NavigationLink {
                        IrrigationBlockDetailEditor(paddockId: paddock.id, paddockName: paddock.name)
                    } label: {
                        Text(paddock.name)
                    }
                }
            }
            Section {
                NavigationLink {
                    BlocksHubView()
                } label: {
                    Label("Open Vineyard Blocks", systemImage: "square.grid.2x2")
                }
            }
        }
    }
}

private struct IrrigationBlockDetailEditor: View {
    @Environment(\.dismiss) private var dismiss

    let paddockId: UUID
    let paddockName: String

    @State private var dripperOutput = ""
    @State private var dripperSpacing = ""
    @State private var efficiency = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private struct BlockIrrigationRow: Decodable {
        let flowPerEmitter: Double?
        let emitterSpacing: Double?
        let irrigationEfficiencyPercent: Double?
        enum CodingKeys: String, CodingKey {
            case flowPerEmitter = "flow_per_emitter"
            case emitterSpacing = "emitter_spacing"
            case irrigationEfficiencyPercent = "irrigation_efficiency_percent"
        }
    }

    var body: some View {
        Form {
            Section("Irrigation details") {
                LabeledContent("Dripper output") {
                    TextField("L/h", text: $dripperOutput)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Dripper spacing") {
                    TextField("m", text: $dripperSpacing)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Irrigation efficiency") {
                    TextField("%", text: $efficiency)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Text("Efficiency estimates the share of pumped water that is effectively delivered. Leave blank if unknown — VineTrack never assumes 100%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(paddockName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(isSaving || isLoading)
            }
        }
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            let provider = SupabaseClientProvider.shared
            guard provider.isConfigured else { return }
            let rows: [BlockIrrigationRow] = try await provider.client
                .from("paddocks")
                .select("flow_per_emitter, emitter_spacing, irrigation_efficiency_percent")
                .eq("id", value: paddockId.uuidString)
                .execute().value
            if let row = rows.first {
                if let v = row.flowPerEmitter { dripperOutput = String(format: "%g", v) }
                if let v = row.emitterSpacing { dripperSpacing = String(format: "%g", v) }
                if let v = row.irrigationEfficiencyPercent { efficiency = String(format: "%g", v) }
            }
        } catch {
            errorMessage = "Details could not be loaded. \(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        struct Patch: Encodable {
            let flowPerEmitter: Double?
            let emitterSpacing: Double?
            let irrigationEfficiencyPercent: Double?
            enum CodingKeys: String, CodingKey {
                case flowPerEmitter = "flow_per_emitter"
                case emitterSpacing = "emitter_spacing"
                case irrigationEfficiencyPercent = "irrigation_efficiency_percent"
            }
        }
        do {
            let provider = SupabaseClientProvider.shared
            guard provider.isConfigured else { return }
            let patch = Patch(
                flowPerEmitter: Double(dripperOutput.replacingOccurrences(of: ",", with: ".")),
                emitterSpacing: Double(dripperSpacing.replacingOccurrences(of: ",", with: ".")),
                irrigationEfficiencyPercent: Double(efficiency.replacingOccurrences(of: ",", with: ".")))
            try await provider.client
                .from("paddocks")
                .update(patch)
                .eq("id", value: paddockId.uuidString)
                .execute()
            dismiss()
        } catch {
            errorMessage = "Details could not be saved. \(error.localizedDescription)"
        }
    }
}

// MARK: - Error helper

/// Maps SQL error codes (`duplicate_name:`, `allocations_not_100:` …) to the
/// human sentence after the colon.
func friendlyIrrigationError(_ error: Error) -> String {
    let text = error.localizedDescription
    if let range = text.range(of: ": ") ,
       text.contains("_") && text.distance(from: text.startIndex, to: range.lowerBound) < 40 {
        let message = String(text[range.upperBound...])
        if !message.isEmpty { return message.prefix(1).uppercased() + message.dropFirst() }
    }
    return text
}
