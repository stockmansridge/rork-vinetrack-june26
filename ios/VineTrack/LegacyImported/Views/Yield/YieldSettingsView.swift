import SwiftUI

struct YieldSettingsView: View {
    @Environment(MigratedDataStore.self) private var store

    private var paddocks: [Paddock] {
        store.orderedPaddocks
    }

    var body: some View {
        List {
            Section {
                if paddocks.isEmpty {
                    ContentUnavailableView {
                        Label("No Blocks", systemImage: "map")
                    } description: {
                        Text("Add blocks in Vineyard Setup to set bunch weights.")
                    }
                } else {
                    ForEach(paddocks) { paddock in
                        BunchWeightRow(paddock: paddock)
                    }
                }
            } header: {
                Text("Bunch Weight per Block")
            } footer: {
                Text("Set the average bunch weight (in grams) for each block. These values are used in yield estimation calculations.")
            }
        }
        .navigationTitle("Yield Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BunchWeightRow: View {
    @Environment(MigratedDataStore.self) private var store
    private var fmt: RegionFormatter { store.settings.regionFormatter }
    let paddock: Paddock
    @State private var isEditing: Bool = false
    @State private var weightText: String = ""

    private var currentWeightGrams: Double {
        store.settings.defaultBlockBunchWeightsGrams[paddock.id] ?? 150
    }

    var body: some View {
        Button {
            weightText = String(format: "%.0f", currentWeightGrams)
            isEditing = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(paddock.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        if paddock.areaHectares > 0 {
                            Text(fmt.formatArea(hectares: paddock.areaHectares))
                        }
                        if paddock.effectiveVineCount > 0 {
                            if paddock.areaHectares > 0 {
                                Text("•")
                            }
                            Text("\(paddock.effectiveVineCount) vines")
                        }

                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(String(format: "%.0f g", currentWeightGrams))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VineyardTheme.leafGreen)

                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .alert("Bunch Weight", isPresented: $isEditing) {
            TextField("Weight in grams", text: $weightText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let grams = Double(weightText), grams > 0 else { return }
                var s = store.settings
                s.defaultBlockBunchWeightsGrams[paddock.id] = grams
                store.updateSettings(s)
            }
        } message: {
            Text("Enter the default bunch weight in grams for \(paddock.name).")
        }
    }
}
