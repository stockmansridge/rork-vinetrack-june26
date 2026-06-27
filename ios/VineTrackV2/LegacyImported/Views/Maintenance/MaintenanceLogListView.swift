import SwiftUI

struct MaintenanceLogListView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(MaintenanceLogSyncService.self) private var maintenanceLogSync
    @Environment(\.accessControl) private var accessControl

    @State private var showAddLog: Bool = false
    @State private var searchText: String = ""
    @State private var selectedLog: MaintenanceLog?

    private var filteredLogs: [MaintenanceLog] {
        let sorted = store.maintenanceLogs.sorted { $0.date > $1.date }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            store.resolvedMaintenanceItemName($0).localizedStandardContains(searchText) ||
            $0.itemName.localizedStandardContains(searchText) ||
            $0.workCompleted.localizedStandardContains(searchText) ||
            $0.partsUsed.localizedStandardContains(searchText)
        }
    }

    private var totalPartsCost: Double {
        store.maintenanceLogs.reduce(0) { $0 + $1.partsCost }
    }

    private var totalLabourCost: Double {
        store.maintenanceLogs.reduce(0) { $0 + $1.labourCost }
    }

    private var totalHours: Double {
        store.maintenanceLogs.reduce(0) { $0 + $1.hours }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if accessControl?.canViewFinancials ?? false {
                    costSummaryCard
                } else {
                    simpleSummaryCard
                }
                logsList
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Maintenance Log")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search logs...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddLog = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddLog) {
            AddEditMaintenanceLogView()
        }
        .sheet(item: $selectedLog) { log in
            MaintenanceLogDetailView(log: log)
        }
        .refreshable {
            await maintenanceLogSync.syncForSelectedVineyard()
        }
    }

    private var simpleSummaryCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title3)
                .foregroundStyle(VineyardTheme.earthBrown)
                .frame(width: 40, height: 40)
                .background(VineyardTheme.earthBrown.opacity(0.12), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.maintenanceLogs.count) record\(store.maintenanceLogs.count == 1 ? "" : "s")")
                    .font(.headline)
                Text(String(format: "%.1f total hours logged", totalHours))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var costSummaryCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cost Summary")
                        .font(.title3.weight(.bold))
                    Text("\(store.maintenanceLogs.count) record\(store.maintenanceLogs.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fmt.formatCurrency(totalPartsCost + totalLabourCost))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(VineyardTheme.earthBrown)
                }
            }
            .padding(.bottom, 16)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                summaryMetric(
                    value: totalPartsCost,
                    label: "Parts",
                    icon: "wrench.and.screwdriver",
                    color: .orange
                )
                summaryMetric(
                    value: totalLabourCost,
                    label: "Labour",
                    icon: "person.fill",
                    color: .blue
                )
                hourMetric(
                    value: totalHours,
                    label: "Hours",
                    icon: "clock.fill",
                    color: VineyardTheme.olive
                )
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func summaryMetric(value: Double, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(fmt.formatCurrency(value))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func hourMetric(value: Double, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(String(format: "%.1f", value))
                .font(.subheadline.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var logsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if filteredLogs.isEmpty {
                emptyState
            } else {
                ForEach(filteredLogs) { log in
                    logRow(log)
                }
            }
        }
    }

    private func logRow(_ log: MaintenanceLog) -> some View {
        Button {
            selectedLog = log
        } label: {
            HStack(spacing: 14) {
                VStack {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .background(VineyardTheme.earthBrown.gradient, in: .rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.resolvedMaintenanceItemName(log))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(log.workCompleted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        Label(String(format: "%.1fh", log.hours), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if let mh = log.machineHours {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Label(String(format: "%.0f mh", mh), systemImage: "gauge.with.dots.needle.67percent")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if log.totalCost > 0 && (accessControl?.canViewFinancials ?? false) {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(fmt.formatCurrency(log.totalCost))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(VineyardTheme.earthBrown)
                        }

                        if log.invoicePhotoData != nil {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Image(systemName: "doc.text.image")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(fmt.formatDate(log.date))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Maintenance Records")
                .font(.headline)
            Text("Tap + to log maintenance work on machinery, pumps, or equipment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }
}
