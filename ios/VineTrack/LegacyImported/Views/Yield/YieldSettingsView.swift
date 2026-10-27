import SwiftUI

struct YieldSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    var body: some View {
        List {
            Section {
                Text("Shared Master Bunch Weights are managed in the Portal. Block overrides take priority over vineyard variety masters. Pull to refresh; offline uses only the last server-confirmed values for this account and vineyard.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.orderedPaddocks) { paddock in
                    let observation = YieldEstimationSession(vineyardId: store.selectedVineyardId ?? UUID(), selectedPaddockIds: [paddock.id])
                    let estimate = CurrentYieldEstimate.trip(session: observation, paddocks: [paddock],
                        weights: YieldMasterWeightCache.shared.weights(vineyardId: store.selectedVineyardId))
                    CurrentYieldEstimateSummary(estimate: estimate, detailed: false)
                }
            } header: { Text("Master Bunch Weights") }
        }
        .navigationTitle("Yield Settings")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(YieldMasterRefresh())
    }
}
