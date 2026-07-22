import SwiftUI

struct SprayPresetsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var showAddChemical: Bool = false
    @State private var showAddPreset: Bool = false
    @State private var editingChemical: SavedChemical?
    @State private var editingPreset: SavedSprayPreset?
    @State private var deleteCoordinator = ChemicalDeleteCoordinator()

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    var body: some View {
        List {
            chemicalsSection
            tankPresetsSection
        }
        .navigationTitle("Spray Presets")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddChemical) {
            EditSavedChemicalSheet(chemical: nil)
        }
        .sheet(item: $editingChemical) { chem in
            EditSavedChemicalSheet(chemical: chem)
        }
        .sheet(isPresented: $showAddPreset) {
            EditSavedSprayPresetSheet(preset: nil)
        }
        .sheet(item: $editingPreset) { preset in
            EditSavedSprayPresetSheet(preset: preset)
        }
        .chemicalDeletionActions(coordinator: deleteCoordinator, store: store)
    }

    private var chemicalsSection: some View {
        Section {
            ForEach(store.savedChemicals) { chemical in
                Group {
                    if canManageSetup {
                        Button {
                            editingChemical = chemical
                        } label: { chemicalRowContent(chemical) }
                    } else {
                        chemicalRowContent(chemical)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if canManageSetup {
                        Button(role: .destructive) {
                            deleteCoordinator.pending = chemical
                        } label: {
                            let inUse = store.isSavedChemicalInUseLocally(chemical.id)
                            Label(inUse ? "Archive" : "Delete", systemImage: inUse ? "archivebox" : "trash")
                        }
                    }
                }
            }

            if canManageSetup {
                Button {
                    showAddChemical = true
                } label: {
                    Label("Add Chemical", systemImage: "plus.circle")
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.olive)
                    .font(.caption)
                Text("Chemicals")
            }
        } footer: {
            if canManageSetup {
                Text("Saved chemicals are shared with all users of this vineyard.")
            } else {
                Text("Setup data is managed by vineyard owners and managers.")
            }
        }
    }

    @ViewBuilder
    private func chemicalRowContent(_ chemical: SavedChemical) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(chemical.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if !chemical.activeIngredient.isEmpty {
                    Text(chemical.activeIngredient)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(String(format: "%.2f", chemical.ratePerHa)) \(chemical.unit.rawValue)/Ha")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if canManageSetup {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var tankPresetsSection: some View {
        Section {
            ForEach(store.savedSprayPresets) { preset in
                Group {
                    if canManageSetup {
                        Button {
                            editingPreset = preset
                        } label: { presetRowContent(preset) }
                    } else {
                        presetRowContent(preset)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if canManageSetup {
                        Button(role: .destructive) {
                            store.deleteSavedSprayPreset(preset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            if canManageSetup {
                Button {
                    showAddPreset = true
                } label: {
                    Label("Add Tank Preset", systemImage: "plus.circle")
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(VineyardTheme.olive)
                    .font(.caption)
                Text("Tank Presets")
            }
        } footer: {
            Text("Tank presets save Water Volume, Spray Rate, and Concentration Factor.")
        }
    }

    @ViewBuilder
    private func presetRowContent(_ preset: SavedSprayPreset) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(Int(preset.waterVolume))L • \(Int(preset.sprayRatePerHa))L/Ha • CF \(String(format: "%.1f", preset.concentrationFactor))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canManageSetup {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Edit Saved Chemical Sheet

private enum ChemicalFormType: String, CaseIterable, Identifiable {
    case liquid = "Liquid"
    case solid = "Solid"
    var id: String { rawValue }

    var units: [ChemicalUnit] {
        switch self {
        case .liquid: return [.litres, .millilitres]
        case .solid: return [.kilograms, .grams]
        }
    }

    static func from(unit: ChemicalUnit) -> ChemicalFormType {
        switch unit {
        case .litres, .millilitres: return .liquid
        case .kilograms, .grams: return .solid
        }
    }
}

struct EditSavedChemicalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    /// Purchase cost data (container size, dollar cost) is owner/manager only.
    /// Supervisors/operators can still see other chemical details but the
    /// purchase/cost section is hidden so they never see pricing.
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    let chemical: SavedChemical?

    @State private var name: String = ""
    @State private var formType: ChemicalFormType = .liquid
    @State private var unit: ChemicalUnit = .litres
    @State private var chemicalGroup: String = ""
    @State private var use: String = ""
    @State private var manufacturer: String = ""
    @State private var notes: String = ""
    @State private var problem: String = ""
    @State private var ratePerHaText: String = ""
    @State private var ratePer100LText: String = ""
    @State private var activeIngredient: String = ""
    @State private var modeOfAction: String = ""
    @State private var labelURL: String = ""
    @State private var productURL: String = ""
    @State private var trackPurchase: Bool = false
    @State private var containerSizeText: String = ""
    @State private var containerUnit: ChemicalUnit = .litres
    @State private var costText: String = ""
    // Unified product library fields (sql/111). Fertiliser-specific inputs
    // only appear when a fertiliser/nutrient category is selected.
    @State private var productCategory: ProductCategory?
    @State private var packSizeText: String = ""
    @State private var packPriceText: String = ""
    @State private var densityText: String = ""
    @State private var nitrogenText: String = ""
    @State private var phosphorusText: String = ""
    @State private var potassiumText: String = ""
    @State private var analysisBasis: FertiliserAnalysisBasis = .elemental
    @State private var organicCertified: Bool = false
    @State private var inventoryText: String = ""
    @State private var applicationNotes: String = ""
    @State private var showAILookup: Bool = false
    @State private var aiLoading: Bool = false
    @State private var aiError: String?
    @State private var linkAlertMessage: String?
    @State private var showLinkAlert: Bool = false
    @State private var deleteCoordinator = ChemicalDeleteCoordinator()

    private let existingPerHaRateId: UUID?
    private let existingPer100LRateId: UUID?

    init(chemical: SavedChemical?) {
        self.chemical = chemical
        if let c = chemical {
            _name = State(initialValue: c.name)
            _unit = State(initialValue: c.unit)
            _formType = State(initialValue: ChemicalFormType.from(unit: c.unit))
            _chemicalGroup = State(initialValue: c.chemicalGroup)
            _use = State(initialValue: c.use)
            _manufacturer = State(initialValue: c.manufacturer)
            _notes = State(initialValue: c.notes)
            _problem = State(initialValue: c.problem)
            _activeIngredient = State(initialValue: c.activeIngredient)
            _modeOfAction = State(initialValue: c.modeOfAction)
            _labelURL = State(initialValue: c.labelURL)
            _productURL = State(initialValue: c.productURL)

            let perHa = c.rates.first(where: { $0.basis == .perHectare })
            let per100L = c.rates.first(where: { $0.basis == .per100Litres })
            self.existingPerHaRateId = perHa?.id
            self.existingPer100LRateId = per100L?.id

            if let perHa {
                _ratePerHaText = State(initialValue: Self.formatRate(c.unit.fromBase(perHa.value)))
            } else if c.ratePerHa > 0 {
                _ratePerHaText = State(initialValue: Self.formatRate(c.ratePerHa))
            }
            if let per100L {
                _ratePer100LText = State(initialValue: Self.formatRate(c.unit.fromBase(per100L.value)))
            }

            if let p = c.purchase {
                _trackPurchase = State(initialValue: true)
                _containerSizeText = State(initialValue: Self.formatRate(p.containerSizeML))
                _containerUnit = State(initialValue: p.containerUnit)
                _costText = State(initialValue: p.costDollars > 0 ? Self.formatRate(p.costDollars) : "")
            } else {
                _containerUnit = State(initialValue: c.unit)
            }

            _productCategory = State(initialValue: c.category)
            _packSizeText = State(initialValue: c.packSize.map { Self.formatRate($0) } ?? "")
            _packPriceText = State(initialValue: c.pricePerPack.map { Self.formatRate($0) } ?? "")
            _densityText = State(initialValue: c.density.map { Self.formatRate($0) } ?? "")
            _nitrogenText = State(initialValue: c.nitrogenPercent.map { Self.formatRate($0) } ?? "")
            _phosphorusText = State(initialValue: c.phosphorusPercent.map { Self.formatRate($0) } ?? "")
            _potassiumText = State(initialValue: c.potassiumPercent.map { Self.formatRate($0) } ?? "")
            _analysisBasis = State(initialValue: FertiliserAnalysisBasis(rawValue: c.analysisBasis) ?? .elemental)
            _organicCertified = State(initialValue: c.organicCertified)
            _inventoryText = State(initialValue: c.inventoryQuantity.map { Self.formatRate($0) } ?? "")
            _applicationNotes = State(initialValue: c.applicationNotes)
        } else {
            self.existingPerHaRateId = nil
            self.existingPer100LRateId = nil
        }
    }

    private static func formatRate(_ value: Double) -> String {
        if value == 0 { return "" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.settings.aiSuggestionsEnabled {
                    aiSection
                }
                productSection
                detailsSection
                ratesSection
                if productCategory?.isFertiliser == true {
                    fertiliserSection
                }
                if canViewFinancials {
                    purchaseSection
                }
                sharingSection
                notesSection
                if chemical != nil {
                    dangerZoneSection
                }
            }
            .navigationTitle(chemical == nil ? "New Chemical" : "Edit Chemical")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAILookup) {
                ChemicalAILookupSheet(initialQuery: name) { result in
                    Task { await applyAIResult(result) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .alert("Link", isPresented: $showLinkAlert, presenting: linkAlertMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
            .chemicalDeletionActions(coordinator: deleteCoordinator, store: store)
            .onChange(of: deleteCoordinator.didDeleteId) { _, newValue in
                if newValue != nil { dismiss() }
            }
            .onChange(of: formType) { _, newValue in
                if !newValue.units.contains(unit) {
                    unit = newValue.units.first ?? .litres
                }
                if !newValue.units.contains(containerUnit) {
                    containerUnit = newValue.units.first ?? .litres
                }
            }
        }
    }

    private var aiSection: some View {
        Section {
            Button {
                showAILookup = true
            } label: {
                Label(aiLoading ? "Looking up..." : "Search with AI", systemImage: "sparkles")
            }
            .disabled(aiLoading)
            if let aiError {
                Text(aiError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("AI suggestions must be checked against the current product label, permit, SDS, and local regulations before use.")
        }
    }

    private var productSection: some View {
        Section {
            LabeledField(label: "Chemical / Product Name") {
                TextField("e.g. Synertrol Horti Oil", text: $name)
            }
            Picker("Category", selection: $productCategory) {
                Text("Uncategorised").tag(ProductCategory?.none)
                ForEach(ProductCategory.allCases) { option in
                    Text(option.label).tag(ProductCategory?.some(option))
                }
            }
            Picker("Form", selection: $formType) {
                ForEach(ChemicalFormType.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            Picker("Unit", selection: $unit) {
                ForEach(formType.units, id: \.self) { u in
                    Text(u.rawValue).tag(u)
                }
            }
        } header: {
            Text("Product")
        } footer: {
            Text("Fertiliser and nutrient categories unlock pack, N-P-K and inventory fields used by the Fertiliser Calculator.")
        }
    }

    /// Pack, nutrient analysis and inventory inputs — shown only for
    /// fertiliser/nutrient categories so ordinary spray chemicals stay clean.
    private var fertiliserSection: some View {
        Group {
            Section("Pack & Inventory") {
                Toggle("Organic certified", isOn: $organicCertified)
                LabeledContent("Pack size (\(formType == .liquid ? "L" : "kg"))") {
                    TextField("25", text: $packSizeText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                if canViewFinancials {
                    LabeledContent("Price per pack ($)") {
                        TextField("Optional", text: $packPriceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if formType == .liquid {
                    LabeledContent("Density (kg/L)") {
                        TextField("Optional", text: $densityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Stock on hand (packs)") {
                    TextField("Optional", text: $inventoryText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                LabeledContent("Nitrogen (N) %") {
                    TextField("0", text: $nitrogenText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Phosphorus %") {
                    TextField("0", text: $phosphorusText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Potassium %") {
                    TextField("0", text: $potassiumText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Picker("P & K basis", selection: $analysisBasis) {
                    ForEach(FertiliserAnalysisBasis.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            } header: {
                Text("Nutrient Analysis")
            } footer: {
                Text("Record whether the label lists elemental P/K or oxide (P\u{2082}O\u{2085}/K\u{2082}O) values — mixing them up causes major rate errors.")
            }

            Section("Application Notes") {
                TextField("Optional notes", text: $applicationNotes, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
    }

    private var detailsSection: some View {
        Section {
            LabeledField(label: "Active Ingredient") {
                TextField("e.g. Glyphosate 360 g/L", text: $activeIngredient)
            }
            LabeledField(label: "Chemical Group") {
                TextField("e.g. Group M", text: $chemicalGroup)
            }
            LabeledField(label: "Use / Problem") {
                TextField("e.g. Fungicide", text: $use)
            }
            LabeledField(label: "Target Problem") {
                TextField("e.g. Powdery Mildew", text: $problem)
            }
            LabeledField(label: "Manufacturer") {
                TextField("e.g. Syngenta", text: $manufacturer)
            }
            LabeledField(label: "Mode of Action (MOA)") {
                TextField("e.g. 11", text: $modeOfAction)
            }
            LabeledURLField(
                label: "Official Label URL",
                placeholder: "https://...",
                text: $labelURL,
                onOpenFailure: { message in
                    linkAlertMessage = message
                    showLinkAlert = true
                }
            )
            LabeledURLField(
                label: "Product Page URL",
                placeholder: "https://...",
                text: $productURL,
                onOpenFailure: { message in
                    linkAlertMessage = message
                    showLinkAlert = true
                }
            )
        } header: {
            Text("Details")
        } footer: {
            Text("Use Label URL only for the official product label, preferably a PDF. Product pages may be used for manufacturer or marketing information, but are never shown as the official label.")
        }
    }

    private var ratesSection: some View {
        Section {
            LabeledField(label: "Rate per ha") {
                HStack {
                    TextField("0", text: $ratePerHaText)
                        .keyboardType(.decimalPad)
                    Text("\(unit.rawValue)/ha")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            LabeledField(label: "Rate per 100L water") {
                HStack {
                    TextField("0", text: $ratePer100LText)
                        .keyboardType(.decimalPad)
                    Text("\(unit.rawValue)/100L")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Rates")
        } footer: {
            Text("Enter either or both. The Spray Calculator lets the operator pick which basis to use per job.")
        }
    }

    private var purchaseSection: some View {
        Section {
            Toggle("Track Purchase Info", isOn: $trackPurchase.animation())
            if trackPurchase {
                HStack {
                    Text("Container Size")
                    Spacer()
                    TextField("0", text: $containerSizeText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Picker("Unit", selection: $containerUnit) {
                        ForEach(formType.units, id: \.self) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("Cost")
                    Spacer()
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("0.00", text: $costText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }
        } header: {
            Text("Purchase Tracking")
        } footer: {
            Text("Used to calculate chemical cost in spray reports. AI does not fill in pricing — enter it from your invoice.")
        }
    }

    private var sharingSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                Text("Saved chemicals are shared with all users of this vineyard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dangerZoneSection: some View {
        Section {
            if let chemical {
                let inUseLocally = store.isSavedChemicalInUseLocally(chemical.id)
                Button {
                    deleteCoordinator.pending = chemical
                } label: {
                    Label("Archive Chemical", systemImage: "archivebox")
                        .foregroundStyle(.orange)
                }
                .disabled(deleteCoordinator.isWorking)

                if !inUseLocally {
                    Button(role: .destructive) {
                        deleteCoordinator.pending = chemical
                    } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                    .disabled(deleteCoordinator.isWorking)
                }
            }
        } header: {
            Text("Manage Chemical")
        } footer: {
            Text("Archiving hides the chemical from active lists but keeps it for historical records. Permanent delete is only available when this chemical has not been used in any spray records — the server makes the final decision.")
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .frame(minHeight: 80)
                    .padding(8)
                    .background(Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
                    .clipShape(.rect(cornerRadius: 8))
            }
            .padding(.vertical, 4)
        }
    }

    @MainActor
    private func applyAIResult(_ result: ChemicalSearchResult) async {
        aiError = nil
        aiLoading = true
        defer { aiLoading = false }
        // Explicit user selection — replace the typed search text with the
        // official product name and manufacturer returned by the lookup so
        // spelling mistakes ('Syntirol' -> 'Syntiro') are corrected and the
        // chemical is easier to find later. Other fields only fill when empty
        // so existing manual edits are preserved.
        let officialName = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !officialName.isEmpty { name = officialName }
        let officialBrand = result.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !officialBrand.isEmpty { manufacturer = officialBrand }
        if activeIngredient.isEmpty { activeIngredient = result.activeIngredient }
        if chemicalGroup.isEmpty { chemicalGroup = result.chemicalGroup }
        if modeOfAction.isEmpty { modeOfAction = result.modeOfAction }
        if use.isEmpty { use = result.primaryUse }
        if problem.isEmpty { problem = result.primaryUse }

        let country = ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
        do {
            let info = try await ChemicalInfoService().lookupChemicalInfo(productName: officialName.isEmpty ? result.name : officialName, country: country)
            if activeIngredient.isEmpty { activeIngredient = info.activeIngredient }
            let infoBrand = info.brand.trimmingCharacters(in: .whitespacesAndNewlines)
            if manufacturer.isEmpty, !infoBrand.isEmpty { manufacturer = infoBrand }
            if chemicalGroup.isEmpty { chemicalGroup = info.chemicalGroup }
            if labelURL.isEmpty { labelURL = LabelURLValidator.sanitize(info.labelURL) }
            if productURL.isEmpty, let p = info.productURL {
                productURL = LabelURLValidator.sanitize(p)
            }
            if let moa = info.modeOfAction, modeOfAction.isEmpty { modeOfAction = moa }
            if use.isEmpty { use = info.primaryUse }
            unit = info.defaultUnit
            formType = ChemicalFormType.from(unit: info.defaultUnit)
            if !formType.units.contains(containerUnit) {
                containerUnit = info.defaultUnit
            }
            if let rates = info.ratesPerHectare, let first = rates.first, ratePerHaText.isEmpty {
                ratePerHaText = Self.formatRate(first.value)
            }
            if let rates = info.ratesPer100L, let first = rates.first, ratePer100LText.isEmpty {
                ratePer100LText = Self.formatRate(first.value)
            }
        } catch {
            aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() {
        let perHaDisplay = Double(ratePerHaText) ?? 0
        let per100LDisplay = Double(ratePer100LText) ?? 0

        var rates: [ChemicalRate] = []
        if perHaDisplay > 0 {
            rates.append(ChemicalRate(
                id: existingPerHaRateId ?? UUID(),
                label: "Per Ha",
                value: unit.toBase(perHaDisplay),
                basis: .perHectare
            ))
        }
        if per100LDisplay > 0 {
            rates.append(ChemicalRate(
                id: existingPer100LRateId ?? UUID(),
                label: "Per 100L",
                value: unit.toBase(per100LDisplay),
                basis: .per100Litres
            ))
        }

        // Preserve existing purchase data when the editor cannot see/edit
        // financials so that owners/managers don't lose cost values when a
        // supervisor/operator edits the same chemical for other details.
        var purchase: ChemicalPurchase? = canViewFinancials ? nil : chemical?.purchase
        if canViewFinancials, trackPurchase {
            let containerSize = Double(containerSizeText) ?? 0
            let cost = Double(costText) ?? 0
            if containerSize > 0 || cost > 0 {
                purchase = ChemicalPurchase(
                    brand: manufacturer,
                    activeIngredient: activeIngredient,
                    chemicalGroup: chemicalGroup,
                    labelURL: labelURL,
                    costDollars: cost,

                    containerSizeML: containerSize,
                    containerUnit: containerUnit
                )
            }
        }

        let parseOptional: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
        let productForm = formType == .liquid ? "liquid" : "solid"
        let packUnit = formType == .liquid ? "L" : "kg"

        if var existing = chemical {
            existing.name = name
            existing.unit = unit
            existing.chemicalGroup = chemicalGroup
            existing.use = use
            existing.manufacturer = manufacturer
            existing.notes = notes
            existing.problem = problem
            existing.ratePerHa = perHaDisplay
            existing.activeIngredient = activeIngredient
            existing.modeOfAction = modeOfAction
            existing.labelURL = labelURL
            existing.productURL = productURL
            existing.rates = rates
            existing.purchase = purchase
            existing.productCategory = productCategory?.rawValue ?? ""
            existing.productForm = productForm
            existing.packSize = parseOptional(packSizeText)
            existing.packUnit = packUnit
            // Preserve pricing authored by owners/managers when the current
            // editor cannot see financials.
            existing.pricePerPack = canViewFinancials ? parseOptional(packPriceText) : chemical?.pricePerPack
            existing.density = parseOptional(densityText)
            existing.nitrogenPercent = parseOptional(nitrogenText)
            existing.phosphorusPercent = parseOptional(phosphorusText)
            existing.potassiumPercent = parseOptional(potassiumText)
            existing.analysisBasis = analysisBasis.rawValue
            existing.organicCertified = organicCertified
            existing.inventoryQuantity = parseOptional(inventoryText)
            existing.inventoryUnit = parseOptional(inventoryText) != nil ? "packs" : existing.inventoryUnit
            existing.applicationNotes = applicationNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            store.updateSavedChemical(existing)
        } else {
            let new = SavedChemical(
                name: name,
                ratePerHa: perHaDisplay,
                unit: unit,
                chemicalGroup: chemicalGroup,
                use: use,
                manufacturer: manufacturer,
                notes: notes,
                problem: problem,
                activeIngredient: activeIngredient,
                rates: rates,
                purchase: purchase,
                labelURL: labelURL,
                productURL: productURL,
                modeOfAction: modeOfAction,
                productCategory: productCategory?.rawValue ?? "",
                productForm: productForm,
                packSize: parseOptional(packSizeText),
                packUnit: packUnit,
                pricePerPack: canViewFinancials ? parseOptional(packPriceText) : nil,
                density: parseOptional(densityText),
                nitrogenPercent: parseOptional(nitrogenText),
                phosphorusPercent: parseOptional(phosphorusText),
                potassiumPercent: parseOptional(potassiumText),
                analysisBasis: analysisBasis.rawValue,
                organicCertified: organicCertified,
                inventoryQuantity: parseOptional(inventoryText),
                inventoryUnit: parseOptional(inventoryText) != nil ? "packs" : "",
                applicationNotes: applicationNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            store.addSavedChemical(new)
        }
    }
}

// MARK: - Chemical AI Lookup Sheet

struct ChemicalAILookupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let initialQuery: String
    let onSelect: (ChemicalSearchResult) -> Void

    @State private var query: String = ""
    @State private var results: [ChemicalSearchResult] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    init(initialQuery: String, onSelect: @escaping (ChemicalSearchResult) -> Void) {
        self.initialQuery = initialQuery
        self.onSelect = onSelect
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Product or active ingredient", text: $query)
                            .textInputAutocapitalization(.words)
                            .onSubmit { Task { await search() } }
                        Button {
                            Task { await search() }
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .disabled(isLoading || query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("AI suggestions must be checked against the current label, permit, SDS, and local regulations before use.")
                }

                if isLoading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Searching...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if !results.isEmpty {
                    Section {
                        ForEach(results) { item in
                            Button {
                                onSelect(item)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    // Manufacturer first, bold, most scannable.
                                    if !item.brand.isEmpty {
                                        Text(item.brand)
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.primary)
                                    }
                                    // Official product name directly underneath.
                                    Text(item.name)
                                        .font(.subheadline)
                                        .foregroundStyle(item.brand.isEmpty ? .primary : .secondary)
                                    if !item.activeIngredient.isEmpty {
                                        Text("Active: \(item.activeIngredient)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 6) {
                                        if !item.chemicalGroup.isEmpty {
                                            Text(item.chemicalGroup).font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        if !item.modeOfAction.isEmpty {
                                            Text("• MOA \(item.modeOfAction)").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                    if !item.primaryUse.isEmpty {
                                        Text(item.primaryUse)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkles")
                                            .font(.caption2)
                                        Text("Source: AI lookup")
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                                }
                            }
                        }
                    } header: {
                        Text("Results")
                    } footer: {
                        Text("You can search again if you do not see the right product. A second search may find additional chemicals or alternative product listings.")
                    }
                }
            }
            .navigationTitle("Search with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if !initialQuery.trimmingCharacters(in: .whitespaces).isEmpty && results.isEmpty {
                    await search()
                }
            }
        }
    }

    @MainActor
    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let country = ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
        do {
            results = try await ChemicalInfoService().searchChemicals(query: trimmed, country: country)
            if results.isEmpty {
                errorMessage = "No products found."
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results = []
        }
    }
}

// MARK: - Edit Saved Spray Preset Sheet

struct EditSavedSprayPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let preset: SavedSprayPreset?

    @State private var name: String = ""
    @State private var waterVolumeText: String = ""
    @State private var sprayRateText: String = ""
    @State private var concentrationText: String = "1.0"

    init(preset: SavedSprayPreset?) {
        self.preset = preset
        if let p = preset {
            _name = State(initialValue: p.name)
            _waterVolumeText = State(initialValue: String(format: "%.0f", p.waterVolume))
            _sprayRateText = State(initialValue: String(format: "%.0f", p.sprayRatePerHa))
            _concentrationText = State(initialValue: String(format: "%.1f", p.concentrationFactor))
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Preset Name", text: $name)
                }
                Section("Volumes") {
                    HStack {
                        Text("Water Volume")
                        Spacer()
                        TextField("0", text: $waterVolumeText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("L")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Spray Rate")
                        Spacer()
                        TextField("0", text: $sprayRateText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("L/Ha")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Concentration Factor")
                        Spacer()
                        TextField("1.0", text: $concentrationText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
            }
            .navigationTitle(preset == nil ? "New Preset" : "Edit Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let water = Double(waterVolumeText) ?? 0
        let rate = Double(sprayRateText) ?? 0
        let cf = Double(concentrationText) ?? 1.0
        if var existing = preset {
            existing.name = name
            existing.waterVolume = water
            existing.sprayRatePerHa = rate
            existing.concentrationFactor = cf
            store.updateSavedSprayPreset(existing)
        } else {
            let new = SavedSprayPreset(
                name: name,
                waterVolume: water,
                sprayRatePerHa: rate,
                concentrationFactor: cf
            )
            store.addSavedSprayPreset(new)
        }
    }
}

// MARK: - Labeled Field Helpers

/// A form field with a small, persistent grey label above a bordered white input.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .clipShape(.rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }
}

/// A labeled URL field with a trailing open-in-browser button.
/// The button is only visible when the field contains a valid http(s) URL.
struct LabeledURLField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let onOpenFailure: (String) -> Void

    @Environment(\.openURL) private var openURL

    private var resolvedURL: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://" + trimmed
        }
        guard let url = URL(string: withScheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let url = resolvedURL {
                    Button {
                        openURL(url) { accepted in
                            if !accepted {
                                onOpenFailure("This link could not be opened.")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(VineyardTheme.olive)
                            .padding(4)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(label)")
                }
            }
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .clipShape(.rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }
}
