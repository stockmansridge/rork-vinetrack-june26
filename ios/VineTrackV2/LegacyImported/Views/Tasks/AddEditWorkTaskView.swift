import SwiftUI

struct AddEditWorkTaskView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(WorkTaskSyncService.self) private var workTaskSync
    @Environment(WorkTaskTypeSyncService.self) private var workTaskTypeSync
    @Environment(WorkTaskPaddockSyncService.self) private var workTaskPaddockSync
    @Environment(WorkTaskMachineLineSyncService.self) private var workTaskMachineLineSync
    @Environment(TripSyncService.self) private var tripSync
    @Environment(PaddockSyncService.self) private var paddockSync
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let existingTask: WorkTask?

    @State private var date: Date = Date()
    @State private var taskType: String = ""
    @State private var customTaskType: String = ""
    @State private var showCustomTaskField: Bool = false
    @State private var selectedBlockIds: Set<UUID> = []
    @State private var showBlockPicker: Bool = false
    @State private var durationText: String = ""
    @State private var notes: String = ""
    @State private var resources: [WorkTaskResource] = []
    @State private var showDelete: Bool = false
    @State private var showWorkerTypes: Bool = false
    @State private var showAddMachineLine: Bool = false
    @State private var editingMachineLine: WorkTaskMachineLine?
    @State private var showLinkTripPicker: Bool = false
    @State private var tripToUnlink: Trip?

    init(existingTask: WorkTask? = nil) {
        self.existingTask = existingTask
    }

    private var isEditing: Bool { existingTask != nil }
    private var canDelete: Bool { accessControl?.canDelete ?? false }

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var tz: TimeZone { store.settings.resolvedTimeZone }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    private var durationHours: Double {
        Double(durationText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var totalPeople: Int { resources.reduce(0) { $0 + $1.count } }

    /// Active blocks/paddocks for the selected vineyard, loaded from the same
    /// offline-first store every other screen uses. Works fully offline once
    /// the vineyard/block data has previously synced.
    private var assignableBlocks: [Paddock] {
        store.orderedPaddocks
    }

    /// Selected blocks, returned in the same stable order as the assignable
    /// list so backward-compat fields and breakdowns are deterministic.
    private var selectedBlocksOrdered: [Paddock] {
        assignableBlocks.filter { selectedBlockIds.contains($0.id) }
    }

    /// Collapsed picker label per the multi-select rules.
    private var blockCollapsedLabel: String {
        let selected = selectedBlocksOrdered
        if selected.isEmpty { return "Does not apply to a \(fmt.blockTerm)" }
        if selected.count == 1 { return selected[0].name }
        return "\(selected.count) \(fmt.blockTermPlural) selected"
    }

    /// Block area (ha) only when known/positive; nil otherwise.
    private func areaFor(_ p: Paddock) -> Double? {
        let a = p.areaHectares
        return a > 0 ? a : nil
    }

    /// Sum of known selected block areas.
    private var totalSelectedArea: Double {
        selectedBlocksOrdered.compactMap { areaFor($0) }.reduce(0, +)
    }

    private var hasMissingArea: Bool {
        selectedBlocksOrdered.contains { areaFor($0) == nil }
    }

    /// Per-block hours/cost allocation proportional to block area.
    private var blockAllocations: [BlockAllocation] {
        let total = totalSelectedArea
        return selectedBlocksOrdered.map { p in
            let area = areaFor(p)
            let share = (total > 0 && area != nil) ? (area! / total) : 0
            let cost = totalCost * share
            let cph: Double? = (area ?? 0) > 0 ? cost / area! : nil
            return BlockAllocation(
                id: p.id,
                name: p.name,
                areaHa: area,
                pctOfTotal: share,
                allocatedHours: durationHours * share,
                allocatedCost: cost,
                costPerHa: cph
            )
        }
    }

    /// Vineyard-scoped catalog merged with the built-in defaults. Drives the
    /// Task Type picker so Lovable-created custom types appear alongside the
    /// existing iOS defaults.
    private var mergedTaskTypeNames: [String] {
        let vineyardId = store.selectedVineyardId
        let scoped = store.workTaskTypes.filter { vineyardId == nil || $0.vineyardId == vineyardId }
        return WorkTaskTypeCatalog.merged(with: scoped)
    }

    private var totalCost: Double {
        resources.reduce(0.0) { $0 + ($1.hourlyRate * durationHours * Double($1.count)) }
    }

    private var costPerPerson: Double {
        guard totalPeople > 0 else { return 0 }
        return totalCost / Double(totalPeople)
    }

    /// Manual machine/tractor work lines recorded under this task (when no GPS
    /// trip exists). Only available once the task has been saved.
    private var machineLines: [WorkTaskMachineLine] {
        guard let id = existingTask?.id else { return [] }
        return store.workTaskMachineLines
            .filter { $0.workTaskId == id }
            .sorted { $0.workDate > $1.workDate }
    }

    // MARK: - Operational summary (read-only)

    /// Labour hours = the task duration entered on this form.
    private var labourHours: Double { durationHours }

    /// Manual machine entries recorded under this task (non-deleted lines are
    /// already the only ones kept in the store).
    private var manualMachineCount: Int { machineLines.count }

    /// Manual machine hours, mirroring Lovable's formula: prefer the explicit
    /// duration, otherwise fall back to engine hours used.
    private var manualMachineHours: Double {
        machineLines.reduce(0.0) { $0 + ($1.durationHours ?? $1.engineHoursUsed ?? 0) }
    }

    /// Successful GPS trips grouped under this task via `trips.work_task_id`.
    private var linkedTripCount: Int {
        guard let id = existingTask?.id else { return 0 }
        return store.trips.filter { $0.workTaskId == id }.count
    }

    /// Manual machine charge = sum of explicit total machine cost where present.
    private var manualMachineCharge: Double {
        machineLines.reduce(0.0) { $0 + ($1.totalMachineCost ?? 0) }
    }

    /// Manual machine fuel cost = sum of explicit fuel cost where present.
    private var manualMachineFuel: Double {
        machineLines.reduce(0.0) { $0 + ($1.fuelCost ?? 0) }
    }

    /// Estimated cost of linked GPS trips, summed from already-synced
    /// `trip_cost_allocations`. Available client-side, so no deferral needed.
    private var linkedTripCost: Double {
        guard let id = existingTask?.id else { return 0 }
        let linkedTripIds = Set(store.trips.filter { $0.workTaskId == id }.map { $0.id })
        guard !linkedTripIds.isEmpty else { return 0 }
        return store.tripCostAllocations
            .filter { linkedTripIds.contains($0.tripId) }
            .reduce(0.0) { $0 + ($1.totalCost ?? 0) }
    }

    /// Combined total across manual labour, manual machine charge + fuel, and
    /// linked GPS trip cost. Manual entries and trips are distinct sources, so
    /// they sum without double-counting.
    private var combinedTotalCost: Double {
        totalCost + manualMachineCharge + manualMachineFuel + linkedTripCost
    }

    /// Successful GPS trips grouped under this task, newest first. Reads the
    /// live store slice so the list refreshes as soon as a link/unlink applies.
    private var linkedTrips: [Trip] {
        guard let id = existingTask?.id else { return [] }
        return store.trips
            .filter { $0.workTaskId == id }
            .sorted { $0.startTime > $1.startTime }
    }

    /// Completed trips in the selected vineyard not yet linked to any Work Task.
    /// `store.trips` is already scoped to the selected vineyard.
    private var eligibleTripsForLinking: [Trip] {
        store.trips
            .filter { $0.workTaskId == nil && !$0.isActive }
            .sorted { $0.startTime > $1.startTime }
    }

    /// Estimated cost for a linked trip, summed from already-synced
    /// `trip_cost_allocations`. Returns nil when no allocation data exists
    /// client-side (never invents a cost).
    private func allocatedCost(for trip: Trip) -> Double? {
        let allocs = store.tripCostAllocations.filter { $0.tripId == trip.id }
        guard !allocs.isEmpty else { return nil }
        return allocs.reduce(0.0) { $0 + ($1.totalCost ?? 0) }
    }

    // MARK: - Duplicate-risk detection (operational data-quality warning)

    /// Manual entry sources that describe machine work which may also have been
    /// captured as a GPS trip (missed/failed tracking, or a manual correction).
    private static let overlapEntrySources: Set<String> = [
        "missed_trip", "trip_failed", "correction"
    ]

    /// Non-deleted manual machine lines whose entry source indicates they may
    /// overlap with a linked GPS trip. `machineLines` already excludes deleted.
    private var overlapCandidateLines: [WorkTaskMachineLine] {
        machineLines.filter { Self.overlapEntrySources.contains($0.entrySource) }
    }

    /// v1: the task has at least one linked GPS trip AND at least one manual
    /// correction/missed/failed machine line — they may describe the same work.
    private var hasDuplicateRisk: Bool {
        linkedTripCount > 0 && !overlapCandidateLines.isEmpty
    }

    /// Stronger signal: a candidate line shares its work date with a linked
    /// trip AND the equipment appears to match (same ref id, same legacy
    /// tractor) or neither side has a reliable equipment link.
    private var hasStrongDuplicateRisk: Bool {
        guard hasDuplicateRisk else { return false }
        let cal = Calendar.current
        for line in overlapCandidateLines {
            for trip in linkedTrips where cal.isDate(line.workDate, inSameDayAs: trip.startTime) {
                if equipmentLikelyMatches(line: line, trip: trip) { return true }
            }
        }
        return false
    }

    /// Conservative equipment match: identical stable ref, the line's ref maps
    /// to the trip's machine/legacy tractor, or both sides lack any reliable
    /// equipment link (so we cannot rule the overlap out).
    private func equipmentLikelyMatches(line: WorkTaskMachineLine, trip: Trip) -> Bool {
        let lineRef = line.equipmentRefId
        let tripHasEquipment = trip.machineId != nil || trip.tractorId != nil
        if let lineRef {
            if lineRef == trip.machineId || lineRef == trip.tractorId { return true }
            return false
        }
        // Line has no stable equipment link; treat as a possible match only when
        // the trip also lacks one (otherwise we can rule the overlap out).
        return !tripHasEquipment
    }

    private func entrySourceLabel(_ raw: String) -> String {
        switch raw {
        case "missed_trip": return "Missed trip"
        case "trip_failed": return "Trip failed"
        case "correction": return "Correction"
        default: return "Manual entry"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task Details") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)

                    Menu {
                        ForEach(mergedTaskTypeNames, id: \.self) { t in
                            Button(t) {
                                taskType = t
                                showCustomTaskField = false
                            }
                        }
                        Divider()
                        Button {
                            showCustomTaskField = true
                            taskType = customTaskType
                        } label: {
                            Label("Custom…", systemImage: "pencil")
                        }
                    } label: {
                        HStack {
                            Text("Task Type")
                            Spacer()
                            Text(taskType.isEmpty ? "Select" : taskType)
                                .foregroundStyle(taskType.isEmpty ? .secondary : .primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if showCustomTaskField {
                        TextField("Custom task name", text: $customTaskType)
                            .onChange(of: customTaskType) { _, v in taskType = v }
                    }

                    Button {
                        showBlockPicker = true
                    } label: {
                        HStack {
                            Text(fmt.blockTermCapitalised)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(blockCollapsedLabel)
                                .foregroundStyle(selectedBlockIds.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    HStack {
                        Text("Duration (hours)")
                        Spacer()
                        TextField("0", text: $durationText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                Section {
                    if resources.isEmpty {
                        Text("No workers added")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($resources) { $res in
                            resourceRow($res)
                        }
                        .onDelete { idx in
                            resources.remove(atOffsets: idx)
                        }
                    }
                    Button {
                        addResource()
                    } label: {
                        Label("Add Worker Type", systemImage: "plus.circle.fill")
                    }
                    .disabled(store.operatorCategories.isEmpty)
                    if store.operatorCategories.isEmpty {
                        Text("Add worker types in Settings → Worker Types first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Resources")
                        Spacer()
                        Button {
                            showWorkerTypes = true
                        } label: {
                            Label("Edit", systemImage: "square.and.pencil")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    Text("Set the number of workers of each type used on this task.")
                }

                if accessControl?.canViewFinancials ?? false {
                    Section("Estimated Cost") {
                        LabeledContent("Total People") {
                            Text("\(totalPeople)")
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Cost / Person") {
                            Text(fmt.formatCurrency(costPerPerson))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("\(fmt.blockTermCapitalised) Total")
                                .font(.headline)
                            Spacer()
                            Text(fmt.formatCurrency(totalCost))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section("Task Summary") {
                        LabeledContent("Total People") {
                            Text("\(totalPeople)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if selectedBlockIds.count > 1 {
                    Section("\(fmt.blockTermCapitalised) Breakdown") {
                        if hasMissingArea {
                            Label("One or more selected blocks are missing area, so the cost per hectare breakdown may be incomplete.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ForEach(blockAllocations) { alloc in
                            blockAllocationRow(alloc)
                        }
                        LabeledContent("Total Area") {
                            Text(totalSelectedArea > 0 ? fmt.formatArea(hectares: totalSelectedArea) : "—")
                                .foregroundStyle(.secondary)
                        }
                        if (accessControl?.canViewFinancials ?? false) && totalSelectedArea > 0 {
                            LabeledContent("Cost / \(fmt.areaUnitAbbreviation)") {
                                Text("\(fmt.formatCurrency((totalCost / totalSelectedArea) / fmt.areaValue(hectares: 1)))/\(fmt.areaUnitAbbreviation)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                operationalSummarySection

                linkedTripsSection

                machineWorkSection

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
                                Label("Delete Task", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Task" : "New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if let task = existingTask {
                    ToolbarItem(placement: .principal) {
                        RecordSyncBadge(state: .forWorkTask(task.id, taskSync: workTaskSync))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTask() }
                        .fontWeight(.semibold)
                        .disabled(taskType.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Delete Task", isPresented: $showDelete) {
                Button("Delete", role: .destructive) {
                    if let t = existingTask {
                        store.deleteWorkTask(t.id)
                        Task { await workTaskSync.syncForSelectedVineyard() }
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear(perform: loadIfEditing)
            .sheet(isPresented: $showBlockPicker) {
                BlockMultiSelectSheet(blocks: assignableBlocks, selected: $selectedBlockIds)
            }
            .sheet(isPresented: $showLinkTripPicker) {
                LinkTripPickerSheet(
                    trips: eligibleTripsForLinking,
                    tz: tz,
                    store: store,
                    onSelect: { link($0) }
                )
            }
            .confirmationDialog(
                "Unlink this trip from the task?",
                isPresented: Binding(
                    get: { tripToUnlink != nil },
                    set: { if !$0 { tripToUnlink = nil } }
                ),
                presenting: tripToUnlink
            ) { trip in
                Button("Unlink Trip", role: .destructive) {
                    unlink(trip)
                    tripToUnlink = nil
                }
                Button("Cancel", role: .cancel) { tripToUnlink = nil }
            } message: { _ in
                Text("The trip is kept. Only its link to this task is removed.")
            }
            .sheet(isPresented: $showAddMachineLine) {
                if let id = existingTask?.id, let vid = store.selectedVineyardId {
                    AddEditWorkTaskMachineLineView(workTaskId: id, vineyardId: vid)
                }
            }
            .sheet(item: $editingMachineLine) { line in
                AddEditWorkTaskMachineLineView(workTaskId: line.workTaskId, vineyardId: line.vineyardId, existingLine: line)
            }
            .sheet(isPresented: $showWorkerTypes) {
                NavigationStack {
                    OperatorCategoriesView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showWorkerTypes = false }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var operationalSummarySection: some View {
        Section {
            LabeledContent("Labour Hours") {
                Text(String(format: "%.1fh", labourHours))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Manual Machine Entries") {
                Text("\(manualMachineCount)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Manual Machine Hours") {
                Text(String(format: "%.1fh", manualMachineHours))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Linked GPS Trips") {
                Text("\(linkedTripCount)")
                    .foregroundStyle(.secondary)
            }

            if accessControl?.canViewFinancials ?? false {
                LabeledContent("Manual Labour Cost") {
                    Text(fmt.formatCurrency(totalCost))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Manual Machine Charge") {
                    Text(fmt.formatCurrency(manualMachineCharge))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Manual Machine Fuel") {
                    Text(fmt.formatCurrency(manualMachineFuel))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Linked GPS Trip Cost") {
                    Text(fmt.formatCurrency(linkedTripCost))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Combined Total")
                        .font(.headline)
                    Spacer()
                    Text(fmt.formatCurrency(combinedTotalCost))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
                .padding(.vertical, 4)
            }
            if hasDuplicateRisk {
                duplicateRiskNotice
            }
        } header: {
            Text("Work Task Summary")
        } footer: {
            Text("Manual entries are shown separately from linked GPS trip costs.")
        }
    }

    /// Soft, non-blocking operational warning shown to all users when linked
    /// GPS trips and manual correction/missed machine entries may overlap.
    @ViewBuilder
    private var duplicateRiskNotice: some View {
        Label {
            Text(hasStrongDuplicateRisk
                 ? "Review: a linked GPS trip and a manual correction/missed machine entry share the same date and equipment — they may double-count the same work."
                 : "Review: linked GPS trips and manual correction/missed machine entries may overlap.")
                .font(.caption)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var linkedTripsSection: some View {
        Section {
            if !isEditing {
                Text("Save this task first to link GPS trips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if linkedTrips.isEmpty {
                    Text("No GPS trips linked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(linkedTrips) { trip in
                        linkedTripRow(trip)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    tripToUnlink = trip
                                } label: {
                                    Label("Unlink", systemImage: "link.badge.minus")
                                }
                            }
                    }
                }
                Button {
                    showLinkTripPicker = true
                } label: {
                    Label("Link Trip", systemImage: "link")
                }
            }
        } header: {
            Text("Linked GPS Trips")
        } footer: {
            Text("Group successful GPS trips under this task. Linking does not change trip paths or costs.")
        }
    }

    @ViewBuilder
    private func linkedTripRow(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trip.displayFunctionLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(trip.startTime.formattedTZ(date: .abbreviated, time: .shortened, in: tz))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Label(WorkTaskTripFormat.duration(trip.activeDuration), systemImage: "clock")
                Label(WorkTaskTripFormat.machineName(trip, store: store), systemImage: "gearshape")
                    .lineLimit(1)
                if canViewFinancials, let cost = allocatedCost(for: trip) {
                    Text(fmt.formatCurrency(cost))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func link(_ trip: Trip) {
        guard let taskId = existingTask?.id else { return }
        Task { await tripSync.setWorkTaskLink(tripId: trip.id, workTaskId: taskId) }
    }

    private func unlink(_ trip: Trip) {
        Task { await tripSync.setWorkTaskLink(tripId: trip.id, workTaskId: nil) }
    }

    @ViewBuilder
    private var machineWorkSection: some View {
        Section {
            if !isEditing {
                Text("Save this task first to add manual machine or tractor work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if machineLines.isEmpty {
                    Text("No machine work recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(machineLines) { line in
                        Button {
                            editingMachineLine = line
                        } label: {
                            machineLineRow(line)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteMachineLines)
                }
                Button {
                    showAddMachineLine = true
                } label: {
                    Label("Add Machine Work", systemImage: "plus.circle.fill")
                }
            }
        } header: {
            Text("Manual Machine Work")
        } footer: {
            Text("Record machine or tractor work entered manually when no GPS trip exists, or when tracking was missed or failed.")
        }
    }

    @ViewBuilder
    private func machineLineRow(_ line: WorkTaskMachineLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(machineLineName(line))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(fmt.formatDate(line.workDate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text(entrySourceLabel(line.entrySource))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                if let d = line.durationHours, d > 0 {
                    Label(String(format: "%.1fh", d), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let e = line.engineHoursUsed, e > 0 {
                    Label(String(format: "%.1f", e), systemImage: "gauge.with.dots.needle.bottom.50percent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func machineLineName(_ line: WorkTaskMachineLine) -> String {
        let resolved = store.resolvedMachineLineEquipmentName(line)
        return resolved.isEmpty ? "Unknown equipment" : resolved
    }

    private func deleteMachineLines(at offsets: IndexSet) {
        let lines = machineLines
        for index in offsets {
            guard lines.indices.contains(index) else { continue }
            store.deleteWorkTaskMachineLine(lines[index].id)
        }
        Task { await workTaskMachineLineSync.syncForSelectedVineyard() }
    }

    @ViewBuilder
    private func blockAllocationRow(_ alloc: BlockAllocation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(alloc.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(alloc.areaHa.map { fmt.formatArea(hectares: $0) } ?? "— \(fmt.areaUnitAbbreviation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("\(Int((alloc.pctOfTotal * 100).rounded()))%")
                Text(String(format: "%.1fh", alloc.allocatedHours))
                if accessControl?.canViewFinancials ?? false {
                    Text(fmt.formatCurrency(alloc.allocatedCost))
                    if let cph = alloc.costPerHa {
                        Text("\(fmt.formatCurrency(cph / fmt.areaValue(hectares: 1)))/\(fmt.areaUnitAbbreviation)")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func resourceRow(_ res: Binding<WorkTaskResource>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(store.operatorCategories) { cat in
                    Button(cat.name) {
                        res.wrappedValue.operatorCategoryId = cat.id
                        res.wrappedValue.workerTypeName = cat.name
                        res.wrappedValue.hourlyRate = cat.costPerHour
                    }
                }
            } label: {
                HStack {
                    Text(res.wrappedValue.workerTypeName.isEmpty ? "Select worker type" : res.wrappedValue.workerTypeName)
                        .foregroundStyle(res.wrappedValue.workerTypeName.isEmpty ? .secondary : .primary)
                    Spacer()
                    if accessControl?.canViewFinancials ?? false {
                        Text(fmt.formatCurrency(res.wrappedValue.hourlyRate))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Count")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper(value: res.count, in: 1...99) {
                    Text("\(res.wrappedValue.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .labelsHidden()
                Text("\(res.wrappedValue.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(width: 28)
            }
        }
        .padding(.vertical, 4)
    }

    private func addResource() {
        guard let first = store.operatorCategories.first else { return }
        resources.append(WorkTaskResource(
            operatorCategoryId: first.id,
            workerTypeName: first.name,
            hourlyRate: first.costPerHour,
            count: 1
        ))
    }

    /// Emits a diagnostic when the selected vineyard has no assignable blocks
    /// in the local store so we can tell whether the data simply hasn't synced
    /// yet versus a filtering bug. Read-only; never blocks the form.
    private func logBlockPickerDiagnosticsIfEmpty() {
        guard assignableBlocks.isEmpty else { return }
        #if DEBUG
        let allLocal: Int = store.paddocks.count
        let lastSync = paddockSync.lastSyncDate.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        let roleHint = "manageSetup=\(accessControl?.canManageSetup ?? false) delete=\(accessControl?.canDelete ?? false)"
        print("""
        [WorkTask] block picker has no assignable blocks \
        vineyardId=\(store.selectedVineyardId?.uuidString ?? "nil") \
        localPaddocks=\(allLocal) \
        afterActiveFilter=\(assignableBlocks.count) \
        role=\(roleHint) \
        syncStatus=\(String(describing: paddockSync.syncStatus)) lastSync=\(lastSync)
        """)
        #endif
    }

    private func loadIfEditing() {
        logBlockPickerDiagnosticsIfEmpty()
        if let t = existingTask {
            date = t.date
            taskType = t.taskType
            if !mergedTaskTypeNames.contains(t.taskType) && !t.taskType.isEmpty {
                showCustomTaskField = true
                customTaskType = t.taskType
            }
            // Prefer existing work_task_paddocks join rows for the selected
            // block set; fall back to the legacy single paddock_id when no join
            // rows exist. Works fully offline once paddock data has synced.
            let links = store.workTaskPaddocks.filter { $0.workTaskId == t.id }
            if !links.isEmpty {
                selectedBlockIds = Set(links.map { $0.paddockId })
            } else if let pid = t.paddockId {
                selectedBlockIds = [pid]
            } else {
                selectedBlockIds = []
            }
            durationText = t.durationHours > 0 ? String(format: "%.2f", t.durationHours) : ""
            notes = t.notes
            resources = t.resources
        }
    }

    private func saveTask() {
        let trimmed = taskType.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // If the user entered a custom task type that is not in the merged
        // catalog yet, persist it to work_task_types so it syncs to other
        // devices and Lovable.
        let lower = trimmed.lowercased()
        let knownLower = Set(mergedTaskTypeNames.map { $0.lowercased() })
        if !knownLower.contains(lower), let vineyardId = store.selectedVineyardId {
            store.addWorkTaskType(WorkTaskType(
                vineyardId: vineyardId,
                name: trimmed,
                isDefault: false,
                sortOrder: 0
            ))
        }

        // Backward-compat scalar fields: first selected block id, and a
        // comma-separated list of selected block names. Empty when no block.
        let orderedSelected = selectedBlocksOrdered
        let primaryBlockId = orderedSelected.first?.id
        let blockNames = orderedSelected.map { $0.name }.joined(separator: ", ")

        var task = existingTask ?? WorkTask()
        task.date = date
        task.taskType = trimmed
        task.paddockId = primaryBlockId
        task.paddockName = blockNames
        task.durationHours = durationHours
        task.resources = resources
        task.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = auth.userName ?? ""
        task.createdBy = userName.isEmpty ? nil : userName

        // Auto-populate area (hectares) from the selected block so portal
        // reports can show hectares without the operator entering them.
        // Portal-created tasks persist `area_ha` directly; iPhone-created
        // tasks now match by deriving it from the linked block. The block ID
        // is still synced (`paddock_id`) so the portal can re-derive if needed.
        var areaSource = "none"
        let summedArea = totalSelectedArea
        if summedArea > 0 {
            task.areaHa = summedArea
            areaSource = orderedSelected.count > 1 ? "summed-from-blocks" : "derived-from-block"
        } else if orderedSelected.isEmpty, task.areaHa != nil {
            // No block selected (Does not apply to a block) — keep existing value.
            areaSource = "existing"
        } else if task.areaHa != nil {
            areaSource = "existing"
        }

        #if DEBUG
        print("""
        [WorkTask] saveTask id=\(task.id) type=\(task.taskType) \
        blockId=\(task.paddockId?.uuidString ?? "nil") \
        block=\(task.paddockName.isEmpty ? "<none>" : task.paddockName) \
        areaHa=\(task.areaHa.map { String(format: "%.4f", $0) } ?? "nil") \
        areaSource=\(areaSource)
        """)
        #endif

        if isEditing {
            store.updateWorkTask(task)
        } else {
            store.addWorkTask(task)
        }

        reconcileBlockLinks(for: task.id)

        Task {
            await workTaskTypeSync.syncForSelectedVineyard()
            await workTaskSync.syncForSelectedVineyard()
            await workTaskPaddockSync.syncForSelectedVineyard()
        }
        dismiss()
    }

    /// Reconciles work_task_paddocks join rows against the selected block set:
    /// inserts newly selected blocks, refreshes area snapshots for still-selected
    /// blocks, and removes (soft-deletes via sync) blocks that were deselected.
    private func reconcileBlockLinks(for taskId: UUID) {
        guard let vineyardId = store.selectedVineyardId else { return }
        let existing = store.workTaskPaddocks.filter { $0.workTaskId == taskId }
        let existingByPaddock = Dictionary(existing.map { ($0.paddockId, $0) }, uniquingKeysWith: { a, _ in a })

        // Remove links no longer selected.
        for link in existing where !selectedBlockIds.contains(link.paddockId) {
            store.deleteWorkTaskPaddock(link.id)
        }

        // Insert or update selected links with an area snapshot.
        for pid in selectedBlockIds {
            let area = store.paddocks.first(where: { $0.id == pid }).flatMap { areaFor($0) }
            if var row = existingByPaddock[pid] {
                if row.areaHa != area {
                    row.areaHa = area
                    store.updateWorkTaskPaddock(row)
                }
            } else {
                store.addWorkTaskPaddock(WorkTaskPaddock(
                    workTaskId: taskId,
                    vineyardId: vineyardId,
                    paddockId: pid,
                    areaHa: area
                ))
            }
        }
    }
}

/// Per-block hours/cost allocation used by the breakdown section.
private struct BlockAllocation: Identifiable {
    let id: UUID
    let name: String
    let areaHa: Double?
    let pctOfTotal: Double
    let allocatedHours: Double
    let allocatedCost: Double
    let costPerHa: Double?
}

/// Multi-select block picker presented as a sheet. Selecting “Does not apply
/// to a block” clears the set; selecting any block clears the no-block state.
private struct BlockMultiSelectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let blocks: [Paddock]
    @Binding var selected: Set<UUID>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selected.removeAll()
                    } label: {
                        HStack {
                            Text("Does not apply to a block")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selected.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }

                if blocks.isEmpty {
                    Section {
                        Text("No blocks available for this vineyard yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Blocks") {
                        ForEach(blocks) { p in
                            Button {
                                toggle(p.id)
                            } label: {
                                HStack {
                                    Text(p.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selected.contains(p.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Blocks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}

/// Shared formatting helpers for the linked-trip rows in the Work Task editor
/// and the link picker, so both surfaces resolve names/durations identically.
enum WorkTaskTripFormat {
    /// Friendly duration using "min" (never "m") per the regional convention.
    /// Delegates to the shared `RegionFormatter` duration formatter.
    static func duration(_ seconds: TimeInterval) -> String {
        RegionFormatter.formatDuration(seconds: seconds)
    }

    /// Resolve a trip's machine/tractor display name, preferring the linked
    /// vineyard machine, then the legacy tractor, with a safe fallback.
    static func machineName(_ trip: Trip, store: MigratedDataStore) -> String {
        store.equipmentResolver.tripMachineName(trip)
    }
}

/// Lightweight picker listing completed, unlinked GPS trips for the selected
/// vineyard so the user can attach one to the current Work Task.
private struct LinkTripPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let trips: [Trip]
    let tz: TimeZone
    let store: MigratedDataStore
    let onSelect: (Trip) -> Void
    @State private var search: String = ""

    private var filtered: [Trip] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return trips }
        return trips.filter {
            $0.displayFunctionLabel.lowercased().contains(query)
            || $0.paddockName.lowercased().contains(query)
            || WorkTaskTripFormat.machineName($0, store: store).lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if trips.isEmpty {
                    Text("No eligible trips. Active trips and trips already linked to another task are not shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { trip in
                        Button {
                            onSelect(trip)
                            dismiss()
                        } label: {
                            tripRow(trip)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search trips")
            .navigationTitle("Link Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func tripRow(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trip.displayFunctionLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(trip.startTime.formattedTZ(date: .abbreviated, time: .shortened, in: tz))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Label(WorkTaskTripFormat.duration(trip.activeDuration), systemImage: "clock")
                Label(WorkTaskTripFormat.machineName(trip, store: store), systemImage: "gearshape")
                    .lineLimit(1)
                if !trip.paddockName.isEmpty {
                    Label(trip.paddockName, systemImage: "leaf")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
