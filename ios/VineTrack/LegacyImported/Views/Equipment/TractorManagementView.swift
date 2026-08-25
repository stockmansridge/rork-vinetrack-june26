import SwiftUI

/// Manages `tractors` for the selected vineyard. This is the ONLY place a
/// tractor is created or edited.
///
/// A tractor keeps its own model because it backs trip costing and, where the
/// architecture needs one, a linked `vineyard_machines` row. That linked row is
/// an internal compatibility record: it is deliberately hidden from the
/// Vineyard Machines screen so the user sees each tractor in one place only.
struct TractorManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    @State private var showAddTractorSheet: Bool = false
    @State private var editingTractor: Tractor?

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    var body: some View {
        List {
            Section {
                ForEach(store.currentTractorsSorted) { tractor in
                    Group {
                        if canManageSetup {
                            Button { editingTractor = tractor } label: { TractorRow(tractor: tractor) }
                        } else {
                            TractorRow(tractor: tractor)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if canManageSetup {
                            Button(role: .destructive) {
                                store.deleteTractor(tractor)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Label("Tractors", systemImage: "truck.pickup.side.fill")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                    Spacer()
                    if canManageSetup {
                        Button {
                            showAddTractorSheet = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.body)
                        }
                    }
                }
            } footer: {
                if canManageSetup {
                    Text("Add tractors used for vineyard work, fuel tracking and trip costing. Fuel usage (L/hr) can typically be found in your tractor's user manual under engine specifications.")
                } else {
                    Text("Tractors are managed by vineyard owners and managers.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tractors")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.currentTractors.isEmpty {
                ContentUnavailableView {
                    Label("No Tractors", systemImage: "truck.pickup.side.fill")
                } description: {
                    Text(canManageSetup
                         ? "Add your tractors to track fuel use and trip costing."
                         : "No tractors have been added yet.")
                }
            }
        }
        .sheet(isPresented: $showAddTractorSheet) {
            TractorFormSheet(tractor: nil)
        }
        .sheet(item: $editingTractor) { item in
            TractorFormSheet(tractor: item)
        }
    }
}
