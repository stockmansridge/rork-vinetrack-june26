import SwiftUI

/// Record Actual Yield — `Basic | Detailed`.
///
/// Basic preserves the original single actual-yield entry (one
/// `HistoricalYieldRecord` per save). Detailed is the picking log: one
/// `PickingRecord` per pick, with many picks allowed for the same
/// Block + Variety + Vintage.
///
/// Aggregation precedence: when detailed picking records exist for a
/// Block + Variety + Vintage, their summed weight IS the actual yield for
/// that combination — a Basic actual for the same combination is superseded,
/// never added on top.
struct RecordActualYieldSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case basic = "Basic"
        case detailed = "Detailed"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(HistoricalYieldRecordSyncService.self) private var historicalYieldSync
    @Environment(PickingRecordSyncService.self) private var pickingRecordSync

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    let initialMode: Mode

    /// Non-nil when the sheet edits an existing picking record instead of
    /// creating new ones. Editing reuses the exact Detailed form: the same
    /// fields, the same block/variety/clone dependency resets, and the same
    /// sync path (dirty-mark → upsert, last-write-wins). Server-authoritative
    /// fields are never written: `vintage` re-derives from the picked date on
    /// the server and `grape_value` is a generated column.
    let editingRecord: PickingRecord?

    init(initialMode: Mode = .basic) {
        self.initialMode = initialMode
        self.editingRecord = nil
    }

    /// Edit an existing picking record — prefills every Detailed field,
    /// preserving the record's historical sugar unit.
    init(editing record: PickingRecord) {
        self.initialMode = .detailed
        self.editingRecord = record
        _mode = State(initialValue: .detailed)
        _didApplyInitialMode = State(initialValue: true)
        _pickDate = State(initialValue: record.pickedAt)
        _detailPaddockId = State(initialValue: record.paddockId)
        let trimmedVariety = record.varietyName.trimmingCharacters(in: .whitespacesAndNewlines)
        _selectedVarietyKey = State(initialValue: trimmedVariety.isEmpty ? nil : PickingYieldAggregator.normalisedVariety(trimmedVariety))
        _freeTextVariety = State(initialValue: trimmedVariety)
        _selectedClone = State(initialValue: record.clone)
        _weightText = State(initialValue: Self.numberText(record.weightKg))
        _sugarText = State(initialValue: Self.numberText(record.sugarValue))
        if let unit = record.sugarMeasurement {
            _sugarUnit = State(initialValue: unit)
        }
        _phText = State(initialValue: Self.numberText(record.ph))
        _taText = State(initialValue: Self.numberText(record.taGPerL))
        _purpose = State(initialValue: record.purpose)
        _sold = State(initialValue: record.sold)
        _soldTo = State(initialValue: record.soldTo ?? "")
        _priceText = State(initialValue: Self.numberText(record.pricePerTonne))
        _detailNotes = State(initialValue: record.notes)
    }

    private var isEditing: Bool { editingRecord != nil }

    /// Plain decimal text for prefilling numeric fields (no grouping, no
    /// trailing `.0` for whole numbers) so the decimal-pad parser round-trips.
    private static func numberText(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.truncatingRemainder(dividingBy: 1) == 0, abs(value) < 1_000_000_000 {
            return String(Int(value))
        }
        return String(value)
    }

    @State private var mode: Mode = .basic
    @State private var didApplyInitialMode: Bool = false

    // MARK: Basic state (unchanged workflow)
    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var season: String = ""
    @State private var selectedPaddockId: UUID?
    @State private var variety: String = ""
    @State private var actualYieldText: String = ""
    @State private var notes: String = ""
    @FocusState private var yieldFocused: Bool

    // MARK: Detailed state (picking log)
    @State private var pickDate: Date = Date()
    @State private var detailPaddockId: UUID?
    @State private var selectedVarietyKey: String?
    @State private var selectedClone: String?
    @State private var freeTextVariety: String = ""
    @State private var weightText: String = ""
    @State private var sugarText: String = ""
    @State private var sugarUnit: SugarMeasurementUnit = .baume
    @State private var phText: String = ""
    @State private var taText: String = ""
    @State private var purpose: String = ""
    @State private var sold: Bool = false
    @State private var soldTo: String = ""
    @State private var priceText: String = ""
    @State private var detailNotes: String = ""
    @State private var savedFeedback: Bool = false
    @FocusState private var weightFocused: Bool

    private var paddocks: [Paddock] {
        store.orderedPaddocks
    }

    private var selectedPaddock: Paddock? {
        guard let id = selectedPaddockId else { return nil }
        return paddocks.first(where: { $0.id == id })
    }

    private var parsedYield: Double? {
        let trimmed = actualYieldText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private var canSaveBasic: Bool {
        guard let yield = parsedYield, yield >= 0 else { return false }
        return selectedPaddockId != nil && store.selectedVineyardId != nil
    }

    // MARK: Detailed derived values

    private var detailPaddock: Paddock? {
        guard let id = detailPaddockId else { return nil }
        return paddocks.first(where: { $0.id == id })
    }

    /// One selectable variety per distinct resolved variety on the block.
    private struct VarietyOption: Identifiable, Hashable {
        let id: String            // normalised display name
        let name: String
        let varietyId: UUID?
        let varietyKey: String?
    }

    private var varietyOptions: [VarietyOption] {
        guard let paddock = detailPaddock else { return [] }
        var seen: Set<String> = []
        var options: [VarietyOption] = []
        for allocation in paddock.varietyAllocations {
            let resolved = PaddockVarietyResolver.resolve(allocation: allocation, varieties: store.grapeVarieties)
            guard let name = resolved.displayName, !name.isEmpty else { continue }
            let key = PickingYieldAggregator.normalisedVariety(name)
            guard seen.insert(key).inserted else { continue }
            options.append(VarietyOption(
                id: key,
                name: name,
                varietyId: resolved.varietyId ?? allocation.varietyId,
                varietyKey: allocation.varietyKey
            ))
        }
        // Editing: the record's original variety stays selectable even when the
        // block's configuration changed since the pick was recorded, so an edit
        // never silently loses the historical variety snapshot.
        if let record = editingRecord, record.paddockId == paddock.id {
            let name = record.varietyName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let key = PickingYieldAggregator.normalisedVariety(name)
                if seen.insert(key).inserted {
                    options.append(VarietyOption(
                        id: key,
                        name: name,
                        varietyId: record.varietyId,
                        varietyKey: record.varietyKey
                    ))
                }
            }
        }
        return options
    }

    private var selectedVarietyOption: VarietyOption? {
        guard let key = selectedVarietyKey else { return nil }
        return varietyOptions.first(where: { $0.id == key })
    }

    /// Distinct configured clones for the selected variety on the block.
    private var cloneOptions: [String] {
        guard let paddock = detailPaddock, let selected = selectedVarietyOption else { return [] }
        var seen: Set<String> = []
        var clones: [String] = []
        for allocation in paddock.varietyAllocations {
            let resolved = PaddockVarietyResolver.resolve(allocation: allocation, varieties: store.grapeVarieties)
            guard let name = resolved.displayName,
                  PickingYieldAggregator.normalisedVariety(name) == selected.id else { continue }
            guard let clone = allocation.clone?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clone.isEmpty else { continue }
            if seen.insert(clone.lowercased()).inserted {
                clones.append(clone)
            }
        }
        // Editing: keep the record's original clone selectable while the block
        // and variety still match the record — historical clone snapshots are
        // preserved even if Block Setup no longer lists them.
        if let record = editingRecord,
           record.paddockId == paddock.id,
           PickingYieldAggregator.normalisedVariety(record.varietyName) == selected.id,
           let clone = record.clone?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clone.isEmpty,
           seen.insert(clone.lowercased()).inserted {
            clones.append(clone)
        }
        return clones
    }

    /// Vintage derived from the picking date + shared season settings
    /// (mirrors the authoritative server resolver, sql/119).
    private var derivedVintage: Int {
        VintageResolver.vintageYear(
            for: pickDate,
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    private var parsedWeight: Double? {
        let trimmed = weightText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private var parsedSugar: Double? { Double(sugarText.trimmingCharacters(in: .whitespaces)) }
    private var parsedPh: Double? { Double(phText.trimmingCharacters(in: .whitespaces)) }
    private var parsedTa: Double? { Double(taText.trimmingCharacters(in: .whitespaces)) }
    private var parsedPrice: Double? { Double(priceText.trimmingCharacters(in: .whitespaces)) }

    private var resolvedDetailVarietyName: String {
        if let option = selectedVarietyOption { return option.name }
        return freeTextVariety.trimmingCharacters(in: .whitespaces)
    }

    private var calculatedGrapeValue: Double? {
        guard sold, let weight = parsedWeight, weight > 0, let price = parsedPrice else { return nil }
        return (weight / 1000.0) * price
    }

    private var canSaveDetailed: Bool {
        guard store.selectedVineyardId != nil, detailPaddockId != nil,
              let weight = parsedWeight, weight > 0 else { return false }
        // A block with configured varieties requires a selection.
        if !varietyOptions.isEmpty && selectedVarietyOption == nil { return false }
        return true
    }

    /// Running detailed total for the chosen Block + Variety + Vintage. When
    /// editing, the record being edited is excluded so the "after saving"
    /// preview reflects its NEW weight, not old + new.
    private var existingDetailedTonnes: Double? {
        guard let paddockId = detailPaddockId else { return nil }
        let varietyName = resolvedDetailVarietyName.isEmpty ? nil : resolvedDetailVarietyName
        let records = store.pickingRecords.filter { $0.id != editingRecord?.id }
        return PickingYieldAggregator.detailedActualTonnes(
            records: records,
            paddockId: paddockId,
            varietyName: varietyName,
            vintage: derivedVintage
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing {
                    Section {
                        Picker("Entry mode", selection: $mode) {
                            ForEach(Mode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        if mode == .detailed {
                            Text("Each save adds one picking record. Actual yield for a block, variety and vintage is the sum of its picking records — it replaces any Basic actual entered for the same combination.")
                        }
                    }
                }

                if mode == .basic {
                    basicSections
                } else {
                    detailedSections
                }
            }
            .navigationTitle(isEditing ? "Edit Picking Record" : "Record Actual Yield")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.success, trigger: savedFeedback)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save Changes" : "Save") {
                        if isEditing {
                            saveEdit()
                        } else if mode == .basic {
                            saveBasic()
                            dismiss()
                        } else {
                            saveDetailed()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(mode == .basic ? !canSaveBasic : !canSaveDetailed)
                }
            }
            .onAppear {
                if !didApplyInitialMode {
                    mode = initialMode
                    didApplyInitialMode = true
                }
                if selectedPaddockId == nil {
                    selectedPaddockId = paddocks.first?.id
                }
                if detailPaddockId == nil {
                    detailPaddockId = paddocks.first?.id
                    autoSelectVariety()
                }
                // Editing preserves the record's historical sugar unit; only
                // a fresh entry (or a record without sugar) uses the vineyard
                // preference as the default.
                if editingRecord?.sugarMeasurement == nil {
                    sugarUnit = store.settings.regionSettings.sugarUnit
                }
                if mode == .basic { yieldFocused = true }
            }
            .onChange(of: detailPaddockId) { _, _ in
                selectedVarietyKey = nil
                selectedClone = nil
                autoSelectVariety()
            }
            .onChange(of: selectedVarietyKey) { _, _ in
                selectedClone = nil
                autoSelectClone()
            }
        }
    }

    // MARK: - Basic (original workflow, unchanged)

    @ViewBuilder
    private var basicSections: some View {
        Section {
            Stepper(value: $year, in: 2000...2100) {
                HStack {
                    Text("Year")
                    Spacer()
                    Text("\(year, format: .number.grouping(.never))")
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Season (optional)", text: $season)
        } header: {
            Text("Season")
        }

        Section {
            if paddocks.isEmpty {
                Text("No blocks available. Add a block first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Block", selection: $selectedPaddockId) {
                    Text("Select a block").tag(UUID?.none)
                    ForEach(paddocks, id: \.id) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                }
            }
            TextField("Variety (optional)", text: $variety)
        } header: {
            Text("Block & Variety")
        } footer: {
            if let p = selectedPaddock, p.areaHectares > 0 {
                Text("Area: \(fmt.formatArea(hectares: p.areaHectares))")
            }
        }

        Section {
            HStack {
                TextField("0.00", text: $actualYieldText)
                    .keyboardType(.decimalPad)
                    .focused($yieldFocused)
                Text("t")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Actual Yield (tonnes)")
        } footer: {
            if let yield = parsedYield, let p = selectedPaddock, p.areaHectares > 0 {
                Text(fmt.formatYieldPerArea(perHectare: yield / p.areaHectares))
            } else {
                Text("Used by Cost Reports to calculate cost per tonne.")
            }
        }

        Section {
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(3...6)
        } header: {
            Text("Notes (optional)")
        }
    }

    // MARK: - Detailed (picking log)

    @ViewBuilder
    private var detailedSections: some View {
        Section {
            DatePicker("Picking date", selection: $pickDate, displayedComponents: .date)
            LabeledContent("Vintage") {
                Text(String(derivedVintage))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pick")
        } footer: {
            Text("Vintage is calculated from the picking date and the vineyard's shared season settings.")
        }

        Section {
            if paddocks.isEmpty {
                Text("No blocks available. Add a block first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Block", selection: $detailPaddockId) {
                    Text("Select a block").tag(UUID?.none)
                    ForEach(paddocks, id: \.id) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                }
            }

            if !varietyOptions.isEmpty {
                Picker("Variety", selection: $selectedVarietyKey) {
                    if varietyOptions.count > 1 {
                        Text("Select a variety").tag(String?.none)
                    }
                    ForEach(varietyOptions) { option in
                        Text(option.name).tag(String?.some(option.id))
                    }
                }
            } else if detailPaddock != nil {
                TextField("Variety (optional)", text: $freeTextVariety)
            }

            if cloneOptions.count > 1 || (isEditing && !cloneOptions.isEmpty) {
                Picker("Clone", selection: $selectedClone) {
                    Text("Not specified").tag(String?.none)
                    ForEach(cloneOptions, id: \.self) { clone in
                        Text(clone).tag(String?.some(clone))
                    }
                }
            } else if let clone = cloneOptions.first {
                LabeledContent("Clone") {
                    Text(clone).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Block, Variety & Clone")
        } footer: {
            if varietyOptions.isEmpty, detailPaddock != nil {
                Text("This block has no configured varieties. Configure them in Block setup to select variety and clone here.")
            } else if isEditing {
                Text("Changing the block resets the variety and clone; changing the variety resets the clone.")
            }
        }

        Section {
            HStack {
                TextField("0", text: $weightText)
                    .keyboardType(.decimalPad)
                    .focused($weightFocused)
                Text("kg")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Weight (kg)")
        } footer: {
            if let weight = parsedWeight, weight > 0 {
                let newTotal = (existingDetailedTonnes ?? 0) + weight / 1000.0
                Text("Vintage \(String(derivedVintage)) total for this block & variety after saving: \(newTotal, format: .number.precision(.fractionLength(2))) t")
            }
        }

        Section {
            HStack {
                TextField("Sugar", text: $sugarText)
                    .keyboardType(.decimalPad)
                Picker("", selection: $sugarUnit) {
                    ForEach(SugarMeasurementUnit.allCases) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
            HStack {
                TextField("pH", text: $phText)
                    .keyboardType(.decimalPad)
                Text("pH").foregroundStyle(.secondary)
            }
            HStack {
                TextField("TA", text: $taText)
                    .keyboardType(.decimalPad)
                Text("g/L").foregroundStyle(.secondary)
            }
        } header: {
            Text("Fruit Analysis (optional)")
        } footer: {
            Text("Sugar defaults to the vineyard's preferred measurement (\(store.settings.regionSettings.sugarUnit.displayName)). Each record keeps the unit it was entered in.")
        }

        Section {
            TextField("Purpose (e.g. Sparkling base, Table wine)", text: $purpose)
        } header: {
            Text("Purpose (optional)")
        }

        Section {
            Toggle("Sold", isOn: $sold)
            if sold {
                TextField("Sold to", text: $soldTo)
                HStack {
                    TextField("Price per tonne", text: $priceText)
                        .keyboardType(.decimalPad)
                    Text("/t").foregroundStyle(.secondary)
                }
                if let value = calculatedGrapeValue {
                    LabeledContent("Grape value") {
                        Text(fmt.formatCurrency(value))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Sale")
        } footer: {
            if sold {
                Text("Grape value is calculated as tonnes × price per tonne.")
            }
        }

        Section {
            TextField("Notes", text: $detailNotes, axis: .vertical)
                .lineLimit(3...6)
        } header: {
            Text("Notes (optional)")
        }
    }

    // MARK: - Auto selection

    private func autoSelectVariety() {
        let options = varietyOptions
        if options.count == 1 {
            selectedVarietyKey = options[0].id
        }
        autoSelectClone()
    }

    private func autoSelectClone() {
        let clones = cloneOptions
        if clones.count == 1 {
            selectedClone = clones[0]
        }
    }

    // MARK: - Save

    private func saveBasic() {
        guard let vid = store.selectedVineyardId,
              let paddock = selectedPaddock,
              let yield = parsedYield else { return }

        let now = Date()
        let trimmedVariety = variety.trimmingCharacters(in: .whitespaces)
        let paddockName: String
        if trimmedVariety.isEmpty {
            paddockName = paddock.name
        } else {
            paddockName = "\(paddock.name) — \(trimmedVariety)"
        }

        let blockResult = HistoricalBlockResult(
            paddockId: paddock.id,
            paddockName: paddockName,
            areaHectares: paddock.areaHectares,
            yieldTonnes: yield,
            yieldPerHectare: paddock.areaHectares > 0 ? yield / paddock.areaHectares : 0,
            averageBunchesPerVine: 0,
            averageBunchWeightGrams: 0,
            totalVines: paddock.effectiveVineCount,
            samplesRecorded: 0,
            damageFactor: 1.0,
            actualYieldTonnes: yield,
            actualRecordedAt: now
        )

        let record = HistoricalYieldRecord(
            vineyardId: vid,
            season: season.trimmingCharacters(in: .whitespaces),
            year: year,
            archivedAt: now,
            blockResults: [blockResult],
            totalYieldTonnes: yield,
            totalAreaHectares: paddock.areaHectares,
            notes: notes.trimmingCharacters(in: .whitespaces)
        )

        store.addHistoricalYieldRecord(record)
        Task { await historicalYieldSync.syncForSelectedVineyard() }
    }

    /// Saves one picking record and keeps the sheet open for fast harvest
    /// entry — date, block, variety and analysis defaults are retained so the
    /// next pick only needs a new weight.
    private func saveDetailed() {
        guard let vid = store.selectedVineyardId,
              let paddock = detailPaddock,
              let weight = parsedWeight, weight > 0 else { return }

        let sugarValue = parsedSugar
        let record = PickingRecord(
            vineyardId: vid,
            pickedAt: pickDate,
            vintage: derivedVintage,
            paddockId: paddock.id,
            paddockName: paddock.name,
            varietyId: selectedVarietyOption?.varietyId,
            varietyKey: selectedVarietyOption?.varietyKey,
            varietyName: resolvedDetailVarietyName,
            clone: (selectedClone ?? cloneOptions.first)?.trimmingCharacters(in: .whitespaces),
            weightKg: weight,
            sugarValue: sugarValue,
            sugarUnit: sugarValue != nil ? sugarUnit.rawValue : nil,
            ph: parsedPh,
            taGPerL: parsedTa,
            purpose: purpose.trimmingCharacters(in: .whitespaces),
            sold: sold,
            soldTo: sold ? soldTo.trimmingCharacters(in: .whitespaces).nilIfEmpty : nil,
            pricePerTonne: sold ? parsedPrice : nil,
            notes: detailNotes.trimmingCharacters(in: .whitespaces)
        )

        store.addPickingRecord(record)
        Task { await pickingRecordSync.syncForSelectedVineyard() }

        // Reset the per-pick fields, keep the context fields for the next pick.
        weightText = ""
        sugarText = ""
        phText = ""
        taText = ""
        detailNotes = ""
        savedFeedback.toggle()
        weightFocused = true
    }

    /// Applies the edit to the existing record (same id) and dismisses. The
    /// local `vintage` mirror is recomputed from the new date; the server
    /// re-derives the authoritative vintage from `picked_at` on upsert, and
    /// `grape_value` stays server-generated — neither is ever client-written.
    private func saveEdit() {
        guard let original = editingRecord,
              let paddock = detailPaddock,
              let weight = parsedWeight, weight > 0 else { return }

        let sugarValue = parsedSugar
        var updated = original
        updated.pickedAt = pickDate
        updated.vintage = derivedVintage
        updated.paddockId = paddock.id
        updated.paddockName = paddock.name
        updated.varietyId = selectedVarietyOption?.varietyId
        updated.varietyKey = selectedVarietyOption?.varietyKey
        updated.varietyName = resolvedDetailVarietyName
        let trimmedClone = selectedClone?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.clone = (trimmedClone?.isEmpty ?? true) ? nil : trimmedClone
        updated.weightKg = weight
        updated.sugarValue = sugarValue
        updated.sugarUnit = sugarValue != nil ? sugarUnit.rawValue : nil
        updated.ph = parsedPh
        updated.taGPerL = parsedTa
        updated.purpose = purpose.trimmingCharacters(in: .whitespaces)
        updated.sold = sold
        updated.soldTo = sold ? soldTo.trimmingCharacters(in: .whitespaces).nilIfEmpty : nil
        updated.pricePerTonne = sold ? parsedPrice : nil
        updated.notes = detailNotes.trimmingCharacters(in: .whitespaces)

        store.updatePickingRecord(updated)
        Task { await pickingRecordSync.syncForSelectedVineyard() }
        savedFeedback.toggle()
        dismiss()
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
