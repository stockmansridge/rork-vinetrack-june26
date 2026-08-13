import SwiftUI

/// The add/edit form for ONE pruning-activity labour line (sql/190) — the iOS
/// twin of the Kotlin `PruningActivityLabourLineSheet`.
///
/// A line belongs to the ACTIVITY. It owns labour type, hourly rate, number of
/// people and hours per person, and the derived person-hours and cost — all
/// computed by `PruningActivityLabourCosting`, which mirrors the SQL generated
/// columns and the Kotlin object 1:1.
///
/// When a Work Task is linked this is ALSO the one place the job is priced: the
/// Hourly / Piece Rate choice lives here, so labour is never asked for twice
/// across two screens.
///
/// Piece rate is a property of the linked Work Task (sql/188), NOT a labour
/// type: choosing it writes `work_tasks.costing_method` and the agreed rate, and
/// any hours recorded alongside it are saved as an UNRATED pruning labour line —
/// operational history that never moves the cost. A synthetic "piece rate"
/// labour line is never created, because that is exactly the double-count that
/// SQL 189/190 exist to prevent.
///
/// Nothing entered is discarded when validation fails: issues render inline and
/// the values stay put.
struct AddEditPruningActivityLabourLineView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(PruningSyncService.self) private var pruningSync
    @Environment(WorkTaskSyncService.self) private var workTaskSync
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    let activityId: UUID
    let vineyardId: UUID
    let existingLine: PruningActivityLabourLine?
    /// Date a new line defaults to — normally the activity's own date.
    let defaultWorkDate: Date
    /// Display position of this line within the activity.
    let nextLineIndex: Int
    /// Non-nil lets this sheet choose Hourly or Piece Rate for the linked task.
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
        activityId: UUID,
        vineyardId: UUID,
        existingLine: PruningActivityLabourLine? = nil,
        defaultWorkDate: Date = Date(),
        nextLineIndex: Int = 0,
        costingContext: WorkTaskCostingContext? = nil
    ) {
        self.activityId = activityId
        self.vineyardId = vineyardId
        self.existingLine = existingLine
        self.defaultWorkDate = defaultWorkDate
        self.nextLineIndex = nextLineIndex
        self.costingContext = costingContext
    }

    private var isEditing: Bool { existingLine != nil }
    private var canDelete: Bool { accessControl?.canDelete ?? false }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }
    /// Supervisors and above — they settle the rate with the crew at the vine.
    private var canEnterPricing: Bool { accessControl?.canEnterPricing ?? false }
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var categories: [OperatorCategory] {
        store.operatorCategories
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The labour type actually recorded: the linked worker type when one is
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

    /// An EMPTY rate field is a deliberate "no rate entered", not zero. The line
    /// still records its hours; its cost is simply not specified.
    private var rateProvided: Bool {
        !hourlyRateText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var issues: [WorkTaskLabourCosting.LabourLineIssue] {
        PruningActivityLabourCosting.validate(
            labourType: resolvedLabourType,
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate,
            rateProvided: rateProvided
        )
    }

    private func issue(_ field: WorkTaskLabourCosting.LabourLineField) -> String? {
        // On a piece-rate job the hourly fields are optional history, so their
        // validation must never block the agreement being saved.
        guard showIssues, !isPieceRate else { return nil }
        return WorkTaskLabourCosting.message(issues, for: field)
    }

    private var personHours: Double {
        PruningActivityLabourCosting.personHours(
            workerCount: workerCount ?? 0,
            hoursPerWorker: hoursPerWorker ?? 0
        )
    }

    private var lineCost: Double? {
        guard rateProvided, let hourlyRate else { return nil }
        return personHours * max(hourlyRate, 0)
    }

    // MARK: Piece rate (sql/188) — an agreement on the TASK, never a labour line

    private var linkedTask: WorkTask? {
        guard let costingContext else { return nil }
        return store.workTasks.first { $0.id == costingContext.taskId }
    }

    private var supportsPieceRate: Bool {
        costingContext != nil && linkedTask != nil && canEnterPricing
    }

    private var isPieceRate: Bool { supportsPieceRate && costingMethod == .pieceRate }

    /// A supervisor may set the price ONCE; revisiting it afterwards is
    /// owner/manager work. The figures are WITHHELD rather than shown read-only
    /// — an amount on screen is exactly what "review" means.
    private var isPricingLocked: Bool {
        guard let task = linkedTask else { return false }
        let isPriced = (task.pieceRatePerVine ?? 0) > 0
        return isPriced && !canViewFinancials
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

    /// Managers always; plus the supervisor agreeing the price right now, so they
    /// can sanity-check the total before committing to it.
    private var canSeePieceCost: Bool {
        canViewFinancials || (isPieceRate && !isPricingLocked)
    }

    private func pieceIssue(_ field: PieceRateCosting.PieceRateField) -> String? {
        guard showIssues else { return nil }
        return PieceRateCosting.message(pieceIssues, for: field)
    }

    /// On a piece-rate job people and hours are OPTIONAL operational history, so
    /// they must never block the save.
    private var recordsOptionalHours: Bool {
        (workerCount ?? 0) > 0 && (hoursPerWorker ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                if supportsPieceRate {
                    costingMethodSection
                }
                if isPieceRate {
                    pieceRateSection
                }
                labourTypeSection
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
                        Text("The pruning activity itself is kept — only this labour line is removed.")
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
                        store.deletePruningActivityLabourLine(line.id)
                        Task { await pruningSync.syncForSelectedVineyard() }
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the line for your whole team. The activity's other labour lines are untouched.")
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Sections

    /// THE single switch between the two costing methods (sql/188). Choosing one
    /// here decides which figure this job is costed on — the two are NEVER
    /// summed, and a piece-rate job's hourly lines stay unrated history.
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
                     : "Paid per hour. People × hours per person × hourly rate, recorded on this activity.")
            }
        }
    }

    @ViewBuilder
    private var pieceRateSection: some View {
        Section {
            if isPricingLocked {
                // The agreed figures are withheld deliberately: reviewing a price
                // is owner/manager work, and showing the amount read-only would
                // BE the review.
                Label(
                    "The agreed rate is locked. Ask an owner or manager to review or change it. You can still record hours below.",
                    systemImage: "lock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
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
                if let suggested = costingContext?.suggestedVineCount, suggested > 0, vineCount != suggested {
                    Button("Use \(PieceRateCosting.vineCountLabel(suggested)) vines from the selected rows") {
                        vineCountText = String(suggested)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        } header: {
            Text("Piece rate")
        } footer: {
            if let message = pieceIssue(.ratePerVine) ?? pieceIssue(.vineCount) {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Counted automatically from the rows selected for this job. Adjust it here if you agreed a different quantity.")
            }
        }
    }

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
                Text("A worker CATEGORY — \"Contractor\", \"Casual\" — never a person's name. Selecting one supplies its saved hourly rate.")
            }
        }
    }

    @ViewBuilder
    private var effortSection: some View {
        Section {
            HStack {
                Text("Number of people")
                Spacer()
                TextField("1", text: $workerCountText)
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
            if let message = issue(.workerCount) ?? issue(.hoursPerWorker) {
                Text(message).foregroundStyle(.red)
            } else if isPieceRate {
                Text("Optional. Hours are kept as operational history on a piece-rate job — they never change what it costs. Leave blank if you are not tracking them.")
            } else {
                Text("Add one line per crew or rate. Two contractors on different rates are two lines, not an average.")
            }
        }
    }

    @ViewBuilder
    private var rateSection: some View {
        Section {
            HStack {
                Text("Hourly rate")
                Spacer()
                TextField("Optional", text: $hourlyRateText)
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
                Text("Leave blank if no rate has been agreed. The hours still count; the cost is reported as not specified rather than $0.00.")
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
                Text("\(workerCount ?? 0) people × \(Self.decimal(hoursPerWorker ?? 0)) h = \(Self.hours(personHours)) person-hours. Counted once for the whole activity, never per block.")
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

        if isPieceRate, isPricingLocked {
            // The agreement is untouchable for this role — only the optional
            // hours are written, and the task's costing basis is left alone.
            guard recordsOptionalHours, let workerCount, let hoursPerWorker else {
                dismiss()
                return
            }
            persistLine(workerCount: workerCount, hoursPerWorker: hoursPerWorker, rate: nil)
            dismiss()
            return
        }

        if isPieceRate {
            guard pieceIssues.isEmpty else { return }
            applyCostingMethod(.pieceRate)
            // Hours, if given, become an UNRATED pruning labour line: real work,
            // no money. Never a synthetic "piece rate" labour line.
            if recordsOptionalHours, let workerCount, let hoursPerWorker {
                persistLine(workerCount: workerCount, hoursPerWorker: hoursPerWorker, rate: nil)
            }
            dismiss()
            return
        }

        guard issues.isEmpty, let workerCount, let hoursPerWorker else { return }
        // Switching back to hourly clears the piece-rate basis, so this
        // activity's own lines become the whole cost.
        applyCostingMethod(.hourly)
        persistLine(
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            rate: rateProvided ? hourlyRate : nil
        )
        dismiss()
    }

    /// Writes the linked task's costing basis. No-op without a costing context,
    /// which is what keeps every legacy activity and every unlinked one hourly.
    private func applyCostingMethod(_ method: WorkTaskCostingMethod) {
        guard supportsPieceRate, var task = linkedTask, !isPricingLocked else { return }
        let ratePerVine = method == .pieceRate ? self.ratePerVine : task.pieceRatePerVine
        let vineCount = method == .pieceRate ? self.vineCount : task.pieceVineCount
        guard task.costingMethod != method
                || task.pieceRatePerVine != ratePerVine
                || task.pieceVineCount != vineCount else { return }
        task.costingMethod = method
        // Switching back to hourly KEEPS the previous snapshot: the method alone
        // decides the cost, so a job already priced can be restored without
        // re-agreeing the quantity.
        task.pieceRatePerVine = ratePerVine
        task.pieceVineCount = vineCount
        store.updateWorkTask(task)
        Task { await workTaskSync.syncForSelectedVineyard() }
    }

    private func persistLine(workerCount: Int, hoursPerWorker: Double, rate: Double?) {
        var line = existingLine ?? PruningActivityLabourLine(
            pruningActivityId: activityId,
            vineyardId: vineyardId,
            lineIndex: nextLineIndex
        )
        line.pruningActivityId = activityId
        line.vineyardId = vineyardId
        line.workDate = workDate
        line.operatorCategoryId = operatorCategoryId
        line.workerType = resolvedLabourType.trimmingCharacters(in: .whitespacesAndNewlines)
        line.workerCount = workerCount
        line.hoursPerWorker = hoursPerWorker
        line.hourlyRate = rate
        line.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if isEditing {
            store.updatePruningActivityLabourLine(line)
        } else {
            store.addPruningActivityLabourLine(line)
        }
        // The activity's whole set is pushed as ONE desired-state save, so the
        // id being client-minted means a retry upserts rather than duplicating.
        Task { await pruningSync.syncForSelectedVineyard() }
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " h"
    }
}
