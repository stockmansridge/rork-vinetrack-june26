import SwiftUI

struct YieldReportView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(YieldEstimationSessionSyncService.self) private var yieldSessionSync
    let viewModel: YieldEstimationViewModel

    private var observation: YieldEstimationSession {
        YieldEstimationSession(id: viewModel.sessionId ?? store.selectedVineyardId ?? UUID(),
            vineyardId: store.selectedVineyardId ?? UUID(), createdAt: viewModel.sessionCreatedAt ?? Date(),
            selectedPaddockIds: Array(viewModel.selectedPaddockIds), sampleSites: viewModel.sampleSites,
            blockBunchWeightsKg: viewModel.blockBunchWeightsKg, isCompleted: viewModel.isCompleted,
            completedAt: viewModel.completedAt, applyDamage: viewModel.applyDamage)
    }
    var body: some View {
        let vintage = YieldVintageReport.sessionVintage(observation,
            seasonStartMonth: store.settings.seasonStartMonth, seasonStartDay: store.settings.seasonStartDay)
        let estimate = CurrentYieldEstimate.trip(session: observation, paddocks: store.paddocks,
            weights: YieldMasterWeightCache.shared.weights(vineyardId: store.selectedVineyardId),
            remaining: { store.remainingYieldMultiplier(for: $0, vintage: vintage) })
        let currentVintage = VintageResolver.vintageYear(for: Date(),
            seasonStartMonth: store.settings.seasonStartMonth, seasonStartDay: store.settings.seasonStartDay)
        let isCurrent = observation.isCompleted && observation.selectedPaddockIds.contains { blockId in
            YieldVintageReport.latestCompletedSessionForBlock(
                sessions: store.yieldSessions.filter { $0.vineyardId == store.selectedVineyardId },
                paddockId: blockId, vintage: currentVintage, seasonStartMonth: store.settings.seasonStartMonth,
                seasonStartDay: store.settings.seasonStartDay)?.id == observation.id
        }
        ScrollView {
            Text(observation.isCompleted ? "Completed" : "Draft")
                .font(.subheadline.weight(.semibold)).padding(.top)
            CurrentYieldEstimateSummary(estimate: estimate, current: isCurrent)
                .padding()
            Text("Average recorded bunches/vine × current authoritative vines × resolved kg/bunch ÷ 1,000. Per ha uses only blocks with recorded samples. Historical weights remain evidence, not current authority.")
                .font(.caption).foregroundStyle(.secondary).padding()
        }
        .navigationTitle("Yield Report")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(YieldMasterRefresh())
        .toolbar {
            if let sessionId = viewModel.sessionId {
                ToolbarItem(placement: .topBarTrailing) {
                    RecordSyncBadge(state: .forYieldSession(sessionId, yieldSync: yieldSessionSync))
                }
            }
        }
    }
}
