import SwiftUI

struct YieldReportView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(YieldEstimationSessionSyncService.self) private var yieldSessionSync
    let viewModel: YieldEstimationViewModel

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var paddocks: [Paddock] {
        store.orderedPaddocks.filter { $0.polygonPoints.count >= 3 }
    }

    private var estimates: [BlockYieldEstimate] {
        viewModel.calculateYieldEstimates(paddocks: paddocks, damageFactorProvider: { store.damageFactor(for: $0) })
    }

    private var totalYieldTonnes: Double {
        estimates.reduce(0) { $0 + $1.estimatedYieldTonnes }
    }

    private var totalYieldKg: Double {
        estimates.reduce(0) { $0 + $1.estimatedYieldKg }
    }

    private var totalArea: Double {
        estimates.reduce(0) { $0 + $1.areaHectares }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                overviewCards
                bunchWeightSection
                blockEstimatesSection
                formulaSection
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle("Yield Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let sessionId = viewModel.sessionId {
                ToolbarItem(placement: .topBarTrailing) {
                    RecordSyncBadge(
                        state: .forYieldSession(sessionId, yieldSync: yieldSessionSync)
                    )
                }
            }
        }
    }

    // MARK: - Overview

    private var overviewCards: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                reportCard(
                    title: "Est. Yield",
                    value: String(format: "%.2f t", totalYieldTonnes),
                    icon: "scalemass.fill",
                    color: VineyardTheme.leafGreen
                )
                reportCard(
                    title: "Yield/\(fmt.areaUnitAbbreviation)",
                    value: totalArea > 0 ? fmt.formatYieldPerArea(perHectare: totalYieldTonnes / totalArea) : "—",
                    icon: "square.dashed",
                    color: .orange
                )
            }

            HStack(spacing: 12) {
                reportCard(
                    title: "Samples",
                    value: "\(viewModel.recordedSiteCount)/\(viewModel.totalSiteCount)",
                    icon: "mappin.and.ellipse",
                    color: .purple
                )
                reportCard(
                    title: "Blocks",
                    value: "\(estimates.count)",
                    icon: "map.fill",
                    color: .teal
                )
            }
        }
    }

    private func reportCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Bunch Weight

    private var bunchWeightSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Bunch Weight per Block", systemImage: "scalemass")
                .font(.headline)

            ForEach(estimates, id: \.paddockId) { est in
                HStack {
                    Text(est.paddockName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(format: "%.0f g", est.averageBunchWeightKg * 1000))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            }
        }
    }

    // MARK: - Block Estimates

    private var blockEstimatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Block Estimates", systemImage: "chart.bar.doc.horizontal")
                .font(.headline)

            ForEach(estimates, id: \.paddockId) { est in
                blockEstimateCard(est)
            }
        }
    }

    private func blockEstimateCard(_ est: BlockYieldEstimate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(est.paddockName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f t", est.estimatedYieldTonnes))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(VineyardTheme.leafGreen)
            }

            Divider()

            VStack(spacing: 6) {
                estimateRow("Area", value: fmt.formatArea(hectares: est.areaHectares))
                estimateRow("Total Vines", value: "\(est.totalVines)")
                estimateRow("Avg Bunches/Vine", value: String(format: "%.2f", est.averageBunchesPerVine))
                estimateRow("Total Bunches", value: String(format: "%.0f", est.totalBunches))
                estimateRow("Avg Bunch Weight", value: String(format: "%.0f g", est.averageBunchWeightKg * 1000))
                estimateRow("Damage Factor", value: String(format: "%.2f (%.0f%% viable)", est.damageFactor, est.damageFactor * 100))
                estimateRow("Samples", value: "\(est.samplesRecorded)/\(est.samplesTotal)")
            }

            if est.areaHectares > 0 {
                HStack {
                    Text("Yield per \(fmt.areaUnitAbbreviation)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.formatYieldPerArea(perHectare: est.estimatedYieldTonnes / est.areaHectares))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func estimateRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
        }
    }

    // MARK: - Formula

    private var formulaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Calculation Formula", systemImage: "function")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Estimated Yield =")
                    .font(.subheadline.weight(.medium))
                Text("Vines per Block × Avg Bunches per Vine × Avg Bunch Weight × Damage Factor")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    formulaNote("Bunches per vine is averaged from all recorded samples (to 2 decimal places)")
                    formulaNote("Bunch weight can be manually entered or loaded from previous season records")
                    formulaNote("Damage factor reflects cumulative damage recorded for each block (1.0 = no damage)")
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
    }

    private func formulaNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
