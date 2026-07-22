import SwiftUI
import MapKit

struct DamageRecordsListView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(DamageRecordSyncService.self) private var damageRecordSync
    @Environment(\.accessControl) private var accessControl

    @State private var showReportSheet: Bool = false
    @State private var pendingPaddock: Paddock?

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var canDelete: Bool { accessControl?.canDelete ?? false }
    private var canCreate: Bool { true }

    private var paddocks: [Paddock] {
        store.orderedPaddocks.filter { $0.polygonPoints.count >= 3 }
    }

    private var allDamageRecords: [DamageRecord] {
        store.damageRecords.sorted { $0.date > $1.date }
    }

    private let blockColors: [Color] = [
        .blue, .green, .orange, .purple, .red, .cyan, .mint, .indigo, .pink, .teal, .yellow, .brown
    ]

    private func colorFor(_ paddock: Paddock) -> Color {
        guard let idx = paddocks.firstIndex(where: { $0.id == paddock.id }) else { return .blue }
        return blockColors[idx % blockColors.count]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                overviewSection

                if !affectedPaddocks.isEmpty {
                    yieldImpactSection
                }

                damageReportsSection
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Damage Reports")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showReportSheet = true
                } label: {
                    Label("Report Damage", systemImage: "plus.circle.fill")
                }
                .disabled(paddocks.isEmpty)
            }
        }
        .sheet(isPresented: $showReportSheet) {
            reportDamagePicker
        }
        .navigationDestination(item: $pendingPaddock) { paddock in
            RecordDamageView(paddock: paddock)
        }
        .task {
            await damageRecordSync.syncForSelectedVineyard()
        }
        .refreshable {
            await damageRecordSync.syncForSelectedVineyard()
        }
    }

    // MARK: - Damage Overview

    private var totalAffectedHa: Double {
        allDamageRecords.reduce(0) { $0 + $1.areaHectares }
    }

    private var effectiveLossHa: Double {
        allDamageRecords.reduce(0) { acc, record in
            acc + record.areaHectares * (max(0, min(100, record.damagePercent)) / 100.0)
        }
    }

    private var overallImpactPercent: Double {
        let total = paddocks.reduce(0.0) { $0 + $1.areaHectares }
        guard total > 0 else { return 0 }
        return min(100, (effectiveLossHa / total) * 100)
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Damage Overview", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                overviewCard(
                    title: "Records",
                    value: "\(allDamageRecords.count)",
                    icon: "list.bullet.clipboard",
                    color: .orange
                )
                overviewCard(
                    title: "Blocks Affected",
                    value: "\(Set(allDamageRecords.map(\.paddockId)).count)",
                    icon: "map.fill",
                    color: .red
                )
                overviewCard(
                    title: "Effective Loss",
                    value: fmt.formatArea(hectares: effectiveLossHa),
                    icon: "leaf.fill",
                    color: .brown
                )
                overviewCard(
                    title: "Yield Impact",
                    value: String(format: "%.1f%%", overallImpactPercent),
                    icon: "chart.line.downtrend.xyaxis",
                    color: .pink
                )
            }
        }
    }

    private func overviewCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Yield Impact (per-block viability)

    private var affectedPaddocks: [Paddock] {
        paddocks.filter { !store.damageRecords(for: $0.id).isEmpty }
    }

    private var yieldImpactSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Yield Impact", systemImage: "chart.bar.xaxis")
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(affectedPaddocks) { paddock in
                    let records = store.damageRecords(for: paddock.id)
                    let factor = store.damageFactor(for: paddock.id)
                    let color = colorFor(paddock)

                    HStack(spacing: 12) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(paddock.name)
                                .font(.subheadline.weight(.semibold))
                            Text("\(records.count) record\(records.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(String(format: "%.0f%% viable", factor * 100))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(factor >= 0.8 ? .green : factor >= 0.5 ? .orange : .red)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: - Damage Reports list

    private var damageReportsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Damage Reports", systemImage: "list.bullet.clipboard")
                    .font(.headline)
                Spacer()
                if !allDamageRecords.isEmpty {
                    Text("\(allDamageRecords.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemFill), in: .capsule)
                }
            }

            if allDamageRecords.isEmpty {
                emptyState
            } else {
                ForEach(allDamageRecords) { record in
                    SwipeToDeleteCard(
                        actionLabel: "Delete",
                        isEnabled: canDelete
                    ) {
                        store.deleteDamageRecord(record)
                        Task { await damageRecordSync.syncForSelectedVineyard() }
                    } content: {
                        damageRecordCard(record)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Damage Recorded")
                .font(.subheadline.weight(.semibold))
            Text("Tap Report Damage to log frost, hail, wind, or other damage events.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func damageRecordCard(_ record: DamageRecord) -> some View {
        let paddock = paddocks.first { $0.id == record.paddockId }
        let paddockName = paddock?.name ?? "Unknown Block"
        let color = paddock.map { colorFor($0) } ?? .gray

        return NavigationLink {
            if let paddock {
                RecordDamageView(paddock: paddock, editingRecord: record)
            }
        } label: {
            damageRecordCardContent(record, paddockName: paddockName, color: color)
        }
        .buttonStyle(.plain)
    }

    private func damageRecordCardContent(_ record: DamageRecord, paddockName: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: record.damageType.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(record.damageType.rawValue)
                        .font(.subheadline.weight(.semibold))
                }

                Spacer()

                RecordSyncBadge(
                    state: RecordSyncState.forDamageRecord(record.id, damageSync: damageRecordSync),
                    showsLabel: false
                )

                Text(String(format: "%.0f%%", record.damagePercent))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.red)
            }

            Divider()

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                    Text(paddockName)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(fmt.formatDate(record.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(fmt.formatArea(hectares: record.areaHectares, fractionDigits: 4))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }

            if !record.notes.isEmpty {
                Text(record.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(10)
        }
    }

    // MARK: - Report Damage Sheet (paddock picker)

    private var reportDamagePicker: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select the block where damage occurred.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    if paddocks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "map")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No blocks with boundaries found")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(paddocks) { paddock in
                                paddockPickerButton(paddock)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Report Damage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showReportSheet = false }
                }
            }
        }
    }

    private func paddockPickerButton(_ paddock: Paddock) -> some View {
        let color = colorFor(paddock)
        let existingCount = store.damageRecords(for: paddock.id).count

        return Button {
            showReportSheet = false
            // Defer to allow sheet dismissal to complete before pushing.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                pendingPaddock = paddock
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: 1) {
                    Text(paddock.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if existingCount > 0 {
                        Text("\(existingCount) existing")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Text(fmt.formatArea(hectares: paddock.areaHectares))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
