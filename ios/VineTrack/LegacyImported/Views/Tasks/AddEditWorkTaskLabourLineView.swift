import SwiftUI

/// Optional piece-rate capability for the labour sheet (sql/188).
///
/// Supplied by hosts that already know which rows a job covers — the Pruning
/// Activity editor, where blocks and quarters are chosen before labour. When
/// present the sheet offers the Hourly / Piece Rate choice and owns writing
/// `work_tasks.costing_method`. When absent the sheet behaves exactly as it
/// always has, so every existing caller is untouched and every legacy task
/// stays hourly.
struct WorkTaskCostingContext: Equatable {
    let taskId: UUID
    /// Vines under the rows already selected, used as the DEFAULT piece-rate
    /// quantity so the operator never re-enters a number the app knows.
    var suggestedVineCount: Int?

    init(taskId: UUID, suggestedVineCount: Int? = nil) {
        self.taskId = taskId
        self.suggestedVineCount = suggestedVineCount
    }
}

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
    @Environment(WorkTaskSyncService.self) private var workTaskSync
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let workTaskId: UUID
    let vineyardId: UUID
    let existingLine: WorkTaskLabourLine?
    /// Date the line defaults to for a new entry — normally the task's own date.
    let defaultWorkDate: Date
    /// Non-nil enables the Hourly / Piece Rate choice.
    let costingContext: WorkTaskCostingContext?

    @State private var workDate: Date = Date()
    @State private var operatorCategoryId: UUID?
    @State private var workerTypeText: String = ""
    @State private var workerCountText: String = "1"
    @State private var hoursPerWorkerText: String = ""
    @State private var hourlyRateText: String = ""
    @State private var notes: String = ""
    @State private var showIssues: Bool = false
    @State private var showDelete: Bool = false
    @State private var costingMethod: WorkTaskCostingMethod = .hourly
    @State private var ratePerVineText: String = ""
    @State private var vineCountText: String = ""

    init(
        workTaskId: UUID,
        vineyardId: UUID,
        existingLine: WorkTaskLabourLine? = nil,
        defaultWorkDate: Date = Date(),
        costingContext: WorkTaskCostingContext? = nil
    ) {
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.existingLine = existingLine
        self.defaultWorkDate = defaultWorkDate
        self.costingContext = costingContext
    }

    private var isEditing: Bool { existingLine != nil }
    private var canDelete: Bool { accessControl?.canDelete ?? false }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }
    /// Supervisors and above — may agree a rate in the field.
    private var canEnterPricing: Bool { accessControl?.canEnterPricing ?? false }
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

    // MARK: Piece rate (sql/188)

    /// Offered when the host supplies a costing context and the user may agree a
    /// price — supervisors included, because they are the ones settling the rate
    /// with the crew at the vine.
    private var supportsPieceRate: Bool {
        costingContext != nil && canEnterPricing
    }

    private var isPieceRate: Bool {
        supportsPieceRate && costingMethod == .pieceRate
    }

    /// True once this job carries an agreed price. Entering a price and
    /// REVISITING one are different authorities.
    private var isAlreadyPriced: Bool {
        (linkedTask?.pieceRatePerVine ?? 0) > 0
    }

    /// A supervisor may set the price once; reviewing or changing it afterwards
    /// is owner/manager work, so the figures are withheld rather than shown
    /// read-only — an amount on screen is exactly what "review" means.
    private var isPricingLocked: Bool {
        isAlreadyPriced && !canViewFinancials
    }

    /// Who may see a money amount for THIS job: managers always, and the
    /// supervisor who is agreeing the price right now, so they can sanity-check
    /// the total before committing to it.
    private var canSeePieceCost: Bool {
        canViewFinancials || (isPieceRate && !isPricingLocked)
    }

    private var linkedTask: WorkTask? {
        guard let costingContext else { return nil }
        return store.workTasks.first { $0.id == costingContext.taskId }
    }

    private var ratePerVine: Double? { parsed(ratePerVineText) }

    private var vineCount: Int? {
        let trimmed = vineCountText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    private var pieceIssues: [PieceRateCosting.PieceRateIssue] {
        PieceRateCosting.validate(ratePerVine: ratePerVine, vineCount: vineCount)
    }

    private var pieceCost: Double? {
        PieceRateCosting.cost(vineCount: vineCount, ratePerVine: ratePerVine)
    }

    private func pieceIssue(_ field: PieceRateCosting.PieceRateField) -> String? {
        guard showIssues else { return nil }
        return PieceRateCosting.message(pieceIssues, for: field)
    }

    /// On a piece-rate job people and hours are OPTIONAL operational history, so
    /// they must never block the save. A line is written only when BOTH are
    /// present and positive.
    private var recordsOptionalHours: Bool {
        (workerCount ?? 0) > 0 && (hoursPerWorker ?? 0) > 0
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
        guard showIssues, !isPieceRate else { return nil }
        return WorkTaskLabourCosting.message(issues, for: field)
    }

    var body: some View {
        NavigationStack {
            Form {
                if supportsPieceRate {
                    costingMethodSection
                }
                labourTypeSection
                if isPieceRate {
                    pieceRateSection
                }
                effortSection
                if canViewFinancials, !isPieceRate {
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

    /// THE single switch between the two costing methods (sql/188). Hourly and
    /// piece-rate totals are never summed — choosing one here is what decides
    /// which figure this job is costed on.
    @ViewBuilder
    private var costingMethodSection: some View {
        Section {
            Picker("Costing method", selection: $costingMethod) {
                ForEach(WorkTaskCostingMethod.allCases) { method in
                    Text(method.label).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isPricingLocked)
        } header: {
            Text("How is this job paid?")
        } footer: {
            if isPricingLocked {
                Text("This job has already been priced. Ask an owner or manager to review or change how it is paid.")
            } else {
                Text(isPieceRate
                     ? "Paid per vine. The rate you agree is multiplied by the vines in the rows selected for this job — hours never change a piece-rate cost."
                     : "Paid per hour. People × hours per person × hourly rate.")
            }
        }
    }

    /// The agreed piece rate and the quantity it applies to. The quantity is
    /// pre-filled from the rows already selected, so the operator confirms a
    /// number rather than counting one.
    @ViewBuilder
    private var pieceRateSection: some View {
        if isPricingLocked {
            lockedPricingSection
        } else {
            pieceRateEntrySection
        }
    }

    /// Shown to a supervisor reopening a job they already priced. The agreed
    /// figures are withheld deliberately — reviewing a price is owner/manager
    /// work, and showing the amount read-only would BE the review.
    @ViewBuilder
    private var lockedPricingSection: some View {
        Section {
            Label("Priced per vine", systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VineyardTheme.leafGreen)
        } header: {
            Text("Piece rate")
        } footer: {
            Text("The agreed rate is locked. Ask an owner or manager to review or change it. You can still record hours below.")
        }
    }

    @ViewBuilder
    private var pieceRateEntrySection: some View {
        Section {
            HStack {
                Text("Rate per vine")
                Spacer()
                TextField("0.00", text: $ratePerVineText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            HStack {
                Text("Vines in this job")
                Spacer()
                TextField("0", text: $vineCountText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            if let suggested = costingContext?.suggestedVineCount, suggested > 0, vineCount != suggested, !isPricingLocked {
                Button {
                    vineCountText = String(suggested)
                } label: {
                    Text("Use \(PieceRateCosting.vineCountLabel(suggested)) vines from the selected rows")
                        .font(.caption.weight(.semibold))
                }
            }
        } header: {
            Text("Piece rate")
        } footer: {
            let messages = [pieceIssue(.ratePerVine), pieceIssue(.vineCount)].compactMap { $0 }
            if messages.isEmpty {
                Text("Counted automatically from the rows selected for this job — each row's own vine count, or your manual count where you set one. Adjust it here if you agreed a different quantity.")
            } else {
                Text(messages.joined(separator: "\n")).foregroundStyle(.red)
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
            Text(isPieceRate ? "Hours worked (optional)" : "Effort")
        } footer: {
            let messages = [issue(.workerCount), issue(.hoursPerWorker)].compactMap { $0 }
            if !messages.isEmpty {
                Text(messages.joined(separator: "\n")).foregroundStyle(.red)
            } else if isPieceRate {
                Text("Optional. Hours are kept as operational history on a piece-rate job — they never change what it costs. Leave blank if you are not tracking them.")
            } else {
                Text("Hours per person — not the whole crew's combined total, and not the activity's elapsed duration.")
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
            if isPieceRate ? canSeePieceCost : canViewFinancials {
                LabeledContent(isPieceRate ? "Piece-rate cost" : "Line cost") {
                    Text((isPieceRate ? pieceCost : lineCost).map { fmt.formatCurrency($0) } ?? "Not specified")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(isPieceRate ? VineyardTheme.leafGreen : .primary)
                }
            }
        } header: {
            Text("Calculated")
        } footer: {
            if isPieceRate, canSeePieceCost {
                Text("\(PieceRateCosting.vineCountLabel(vineCount ?? 0)) vines × \(PieceRateCosting.rateLabel(ratePerVine ?? 0)) per vine = \(pieceCost.map { fmt.formatCurrency($0) } ?? "not specified"). Hours above are recorded but do not affect this.")
            } else if isPieceRate {
                Text("Hours are recorded as operational history — they do not affect what this job costs.")
            } else {
                Text("\(workerCount ?? 0) people × \(Self.decimal(hoursPerWorker ?? 0)) h = \(Self.hours(personHours)) person-hours.")
            }
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
        // Seed the costing method and piece-rate basis from the linked task, so
        // reopening the sheet shows the agreement already in force rather than
        // silently defaulting back to hourly.
        if let task = linkedTask {
            costingMethod = task.costingMethod
            // A role that may not review the price never receives it, not even
            // into a field it cannot edit.
            if !isPricingLocked {
                if let rate = task.pieceRatePerVine {
                    ratePerVineText = Self.decimal(rate)
                }
                if let vines = task.pieceVineCount ?? costingContext?.suggestedVineCount, vines > 0 {
                    vineCountText = String(vines)
                }
            }
        }
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
        if isPricingLocked {
            // The agreement is untouchable for this role — only the optional
            // hours are written, and the task's costing basis is left alone.
            guard recordsOptionalHours, let workerCount, let hoursPerWorker else {
                dismiss()
                return
            }
            persistLine(workerCount: workerCount, hoursPerWorker: hoursPerWorker, rate: nil)
        } else if isPieceRate {
            guard pieceIssues.isEmpty else { return }
            savePieceRate()
        } else {
            guard issues.isEmpty, let workerCount, let hoursPerWorker else { return }
            applyCostingMethod(.hourly)
            persistLine(workerCount: workerCount, hoursPerWorker: hoursPerWorker, rate: rateProvided ? hourlyRate : nil)
        }
        dismiss()
    }

    /// Piece rate: the AGREEMENT lives on the task (`costing_method`,
    /// `piece_rate_per_vine`, `piece_vine_count`), so a completed job keeps the
    /// quantity it was priced on. Hours, if given, are written as an ordinary
    /// labour line for operational history and never drive the cost.
    private func savePieceRate() {
        applyCostingMethod(.pieceRate)
        guard recordsOptionalHours, let workerCount, let hoursPerWorker else { return }
        persistLine(workerCount: workerCount, hoursPerWorker: hoursPerWorker, rate: nil)
    }

    /// Writes the task's costing basis. No-op without a costing context, which
    /// is what keeps every existing caller — and every legacy task — hourly.
    private func applyCostingMethod(_ method: WorkTaskCostingMethod) {
        guard var task = linkedTask, !isPricingLocked else { return }
        let ratePerVine = method == .pieceRate ? self.ratePerVine : task.pieceRatePerVine
        let vineCount = method == .pieceRate ? self.vineCount : task.pieceVineCount
        guard task.costingMethod != method
                || task.pieceRatePerVine != ratePerVine
                || task.pieceVineCount != vineCount else { return }
        task.costingMethod = method
        // Switching back to hourly KEEPS the previous piece-rate snapshot: the
        // method alone decides the cost, and preserving it means a job that was
        // already priced can be restored without re-agreeing the quantity.
        task.pieceRatePerVine = ratePerVine
        task.pieceVineCount = vineCount
        store.updateWorkTask(task)
        Task { await workTaskSync.syncForSelectedVineyard() }
    }

    private func persistLine(workerCount: Int, hoursPerWorker: Double, rate: Double?) {
        var line = existingLine ?? WorkTaskLabourLine(workTaskId: workTaskId, vineyardId: vineyardId)
        line.workTaskId = workTaskId
        line.vineyardId = vineyardId
        line.workDate = workDate
        line.operatorCategoryId = operatorCategoryId
        line.workerType = resolvedLabourType.trimmingCharacters(in: .whitespacesAndNewlines)
        line.workerCount = workerCount
        line.hoursPerWorker = hoursPerWorker
        line.hourlyRate = rate
        line.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if isEditing {
            store.updateWorkTaskLabourLine(line)
        } else {
            store.addWorkTaskLabourLine(line)
        }
        // The line's own sync service owns the push; the id is client-minted so a
        // retry upserts rather than duplicating.
        Task { await labourLineSync.syncForSelectedVineyard() }
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " h"
    }
}
