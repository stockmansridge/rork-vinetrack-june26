import SwiftUI

/// Combined Fuel screen reached from the FUEL entry of the Equipment screen.
/// Shows Fuel Purchases first (driving weighted cost per litre) and the Fuel
/// Log underneath (fills per vineyard machine). Both reuse the existing rows
/// and form sheets so underlying behaviour, data sources, and sync are
/// unchanged:
/// - Fuel Purchases → `fuel_purchases`
/// - Fuel Log → `tractor_fuel_logs` (grouped by `machine_id` where available)
struct FuelView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    @State private var showAddPurchaseSheet: Bool = false
    @State private var editingPurchase: FuelPurchase?
    @State private var showAddFillSheet: Bool = false
    @State private var editingLog: TractorFuelLog?

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    /// Region-aware display formatter (AU defaults when no settings exist).
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    // MARK: - Fuel Log data (mirrors FuelLogView)

    private var vineyardTractors: [Tractor] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.tractors.filter { $0.vineyardId == vid }
    }

    private var logs: [TractorFuelLog] {
        guard let vid = store.selectedVineyardId else { return [] }
        return store.tractorFuelLogs
            .filter { $0.vineyardId == vid }
            .sorted { $0.fillDateTime > $1.fillDateTime }
    }

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
        if let tid = log.tractorId, let t = vineyardTractors.first(where: { $0.id == tid }) {
            return t.displayName
        }
        return "Unassigned machine"
    }

    // MARK: - Body

    var body: some View {
        List {
            fuelPurchasesSection
            fuelLogSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Fuel")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddPurchaseSheet) {
            FuelPurchaseFormSheet(purchase: nil)
        }
        .sheet(item: $editingPurchase) { item in
            FuelPurchaseFormSheet(purchase: item)
        }
        .sheet(isPresented: $showAddFillSheet) {
            FuelFillFormSheet(log: nil)
        }
        .sheet(item: $editingLog) { item in
            FuelFillFormSheet(log: item)
        }
    }

    // MARK: - Fuel Purchases

    @ViewBuilder
    private var fuelPurchasesSection: some View {
        Section {
            if store.fuelPurchases.isEmpty {
                Text(canManageSetup
                     ? "Record fuel purchases to calculate an average cost per litre."
                     : "No fuel purchases have been recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.fuelPurchases.sorted(by: { $0.date > $1.date })) { purchase in
                    Group {
                        if canManageSetup {
                            Button { editingPurchase = purchase } label: { FuelPurchaseRow(purchase: purchase) }
                        } else {
                            FuelPurchaseRow(purchase: purchase)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if canManageSetup {
                            Button(role: .destructive) {
                                store.deleteFuelPurchase(purchase)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Season Average")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if accessControl?.canViewFinancials ?? false {
                            Text(fmt.formatFuelCostPerUnit(perLitre: store.seasonFuelCostPerLitre))
                                .font(.headline.bold())
                                .foregroundStyle(VineyardTheme.olive)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Total Purchased")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let totalVol = store.fuelPurchases.reduce(0) { $0 + $1.volumeLitres }
                        Text(fmt.formatFuel(litres: totalVol, fractionDigits: 0))
                            .font(.subheadline.weight(.medium))
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            sectionHeader(title: "Fuel Purchases", systemImage: "fuelpump.circle.fill") {
                showAddPurchaseSheet = true
            }
        } footer: {
            Text("Record fuel purchases used to calculate weighted fuel cost per litre.")
        }
    }

    // MARK: - Fuel Log

    @ViewBuilder
    private var fuelLogSection: some View {
        Section {
            if logs.isEmpty {
                Text("No fuel fills recorded yet. Tap + to record litres added and engine hours when you fill a vineyard machine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupedLogs, id: \.key) { group in
                    fuelLogGroup(group)
                }
            }
        } header: {
            sectionHeader(title: "Fuel Log", systemImage: "drop.circle.fill") {
                showAddFillSheet = true
            }
        } footer: {
            Text("Record fuel fills for Vineyard Machines and calculate usage over time.")
        }
    }

    @ViewBuilder
    private func fuelLogGroup(_ group: (key: String, header: String, logs: [TractorFuelLog])) -> some View {
        Text(group.header)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)

        ForEach(group.logs) { log in
            let previous = store.previousFuelLog(forMachineGroupOf: log, before: log.fillDateTime, excluding: log.id)
            let rate = TractorFuelRateCalculator.rate(current: log, previous: previous)
            let canEdit = canManageSetup || (log.operatorUserId != nil && log.operatorUserId == store.currentUserIdProvider?())
            Group {
                if canEdit {
                    Button { editingLog = log } label: { FuelLogRow(log: log, rate: rate) }
                } else {
                    FuelLogRow(log: log, rate: rate)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if canManageSetup {
                    Button(role: .destructive) {
                        store.deleteTractorFuelLog(log)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Shared header with blue circular add button

    @ViewBuilder
    private func sectionHeader(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
            Spacer()
            if canManageSetup {
                Button(action: action) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
