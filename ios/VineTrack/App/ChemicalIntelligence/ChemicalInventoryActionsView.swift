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
                            Text("\(row.text("purchase_date") ?? "") · \(row.number("quantity").map { String($0) } ?? "—") \(row.text("unit") ?? "")")
                            Text("\(row.number("total_cost").map { String($0) } ?? "—") \(row.text("currency") ?? "") · \(row.text("batch_number") ?? "")")
                        }
                    }
                    Button("Load history") { Task { await loadHistory() } }
                } else {
                    if action != "Mark finished" {
                        TextField(action == "Low-stock settings" ? "Low stock percent (0–100)" : "Quantity", text: $quantity).keyboardType(.decimalPad)
                        if action != "Low-stock settings" { Picker("Unit", selection: $unit) { ForEach(["L", "mL", "kg", "g"], id: \.self) { Text($0) } } }
                    }
                    if action == "Record purchase" {
                        DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                        TextField("Total cost", text: $cost).keyboardType(.decimalPad)
                        TextField("Currency", text: $currency)
                        TextField("Batch", text: $batch)
                    }
                    if action == "Low-stock settings" { Toggle("Low-stock warnings", isOn: $warnings) }
                    TextField("Notes", text: $notes)
                    Button("Save") { Task { await save() } }.disabled(busy || !admin.isSystemAdmin)
                }
                if let error { Text(error) }
            }.navigationTitle("Inventory")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private func loadHistory() async {
        guard admin.isSystemAdmin else { return }
        do { history = try await CatalogueRepository().rpc("chemical_inventory_purchase_history", ["p_saved_chemical_id": .string(chemical.id.uuidString)]) }
        catch { self.error = "Unable to load purchase history." }
    }
    private func save() async {
        guard admin.isSystemAdmin else { return }
        var params: [String: SprayReportPayloadV1.JSONValue] = ["p_saved_chemical_id": .string(chemical.id.uuidString)]
        var name = "chemical_inventory_mark_finished"
        if action != "Mark finished" {
            guard let value = Double(quantity), value.isFinite, value >= 0 else { error = "Enter a valid quantity or percentage."; return }
            if action == "Low-stock settings" {
                guard value <= 100 else { error = "Percentage must be 0–100."; return }
                name = "chemical_inventory_set_settings"; params["p_low_stock_percent"] = .number(value); params["p_warnings_enabled"] = .bool(warnings)
            } else {
                params["p_quantity"] = .number(value); params["p_unit"] = .string(unit); params["p_notes"] = .string(notes)
                if action == "Record purchase" {
                    guard value > 0, let total = Double(cost), total.isFinite, total >= 0 else { error = "Enter a positive quantity and valid total cost."; return }
                    name = "chemical_inventory_record_purchase"
                    params["p_total_cost"] = .number(total); params["p_currency"] = .string(currency.uppercased()); params["p_batch_number"] = .string(batch)
                    params["p_purchase_date"] = .string(purchaseDate.formatted(.iso8601.year().month().day().dateSeparator(.dash)))
                } else { name = "chemical_inventory_record_stocktake"; params["p_reason"] = .string(summary?.text("tracking_status") == "needs_opening_stock" ? "opening_stock" : "correction") }
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
