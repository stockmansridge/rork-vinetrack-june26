import SwiftUI

/// Read-only debug/validation view for the new `growth_stage_records` sync
/// store. Lets us verify that mirrored rows from growth-stage pins are being
/// created, synced and displayed correctly before we migrate the existing
/// Growth Stage Report flow off pins.
struct GrowthStageRecordsListView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(GrowthStageRecordSyncService.self) private var growthStageRecordSync
    @Environment(BackendAccessControl.self) private var accessControl

    @State private var searchText: String = ""
    @State private var showPDFExport: Bool = false

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var vineyardRecords: [GrowthStageRecord] {
        guard let vineyardId = store.selectedVineyardId else { return [] }
        let mirrored = growthStageRecordSync.records.filter { $0.vineyardId == vineyardId }
        // Fallback: synthesize ephemeral records for any growth-stage pins
        // that haven't been mirrored yet (e.g. legacy pins created before
        // the sync service existed). This guarantees the new list is never
        // empty when the old Growth Stage Report can see records.
        let mirroredPinIds = Set(mirrored.compactMap { $0.pinId })
        let legacy: [GrowthStageRecord] = store.pins.compactMap { pin in
            guard pin.vineyardId == vineyardId,
                  pin.mode == .growth,
                  let code = pin.growthStageCode, !code.isEmpty,
                  !mirroredPinIds.contains(pin.id) else { return nil }
            let label = GrowthStage.allStages.first { $0.code == code }?.description
            let variety = paddockVariety(for: pin.paddockId)
            return GrowthStageRecord(
                id: pin.id, // ephemeral, stable per pin
                vineyardId: pin.vineyardId,
                paddockId: pin.paddockId,
                pinId: pin.id,
                stageCode: code,
                stageLabel: label,
                variety: variety,
                observedAt: pin.timestamp,
                latitude: pin.latitude,
                longitude: pin.longitude,
                rowNumber: pin.rowNumber,
                side: nil, // intentionally hidden for growth-stage display
                notes: pin.notes,
                photoPaths: pin.photoPath.map { [$0] } ?? [],
                recordedByName: pin.createdBy,
                createdAt: pin.timestamp,
                updatedAt: pin.timestamp
            )
        }
        return (mirrored + legacy).sorted { $0.observedAt > $1.observedAt }
    }

    private var filteredRecords: [GrowthStageRecord] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return vineyardRecords }
        return vineyardRecords.filter { record in
            let haystack = [
                record.stageCode,
                record.stageLabel ?? "",
                record.variety ?? "",
                paddockName(for: record.paddockId) ?? "",
                record.notes ?? "",
                record.recordedByName ?? ""
            ].joined(separator: " ").lowercased()
            return haystack.contains(trimmed)
        }
    }

    private var mirroredFromPinsCount: Int {
        vineyardRecords.filter { $0.pinId != nil }.count
    }

    private var withPhotosCount: Int {
        vineyardRecords.filter { !$0.photoPaths.isEmpty }.count
    }

    var body: some View {
        List {
            Section {
                summaryCard
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            if filteredRecords.isEmpty {
                Section {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(filteredRecords) { record in
                        recordRow(record)
                    }
                } header: {
                    Text("Records (\(filteredRecords.count))")
                } footer: {
                    Text("Read-only. Mirrored from growth-stage pins via pin_id where applicable.")
                        .font(.caption2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Growth Stage Records")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search variety, block, stage, notes")
        .task { await growthStageRecordSync.syncForSelectedVineyard() }
        .refreshable { await growthStageRecordSync.syncForSelectedVineyard() }
        .toolbar {
            if accessControl.canExport {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPDFExport = true
                    } label: {
                        Label("Export PDF", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showPDFExport) {
            NavigationStack {
                GrowthStageReportView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showPDFExport = false }
                        }
                    }
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        HStack(spacing: 0) {
            summaryStat(
                value: "\(vineyardRecords.count)",
                label: "Total",
                icon: "leaf.fill",
                color: .green
            )
            summaryStat(
                value: "\(mirroredFromPinsCount)",
                label: "From Pins",
                icon: "mappin.and.ellipse",
                color: .orange
            )
            summaryStat(
                value: "\(withPhotosCount)",
                label: "With Photos",
                icon: "photo.fill",
                color: .blue
            )
        }
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func summaryStat(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Row

    private func recordRow(_ record: GrowthStageRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.stageCode)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.gradient, in: .capsule)
                if let label = record.stageLabel, !label.isEmpty {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
                Text(fmt.formatDate(record.observedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(paddockName(for: record.paddockId) ?? "—")
                    .font(.caption)
                    .foregroundStyle(.primary)
                if let variety = record.variety, !variety.isEmpty {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "leaf")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(variety)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }

            if let notes = record.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                if let name = record.recordedByName, !name.isEmpty {
                    Label(name, systemImage: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !record.photoPaths.isEmpty {
                    Label("\(record.photoPaths.count)", systemImage: "photo.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                if record.pinId != nil {
                    Label("from pin", systemImage: "mappin.and.ellipse")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: .capsule)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "leaf.circle")
                .font(.system(size: 44))
                .foregroundStyle(.green.opacity(0.6))
            Text(searchText.isEmpty ? "No growth stage records yet" : "No matches")
                .font(.headline)
            Text(searchText.isEmpty
                 ? "Add a growth-stage pin in the field — it will mirror here once synced."
                 : "Try a different search term.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Helpers

    private func paddockName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return store.paddocks.first(where: { $0.id == id })?.name
    }

    private func paddockVariety(for id: UUID?) -> String? {
        guard let id, let paddock = store.paddocks.first(where: { $0.id == id }) else { return nil }
        for child in Mirror(reflecting: paddock).children {
            guard let label = child.label?.lowercased() else { continue }
            if label == "variety" || label == "grapevariety" || label == "grape" {
                if let s = child.value as? String, !s.isEmpty { return s }
            }
        }
        return nil
    }
}
