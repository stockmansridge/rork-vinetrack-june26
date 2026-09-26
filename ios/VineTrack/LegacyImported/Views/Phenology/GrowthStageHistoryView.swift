import SwiftUI

struct GrowthStageHistoryView: View {
    @Environment(MigratedDataStore.self) private var store
    let blockName: String
    let records: [GrowthStageRecord]
    let formatter: RegionFormatter

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView("No observations yet", systemImage: "leaf", description: Text("Capture a growth stage to start the seasonal history."))
            } else {
                ForEach(records.sorted { $0.observedAt < $1.observedAt }) { record in
                    let code = "EL\(record.stageCode.filter(\.isNumber))"
                    let stage = GrowthStage.allStages.first { $0.code == code }
                    HStack(alignment: .top, spacing: 14) {
                        Color(.tertiarySystemGroupedBackground)
                            .frame(width: 58, height: 58)
                            .overlay {
                                if let stage, let image = store.resolvedELStageImage(for: stage) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .allowsHitTesting(false)
                                } else {
                                    Image(systemName: "leaf.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .clipShape(.rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ELRipeness.formatEl(Double(record.stageCode.filter(\.isNumber))))
                                .font(.headline)
                            if let stage { Text(stage.description).font(.subheadline) }
                            Text(formatter.formatDate(record.observedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let notes = record.notes, !notes.isEmpty {
                                Text(notes).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("\(blockName) · All Stages")
        .navigationBarTitleDisplayMode(.inline)
    }
}
