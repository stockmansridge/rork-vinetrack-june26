import SwiftUI

/// Row-quarter progress screen for one block: tap quarters (or select a row
/// range), then "Record Pruning" records an entry with crew and hours — and
/// can optionally create one linked, completed Work Task in the same flow.
struct PruningBlockDetailView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    let paddock: Paddock
    let pruningStore: PruningStore
    /// Deep link from the Pruning Activity Report: open with this entry
    /// already in edit mode so the report reuses THIS edit flow and its RPC
    /// rather than introducing a second editing path.
    var initialEditEntryId: UUID?

    @State private var selectedSegments: Set<PruningSegment> = []
    @State private var showEntrySheet: Bool = false
    @State private var showSetupSheet: Bool = false
    @State private var rangeFromIndex: Int = 0
    @State private var rangeToIndex: Int = 0
    @State private var entryPendingReversal: PruningEntry?
    @State private var linkedTask: WorkTask?
    /// Entry being edited — its own quarters unlock in the grid so the user
    /// can add/remove/replace them before saving through the edit form.
    @State private var editingEntry: PruningEntry?

    private var setup: PruningBlockSetup? { pruningStore.setup(for: paddock.id) }
    private var entries: [PruningEntry] { pruningStore.entries(for: paddock.id) }
    private var metrics: PruningBlockMetrics {
        PruningCalculator.metrics(paddock: paddock, setup: setup, entries: entries)
    }

    /// The block's ACTUAL rows (configured paddock rows in stored order, or
    /// clearly-labelled fallback rows generated from the manual row count).
    private var rows: [PruningRowRef] { metrics.rows }

    /// The editing entry's quarters canonicalised onto the block's rows.
    private var editingSegments: Set<PruningSegment> {
        guard let editingEntry else { return [] }
        return PruningCalculator.completedSegments(entries: [editingEntry], rows: rows)
    }

    /// Quarters locked in the grid. While editing, the entry's own quarters
    /// become toggleable; quarters completed by OTHER entries stay locked —
    /// the server refuses to steal them anyway.
    private var lockedSegments: Set<PruningSegment> {
        editingEntry == nil ? metrics.completed : metrics.completed.subtracting(editingSegments)
    }

    /// Quarters inside the rows the user selected that are ALREADY complete and
    /// therefore excluded from this save.
    ///
    /// The grid locks completed quarters, so a range selection quietly drops
    /// them. Counting them here lets the sheet say so out loud instead of the
    /// user wondering why a row they picked was only partly recorded.
    private var alreadyCompleteInSelectedRows: Int {
        let touchedRows = Set(selectedSegments.map(\.rowKey))
        guard !touchedRows.isEmpty else { return 0 }
        return lockedSegments.filter { touchedRows.contains($0.rowKey) }.count
    }

    private func beginEdit(_ entry: PruningEntry) {
        editingEntry = entry
        selectedSegments = PruningCalculator.completedSegments(entries: [entry], rows: rows)
    }

    private func cancelEdit() {
        editingEntry = nil
        selectedSegments.removeAll()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if metrics.rowCount == 0 {
                    setupPromptCard
                } else {
                    if editingEntry != nil {
                        editBanner
                    }
                    progressCard
                    ratesCard
                    rowGridCard
                    historyCard
                }
                Spacer(minLength: 90)
            }
            .padding(.vertical)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle(paddock.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSetupSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Block pruning setup")
            }
        }
        .onAppear {
            guard let initialEditEntryId, editingEntry == nil,
                  let entry = entries.first(where: { $0.id == initialEditEntryId }) else { return }
            beginEdit(entry)
        }
        .safeAreaInset(edge: .bottom) {
            if !selectedSegments.isEmpty || editingEntry != nil {
                selectionBar
            }
        }
        .sheet(isPresented: $showEntrySheet) {
            PruningEntrySheet(
                paddock: paddock,
                pruningStore: pruningStore,
                vineyardId: store.selectedVineyardId ?? paddock.vineyardId,
                segments: Array(selectedSegments).sorted { ($0.row, $0.quarter) < ($1.row, $1.quarter) },
                rows: rows,
                defaultMethod: setup?.method ?? .spur,
                defaultWorker: setup?.crew ?? "",
                existingEntry: editingEntry,
                alreadyCompleteInSelectedRows: alreadyCompleteInSelectedRows
            ) {
                selectedSegments.removeAll()
                editingEntry = nil
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            PruningBlockSetupSheet(
                paddock: paddock,
                pruningStore: pruningStore,
                vineyardId: store.selectedVineyardId ?? paddock.vineyardId,
                needsRowCount: paddock.rows.isEmpty
            )
        }
        .sheet(item: $linkedTask) { task in
            AddEditWorkTaskView(existingTask: task)
        }
        .confirmationDialog(
            "This pruning entry has a linked Work Task. What should happen to the task?",
            isPresented: Binding(
                get: { entryPendingReversal != nil },
                set: { if !$0 { entryPendingReversal = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep Work Task") {
                if let entry = entryPendingReversal { pruningStore.deleteEntry(id: entry.id) }
                entryPendingReversal = nil
            }
            if canDeleteLinkedTask {
                Button("Delete Work Task", role: .destructive) {
                    if let entry = entryPendingReversal {
                        if let taskId = entry.workTaskId {
                            store.deleteWorkTask(taskId)
                        }
                        pruningStore.deleteEntry(id: entry.id)
                    }
                    entryPendingReversal = nil
                }
            }
            Button("Cancel", role: .cancel) { entryPendingReversal = nil }
        } message: {
            Text("Reversing the entry always reopens its row quarters. The linked Work Task can be kept for your labour records or deleted with it.")
        }
    }

    /// Deleting the linked task follows the normal Work Task permission rules.
    private var canDeleteLinkedTask: Bool {
        guard let entry = entryPendingReversal, let taskId = entry.workTaskId else { return false }
        guard store.workTasks.contains(where: { $0.id == taskId }) else { return false }
        return accessControl?.canDelete ?? false
    }

    // MARK: Setup prompt

    private var setupPromptCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.title)
                .foregroundStyle(.teal)
            Text("Set up pruning for this block")
                .font(.headline)
            Text(paddock.rows.isEmpty
                 ? "This block has no mapped rows. Enter a row count, due date and crew to start tracking."
                 : "Add a due date and crew to start tracking.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showSetupSheet = true
            } label: {
                Text("Set Up Block")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    // MARK: Edit banner

    private var editBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Editing \(editingEntry?.date.formatted(date: .abbreviated, time: .omitted) ?? "") entry")
                    .font(.footnote.weight(.semibold))
                Text("Tap quarters to adjust the selection, then Save Changes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                cancelEdit()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.1), in: .rect(cornerRadius: 14))
        .padding(.horizontal)
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Progress")
                    .font(.headline)
                Spacer()
                PruningStatusChip(status: metrics.status)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(PruningCalculator.displayPercent(metrics.fractionComplete))%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(metrics.completedRowEquivalents.formatted(.number.precision(.fractionLength(0...2)))) of \(metrics.rowCount) row equivalents")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            PruningProgressBar(
                fraction: metrics.fractionComplete,
                elapsedFraction: metrics.timeElapsedFraction,
                tint: metrics.status.tint
            )

            // The split only appears once something is out of rotation, so a
            // vineyard that never skips a row sees exactly the screen it had.
            if metrics.hasSkippedSections {
                HStack(spacing: 12) {
                    legendDot(
                        color: VineyardTheme.leafGreen,
                        text: "Pruned \(PruningCalculator.displayPercent(metrics.fractionPruned))%"
                    )
                    legendDot(
                        color: skippedTint,
                        text: "Skipped \(PruningCalculator.displayPercent(metrics.fractionSkipped))%"
                    )
                }
            }

            if let elapsed = metrics.timeElapsedFraction {
                HStack(spacing: 12) {
                    legendDot(color: metrics.status.tint, text: "Work \(PruningCalculator.displayPercent(metrics.fractionComplete))%")
                    legendDot(color: .primary.opacity(0.55), text: "Time \(PruningCalculator.displayPercent(elapsed))%")
                }
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                detailRow(label: "Vines pruned", value: "\(metrics.vinesPruned.formatted()) of \(metrics.vinesTotal.formatted())")
                if metrics.hasSkippedSections {
                    detailRow(
                        label: "Skipped",
                        value: "\(metrics.skippedRowEquivalents.formatted(.number.precision(.fractionLength(0...2)))) rows · \(metrics.vinesSkipped.formatted()) vines"
                    )
                }
                if let due = setup?.dueDate {
                    detailRow(label: "Due date", value: due.formatted(date: .abbreviated, time: .omitted))
                }
                if let projected = metrics.projectedFinish {
                    detailRow(label: "Estimated finish", value: projected.formatted(date: .abbreviated, time: .omitted))
                }
                if let crew = setup?.crew, !crew.isEmpty {
                    detailRow(label: "Crew", value: crew)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.semibold))
        }
    }

    // MARK: Rates

    private var ratesCard: some View {
        let today = PruningCalculator.rowEquivalentsPerDay(entries: entries, lastDays: 1)
        let last3 = PruningCalculator.rowEquivalentsPerDay(entries: entries, lastDays: 3)
        let last7 = PruningCalculator.rowEquivalentsPerDay(entries: entries, lastDays: 7)
        let period = PruningCalculator.rowEquivalentsPerDay(entries: entries, lastDays: nil)
        let rate = metrics.ratePerWorkday

        // SHARED CONTRACT (SQL 115): exact per-day vine totals and person-hour
        // rates — full precision throughout, rounded once at display. Never
        // sum per-entry rounded values or approximate via vines-per-row.
        let vinesPerDay = PruningCalculator.exactVinesPerDay(entries: entries, rows: rows)
        let vinesPerHour = PruningCalculator.vinesPerLabourHour(entries: entries, rows: rows)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Daily Rate")
                .font(.headline)

            if entries.isEmpty {
                Text("Record your first day of pruning to see rates and the estimated finish date.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    rateStat(value: today, label: "Today")
                    rateStat(value: last3, label: "3 days")
                    rateStat(value: last7, label: "7 days")
                    rateStat(value: period, label: "Period")
                }
                Text("Rows per working day (rolling average). Days without entries — e.g. rain days — don't count against the rate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    smallStat(
                        value: vinesPerDay.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                        label: "Vines / day"
                    )
                    smallStat(
                        value: vinesPerHour.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                        label: "Vines / labour hr"
                    )
                    smallStat(
                        value: rate.map { ($0 * metrics.averageRowLength).formatted(.number.precision(.fractionLength(0))) + " m" } ?? "—",
                        label: "Row metres / day"
                    )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    private func rateStat(value: Double?, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "—")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func smallStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.footnote.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Row grid

    private var rowGridCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rows")
                    .font(.headline)
                Spacer()
                if !selectedSegments.isEmpty {
                    Button("Clear") {
                        selectedSegments.removeAll()
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            rangeSelector

            HStack(spacing: 14) {
                gridLegend(color: VineyardTheme.leafGreen, text: "Pruned")
                if metrics.hasSkippedSections {
                    gridLegend(color: skippedTint, text: "Skipped")
                }
                gridLegend(color: .blue, text: "Selected")
                gridLegend(color: Color(.systemGray5), text: "Remaining")
            }

            if rows.first?.isFallback == true {
                Label {
                    Text("Using manually entered row count — this block has no configured rows. Map its rows in Vineyard Setup to track real row numbers.")
                        .font(.caption2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
            }

            VStack(spacing: 6) {
                ForEach(rows) { row in
                    rowLine(row)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    /// The pickers are `.fixedSize()` so the menu labels can never be
    /// compressed into wrapped digits on narrow screens; when one line is
    /// too tight, the whole control wraps to two lines instead.
    private var rangeSelector: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                rangePickers
                Spacer(minLength: 8)
                selectRangeButton
            }
            VStack(alignment: .leading, spacing: 8) {
                rangePickers
                selectRangeButton
            }
        }
    }

    private var rangePickers: some View {
        HStack(spacing: 8) {
            Text("Rows")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("From", selection: $rangeFromIndex) {
                ForEach(rows.indices, id: \.self) { index in
                    Text(rows[index].label).tag(index)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text("to")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("To", selection: $rangeToIndex) {
                ForEach(rows.indices, id: \.self) { index in
                    Text(rows[index].label).tag(index)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var selectRangeButton: some View {
        Button {
            selectRange()
        } label: {
            Text("Select range")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.bordered)
    }

    private func gridLegend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func rowLine(_ row: PruningRowRef) -> some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                ForEach(1...4, id: \.self) { quarter in
                    quarterCell(segment: row.segment(quarter: quarter))
                }
            }

            Button {
                toggleWholeRow(row)
            } label: {
                Image(systemName: rowFullySelectedOrDone(row) ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.subheadline)
                    .foregroundStyle(rowFullySelectedOrDone(row) ? VineyardTheme.leafGreen : Color.secondary)
            }
            .frame(width: 30)
            .accessibilityLabel("Select all of row \(row.label)")
        }
        .frame(minHeight: 34)
    }

    private func quarterCell(segment: PruningSegment) -> some View {
        let isDone = lockedSegments.contains(segment)
        // A skipped quarter is COMPLETE and locked exactly like a pruned one —
        // it just reads as out of rotation rather than as work done, so the two
        // are never confused at a glance.
        let isSkipped = isDone && metrics.skipped.contains(segment)
        let isSelected = selectedSegments.contains(segment)
        return Button {
            guard !isDone else { return }
            if isSelected {
                selectedSegments.remove(segment)
            } else {
                selectedSegments.insert(segment)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        isSkipped
                            ? skippedTint
                            : (isDone ? VineyardTheme.leafGreen : (isSelected ? Color.blue : Color(.systemGray5)))
                    )
                if isSkipped {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if isSelected {
                    Image(systemName: "scissors")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
        .disabled(isDone)
        .accessibilityLabel(
            "Row \(segment.row), quarter \(segment.quarter)"
                + (isSkipped ? ", skipped" : isDone ? ", pruned" : isSelected ? ", selected" : "")
        )
    }

    /// Slate, deliberately not a shade of the pruned green: skipped sections
    /// are complete but they are not work, and the grid should say so.
    private var skippedTint: Color { Color(.systemGray) }

    private func rowFullySelectedOrDone(_ row: PruningRowRef) -> Bool {
        (1...4).allSatisfy { quarter in
            let segment = row.segment(quarter: quarter)
            return lockedSegments.contains(segment) || selectedSegments.contains(segment)
        }
    }

    private func toggleWholeRow(_ row: PruningRowRef) {
        let remaining = (1...4)
            .map { row.segment(quarter: $0) }
            .filter { !lockedSegments.contains($0) }
        if remaining.allSatisfy({ selectedSegments.contains($0) }) {
            for segment in remaining { selectedSegments.remove(segment) }
        } else {
            for segment in remaining { selectedSegments.insert(segment) }
        }
    }

    private func selectRange() {
        guard !rows.isEmpty else { return }
        let low = min(rangeFromIndex, rangeToIndex)
        let high = max(rangeFromIndex, rangeToIndex)
        guard low >= 0, high < rows.count else { return }
        for row in rows[low...high] {
            for quarter in 1...4 {
                let segment = row.segment(quarter: quarter)
                if !lockedSegments.contains(segment) {
                    selectedSegments.insert(segment)
                }
            }
        }
    }

    // MARK: Selection bar

    private var selectionBar: some View {
        let rowEq = Double(selectedSegments.count) / 4.0
        let vines = PruningCalculator.vines(for: selectedSegments, rows: rows)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(rowEq.formatted(.number.precision(.fractionLength(0...2)))) row equivalents")
                    .font(.subheadline.weight(.semibold))
                Text("\(selectedSegments.count) quarters · ~\(vines.formatted()) vines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showEntrySheet = true
            } label: {
                Text(editingEntry == nil ? "Record Pruning" : "Save Changes")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(editingEntry == nil ? "Record pruning for the selected quarters" : "Review and save the edited pruning entry")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    // MARK: History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Completed Days")
                .font(.headline)

            if entries.isEmpty {
                Text("No entries yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.footnote.weight(.semibold))
                                if entry.isSkipped {
                                    Text("Skipped")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(skippedTint.opacity(0.18), in: .capsule)
                                        .foregroundStyle(skippedTint)
                                }
                            }
                            Text(entryDetail(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !entry.notes.isEmpty {
                                Text(entry.notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
                            if let taskId = entry.workTaskId {
                                Button {
                                    if let task = store.workTasks.first(where: { $0.id == taskId }) {
                                        linkedTask = task
                                    }
                                } label: {
                                    Label(
                                        store.workTasks.contains(where: { $0.id == taskId }) ? "Work Task" : "Work Task (removed)",
                                        systemImage: "link"
                                    )
                                    .font(.caption2.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(!store.workTasks.contains(where: { $0.id == taskId }))
                                .accessibilityLabel("Open the linked Work Task")
                            }
                        }
                        Spacer()
                        Text("\(entry.rowEquivalents.formatted(.number.precision(.fractionLength(0...2)))) rows")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                        Button {
                            beginEdit(entry)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                        .accessibilityLabel("Edit this pruning entry")
                        Button(role: .destructive) {
                            if entry.workTaskId != nil {
                                entryPendingReversal = entry
                            } else {
                                pruningStore.deleteEntry(id: entry.id)
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .accessibilityLabel("Reverse this pruning entry")
                    }
                    .padding(.vertical, 4)
                    if entry.id != entries.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    private func entryDetail(_ entry: PruningEntry) -> String {
        // A skipped record has no worker, no hours and no method to show. Its
        // labour reads as an em dash, never as zero — zero would claim the work
        // was done for free.
        if entry.isSkipped {
            return "\(skippedSelectionSummary(entry)) · Labour — · Cost —"
        }
        var parts: [String] = []
        if !entry.worker.isEmpty { parts.append(entry.worker) }
        if let hours = entry.labourHours, hours > 0 {
            parts.append("\(hours.formatted(.number.precision(.fractionLength(0...1)))) h")
        }
        parts.append(entry.method.label)
        return parts.joined(separator: " · ")
    }

    /// "Rows 8–9 marked skipped" for whole rows, "Row 8, sections 2–4 marked
    /// skipped" when only part of a single row is out of rotation.
    private func skippedSelectionSummary(_ entry: PruningEntry) -> String {
        let numbers = Set(entry.segments.map(\.row)).sorted()
        guard let low = numbers.first, let high = numbers.last else { return "Marked skipped" }
        if numbers.count == 1 {
            let quarters = entry.segments.filter { $0.row == low }.map(\.quarter).sorted()
            if quarters.count == 4 {
                return "Row \(low) marked skipped"
            }
            let list = quarters.map(String.init).joined(separator: ", ")
            let range = (quarters.count > 1 && quarters.last! - quarters.first! == quarters.count - 1)
                ? "\(quarters.first!)–\(quarters.last!)"
                : list
            return "Row \(low), sections \(range) marked skipped"
        }
        let contiguous = numbers.count == (high - low + 1)
        let label = contiguous ? "Rows \(low)–\(high)" : "Rows \(numbers.map(String.init).joined(separator: ", "))"
        return "\(label) marked skipped"
    }
}

// MARK: - Entry sheet

/// Editable labour-line draft for the Record Pruning sheet. The id is minted
/// once when the row is added and becomes the `work_task_labour_lines` row id,
/// so offline replay and retries can never create a duplicate line.
private struct PruningLabourLineDraft: Identifiable {
    /// Stable line id — for lines loaded from an existing linked Work Task
    /// this is the REAL `work_task_labour_lines` row id, so edits update the
    /// canonical row instead of duplicating it.
    var id: UUID = UUID()
    var operatorCategoryId: UUID? = nil
    var workerType: String = ""
    var countText: String = "1"
    var hoursText: String = ""
    var rateText: String = ""

    var workerCount: Int { max(Int(countText) ?? 1, 1) }
    var hoursPerWorker: Double { Double(hoursText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    var hourlyRate: Double? { Double(rateText.replacingOccurrences(of: ",", with: ".")) }
    /// Person-hours: worker count × hours per worker (matches the DB-generated
    /// `total_hours` column).
    var totalHours: Double { Double(workerCount) * hoursPerWorker }
    /// Line cost: person-hours × hourly rate; nil when no rate was specified
    /// (mirrors the existing Work Task "Not specified" convention — never $0).
    var totalCost: Double? { hourlyRate.map { totalHours * $0 } }
    var isValid: Bool { hoursPerWorker > 0 }
}

private struct PruningEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var dataStore
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.accessControl) private var accessControl
    let paddock: Paddock
    let pruningStore: PruningStore
    let vineyardId: UUID
    let segments: [PruningSegment]
    let rows: [PruningRowRef]
    let defaultMethod: PruningMethod
    let defaultWorker: String
    /// Non-nil puts the SAME form into edit mode: fields preload from this
    /// entry, `segments` carries the edited quarter set, and saving routes
    /// through the offline edit queue + `update_pruning_entry` RPC.
    let existingEntry: PruningEntry?
    /// Quarters inside the selected rows that are already complete and will be
    /// left alone. Surfaced as a notice rather than silently dropped.
    let alreadyCompleteInSelectedRows: Int
    let onSaved: () -> Void

    @State private var date: Date = Date()
    @State private var worker: String = ""
    @State private var labourHoursText: String = ""
    @State private var includeTimes: Bool = false
    @State private var startTime: Date = Date()
    @State private var finishTime: Date = Date()
    @State private var method: PruningMethod = .spur
    @State private var notes: String = ""
    @State private var createWorkTask: Bool = false
    @State private var workTaskType: String = "Pruning"
    @State private var labourLines: [PruningLabourLineDraft] = []
    /// HOW this job's labour is costed (sql/188). Defaults to Hourly — the
    /// behaviour every existing record has always had — and only changes when
    /// the user explicitly chooses Piece Rate.
    @State private var costingMethod: WorkTaskCostingMethod = .hourly
    /// The agreed dollars per vine, as typed.
    @State private var pieceRateText: String = ""
    @State private var updateLinkedTask: Bool = true
    @State private var originalLineIds: Set<UUID> = []
    @State private var showUnlinkDialog: Bool = false
    @State private var unlinkKeepTask: Bool = false
    @State private var unlinkDeleteTask: Bool = false
    /// The skip toggle. On, this stops being a work record: the sections are
    /// marked OUT OF PRUNING ROTATION and every labour, costing and Work Task
    /// field disappears — there is nothing to enter, so nothing is shown.
    @State private var markSkipped: Bool = false
    @State private var showSkipConfirm: Bool = false

    private var taskTypeOptions: [String] {
        WorkTaskTypeCatalog.merged(with: dataStore.workTaskTypes)
    }

    private var workerCategories: [OperatorCategory] {
        dataStore.operatorCategories.filter { $0.vineyardId == vineyardId }
    }

    /// Total person-hours across labour lines (worker count × hours per worker,
    /// summed) — the existing VineTrack Work Task convention, and the value
    /// stored on `pruning_entries.labour_hours` when a task is created.
    private var labourPersonHours: Double {
        labourLines.reduce(0) { $0 + $1.totalHours }
    }

    /// Total labour cost across lines that have a rate.
    private var labourTotalCost: Double {
        labourLines.reduce(0) { $0 + ($1.totalCost ?? 0) }
    }

    private var hasRatedLine: Bool {
        labourLines.contains { $0.hourlyRate != nil }
    }

    // MARK: Piece rate (sql/188)

    private var isPieceRate: Bool { costingMethod == .pieceRate }

    /// The agreed rate per vine, parsed locale-safely.
    private var pieceRatePerVine: Double? {
        Double(pieceRateText.replacingOccurrences(of: ",", with: "."))
    }

    /// Stable ids of the rows this record touches — taken straight from the
    /// quarters already selected on the progress grid. The operator never
    /// selects rows a second time just to be costed.
    private var selectedRowIds: Set<UUID> {
        Set(segments.compactMap(\.rowId))
    }

    /// Distinct rows covered by this job.
    private var selectedRowCount: Int {
        let ids = selectedRowIds
        if !ids.isEmpty { return ids.count }
        // Fallback rows carry no id — count their numbers instead.
        return Set(segments.map(\.row)).count
    }

    /// THE historical snapshot rows for this job, derived from the block's
    /// CURRENT effective row counts at the moment of saving.
    private var pieceRateSnapshotRows: [WorkTaskPieceRateRow] {
        guard !selectedRowIds.isEmpty else { return [] }
        return PieceRateCosting.snapshotRows(
            workTaskId: UUID(), // replaced with the real task id at save time
            vineyardId: vineyardId,
            paddock: paddock,
            selectedRowIds: selectedRowIds
        )
    }

    /// The vine quantity this job is priced on, derived automatically from the
    /// selected rows' effective vine counts (manual per-row overrides win).
    ///
    /// Falls back to the pruning tracker's own weighted vine estimate for
    /// blocks whose rows have no stable ids (manual fallback rows), so a
    /// piece-rate job is never blocked by legacy row data.
    private var pieceVineCount: Int {
        let fromRows = PieceRateCosting.vineCount(forSelectedRows: pieceRateSnapshotRows)
        if fromRows > 0 { return fromRows }
        return PruningCalculator.vines(for: segments, rows: rows)
    }

    /// vine count × rate per vine.
    private var pieceRateCost: Double? {
        PieceRateCosting.cost(vineCount: pieceVineCount, ratePerVine: pieceRatePerVine)
    }

    /// Hectares actually covered by this record's quarters — the only honest
    /// denominator for cost per hectare on a partial-block job.
    private var pieceRateAreaHa: Double? {
        let area = PruningCalculator.areaHectares(for: segments, rows: rows, paddock: paddock)
        return area > 0 ? area : (paddock.areaHectares > 0 ? paddock.areaHectares : nil)
    }

    private var pieceRateCostPerHa: Double? {
        PieceRateCosting.costPerHectare(cost: pieceRateCost, hectares: pieceRateAreaHa)
    }

    private var pieceRateIssues: [PieceRateCosting.PieceRateIssue] {
        PieceRateCosting.validate(ratePerVine: pieceRatePerVine, vineCount: pieceVineCount)
    }

    private var pieceRateValid: Bool { pieceRateIssues.isEmpty }

    /// Whether the costing inputs are complete enough to save. Hourly keeps its
    /// existing rule EXACTLY; piece rate applies its own.
    private var costingValid: Bool {
        isPieceRate ? pieceRateValid : labourLinesValid
    }

    /// Every labour line needs hours > 0 before the task can be created.
    private var labourLinesValid: Bool {
        !labourLines.isEmpty && labourLines.allSatisfy { $0.isValid }
    }

    private func hoursLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " h"
    }

    private func currencyLabel(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(2)))
    }

    private var recordButtonTitle: String {
        segments.count == 1 ? "Record 1 quarter" : "Record \(segments.count) quarters"
    }

    private var saveButtonTitle: String {
        if markSkipped { return "Mark Skipped" }
        return isEditing ? "Save Changes" : recordButtonTitle
    }

    private var navigationTitle: String {
        if markSkipped { return "Mark Skipped \u{2014} \(paddock.name)" }
        return isEditing ? "Edit Pruning Record \u{2014} \(paddock.name)" : "Record Pruning \u{2014} \(paddock.name)"
    }

    /// The toggle plus the two things the user needs to know before using it:
    /// what it will and won't record, and whether any of their selection is
    /// already complete and will therefore be left alone.
    @ViewBuilder
    private var skipSection: some View {
        Section {
            Toggle("Mark as skipped", isOn: $markSkipped.animation(.easeInOut(duration: 0.2)))
                .disabled(isEditing)
            if alreadyCompleteInSelectedRows > 0 {
                Label(
                    "Some selected sections are already complete. Only the remaining sections will be marked as skipped.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } footer: {
            if markSkipped {
                Text("For rows temporarily or permanently out of pruning rotation \u{2014} vines removed, rows pulled out, replanted or dead sections. They count as complete in pruning progress, and record no worker, labour, cost or Work Task.")
            } else if isEditing, existingEntry?.isSkipped == false {
                Text("This is a pruning record. To take sections out of rotation, reverse it and mark the sections skipped instead.")
            }
        }
    }

    private var isEditing: Bool { existingEntry != nil }

    private var hasLinkedTask: Bool { existingEntry?.workTaskId != nil }

    /// The linked Work Task when it exists in the local store.
    private var linkedTask: WorkTask? {
        guard let id = existingEntry?.workTaskId else { return nil }
        return dataStore.workTasks.first { $0.id == id }
    }

    private var willUnlink: Bool { unlinkKeepTask || unlinkDeleteTask }

    /// Whether the Work Task costing fields (work type + labour lines) are
    /// active: creating a new task, or updating an existing linked one.
    private var showsTaskFields: Bool {
        // A skipped record has no costing at all, so the Work Task branch is
        // closed before any of its state can matter.
        if markSkipped { return false }
        if isEditing, hasLinkedTask {
            return updateLinkedTask && !willUnlink && linkedTask != nil
        }
        return createWorkTask
    }

    /// Plain-text number for prefilling editable fields (locale-safe parse).
    private func numText(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded() { return String(Int(value)) }
        return String(value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(markSkipped ? "Sections" : "Work Completed") {
                    LabeledContent("Block", value: paddock.name)
                    LabeledContent("Row equivalents", value: (Double(segments.count) / 4.0).formatted(.number.precision(.fractionLength(0...2))))
                    if !markSkipped {
                        LabeledContent("Vines (approx.)", value: "\(PruningCalculator.vines(for: segments, rows: rows).formatted())")
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                skipSection

                if !markSkipped {
                Section("Crew") {
                    TextField("Worker or crew", text: $worker)
                    if showsTaskFields {
                        // Person-hours convention: with labour lines, the pruning
                        // record's labour hours = sum of all line person-hours.
                        LabeledContent("Labour hours", value: hoursLabel(labourPersonHours))
                    } else {
                        TextField("Labour hours", text: $labourHoursText)
                            .keyboardType(.decimalPad)
                    }
                    Toggle("Record start & finish time", isOn: $includeTimes)
                    if includeTimes {
                        DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                        DatePicker("Finish", selection: $finishTime, displayedComponents: .hourAndMinute)
                    }
                }

                Section("Method") {
                    Picker("Pruning method", selection: $method) {
                        ForEach(PruningMethod.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
                }

                // Notes stay in both modes: one lightweight field, and "why is
                // this out of rotation" is exactly the thing a grower wants to
                // find next season.
                Section("Notes") {
                    TextField(
                        markSkipped ? "Why are these sections out of rotation? (optional)" : "Optional notes",
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                }

                if !markSkipped {
                Section {
                    if isEditing, hasLinkedTask {
                        if willUnlink {
                            Label(
                                unlinkDeleteTask
                                    ? "The Work Task will be deleted and unlinked when you save."
                                    : "The Work Task will be kept but unlinked when you save.",
                                systemImage: "link.badge.plus"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            Button("Keep Work Task linked") {
                                unlinkKeepTask = false
                                unlinkDeleteTask = false
                            }
                        } else if linkedTask != nil {
                            Toggle("Update linked Work Task", isOn: $updateLinkedTask)
                            if updateLinkedTask {
                                Picker("Work type", selection: $workTaskType) {
                                    ForEach(taskTypeOptions, id: \.self) { option in
                                        Text(option).tag(option)
                                    }
                                }
                                LabeledContent("Title", value: "Pruning \u{2014} \(paddock.name)")
                                LabeledContent("Status", value: linkedTask?.status ?? "Completed")
                            }
                            Button("Unlink Work Task\u{2026}", role: .destructive) {
                                showUnlinkDialog = true
                            }
                        } else {
                            Text("The linked Work Task isn't on this device yet \u{2014} its costing fields can't be edited here.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Unlink Work Task\u{2026}", role: .destructive) {
                                showUnlinkDialog = true
                            }
                        }
                    } else {
                        Toggle(isEditing ? "Create a Work Task for this pruning record" : "Create a Work Task for this pruning work", isOn: $createWorkTask)
                            .onChange(of: createWorkTask) { _, isOn in
                                guard isOn, labourLines.isEmpty else { return }
                                // Seed the first labour line from the pruning form's
                                // Worker/Crew and Labour Hours so nothing is re-entered.
                                var first = PruningLabourLineDraft()
                                first.workerType = worker.trimmingCharacters(in: .whitespaces)
                                first.hoursText = labourHoursText
                                labourLines = [first]
                            }
                        if createWorkTask {
                            Picker("Work type", selection: $workTaskType) {
                                ForEach(taskTypeOptions, id: \.self) { option in
                                    Text(option).tag(option)
                                }
                            }
                            LabeledContent("Title", value: "Pruning \u{2014} \(paddock.name)")
                            LabeledContent("Status", value: "Completed")
                        }
                    }
                } header: {
                    Text("Work Task")
                } footer: {
                    if isEditing, hasLinkedTask, showsTaskFields {
                        Text("Saving synchronises the task's date, work type, notes and the labour lines below \u{2014} stable ids, so retries never duplicate the task or its lines. The pruning record stays the source of truth for row completion.")
                    } else if createWorkTask {
                        Text("The Work Task reuses this record's date, block, crew, times and notes \u{2014} nothing is entered twice. It is created as completed with the labour lines below and appears in the Work Tasks tool.")
                    }
                }

                if showsTaskFields {
                    costingMethodSection
                    if isPieceRate { pieceRateSection }
                    Section {
                        ForEach($labourLines) { $line in
                            labourLineEditor($line)
                        }
                        Button {
                            labourLines.append(PruningLabourLineDraft())
                        } label: {
                            Label("Add worker", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        Text(isPieceRate ? "Hours Worked (optional)" : "Labour Lines")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if isPieceRate {
                                // Hours stay recordable as operational history,
                                // but they never drive a piece-rate job's cost.
                                Text("Total: \(hoursLabel(labourPersonHours)) person-hours")
                                Text("Hours are kept for operational history only. This job's labour cost is the piece rate above \u{2014} hours never change it.")
                            } else if labourLinesValid {
                                Text("Total: \(hoursLabel(labourPersonHours)) person-hours" + (hasRatedLine ? " \u{00B7} \(currencyLabel(labourTotalCost)) labour cost" : ""))
                                Text("One costing line per worker or crew \u{2014} different hours and rates per worker are supported. Rates left blank show as \u{201C}Not specified\u{201D} in the Work Task.")
                            } else {
                                Text("Each labour line needs hours greater than zero.")
                                    .foregroundStyle(.red)
                                Text("One costing line per worker or crew \u{2014} different hours and rates per worker are supported. Rates left blank show as \u{201C}Not specified\u{201D} in the Work Task.")
                            }
                        }
                    }
                }
                }
                if let original = existingEntry {
                    editSummarySection(original)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        // Marking sections out of rotation changes what the
                        // vineyard's progress figures mean, so it is always
                        // confirmed — including on an edit.
                        if markSkipped {
                            showSkipConfirm = true
                        } else {
                            save()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled((!isEditing && segments.isEmpty) || (showsTaskFields && !costingValid))
                    .accessibilityLabel(
                        markSkipped
                            ? "Mark the selected sections as skipped"
                            : (isEditing ? "Save pruning changes" : "Record pruning")
                    )
                }
            }
            .confirmationDialog(
                "Mark selected rows as skipped?",
                isPresented: $showSkipConfirm,
                titleVisibility: .visible
            ) {
                Button("Mark Skipped") { save() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These rows will count as complete in pruning progress, but no pruning work, labour or cost will be recorded.")
            }
            .onAppear {
                if let entry = existingEntry {
                    preload(from: entry)
                } else {
                    method = defaultMethod
                    worker = defaultWorker
                }
            }
            .confirmationDialog(
                "Remove the Work Task link from this pruning record?",
                isPresented: $showUnlinkDialog,
                titleVisibility: .visible
            ) {
                Button("Keep Work Task but unlink") {
                    unlinkKeepTask = true
                    unlinkDeleteTask = false
                }
                if accessControl?.canDelete ?? false {
                    Button("Delete Work Task and unlink", role: .destructive) {
                        unlinkDeleteTask = true
                        unlinkKeepTask = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The pruning record keeps its quarters either way \u{2014} unlinking only affects Work Task reporting.")
            }
        }
    }

    /// Preloads the form from the entry being edited, including the linked
    /// Work Task's REAL labour lines (stable ids preserved for the diff).
    private func preload(from entry: PruningEntry) {
        // The kind of a record is fixed once saved: converting a pruning record
        // into a skipped one would silently delete recorded labour, and the
        // reverse would invent work that never happened. The server refuses
        // both, so the toggle is preloaded and locked.
        markSkipped = entry.isSkipped
        date = entry.date
        worker = entry.worker
        labourHoursText = numText(entry.labourHours)
        includeTimes = entry.startTime != nil || entry.finishTime != nil
        if let start = entry.startTime { startTime = start }
        if let finish = entry.finishTime { finishTime = finish }
        method = entry.method
        notes = entry.notes
        guard let task = linkedTask else { return }
        workTaskType = task.taskType
        // sql/188: an existing task keeps the method it was saved with. Legacy
        // tasks resolve to Hourly, so nothing about them changes.
        costingMethod = task.costingMethod
        if let rate = task.pieceRatePerVine {
            pieceRateText = rate.formatted(.number.precision(.fractionLength(0...4)))
        }
        let lines = dataStore.workTaskLabourLines.filter { $0.workTaskId == task.id }
        if lines.isEmpty {
            var first = PruningLabourLineDraft()
            first.workerType = entry.worker
            first.hoursText = numText(entry.labourHours)
            labourLines = [first]
        } else {
            labourLines = lines.map { line in
                PruningLabourLineDraft(
                    id: line.id,
                    operatorCategoryId: line.operatorCategoryId,
                    workerType: line.workerType,
                    countText: "\(line.workerCount)",
                    hoursText: numText(line.hoursPerWorker),
                    rateText: numText(line.hourlyRate)
                )
            }
            originalLineIds = Set(lines.map(\.id))
        }
    }

    /// Before-save summary so the user sees exactly what the edit changes.
    @ViewBuilder
    private func editSummarySection(_ original: PruningEntry) -> some View {
        let oldQuarters = original.segments.count
        let newQuarters = segments.count
        let newHours: Double? = showsTaskFields
            ? (labourPersonHours > 0 ? labourPersonHours : nil)
            : Double(labourHoursText.replacingOccurrences(of: ",", with: "."))
        let vintage = VintageResolver.vintageYear(
            for: date,
            seasonStartMonth: dataStore.settings.seasonStartMonth,
            seasonStartDay: dataStore.settings.seasonStartDay
        )
        Section {
            LabeledContent("Quarters", value: "\(oldQuarters) \u{2192} \(newQuarters)")
            LabeledContent(
                "Row equivalents",
                value: "\((Double(oldQuarters) / 4.0).formatted(.number.precision(.fractionLength(0...2)))) \u{2192} \((Double(newQuarters) / 4.0).formatted(.number.precision(.fractionLength(0...2))))"
            )
            LabeledContent(
                "Person-hours",
                value: "\(original.labourHours.map { hoursLabel($0) } ?? "\u{2014}") \u{2192} \(newHours.map { hoursLabel($0) } ?? "\u{2014}")"
            )
            if showsTaskFields, hasRatedLine {
                LabeledContent("Labour cost", value: currencyLabel(labourTotalCost))
            }
            LabeledContent("Vintage", value: String(vintage))
        } header: {
            Text("Edit Summary")
        } footer: {
            Text("Quarters completed by other entries are never taken over \u{2014} any conflict is reported after sync.")
        }
    }

    /// Distinct selected row numbers grouped into compact ranges, e.g. "44\u{2013}46, 50".
    private var rowRangeSummary: String {
        let numbers = Set(segments.map(\.row)).sorted()
        guard let first = numbers.first else { return "\u{2014}" }
        var parts: [String] = []
        var start = first
        var previous = first
        for number in numbers.dropFirst() {
            if number == previous + 1 {
                previous = number
                continue
            }
            parts.append(start == previous ? "\(start)" : "\(start)\u{2013}\(previous)")
            start = number
            previous = number
        }
        parts.append(start == previous ? "\(start)" : "\(start)\u{2013}\(previous)")
        return parts.joined(separator: ", ")
    }

    /// Work Task notes composed from the pruning record so nothing is entered twice.
    private var composedTaskNotes: String {
        let rowEq = (Double(segments.count) / 4.0).formatted(.number.precision(.fractionLength(0...2)))
        let vines = PruningCalculator.vines(for: segments, rows: rows)
        var summary = "Source: Pruning Tracker \u{2014} Rows \(rowRangeSummary) \u{00B7} \(segments.count) quarters \u{00B7} \(rowEq) row equivalents \u{00B7} ~\(vines.formatted()) vines \u{00B7} \(method.label)"
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            summary += "\n" + trimmed
        }
        return summary
    }

    @ViewBuilder
    private func labourLineEditor(_ line: Binding<PruningLabourLineDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Worker or crew member", text: line.workerType)
                if !workerCategories.isEmpty {
                    Menu {
                        ForEach(workerCategories) { category in
                            Button {
                                line.wrappedValue.operatorCategoryId = category.id
                                line.wrappedValue.workerType = category.name
                                // Worker-type default rate seeds an empty rate
                                // field \u{2014} same behaviour as the existing Work
                                // Task labour sheet.
                                if line.wrappedValue.rateText.isEmpty, category.costPerHour > 0 {
                                    line.wrappedValue.rateText = category.costPerHour.formatted(.number.precision(.fractionLength(0...2)))
                                }
                            } label: {
                                if category.costPerHour > 0 {
                                    Text("\(category.name) \u{00B7} \(currencyLabel(category.costPerHour))/h")
                                } else {
                                    Text(category.name)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.blue)
                    }
                    .accessibilityLabel("Choose worker type")
                }
                if labourLines.count > 1 {
                    Button {
                        labourLines.removeAll { $0.id == line.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove labour line")
                }
            }
            HStack(spacing: 12) {
                TextField("Workers", text: line.countText)
                    .keyboardType(.numberPad)
                TextField("Hrs / worker", text: line.hoursText)
                    .keyboardType(.decimalPad)
                // The hourly rate IS the costing input — on a piece-rate job it
                // would be a second, contradictory cost, so it is hidden.
                if !isPieceRate {
                    TextField("Rate $/h", text: line.rateText)
                        .keyboardType(.decimalPad)
                }
            }
            .font(.subheadline)
            HStack {
                Text(hoursLabel(line.wrappedValue.totalHours))
                if !isPieceRate {
                    Text("\u{00B7}")
                    if let cost = line.wrappedValue.totalCost {
                        Text(currencyLabel(cost))
                    } else {
                        Text("Cost not specified")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Costing method + piece rate UI (sql/188)

    private var costingMethodSection: some View {
        Section {
            Picker("Costing method", selection: $costingMethod) {
                ForEach(WorkTaskCostingMethod.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Costing Method")
        } footer: {
            Text(costingMethod == .pieceRate
                ? "Priced per vine. The vine count comes from the rows selected above, using each row's manual count where one is set."
                : "Priced per hour from the labour lines below \u{2014} the existing VineTrack costing.")
        }
    }

    private var pieceRateSection: some View {
        let issues = pieceRateIssues
        return Section {
            HStack {
                Text("Rate / vine")
                Spacer()
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("0.00", text: $pieceRateText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
            if let message = PieceRateCosting.message(issues, for: .ratePerVine) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            LabeledContent("Rows", value: "\(selectedRowCount)")
            LabeledContent("Vines", value: PieceRateCosting.vineCountLabel(pieceVineCount))
            if let message = PieceRateCosting.message(issues, for: .vineCount) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("Estimated cost")
                    .font(.headline)
                Spacer()
                Text(pieceRateCost.map { PieceRateCosting.currencyLabel($0) } ?? "\u{2014}")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(VineyardTheme.earthBrown)
            }
            if let perHa = pieceRateCostPerHa {
                LabeledContent("Cost / ha", value: PieceRateCosting.currencyLabel(perHa))
            }
        } header: {
            Text("Piece Rate")
        } footer: {
            Text("The vine count is worked out from the selected rows and saved with this job. Later edits to the block's rows never change what this job cost.")
        }
    }

    /// Writes the piece-rate agreement and its historical row snapshot onto a
    /// task. Called for BOTH create and update so a job re-agreed before it is
    /// finalised keeps one consistent basis.
    ///
    /// Switching a task back to Hourly clears the piece-rate basis and removes
    /// its snapshot rows, so no stale agreement can be resurrected.
    private func applyCosting(to task: inout WorkTask) {
        task.costingMethod = costingMethod
        guard isPieceRate else {
            task.pieceRatePerVine = nil
            task.pieceVineCount = nil
            return
        }
        task.pieceRatePerVine = pieceRatePerVine
        task.pieceVineCount = pieceVineCount
    }

    /// Persists the per-row historical snapshot for a piece-rate job.
    private func persistPieceRateRows(for taskId: UUID) {
        guard isPieceRate else {
            dataStore.replaceWorkTaskPieceRateRows([], forWorkTask: taskId)
            return
        }
        let snapshot = PieceRateCosting.snapshotRows(
            workTaskId: taskId,
            vineyardId: vineyardId,
            paddock: paddock,
            selectedRowIds: selectedRowIds
        )
        dataStore.replaceWorkTaskPieceRateRows(snapshot, forWorkTask: taskId)
    }

    /// Creates the linked, completed Work Task AND its labour costing lines
    /// through the existing shared work-task store + sync. Every id (task and
    /// each `work_task_labour_lines` row) is client-generated and stable, so
    /// retries and offline replays can never create a duplicate task or line.
    /// Sequence: task header \u{2192} block join row \u{2192} labour lines; the labour
    /// sync queues independently and the server upsert is idempotent by id.
    private func createLinkedWorkTask() -> UUID {
        let userName = auth.userName ?? ""
        var task = WorkTask(
            vineyardId: vineyardId,
            date: date,
            taskType: workTaskType,
            paddockId: paddock.id,
            paddockName: paddock.name,
            durationHours: labourPersonHours,
            notes: composedTaskNotes,
            createdBy: userName.isEmpty ? nil : userName,
            isFinalized: true,
            finalizedAt: Date(),
            finalizedBy: userName.isEmpty ? nil : userName,
            taskDescription: "Pruning \u{2014} \(paddock.name)",
            status: "Completed"
        )
        if paddock.areaHectares > 0 {
            task.areaHa = paddock.areaHectares
        }
        // sql/188: the costing method and, for piece rate, the agreed rate plus
        // the SNAPSHOTTED vine quantity are written with the task itself.
        applyCosting(to: &task)
        dataStore.addWorkTask(task)
        persistPieceRateRows(for: task.id)
        dataStore.addWorkTaskPaddock(WorkTaskPaddock(
            workTaskId: task.id,
            vineyardId: vineyardId,
            paddockId: paddock.id,
            areaHa: paddock.areaHectares > 0 ? paddock.areaHectares : nil
        ))
        // One canonical labour line per worker/crew row \u{2014} the same
        // work_task_labour_lines records the Work Task editor and portal use.
        // Draft ids were minted when the rows were added, so a re-run of the
        // offline queue upserts by id instead of duplicating.
        //
        // On a PIECE RATE job these lines still record hours as operational
        // history; the hourly rate is dropped so the task can never carry two
        // competing labour costs.
        for draft in labourLines where draft.isValid {
            dataStore.addWorkTaskLabourLine(WorkTaskLabourLine(
                id: draft.id,
                workTaskId: task.id,
                vineyardId: vineyardId,
                workDate: date,
                operatorCategoryId: draft.operatorCategoryId,
                workerType: draft.workerType.trimmingCharacters(in: .whitespaces),
                workerCount: draft.workerCount,
                hoursPerWorker: draft.hoursPerWorker,
                hourlyRate: isPieceRate ? nil : draft.hourlyRate,
                notes: ""
            ))
        }
        return task.id
    }

    private func save() {
        if let original = existingEntry {
            saveEdit(original)
            onSaved()
            dismiss()
            return
        }
        // CANONICAL SEASON (sql/161): an entry belongs to the season of the
        // year the work was DONE — the date on this form, never today's date
        // and never the highest season row the block happens to own.
        // Recording work on an unconfigured season auto-creates that season.
        let season: PruningBlockSetup
        if let existing = pruningStore.setup(for: paddock.id, on: date) {
            season = existing
        } else {
            let template = pruningStore.setup(for: paddock.id)
            season = PruningBlockSetup(
                vineyardId: vineyardId,
                paddockId: paddock.id,
                seasonYear: PruningSeasonId.seasonYear(for: date),
                method: template?.method ?? .spur,
                crew: template?.crew ?? "",
                workingDays: template?.workingDays ?? [1, 2, 3, 4, 5],
                rowCountOverride: template?.rowCountOverride
            )
            pruningStore.upsertSetup(season)
        }
        // A SKIPPED record: the sections are out of rotation, so there is no
        // worker, no hours, no times, no method, no vine count, no cost and no
        // Work Task to create. It carries only what is needed to locate the
        // selection, and it takes the same offline queue and the same reversal
        // path as any other pruning record.
        if markSkipped {
            let skippedEntry = PruningEntry(
                vineyardId: vineyardId,
                paddockId: paddock.id,
                seasonId: season.id,
                date: date,
                segments: segments,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                skipped: true
            )
            pruningStore.addEntry(skippedEntry)
            onSaved()
            dismiss()
            return
        }
        // The Work Task is created first with a client-generated id; the entry
        // stores that id, so both records stay linked through offline replay
        // and a retry can never create a second task for the same entry.
        let linkedTaskId: UUID? = createWorkTask ? createLinkedWorkTask() : nil
        // Person-hours convention: with labour lines, the pruning entry's labour
        // hours = sum of all line person-hours (e.g. 2 workers \u{00D7} 8 h = 16 h) so
        // vines-per-labour-hour stays accurate. Without a task, the manually
        // entered value applies as before.
        let entryHours: Double? = createWorkTask
            ? (labourPersonHours > 0 ? labourPersonHours : nil)
            : Double(labourHoursText.replacingOccurrences(of: ",", with: "."))
        let entry = PruningEntry(
            vineyardId: vineyardId,
            paddockId: paddock.id,
            seasonId: season.id,
            date: date,
            segments: segments,
            worker: worker.trimmingCharacters(in: .whitespaces),
            labourHours: entryHours,
            startTime: includeTimes ? startTime : nil,
            finishTime: includeTimes ? finishTime : nil,
            method: method,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            estimatedVines: PruningCalculator.vines(for: segments, rows: rows),
            workTaskId: linkedTaskId
        )
        pruningStore.addEntry(entry)
        onSaved()
        dismiss()
    }

    /// Applies an edit: updates the local entry (which queues the
    /// `update_pruning_entry` push) and synchronises / creates / unlinks the
    /// linked Work Task through the existing offline-safe work-task stores.
    /// Every id is stable, so retries never duplicate a task or line.
    private func saveEdit(_ original: PruningEntry) {
        var updated = original
        updated.date = date
        // Editing a skipped record only ever changes its date, its section
        // selection and its note — there is nothing else on it to change.
        if original.isSkipped {
            if PruningSeasonId.seasonYear(for: date) != PruningSeasonId.seasonYear(for: original.date) {
                updated.seasonId = pruningStore.setup(for: paddock.id, on: date)?.id
                    ?? PruningSeasonId.make(
                        vineyardId: original.vineyardId,
                        paddockId: original.paddockId,
                        date: date
                    )
            }
            updated.segments = segments
            updated.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            pruningStore.updateEntry(updated)
            return
        }
        // A date edit that crosses a pruning year re-points the entry at that
        // year's season — `update_pruning_entry` (sql/161) does exactly the
        // same server-side and returns the canonical id, which we adopt.
        if PruningSeasonId.seasonYear(for: date) != PruningSeasonId.seasonYear(for: original.date) {
            updated.seasonId = pruningStore.setup(for: paddock.id, on: date)?.id
                ?? PruningSeasonId.make(
                    vineyardId: original.vineyardId,
                    paddockId: original.paddockId,
                    date: date
                )
        }
        updated.segments = segments
        updated.worker = worker.trimmingCharacters(in: .whitespaces)
        updated.startTime = includeTimes ? startTime : nil
        updated.finishTime = includeTimes ? finishTime : nil
        updated.method = method
        updated.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.estimatedVines = PruningCalculator.vines(for: segments, rows: rows)
        updated.labourHours = Double(labourHoursText.replacingOccurrences(of: ",", with: "."))

        if willUnlink, let taskId = original.workTaskId {
            // Explicit user choice from the unlink dialog — never silent.
            if unlinkDeleteTask { dataStore.deleteWorkTask(taskId) }
            updated.workTaskId = nil
        } else if hasLinkedTask, showsTaskFields, let current = linkedTask {
            // Synchronise the reusable fields onto the linked task. The SQL 119
            // trigger re-resolves the task's costing vintage from the new date,
            // so date edits across the season boundary move costs with them.
            var task = current
            task.date = date
            task.taskType = workTaskType
            task.durationHours = labourPersonHours
            task.notes = composedTaskNotes
            applyCosting(to: &task)
            dataStore.updateWorkTask(task)
            persistPieceRateRows(for: task.id)
            // Labour-line diff: stable ids update the canonical rows, new
            // lines carry their minted ids, removed lines soft-delete.
            for draft in labourLines where draft.isValid {
                let line = WorkTaskLabourLine(
                    id: draft.id,
                    workTaskId: task.id,
                    vineyardId: vineyardId,
                    workDate: date,
                    operatorCategoryId: draft.operatorCategoryId,
                    workerType: draft.workerType.trimmingCharacters(in: .whitespaces),
                    workerCount: draft.workerCount,
                    hoursPerWorker: draft.hoursPerWorker,
                    hourlyRate: isPieceRate ? nil : draft.hourlyRate,
                    notes: ""
                )
                if originalLineIds.contains(draft.id) {
                    dataStore.updateWorkTaskLabourLine(line)
                } else {
                    dataStore.addWorkTaskLabourLine(line)
                }
            }
            let keptIds = Set(labourLines.filter { $0.isValid }.map(\.id))
            for removedId in originalLineIds.subtracting(keptIds) {
                dataStore.deleteWorkTaskLabourLine(removedId)
            }
            // Person-hours convention: the entry's labour hours = sum of all
            // live labour-line person-hours — entry and task never disagree.
            updated.labourHours = labourPersonHours > 0 ? labourPersonHours : nil
        } else if !hasLinkedTask, createWorkTask {
            updated.workTaskId = createLinkedWorkTask()
            updated.labourHours = labourPersonHours > 0 ? labourPersonHours : nil
        }

        pruningStore.updateEntry(updated)
    }
}

// MARK: - Setup sheet

private struct PruningBlockSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let paddock: Paddock
    let pruningStore: PruningStore
    let vineyardId: UUID
    let needsRowCount: Bool

    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var hasStartDate: Bool = false
    @State private var startDate: Date = Date()
    @State private var method: PruningMethod = .spur
    @State private var crew: String = ""
    @State private var workingDays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var rowCountText: String = ""
    @State private var labourHoursText: String = ""
    @State private var notes: String = ""

    private let dayLabels: [(Int, String)] = [
        (1, "Mon"), (2, "Tue"), (3, "Wed"), (4, "Thu"), (5, "Fri"), (6, "Sat"), (7, "Sun"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if needsRowCount {
                    Section {
                        TextField("Number of rows", text: $rowCountText)
                            .keyboardType(.numberPad)
                    } header: {
                        Text("Rows")
                    } footer: {
                        Text("This block has no mapped rows, so enter the row count manually. Mapped blocks use their real rows automatically.")
                    }
                }

                Section("Schedule") {
                    Toggle("Pruning start date", isOn: $hasStartDate)
                    if hasStartDate {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    }
                    Toggle("Pruning due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    }
                }

                Section {
                    HStack(spacing: 6) {
                        ForEach(dayLabels, id: \.0) { day, label in
                            let isOn = workingDays.contains(day)
                            Button {
                                if isOn {
                                    if workingDays.count > 1 { workingDays.remove(day) }
                                } else {
                                    workingDays.insert(day)
                                }
                            } label: {
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(isOn ? Color.blue : Color(.systemGray5), in: .rect(cornerRadius: 8))
                                    .foregroundStyle(isOn ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Working Days")
                } footer: {
                    Text("Used to project the estimated completion date.")
                }

                Section("Crew & Method") {
                    TextField("Assigned crew", text: $crew)
                    Picker("Pruning method", selection: $method) {
                        ForEach(PruningMethod.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    TextField("Estimated labour hours (optional)", text: $labourHoursText)
                        .keyboardType(.decimalPad)
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Pruning Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { loadExisting() }
        }
    }

    private func loadExisting() {
        guard let existing = pruningStore.setup(for: paddock.id) else { return }
        if let due = existing.dueDate {
            hasDueDate = true
            dueDate = due
        }
        if let start = existing.startDate {
            hasStartDate = true
            startDate = start
        }
        method = existing.method
        crew = existing.crew
        workingDays = Set(existing.workingDays)
        if let rows = existing.rowCountOverride { rowCountText = "\(rows)" }
        if let hours = existing.estimatedLabourHours { labourHoursText = hours.formatted() }
        notes = existing.notes
    }

    private func save() {
        let existing = pruningStore.setup(for: paddock.id)
        let setup = PruningBlockSetup(
            id: existing?.id,
            vineyardId: vineyardId,
            paddockId: paddock.id,
            seasonYear: existing?.seasonYear ?? PruningSeasonId.currentSeasonYear,
            startDate: hasStartDate ? startDate : nil,
            dueDate: hasDueDate ? dueDate : nil,
            method: method,
            crew: crew.trimmingCharacters(in: .whitespaces),
            workingDays: workingDays.sorted(),
            rowCountOverride: needsRowCount ? Int(rowCountText) : existing?.rowCountOverride,
            estimatedLabourHours: Double(labourHoursText.replacingOccurrences(of: ",", with: ".")),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        pruningStore.upsertSetup(setup)
        dismiss()
    }
}
