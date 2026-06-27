import SwiftUI

struct SprayManagementSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    @State private var showUCRInfo: Bool = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SprayPresetsView()
                } label: {
                    HStack {
                        Label("Spray Presets", systemImage: "flask")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(store.savedChemicals.count) chemicals")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Manage saved chemicals and tank presets for quick selection in spray records.")
            }

            Section {
                NavigationLink {
                    ChemicalsManagementView()
                } label: {
                    HStack {
                        Label("Chemicals", systemImage: "flask.fill")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(store.savedChemicals.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    EquipmentManagementView()
                } label: {
                    HStack {
                        Label("Equipment", systemImage: "wrench.and.screwdriver")
                            .foregroundStyle(.primary)
                        Spacer()
                        let total = store.sprayEquipment.count + store.tractors.count
                        if total > 0 {
                            Text("\(total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Manage chemicals and equipment used in spray calculations.")
            }

            Section {
                NavigationLink {
                    OperatorCategoriesView()
                } label: {
                    HStack {
                        Label("Operator Categories", systemImage: "person.badge.clock")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(store.operatorCategories.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Operator Costs")
            } footer: {
                Text("Define operator cost categories and assign them to vineyard users for trip cost calculations.")
            }

            Section {
                NavigationLink {
                    CalculationSettingsView()
                } label: {
                    HStack {
                        Label("Canopy Water Rates", systemImage: "drop.triangle.fill")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("L/100m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("VSP Canopy Calculation Settings")
                    Button {
                        showUCRInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(VineyardTheme.info)
                    }
                }
            } footer: {
                Text("Configure the indicative water volumes per 100m of row for each canopy size and density.")
            }
        }
        .navigationTitle("Spray Management")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showUCRInfo) {
            UCRInfoSheet()
        }
    }
}
