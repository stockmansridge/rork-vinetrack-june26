import SwiftUI

/// Detailed picking log — individual picking records grouped by vintage with
/// per Block + Variety actual-yield totals (`SUM(weight_kg) / 1000`).
///
/// When picking records exist for a Block + Variety + Vintage, the totals
/// shown here ARE the actual yield for that combination and supersede any
/// Basic actual entered for the same combination (never added together).
struct PickingLogListView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(PickingRecordSyncService.self) private var pickingRecordSync
    @Environment(\.accessControl) private var accessControl

    @State private var showRecordSheet: Bool = false
    @State private var recordPendingDeletion: PickingRecord?
    @State private var recordToEdit: PickingRecord?

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    /// Commercial sale data (sold to, price, grape value) is owner/manager
    /// only — sql/187 enforces this server-side; lower roles receive masked
    /// NULLs and the UI never renders money for them. `sold` itself stays
    /// visible as operational status.
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    private var records: [PickingRecord] {
        store.pickingRecords.sorted { $0.pickedAt > $1.pickedAt }
    }

    private var vintages: [Int] {
        Set(records.map(\.vintage)).sorted(by: >)
    }

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(
                    "No Picking Records",
                    systemImage: "basket",
                    description: Text("Use Record Actual Yield → Detailed to log individual picks. Actual yield per block, variety and vintage is the sum of its picks.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(vintages, id: \.self) { vintage in
                    vintageSection(vintage)
                }
            }
        }
        .navigationTitle("Picking Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showRecordSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showRecordSheet) {
            RecordActualYieldSheet(initialMode: .detailed)
        }
        .sheet(item: $recordToEdit) { record in
            RecordActualYieldSheet(editing: record)
        }
        .task { await pickingRecordSync.syncForSelectedVineyard() }
        .refreshable { await pickingRecordSync.syncForSelectedVineyard() }
        .confirmationDialog(
            "Delete this picking record?",
            isPresented: Binding(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil } }
            ),
            presenting: recordPendingDeletion
        ) { record in
            Button("Delete Pick", role: .destructive) {
                store.deletePickingRecord(record)
                recordPendingDeletion = nil
                Task { await pickingRecordSync.syncForSelectedVineyard() }
            }
            Button("Cancel", role: .cancel) { recordPendingDeletion = nil }
        } message: { record in
            Text("\(fmt.formatDate(record.pickedAt)) — \(record.paddockName)\(record.varietyName.isEmpty ? "" : " · \(record.varietyName)") — \(Int(record.weightKg)) kg")
        }
    }

    private func vintageSection(_ vintage: Int) -> some View {
        let vintageRecords = records.filter { $0.vintage == vintage }
        let totals = PickingYieldAggregator.totals(for: vintageRecords)

        return Section {
            ForEach(totals) { total in
                totalRow(total, vintageRecords: vintageRecords)
            }
            ForEach(vintageRecords) { record in
                Button {
                    recordToEdit = record
                } label: {
                    recordRow(record)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        recordPendingDeletion = record
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Vintage \(String(vintage))")
        } footer: {
            let tonnes = vintageRecords.reduce(0.0) { $0 + $1.weightKg } / 1000.0
            Text("\(vintageRecords.count) pick\(vintageRecords.count == 1 ? "" : "s") · \(tonnes, format: .number.precision(.fractionLength(2))) t total. These totals are the actual yield for their block, variety and vintage.")
        }
    }

    private func totalRow(_ total: PickingYieldAggregator.Total, vintageRecords: [PickingRecord]) -> some View {
        // Planting-group production breakdown (sql/184): partition this
        // Block + Variety + Vintage bucket's picks per planting group. Only
        // shown once at least one pick is linked — fully-legacy history
        // keeps the compact single-row total. Group rows always reconcile
        // exactly to the variety total (they partition the same picks).
        let bucket = vintageRecords.filter { record in
            record.paddockId == total.paddockId &&
            record.vintage == total.vintage &&
            PickingYieldAggregator.normalisedVariety(record.varietyName)
                == PickingYieldAggregator.normalisedVariety(total.varietyName)
        }
        let groups = PickingYieldAggregator.plantingGroupTotals(for: bucket)
        let showGroups = groups.contains { $0.groupKey != nil }
        let groupConfig: [String: (hectares: Double, sections: Int)] =
            showGroups ? plantingGroupConfig(paddockId: total.paddockId) : [:]

        return VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(total.varietyName.isEmpty ? total.paddockName : "\(total.paddockName) · \(total.varietyName)")
                        .font(.subheadline.weight(.semibold))
                    Text("\(total.pickCount) pick\(total.pickCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(total.actualYieldTonnes, format: .number.precision(.fractionLength(2))) t")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(VineyardTheme.leafGreen)
                    if canViewFinancials, let value = total.totalGrapeValue {
                        Text(fmt.formatCurrency(value))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if showGroups {
                VStack(spacing: 6) {
                    ForEach(groups) { group in
                        plantingGroupRow(group, config: group.groupKey.flatMap { groupConfig[$0] })
                    }
                }
                .padding(.leading, 12)
            }
        }
        .padding(.vertical, 2)
    }

    /// One planting-group sub-row: `clone · rootstock`, current group
    /// hectares + section count from the block's live configuration, group
    /// tonnes and t/ha. The unlinked bucket is labelled explicitly.
    private func plantingGroupRow(
        _ group: PickingYieldAggregator.PlantingGroupTotal,
        config: (hectares: Double, sections: Int)?
    ) -> some View {
        let label: String
        if group.groupKey == nil {
            label = "Not linked to a planting"
        } else {
            let parts = [group.clone, group.rootstock].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            label = parts.isEmpty ? "No clone / rootstock" : parts.joined(separator: " · ")
        }
        let hectares = config?.hectares ?? 0

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(group.groupKey == nil ? .regular : .medium))
                    .foregroundStyle(group.groupKey == nil ? .secondary : .primary)
                if let config, hectares > 0 {
                    Text("\(fmt.formatArea(hectares: hectares))\(config.sections > 1 ? " · \(config.sections) sections" : "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(group.actualYieldTonnes, format: .number.precision(.fractionLength(2))) t")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(group.groupKey == nil ? .secondary : VineyardTheme.leafGreen)
                if hectares > 0 {
                    Text(fmt.formatYieldPerArea(perHectare: group.actualYieldTonnes / hectares))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Live block configuration per planting group: summed member hectares
    /// (allocation percent × block area) and section count, keyed by the
    /// canonical group key. Groups no longer present on the block simply
    /// show without hectares (their snapshots remain on the records).
    private func plantingGroupConfig(paddockId: UUID) -> [String: (hectares: Double, sections: Int)] {
        guard let paddock = store.paddocks.first(where: { $0.id == paddockId }) else { return [:] }
        var result: [String: (hectares: Double, sections: Int)] = [:]
        for allocation in paddock.varietyAllocations {
            let resolved = PaddockVarietyResolver.resolve(allocation: allocation, varieties: store.grapeVarieties)
            guard let name = resolved.displayName, !name.isEmpty else { continue }
            let key = PlantingGroup.key(varietyName: name, clone: allocation.clone, rootstock: allocation.rootstock)
            let hectares = allocation.percent > 0 ? paddock.areaHectares * allocation.percent / 100.0 : 0
            var entry = result[key] ?? (0, 0)
            entry.hectares += hectares
            entry.sections += 1
            result[key] = entry
        }
        return result
    }

    private func recordRow(_ record: PickingRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(fmt.formatDate(record.pickedAt))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(record.weightKg, format: .number.precision(.fractionLength(0))) kg")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            HStack(spacing: 6) {
                Text(record.paddockName)
                if !record.varietyName.isEmpty {
                    Text("· \(record.varietyName)")
                }
                if let clone = record.clone, !clone.isEmpty {
                    Text("· \(clone)")
                }
                if let rootstock = record.rootstock, !rootstock.isEmpty {
                    Text("· \(rootstock)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let sugar = record.sugarValue, let unit = record.sugarMeasurement {
                    metricBadge("\(String(format: "%.1f", sugar)) \(unit.symbol)")
                }
                if let ph = record.ph {
                    metricBadge("pH \(String(format: "%.2f", ph))")
                }
                if let ta = record.taGPerL {
                    metricBadge("TA \(String(format: "%.1f", ta))")
                }
                if record.sold {
                    soldBadge(record)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func metricBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: .capsule)
    }

    private func soldBadge(_ record: PickingRecord) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.caption2)
            if canViewFinancials, let value = record.grapeValue {
                Text(fmt.formatCurrency(value))
            } else {
                Text("Sold")
            }
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(VineyardTheme.leafGreen, in: .capsule)
    }
}
