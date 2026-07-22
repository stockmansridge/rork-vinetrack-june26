import SwiftUI

/// Fuel Log operational tool hub — one home for both canonical fuel record
/// types, following the Work Tasks hub pattern (summary card, tabs, record
/// list, add workflow, pull-to-refresh + auto-sync on open):
/// - Fuel Purchases → `fuel_purchases` (fuel bought from a supplier)
/// - Equipment Refuelling → `tractor_fuel_logs` (fills per vineyard machine)
///
/// Reuses the existing rows, form sheets, offline store and sync services, so
/// the Supabase data contract shared with Android and the portal is unchanged.
struct FuelLogHubView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(FuelPurchaseSyncService.self) private var fuelPurchaseSync
    @Environment(TractorFuelLogSyncService.self) private var tractorFuelLogSync
    @Environment(\.accessControl) private var accessControl

    private enum FuelTab: String, CaseIterable, Identifiable {
        case purchases = "Purchases"
        case refuelling = "Refuelling"
        var id: String { rawValue }
    }

    @State private var tab: FuelTab = .purchases
    @State private var showAddPurchase: Bool = false
    @State private var editingPurchase: FuelPurchase?
    @State private var showAddFill: Bool = false
    @State private var editingLog: TractorFuelLog?

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    // MARK: - Season boundary (same rule as the Work Tasks hub)

    /// Start of the current season — the most recent occurrence of the
    /// vineyard's configured season start (default 1 July) on or before today.
    private var currentSeasonStart: Date {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year], from: now)
        comps.month = store.settings.seasonStartMonth
        comps.day = store.settings.seasonStartDay
        guard let thisYear = cal.date(from: comps) else { return cal.startOfDay(for: now) }
        if thisYear <= now { return cal.startOfDay(for: thisYear) }
        comps.year = (comps.year ?? 0) - 1
        return cal.startOfDay(for: cal.date(from: comps) ?? now)
    }

    // MARK: - Data

    private var purchases: [FuelPurchase] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.fuelPurchases
            .filter { $0.vineyardId == vid }
            .sorted { $0.date > $1.date }
    }

    private var seasonPurchases: [FuelPurchase] {
        purchases.filter { $0.date >= currentSeasonStart }
    }

    private var logs: [TractorFuelLog] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.tractorFuelLogs
            .filter { $0.vineyardId == vid }
            .sorted { $0.fillDateTime > $1.fillDateTime }
    }

    private var seasonLogs: [TractorFuelLog] {
        logs.filter { $0.fillDateTime >= currentSeasonStart }
    }

    /// Fills grouped by machine (machineId preferred, legacy tractor fallback)
    /// in display order, each with a header label — mirrors the old Fuel Log.
    private var groupedLogs: [(key: String, header: String, logs: [TractorFuelLog])] {
        var order: [String] = []
        var map: [String: [TractorFuelLog]] = [:]
        for log in logs {
            let k = store.fuelLogGroupKey(log)
            if map[k] == nil { order.append(k); map[k] = [] }
            map[k]?.append(log)
        }
        return order.map { key in
            let groupLogs = map[key] ?? []
            let header = groupLogs.first.map { groupHeader(for: $0) } ?? "Machine"
            return (key, header, groupLogs)
        }
    }

    private func groupHeader(for log: TractorFuelLog) -> String {
        if let m = store.machine(forFuelLog: log) {
            return "\(m.displayName) · \(m.machineType.displayName)"
        }
        if let tid = log.tractorId,
           let t = store.tractors.first(where: { $0.id == tid && $0.vineyardId == store.selectedVineyardId }) {
            return t.displayName
        }
        return "Unassigned machine"
    }

    // MARK: - Season metrics (only from stored purchase/fill rows — never invented)

    private var seasonLitresPurchased: Double { seasonPurchases.reduce(0) { $0 + $1.volumeLitres } }
    private var seasonPurchaseCost: Double { seasonPurchases.reduce(0) { $0 + $1.totalCost } }
    /// Weighted average — total cost ÷ total litres for the season's purchases.
    private var seasonAvgCostPerLitre: Double? {
        guard seasonLitresPurchased > 0 else { return nil }
        return seasonPurchaseCost / seasonLitresPurchased
    }
    private var seasonLitresFilled: Double { seasonLogs.reduce(0) { $0 + $1.litresAdded } }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                summaryCard
                tabPicker
                if tab == .purchases {
                    purchasesSection
                } else {
                    refuellingSection
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Fuel Log")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if tab == .purchases {
                    if canManageSetup {
                        Button { showAddPurchase = true } label: { Image(systemName: "plus") }
                    }
                } else {
                    Button { showAddFill = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $showAddPurchase) {
            FuelPurchaseFormSheet(purchase: nil)
        }
        .sheet(item: $editingPurchase) { item in
            FuelPurchaseFormSheet(purchase: item)
        }
        .sheet(isPresented: $showAddFill) {
            FuelFillFormSheet(log: nil)
        }
        .sheet(item: $editingLog) { item in
            FuelFillFormSheet(log: item)
        }
        .refreshable {
            await syncFuelData()
        }
        // Auto-sync on open so the summary and lists are current without a
        // manual pull-to-refresh. Cached records stay visible while it runs.
        .task {
            await syncFuelData()
        }
    }

    private func syncFuelData() async {
        await fuelPurchaseSync.syncForSelectedVineyard()
        await tractorFuelLogSync.syncForSelectedVineyard()
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fuel Summary")
                        .font(.title3.weight(.bold))
                    Text("\(purchases.count) purchase\(purchases.count == 1 ? "" : "s") · \(logs.count) fill\(logs.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if canViewFinancials {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Purchased · This Season")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(fmt.formatCurrency(seasonPurchaseCost))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(VineyardTheme.leafGreen)
                        Text("From \(currentSeasonStart.formatted(.dateTime.day().month(.abbreviated).year()))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 10) {
                metricCell(
                    title: "Purchased",
                    value: fmt.formatFuel(litres: seasonLitresPurchased, fractionDigits: 0),
                    icon: "fuelpump.fill",
                    tint: .red
                )
                if canViewFinancials {
                    metricCell(
                        title: "Avg Cost / L",
                        value: seasonAvgCostPerLitre.map { fmt.formatFuelCostPerUnit(perLitre: $0) } ?? "Not specified",
                        icon: "dollarsign.circle.fill",
                        tint: VineyardTheme.olive
                    )
                }
                metricCell(
                    title: "Filled",
                    value: fmt.formatFuel(litres: seasonLitresFilled, fractionDigits: 0),
                    icon: "drop.fill",
                    tint: .cyan
                )
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func metricCell(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    // MARK: - Tabs

    private var tabPicker: some View {
        Picker("Record type", selection: $tab) {
            ForEach(FuelTab.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Purchases tab

    @ViewBuilder
    private var purchasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if canManageSetup {
                addActionCard(
                    title: "Add Fuel Purchase",
                    subtitle: "Record litres bought and the amount paid",
                    tint: .red
                ) {
                    showAddPurchase = true
                }
            }

            Text("Fuel Purchases")
                .font(.headline)

            if purchases.isEmpty {
                emptyStateCard(
                    icon: "fuelpump.circle.fill",
                    title: "No fuel purchases yet",
                    message: canManageSetup
                        ? "Record fuel purchases to calculate the weighted cost per litre used in trip and machine costing."
                        : "No fuel purchases have been recorded yet."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(purchases) { purchase in
                        Group {
                            if canManageSetup {
                                Button { editingPurchase = purchase } label: { purchaseCard(purchase) }
                                    .buttonStyle(.plain)
                            } else {
                                purchaseCard(purchase)
                            }
                        }
                    }
                }
                Text("Purchases drive the weighted average fuel cost per litre used by trip and machine costing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func purchaseCard(_ purchase: FuelPurchase) -> some View {
        FuelPurchaseRow(purchase: purchase)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Refuelling tab

    @ViewBuilder
    private var refuellingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            addActionCard(
                title: "Record Fuel Fill",
                subtitle: "Litres added and engine hours for a vineyard machine",
                tint: .cyan
            ) {
                showAddFill = true
            }

            Text("Equipment Refuelling")
                .font(.headline)

            if logs.isEmpty {
                emptyStateCard(
                    icon: "drop.circle.fill",
                    title: "No fuel fills yet",
                    message: "Record litres added and engine hours when you fill a vineyard machine to calculate usage over time."
                )
            } else {
                ForEach(groupedLogs, id: \.key) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.header)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        ForEach(group.logs) { log in
                            fillCard(log)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fillCard(_ log: TractorFuelLog) -> some View {
        let previous = store.previousFuelLog(forMachineGroupOf: log, before: log.fillDateTime, excluding: log.id)
        let rate = TractorFuelRateCalculator.rate(current: log, previous: previous)
        let canEdit = canManageSetup || (log.operatorUserId != nil && log.operatorUserId == store.currentUserIdProvider?())
        Group {
            if canEdit {
                Button { editingLog = log } label: {
                    FuelLogRow(log: log, rate: rate)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            } else {
                FuelLogRow(log: log, rate: rate)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            }
        }
    }

    // MARK: - Shared pieces

    private func addActionCard(title: String, subtitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint.gradient, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func emptyStateCard(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}
