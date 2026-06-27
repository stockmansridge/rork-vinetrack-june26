import SwiftUI

struct GrowthStagePickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var pendingStage: GrowthStage?
    let onSelect: (GrowthStage) -> Void

    private var enabledStages: [GrowthStage] {
        let enabledCodes = store.settings.enabledGrowthStageCodes
        return GrowthStage.allStages.filter { enabledCodes.contains($0.code) }
    }

    private var filteredStages: [GrowthStage] {
        guard !searchText.isEmpty else { return enabledStages }
        return enabledStages.filter {
            $0.code.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var showConfirmation: Bool {
        store.settings.elConfirmationEnabled
    }

    var body: some View {
        NavigationStack {
            Group {
                if let stage = pendingStage {
                    ELStageConfirmationView(
                        stage: stage,
                        onConfirm: {
                            onSelect(stage)
                            dismiss()
                        },
                        onBack: {
                            withAnimation {
                                pendingStage = nil
                            }
                        }
                    )
                } else {
                    stageList
                }
            }
            .navigationTitle(pendingStage != nil ? "" : "Select Growth Stage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if pendingStage == nil {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private var stageList: some View {
        List {
            ForEach(filteredStages) { stage in
                Button {
                    if showConfirmation, (stage.imageName != nil || store.hasCustomELStageImage(for: stage.code)) {
                        withAnimation {
                            pendingStage = stage
                        }
                    } else {
                        onSelect(stage)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(stage.code)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 32)
                            .background(Color.green.gradient, in: .rect(cornerRadius: 6))

                        Text(stage.description)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer()

                        if showConfirmation, (stage.imageName != nil || store.hasCustomELStageImage(for: stage.code)) {
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search stages")
    }
}
