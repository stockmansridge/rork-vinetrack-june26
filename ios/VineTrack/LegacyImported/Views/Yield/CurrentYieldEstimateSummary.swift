import SwiftUI

/// Shared current-authority presentation for trip lists, detail, completion and reports.
struct CurrentYieldEstimateSummary: View {
    let estimate: CurrentYieldEstimate.Trip
    var detailed = true
    var current = false

    private func tonnes(_ value: Double?) -> String {
        value.map { String(format: "%.3f t", $0) } ?? "Bunch weight required"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let method = estimate.countMethod { Text(method).font(.caption.weight(.semibold)) }
            if current { Text("Current Estimate").font(.caption.weight(.semibold)).foregroundStyle(VineyardTheme.leafGreen) }
            ForEach(estimate.blocks) { block in
                VStack(alignment: .leading, spacing: 3) {
                    Text(block.name).font(.subheadline.weight(.semibold))
                    Text(block.varieties.isEmpty ? "Variety not configured" : block.varieties).font(.caption)
                    Text("\(block.samplesRecorded)/\(block.samplesTotal) samples · \(block.averageBunches.map { String(format: "%.2f", $0) } ?? "—") bunches/vine · \(block.vines) vines").font(.caption2)
                    Text(block.weightKg.map { String(format: "Current bunch weight %.1f g", $0 * 1000) } ?? "Bunch weight not set").font(.caption)
                    ForEach(block.weightSources, id: \.self) { Text($0).font(.caption2) }
                    Text(block.samplesRecorded == 0 ? "Not sampled" : (block.averageBunches == nil ? "Recorded counts need review" : tonnes(block.displayTonnes))).font(.subheadline.weight(.semibold))
                    if let perHa = block.tonnesPerHa { Text(String(format: "%.3f t/ha", perHa)).font(.caption) }
                    if detailed {
                        Text(String(format: "Sampled area %.3f ha", block.sampledAreaHa)).font(.caption2)
                        if let base = block.baseTonnes, let adjusted = block.adjustedTonnes {
                            Text(String(format: "Base %.3f t · damage adjusted %.3f t", base, adjusted)).font(.caption2)
                        }
                        if let historical = block.historicalWeightKg {
                            Text(String(format: "Historical trip weight %.1f g — not current authority", historical * 1000)).font(.caption2)
                        }
                    }
                }
            }
            Divider()
            Text("Trip estimate: \(tonnes(estimate.totalTonnes))").font(.subheadline.weight(.semibold))
            Text(String(format: "Sampled area %.3f ha", estimate.sampledAreaHa)).font(.caption)
            if let perHa = estimate.tonnesPerHa { Text(String(format: "Per ha %.3f t/ha", perHa)).font(.caption) }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct YieldMasterRefresh: ViewModifier {
    var enabled = true
    @Environment(MigratedDataStore.self) private var store
    private var identity: String {
        let plantings = store.paddocks.map { "\($0.id):\(CurrentYieldEstimate.plantings($0).map(\.key).joined(separator: ","))" }.joined(separator: ";")
        return "\(store.selectedVineyardId?.uuidString ?? "")/\(YieldMasterWeightCache.shared.scopeIdentity)/\(plantings)"
    }
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if enabled, let warning = YieldMasterWeightCache.shared.syncError(vineyardId: store.selectedVineyardId) {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            content
        }.task(id: identity) {
            if enabled { await YieldMasterWeightCache.shared.refresh(vineyardId: store.selectedVineyardId, paddocks: store.paddocks) }
        }.refreshable {
            if enabled { await YieldMasterWeightCache.shared.refresh(vineyardId: store.selectedVineyardId, paddocks: store.paddocks) }
        }
    }
}
