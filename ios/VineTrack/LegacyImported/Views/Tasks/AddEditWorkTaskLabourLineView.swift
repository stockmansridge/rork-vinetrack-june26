import SwiftUI

/// THE standard Work Task labour-line form — the single implementation used by
/// the Work Task editor AND the Pruning Activity editor, so the two surfaces can
/// never drift into two incompatible labour editors. Mirrors the Kotlin
/// `WorkTaskLabourLineSheet`.
///
/// A labour line belongs to the PARENT Work Task, never to a pruning allocation.
/// It owns labour type, hourly rate, number of people, hours per person, and the
/// derived person-hours and cost — all computed by `WorkTaskLabourCosting`, which
/// is mirrored 1:1 in Kotlin.
///
/// Nothing entered here is discarded when validation fails: the issues render
/// inline and the values stay put.
struct AddEditWorkTaskLabourLineView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(WorkTaskLabourLineSyncService.self) private var labourLineSync
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let workTaskId: UUID
    let vineyardId: UUID
    let existingLine: WorkTaskLabourLine?
    /// Date the line defaults to for a new entry — normally the task's own date.
    let defaultWorkDate: Date

    @State private var workDate: Date = Date()
    @State private var operatorCategoryId: UUID?
    @State private var workerTypeText: String = ""
    @State private var workerCountText: String = "1"
    @State private var hoursPerWorkerText: String = ""
    @State private var hourlyRateText: String = ""
    @State private var notes: String = ""
    @State private var showIssues: Bool = false
    @State private var showDelete: Bool = false

    init(
        workTaskId: UUID,
        vineyardId: UUID,
        existingLine: WorkTaskLabourLine? = nil,
        defaultWorkDate: Date = Date()
    ) {
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.existingLine = existingLine
        self.defaultWorkDate = defaultWorkDate
    }

    private var isEditing: Bool { existingLine != nil }
    private var canDelete: Bool { accessControl?.canDelete ?? false }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var categories: [OperatorCategory] {
        store.operatorCategories
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Labour type name actually recorded: the linked worker type when one is
    /// chosen, otherwise the free-text snapshot.
    private var resolvedLabourType: String {
        categories.first { $0.id == operatorCategoryId }?.name ?? workerTypeText
    }

    private var workerCount: Int? { Int(workerCountText.trimmingCharacters(in: .whitespaces)) }

    private func parsed(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private var hoursPerWorker: Double? { parsed(hoursPerWorkerText) }
    private var hourlyRate: Double? { parsed(hourlyRateText) }
    private var rateProvided: Bool {
        !hourlyRateText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var issues: [WorkTaskLabourCosting.LabourLineIssue] {
        WorkTaskLabourCosting.validate(
            labourType: resolvedLabourType,
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate,
            rateProvided: rateProvided
        )
    }

    private var personHours: Double {
        WorkTaskLabourCosting.personHours(
            workerCount: workerCount ?? 0,
            hoursPerWorker: hoursPerWorker ?? 0
        )
    }

    private var lineCost: Double? {
        WorkTaskLabourCosting.lineCost(
            workerCount: workerCount ?? 0,
            hoursPerWorker: hoursPerWorker ?? 0,
            hourlyRate: rateProvided ? hourlyRate : nil
        )
    }

    private func issue(_ field: WorkTaskLabourCosting.LabourLineField) -> String? {
        guard showIssues else { return nil }
        return WorkTaskLabourCosting.message(issues, for: field)
    }

    var body: some View {
        NavigationStack {
            Form {
                labourTypeSection
                effortSection
                if canViewFinancials {
                    rateSection
                }
                calculationSection
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
                                Label("Remove Labour Line", systemImage: "trash")
                                Spacer()
                            }
                        }
                    } footer: {
                        Text("The Work Task itself is kept — only this labour line is removed.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Labour" : "Add Labour")
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
            .alert("Remove Labour Line", isPresented: $showDelete) {
                Button("Remove", role: .destructive) {
                    if let line = existingLine {
                        store.deleteWorkTaskLabourLine(line.id)
                        Task { await labourLineSync.syncForSelectedVineyard() }
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var labourTypeSection: some View {
        Section {
            Picker("Labour type", selection: $operatorCategoryId) {
                Text("Choose labour type").tag(UUID?.none)
                ForEach(categories) { category in
                    Text(labourTypeLabel(category)).tag(UUID?.some(category.id))
                }
            }
            .onChange(of: operatorCategoryId) { _, newValue in
                guard let newValue, let category = categories.first(where: { $0.id == newValue }) else { return }
                workerTypeText = category.name
                // The labour type's saved rate is the DEFAULT; an explicit edit
                // is never overwritten.
                if let rate = WorkTaskLabourCosting.defaultRate(category) {
                    hourlyRateText = Self.decimal(rate)
                }
            }
            if categories.isEmpty {
                Text("Add labour types in Settings → Worker Types to get saved hourly rates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DatePicker("Work date", selection: $workDate, displayedComponents: .date)
        } header: {
            Text("Labour type")
        } footer: {
            if let message = issue(.labourType) {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Selecting a labour type supplies its saved hourly rate.")
            }
        }
    }

    @ViewBuilder
    private var effortSection: some View {
        Section {
            HStack {
                Text("Number of people")
                Spacer()
                TextField("0", text: $workerCountText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            HStack {
                Text("Hours per person")
                Spacer()
                TextField("0", text: $hoursPerWorkerText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
        } header: {
            Text("Effort")
        } footer: {
            let messages = [issue(.workerCount), issue(.hoursPerWorker)].compactMap { $0 }
            if messages.isEmpty {
                Text("Hours per person — not the whole crew's combined total, and not the activity's elapsed duration.")
            } else {
                Text(messages.joined(separator: "\n")).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var rateSection: some View {
        Section {
            HStack {
                Text("Hourly rate")
                Spacer()
                TextField("0", text: $hourlyRateText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
        } header: {
            Text("Rate")
        } footer: {
            if let message = issue(.hourlyRate) {
                Text(message).foregroundStyle(.red)
            } else {
                Text("This is the authoritative rate for the labour cost of this line.")
            }
        }
    }

    @ViewBuilder
    private var calculationSection: some View {
        Section {
            LabeledContent("Person-hours") {
                Text(Self.hours(personHours))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            if canViewFinancials {
                LabeledContent("Line cost") {
                    Text(lineCost.map { fmt.formatCurrency($0) } ?? "Not specified")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Calculated")
        } footer: {
            Text("\(workerCount ?? 0) people × \(Self.decimal(hoursPerWorker ?? 0)) h = \(Self.hours(personHours)) person-hours.")
        }
    }

    private func labourTypeLabel(_ category: OperatorCategory) -> String {
        guard canViewFinancials, let rate = WorkTaskLabourCosting.defaultRate(category) else {
            return category.name
        }
        return "\(category.name) · \(fmt.formatCurrency(rate))/h"
    }

    // MARK: Load / save

    private func load() {
        guard let line = existingLine else {
            workDate = defaultWorkDate
            return
        }
        workDate = line.workDate
        operatorCategoryId = line.operatorCategoryId
        workerTypeText = line.workerType
        workerCountText = String(line.workerCount)
        hoursPerWorkerText = line.hoursPerWorker > 0 ? Self.decimal(line.hoursPerWorker) : ""
        hourlyRateText = line.hourlyRate.map { Self.decimal($0) } ?? ""
        notes = line.notes
    }

    private func save() {
        showIssues = true
        guard issues.isEmpty, let workerCount, let hoursPerWorker else { return }

        var line = existingLine ?? WorkTaskLabourLine(workTaskId: workTaskId, vineyardId: vineyardId)
        line.workTaskId = workTaskId
        line.vineyardId = vineyardId
        line.workDate = workDate
        line.operatorCategoryId = operatorCategoryId
        line.workerType = resolvedLabourType.trimmingCharacters(in: .whitespacesAndNewlines)
        line.workerCount = workerCount
        line.hoursPerWorker = hoursPerWorker
        line.hourlyRate = rateProvided ? hourlyRate : nil
        line.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if isEditing {
            store.updateWorkTaskLabourLine(line)
        } else {
            store.addWorkTaskLabourLine(line)
        }
        // The line's own sync service owns the push; the id is client-minted so a
        // retry upserts rather than duplicating.
        Task { await labourLineSync.syncForSelectedVineyard() }
        dismiss()
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " h"
    }
}
