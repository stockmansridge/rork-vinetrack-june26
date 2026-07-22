import SwiftUI

struct GrowthStageConfigSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var enabledCodes: Set<String> = []
    @State private var searchText: String = ""

    private var filteredStages: [GrowthStage] {
        guard !searchText.isEmpty else { return GrowthStage.allStages }
        return GrowthStage.allStages.filter {
            $0.code.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button("Select All") {
                            enabledCodes = Set(GrowthStage.allStages.map { $0.code })
                        }
                        .font(.subheadline.weight(.medium))

                        Spacer()

                        Button("Deselect All") {
                            enabledCodes.removeAll()
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                    }
                }

                Section {
                    ForEach(filteredStages) { stage in
                        Button {
                            if enabledCodes.contains(stage.code) {
                                enabledCodes.remove(stage.code)
                            } else {
                                enabledCodes.insert(stage.code)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: enabledCodes.contains(stage.code) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(enabledCodes.contains(stage.code) ? .green : .secondary)
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stage.code)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.primary)
                                    Text(stage.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .contentShape(.rect)
                        }
                    }
                } header: {
                    Text("\(enabledCodes.count) of \(GrowthStage.allStages.count) enabled")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search stages")
            .navigationTitle("E-L Growth Stages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var s = store.settings
                        s.enabledGrowthStageCodes = GrowthStage.allStages
                            .filter { enabledCodes.contains($0.code) }
                            .map { $0.code }
                        store.updateSettings(s)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                enabledCodes = Set(store.settings.enabledGrowthStageCodes)
            }
        }
    }
}
