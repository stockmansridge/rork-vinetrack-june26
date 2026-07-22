import SwiftUI

/// Owner/manager-only Cost Reports screen.
///
/// Reads from `store.tripCostAllocations` (saved breakdowns produced by
/// `TripCostAllocationCalculator`). Supervisors/operators must never see this
/// screen — gate the entry point via `accessControl.canViewCosting`.
struct CostReportsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(TripCostAllocationSyncService.self) private var allocationSync

    @State private var selectedSeason: Int? = nil
    @State private var selectedPaddockId: UUID? = nil
    @State private var selectedVariety: String? = nil
    @State private var selectedFunction: String? = nil
    @State private var isRecalculating: Bool = false
    @State private var recalcMessage: String?
    @State private var showTreatedAreaInfo: Bool = false
    @State private var showUnassignedInfo: Bool = false
    @State private var groupByFunction: Bool = false

    private var canViewCosting: Bool { accessControl.canViewCosting }

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var vineyardId: UUID? { store.selectedVineyardId }

    private var allRows: [TripCostAllocation] {
        guard let vid = vineyardId else { return [] }
        return store.tripCostAllocations.filter { $0.vineyardId == vid }
    }

    private var seasons: [Int] {
        Array(Set(allRows.map { $0.seasonYear })).sorted(by: >)
    }

    private var functions: [String] {
        Array(Set(allRows.compactMap { $0.tripFunction })).sorted()
    }

    private var paddocks: [(id: UUID, name: String)] {
        let pairs = allRows.compactMap { row -> (UUID, String)? in
            guard let id = row.paddockId else { return nil }
            return (id, row.paddockName ?? "Block")
        }
        let map = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        return map.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var varieties: [String] {
        Array(Set(allRows.compactMap { $0.variety })).sorted()
    }

    private var filteredRows: [TripCostAllocation] {
        allRows.filter { row in
            if let season = selectedSeason, row.seasonYear != season { return false }
            if let pid = selectedPaddockId, row.paddockId != pid { return false }
            if let v = selectedVariety, row.variety != v { return false }
            if let f = selectedFunction, row.tripFunction != f { return false }
            return true
        }
    }

    var body: some View {
        Group {
            if !canViewCosting {
                ContentUnavailableView(
                    "Cost Reports unavailable",
                    systemImage: "lock.fill",
                    description: Text("Cost reports are visible to vineyard owners and managers only.")
                )
            } else {
                List {
                    if let vid = vineyardId {
                        CostingSetupWizardSection(
                            analysis: CostingSetupAnalysis.make(store: store, vineyardId: vid)
                        )
                    }
                    staleAllocationsBanner
                    filtersSection
                    seasonSummarySection
                    blockBreakdownSection
                    actionsSection
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Cost Reports")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if canViewCosting, selectedSeason == nil {
                selectedSeason = seasons.first
            }
        }
        .refreshable {
            await allocationSync.syncForSelectedVineyard()
        }
        .sheet(isPresented: $showTreatedAreaInfo) { TreatedAreaInfoSheet() }
        .sheet(isPresented: $showUnassignedInfo) { UnassignedVarietyInfoSheet() }
    }

    // MARK: Filters

    @ViewBuilder
    private var filtersSection: some View {
        Section("Filters") {
            Picker("Vintage", selection: $selectedSeason) {
                Text("All vintages").tag(Int?.none)
                ForEach(seasons, id: \.self) { y in
                    Text("Vintage \(String(y))").tag(Int?.some(y))
                }
            }
            Picker(fmt.blockTermCapitalised, selection: $selectedPaddockId) {
                Text("All \(fmt.blockTermPlural)").tag(UUID?.none)
                ForEach(paddocks, id: \.id) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }
            Picker("Variety", selection: $selectedVariety) {
                Text("All varieties").tag(String?.none)
                ForEach(varieties, id: \.self) { v in
                    Text(v).tag(String?.some(v))
                }
            }
            Picker("Operation", selection: $selectedFunction) {
                Text("All operations").tag(String?.none)
                ForEach(functions, id: \.self) { f in
                    Text(f.capitalized).tag(String?.some(f))
                }
            }
        }
    }

    // MARK: Season summary

    @ViewBuilder
    private var seasonSummarySection: some View {
        let rows = filteredRows
        let totalCost = rows.reduce(0.0) { $0 + ($1.totalCost ?? 0) }
        let totalArea = rows.reduce(0.0) { $0 + ($1.allocationAreaHa ?? 0) }
        let totalYield = rows.reduce(0.0) { $0 + ($1.yieldTonnes ?? 0) }
        let costPerHa: Double? = totalArea > 0 && totalCost > 0 ? totalCost / totalArea : nil
        let costPerTonne: Double? = totalYield > 0 && totalCost > 0 ? totalCost / totalYield : nil

        Section {
            summaryRow("Total estimated cost", value: fmt.formatCurrency(totalCost))
            HStack {
                Text("Treated area")
                Button {
                    showTreatedAreaInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About treated area")
                Spacer()
                Text(fmt.formatArea(hectares: totalArea))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            summaryRow("Cost / \(fmt.areaUnitAbbreviation)", value: costPerHa.map { "\(fmt.formatCurrency(fmt.perAreaValue(perHectare: $0)))/\(fmt.areaUnitAbbreviation)" } ?? "—")
            summaryRow("Yield", value: totalYield > 0 ? String(format: "%.2f t", totalYield) : "—")
            summaryRow("Cost / tonne", value: costPerTonne.map { "\(fmt.formatCurrency($0))/t" } ?? "—")
            if rows.isEmpty {
                Text("No cost allocations yet — recalculate to populate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Vintage summary")
        } footer: {
            Text("Treated area is the accumulated mapped block area from the jobs/trips included in this report. If the same block is treated multiple times, its area contributes once per job.")
        }
    }

    // MARK: Block breakdown

    private struct BlockVarietyKey: Hashable {
        let seasonYear: Int
        let paddockId: UUID?
        let paddockName: String
        let variety: String
        let tripFunction: String?
    }

    private struct BlockVarietyAggregate {
        var area: Double = 0
        var yieldT: Double = 0
        var labour: Double = 0
        var fuel: Double = 0
        var chemical: Double = 0
        var input: Double = 0
        var total: Double = 0
    }

    @ViewBuilder
    private var blockBreakdownSection: some View {
        let rows = filteredRows
        let groups: [(BlockVarietyKey, BlockVarietyAggregate, [TripCostAllocation])] = aggregate(rows)
        Section {
            Toggle("Group by operation", isOn: $groupByFunction)
                .font(.caption)
            if groups.isEmpty {
                Text("No breakdown rows for the current filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups, id: \.0) { triple in
                    NavigationLink {
                        CostBreakdownDetailView(rows: triple.2, title: "\(triple.0.paddockName) · \(triple.0.variety)")
                    } label: {
                        breakdownRow(key: triple.0, agg: triple.1, tripCount: triple.2.count)
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("Vintage × \(fmt.blockTermCapitalised) × Variety")
                if groups.contains(where: { $0.0.variety == "Unassigned variety" }) {
                    Button {
                        showUnassignedInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About unassigned variety")
                }
            }
        } footer: {
            Text("Rows are grouped by vintage, block and variety. Costs are assigned to the production vintage resolved from the work date and your season start setting. Tap a row to see the contributing trips.")
        }
    }

    private func aggregate(_ rows: [TripCostAllocation]) -> [(BlockVarietyKey, BlockVarietyAggregate, [TripCostAllocation])] {
        var buckets: [BlockVarietyKey: (agg: BlockVarietyAggregate, rows: [TripCostAllocation])] = [:]
        for row in rows {
            let normalisedVariety: String = {
                guard let v = row.variety?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                    return "Unassigned variety"
                }
                return v
            }()
            let key = BlockVarietyKey(
                seasonYear: row.seasonYear,
                paddockId: row.paddockId,
                paddockName: row.paddockName ?? "Block",
                variety: normalisedVariety,
                tripFunction: groupByFunction ? row.tripFunction : nil
            )
            var bucket = buckets[key] ?? (BlockVarietyAggregate(), [])
            bucket.agg.area += row.allocationAreaHa ?? 0
            bucket.agg.yieldT += row.yieldTonnes ?? 0
            bucket.agg.labour += row.labourCost ?? 0
            bucket.agg.fuel += row.fuelCost ?? 0
            bucket.agg.chemical += row.chemicalCost ?? 0
            bucket.agg.input += row.inputCost ?? 0
            bucket.agg.total += row.totalCost ?? 0
            bucket.rows.append(row)
            buckets[key] = bucket
        }
        return buckets
            .map { ($0.key, $0.value.agg, $0.value.rows) }
            .sorted {
                if $0.0.seasonYear != $1.0.seasonYear {
                    return $0.0.seasonYear > $1.0.seasonYear
                }
                if $0.0.paddockName != $1.0.paddockName {
                    return $0.0.paddockName.localizedStandardCompare($1.0.paddockName) == .orderedAscending
                }
                if $0.0.variety != $1.0.variety {
                    return $0.0.variety.localizedStandardCompare($1.0.variety) == .orderedAscending
                }
                return ($0.0.tripFunction ?? "").localizedStandardCompare($1.0.tripFunction ?? "") == .orderedAscending
            }
    }

    @ViewBuilder
    private func breakdownRow(key: BlockVarietyKey, agg: BlockVarietyAggregate, tripCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Vintage \(String(key.seasonYear)) · \(key.paddockName)")
                    .font(.headline)
                Spacer()
                Text(fmt.formatCurrency(agg.total))
                    .font(.headline.monospacedDigit())
            }
            HStack(spacing: 8) {
                Text(key.variety)
                if key.variety == "Unassigned variety" {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let f = key.tripFunction {
                    Text("·")
                    Text(f.capitalized)
                }
                Text("·")
                Text(fmt.formatArea(hectares: agg.area))
                if agg.yieldT > 0 {
                    Text("·")
                    Text(String(format: "%.1f t", agg.yieldT))
                }
                Text("·")
                Text("\(tripCount) trip\(tripCount == 1 ? "" : "s")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if agg.area > 0 {
                    Text("\(fmt.formatCurrency(fmt.perAreaValue(perHectare: agg.total / agg.area)))/\(fmt.areaUnitAbbreviation)")
                }
                if agg.yieldT > 0 {
                    Text(String(format: "$%.0f/t", agg.total / agg.yieldT))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Stale allocation detection

    /// Count rows that report "Unassigned variety" but whose linked paddock
    /// now has a variety allocation that the resolver can resolve. These rows
    /// were created before the latest variety resolver and just need a
    /// recalculation to pick up the correct name/id.
    private var staleUnassignedRowCount: Int {
        filteredRows.reduce(0) { count, row in
            let isUnassigned: Bool = {
                guard let v = row.variety?.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
                return v.isEmpty || v == "Unassigned variety"
            }()
            guard isUnassigned else { return count }
            guard let pid = row.paddockId,
                  let paddock = store.paddocks.first(where: { $0.id == pid })
            else { return count }
            let resolvable = paddock.varietyAllocations.contains { alloc in
                PaddockVarietyResolver.resolve(allocation: alloc, varieties: store.grapeVarieties).isResolved
            }
            return resolvable ? count + 1 : count
        }
    }

    @ViewBuilder
    private var staleAllocationsBanner: some View {
        let stale = staleUnassignedRowCount
        if stale > 0 {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Some cost rows look out of date", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("\(stale) row\(stale == 1 ? "" : "s") were calculated before the latest block variety resolver. Recalculate Costs to refresh block and variety names.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await recalculateAll() }
                    } label: {
                        HStack {
                            if isRecalculating { ProgressView().controlSize(.small) }
                            Text(isRecalculating ? "Recalculating…" : "Recalculate Costs")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isRecalculating)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                Task { await recalculateAll() }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(isRecalculating ? "Recalculating…" : "Recalculate Costs")
                    Spacer()
                    if isRecalculating { ProgressView() }
                }
            }
            .disabled(isRecalculating)
            if let recalcMessage {
                Text(recalcMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Recalculate rebuilds cost allocation rows for every trip in the selected vintage from current trip costing. Owners and managers only.")
        }
    }

    private func recalculateAll() async {
        guard canViewCosting else { return }
        isRecalculating = true
        defer { isRecalculating = false }
        let runner = TripCostAllocationRecalculator(store: store, allocationSync: allocationSync)
        let season = selectedSeason
        let count = await runner.recalculateSeason(season)
        recalcMessage = "Recalculated \(count) trip\(count == 1 ? "" : "s")."
        await allocationSync.syncForSelectedVineyard()
    }

    // MARK: Helpers

    @ViewBuilder
    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

}

// MARK: - Detail drilldown

struct CostBreakdownDetailView: View {
    let rows: [TripCostAllocation]
    let title: String
    @Environment(MigratedDataStore.self) private var store

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    var body: some View {
        List {
            Section("Contributing trips") {
                if rows.isEmpty {
                    Text("No contributing trips.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows.sorted(by: { ($0.calculatedAt) > ($1.calculatedAt) }), id: \.id) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tripTitle(for: row))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(fmt.formatCurrency(row.totalCost ?? 0))
                                .font(.subheadline.monospacedDigit())
                        }
                        HStack(spacing: 6) {
                            if let f = row.tripFunction { Text(f.capitalized) }
                            if let a = row.allocationAreaHa { Text("· \(fmt.formatArea(hectares: a))") }
                            if let y = row.yieldTonnes { Text("· \(String(format: "%.1f t", y))") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !row.warnings.isEmpty {
                            ForEach(row.warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tripTitle(for row: TripCostAllocation) -> String {
        if let trip = store.trips.first(where: { $0.id == row.tripId }) {
            let date = fmt.formatDate(trip.startTime)
            return "\(trip.tripFunction?.capitalized ?? "Trip") · \(date)"
        }
        return "Trip"
    }
}

// MARK: - Recalculation

/// Drives the recalculation flow for one or many trips. Reuses
/// `TripCostService` for the totals and `TripCostAllocationCalculator` for
/// the per-(paddock, variety) split so the saved breakdown always matches
/// what users see in Trip Detail.
@MainActor
struct TripCostAllocationRecalculator {
    let store: MigratedDataStore
    let allocationSync: TripCostAllocationSyncService

    /// Rebuild allocation rows for every trip in `season` (a production
    /// VINTAGE year; nil = all vintages). Vintage resolution mirrors the
    /// authoritative database resolver (sql/119).
    func recalculateSeason(_ season: Int?) async -> Int {
        guard let vineyardId = store.selectedVineyardId else { return 0 }
        let startMonth = store.settings.seasonStartMonth
        let startDay = store.settings.seasonStartDay
        let trips = store.trips.filter { trip in
            guard trip.vineyardId == vineyardId else { return false }
            guard let season else { return true }
            return VintageResolver.vintageYear(
                for: trip.startTime,
                seasonStartMonth: startMonth,
                seasonStartDay: startDay
            ) == season
        }
        var processed = 0
        for trip in trips {
            if await recalculate(trip: trip) { processed += 1 }
        }
        return processed
    }

    /// Rebuild allocation rows for a single trip. Soft-deletes any existing
    /// rows for the trip on Supabase and locally, then inserts a fresh set.
    @discardableResult
    func recalculate(trip: Trip) async -> Bool {
        // Resolve TripCostService inputs the same way TripDetailView does.
        let operatorCategory: OperatorCategory? = {
            if let cid = trip.operatorCategoryId,
               let cat = store.operatorCategories.first(where: { $0.id == cid }) {
                return cat
            }
            return nil
        }()
        let tractor: Tractor? = trip.tractorId.flatMap { id in
            store.tractors.first { $0.id == id }
        }
        // Preferred fuel source: the linked vineyard machine (by machineId, or
        // the legacy tractor link). Falls back to the tractor rate inside
        // TripCostService when the machine has no approved rate.
        let machine: VineyardMachine? = {
            if let mid = trip.machineId,
               let m = store.vineyardMachines.first(where: { $0.id == mid }) {
                return m
            }
            if let tid = trip.tractorId {
                return store.vineyardMachines.first { $0.legacyTractorId == tid && $0.vineyardId == trip.vineyardId }
            }
            return nil
        }()
        let fuelPurchases = store.fuelPurchases.filter { $0.vineyardId == trip.vineyardId }
        let sprayRecord = store.sprayRecords.first { $0.tripId == trip.id }

        var paddockAreasById: [UUID: Double] = [:]
        var paddockIds: [UUID] = trip.paddockIds
        if paddockIds.isEmpty, let single = trip.paddockId { paddockIds = [single] }
        for id in paddockIds {
            if let p = store.paddocks.first(where: { $0.id == id }) {
                paddockAreasById[id] = p.areaHectares
            }
        }
        let paddockHectares = paddockAreasById.values.reduce(0, +)

        let result = TripCostService.estimate(
            trip: trip,
            operatorCategory: operatorCategory,
            machine: machine,
            tractor: tractor,
            fuelPurchases: fuelPurchases,
            sprayRecord: sprayRecord,
            savedChemicals: store.savedChemicals,
            savedInputs: store.savedInputs,
            paddockHectares: paddockHectares > 0 ? paddockHectares : nil,
            paddockAreasById: paddockAreasById,
            historicalYieldRecords: store.historicalYieldRecords
        )

        let rows = TripCostAllocationCalculator.makeAllocations(
            trip: trip,
            result: result,
            paddocks: store.paddocks,
            varieties: store.grapeVarieties,
            historicalYieldRecords: store.historicalYieldRecords,
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay,
            sourceTripUpdatedAt: trip.endTime ?? trip.startTime
        )

        // Soft-delete every existing remote row for this trip in bulk so the
        // unique (trip, paddock, variety) index never fights us when fresh
        // rows have new ids.
        await allocationSync.softDeleteAllocations(forTripId: trip.id)
        store.replaceTripCostAllocations(tripId: trip.id, with: rows)
        return !rows.isEmpty
    }
}

// MARK: - Info sheets

struct TreatedAreaInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("What is treated area?") {
                    Text("Treated area is the accumulated mapped block area from the jobs/trips included in this report. If the same block is treated multiple times, its area contributes once per job.")
                        .font(.subheadline)
                }
                Section("Example") {
                    Text("If Block A is 2 ha and has 3 spray trips this season, treated area contributes 6 ha across those jobs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Why this matters") {
                    Label("Cost / ha = total estimated cost ÷ treated area.", systemImage: "divide.circle")
                        .font(.footnote)
                    Label("Treated area is not the same as the vineyard's total area — it reflects work done.", systemImage: "square.grid.2x2")
                        .font(.footnote)
                }
            }
            .navigationTitle("Treated area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct UnassignedVarietyInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Unassigned variety") {
                    Text("This means the block has no variety allocation, or VineTrack could not match the block's variety allocation to a recognised variety. Add or fix variety allocations in Block Settings.")
                        .font(.subheadline)
                }
                Section("Fix it") {
                    NavigationLink {
                        VineyardSetupHubView()
                    } label: {
                        Label("Open Blocks", systemImage: "square.grid.2x2.fill")
                    }
                }
            }
            .navigationTitle("Variety allocation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
