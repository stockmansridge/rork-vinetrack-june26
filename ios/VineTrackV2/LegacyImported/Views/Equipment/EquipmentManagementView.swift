import SwiftUI

/// Shared compact subtitle for an equipment asset's optional Serial / VIN
/// identifiers. Returns nil when neither is set so callers can hide the row.
func equipmentIdentifierSubtitle(serialNumber: String?, vinNumber: String?) -> String? {
    var parts: [String] = []
    if let serial = serialNumber?.trimmingCharacters(in: .whitespaces), !serial.isEmpty {
        parts.append("S/N \(serial)")
    }
    if let vin = vinNumber?.trimmingCharacters(in: .whitespaces), !vin.isEmpty {
        parts.append("VIN \(vin)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

struct EquipmentManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    private var otherItemsCount: Int {
        guard let vid = store.selectedVineyardId else { return 0 }
        return store.equipmentItems.filter { $0.vineyardId == vid }.count
    }

    private var otherItemsSubtitle: String {
        let count = otherItemsCount
        if count == 0 { return "Add trailers, implements, tools, irrigation parts…" }
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private var machineCount: Int {
        store.machines().filter { $0.legacyTractorId == nil }.count
    }

    private var machineSubtitle: String {
        let count = machineCount
        if count == 0 { return "Add ATVs, side-by-sides, harvesters…" }
        return "\(count) machine\(count == 1 ? "" : "s")"
    }

    private var tractorSubtitle: String {
        let count = store.tractors.count
        if count == 0 { return "Add tractors for fuel use and trip costing" }
        return "\(count) tractor\(count == 1 ? "" : "s")"
    }

    private var sprayEquipmentSubtitle: String {
        let count = store.sprayEquipment.count
        if count == 0 { return "Add spray rigs and tanks" }
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private var fuelSubtitle: String {
        let fills = fuelLogCount
        let purchases = store.fuelPurchases.count
        if fills == 0 && purchases == 0 { return "Record purchases and fuel fills" }
        return "\(purchases) purchase\(purchases == 1 ? "" : "s") · \(fills) fill\(fills == 1 ? "" : "s")"
    }

    private var fuelLogCount: Int {
        guard let vid = store.selectedVineyardId else { return 0 }
        return store.tractorFuelLogs.filter { $0.vineyardId == vid }.count
    }

    private func navCard(title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TractorManagementView()
                } label: {
                    navCard(title: "Manage Tractors", subtitle: tractorSubtitle)
                }
            } header: {
                sectionHeader("Tractors", systemImage: "truck.pickup.side.fill")
            } footer: {
                Text("Tractors used for vineyard work. Used for Fuel Log and trip costing.")
            }

            Section {
                NavigationLink {
                    SprayEquipmentManagementView()
                } label: {
                    navCard(title: "Manage Spray Equipment", subtitle: sprayEquipmentSubtitle)
                }
            } header: {
                sectionHeader("Spray Equipment", systemImage: "wrench.and.screwdriver.fill")
            } footer: {
                Text("Spray rigs and tanks used for spray applications. Not used for Fuel Log or machine fuel costing.")
            }

            Section {
                NavigationLink {
                    VineyardMachineManagementView()
                } label: {
                    navCard(title: "Manage Vineyard Machines", subtitle: machineSubtitle)
                }
            } header: {
                sectionHeader("Vineyard Machines", systemImage: "gearshape.2.fill")
            } footer: {
                Text("ATVs, side-by-sides, harvesters, utility vehicles and other powered machines used directly for vineyard work.")
            }

            Section {
                NavigationLink {
                    OtherEquipmentManagementView()
                } label: {
                    navCard(title: "Manage Other Items", subtitle: otherItemsSubtitle)
                }
            } header: {
                sectionHeader("Other Equipment & Assets", systemImage: "shippingbox.fill")
            } footer: {
                Text("Trailers, implements, tools, irrigation parts, workshop gear and other non-fuel-tracked assets.")
            }

            Section {
                NavigationLink {
                    FuelView()
                } label: {
                    navCard(title: "Fuel", subtitle: fuelSubtitle)
                }
            } header: {
                sectionHeader("Fuel", systemImage: "fuelpump.fill")
            } footer: {
                Text("Record fuel purchases for weighted cost per litre, and fuel fills to calculate machine usage over time.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Equipment")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
    }
}

struct EquipmentRow: View {
    let equipment: SprayEquipmentItem

    private var identifier: String? {
        equipmentIdentifierSubtitle(serialNumber: equipment.serialNumber, vinNumber: equipment.vinNumber)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(equipment.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Label("\(String(format: "%.0f", equipment.tankCapacityLitres)) L tank", systemImage: "drop.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let identifier {
                    Text(identifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct TractorRow: View {
    let tractor: Tractor

    private var identifier: String? {
        equipmentIdentifierSubtitle(serialNumber: tractor.serialNumber, vinNumber: tractor.vinNumber)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(tractor.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Label("\(String(format: "%.1f", tractor.fuelUsageLPerHour)) L/hr fuel usage", systemImage: "fuelpump.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let identifier {
                    Text(identifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct FuelPurchaseRow: View {
    let purchase: FuelPurchase
    @Environment(\.accessControl) private var accessControl
    @Environment(MigratedDataStore.self) private var store

    /// Region-aware display formatter (AU defaults when no settings exist).
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if accessControl?.canViewFinancials ?? false {
                    Text("\(fmt.formatFuel(litres: purchase.volumeLitres, fractionDigits: 0)) — \(fmt.formatCurrency(purchase.totalCost))")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                } else {
                    Text(fmt.formatFuel(litres: purchase.volumeLitres, fractionDigits: 0))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 8) {
                    Label(purchase.date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if accessControl?.canViewFinancials ?? false {
                        Text(fmt.formatFuelCostPerUnit(perLitre: purchase.costPerLitre))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(VineyardTheme.olive)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct EquipmentFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let equipment: SprayEquipmentItem?

    @State private var name: String = ""
    @State private var tankCapacity: String = ""
    @State private var serialNumber: String = ""
    @State private var vinNumber: String = ""

    init(equipment: SprayEquipmentItem?) {
        self.equipment = equipment
        if let e = equipment {
            _name = State(initialValue: e.name)
            _tankCapacity = State(initialValue: String(format: "%.0f", e.tankCapacityLitres))
            _serialNumber = State(initialValue: e.serialNumber ?? "")
            _vinNumber = State(initialValue: e.vinNumber ?? "")
        }
    }

    private var isValid: Bool {
        !name.isEmpty && (Double(tankCapacity) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Equipment Name", text: $name)
                } header: {
                    Text("Equipment Name")
                } footer: {
                    Text("A descriptive name for this spray rig or tank.")
                }

                Section {
                    TextField("e.g. 400", text: $tankCapacity)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Tank Capacity (litres)")
                }

                Section("Identification (optional)") {
                    TextField("Serial number", text: $serialNumber)
                        .autocorrectionDisabled()
                    TextField("VIN number", text: $vinNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
            }
            .navigationTitle(equipment == nil ? "New Equipment" : "Edit Equipment")
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
        let capacity = Double(tankCapacity) ?? 0
        let trimmedSerial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVin = vinNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing = equipment {
            existing.name = name
            existing.tankCapacityLitres = capacity
            existing.serialNumber = trimmedSerial.isEmpty ? nil : trimmedSerial
            existing.vinNumber = trimmedVin.isEmpty ? nil : trimmedVin
            store.updateSprayEquipment(existing)
        } else {
            store.addSprayEquipment(SprayEquipmentItem(
                name: name,
                tankCapacityLitres: capacity,
                serialNumber: trimmedSerial.isEmpty ? nil : trimmedSerial,
                vinNumber: trimmedVin.isEmpty ? nil : trimmedVin
            ))
        }
    }
}

struct TractorFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(TractorSyncService.self) private var tractorSync

    let tractor: Tractor?

    @Environment(MigratedDataStore.self) private var storeForAI
    @State private var brand: String = ""
    @State private var model: String = ""
    @State private var modelYearText: String = ""
    @State private var fuelUsage: String = ""
    @State private var serialNumber: String = ""
    @State private var vinNumber: String = ""
    @State private var fuelLookupLoading: Bool = false

    /// One of three mutually-exclusive lookup outcomes, shown as an inline
    /// confirmation panel above the fuel-usage field. The AI never silently
    /// overwrites the user's entered value — they must explicitly apply.
    private enum LookupOutcome {
        case match(FuelLookupResult)          // reliable AI match — confirm before applying
        case uncertain(FuelLookupResult)      // AI returned low-confidence / no model echo
        case noMatch(String?)                 // AI ran but couldn't identify the tractor
        case unavailable(String)              // network/API failure — manual entry only
    }
    @State private var lookupOutcome: LookupOutcome?

    init(tractor: Tractor?) {
        self.tractor = tractor
        if let t = tractor {
            _brand = State(initialValue: t.brand)
            _model = State(initialValue: t.model)
            _modelYearText = State(initialValue: t.modelYear.map { String($0) } ?? "")
            _fuelUsage = State(initialValue: String(format: "%.1f", t.fuelUsageLPerHour))
            _serialNumber = State(initialValue: t.serialNumber ?? "")
            _vinNumber = State(initialValue: t.vinNumber ?? "")
        }
    }

    private var parsedYear: Int? {
        let trimmed = modelYearText.trimmingCharacters(in: .whitespaces)
        guard let y = Int(trimmed), y >= 1900, y <= 2100 else { return nil }
        return y
    }

    private var isValid: Bool {
        !brand.isEmpty && !model.isEmpty && (Double(fuelUsage) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. John Deere", text: $brand)
                    TextField("e.g. 5075E", text: $model)
                    TextField("e.g. 2018", text: $modelYearText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Tractor")
                }

                Section {
                    TextField("e.g. 8.5", text: $fuelUsage)
                        .keyboardType(.decimalPad)
                    if storeForAI.settings.aiSuggestionsEnabled {
                        Button {
                            Task { await estimateFuel() }
                        } label: {
                            HStack {
                                if fuelLookupLoading {
                                    ProgressView()
                                    Text("Searching…")
                                } else {
                                    Label((lookupOutcome != nil) ? "Search Again" : "Estimate Fuel Use", systemImage: "sparkles")
                                }
                            }
                        }
                        .disabled(fuelLookupLoading || brand.trimmingCharacters(in: .whitespaces).isEmpty || model.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Fuel Usage (L/hr)")
                } footer: {
                    Text("Fuel consumption rate in litres per hour under working load. AI estimates are approximate — actual fuel use varies by load, terrain, implement, speed, and conditions.")
                }

                if let outcome = lookupOutcome {
                    lookupOutcomeSection(outcome)
                }

                Section("Identification (optional)") {
                    TextField("Serial number", text: $serialNumber)
                        .autocorrectionDisabled()
                    TextField("VIN number", text: $vinNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
            }
            .navigationTitle(tractor == nil ? "New Tractor" : "Edit Tractor")
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

    @MainActor
    private func estimateFuel() async {
        lookupOutcome = nil
        fuelLookupLoading = true
        defer { fuelLookupLoading = false }
        do {
            let result = try await TractorFuelLookupService().lookupFuelUsage(
                brand: brand.trimmingCharacters(in: .whitespaces),
                model: model.trimmingCharacters(in: .whitespaces),
                year: parsedYear
            )
            // Do NOT auto-fill — show a confirmation panel so the user can
            // verify what tractor the AI actually referenced before applying.
            lookupOutcome = result.isReliableMatch ? .match(result) : .uncertain(result)
        } catch let err as TractorLookupError {
            switch err {
            case .noReliableMatch(let msg):
                lookupOutcome = .noMatch(msg)
            case .unavailable(let msg):
                lookupOutcome = .unavailable(msg)
            case .notConfigured, .missingProviderKey:
                lookupOutcome = .unavailable(err.errorDescription ?? "Lookup unavailable")
            }
        } catch {
            lookupOutcome = .unavailable(error.localizedDescription)
        }
    }

    /// Friendly summary of what the AI referenced, e.g. "John Deere 5075E · 2018–2021".
    private func matchedTractorLabel(_ result: FuelLookupResult) -> String {
        let b = result.matchedBrand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let m = result.matchedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = [b, m].filter { !$0.isEmpty }.joined(separator: " ")
        let entered = "\(brand) \(model)".trimmingCharacters(in: .whitespaces)
        let primary = head.isEmpty ? entered : head
        if let yr = result.matchedYearRange?.trimmingCharacters(in: .whitespacesAndNewlines), !yr.isEmpty {
            return "\(primary) · \(yr)"
        }
        return primary
    }

    @ViewBuilder
    private func lookupOutcomeSection(_ outcome: LookupOutcome) -> some View {
        switch outcome {
        case .match(let result):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Tractor match found", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.olive)
                    Text(matchedTractorLabel(result))
                        .font(.body.weight(.medium))
                    Text("Estimated fuel use: \(String(format: "%.1f", result.fuelUsageLPerHour)) L/hr")
                        .font(.subheadline)
                    if let conf = result.confidence, !conf.isEmpty {
                        Text("Confidence: \(conf.capitalized)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let notes = result.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Please confirm this looks correct before saving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                Button {
                    fuelUsage = String(format: "%.1f", result.fuelUsageLPerHour)
                    lookupOutcome = nil
                } label: {
                    Label("Use this match", systemImage: "checkmark.circle.fill")
                }
                Button(role: .cancel) {
                    lookupOutcome = nil
                } label: {
                    Label("Edit manually", systemImage: "pencil")
                }
            } header: {
                Text("AI Suggestion")
            }

        case .uncertain(let result):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Uncertain match", systemImage: "questionmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("We couldn’t find a reliable tractor match. We’ve kept the details you entered. Please enter an estimated fuel rate to finish setting up this tractor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if result.fuelUsageLPerHour > 0 {
                        Divider().padding(.vertical, 2)
                        Text("Closest guess: \(matchedTractorLabel(result))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Approx. \(String(format: "%.1f", result.fuelUsageLPerHour)) L/hr")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("If unsure, enter an estimate. You can edit this later from Tractors.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                if result.fuelUsageLPerHour > 0 {
                    Button {
                        fuelUsage = String(format: "%.1f", result.fuelUsageLPerHour)
                        lookupOutcome = nil
                    } label: {
                        Label("Use closest guess", systemImage: "sparkles")
                    }
                }
                Button(role: .cancel) {
                    lookupOutcome = nil
                } label: {
                    Label("Enter fuel rate manually", systemImage: "pencil")
                }
            } header: {
                Text("AI Suggestion")
            }

        case .noMatch(let msg):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No reliable match", systemImage: "questionmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(msg ?? "We couldn’t find a reliable tractor match. We’ve kept the details you entered. Please enter an estimated fuel rate to finish setting up this tractor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("If unsure, enter an estimate. You can edit this later from Tractors.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(role: .cancel) {
                    lookupOutcome = nil
                } label: {
                    Label("Enter fuel rate manually", systemImage: "pencil")
                }
            } header: {
                Text("AI Suggestion")
            }

        case .unavailable(let msg):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Lookup unavailable", systemImage: "wifi.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Text("Tractor lookup is unavailable right now. You can still enter the tractor manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !msg.isEmpty {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Button(role: .cancel) {
                    lookupOutcome = nil
                } label: {
                    Label("Enter fuel rate manually", systemImage: "pencil")
                }
            } header: {
                Text("AI Suggestion")
            }
        }
    }

    private func save() {
        let usage = Double(fuelUsage) ?? 0
        let displayName = "\(brand) \(model)".trimmingCharacters(in: .whitespaces)
        let trimmedSerial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVin = vinNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = trimmedSerial.isEmpty ? nil : trimmedSerial
        let vin = trimmedVin.isEmpty ? nil : trimmedVin
        if var existing = tractor {
            existing.brand = brand
            existing.model = model
            existing.modelYear = parsedYear
            existing.name = displayName
            existing.fuelUsageLPerHour = usage
            existing.serialNumber = serial
            existing.vinNumber = vin
            store.updateTractor(existing)
        } else {
            store.addTractor(Tractor(name: displayName, brand: brand, model: model, modelYear: parsedYear, fuelUsageLPerHour: usage, serialNumber: serial, vinNumber: vin))
        }
        // Push immediately so other devices see the change without waiting for
        // a scene-phase active event or vineyard switch.
        Task { await tractorSync.syncForSelectedVineyard() }
    }
}

struct FuelPurchaseFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let purchase: FuelPurchase?

    @State private var volumeText: String = ""
    @State private var costText: String = ""
    @State private var date: Date = Date()

    init(purchase: FuelPurchase?) {
        self.purchase = purchase
        if let p = purchase {
            _volumeText = State(initialValue: String(format: "%.0f", p.volumeLitres))
            _costText = State(initialValue: String(format: "%.2f", p.totalCost))
            _date = State(initialValue: p.date)
        }
    }

    private var isValid: Bool {
        (Double(volumeText) ?? 0) > 0 && (Double(costText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Volume (Litres)") {
                    TextField("e.g. 500", text: $volumeText)
                        .keyboardType(.decimalPad)
                }

                Section("Total Cost ($)") {
                    TextField("e.g. 950.00", text: $costText)
                        .keyboardType(.decimalPad)
                }

                Section {
                    DatePicker("Purchase Date", selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle(purchase == nil ? "New Fuel Purchase" : "Edit Fuel Purchase")
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
        let vol = Double(volumeText) ?? 0
        let cost = Double(costText) ?? 0
        if var existing = purchase {
            existing.volumeLitres = vol
            existing.totalCost = cost
            existing.date = date
            store.updateFuelPurchase(existing)
        } else {
            store.addFuelPurchase(FuelPurchase(volumeLitres: vol, totalCost: cost, date: date))
        }
    }
}
