import SwiftUI

/// Member-visible inventory; authorized RPCs redact financial data server-side.
struct ChemicalInventoryView: View {
    var recordPurchase: Bool = false
    @Environment(\.accessControl) private var accessControl
    private var canViewInventory: Bool { store.selectedVineyardId != nil && accessControl?.inventoryVineyardId == store.selectedVineyardId && accessControl?.canViewInventory == true }
    private var canViewInventoryCosts: Bool { canViewInventory && accessControl?.canViewInventoryCosts == true }
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @State private var inventory: ChemicalInventorySummaryState = ChemicalInventorySummaryState()
    private var inventoryScope: String? {
        guard canViewInventory, auth.isSignedIn, let user = auth.userId, let vineyard = store.selectedVineyardId else { return nil }
        return "\(user)|\(auth.completedSignOutSequence)|\(vineyard)|\(canViewInventoryCosts)|\(accessControl?.canRecordInventoryPurchase == true)|\(accessControl?.canManageInventory == true)"
    }
    private var inventoryChemicals: [SavedChemical] {
        ChemicalStorePresentation.active(store.savedChemicals.filter { $0.vineyardId == store.selectedVineyardId })
    }
    private var summaries: [UUID: CatalogueWire] {
        inventory.values(for: inventoryScope).filter { id, _ in inventoryChemicals.contains { $0.id == id } }
    }
    private struct LoadKey: Hashable { let scope: String?; let chemicals: [SavedChemical] }
    @State private var selected: SavedChemical?
    @State private var search: String = ""
    @State private var filter: String = "All"
    private var error: String? { inventory.error }
    private var loading: Bool { inventory.loading }
    private var rows: [SavedChemical] {
        inventoryChemicals.filter { chemical in
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
                        Button("Retry") { inventory.retry() }
                    }
                }
                .searchable(text: $search)
                .task(id: LoadKey(scope: inventoryScope, chemicals: inventoryChemicals)) {
                    inventory.update(scope: inventoryScope, chemicals: inventoryChemicals)
                    if let selected, !inventoryChemicals.contains(where: { $0.id == selected.id }) { self.selected = nil }
                }
                .sheet(item: $selected) { chemical in
                    if inventoryChemicals.contains(where: { $0.id == chemical.id }), let requestScope = inventoryScope {
                        ChemicalInventoryActionsView(chemical: chemical, summary: summaries[chemical.id], recordPurchase: recordPurchase) {
                            guard requestScope == inventoryScope else { return }
                            inventory.update(scope: requestScope, chemicals: inventoryChemicals, force: [chemical.id])
                            await inventory.waitForRefresh()
                        }
                    }
                }
            } else { ContentUnavailableView("Inventory access", systemImage: "lock", description: Text("Selected-vineyard membership required.")) }
        }
        .onDisappear { inventory.update(scope: nil, chemicals: []); selected = nil }
        .onChange(of: inventoryScope) { _, _ in selected = nil; inventory.update(scope: inventoryScope, chemicals: inventoryChemicals) }
        .navigationTitle(recordPurchase ? "Chemical Purchase" : "Chemical Inventory")
    }
}
