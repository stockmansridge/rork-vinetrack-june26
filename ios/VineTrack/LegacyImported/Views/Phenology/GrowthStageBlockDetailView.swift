import SwiftUI

struct GrowthStageBlockDetailView: View {
    @Environment(MigratedDataStore.self) private var store
    let blockName: String
    let currentEl: Double?
    let records: [GrowthStageRecord]
    let formatter: RegionFormatter

    @State private var isCapturing: Bool = false

    private var currentRecord: GrowthStageRecord? {
        guard let currentEl else { return nil }
        return records.filter { Double($0.stageCode.filter(\.isNumber)) == currentEl }
            .max(by: { $0.observedAt < $1.observedAt })
    }

    private var currentStage: GrowthStage? {
        guard let currentEl else { return nil }
        return GrowthStage.allStages.first { Double($0.code.filter(\.isNumber)) == currentEl }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(blockName)
                    .font(.title2.weight(.bold))
                progression
                VStack(alignment: .leading, spacing: 14) {
                    Text("Current Growth Stage").font(.headline)
                    if let currentEl {
                        HStack(alignment: .top, spacing: 14) {
                            if let stage = currentStage, let image = store.resolvedELStageImage(for: stage) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 108, height: 118)
                                    .clipShape(.rect(cornerRadius: 12))
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(ELRipeness.formatEl(currentEl))
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(Color(uiColor: ELRipenessPinFactory.uiColour(for: currentEl)))
                                if let stage = currentStage { Text(stage.description).font(.subheadline) }
                                if let date = currentRecord?.observedAt {
                                    Label("Recorded \(formatter.formatDate(date))", systemImage: "calendar")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let notes = currentRecord?.notes, !notes.isEmpty {
                                    Text(notes).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("No current stage", systemImage: "leaf", description: Text("No eligible recent observation for this block and vintage."))
                    }
                    Button { isCapturing = true } label: {
                        Label("Update Stage", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.06, green: 0.31, blue: 0.20))
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Seasonal Development").font(.headline)
                    if records.isEmpty {
                        Text("No observations recorded for this block this vintage.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(records.sorted(by: { $0.observedAt < $1.observedAt })) { record in
                        HStack(spacing: 12) {
                            if let stage = GrowthStage.allStages.first(where: { $0.code == "EL\(record.stageCode.filter(\.isNumber))" }),
                               let image = store.resolvedELStageImage(for: stage) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(.rect(cornerRadius: 9))
                            } else {
                                Image(systemName: "leaf")
                                    .frame(width: 48, height: 48)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading) {
                                Text(record.stageCode).font(.subheadline.weight(.semibold))
                                Text(formatter.formatDate(record.observedAt))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Growth Stage")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isCapturing) {
            UnifiedPinComposerView(onSaved: { isCapturing = false })
        }
    }

    private var progression: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(["EL4", "EL12", "EL23", "EL27", "EL35"], id: \.self) { code in
                    if let stage = GrowthStage.allStages.first(where: { $0.code == code }) {
                        VStack(spacing: 5) {
                            if let image = store.resolvedELStageImage(for: stage) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(.rect(cornerRadius: 10))
                            }
                            Text(code.replacingOccurrences(of: "EL", with: "E-L "))
                                .font(.caption2.weight(.semibold))
                            Text(stage.description.components(separatedBy: ";").first ?? stage.description)
                                .font(.caption2).lineLimit(1)
                                .frame(width: 75)
                        }
                        .opacity((currentEl ?? 0) < (Double(code.dropFirst(2)) ?? 0) ? 0.6 : 1)
                    }
                }
            }
        }
        .contentMargins(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}
