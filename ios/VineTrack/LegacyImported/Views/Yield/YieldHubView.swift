import SwiftUI

struct YieldHubView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(DamageRecordSyncService.self) private var damageRecordSync
    @Environment(YieldEstimationSessionSyncService.self) private var yieldSessionSync
    @Environment(HistoricalYieldRecordSyncService.self) private var historicalYieldSync
    @State private var showRecordActualSheet: Bool = false

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard

                VStack(spacing: 12) {
                    NavigationLink {
                        YieldDeterminationCalculatorView()
                    } label: {
                        hubOption(
                            icon: "scalemass.fill",
                            iconGradient: [.purple, .pink],
                            title: "Pruning Yield Calculator",
                            subtitle: "Pruning bud-load potential",
                            detail: determinationDetail
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        DamageRecordsListView()
                    } label: {
                        hubOption(
                            icon: "exclamationmark.triangle.fill",
                            iconGradient: [.red, .orange],
                            title: "Record Damage",
                            subtitle: "Adjust yield estimates for seasonal damage.",
                            detail: damageDetail
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        YieldEstimationView()
                    } label: {
                        hubOption(
                            icon: "chart.bar.doc.horizontal",
                            iconGradient: [.orange, .red],
                            title: "Yield Estimation",
                            subtitle: "Sample sites & bunch counts",
                            detail: yieldEstimationDetail
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        showRecordActualSheet = true
                    } label: {
                        hubOption(
                            icon: "square.and.pencil",
                            iconGradient: [.green, VineyardTheme.leafGreen],
                            title: "Record Actual Yield",
                            subtitle: "Add harvested tonnes by block & season",
                            detail: nil
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        YieldReportsListView()
                    } label: {
                        hubOption(
                            icon: "list.clipboard.fill",
                            iconGradient: [.indigo, .blue],
                            title: "Yield Reports",
                            subtitle: "Compare estimates and harvest results",
                            detail: yieldReportsDetail
                        )
                    }
                    .buttonStyle(.plain)

                }

                Label("Actual yield records are used by Cost Reports to calculate cost per tonne.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Yields")
        .sheet(isPresented: $showRecordActualSheet) {
            RecordActualYieldSheet()
        }
        .navigationBarTitleDisplayMode(.large)
        .task {
            await damageRecordSync.syncForSelectedVineyard()
            await yieldSessionSync.syncForSelectedVineyard()
            await historicalYieldSync.syncForSelectedVineyard()
        }
        .refreshable {
            await damageRecordSync.syncForSelectedVineyard()
            await yieldSessionSync.syncForSelectedVineyard()
            await historicalYieldSync.syncForSelectedVineyard()
        }
    }

    private var headerCard: some View {
        HStack(spacing: 0) {
            yieldStat(
                value: "\(store.yieldSessions.count)",
                label: "Sessions",
                icon: "chart.bar.fill",
                color: .purple
            )
            yieldStat(
                value: "\(estimatedBlockCount)",
                label: "Blocks Est.",
                icon: "square.grid.2x2",
                color: .indigo
            )
            yieldStat(
                value: "\(store.damageRecords.count)",
                label: "Damage",
                icon: "exclamationmark.triangle",
                color: .red
            )
        }
        .padding(.vertical, 16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func yieldStat(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func hubOption(
        icon: String,
        iconGradient: [Color],
        title: String,
        subtitle: String,
        detail: String?
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(colors: iconGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var estimatedBlockCount: Int {
        Set(store.yieldSessions.flatMap(\.selectedPaddockIds)).count
    }

    private var yieldEstimationDetail: String? {
        let count = store.yieldSessions.count
        guard count > 0 else { return nil }
        return "\(count) session\(count == 1 ? "" : "s") recorded"
    }

    private var yieldReportsDetail: String? {
        let blocks = estimatedBlockCount
        guard blocks > 0 else { return nil }
        return "\(blocks) block\(blocks == 1 ? "" : "s") estimated"
    }

    private var damageDetail: String? {
        let count = store.damageRecords.count
        guard count > 0 else { return nil }
        return "\(count) damage record\(count == 1 ? "" : "s")"
    }

    private var determinationDetail: String? {
        guard let latest = store.latestDeterminationOverall else { return nil }
        return "Latest: \(fmt.formatYieldPerArea(perHectare: latest.yieldTonnesPerHa, fractionDigits: 1))"
    }
}
