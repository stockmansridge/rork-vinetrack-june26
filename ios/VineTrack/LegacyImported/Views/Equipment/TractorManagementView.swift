import SwiftUI

/// Manages legacy `tractors` for the selected vineyard. Tractors remain a
/// distinct model (they back trip costing and tractor-typed Vineyard Machines),
/// so they keep their own screen — now reached from inside Vineyard Machines
/// rather than as a competing top-level Equipment section.
struct TractorManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    @State private var showAddTractorSheet: Bool = false
    @State private var editingTractor: Tractor?

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    var body: some View {
        List {
            Section {
                ForEach(store.tractors) { tractor in
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
                    Text("Tractors also appear under Vineyard Machines. Fuel usage (L/hr) can typically be found in your tractor's user manual under engine specifications.")
                } else {
                    Text("Tractors are managed by vineyard owners and managers.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tractors")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.tractors.isEmpty {
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
