import SwiftUI

/// Row-quarter progress screen for one block: tap quarters (or select a row
/// range), then "Record Pruning" records an entry with crew and hours — and
/// can optionally create one linked, completed Work Task in the same flow.
struct PruningBlockDetailView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    let paddock: Paddock
    let pruningStore: PruningStore

    @State private var selectedSegments: Set<PruningSegment> = []
    @State private var showEntrySheet: Bool = false
    @State private var showSetupSheet: Bool = false
    @State private var rangeFromIndex: Int = 0
    @State private var rangeToIndex: Int = 0
    @State private var entryPendingReversal: PruningEntry?
    @State private var linkedTask: WorkTask?

    private var setup: PruningBlockSetup? { pruningStore.setup(for: paddock.id) }
    private var entries: [PruningEntry] { pruningStore.entries(for: paddock.id) }
    private var metrics: PruningBlockMetrics {
        PruningCalculator.metrics(paddock: paddock, setup: setup, entries: entries)
    }

    /// The block's ACTUAL rows (configured paddock rows in stored order, or
    /// clearly-labelled fallback rows generated from the manual row count).
    private var rows: [PruningRowRef] { metrics.rows }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if metrics.rowCount == 0 {
                    setupPromptCard
                } else {
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
        .safeAreaInset(edge: .bottom) {
            if !selectedSegments.isEmpty {
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
                defaultWorker: setup?.crew ?? ""
            ) {
                selectedSegments.removeAll()
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
                Text(metrics.fractionComplete.formatted(.percent.precision(.fractionLength(0))))
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

            if let elapsed = metrics.timeElapsedFraction {
                HStack(spacing: 12) {
                    legendDot(color: metrics.status.tint, text: "Work \(metrics.fractionComplete.formatted(.percent.precision(.fractionLength(0))))")
                    legendDot(color: .primary.opacity(0.55), text: "Time \(elapsed.formatted(.percent.precision(.fractionLength(0))))")
                }
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                detailRow(label: "Vines pruned", value: "\(metrics.vinesPruned.formatted()) of \(metrics.vinesTotal.formatted())")
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

        var vinesForHours = 0.0
        var hours = 0.0
        for entry in entries {
            if let entryHours = entry.labourHours, entryHours > 0 {
                vinesForHours += Double(PruningCalculator.vines(for: entry.segments, rows: rows))
                hours += entryHours
            }
        }
        let vinesPerHour: Double? = hours > 0 ? vinesForHours / hours : nil

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
                        value: rate.map { ($0 * metrics.vinesPerRow).formatted(.number.precision(.fractionLength(0))) } ?? "—",
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
                gridLegend(color: VineyardTheme.leafGreen, text: "Done")
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

    private var rangeSelector: some View {
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
            Text("to")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("To", selection: $rangeToIndex) {
                ForEach(rows.indices, id: \.self) { index in
                    Text(rows[index].label).tag(index)
                }
            }
            .pickerStyle(.menu)
            Spacer()
            Button {
                selectRange()
            } label: {
                Text("Select range")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
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
        let isDone = metrics.completed.contains(segment)
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
                    .fill(isDone ? VineyardTheme.leafGreen : (isSelected ? Color.blue : Color(.systemGray5)))
                if isDone {
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
        .accessibilityLabel("Row \(segment.row), quarter \(segment.quarter)\(isDone ? ", complete" : isSelected ? ", selected" : "")")
    }

    private func rowFullySelectedOrDone(_ row: PruningRowRef) -> Bool {
        (1...4).allSatisfy { quarter in
            let segment = row.segment(quarter: quarter)
            return metrics.completed.contains(segment) || selectedSegments.contains(segment)
        }
    }

    private func toggleWholeRow(_ row: PruningRowRef) {
        let remaining = (1...4)
            .map { row.segment(quarter: $0) }
            .filter { !metrics.completed.contains($0) }
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
                if !metrics.completed.contains(segment) {
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
                Text("Record Pruning")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Record pruning for the selected quarters")
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
                            Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.footnote.weight(.semibold))
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
        var parts: [String] = []
        if !entry.worker.isEmpty { parts.append(entry.worker) }
        if let hours = entry.labourHours, hours > 0 {
            parts.append("\(hours.formatted(.number.precision(.fractionLength(0...1)))) h")
        }
        parts.append(entry.method.label)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Entry sheet

/// Editable labour-line draft for the Record Pruning sheet. The id is minted
/// once when the row is added and becomes the `work_task_labour_lines` row id,
/// so offline replay and retries can never create a duplicate line.
private struct PruningLabourLineDraft: Identifiable {
    let id: UUID = UUID()
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
    let paddock: Paddock
    let pruningStore: PruningStore
    let vineyardId: UUID
    let segments: [PruningSegment]
    let rows: [PruningRowRef]
    let defaultMethod: PruningMethod
    let defaultWorker: String
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Work Completed") {
                    LabeledContent("Block", value: paddock.name)
                    LabeledContent("Row equivalents", value: (Double(segments.count) / 4.0).formatted(.number.precision(.fractionLength(0...2))))
                    LabeledContent("Vines (approx.)", value: "\(PruningCalculator.vines(for: segments, rows: rows).formatted())")
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Crew") {
                    TextField("Worker or crew", text: $worker)
                    if createWorkTask {
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

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    Toggle("Create a Work Task for this pruning work", isOn: $createWorkTask)
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
                } header: {
                    Text("Work Task")
                } footer: {
                    if createWorkTask {
                        Text("The Work Task reuses this record's date, block, crew, times and notes \u{2014} nothing is entered twice. It is created as completed with the labour lines below and appears in the Work Tasks tool.")
                    }
                }

                if createWorkTask {
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
                        Text("Labour Lines")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if labourLinesValid {
                                Text("Total: \(hoursLabel(labourPersonHours)) person-hours" + (hasRatedLine ? " \u{00B7} \(currencyLabel(labourTotalCost)) labour cost" : ""))
                            } else {
                                Text("Each labour line needs hours greater than zero.")
                                    .foregroundStyle(.red)
                            }
                            Text("One costing line per worker or crew \u{2014} different hours and rates per worker are supported. Rates left blank show as \u{201C}Not specified\u{201D} in the Work Task.")
                        }
                    }
                }
            }
            .navigationTitle("Record Pruning \u{2014} \(paddock.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(recordButtonTitle) { save() }
                        .fontWeight(.semibold)
                        .disabled(segments.isEmpty || (createWorkTask && !labourLinesValid))
                        .accessibilityLabel("Record pruning")
                }
            }
            .onAppear {
                method = defaultMethod
                worker = defaultWorker
            }
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
                TextField("Rate $/h", text: line.rateText)
                    .keyboardType(.decimalPad)
            }
            .font(.subheadline)
            HStack {
                Text(hoursLabel(line.wrappedValue.totalHours))
                Text("\u{00B7}")
                if let cost = line.wrappedValue.totalCost {
                    Text(currencyLabel(cost))
                } else {
                    Text("Cost not specified")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
        dataStore.addWorkTask(task)
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
                hourlyRate: draft.hourlyRate,
                notes: ""
            ))
        }
        return task.id
    }

    private func save() {
        // Make sure the season row exists before the entry references it —
        // recording work on an unconfigured block auto-creates the season.
        let season: PruningBlockSetup
        if let existing = pruningStore.setup(for: paddock.id) {
            season = existing
        } else {
            season = PruningBlockSetup(vineyardId: vineyardId, paddockId: paddock.id)
            pruningStore.upsertSetup(season)
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
