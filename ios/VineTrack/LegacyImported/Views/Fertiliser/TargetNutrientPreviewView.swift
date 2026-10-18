import SwiftUI

/// A single nutrient-entry workflow. Receives existing library/blocks; cannot save or mutate either.
struct TargetNutrientPreviewView: View {
    let products: [SavedChemical]
    let paddocks: [Paddock]
    let formatter: RegionFormatter
    let isSystemAdmin: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: TargetNutrient.Draft = .init()
    @State private var productId: UUID?
    @State private var manualName: String = ""
    @State private var liquid: Bool = false
    @State private var selectedIds: Set<UUID> = []
    @State private var countBasis: String = FertiliserVineCounts.actual
    @State private var vinesText: String = ""
    @State private var areaText: String = ""
    @State private var information: String?
    @State private var packSizeText: String = ""
    @State private var packPriceText: String = ""
    private var product: SavedChemical? { products.first { $0.id == productId } }
    private var isLiquid: Bool { product?.fertiliserForm == .liquid || (product == nil && liquid) }
    private var blocks: [Paddock] { paddocks.filter { selectedIds.contains($0.id) } }
    private var vines: Int? { blocks.isEmpty ? Int(vinesText) : FertiliserVineCounts.total(blocks, basis: countBasis) }
    private var area: Double? {
        if blocks.isEmpty { return TargetNutrient.number(areaText).map { formatter.areaToCanonical($0) } }
        guard blocks.allSatisfy({ $0.areaHectares.isFinite && $0.areaHectares > 0 }) else { return nil }
        return blocks.reduce(0) { $0 + $1.areaHectares }
    }
    private var result: TargetNutrient.Result { TargetNutrient.calculate(draft, liquid: isLiquid, vines: vines, areaHa: area) }

    var body: some View {
        if TargetNutrient.canPreview(isSystemAdmin: isSystemAdmin) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("System Admin preview · Nothing is saved")
                            .font(.caption).foregroundStyle(.secondary)
                        if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
                            HStack(alignment: .top, spacing: 20) {
                                inputs.frame(maxWidth: .infinity)
                                results.frame(maxWidth: .infinity)
                            }
                        } else {
                            inputs
                            results
                        }
                        blockDetails
                        packaging
                        Button("Save unavailable in preview") {}.disabled(true)
                            .accessibilityIdentifier("nutrient.saveDisabled")
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            .alert("About this calculation", isPresented: Binding(get: { information != nil }, set: { if !$0 { information = nil } })) {
                Button("OK") { information = nil }
            } message: { Text(information ?? "") }
        } else {
            ContentUnavailableView("System Admin preview", systemImage: "lock", description: Text("Target Nutrient is not enabled for this account."))
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calculator").font(.headline)
            Picker("Product", selection: $productId) {
                Text("Manual entry").tag(UUID?.none)
                ForEach(products) { item in Text(item.name).tag(UUID?.some(item.id)) }
            }.accessibilityIdentifier("nutrient.product")
            .onChange(of: productId) { _, _ in
                draft.analysisBasis = "unknown"
                draft.concentrationBasis = "unknown"
                draft.density = ""; draft.densityReference = ""
            }
            if product == nil {
                TextField("Product name", text: $manualName).textFieldStyle(.roundedBorder)
                Toggle("Liquid product", isOn: $liquid).onChange(of: liquid) { _, _ in
                    draft.concentrationBasis = "unknown"; draft.density = ""; draft.densityReference = ""
                }
            } else {
                Text("Enter the percentage from the label. Legacy N/P/K values are not verified analysis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Nutrient", selection: Binding(get: { draft.nutrient }, set: { draft.selectNutrient($0) })) {
                ForEach(TargetNutrient.nutrients, id: \.key) { item in Text("\(item.key) — \(item.name)").tag(item.key) }
            }.accessibilityIdentifier("nutrient.selection")
            if draft.nutrient == "other" { TextField("Nutrient name", text: $draft.otherName).textFieldStyle(.roundedBorder) }
            HStack {
                Text("Product nutrient (%)").font(.subheadline)
                info("Percentage", "Use the actual elemental nutrient percentage on the label. Oxide values such as P₂O₅ and K₂O are different and are not converted. w/w means grams per 100 g product; w/v means grams per 100 mL product.")
            }
            decimal("Nutrient percent", text: $draft.percent, id: "nutrient.percent")
                .onChange(of: draft.percent) { _, _ in
                    if draft.nutrient == "N" { draft.analysisBasis = "elemental" }
                    if !isLiquid { draft.concentrationBasis = "w/w" }
                }
            if TargetNutrient.oxideKeys.contains(draft.nutrient) || draft.analysisBasis != "elemental" {
                Picker("Percentage declared as", selection: $draft.analysisBasis) {
                    Text("Confirm from label").tag("unknown")
                    Text("Elemental — actual nutrient").tag("elemental")
                    Text("Oxide — conversion unavailable").tag("oxide")
                }.accessibilityIdentifier("nutrient.analysisBasis")
            }
            if isLiquid {
                Picker("Concentration basis", selection: $draft.concentrationBasis) {
                    Text("Confirm from label").tag("unknown")
                    Text("w/w — weight / weight").tag("w/w")
                    Text("w/v — weight / volume").tag("w/v")
                }.accessibilityIdentifier("nutrient.concentration")
                if draft.concentrationBasis == "w/w" {
                    HStack { Text("Documented density"); info("Density", "Only w/w liquids need density to convert product mass to litres. Enter kg/L and the label or technical-sheet reference. A w/v percentage already gives nutrient mass per product volume.") }
                    decimal("Density (kg/L)", text: $draft.density, id: "nutrient.density")
                    TextField("Density source — label / technical sheet", text: $draft.densityReference).textFieldStyle(.roundedBorder)
                }
            }
            Picker("Target basis", selection: $draft.perVine) {
                Text("g nutrient/vine").tag(true)
                Text("kg nutrient/ha").tag(false)
            }.accessibilityIdentifier("nutrient.targetBasis")
            decimal("Target amount", text: $draft.target, id: "nutrient.target")
            if blocks.isEmpty {
                if draft.perVine {
                    TextField("Number of vines", text: $vinesText).keyboardType(.numberPad).textFieldStyle(.roundedBorder).accessibilityIdentifier("nutrient.vines")
                } else {
                    decimal("Treated area (\(formatter.areaUnitAbbreviation))", text: $areaText, id: "nutrient.area")
                }
            } else {
                Text(draft.perVine ? "\(vines.map(String.init) ?? "Unavailable") vines selected" : formatter.formatArea(hectares: area ?? 0))
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(14).background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Results").font(.headline).accessibilityIdentifier("nutrient.results")
            if let rate = result.rate {
                metric("Product required", "\(display(rate)) \(result.rateUnit)", id: "nutrient.rate")
            } else { Text("Product rate — waiting for label information").foregroundStyle(.secondary) }
            if let total = result.totalProduct {
                metric("Total product required", result.productUnit == "L" ? "\(display(formatter.volumeValue(litres: total))) \(formatter.volumeUnitAbbreviation)" : "\(display(total)) kg", id: "nutrient.total")
            } else { Text("Total product — enter quantity or select blocks").foregroundStyle(.secondary) }
            if let nutrient = result.totalNutrientKg {
                metric("Total actual \(draft.nutrient == "other" ? draft.otherName : draft.nutrient) delivered", "\(display(nutrient)) kg", id: "nutrient.delivered")
            }
            ForEach(result.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Text("Preview only · No records, inventory or product analyses are changed.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.leafGreen.opacity(0.08), in: .rect(cornerRadius: 14))
    }

    private var blockDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocks & vine counts").font(.headline).accessibilityIdentifier("nutrient.blockDetails")
            Text("Choose existing blocks, or leave unselected to use manual quantities above.").font(.caption).foregroundStyle(.secondary)
            if draft.perVine {
                Picker("Vine count basis", selection: $countBasis) {
                    Text("Actual").tag(FertiliserVineCounts.actual)
                    Text("Assumed full").tag(FertiliserVineCounts.assumedFull)
                }.pickerStyle(.segmented)
            }
            ForEach(paddocks) { block in
                Toggle(isOn: Binding(get: { selectedIds.contains(block.id) }, set: { if $0 { selectedIds.insert(block.id) } else { selectedIds.remove(block.id) } })) {
                    VStack(alignment: .leading) {
                        Text(block.name)
                        Text(draft.perVine ? "\(FertiliserVineCounts.count(block, basis: countBasis).map(String.init) ?? "Unavailable") vines · \(FertiliserVineCounts.label(countBasis))" : formatter.formatArea(hectares: block.areaHectares)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(14).background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
    }

    private var packaging: some View {
        DisclosureGroup("Packaging & costs (optional)") {
            VStack(alignment: .leading, spacing: 8) {
                if let size = product?.packSize {
                    Text("Saved pack size: \(display(size)) \(isLiquid ? "L" : "kg")")
                } else { decimal("Pack size (\(isLiquid ? "L" : "kg"))", text: $packSizeText, id: "nutrient.packSize") }
                if product == nil { decimal("Price per pack (\(formatter.currencyCode))", text: $packPriceText, id: "nutrient.packPrice") }
                if let total = result.totalProduct, result.productUnit == (isLiquid ? "L" : "kg"),
                   let size = product?.packSize ?? TargetNutrient.number(packSizeText),
                   let packs = FertiliserCalculator.packsRequired(total: total, packSize: size), packs.isFinite {
                    Text("Packs required: \(display(packs)) · Open \(display(packs.rounded(.up)))")
                    if product == nil, let cost = FertiliserCalculator.productCost(total: total, packSize: size, pricePerPack: TargetNutrient.number(packPriceText)), cost.isFinite {
                        Text("Estimated product cost: \(formatter.formatCurrency(cost))")
                    }
                }
                Text("No stock is reserved or deducted. Saved-product pricing remains in the existing purchase history.").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.font(.subheadline).padding(14).background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
    }

    private func display(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...3))) }
    private func metric(_ label: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.bold)).monospacedDigit().accessibilityIdentifier(id)
        }
    }
    private func decimal(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityIdentifier(id)
        }
    }
    private func info(_ label: String, _ message: String) -> some View {
        Button { information = message } label: { Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("About \(label)")
    }
}
