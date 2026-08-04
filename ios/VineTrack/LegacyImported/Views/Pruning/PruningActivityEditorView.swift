import SwiftUI

/// MULTI-BLOCK PRUNING ACTIVITY EDITOR (sql/166).
///
/// One activity, one crew, one date, one set of labour hours — across ONE OR
/// MANY blocks. The strict split the whole feature rests on:
///
/// * ACTIVITY level, shown ONCE at the top: date, worker/crew, method, start,
///   finish, labour hours, hourly rate (where authorised), notes, linked Work
///   Task. Switching the focused block never resets or duplicates these.
/// * ALLOCATION level, per block: the rows and quarters pruned in THAT block,
///   its row equivalents and its vine estimate.
///
/// Every allocation mutation goes through `PruningAllocationEditor`, so a
/// selection in one block can never be lost by focusing another.
struct PruningActivityEditorView: View {
    let paddocks: [Paddock]
    let isEditing: Bool
    let canViewCosting: Bool
    let workTasks: [WorkTask]
    /// Reconciliation of the last server answer for THIS activity, if any.
    let reconciliation: PruningActivityReconciliation?
    let onSave: (PruningActivityDraft) -> Void
    let onReverse: (() -> Void)?
    /// Creates ONE Work Task for the whole activity and returns its canonical
    /// client id, or nil when the task could not be created. Offline the task is
    /// queued with that same id and the activity push waits for it.
    let onCreateWorkTask: ((PruningActivityDraft, PruningWorkTaskLinkDraft) -> UUID?)?

    @Environment(\.dismiss) private var dismiss
    private var pruningStore: PruningStore { .shared }

    @State private var draft: PruningActivityDraft
    @State private var showBlockPicker: Bool = false
    @State private var showReversePrompt: Bool = false
    @State private var showDiscardPrompt: Bool = false
    @State private var removeCandidate: UUID?
    @State private var labourText: String = ""
    @State private var rateText: String = ""
    @State private var recordsTimes: Bool = false
    @State private var rangeFrom: Int = 0
    @State private var rangeTo: Int = 0
    @State private var showTaskPicker: Bool = false
    @State private var taskCreateDraft: PruningWorkTaskLinkDraft?
    @State private var openTask: WorkTask?

    private let original: PruningActivityDraft

    init(
        draft: PruningActivityDraft,
        paddocks: [Paddock],
        isEditing: Bool,
        canViewCosting: Bool,
        workTasks: [WorkTask],
        reconciliation: PruningActivityReconciliation? = nil,
        onSave: @escaping (PruningActivityDraft) -> Void,
        onReverse: (() -> Void)? = nil,
        onCreateWorkTask: ((PruningActivityDraft, PruningWorkTaskLinkDraft) -> UUID?)? = nil
    ) {
        self.original = draft
        self._draft = State(initialValue: draft)
        self.paddocks = paddocks
        self.isEditing = isEditing
        self.canViewCosting = canViewCosting
        self.workTasks = workTasks
        self.reconciliation = reconciliation
        self.onSave = onSave
        self.onReverse = onReverse
        self.onCreateWorkTask = onCreateWorkTask
        self._labourText = State(initialValue: draft.labourHours.map { Self.number($0) } ?? "")
        self._rateText = State(initialValue: draft.hourlyRate.map { Self.number($0) } ?? "")
        self._recordsTimes = State(initialValue: draft.startTime != nil || draft.finishTime != nil)
    }

    private var blocksById: [UUID: Paddock] {
        Dictionary(uniqueKeysWithValues: paddocks.map { ($0.id, $0) })
    }

    /// The linked Work Task, when this device has it cached.
    private var linkedTask: WorkTask? {
        PruningWorkTaskLink.linkedTask(draft, tasks: workTasks)
    }

    /// A link this device cannot resolve yet — warned about, never cleared.
    private var hasUnresolvableLink: Bool {
        PruningWorkTaskLink.hasUnresolvableLink(draft, tasks: workTasks)
    }

    private func varietyName(of paddockId: UUID) -> String? {
        let allocations = blocksById[paddockId]?.varietyAllocations ?? []
        let top = allocations.max(by: { $0.percent < $1.percent })
        guard let name = top?.name, !name.isEmpty else { return nil }
        return name
    }

    /// One line describing the PARENT activity: its canonical season, resolved
    /// vintage, elapsed span and the labour cost of the whole job.
    private var activityFooter: String {
        var parts: [String] = ["Recorded once for the whole job — season " + String(draft.seasonYear)]
        if let vintage = draft.vintageYear {
            parts.append("Vintage " + String(vintage))
        }
        if let elapsed = draft.durationHours {
            parts.append("elapsed " + Self.number(elapsed, digits: 1) + " h")
        }
        if canViewCosting, let cost = draft.labourCost {
            parts.append("labour cost " + Self.number(cost) + " (whole activity)")
        }
        return parts.joined(separator: " · ")
    }

    private var focusedPaddock: Paddock? {
        draft.focusedPaddockId.flatMap { blocksById[$0] }
    }

    private var isDirty: Bool { draft != original }

    // MARK: Geometry helpers

    /// The rows of one block, always through the shared calculator so the grid,
    /// the vine estimate and every report agree.
    private func rows(of paddock: Paddock) -> [PruningRowRef] {
        PruningCalculator.rowRefs(paddock: paddock, setup: pruningStore.setup(for: paddock.id))
    }

    /// Quarters ALREADY completed in this block by another record. This
    /// activity's own allocations are excluded, so editing keeps its quarters
    /// selectable instead of showing them as locked.
    private func locked(in paddock: Paddock) -> Set<PruningSegment> {
        let ownIds = Set(draft.allocations.values.map { $0.allocationId(for: draft.id) })
        let others = pruningStore.entries(for: paddock.id).filter { !ownIds.contains($0.id) }
        return PruningCalculator.completedSegments(entries: others, rows: rows(of: paddock))
    }

    private func selection(in paddockId: UUID) -> Set<PruningSegment> {
        Set(draft.allocations[paddockId]?.segments ?? [])
    }

    /// Re-derives THIS block's vine estimate after any selection change.
    private func applyVines(_ next: PruningActivityDraft, paddockId: UUID) -> PruningActivityDraft {
        guard let paddock = blocksById[paddockId], let allocation = next.allocations[paddockId] else { return next }
        let vines = PruningCalculator.vines(for: allocation.segments, rows: rows(of: paddock))
        return PruningAllocationEditor.setEstimatedVines(next, paddockId: paddockId, vines: vines)
    }

    private func mutate(_ paddockId: UUID, _ transform: (PruningActivityDraft) -> PruningActivityDraft) {
        draft = applyVines(transform(draft), paddockId: paddockId)
    }

    // MARK: Body

    var body: some View {
        Form {
            if let reconciliation, reconciliation.activityId == draft.id {
                Section {
                    PruningReconciliationRow(
                        reconciliation: reconciliation,
                        blockName: { blocksById[$0]?.name ?? "Block" },
                        onOpenBlock: { paddockId in
                            draft = PruningAllocationEditor.focus(
                                draft,
                                paddockId: paddockId,
                                blockName: blocksById[paddockId]?.name ?? ""
                            )
                        }
                    )
                }
            }

            activitySection
            workTaskSection
            blocksSection
            if let focusedPaddock {
                focusedBlockSection(focusedPaddock)
            }
            summarySection
            saveSection
        }
        .navigationTitle(isEditing ? "Edit Pruning Activity" : "New Pruning Activity")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showDiscardPrompt = true }
                }
            }
            if isEditing, onReverse != nil, !draft.isReversed {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showReversePrompt = true
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .accessibilityLabel("Reverse this activity")
                }
            }
        }
        .sheet(isPresented: $showBlockPicker) {
            PruningActivityBlockPicker(blocks: paddocks, draft: draft) { paddock in
                draft = PruningAllocationEditor.focus(draft, paddockId: paddock.id, blockName: paddock.name)
            }
        }
        .sheet(isPresented: $showTaskPicker) {
            PruningWorkTaskPicker(tasks: workTasks, linkedId: draft.workTaskId) { task in
                // Only the parent's link changes — every allocation is carried
                // through untouched.
                draft = PruningWorkTaskLink.link(draft, taskId: task.id)
            }
        }
        .sheet(item: $taskCreateDraft) { pending in
            PruningWorkTaskCreateSheet(
                activity: draft,
                task: pending,
                onCreate: { confirmed in
                    // The LIVE draft is passed, so the task's date, hours and
                    // blocks match what the operator is actually recording.
                    if let created = onCreateWorkTask?(draft, confirmed) {
                        draft = PruningWorkTaskLink.link(draft, taskId: created)
                    }
                    taskCreateDraft = nil
                },
                onCancel: { taskCreateDraft = nil }
            )
        }
        // The linked task opens in a sheet, so the draft — every block and
        // quarter selection — survives the round trip untouched.
        .sheet(item: $openTask) { task in
            AddEditWorkTaskView(existingTask: task)
        }
        .alert("Remove block?", isPresented: Binding(
            get: { removeCandidate != nil },
            set: { if !$0 { removeCandidate = nil } }
        )) {
            Button("Remove block", role: .destructive) {
                if let id = removeCandidate {
                    draft = PruningAllocationEditor.removeBlock(draft, paddockId: id)
                }
                removeCandidate = nil
            }
            Button("Keep", role: .cancel) { removeCandidate = nil }
        } message: {
            Text("Only this block's rows and quarters leave the activity. The crew, hours, times and notes stay exactly as they are.")
        }
        .alert("Reverse this activity?", isPresented: $showReversePrompt) {
            Button("Reverse activity", role: .destructive) {
                onReverse?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(draft.blockSummary) — all \(draft.totalQuarters) quarters in this activity will be reopened. The record stays visible as reversed audit history.")
        }
        .alert("Discard changes?", isPresented: $showDiscardPrompt) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("This activity has unsaved changes. Discarding loses every block selection made here.")
        }
    }

    // MARK: Activity-level fields

    /// The parent activity's own fields. Rendered ONCE: labour, timing, rate,
    /// notes and the Work Task link belong to the whole job and are never
    /// apportioned or duplicated across blocks.
    private var activitySection: some View {
        Section {
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
            TextField("Worker or crew", text: $draft.worker)
            Picker("Method", selection: $draft.method) {
                ForEach(PruningMethod.allCases) { method in
                    Text(method.label).tag(method)
                }
            }
            Toggle("Record start and finish", isOn: $recordsTimes)
                .onChange(of: recordsTimes) { _, isOn in
                    if isOn {
                        if draft.startTime == nil { draft.startTime = draft.date }
                        if draft.finishTime == nil { draft.finishTime = draft.date }
                    } else {
                        draft.startTime = nil
                        draft.finishTime = nil
                    }
                }
            if recordsTimes {
                DatePicker(
                    "Start",
                    selection: Binding(
                        get: { draft.startTime ?? draft.date },
                        set: { draft.startTime = $0 }
                    ),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "Finish",
                    selection: Binding(
                        get: { draft.finishTime ?? draft.date },
                        set: { draft.finishTime = $0 }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            HStack {
                Text("Labour hours")
                Spacer()
                TextField("0", text: $labourText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .onChange(of: labourText) { _, value in
                        draft.labourHours = Double(value.replacingOccurrences(of: ",", with: "."))
                    }
            }
            if canViewCosting {
                HStack {
                    Text("Hourly rate")
                    Spacer()
                    TextField("0", text: $rateText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .onChange(of: rateText) { _, value in
                            draft.hourlyRate = Double(value.replacingOccurrences(of: ",", with: "."))
                        }
                }
            }
            TextField("Notes", text: $draft.notes, axis: .vertical)
        } header: {
            Text("This activity")
        } footer: {
            Text(activityFooter)
        }
    }

    // MARK: Work Task (activity level)

    /// The activity's Work Task link. ONE link on the parent draft
    /// (`PruningActivityDraft.workTaskId`) — never a copy on any
    /// `BlockPruningSelection` — with the full workflow the single-block editor
    /// had: create a task for this job, link an existing one, open the linked
    /// task, or unlink it. Every action only rewrites the parent's link, so block
    /// and quarter selections survive untouched.
    @ViewBuilder
    private var workTaskSection: some View {
        Section {
            if let linkedTask {
                VStack(alignment: .leading, spacing: 2) {
                    Text(linkedTask.taskType.isEmpty ? "Work task" : linkedTask.taskType)
                        .font(.subheadline.weight(.semibold))
                    Text(
                        [
                            linkedTask.date.formatted(date: .abbreviated, time: .omitted),
                            linkedTask.paddockName.isEmpty ? nil : linkedTask.paddockName,
                            Self.number(linkedTask.durationHours, digits: 1) + " h",
                            linkedTask.isFinalized ? "Completed" : nil
                        ]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button {
                    openTask = linkedTask
                } label: {
                    Label("Open task", systemImage: "arrow.up.forward.square")
                        .font(.subheadline.weight(.semibold))
                }
                Button("Change linked task") { showTaskPicker = true }
                    .font(.subheadline)
                Button("Unlink task", role: .destructive) {
                    draft = PruningWorkTaskLink.unlink(draft)
                }
                .font(.subheadline)
            } else if hasUnresolvableLink {
                // NEVER cleared silently: the link is real server state this
                // device simply hasn't pulled yet.
                Text("This activity is linked to a Work Task that hasn't reached this device yet. It stays linked — pull to refresh, or unlink deliberately.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Link another task") { showTaskPicker = true }
                    .font(.subheadline)
                Button("Unlink task", role: .destructive) {
                    draft = PruningWorkTaskLink.unlink(draft)
                }
                .font(.subheadline)
            } else {
                Text("Not linked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if onCreateWorkTask != nil {
                    Button {
                        taskCreateDraft = PruningWorkTaskLink.createDraft(draft)
                    } label: {
                        Label("Create Work Task", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                Button("Link an existing task") { showTaskPicker = true }
                    .font(.subheadline)
            }
        } header: {
            Text("Work Task")
        } footer: {
            Text("Linked once for the whole activity — the labour record covers every block below. Unlinking leaves the Work Task and its labour lines intact.")
        }
    }

    // MARK: Included blocks

    private var blocksSection: some View {
        Section {
            if draft.allocations.isEmpty {
                Text("No blocks in this activity yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.allocations.values.sorted { $0.paddockId.uuidString < $1.paddockId.uuidString }) { allocation in
                Button {
                    draft = PruningAllocationEditor.focus(
                        draft,
                        paddockId: allocation.paddockId,
                        blockName: blocksById[allocation.paddockId]?.name ?? ""
                    )
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: allocation.isEmpty ? "circle.dotted" : "checkmark.circle.fill")
                            .foregroundStyle(allocation.isEmpty ? Color.secondary : VineyardTheme.leafGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(allocation.blockName.isEmpty
                                 ? (blocksById[allocation.paddockId]?.name ?? "Block")
                                 : allocation.blockName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(allocation.isEmpty
                                 ? "Nothing selected yet"
                                 : "Rows \(PruningActivityListing.rowRangeLabel(allocation.rows)) · \(allocation.quarters) quarters")
                                .font(.caption)
                                .foregroundStyle(allocation.isEmpty ? .orange : .secondary)
                        }
                        Spacer()
                        if allocation.paddockId == draft.focusedPaddockId {
                            Text("Editing")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            Button {
                showBlockPicker = true
            } label: {
                Label("Add another block", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
        } header: {
            Text("Blocks")
        }
    }

    // MARK: Focused block

    @ViewBuilder
    private func focusedBlockSection(_ paddock: Paddock) -> some View {
        let blockRows = rows(of: paddock)
        let lockedSegments = locked(in: paddock)
        let selected = selection(in: paddock.id)
        Section {
            if blockRows.isEmpty {
                Text("\(paddock.name) has no rows yet. Map its rows, or set a manual row count in the block setup, then record against it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    Text("Rows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("From", selection: $rangeFrom) {
                        ForEach(blockRows.indices, id: \.self) { index in
                            Text(blockRows[index].label).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Text("to")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("To", selection: $rangeTo) {
                        ForEach(blockRows.indices, id: \.self) { index in
                            Text(blockRows[index].label).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer(minLength: 4)
                    Button("Select range") {
                        let a = blockRows[min(rangeFrom, blockRows.count - 1)].number
                        let b = blockRows[min(rangeTo, blockRows.count - 1)].number
                        let range = min(a, b)...max(a, b)
                        let additions = blockRows
                            .filter { range.contains($0.number) }
                            .flatMap { row in (1...4).map { row.segment(quarter: $0) } }
                            .filter { !lockedSegments.contains($0) }
                        mutate(paddock.id) {
                            PruningAllocationEditor.setSegments(
                                $0,
                                paddockId: paddock.id,
                                segments: Array(selected.union(additions)),
                                blockName: paddock.name
                            )
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 14) {
                    legendDot(VineyardTheme.leafGreen, "Done")
                    legendDot(.blue, "This activity")
                    legendDot(Color(.systemGray5), "Remaining")
                }

                ForEach(blockRows) { row in
                    quarterRow(row, paddock: paddock, locked: lockedSegments, selected: selected)
                }

                HStack {
                    Button("Clear this block") {
                        mutate(paddock.id) {
                            PruningAllocationEditor.setSegments(
                                $0,
                                paddockId: paddock.id,
                                segments: [],
                                blockName: paddock.name
                            )
                        }
                    }
                    .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Remove block from activity", role: .destructive) {
                        removeCandidate = paddock.id
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        } header: {
            HStack {
                Text(paddock.name)
                if let variety = paddock.varietyAllocations.max(by: { $0.percent < $1.percent })?.name,
                   !variety.isEmpty {
                    Text("· \(variety)")
                }
                Spacer()
                Text("\(selected.count) quarters")
            }
        } footer: {
            let blockConflicts = reconciliation?.conflicts(in: paddock.id) ?? []
            if blockConflicts.isEmpty {
                Text("Tap quarters to record what this crew pruned in \(paddock.name). Green quarters were completed by another record and stay locked.")
            } else {
                Text("\(blockConflicts.count) quarter(s) here were already recorded by another activity and were not counted: \(blockConflicts.prefix(6).map(\.label).joined(separator: ", "))")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func quarterRow(
        _ row: PruningRowRef,
        paddock: Paddock,
        locked: Set<PruningSegment>,
        selected: Set<PruningSegment>
    ) -> some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...4, id: \.self) { quarter in
                    let segment = row.segment(quarter: quarter)
                    let isLocked = locked.contains(segment)
                    let isSelected = selected.contains(segment)
                    Button {
                        guard !isLocked else { return }
                        mutate(paddock.id) {
                            PruningAllocationEditor.toggleSegment(
                                $0,
                                paddockId: paddock.id,
                                segment: segment,
                                blockName: paddock.name
                            )
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isLocked ? VineyardTheme.leafGreen : (isSelected ? Color.blue : Color(.systemGray5)))
                            .frame(height: 30)
                            .overlay {
                                if isLocked {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                } else if isSelected {
                                    Image(systemName: "scissors")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLocked)
                    .accessibilityLabel("Row \(row.label) quarter \(quarter)")
                }
            }
            Button {
                let all = (1...4).map { row.segment(quarter: $0) }.filter { !locked.contains($0) }
                let hasAll = !all.isEmpty && all.allSatisfy { selected.contains($0) }
                let next = hasAll ? selected.subtracting(all) : selected.union(all)
                mutate(paddock.id) {
                    PruningAllocationEditor.setSegments(
                        $0,
                        paddockId: paddock.id,
                        segments: Array(next),
                        blockName: paddock.name
                    )
                }
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select all of row \(row.label)")
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Summary + save

    /// Everything the activity will save, per block AND combined. Labour appears
    /// in the combined line only — never repeated per block, so no total can
    /// count it twice.
    private var summarySection: some View {
        Section {
            if draft.activeAllocations.isEmpty {
                Text("Select at least one quarter in one block to save this activity.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(draft.activeAllocations) { allocation in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(allocation.blockName.isEmpty
                             ? (blocksById[allocation.paddockId]?.name ?? "Block")
                             : allocation.blockName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Self.number(allocation.rowEquivalents)) rows")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text(
                        [
                            varietyName(of: allocation.paddockId),
                            "Rows \(PruningActivityListing.rowRangeLabel(allocation.rows))",
                            "\(allocation.quarters) quarters",
                            "\(allocation.estimatedVines) vines"
                        ]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(PruningActivityListing.blockLabel(draft.activeAllocations.map(\.blockName)))
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("\(Self.number(draft.totalRowEquivalents)) rows total")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
        } header: {
            Text("Activity summary")
        } footer: {
            Text(
                [
                    "\(draft.blockCount) block(s)",
                    "\(draft.totalQuarters) quarters",
                    "\(draft.totalEstimatedVines) vines",
                    draft.labourHours.map { "\(Self.number($0, digits: 1)) labour h recorded once for the whole activity" }
                ]
                .compactMap { $0 }
                .joined(separator: " · ")
            )
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                onSave(PruningAllocationEditor.pruneEmptyBlocks(draft))
                dismiss()
            } label: {
                Text(isEditing ? "Save changes" : "Record activity")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(VineyardTheme.leafGreen)
            .disabled(!draft.canSave)
        }
    }

    private static func number(_ value: Double, digits: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }
}

// MARK: - Block picker

/// Searchable chooser listing EVERY active block in the vineyard, with a
/// selected-state badge for blocks already included in this activity.
struct PruningActivityBlockPicker: View {
    let blocks: [Paddock]
    let draft: PruningActivityDraft
    let onSelect: (Paddock) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""

    private var results: [Paddock] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return blocks }
        return blocks.filter { paddock in
            if paddock.name.localizedStandardContains(trimmed) { return true }
            return paddock.varietyAllocations.contains { ($0.name ?? "").localizedStandardContains(trimmed) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(results) { paddock in
                        Button {
                            onSelect(paddock)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(paddock.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let variety = paddock.varietyAllocations
                                        .max(by: { $0.percent < $1.percent })?.name,
                                       !variety.isEmpty {
                                        Text(variety)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let allocation = draft.allocations[paddock.id] {
                                    Text(allocation.isEmpty ? "In activity" : "In activity · \(allocation.quarters) q")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(VineyardTheme.leafGreen)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(VineyardTheme.leafGreen.opacity(0.14), in: .capsule)
                                } else {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search blocks")
            .navigationTitle("Add a block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Work Task picker

/// Searchable picker over EVERY live Work Task of the vineyard. Selecting one
/// only changes the PARENT activity's link — no allocation is touched.
struct PruningWorkTaskPicker: View {
    let tasks: [WorkTask]
    let linkedId: UUID?
    let onSelect: (WorkTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""

    private var results: [WorkTask] {
        PruningWorkTaskLink.search(tasks, query: search)
    }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView(
                            "No Work Tasks",
                            systemImage: "checklist",
                            description: Text("This vineyard has no Work Tasks yet. Create one from the pruning activity instead.")
                        )
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                } else {
                    ForEach(results) { task in
                        Button {
                            onSelect(task)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.taskType.isEmpty ? "Work task" : task.taskType)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(
                                        [
                                            task.date.formatted(date: .abbreviated, time: .omitted),
                                            task.paddockName.isEmpty ? nil : task.paddockName,
                                            task.durationHours
                                                .formatted(.number.precision(.fractionLength(0...1))) + " h"
                                        ]
                                        .compactMap { $0 }
                                        .joined(separator: " · ")
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if task.id == linkedId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(VineyardTheme.leafGreen)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search work type, block or date")
            .navigationTitle("Link a Work Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Creates ONE completed Work Task for the whole activity. Date, duration and
/// blocks come from the activity itself, so the shared labour is recorded once
/// and never apportioned per block.
struct PruningWorkTaskCreateSheet: View {
    let activity: PruningActivityDraft
    let onCreate: (PruningWorkTaskLinkDraft) -> Void
    let onCancel: () -> Void

    @State private var task: PruningWorkTaskLinkDraft

    init(
        activity: PruningActivityDraft,
        task: PruningWorkTaskLinkDraft,
        onCreate: @escaping (PruningWorkTaskLinkDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.activity = activity
        self._task = State(initialValue: task)
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    /// What the created task will record — all of it taken from the activity, so
    /// the shared labour is stored once and never apportioned per block.
    private var activitySummary: String {
        let dateText = activity.date.formatted(date: .abbreviated, time: .omitted)
        let hours = PruningWorkTaskLink.durationHours(activity)
        let hoursText = hours.formatted(.number.precision(.fractionLength(0...1)))
        let blocks: String = activity.blockSummary.isEmpty ? "no blocks yet" : activity.blockSummary
        let head = "One task for this whole activity: \(dateText) · \(hoursText) h · \(blocks)."
        return head + " Linked to this activity with a stable id, so an offline retry can never create a second task."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Work type", text: $task.taskType)
                    TextField("Task notes", text: $task.notes, axis: .vertical)
                    Toggle("Mark completed", isOn: $task.markCompleted)
                } header: {
                    Text("New Work Task")
                } footer: {
                    Text(activitySummary)
                }
            }
            .navigationTitle("Create Work Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { onCreate(task) }
                        .font(.body.weight(.semibold))
                        .disabled(!task.isValid)
                }
            }
        }
    }
}

// MARK: - Reconciliation

/// The server's reconciliation of the last save. A save with refused quarters is
/// never presented as fully successful: the user is told exactly what landed and
/// can open the affected block to review the conflicting quarters.
struct PruningReconciliationRow: View {
    let reconciliation: PruningActivityReconciliation
    let blockName: (UUID) -> String
    var onOpenBlock: ((UUID) -> Void)?
    var onDismiss: (() -> Void)?

    private var tint: Color { reconciliation.hasConflicts ? .orange : VineyardTheme.leafGreen }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: reconciliation.hasConflicts
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.seal.fill")
                    .foregroundStyle(tint)
                Text(reconciliation.headline)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .font(.caption.weight(.semibold))
                }
            }
            Text(reconciliation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let season = reconciliation.seasonYear {
                Text("Filed under \(String(season)) Winter Pruning" +
                     (reconciliation.vintageYear.map { " · Vintage \(String($0))" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if reconciliation.hasConflicts, let onOpenBlock {
                ForEach(reconciliation.conflictBlockIds, id: \.self) { paddockId in
                    let quarters = reconciliation.conflicts(in: paddockId)
                    Button {
                        onOpenBlock(paddockId)
                    } label: {
                        Text("Review \(blockName(paddockId)) (\(quarters.count)): " +
                             quarters.prefix(4).map(\.label).joined(separator: ", ") +
                             (quarters.count > 4 ? "…" : ""))
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
    }
}
