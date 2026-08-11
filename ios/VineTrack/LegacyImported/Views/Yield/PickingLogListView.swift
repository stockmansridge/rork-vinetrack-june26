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

    @State private var showRecordSheet: Bool = false
    @State private var recordPendingDeletion: PickingRecord?
    @State private var recordToEdit: PickingRecord?

    private var fmt: RegionFormatter { store.settings.regionFormatter }

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
                totalRow(total)
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

    private func totalRow(_ total: PickingYieldAggregator.Total) -> some View {
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
                if let value = total.totalGrapeValue {
                    Text(fmt.formatCurrency(value))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
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
            if let value = record.grapeValue {
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
