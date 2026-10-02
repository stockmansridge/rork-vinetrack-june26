import SwiftUI
import Supabase

struct ChemicalInventoryActionsView: View {
    let chemical: SavedChemical
    let summary: CatalogueWire?
    let refresh: () async -> Void
    @Environment(SystemAdminService.self) private var admin
    @Environment(\.dismiss) private var dismiss
    @State private var action: String = "Set / adjust stock"
    @State private var quantity: String = ""
    @State private var unit: String = "L"
    @State private var containerCount: String = "1"
    @State private var containerSize: String = ""
    @State private var family: String = "liquid"
    @State private var supplier: String = ""
    @State private var invoice: String = ""
    @State private var expiry: String = ""
    @State private var cost: String = ""
    @State private var currency: String = "AUD"
    @State private var batch: String = ""
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
                Picker("Action", selection: $action) {
                    ForEach(["Record purchase", "Set / adjust stock", "Mark finished", "Low-stock settings", "Purchase history"], id: \.self) { Text($0) }
                }
                if action == "Purchase history" {
                    ForEach(history) { row in
                        VStack(alignment: .leading) {
                            Text("\(row.text("purchase_date") ?? "") · \(CatalogueInventoryContainer.historyText(row))")
                            Text("\(row.number("total_cost").map { String($0) } ?? "—") \(row.text("currency") ?? "") · \(row.text("batch_number") ?? "")")
                        }
                    }
                    Button("Load history") { Task { await loadHistory() } }
                } else {
                    if action == "Low-stock settings" {
                        TextField("Low stock percent (0–100)", text: $quantity).keyboardType(.decimalPad)
                    }
                    if action == "Record purchase" || action == "Set / adjust stock" {
                        if CatalogueInventoryContainer.units(form: chemical.productForm, packUnit: chemical.packUnit).isEmpty {
                            Picker("Product form", selection: $family) { Text("Liquid").tag("liquid"); Text("Solid").tag("solid") }
                                .onChange(of: family) { _, value in unit = value == "solid" ? "kg" : "L" }
                        }
                        TextField("Number of containers", text: $containerCount).keyboardType(.numberPad)
                        TextField("Container size", text: $containerSize).keyboardType(.decimalPad)
                        Picker("Unit", selection: $unit) { ForEach(CatalogueInventoryContainer.units(form: family, packUnit: ""), id: \.self) { Text($0) } }
                        if let count = Double(containerCount), let size = Double(containerSize), CatalogueInventoryContainer.valid(count: count, size: size) {
                            Text(CatalogueInventoryContainer.preview(count: count, size: size, unit: unit))
                        }
                        if action == "Set / adjust stock" {
                            TextField("Physically remaining (\(unit))", text: $quantity).keyboardType(.decimalPad)
                            Text("Container capacity and physically remaining stock are recorded separately. Remaining percentage is supplied by the backend.")
                                .font(.caption)
                        }
                    }
                    if action == "Record purchase" {
                        DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                        TextField("Total cost", text: $cost).keyboardType(.decimalPad)
                        TextField("Currency", text: $currency)
                        TextField("Batch", text: $batch)
                        TextField("Supplier", text: $supplier)
                        TextField("Invoice reference", text: $invoice)
                        TextField("Expiry date YYYY-MM-DD (optional)", text: $expiry)
                    }
                    if action == "Low-stock settings" { Toggle("Low-stock warnings", isOn: $warnings) }
                    TextField("Notes", text: $notes)
                    Button("Save") { Task { await save() } }.disabled(busy || !admin.isSystemAdmin)
                }
                if let error { Text(error) }
            }.navigationTitle("Inventory")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }.task {
            let units = CatalogueInventoryContainer.units(form: chemical.productForm, packUnit: chemical.packUnit)
            family = units.first == "kg" ? "solid" : "liquid"
            unit = units.contains(chemical.packUnit) ? chemical.packUnit : (units.first ?? "L")
            containerSize = chemical.packSize.flatMap { $0.isFinite && $0 > 0 ? CatalogueInventoryContainer.number($0) : nil } ?? ""
        }
    }
    private func loadHistory() async {
        guard admin.isSystemAdmin else { return }
        do { history = try await CatalogueRepository().rpc(CatalogueInventoryMutation.history, ["p_saved_chemical_id": .string(chemical.id.uuidString)]) }
        catch { self.error = "Unable to load purchase history." }
    }
    private func save() async {
        guard admin.isSystemAdmin else { return }
        var params: [String: SprayReportPayloadV1.JSONValue] = ["p_saved_chemical_id": .string(chemical.id.uuidString)]
        var name = "chemical_inventory_mark_finished"
        if action != "Mark finished" {
            if action == "Low-stock settings" {
                guard let value = Double(quantity), value.isFinite, value >= 0 else { error = "Enter a valid percentage."; return }
                guard value <= 100 else { error = "Percentage must be 0–100."; return }
                name = "chemical_inventory_set_settings"; params["p_low_stock_percent"] = .number(value); params["p_warnings_enabled"] = .bool(warnings)
            } else {
                guard let count = Double(containerCount), let size = Double(containerSize), CatalogueInventoryContainer.valid(count: count, size: size) else { error = "Enter a positive whole container count and positive container size."; return }
                params.merge(CatalogueInventoryContainer.fields(count: count, size: size, unit: unit)) { _, new in new }
                params["p_notes"] = .string(notes)
                if action == "Record purchase" {
                    guard let total = Double(cost), total.isFinite, total >= 0 else { error = "Enter a valid total cost."; return }
                    if !expiry.isEmpty {
                        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                        guard let date = formatter.date(from: expiry), formatter.string(from: date) == expiry else { error = "Enter expiry as YYYY-MM-DD."; return }
                    }
                    name = CatalogueInventoryMutation.purchase
                    params["p_supplier"] = supplier.isEmpty ? .null : .string(supplier)
                    params["p_invoice_reference"] = invoice.isEmpty ? .null : .string(invoice)
                    params["p_expiry_date"] = expiry.isEmpty ? .null : .string(expiry)
                    params["p_total_cost"] = .number(total); params["p_currency"] = .string(currency.uppercased()); params["p_batch_number"] = .string(batch)
                    params["p_purchase_date"] = .string(purchaseDate.formatted(.iso8601.year().month().day().dateSeparator(.dash)))
                } else {
                    guard let value = Double(quantity), value.isFinite, value >= 0 else { error = "Enter a valid physically remaining quantity."; return }
                    name = CatalogueInventoryMutation.stocktake
                    params.merge(CatalogueInventoryContainer.stockFields(quantity: value, unit: unit)) { _, new in new }
                    params["p_reason"] = .string(summary?.text("tracking_status") == "needs_opening_stock" ? "opening_stock" : "correction")
                    params["p_effective_at"] = .string(Date().formatted(.iso8601))
                }
            }
        } else { params["p_notes"] = .string(notes) }
        busy = true; defer { busy = false }
        do {
            // Mutations return scalar IDs/void, not summary rows.
            try await CatalogueInventoryMutation.perform(systemAdmin: admin.isSystemAdmin, operation: name, chemicalId: chemical.id,
                mutate: { _ = try await SupabaseClientProvider.shared.client.rpc(name, params: params).execute() },
                refresh: { _ in await refresh() })
            dismiss()
        } catch { self.error = "Inventory was not confirmed. Check access and try again; verify history before repeating an uncertain purchase." }
    }
}
