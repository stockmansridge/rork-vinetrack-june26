import SwiftUI

struct OperationsSetupHubView: View {
    @Environment(DataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    private var canChange: Bool { accessControl?.canChangeSettings ?? false }
    private var isManager: Bool { accessControl?.isManager ?? false }

    var body: some View {
        Form {
            vineyardSetupSection
            sprayAndEquipmentSection
            operatorsSection
            if !canChange && !isManager {
                restrictedSection
            }
        }
        .navigationTitle("Operations Setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var vineyardSetupSection: some View {
        Section {
            NavigationLink {
                VineyardSetupSettingsView()
            } label: {
                hubRow(
                    title: "Blocks, Buttons & Growth Stages",
                    subtitle: "Paddocks, pin buttons, E-L stages, map & weather",
                    symbol: "square.grid.2x2.fill",
                    color: VineyardTheme.leafGreen
                )
            }
        } header: {
            Text("Vineyard Setup")
        } footer: {
            Text("Define blocks, rows, pin buttons and growth stage tracking.")
        }
    }

    private var sprayAndEquipmentSection: some View {
        Section {
            NavigationLink {
                SprayManagementSettingsView()
            } label: {
                hubRow(
                    title: "Spray Management",
                    subtitle: "Presets, chemicals & canopy rates",
                    symbol: "sprinkler.and.droplets.fill",
                    color: .teal
                )
            }

            NavigationLink {
                EquipmentManagementView()
            } label: {
                hubRow(
                    title: "Equipment & Tractors",
                    subtitle: "\(store.sprayEquipment.count + store.tractors.count) items",
                    symbol: "wrench.and.screwdriver.fill",
                    color: .orange
                )
            }

            NavigationLink {
                ChemicalsManagementView()
            } label: {
                hubRow(
                    title: "Chemicals",
                    subtitle: "\(store.savedChemicals.count) saved",
                    symbol: "flask.fill",
                    color: .purple
                )
            }
        } header: {
            Text("Spray & Equipment")
        } footer: {
            Text("Configure chemicals, equipment and spray calculation settings.")
        }
    }

    private var operatorsSection: some View {
        Section {
            NavigationLink {
                OperatorCategoriesView()
            } label: {
                hubRow(
                    title: "Operator Categories",
                    subtitle: "\(store.operatorCategories.count) categories",
                    symbol: "person.badge.clock.fill",
                    color: .blue
                )
            }
        } header: {
            Text("Team Operations")
        } footer: {
            Text("Define operator cost categories used in trip and work records.")
        }
    }

    private var restrictedSection: some View {
        Section {
            Text("Only Managers can change operational setup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hubRow(title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.gradient)
                    .frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
