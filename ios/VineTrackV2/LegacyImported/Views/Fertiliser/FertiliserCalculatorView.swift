import SwiftUI

/// Fertiliser Calculator — per-hectare and per-vine planning with pack, cost
/// and inventory maths. Saved calculations become planned tasks or completed
/// application records. In development: System Admin only.
struct FertiliserCalculatorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(FertiliserSyncService.self) private var fertiliserSync
    private var fertStore: FertiliserStore { .shared }

    @State private var mode: FertiliserCalcMode = .perHectare
    @State private var selectedPaddockIds: Set<UUID> = []
    @State private var areaText: String = ""
    @State private var vinesText: String = ""
    @State private var rateText: String = ""
    @State private var labourCostText: String = ""
    @State private var notes: String = ""

    @State private var selectedProductId: UUID?
    @State private var showAllProducts: Bool = false
    @State private var manualName: String = ""
    @State private var manualForm: FertiliserForm = .solid
    @State private var manualPackSizeText: String = "25"
    @State private var manualPriceText: String = ""

    @State private var savedBanner: String?

    private var vineyardId: UUID? { store.selectedVineyardId }

    private var paddocks: [Paddock] {
        let all = store.paddocks
        guard let vineyardId else { return all }
        return all.filter { $0.vineyardId == vineyardId }
    }

    /// The product library IS the shared saved chemical database (sql/111).
    /// Defaults to fertiliser/nutrient categories; "Show all" surfaces
    /// products that have not been categorised yet.
    private var products: [SavedChemical] {
        let all = store.savedChemicals
            .filter { $0.isActive }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !showAllProducts else { return all }
        let fertiliser = all.filter { $0.isFertiliserProduct }
        // Fall back to the full library while nothing is categorised yet so
        // the picker is never inexplicably empty.
        return fertiliser.isEmpty ? all : fertiliser
    }

    private var selectedProduct: SavedChemical? {
        selectedProductId.flatMap { id in store.savedChemicals.first { $0.id == id } }
    }

    private var records: [FertiliserRecord] {
        fertStore.records(forVineyard: vineyardId)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                devBadge
                modePicker
                blockCard
                productCard
                rateCard
                if let result = calculation {
                    resultsCard(result)
                    saveButtons(result)
                }
                recordsCard
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Fertiliser Calculator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ChemicalsManagementView()
                } label: {
                    Image(systemName: "books.vertical")
                }
                .accessibilityLabel("Saved products")
            }
        }
        .onChange(of: selectedPaddockIds) { _, _ in
            syncAreaAndVines()
        }
        .refreshable {
            await fertiliserSync.syncForSelectedVineyard()
        }
        .task {
            await fertiliserSync.syncForSelectedVineyard()
        }
    }

    private var devBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "hammer.fill")
                .font(.caption2)
            Text("In development — visible to System Admins only")
                .font(.caption)
            Spacer()
            if let savedBanner {
                Text(savedBanner)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(FertiliserCalcMode.allCases) { calcMode in
                Text(calcMode.label).tag(calcMode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    // MARK: Blocks

    private var blockCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocks")
                .font(.headline)

            if paddocks.isEmpty {
                Text("No blocks yet — add blocks in Vineyard Setup, or enter the area/vines manually below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                FlowChips(paddocks: paddocks, selected: $selectedPaddockIds)
            }

            HStack(spacing: 12) {
                if mode == .perHectare {
                    labelledField(label: "Treated area (ha)", text: $areaText, keyboard: .decimalPad)
                } else {
                    labelledField(label: "Number of vines", text: $vinesText, keyboard: .numberPad)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    // MARK: Product

    private var productCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Product")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    ChemicalsManagementView()
                } label: {
                    Text(products.isEmpty ? "Add products" : "Manage")
                        .font(.caption.weight(.semibold))
                }
            }

            Picker("Product", selection: $selectedProductId) {
                Text("Manual entry").tag(UUID?.none)
                ForEach(products) { product in
                    Text(product.name).tag(UUID?.some(product.id))
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: $showAllProducts) {
                Text("Show all saved products")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if let product = selectedProduct {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(product.category?.label ?? "Uncategorised")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if product.organicCertified {
                            Text("Organic")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(VineyardTheme.leafGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(VineyardTheme.leafGreen.opacity(0.12), in: .capsule)
                        }
                    }
                    HStack(spacing: 12) {
                        if let packSize = product.packSize, packSize > 0 {
                            Text("Pack: \(packSize.formatted()) \(product.fertiliserForm.unit)")
                        } else {
                            Text("No pack size saved")
                        }
                        if let price = product.pricePerPack {
                            Text("$\(price.formatted(.number.precision(.fractionLength(2))))/pack")
                        }
                        if let analysis = product.analysisSummary {
                            Text(analysis)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                TextField("Product name", text: $manualName)
                    .textFieldStyle(.roundedBorder)
                Picker("Form", selection: $manualForm) {
                    ForEach(FertiliserForm.allCases) { form in
                        Text(form.label).tag(form)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    labelledField(label: "Pack size (\(manualForm.unit))", text: $manualPackSizeText, keyboard: .decimalPad)
                    labelledField(label: "Price per pack ($)", text: $manualPriceText, keyboard: .decimalPad)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    // MARK: Rate

    private var activeForm: FertiliserForm {
        selectedProduct?.fertiliserForm ?? manualForm
    }

    private var rateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Application Rate")
                .font(.headline)
            HStack(spacing: 12) {
                labelledField(
                    label: mode == .perHectare
                        ? "Rate (\(activeForm.unit)/ha)"
                        : "Rate (\(activeForm.perVineUnit)/vine)",
                    text: $rateText,
                    keyboard: .decimalPad
                )
                labelledField(label: "Labour & machinery ($, optional)", text: $labourCostText, keyboard: .decimalPad)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    // MARK: Calculation

    private struct CalcResult {
        var total: Double
        var area: Double
        var vines: Int
        var rate: Double
        var packSize: Double?
        var packs: Double?
        var productCost: Double?
        var labourCost: Double?
        var remainingAfter: Double?
    }

    private var calculation: CalcResult? {
        let rate = Double(rateText.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard rate > 0 else { return nil }

        let area = Double(areaText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let vines = Int(vinesText) ?? 0

        let total: Double
        switch mode {
        case .perHectare:
            guard area > 0 else { return nil }
            total = FertiliserCalculator.totalForPerHectare(areaHectares: area, ratePerHa: rate)
        case .perVine:
            guard vines > 0 else { return nil }
            total = FertiliserCalculator.totalForPerVine(vineCount: vines, ratePerVine: rate)
        }

        let packSize: Double?
        let price: Double?
        var remaining: Double?
        if let product = selectedProduct {
            packSize = product.packSize
            price = product.pricePerPack
            if let inventory = product.inventoryQuantity, let size = product.packSize, size > 0 {
                remaining = inventory * size - total
            }
        } else {
            packSize = Double(manualPackSizeText.replacingOccurrences(of: ",", with: "."))
            price = Double(manualPriceText.replacingOccurrences(of: ",", with: "."))
        }

        let packs = packSize.flatMap { FertiliserCalculator.packsRequired(total: total, packSize: $0) }
        let cost = packSize.flatMap { FertiliserCalculator.productCost(total: total, packSize: $0, pricePerPack: price) }
        let labour = Double(labourCostText.replacingOccurrences(of: ",", with: "."))

        return CalcResult(
            total: total,
            area: area,
            vines: vines,
            rate: rate,
            packSize: packSize,
            packs: packs,
            productCost: cost,
            labourCost: labour,
            remainingAfter: remaining
        )
    }

    private func resultsCard(_ result: CalcResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Results")
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(result.total.formatted(.number.precision(.fractionLength(0...1))))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(activeForm.unit)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("required")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                if let packs = result.packs {
                    resultRow(label: "Full packs", value: "\(Int(packs))")
                    let partial = packs - Double(Int(packs))
                    resultRow(
                        label: "Partial pack",
                        value: partial > 0.001
                            ? "\((partial * (result.packSize ?? 0)).formatted(.number.precision(.fractionLength(0...1)))) \(activeForm.unit) (\(partial.formatted(.percent.precision(.fractionLength(0)))))"
                            : "None"
                    )
                    resultRow(label: "Packs to open", value: "\(Int(packs.rounded(.up)))")
                }
                if let cost = result.productCost {
                    resultRow(label: "Product cost", value: currency(cost))
                    if result.area > 0 {
                        resultRow(label: "Cost / ha", value: currency(cost / result.area))
                    }
                    if result.vines > 0 {
                        resultRow(label: "Cost / vine", value: currency(cost / Double(result.vines)))
                    }
                    if let labour = result.labourCost {
                        resultRow(label: "Labour & machinery", value: currency(labour))
                        resultRow(label: "Total job cost", value: currency(cost + labour))
                    }
                }
                if let remaining = result.remainingAfter {
                    resultRow(
                        label: "Inventory after",
                        value: "\(remaining.formatted(.number.precision(.fractionLength(0...1)))) \(activeForm.unit)"
                    )
                }
            }

            if let remaining = result.remainingAfter, remaining < 0 {
                Label("Not enough stock on hand — short by \(abs(remaining).formatted(.number.precision(.fractionLength(0...1)))) \(activeForm.unit).", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.35), lineWidth: 1))
        .padding(.horizontal)
    }

    private func resultRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func saveButtons(_ result: CalcResult) -> some View {
        HStack(spacing: 12) {
            Button {
                save(result, status: .planned)
            } label: {
                Text("Save as Planned Task")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            Button {
                save(result, status: .completed)
            } label: {
                Text("Record as Completed")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
    }

    // MARK: Records

    private var recordsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Planned & Completed")
                .font(.headline)

            if records.isEmpty {
                Text("Saved calculations appear here as planned tasks or completed application records.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    recordRow(record)
                    if record.id != records.last?.id {
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

    private func recordRow(_ record: FertiliserRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.productName.isEmpty ? "Fertiliser application" : record.productName)
                    .font(.footnote.weight(.semibold))
                Text(recordDetail(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !record.blockNames.isEmpty {
                    Text(record.blockNames.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.status.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(record.status == .completed ? VineyardTheme.leafGreen : .blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((record.status == .completed ? VineyardTheme.leafGreen : Color.blue).opacity(0.12), in: .capsule)
                HStack(spacing: 10) {
                    if record.status == .planned {
                        Button {
                            fertStore.markCompleted(id: record.id)
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.subheadline)
                        }
                        .accessibilityLabel("Mark completed")
                    }
                    Button(role: .destructive) {
                        fertStore.deleteRecord(id: record.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func recordDetail(_ record: FertiliserRecord) -> String {
        var parts: [String] = [record.date.formatted(date: .abbreviated, time: .omitted)]
        parts.append("\(record.totalProduct.formatted(.number.precision(.fractionLength(0...1)))) \(record.form.unit)")
        parts.append("\(record.rate.formatted(.number.precision(.fractionLength(0...1)))) \(record.rateUnit)")
        if let cost = record.totalCost {
            parts.append(currency(cost))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func syncAreaAndVines() {
        let selected = paddocks.filter { selectedPaddockIds.contains($0.id) }
        guard !selected.isEmpty else { return }
        let area = selected.reduce(0.0) { $0 + $1.areaHectares }
        let vines = selected.reduce(0) { $0 + $1.effectiveVineCount }
        areaText = area > 0 ? area.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) : areaText
        vinesText = vines > 0 ? "\(vines)" : vinesText
    }

    private func save(_ result: CalcResult, status: FertiliserRecordStatus) {
        guard let vineyardId else { return }
        let selected = paddocks.filter { selectedPaddockIds.contains($0.id) }
        let record = FertiliserRecord(
            vineyardId: vineyardId,
            status: status,
            mode: mode,
            productId: selectedProduct?.id,
            productName: selectedProduct?.name ?? manualName.trimmingCharacters(in: .whitespaces),
            form: activeForm,
            paddockIds: selected.map(\.id),
            blockNames: selected.map(\.name),
            areaHectares: result.area,
            vineCount: result.vines,
            rate: result.rate,
            totalProduct: result.total,
            packSize: result.packSize,
            productCost: result.productCost,
            labourMachineryCost: result.labourCost,
            notes: notes,
            allocations: blockAllocations(for: selected, result: result)
        )
        fertStore.addRecord(record)
        savedBanner = status == .planned ? "Saved as planned task" : "Recorded"
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            savedBanner = nil
        }
    }

    // MARK: Helpers

    /// Per-block share of a multi-block calculation, weighted by area
    /// (per-hectare mode) or vine count (per-vine mode) so block-level
    /// costing stays accurate.
    private func blockAllocations(for selected: [Paddock], result: CalcResult) -> [FertiliserAllocation] {
        guard !selected.isEmpty else { return [] }
        let weights: [Double] = selected.map { paddock in
            mode == .perVine ? Double(paddock.effectiveVineCount) : paddock.areaHectares
        }
        let totalWeight = weights.reduce(0, +)
        return selected.enumerated().map { index, paddock in
            let share = totalWeight > 0 ? weights[index] / totalWeight : 1.0 / Double(selected.count)
            return FertiliserAllocation(
                paddockId: paddock.id,
                areaHectares: paddock.areaHectares,
                vineCount: paddock.effectiveVineCount,
                rate: result.rate,
                productRequired: result.total * share,
                allocatedCost: result.productCost.map { $0 * share }
            )
        }
    }

    private func currency(_ value: Double) -> String {
        "$\(value.formatted(.number.precision(.fractionLength(2))))"
    }

    private func labelledField(label: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("0", text: text)
                .keyboardType(keyboard)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Block chips

private struct FlowChips: View {
    let paddocks: [Paddock]
    @Binding var selected: Set<UUID>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(paddocks) { paddock in
                let isOn = selected.contains(paddock.id)
                Button {
                    if isOn {
                        selected.remove(paddock.id)
                    } else {
                        selected.insert(paddock.id)
                    }
                } label: {
                    Text(paddock.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(isOn ? Color.blue : Color(.systemGray5), in: .capsule)
                        .foregroundStyle(isOn ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
