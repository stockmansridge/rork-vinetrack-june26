import SwiftUI

struct ChemicalsManagementView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var showAddSheet: Bool = false
    @State private var editingChemical: SavedChemical?
    @State private var searchText: String = ""
    @State private var deleteCoordinator = ChemicalDeleteCoordinator()

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    private var filteredChemicals: [SavedChemical] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return store.savedChemicals
        }
        return store.savedChemicals.filter { chem in
            let combined = "\(chem.name) \(chem.activeIngredient) \(chem.chemicalGroup) \(chem.manufacturer) \(chem.problem) \(chem.modeOfAction)"
            return combined.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        List {
            if !canManageSetup && !filteredChemicals.isEmpty {
                Section {
                    Label("Setup data is managed by vineyard owners and managers.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(filteredChemicals) { chemical in
                Group {
                    if canManageSetup {
                        Button {
                            editingChemical = chemical
                        } label: {
                            ChemicalDetailRow(chemical: chemical)
                        }
                    } else {
                        ChemicalDetailRow(chemical: chemical)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if canManageSetup {
                        Button(role: .destructive) {
                            deleteCoordinator.pending = chemical
                        } label: {
                            let inUse = store.isSavedChemicalInUseLocally(chemical.id)
                            Label(inUse ? "Archive" : "Delete", systemImage: inUse ? "archivebox" : "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chemicals")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search chemicals...")
        .toolbar {
            if canManageSetup {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .overlay {
            if store.savedChemicals.isEmpty {
                ContentUnavailableView {
                    Label("No Chemicals", systemImage: "flask")
                } description: {
                    Text("Add chemicals to quickly select them in spray records.")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            EditSavedChemicalSheet(chemical: nil)
        }
        .sheet(item: $editingChemical) { chem in
            EditSavedChemicalSheet(chemical: chem)
        }
        .chemicalDeletionActions(coordinator: deleteCoordinator, store: store)
    }
}

struct ChemicalDetailRow: View {
    let chemical: SavedChemical

    private var ratesPerHa: [ChemicalRate] {
        chemical.rates.filter { $0.basis == .perHectare }
    }

    private var ratesPer100L: [ChemicalRate] {
        chemical.rates.filter { $0.basis == .per100Litres }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(chemical.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                if chemical.category != nil || !chemical.chemicalGroup.isEmpty || !chemical.problem.isEmpty {
                    HStack(spacing: 6) {
                        if let category = chemical.category {
                            Text(category.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    (category.isFertiliser ? VineyardTheme.leafGreen : VineyardTheme.info).opacity(0.12)
                                )
                                .foregroundStyle(category.isFertiliser ? VineyardTheme.leafGreen : VineyardTheme.info)
                                .clipShape(Capsule())
                        }
                        if !chemical.chemicalGroup.isEmpty {
                            Text(chemical.chemicalGroup)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(VineyardTheme.olive.opacity(0.12))
                                .foregroundStyle(VineyardTheme.olive)
                                .clipShape(Capsule())
                        }
                        if !chemical.problem.isEmpty {
                            Text(chemical.problem)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(VineyardTheme.info.opacity(0.12))
                                .foregroundStyle(VineyardTheme.info)
                                .clipShape(Capsule())
                        }
                    }
                }

                if !ratesPerHa.isEmpty {
                    Text(ratesPerHa.map { "\($0.label): \(String(format: "%.0f", chemical.unit.fromBase($0.value)))/ha" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !ratesPer100L.isEmpty {
                    Text(ratesPer100L.map { "\($0.label): \(String(format: "%.0f", chemical.unit.fromBase($0.value)))/100L" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if ratesPerHa.isEmpty && ratesPer100L.isEmpty && chemical.ratePerHa > 0 {
                    Text("\(String(format: "%.2f", chemical.ratePerHa)) \(chemical.unit.rawValue)/Ha")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !chemical.activeIngredient.isEmpty {
                    Text(chemical.activeIngredient)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
