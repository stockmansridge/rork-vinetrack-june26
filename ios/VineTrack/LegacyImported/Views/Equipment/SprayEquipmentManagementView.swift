import SwiftUI

/// Manages `spray_equipment` (spray rigs & tanks) for the selected vineyard.
/// These are asset-register items only — they never appear in the Fuel Log or
/// machine fuel costing — so they're reached from inside Vineyard Machines
/// rather than as a competing top-level Equipment section.
struct SprayEquipmentManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    @State private var showAddSheet: Bool = false
    @State private var editingEquipment: SprayEquipmentItem?

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    var body: some View {
        List {
            Section {
                ForEach(store.sprayEquipment) { item in
                    Group {
                        if canManageSetup {
                            Button { editingEquipment = item } label: { EquipmentRow(equipment: item) }
                        } else {
                            EquipmentRow(equipment: item)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if canManageSetup {
                            Button(role: .destructive) {
                                store.deleteSprayEquipment(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Label("Spray Rigs & Tanks", systemImage: "wrench.and.screwdriver")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                    Spacer()
                    if canManageSetup {
                        Button {
                            showAddSheet = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.body)
                        }
                    }
                }
            } footer: {
                if canManageSetup {
                    Text("Spray rigs and tanks used for spray applications. Not used for Fuel Log or machine fuel costing.")
                } else {
                    Text("Spray rigs and tanks are managed by vineyard owners and managers.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Spray Rigs & Tanks")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.sprayEquipment.isEmpty {
                ContentUnavailableView {
                    Label("No Spray Rigs", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text(canManageSetup
                         ? "Add your spray rigs and tanks for spray planning."
                         : "No spray rigs or tanks have been added yet.")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            EquipmentFormSheet(equipment: nil)
        }
        .sheet(item: $editingEquipment) { item in
            EquipmentFormSheet(equipment: item)
        }
    }
}
