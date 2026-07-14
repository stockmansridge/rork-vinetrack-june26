import SwiftUI

/// Row-quarter progress screen for one block: tap quarters (or select a row
/// range), then "Complete Today" records a daily entry with crew and hours.
struct PruningBlockDetailView: View {
    @Environment(MigratedDataStore.self) private var store
    let paddock: Paddock
    let pruningStore: PruningStore

    @State private var selectedSegments: Set<PruningSegment> = []
    @State private var showEntrySheet: Bool = false
    @State private var showSetupSheet: Bool = false
    @State private var rangeFromIndex: Int = 0
    @State private var rangeToIndex: Int = 0

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
                Text("Complete Today")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
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
                        }
                        Spacer()
                        Text("\(entry.rowEquivalents.formatted(.number.precision(.fractionLength(0...2)))) rows")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                        Button(role: .destructive) {
                            pruningStore.deleteEntry(id: entry.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
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

private struct PruningEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
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
                    TextField("Labour hours", text: $labourHoursText)
                        .keyboardType(.decimalPad)
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
            }
            .navigationTitle("Complete Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(segments.isEmpty)
                }
            }
            .onAppear {
                method = defaultMethod
                worker = defaultWorker
            }
        }
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
        let entry = PruningEntry(
            vineyardId: vineyardId,
            paddockId: paddock.id,
            seasonId: season.id,
            date: date,
            segments: segments,
            worker: worker.trimmingCharacters(in: .whitespaces),
            labourHours: Double(labourHoursText.replacingOccurrences(of: ",", with: ".")),
            startTime: includeTimes ? startTime : nil,
            finishTime: includeTimes ? finishTime : nil,
            method: method,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            estimatedVines: PruningCalculator.vines(for: segments, rows: rows)
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
