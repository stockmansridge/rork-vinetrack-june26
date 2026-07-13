import SwiftUI

/// Saved fertiliser products — mirrors the chemical library pattern with
/// pack size, price, nutrient analysis and inventory.
struct FertiliserProductLibraryView: View {
    @Environment(MigratedDataStore.self) private var store
    let fertStore: FertiliserStore

    @State private var editingProduct: FertiliserProduct?
    @State private var showAddSheet: Bool = false

    private var vineyardId: UUID? { store.selectedVineyardId }
    private var products: [FertiliserProduct] { fertStore.products(forVineyard: vineyardId) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if products.isEmpty {
                    emptyState
                } else {
                    ForEach(products) { product in
                        Button {
                            editingProduct = product
                        } label: {
                            productCard(product)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Fertiliser Products")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add product")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            FertiliserProductEditorSheet(fertStore: fertStore, vineyardId: vineyardId, product: nil)
        }
        .sheet(item: $editingProduct) { product in
            FertiliserProductEditorSheet(fertStore: fertStore, vineyardId: vineyardId, product: product)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No products yet")
                .font(.headline)
            Text("Save compost, pelletised fertiliser, foliar nutrition and other products with pack sizes, prices and nutrient analysis.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddSheet = true
            } label: {
                Text("Add Product")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func productCard(_ product: FertiliserProduct) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(product.category.label)
                        if !product.manufacturer.isEmpty {
                            Text("· \(product.manufacturer)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if product.organicCertified {
                    Text("Organic")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(VineyardTheme.leafGreen.opacity(0.12), in: .capsule)
                }
            }

            HStack(spacing: 12) {
                Label("\(product.packSize.formatted()) \(product.form.unit)", systemImage: "shippingbox")
                if let price = product.pricePerPack {
                    Label("$\(price.formatted(.number.precision(.fractionLength(2))))", systemImage: "dollarsign.circle")
                }
                if let analysis = product.analysisSummary {
                    Text(analysis)
                }
                if let inventory = product.inventoryPacks {
                    Label("\(inventory.formatted(.number.precision(.fractionLength(0...1)))) packs", systemImage: "archivebox")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
    }
}

// MARK: - Editor

private struct FertiliserProductEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let fertStore: FertiliserStore
    let vineyardId: UUID?
    let product: FertiliserProduct?

    @State private var name: String = ""
    @State private var manufacturer: String = ""
    @State private var form: FertiliserForm = .solid
    @State private var category: FertiliserCategory = .conventional
    @State private var packSizeText: String = "25"
    @State private var priceText: String = ""
    @State private var densityText: String = ""
    @State private var nText: String = ""
    @State private var pText: String = ""
    @State private var kText: String = ""
    @State private var analysisBasis: FertiliserAnalysisBasis = .elemental
    @State private var organicCertified: Bool = false
    @State private var inventoryText: String = ""
    @State private var notes: String = ""
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    TextField("Product name", text: $name)
                    TextField("Manufacturer", text: $manufacturer)
                    Picker("Category", selection: $category) {
                        ForEach(FertiliserCategory.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Picker("Form", selection: $form) {
                        ForEach(FertiliserForm.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Organic certified", isOn: $organicCertified)
                }

                Section("Pack & Price") {
                    LabeledContent("Pack size (\(form.unit))") {
                        TextField("25", text: $packSizeText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Price per pack ($)") {
                        TextField("Optional", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if form == .liquid {
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
                        TextField("0", text: $nText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Phosphorus %") {
                        TextField("0", text: $pText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Potassium %") {
                        TextField("0", text: $kText)
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
                    Text("Record whether the label lists elemental P/K or oxide (P₂O₅/K₂O) values — mixing them up causes major rate errors. Used by nutrient-target mode (coming next).")
                }

                Section("Application Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                if product != nil {
                    Section {
                        Button("Delete Product", role: .destructive) {
                            showDeleteConfirm = true
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(product == nil ? "New Product" : "Edit Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete this product?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let product {
                        fertStore.deleteProduct(id: product.id)
                    }
                    dismiss()
                }
            }
            .onAppear { loadExisting() }
        }
    }

    private func loadExisting() {
        guard let product else { return }
        name = product.name
        manufacturer = product.manufacturer
        form = product.form
        category = product.category
        packSizeText = product.packSize.formatted(.number.grouping(.never))
        priceText = product.pricePerPack.map { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) } ?? ""
        densityText = product.density.map { $0.formatted(.number.grouping(.never)) } ?? ""
        nText = product.nitrogenPercent.map { $0.formatted(.number.grouping(.never)) } ?? ""
        pText = product.phosphorusPercent.map { $0.formatted(.number.grouping(.never)) } ?? ""
        kText = product.potassiumPercent.map { $0.formatted(.number.grouping(.never)) } ?? ""
        analysisBasis = product.analysisBasis
        organicCertified = product.organicCertified
        inventoryText = product.inventoryPacks.map { $0.formatted(.number.grouping(.never)) } ?? ""
        notes = product.applicationNotes
    }

    private func save() {
        guard let vineyardId = vineyardId ?? product?.vineyardId else {
            dismiss()
            return
        }
        let parse: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
        let updated = FertiliserProduct(
            id: product?.id ?? UUID(),
            vineyardId: vineyardId,
            name: name.trimmingCharacters(in: .whitespaces),
            manufacturer: manufacturer.trimmingCharacters(in: .whitespaces),
            form: form,
            category: category,
            packSize: parse(packSizeText) ?? 25,
            pricePerPack: parse(priceText),
            density: parse(densityText),
            nitrogenPercent: parse(nText),
            phosphorusPercent: parse(pText),
            potassiumPercent: parse(kText),
            analysisBasis: analysisBasis,
            organicCertified: organicCertified,
            applicationNotes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            inventoryPacks: parse(inventoryText)
        )
        fertStore.upsertProduct(updated)
        dismiss()
    }
}
