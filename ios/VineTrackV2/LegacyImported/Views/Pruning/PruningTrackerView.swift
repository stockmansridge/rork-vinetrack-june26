import SwiftUI

/// Pruning Tracker hub — vineyard dashboard plus a visual block list.
/// In development: reachable only by System Admins from Operational Tools.
struct PruningTrackerView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(PruningSyncService.self) private var pruningSync
    private var pruningStore: PruningStore { .shared }

    private var paddocks: [Paddock] {
        let all = store.paddocks
        guard let vineyardId = store.selectedVineyardId else { return all }
        return all.filter { $0.vineyardId == vineyardId }
    }

    private var blockMetrics: [(paddock: Paddock, metrics: PruningBlockMetrics)] {
        paddocks
            .map { paddock in
                let setup = pruningStore.setup(for: paddock.id)
                let entries = pruningStore.entries(for: paddock.id)
                return (paddock, PruningCalculator.metrics(paddock: paddock, setup: setup, entries: entries))
            }
            .sorted { $0.paddock.name.localizedStandardCompare($1.paddock.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                devBadge
                dashboardCard
                blockList
                Spacer(minLength: 24)
            }
            .padding(.vertical)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Pruning Tracker")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await pruningSync.syncForSelectedVineyard()
        }
        .task {
            await pruningSync.syncForSelectedVineyard()
        }
    }

    private var devBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "hammer.fill")
                .font(.caption2)
            Text("In development — visible to System Admins only")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Dashboard

    private var totals: (
        completedEq: Double, totalEq: Double,
        vinesPruned: Int, vinesTotal: Int,
        blocksComplete: Int, blocksBehind: Int,
        vinesPerDay: Double?, vinesPerHour: Double?,
        projectedFinish: Date?
    ) {
        var completedEq = 0.0
        var totalEq = 0.0
        var vinesPruned = 0
        var vinesTotal = 0
        var blocksComplete = 0
        var blocksBehind = 0
        var projected: Date?

        var vinesByDay: [Date: Double] = [:]
        var vinesForHours = 0.0
        var hours = 0.0
        let calendar = Calendar.current

        for (paddock, metrics) in blockMetrics {
            completedEq += metrics.completedRowEquivalents
            totalEq += metrics.totalRowEquivalents
            vinesPruned += metrics.vinesPruned
            vinesTotal += metrics.vinesTotal
            if metrics.status == .complete { blocksComplete += 1 }
            if metrics.status == .behind || metrics.status == .atRisk { blocksBehind += 1 }
            if let finish = metrics.projectedFinish {
                projected = max(projected ?? finish, finish)
            }
            for entry in pruningStore.entries(for: paddock.id) {
                let vines = Double(PruningCalculator.vines(forSegmentCount: entry.segments.count, vinesPerRow: metrics.vinesPerRow))
                vinesByDay[calendar.startOfDay(for: entry.date), default: 0] += vines
                if let entryHours = entry.labourHours, entryHours > 0 {
                    vinesForHours += vines
                    hours += entryHours
                }
            }
        }

        let vinesPerDay = vinesByDay.isEmpty ? nil : vinesByDay.values.reduce(0, +) / Double(vinesByDay.count)
        let vinesPerHour = hours > 0 ? vinesForHours / hours : nil
        return (completedEq, totalEq, vinesPruned, vinesTotal, blocksComplete, blocksBehind, vinesPerDay, vinesPerHour, projected)
    }

    private var dashboardCard: some View {
        let summary = totals
        let fraction = summary.totalEq > 0 ? min(summary.completedEq / summary.totalEq, 1) : 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vineyard Progress")
                    .font(.headline)
                Spacer()
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .monospacedDigit()
            }

            PruningProgressBar(fraction: fraction, elapsedFraction: nil, tint: VineyardTheme.leafGreen)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                dashStat(value: "\(summary.vinesPruned.formatted())", label: "Vines pruned")
                dashStat(value: "\(max(summary.vinesTotal - summary.vinesPruned, 0).formatted())", label: "Vines remaining")
                dashStat(value: summary.vinesPerDay.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", label: "Vines / day")
                dashStat(value: summary.vinesPerHour.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", label: "Vines / labour hr")
                dashStat(value: "\(summary.blocksComplete)", label: "Blocks complete")
                dashStat(value: "\(summary.blocksBehind)", label: "Blocks at risk")
            }

            if let projected = summary.projectedFinish {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Projected vineyard completion: \(projected.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
        .padding(.horizontal)
    }

    private func dashStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Block list

    @ViewBuilder
    private var blockList: some View {
        if paddocks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No blocks yet")
                    .font(.headline)
                Text("Add blocks in Vineyard Setup to start tracking pruning.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
            .padding(.horizontal)
        } else {
            VStack(spacing: 12) {
                ForEach(blockMetrics, id: \.paddock.id) { item in
                    NavigationLink {
                        PruningBlockDetailView(paddock: item.paddock, pruningStore: pruningStore)
                    } label: {
                        PruningBlockCard(paddock: item.paddock, metrics: item.metrics, setup: pruningStore.setup(for: item.paddock.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Block card

struct PruningBlockCard: View {
    let paddock: Paddock
    let metrics: PruningBlockMetrics
    let setup: PruningBlockSetup?

    private var varietyName: String? {
        paddock.varietyAllocations
            .max { $0.percent < $1.percent }?
            .name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(paddock.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let varietyName, !varietyName.isEmpty {
                        Text(varietyName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                PruningStatusChip(status: metrics.status)
            }

            if metrics.rowCount > 0 {
                PruningProgressBar(
                    fraction: metrics.fractionComplete,
                    elapsedFraction: metrics.timeElapsedFraction,
                    tint: metrics.status.tint
                )

                HStack {
                    Text("\(metrics.completedRowEquivalents.formatted(.number.precision(.fractionLength(0...2)))) of \(metrics.rowCount) row equivalents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(metrics.fractionComplete.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            } else {
                Text("Row count needed — open to set up")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 14) {
                if let due = setup?.dueDate {
                    labelledDate(icon: "flag.checkered", text: "Due \(due.formatted(date: .abbreviated, time: .omitted))")
                }
                if let projected = metrics.projectedFinish {
                    labelledDate(icon: "calendar.badge.clock", text: "Est. \(projected.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VineyardTheme.cardBorder, lineWidth: 0.5))
    }

    private func labelledDate(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Shared bits

struct PruningStatusChip: View {
    let status: PruningStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.14), in: .capsule)
    }
}

/// Progress bar with an optional "time elapsed" marker so work-done vs
/// time-used is visible at a glance.
struct PruningProgressBar: View {
    let fraction: Double
    let elapsedFraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))
                Capsule()
                    .fill(tint)
                    .frame(width: max(width * min(max(fraction, 0), 1), fraction > 0 ? 8 : 0))
                if let elapsedFraction {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2)
                        .offset(x: width * min(max(elapsedFraction, 0), 1) - 1)
                }
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

extension PruningStatus {
    var tint: Color {
        switch self {
        case .notStarted: return .gray
        case .ahead: return .green
        case .onTrack: return .blue
        case .atRisk: return .orange
        case .behind: return .red
        case .complete: return VineyardTheme.leafGreen
        }
    }
}
