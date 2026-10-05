import SwiftUI
import Supabase

struct ChemicalInventoryActionsView: View {
    let chemical: SavedChemical
    let summary: CatalogueWire?
    var recordPurchase: Bool = false
    let refresh: () async -> Void
    @Environment(\.accessControl) private var accessControl
    @Environment(MigratedDataStore.self) private var store
    private var canViewInventory: Bool { store.selectedVineyardId != nil && accessControl?.inventoryVineyardId == store.selectedVineyardId && store.selectedVineyardId == chemical.vineyardId && accessControl?.canViewInventory == true }
    private var canRecordInventoryPurchase: Bool { canViewInventory && accessControl?.canRecordInventoryPurchase == true }
    private var canManageInventory: Bool { canViewInventory && accessControl?.canManageInventory == true }
    private var canViewInventoryCosts: Bool { canViewInventory && accessControl?.canViewInventoryCosts == true }
    private var actions: [String] {
        (canRecordInventoryPurchase ? ["Record purchase"] : []) +
        (canManageInventory ? [stockAction, "Mark finished", "Low-stock settings"] : []) +
        (canViewInventory ? ["Purchase history"] : [])
    }
    private var canSave: Bool { actions.contains(action) && action != "Purchase history" && (action == "Record purchase" ? canRecordInventoryPurchase : canManageInventory) }
    @Environment(\.dismiss) private var dismiss
    @State private var action: String = "Stocktake / Adjust"
    @State private var physicalEdited: Bool = false
    @State private var lowStockPercent: String = ""
    private var opening: Bool { summary?.text("tracking_status") == "needs_opening_stock" }
    private var stockAction: String { opening ? "Set Opening Stock" : "Stocktake / Adjust" }
    @State private var quantity: String = ""
    @State private var unit: String = "L"
    @State private var containerCount: String = "1"
    @State private var containerSize: String = ""
    @State private var family: String = "liquid"
    @State private var supplier: String = ""
    @State private var invoice: String = ""
    @State private var expiry: String = ""
    @State private var cost: String = ""
    @State private var currency: String = ""
    @State private var batch: String = ""
    @State private var batchDate: Date? = nil
    @State private var serialNumber: String = ""
    @State private var choosingBatchDate: Bool = false
    @State private var batchDateDraft: Date = Date()
    @State private var notes: String = ""
    @State private var purchaseDate: Date = Date()
    @State private var warnings: Bool = true
    @State private var history: [CatalogueWire] = []
    @State private var busy: Bool = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text(chemical.name).font(.headline)
                if let summary {
                    Text(summary.inventoryStatus)
                    if summary.inventoryStatus != "Opening stock not set" {
                        LabeledContent("Current quantity", value: "\(summary.number("current_quantity").map { String($0) } ?? "—") \(summary.text("display_unit") ?? "")")
                    }
                    LabeledContent("Last stocktake", value: summary.text("last_stocktake_at") ?? "—")
                    LabeledContent("Used since stocktake", value: summary.number("used_since_stocktake").map { String($0) } ?? "—")
                    LabeledContent("Low-stock threshold", value: "\(summary.number("low_stock_threshold_quantity").map { String($0) } ?? "—") \(summary.text("display_unit") ?? "")")
                }
                Picker("Action", selection: $action) {
                    ForEach(actions, id: \.self) { Text($0) }
                }.disabled(busy)
                if action == "Purchase history" {
                    ForEach(history) { row in
                        VStack(alignment: .leading) {
                            Text("\(row.text("purchase_date") ?? "") · \(CatalogueInventoryContainer.historyText(row))")
                            if canViewInventoryCosts { Text("\(row.number("total_cost").map { String($0) } ?? "—") \(row.text("currency") ?? "")") }
                            ForEach(ChemicalInventoryTraceability.display(row), id: \.self) { Text($0).font(.caption) }
                            if canViewInventoryCosts, let unitCost = row.number("unit_cost") { Text("Unit cost: \(unitCost) \(row.text("currency") ?? "")") }
                            if let expiry = row.text("expiry_date") { Text("Expiry: \(expiry)").font(.caption) }
                            Text([row.text("supplier"), row.text("invoice_reference")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption)
                        }
                    }
                    Button("Load history") { Task { await loadHistory() } }
                } else if canSave {
                    if action == "Low-stock settings" {
                        TextField("Low stock percent (0–100)", text: $lowStockPercent).keyboardType(.decimalPad)
                    }
                    if action == "Record purchase" {
                        DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                    }
                    if action == "Record purchase" || action == stockAction {
                        if CatalogueInventoryContainer.units(form: chemical.productForm, packUnit: chemical.packUnit).isEmpty {
                            Picker("Product form", selection: $family) { Text("Liquid").tag("liquid"); Text("Solid").tag("solid") }
                                .onChange(of: family) { _, value in unit = value == "solid" ? "kg" : "L" }
                        }
                        if action == "Record purchase" || opening {
                            TextField("Number of containers", text: $containerCount).keyboardType(.numberPad)
                            TextField("Container size", text: $containerSize).keyboardType(.decimalPad)
                        }
                        Picker("Unit", selection: $unit) { ForEach(CatalogueInventoryContainer.units(form: family, packUnit: ""), id: \.self) { Text($0) } }
                        if (action == "Record purchase" || opening), let count = Double(containerCount), let size = Double(containerSize), CatalogueInventoryContainer.valid(count: count, size: size) {
                            Text(CatalogueInventoryContainer.preview(count: count, size: size, unit: unit))
                        }
                        if action == stockAction {
                            TextField("Current physical quantity (\(unit))", text: Binding(get: { quantity }, set: { quantity = $0; physicalEdited = true })).keyboardType(.decimalPad)
                            Text("Container capacity and physically remaining stock are recorded separately. Remaining percentage is supplied by the backend.")
                                .font(.caption)
                        }
                    }
                    if action == "Record purchase" {
                        TextField("Total cost", text: $cost).keyboardType(.decimalPad)
                        TextField("Currency", text: $currency)
                        TextField("Batch / Lot number", text: $batch)
                        Button {
                            batchDateDraft = batchDate ?? Date()
                            choosingBatchDate = true
                        } label: {
                            LabeledContent("Production / Batch date", value: batchDate.map(ChemicalInventoryTraceability.dateText) ?? "Not set")
                        }.disabled(busy)
                        if batchDate != nil {
                            Button("Clear Production / Batch date") { batchDate = nil }.disabled(busy)
                        }
                        TextField("Serial number (if applicable)", text: $serialNumber)
                        TextField("Supplier", text: $supplier)
                        TextField("Invoice / reference", text: $invoice)
                        TextField("Expiry date YYYY-MM-DD (optional)", text: $expiry)
                    }
                    if action == "Low-stock settings" { Toggle("Low-stock warnings", isOn: $warnings) }
                    TextField("Notes", text: $notes)
                    Button("Save") { Task { await save() } }.disabled(busy || !canSave)
                }
                if let error { Text(error) }
            }.navigationTitle("Inventory")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
        }
        .sheet(isPresented: $choosingBatchDate) {
            NavigationStack {
                Form {
                    DatePicker("Production / Batch date", selection: $batchDateDraft, displayedComponents: .date)
                    Text("Optional manufacturer date; it may pre-date purchase.")
                }
                .navigationTitle("Production / Batch date")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingBatchDate = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use date") { batchDate = batchDateDraft; choosingBatchDate = false }
                    }
                }
            }.presentationDetents([.medium])
        }
        .interactiveDismissDisabled(busy)
        .onChange(of: containerCount) { _, _ in updateOpeningQuantity() }
        .onChange(of: containerSize) { _, _ in updateOpeningQuantity() }
        .onChange(of: action) { _, value in if value == "Purchase history" { Task { await loadHistory() } } }
        .task {
            if currency.isEmpty { currency = store.settings.regionFormatter.currencyCode }
            action = recordPurchase && canRecordInventoryPurchase ? "Record purchase" : (canManageInventory ? stockAction : "Purchase history")
            if action == "Purchase history" { await loadHistory() }
            warnings = summary?.fields["warnings_enabled"] == nil ? true : summary?.bool("warnings_enabled") == true
            lowStockPercent = summary?.number("low_stock_percent").map(CatalogueInventoryContainer.number) ?? ""
            if !opening { quantity = summary?.number("current_quantity").map(CatalogueInventoryContainer.number) ?? "" }
            let units = CatalogueInventoryContainer.units(form: chemical.productForm, packUnit: chemical.packUnit)
            family = units.first == "kg" ? "solid" : "liquid"
            let preferredUnit = !opening ? summary?.text("display_unit") ?? chemical.packUnit : chemical.packUnit
            unit = units.contains(preferredUnit) ? preferredUnit : (units.first ?? "L")
            containerSize = chemical.packSize.flatMap { $0.isFinite && $0 > 0 ? CatalogueInventoryContainer.number($0) : nil } ?? ""
        }
    }
    private func updateOpeningQuantity() {
        guard opening else { return }
        quantity = CatalogueInventoryContainer.openingQuantity(count: containerCount, size: containerSize, physical: quantity, edited: physicalEdited)
    }
    private func loadHistory() async {
        guard canViewInventory else { return }
        do {
            let rows = try await CatalogueRepository().rpc(CatalogueInventoryMutation.history, ["p_saved_chemical_id": .string(chemical.id.uuidString)])
            guard canViewInventory, !Task.isCancelled else { return }
            history = rows
        }
        catch { self.error = "Unable to load purchase history." }
    }
    private func save() async {
        guard canSave else { return }
        var params: [String: SprayReportPayloadV1.JSONValue] = ["p_saved_chemical_id": .string(chemical.id.uuidString)]
        var name = "chemical_inventory_mark_finished"
        if action != "Mark finished" {
            if action == "Low-stock settings" {
                guard let value = Double(lowStockPercent), value.isFinite, value >= 0 else { error = "Enter a valid percentage."; return }
                guard value <= 100 else { error = "Percentage must be 0–100."; return }
                name = "chemical_inventory_set_settings"; params["p_low_stock_percent"] = .number(value); params["p_warnings_enabled"] = .bool(warnings)
            } else {
                if action == "Record purchase" || opening {
                    guard let count = Double(containerCount), let size = Double(containerSize), CatalogueInventoryContainer.valid(count: count, size: size) else { error = "Enter a positive whole container count and positive container size."; return }
                    params.merge(CatalogueInventoryContainer.fields(count: count, size: size, unit: unit)) { _, new in new }
                }
                params["p_notes"] = ChemicalInventoryTraceability.nullableText(notes)
                if action == "Record purchase" {
                    guard let total = Double(cost), total.isFinite, total >= 0 else { error = "Enter a valid total cost."; return }
                    if !expiry.isEmpty {
                        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                        guard let date = formatter.date(from: expiry), formatter.string(from: date) == expiry else { error = "Enter expiry as YYYY-MM-DD."; return }
                    }
                    name = CatalogueInventoryMutation.purchase
                    params["p_supplier"] = ChemicalInventoryTraceability.nullableText(supplier)
                    params["p_invoice_reference"] = ChemicalInventoryTraceability.nullableText(invoice)
                    params["p_expiry_date"] = expiry.isEmpty ? .null : .string(expiry)
                    params["p_total_cost"] = .number(total); params["p_currency"] = .string(currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                    params.merge(ChemicalInventoryTraceability.fields(batch: batch, batchDate: batchDate.map(ChemicalInventoryTraceability.dateText), serial: serialNumber)) { _, new in new }
                    params["p_purchase_date"] = .string(purchaseDate.formatted(.iso8601.year().month().day().dateSeparator(.dash)))
                } else {
                    guard let value = Double(quantity), value.isFinite, value >= 0 else { error = "Enter a valid physically remaining quantity."; return }
                    name = CatalogueInventoryMutation.stocktake
                    params.merge(CatalogueInventoryContainer.stockFields(quantity: value, unit: unit)) { _, new in new }
                    params["p_reason"] = .string(summary?.text("tracking_status") == "needs_opening_stock" ? "opening_stock" : "correction")
                    params["p_effective_at"] = .string(Date().formatted(.iso8601))
                }
            }
        } else { params["p_notes"] = ChemicalInventoryTraceability.nullableText(notes) }
        busy = true; defer { busy = false }
        do {
            // Mutations return scalar IDs/void, not summary rows.
            try await CatalogueInventoryMutation.perform(canManageInventory: canManageInventory, canRecordInventoryPurchase: canRecordInventoryPurchase, operation: name, chemicalId: chemical.id,
                mutate: { _ = try await SupabaseClientProvider.shared.client.rpc(name, params: params).execute() },
                refresh: { _ in await refresh() })
            if name == CatalogueInventoryMutation.purchase { await loadHistory() }
            dismiss()
        } catch { self.error = "Inventory was not confirmed. Check access and try again; verify history before repeating an uncertain purchase." }
    }
}
