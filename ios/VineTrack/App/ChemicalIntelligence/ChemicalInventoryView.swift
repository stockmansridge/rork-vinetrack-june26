import SwiftUI

/// Member-visible inventory; authorized RPCs redact financial data server-side.
struct ChemicalInventoryView: View {
    var recordPurchase: Bool = false
    @Environment(\.accessControl) private var accessControl
    private var canViewInventory: Bool { store.selectedVineyardId != nil && accessControl?.inventoryVineyardId == store.selectedVineyardId && accessControl?.canViewInventory == true }
    private var canViewInventoryCosts: Bool { canViewInventory && accessControl?.canViewInventoryCosts == true }
    @Environment(MigratedDataStore.self) private var store
    @State private var summaries: [UUID: CatalogueWire] = [:]
    @State private var selected: SavedChemical?
    @State private var search: String = ""
    @State private var filter: String = "All"
    @State private var error: String?
    @State private var loading: Bool = false
    private var rows: [SavedChemical] {
        store.savedChemicals.filter { chemical in
            let status = summaries[chemical.id]?.inventoryStatus
            return chemical.vineyardId == store.selectedVineyardId && (filter == "All" || status == filter) && (search.isEmpty || (chemical.name + " " + chemical.manufacturer).localizedStandardContains(search))
        }
    }
    var body: some View {
        Group {
            if canViewInventory {
                List {
                    if recordPurchase && accessControl?.canRecordInventoryPurchase == true {
                        Text("Select a chemical to record a purchase.")
                    }
                    if !recordPurchase {
                        Section("Overview") {
                            LabeledContent("Tracked chemicals", value: "\(summaries.values.filter { $0.bool("tracked") }.count)")
                            LabeledContent("Low stock", value: "\(summaries.values.filter { $0.bool("low_stock") }.count)")
                            LabeledContent("Out of stock", value: "\(summaries.values.filter { $0.bool("out_of_stock") }.count)")
                            if canViewInventoryCosts {
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
                                    if canViewInventoryCosts { Text("Estimated stock value: \(summary.number("estimated_stock_value").map { String($0) } ?? "—") \(summary.text("currency") ?? "")") }
                                    ForEach(ChemicalInventoryTraceability.display(summary, latest: true), id: \.self) { Text($0).font(.caption) }
                                    Text("Latest purchase: \(summary.text("latest_purchase_date") ?? "—")").font(.caption)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    if loading { ProgressView("Loading inventory…") }
                    if rows.isEmpty && !loading { Text("No chemicals match this search or filter.") }
                    if let error {
                        Text(error)
                        Button("Retry") { Task { await loadSummaries() } }
                    }
                }
                .searchable(text: $search)
                .task(id: store.selectedVineyardId) {
                    summaries = [:]
                    await loadSummaries()
                }
                .onChange(of: store.savedChemicals.map(\.id)) { _, _ in Task { await loadSummaries() } }
                .sheet(item: $selected) { chemical in
                    ChemicalInventoryActionsView(chemical: chemical, summary: summaries[chemical.id], recordPurchase: recordPurchase) { await refresh(chemical.id) }
                }
            } else { ContentUnavailableView("Inventory access", systemImage: "lock", description: Text("Selected-vineyard membership required.")) }
        }.navigationTitle(recordPurchase ? "Chemical Purchase" : "Chemical Inventory")
    }
    private func loadSummaries() async {
        loading = true; error = nil
        defer { loading = false }
        for chemical in store.savedChemicals where chemical.vineyardId == store.selectedVineyardId { await refresh(chemical.id) }
    }
    private func refresh(_ id: UUID) async {
        guard canViewInventory, let vineyardId = store.selectedVineyardId,
              store.savedChemicals.contains(where: { $0.id == id && $0.vineyardId == vineyardId }) else { return }
        do {
            let row = try await CatalogueRepository().rpc("chemical_inventory_summary", ["p_saved_chemical_id": .string(id.uuidString)]).first
            guard !Task.isCancelled, canViewInventory, store.selectedVineyardId == vineyardId else { return }
            summaries[id] = row
        }
        catch { self.error = "Unable to load inventory. Check access and try again." }
    }
}
