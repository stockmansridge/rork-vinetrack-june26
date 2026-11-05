import SwiftUI

/// Raw, dated Panel Count observations. This does not silently promote the
/// method as a canonical bunches-per-vine or current seasonal tonnage source.
struct PanelCountSummary: View {
    let session: YieldEstimationSession

    private var groups: [(name: String, measurements: [PanelCountMeasurement])] {
        let recorded = session.sampleSites.compactMap { site -> (UUID, String, PanelCountMeasurement)? in
            guard let entry = site.panelCountEntry else { return nil }
            return (site.paddockId, site.paddockName, entry.measurement)
        }
        return Dictionary(grouping: recorded, by: { $0.0 })
            .map { (_, samples) in
                (name: samples.first?.1 ?? "Block", measurements: samples.map(\.2))
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Panel Count · Recorded Observations", systemImage: "square.grid.3x3.fill")
                .font(.headline)
                .foregroundStyle(.purple)
            if groups.isEmpty {
                Text("No post-to-post panels have been recorded.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups.indices, id: \.self) { index in
                let group = groups[index]
                let totalBunches = group.measurements.reduce(Int64(0)) { $0 + Int64($1.totalBunches) }
                let planted = group.measurements.reduce(Int64(0)) { $0 + Int64($1.plantedPositions) }
                let fruiting = group.measurements.reduce(Int64(0)) { $0 + Int64($1.fruitingVines) }
                let missing = group.measurements.reduce(Int64(0)) { $0 + Int64($1.missingPositions) }
                let nonproductive = group.measurements.reduce(Int64(0)) { $0 + Int64($1.nonproductiveVines) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.subheadline.weight(.semibold))
                    Text("\(group.measurements.count) panels · \(totalBunches) bunches · \(planted) planted positions")
                        .font(.subheadline)
                    Text("\(fruiting) fruiting · \(missing) missing · \(nonproductive) nonproductive")
                        .font(.caption).foregroundStyle(.secondary)
                    if planted > 0 {
                        Text(String(format: "%.2f bunches per planted position",
                                    Double(totalBunches) / Double(planted)))
                            .font(.caption.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            }
            Text("Raw method-specific survey results. Panel Count does not automatically replace the block's current Yield Estimate. No unverified tonnage is calculated.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.purple.opacity(0.07), in: .rect(cornerRadius: 12))
    }
}
