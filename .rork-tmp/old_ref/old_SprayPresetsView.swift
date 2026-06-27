import SwiftUI

struct SprayPresetsView: View {
    @Environment(DataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var showAddChemical: Bool = false
    @State private var showAddPreset: Bool = false
    @State private var editingChemical: SavedChemical?
    @State private var editingPreset: SavedSprayPreset?

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
    }

    private var chemicalsSection: some View {
        Section {
            ForEach(store.savedChemicals) { chemical in
                Button {
                    editingChemical = chemical
                } label: {
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
                                Text("\(String(format: "%.2f", chemical.ratePerHa)) L/Kg per Ha")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if accessControl?.canDelete ?? false {
                        Button(role: .destructive) {
                            store.deleteSavedChemical(chemical)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                showAddChemical = true
            } label: {
                Label("Add Chemical", systemImage: "plus.circle")
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.olive)
                    .font(.caption)
                Text("Chemicals")
            }
        } footer: {
            Text("Saved chemicals link a name with its rate per hectare. Select them quickly when creating spray records.")
        }
    }

    private var tankPresetsSection: some View {
        Section {
            ForEach(store.savedSprayPresets) { preset in
                Button {
                    editingPreset = preset
                } label: {
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
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if accessControl?.canDelete ?? false {
                        Button(role: .destructive) {
                            store.deleteSavedSprayPreset(preset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                showAddPreset = true
            } label: {
                Label("Add Tank Preset", systemImage: "plus.circle")
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(VineyardTheme.olive)
                    .font(.caption)
                Text("Tank Presets")
            }
        } footer: {
            Text("Tank presets save Water Volume, Spray Rate, and Concentration Factor. Load them quickly when setting up tanks.")
        }
    }
}

struct EditSavedChemicalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataStore.self) private var store

    let chemical: SavedChemical?

    @State private var name: String = ""
    @State private var unit: ChemicalUnit = .litres
    @State private var chemicalGroup: String = ""
    @State private var use: String = ""
    @State private var manufacturer: String = ""
    @State private var restrictions: String = ""
    @State private var notes: String = ""
    @State private var crop: String = ""
    @State private var problem: String = ""
    @State private var ratePerHaText: String = ""
    @State private var ratesPerHa: [ChemicalRate] = []
    @State private var ratesPer100L: [ChemicalRate] = []
    @State private var hasPurchaseInfo: Bool = false
    @State private var activeIngredient: String = ""
    @State private var labelURL: String = ""
    @State private var costText: String = ""
    @State private var containerSizeText: String = ""
    @State private var containerUnit: ChemicalUnit = .litres
    @State private var isLookingUp: Bool = false
    @State private var lookupError: String?
    @State private var isSearching: Bool = false
    @State private var searchResults: [ChemicalSearchResult] = []
    @State private var showSearchResults: Bool = false
    @State private var modeOfAction: String = ""

    init(chemical: SavedChemical?) {
        self.chemical = chemical
        if let c = chemical {
            _name = State(initialValue: c.name)
            _unit = State(initialValue: c.unit)
            _chemicalGroup = State(initialValue: c.chemicalGroup)
            _use = State(initialValue: c.use)
            _manufacturer = State(initialValue: c.manufacturer)
            _restrictions = State(initialValue: c.restrictions)
            _notes = State(initialValue: c.notes)
            _crop = State(initialValue: c.crop)
            _problem = State(initialValue: c.problem)
            _activeIngredient = State(initialValue: c.activeIngredient)
            _labelURL = State(initialValue: c.labelURL)
            _modeOfAction = State(initialValue: c.modeOfAction)
            _ratePerHaText = State(initialValue: c.ratePerHa > 0 ? String(format: "%.2f", c.ratePerHa) : "")
            let haRates = c.rates.filter { $0.basis == .perHectare }.map { rate in
                ChemicalRate(id: rate.id, label: rate.label, value: c.unit.fromBase(rate.value), basis: .perHectare)
            }
            let per100LRates = c.rates.filter { $0.basis == .per100Litres }.map { rate in
                ChemicalRate(id: rate.id, label: rate.label, value: c.unit.fromBase(rate.value), basis: .per100Litres)
            }
            _ratesPerHa = State(initialValue: haRates)
            _ratesPer100L = State(initialValue: per100LRates)
            if let p = c.purchase {
                _hasPurchaseInfo = State(initialValue: true)
                if c.activeIngredient.isEmpty {
                    _activeIngredient = State(initialValue: p.activeIngredient)
                }
                _costText = State(initialValue: p.costDollars > 0 ? String(format: "%.2f", p.costDollars) : "")
                _containerSizeText = State(initialValue: p.containerSizeML > 0 ? String(format: "%.0f", p.containerSizeML) : "")
                _containerUnit = State(initialValue: p.containerUnit)
            }
        }
    }

    private var allRates: [ChemicalRate] {
        ratesPerHa + ratesPer100L
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var costDollars: Double {
        Double(costText) ?? 0
    }

    private var containerSize: Double {
        Double(containerSizeText) ?? 0
    }

    private var costPerUnit: Double {
        guard containerSize > 0 else { return 0 }
        let containerInBase = containerUnit.toBase(containerSize)
        guard containerInBase > 0 else { return 0 }
        return costDollars / containerInBase
    }

    private var costUnitLabel: String {
        switch containerUnit {
        case .litres, .millilitres: return "mL"
        case .kilograms, .grams: return "g"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                productDetailsSection
                labelLinkSection
                ratesPerHaSection
                ratesPer100LSection
                legacyRateSection
                purchaseToggleSection
                if hasPurchaseInfo {
                    containerCostSection
                }
                notesSection
            }
            .navigationTitle(chemical == nil ? "New Chemical" : "Edit Chemical")
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
            .sheet(isPresented: $showSearchResults) {
                ChemicalSearchResultsSheet(
                    results: searchResults,
                    query: name
                ) { selected in
                    applySearchResult(selected)
                    showSearchResults = false
                }
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            HStack {
                TextField("Chemical Name", text: $name)
                if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        searchForChemical()
                    } label: {
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Search", systemImage: "sparkle.magnifyingglass")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(VineyardTheme.olive)
                        }
                    }
                    .disabled(isSearching)
                }
            }

            if let lookupError {
                Text(lookupError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("Unit", selection: $unit) {
                ForEach(ChemicalUnit.allCases, id: \.self) { u in
                    Text(u.rawValue).tag(u)
                }
            }
            .onChange(of: unit) { oldUnit, newUnit in
                guard oldUnit != newUnit else { return }
                ratesPerHa = ratesPerHa.map { rate in
                    let baseValue = oldUnit.toBase(rate.value)
                    return ChemicalRate(id: rate.id, label: rate.label, value: newUnit.fromBase(baseValue), basis: .perHectare)
                }
                ratesPer100L = ratesPer100L.map { rate in
                    let baseValue = oldUnit.toBase(rate.value)
                    return ChemicalRate(id: rate.id, label: rate.label, value: newUnit.fromBase(baseValue), basis: .per100Litres)
                }
            }
        }
    }

    private var productDetailsSection: some View {
        Section {
            LabeledContent("Active Ingredient") {
                TextField("Enter active ingredient", text: $activeIngredient)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Chemical Group") {
                TextField("Enter chemical group", text: $chemicalGroup)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Use / Problem") {
                TextField("Enter use or problem", text: $problem)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Manufacturer") {
                TextField("Enter manufacturer", text: $manufacturer)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("MOA") {
                TextField("e.g. 3, 11, M5, 4A", text: $modeOfAction)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Label URL") {
                TextField("Enter URL", text: $labelURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            HStack {
                Text("Product Details")
                Spacer()
                if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        lookupChemicalInfo()
                    } label: {
                        HStack(spacing: 4) {
                            if isLookingUp {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text("Auto-fill")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(VineyardTheme.olive)
                    }
                    .disabled(isLookingUp)
                }
            }
        }
    }

    @ViewBuilder
    private var labelLinkSection: some View {
        if !labelURL.isEmpty, let url = URL(string: labelURL) {
            Section {
                Link(destination: url) {
                    Label("View Product Label", systemImage: "doc.text")
                }
            }
        }
    }

    private var ratesPerHaSection: some View {
        Section {
            ForEach($ratesPerHa) { $rate in
                HStack {
                    TextField("Label", text: $rate.label)
                        .frame(maxWidth: 120)
                    Divider()
                    TextField("Value", value: $rate.value, format: .number)
                        .keyboardType(.decimalPad)
                    Text("\(unit.rawValue)/ha")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { indexSet in
                ratesPerHa.remove(atOffsets: indexSet)
            }

            Button("Add Rate", systemImage: "plus.circle") {
                ratesPerHa.append(ChemicalRate(label: "", value: 0, basis: .perHectare))
            }
        } header: {
            Text("Rates — Per Hectare")
        } footer: {
            Text("Chemical amount applied per hectare of vineyard")
        }
    }

    private var ratesPer100LSection: some View {
        Section {
            ForEach($ratesPer100L) { $rate in
                HStack {
                    TextField("Label", text: $rate.label)
                        .frame(maxWidth: 120)
                    Divider()
                    TextField("Value", value: $rate.value, format: .number)
                        .keyboardType(.decimalPad)
                    Text("\(unit.rawValue)/100L")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { indexSet in
                ratesPer100L.remove(atOffsets: indexSet)
            }

            Button("Add Rate", systemImage: "plus.circle") {
                ratesPer100L.append(ChemicalRate(label: "", value: 0, basis: .per100Litres))
            }
        } header: {
            Text("Rates — Per 100L Water")
        } footer: {
            Text("Chemical amount per 100 litres of water — concentration factor will apply")
        }
    }

    @ViewBuilder
    private var legacyRateSection: some View {
        if ratesPerHa.isEmpty && ratesPer100L.isEmpty {
            Section("Quick Rate") {
                HStack {
                    Text("Rate/Ha (L/Kg)")
                        .font(.subheadline)
                    Spacer()
                    TextField("0", text: $ratePerHaText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
            }
        }
    }

    private var purchaseToggleSection: some View {
        Section {
            Toggle("Track Purchase Info", isOn: $hasPurchaseInfo)
        } header: {
            Text("Purchase")
        } footer: {
            Text("Track product cost and container details for spray job costings")
        }
    }

    private var containerCostSection: some View {
        Section("Container & Cost") {
            HStack {
                Text("Container Size")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Size", text: $containerSizeText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                Picker("", selection: $containerUnit) {
                    ForEach(ChemicalUnit.allCases, id: \.self) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 70)
            }

            HStack {
                Text("Cost ($)")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("0.00", text: $costText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
            }

            if costPerUnit > 0 {
                HStack {
                    Text("Cost per \(costUnitLabel)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("$\(String(format: "%.4f", costPerUnit))")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VineyardTheme.olive)
                }
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if !restrictions.isEmpty || !notes.isEmpty || chemical != nil {
            Section("Notes & Restrictions") {
                LabeledContent("Restrictions / WHP") {
                    TextField("Enter restrictions", text: $restrictions)
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Enter notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
        }
    }

    private func searchForChemical() {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        lookupError = nil
        searchResults = []

        Task {
            do {
                let country = store.selectedVineyard?.country ?? ""
                let aiResults = try await ChemicalInfoService.shared.searchChemicals(query: query, country: country)
                if !aiResults.isEmpty {
                    searchResults = aiResults
                    showSearchResults = true
                } else {
                    lookupError = "No matching chemicals found. Try a different name."
                }
            } catch {
                lookupError = "Search failed: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    private func applySearchResult(_ result: ChemicalSearchResult) {
        name = result.name
        activeIngredient = result.activeIngredient
        chemicalGroup = result.chemicalGroup
        manufacturer = result.brand
        if problem.isEmpty { problem = result.primaryUse }
        if modeOfAction.isEmpty { modeOfAction = result.modeOfAction }
        lookupError = nil

        lookupFullDetails(for: result.name)
    }

    private func lookupFullDetails(for productName: String) {
        isLookingUp = true
        Task {
            do {
                let country = store.selectedVineyard?.country ?? ""
                let info = try await ChemicalInfoService.shared.lookupChemicalInfo(productName: productName, country: country)
                if activeIngredient.isEmpty { activeIngredient = info.activeIngredient }
                if chemicalGroup.isEmpty { chemicalGroup = info.chemicalGroup }
                if manufacturer.isEmpty { manufacturer = info.brand }
                if labelURL.isEmpty { labelURL = info.labelURL }
                if problem.isEmpty { problem = info.primaryUse }
                if modeOfAction.isEmpty, let moa = info.modeOfAction, !moa.isEmpty { modeOfAction = moa }
                unit = info.defaultUnit
                containerUnit = info.defaultUnit
                if ratesPerHa.isEmpty, let haRates = info.ratesPerHectare, !haRates.isEmpty {
                    ratesPerHa = haRates.map { ChemicalRate(label: $0.label, value: $0.value, basis: .perHectare) }
                }
                if ratesPer100L.isEmpty, let per100L = info.ratesPer100L, !per100L.isEmpty {
                    ratesPer100L = per100L.map { ChemicalRate(label: $0.label, value: $0.value, basis: .per100Litres) }
                }
            } catch {
                print("[LookupFullDetails] \(error.localizedDescription)")
            }
            isLookingUp = false
        }
    }

    private func lookupChemicalInfo() {
        guard !name.isEmpty else { return }
        isLookingUp = true
        lookupError = nil
        Task {
            do {
                let country = store.selectedVineyard?.country ?? ""
                let info = try await ChemicalInfoService.shared.lookupChemicalInfo(productName: name, country: country)
                activeIngredient = info.activeIngredient
                chemicalGroup = info.chemicalGroup
                if manufacturer.isEmpty { manufacturer = info.brand }
                if labelURL.isEmpty { labelURL = info.labelURL }
                problem = info.primaryUse
                if let moa = info.modeOfAction, !moa.isEmpty { modeOfAction = moa }
                unit = info.defaultUnit
                containerUnit = info.defaultUnit
                if ratesPerHa.isEmpty, let haRates = info.ratesPerHectare, !haRates.isEmpty {
                    ratesPerHa = haRates.map { ChemicalRate(label: $0.label, value: $0.value, basis: .perHectare) }
                }
                if ratesPer100L.isEmpty, let per100L = info.ratesPer100L, !per100L.isEmpty {
                    ratesPer100L = per100L.map { ChemicalRate(label: $0.label, value: $0.value, basis: .per100Litres) }
                }
            } catch {
                lookupError = "Could not look up product info: \(error.localizedDescription)"
            }
            isLookingUp = false
        }
    }

    private func save() {
        let baseRatesPerHa = ratesPerHa.map { rate in
            ChemicalRate(id: rate.id, label: rate.label, value: unit.toBase(rate.value), basis: .perHectare)
        }
        let baseRatesPer100L = ratesPer100L.map { rate in
            ChemicalRate(id: rate.id, label: rate.label, value: unit.toBase(rate.value), basis: .per100Litres)
        }
        let allBaseRates = baseRatesPerHa + baseRatesPer100L

        let purchase: ChemicalPurchase? = hasPurchaseInfo ? ChemicalPurchase(
            brand: manufacturer,
            activeIngredient: activeIngredient,
            chemicalGroup: chemicalGroup,
            labelURL: labelURL,
            costDollars: costDollars,
            containerSizeML: containerSize,
            containerUnit: containerUnit
        ) : nil

        let legacyRate = Double(ratePerHaText) ?? 0

        if var existing = chemical {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.unit = unit
            existing.chemicalGroup = chemicalGroup
            existing.use = use
            existing.manufacturer = manufacturer
            existing.restrictions = restrictions
            existing.notes = notes
            existing.crop = crop
            existing.problem = problem
            existing.activeIngredient = activeIngredient
            existing.labelURL = labelURL
            existing.modeOfAction = modeOfAction
            existing.rates = allBaseRates
            existing.purchase = purchase
            if legacyRate > 0 { existing.ratePerHa = legacyRate }
            store.updateSavedChemical(existing)
        } else {
            let newChemical = SavedChemical(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                ratePerHa: legacyRate,
                unit: unit,
                chemicalGroup: chemicalGroup,
                use: use,
                manufacturer: manufacturer,
                restrictions: restrictions,
                notes: notes,
                crop: crop,
                problem: problem,
                activeIngredient: activeIngredient,
                rates: allBaseRates,
                purchase: purchase,
                labelURL: labelURL,
                modeOfAction: modeOfAction
            )
            store.addSavedChemical(newChemical)
        }
    }
}

struct ChemicalSearchResultsSheet: View {
    let results: [ChemicalSearchResult]
    let query: String
    let onSelect: (ChemicalSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(results) { result in
                        Button {
                            onSelect(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    if !result.chemicalGroup.isEmpty {
                                        Label(result.chemicalGroup, systemImage: "atom")
                                            .font(.caption)
                                            .foregroundStyle(VineyardTheme.olive)
                                    }
                                    if !result.brand.isEmpty {
                                        Label(result.brand, systemImage: "building.2")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !result.modeOfAction.isEmpty {
                                        Label("MOA: \(result.modeOfAction)", systemImage: "number")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if !result.activeIngredient.isEmpty {
                                    Text(result.activeIngredient)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Label("Results for \"\(query)\"", systemImage: "sparkles")
                } footer: {
                    Text("Tap a product to auto-fill its details")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chemical Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct EditSavedSprayPresetSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let preset: SavedSprayPreset?

    @State private var name: String
    @State private var waterVolumeText: String
    @State private var sprayRateText: String
    @State private var concentrationFactorText: String

    init(preset: SavedSprayPreset?) {
        self.preset = preset
        _name = State(initialValue: preset?.name ?? "")
        _waterVolumeText = State(initialValue: preset.map { String(format: "%.0f", $0.waterVolume) } ?? "")
        _sprayRateText = State(initialValue: preset.map { String(format: "%.0f", $0.sprayRatePerHa) } ?? "")
        _concentrationFactorText = State(initialValue: preset.map { String(format: "%.1f", $0.concentrationFactor) } ?? "1.0")
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Preset Name", text: $name)
                }

                Section {
                    HStack {
                        Text("Water Volume (L)")
                            .font(.subheadline)
                        Spacer()
                        TextField("0", text: $waterVolumeText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Spray Rate (L/Ha)")
                            .font(.subheadline)
                        Spacer()
                        TextField("0", text: $sprayRateText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Concentration Factor")
                            .font(.subheadline)
                        Spacer()
                        TextField("1.0", text: $concentrationFactorText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }
            }
            .navigationTitle(preset != nil ? "Edit Preset" : "Add Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let waterVolume = Double(waterVolumeText) ?? 0
        let sprayRate = Double(sprayRateText) ?? 0
        let cf = Double(concentrationFactorText) ?? 1.0

        if var existing = preset {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.waterVolume = waterVolume
            existing.sprayRatePerHa = sprayRate
            existing.concentrationFactor = cf
            store.updateSavedSprayPreset(existing)
        } else {
            let newPreset = SavedSprayPreset(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                waterVolume: waterVolume,
                sprayRatePerHa: sprayRate,
                concentrationFactor: cf
            )
            store.addSavedSprayPreset(newPreset)
        }
        dismiss()
    }
}
