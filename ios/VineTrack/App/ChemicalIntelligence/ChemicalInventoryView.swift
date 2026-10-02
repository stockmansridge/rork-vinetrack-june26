import SwiftUI

/// System Admin pilot, using inventory RPCs exclusively.
struct ChemicalInventoryView: View {
    @Environment(SystemAdminService.self) private var admin
    @Environment(MigratedDataStore.self) private var store
    @State private var summaries: [UUID: CatalogueWire] = [:]
    @State private var selected: SavedChemical?
    @State private var search: String = ""
    @State private var filter: String = "All"
    @State private var error: String?
    private var rows: [SavedChemical] {
        store.savedChemicals.filter { chemical in
            let status = summaries[chemical.id]?.inventoryStatus
            return (filter == "All" || status == filter) && (search.isEmpty || (chemical.name + " " + chemical.manufacturer).localizedStandardContains(search))
        }
    }
    var body: some View {
        Group {
            if CatalogueTerminalResolver.inventoryAllowed(systemAdmin: admin.isSystemAdmin) {
                List {
                    Section("Overview") {
                        LabeledContent("Tracked chemicals", value: "\(summaries.values.filter { $0.bool("tracked") }.count)")
                        LabeledContent("Low stock", value: "\(summaries.values.filter { $0.bool("low_stock") }.count)")
                        LabeledContent("Out of stock", value: "\(summaries.values.filter { $0.bool("out_of_stock") }.count)")
                        let values = summaries.values.compactMap { row -> (String, Double)? in
                            guard let value = row.number("estimated_stock_value") else { return nil }
                            return (row.text("currency") ?? "", value)
                        }
                        if values.isEmpty { LabeledContent("Estimated stock value", value: "—") }
                        else {
                            ForEach(Dictionary(grouping: values, by: { $0.0 }).keys.sorted(), id: \.self) { currency in
                                LabeledContent("Estimated stock value (\(currency))", value: String(values.filter { $0.0 == currency }.reduce(0) { $0 + $1.1 }))
                            }
                        }
                    }
                    Picker("Filter", selection: $filter) {
                        ForEach(["All", "In stock", "Low stock", "Out of stock", "Opening stock not set"], id: \.self) { Text($0) }
                    }
                    ForEach(rows) { chemical in
                        Button { selected = chemical } label: {
                            VStack(alignment: .leading) {
                                CatalogueSavedChemicalView(chemical: chemical)
                                if let summary = summaries[chemical.id] {
                                    Text(summary.inventoryStatus)
                                    if summary.inventoryStatus != "Opening stock not set" {
                                        Text("\(summary.number("current_quantity").map { String($0) } ?? "—") \(summary.text("display_unit") ?? "")")
                                        if let percent = summary.number("percent_remaining") { ProgressView(value: percent / 100); Text("\(Int(percent))%") }
                                    }
                                    Text("Estimated stock value: \(summary.number("estimated_stock_value").map { String($0) } ?? "—") \(summary.text("currency") ?? "")")
                                    Text("Latest purchase: \(summary.text("latest_purchase_date") ?? "—") · Batch: \(summary.text("latest_batch_number") ?? "—")").font(.caption)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    if let error { Text(error) }
                }
                .searchable(text: $search)
                .task(id: store.selectedVineyardId) {
                    summaries = [:]
                    for chemical in store.savedChemicals { await refresh(chemical.id) }
                }
                .sheet(item: $selected) { chemical in
                    ChemicalInventoryActionsView(chemical: chemical, summary: summaries[chemical.id]) { await refresh(chemical.id) }
                }
            } else { ContentUnavailableView("Inventory pilot", systemImage: "lock", description: Text("System Admin access required.")) }
        }.navigationTitle("Chemical Inventory")
    }
    private func refresh(_ id: UUID) async {
        guard admin.isSystemAdmin else { return }
        do { summaries[id] = try await CatalogueRepository().rpc("chemical_inventory_summary", ["p_saved_chemical_id": .string(id.uuidString)]).first }
        catch { self.error = "Unable to load inventory. Check access and try again." }
    }
}
