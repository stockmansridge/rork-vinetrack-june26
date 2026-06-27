import SwiftUI

nonisolated enum SprayProgramSortOption: String, CaseIterable, Sendable {
    case date = "Date"
    case name = "Name"
}

nonisolated enum SprayStatusFilter: String, CaseIterable, Sendable {
    case all = "All"
    case inProgress = "In Progress"
    case notStarted = "Not Started"
    case completed = "Completed"
    case templates = "Templates"
}

struct SprayProgramView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SprayRecordSyncService.self) private var sprayRecordSync
    @Environment(\.accessControl) private var accessControl

    @State private var selectedRecord: SprayRecord?
    @State private var searchText: String = ""
    @State private var sortOption: SprayProgramSortOption = .date
    @State private var statusFilter: SprayStatusFilter = .all
    @State private var recordToDelete: SprayRecord?
    @State private var showCreateForm: Bool = false
    @State private var sharePDFURL: ShareURL?
    @State private var isExporting: Bool = false
    @State private var exportError: String?

    private func tripForRecord(_ record: SprayRecord) -> Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    private var operationalRecords: [SprayRecord] {
        var records = store.sprayRecords.filter { !$0.isTemplate }
        if !searchText.isEmpty {
            records = records.filter { record in
                let trip = tripForRecord(record)
                let paddockName = trip?.paddockName ?? ""
                let chemicalNames = record.tanks.flatMap { $0.chemicals }.map { $0.name }.joined(separator: " ")
                let combined = "\(record.sprayReference) \(paddockName) \(chemicalNames) \(record.notes) \(record.equipmentType)"
                return combined.localizedStandardContains(searchText)
            }
        }
        switch sortOption {
        case .date:
            records.sort { $0.date > $1.date }
        case .name:
            records.sort { $0.sprayReference.lowercased() < $1.sprayReference.lowercased() }
        }
        return records
    }

    private var templateRecords: [SprayRecord] {
        var records = store.sprayRecords.filter { $0.isTemplate }
        if !searchText.isEmpty {
            records = records.filter { record in
                let chemicalNames = record.tanks.flatMap { $0.chemicals }.map { $0.name }.joined(separator: " ")
                let combined = "\(record.sprayReference) \(chemicalNames) \(record.notes)"
                return combined.localizedStandardContains(searchText)
            }
        }
        return records.sorted { $0.sprayReference.lowercased() < $1.sprayReference.lowercased() }
    }

    private func recordStatus(_ record: SprayRecord) -> SprayStatusFilter {
        if record.endTime != nil { return .completed }
        if let trip = tripForRecord(record), trip.isActive { return .inProgress }
        return .notStarted
    }

    private var filteredRecords: [SprayRecord] {
        switch statusFilter {
        case .all: return operationalRecords
        case .completed: return operationalRecords.filter { recordStatus($0) == .completed }
        case .inProgress: return operationalRecords.filter { recordStatus($0) == .inProgress }
        case .notStarted: return operationalRecords.filter { recordStatus($0) == .notStarted }
        case .templates: return []
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SprayStatusFilter.allCases, id: \.self) { filter in
                            Button {
                                withAnimation(.snappy(duration: 0.2)) { statusFilter = filter }
                            } label: {
                                Text(filter.rawValue)
                                    .font(.subheadline.weight(statusFilter == filter ? .semibold : .regular))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(statusFilter == filter ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                                    .foregroundStyle(statusFilter == filter ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 16)
                .padding(.vertical, 8)

                List {
                    if statusFilter == .templates {
                        ForEach(templateRecords) { recordRow($0) }
                    } else {
                        if statusFilter == .all && !templateRecords.isEmpty {
                            Section {
                                ForEach(templateRecords) { recordRow($0) }
                            } header: {
                                Label("Templates", systemImage: "doc.on.doc")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        ForEach(filteredRecords) { recordRow($0) }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Spray Program")
            .searchable(text: $searchText, prompt: "Search spray records")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showCreateForm = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        if !filteredRecords.isEmpty {
                            Menu {
                                Picker("Sort By", selection: $sortOption) {
                                    ForEach(SprayProgramSortOption.allCases, id: \.self) { option in
                                        Label(option.rawValue, systemImage: option == .date ? "calendar" : "textformat")
                                            .tag(option)
                                    }
                                }
                                Section("Export") {
                                    Button {
                                        exportCSV()
                                    } label: {
                                        Label("Export CSV", systemImage: "tablecells")
                                    }
                                    Button {
                                        exportProgramPDF()
                                    } label: {
                                        Label("Export PDF", systemImage: "doc.richtext")
                                    }
                                    Button {
                                        exportTemplate()
                                    } label: {
                                        Label("CSV Template", systemImage: "doc.badge.plus")
                                    }
                                }
                            } label: {
                                if isExporting {
                                    ProgressView()
                                } else {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if statusFilter == .templates && templateRecords.isEmpty {
                    ContentUnavailableView {
                        Label("No Templates", systemImage: "doc.on.doc")
                    } description: {
                        Text("Mark a spray record as a template to reuse it for future trips.")
                    }
                } else if statusFilter != .templates && filteredRecords.isEmpty && templateRecords.isEmpty {
                    ContentUnavailableView {
                        Label("No Spray Records", systemImage: "list.bullet.clipboard")
                    } description: {
                        Text("Tap + to create a spray record.")
                    }
                }
            }
            .alert("Delete Spray Record", isPresented: .init(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let record = recordToDelete {
                        store.deleteSprayRecord(record)
                    }
                    recordToDelete = nil
                }
                Button("Cancel", role: .cancel) { recordToDelete = nil }
            } message: {
                Text("Are you sure you want to delete this spray record? This action cannot be undone.")
            }
            .sheet(item: $selectedRecord) { record in
                NavigationStack {
                    SprayRecordDetailView(record: record)
                }
            }
            .sheet(isPresented: $showCreateForm) {
                NavigationStack {
                    SprayCalculatorView()
                }
            }
            .sheet(item: $sharePDFURL) { wrapper in
                ShareSheet(items: [wrapper.url])
            }
            .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    private func exportCSV() {
        // Costing columns are only included for owner/manager. Supervisors and
        // operators receive a CSV without any pricing columns.
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let includeCostings = accessControl?.canViewCosting ?? false
        let url = SprayProgramCSVService.exportRecords(
            records: operationalRecords,
            trips: store.trips,
            vineyardName: vineyardName,
            timeZone: store.settings.resolvedTimeZone,
            includeCostings: includeCostings,
            tractors: includeCostings ? store.tractors : [],
            fuelPurchases: includeCostings ? store.fuelPurchases : [],
            operatorCategories: includeCostings ? store.operatorCategories : [],
            operatorCategoryForName: includeCostings ? { store.operatorCategoryForName($0) } : nil,
            savedChemicals: includeCostings ? store.savedChemicals : [],
            paddocks: includeCostings ? store.paddocks : [],
            historicalYieldRecords: includeCostings ? store.historicalYieldRecords : []
        )
        sharePDFURL = ShareURL(url: url)
    }

    private func exportTemplate() {
        let url = SprayProgramCSVService.generateTemplate()
        sharePDFURL = ShareURL(url: url)
    }

    private func exportProgramPDF() {
        guard !isExporting else { return }
        isExporting = true
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let logoData = store.selectedVineyard?.logoData
        let records = operationalRecords
        let trips = store.trips
        let paddocks = store.paddocks
        let tractors = store.tractors
        let machines = store.vineyardMachines
        let sprayEquipment = store.sprayEquipment
        let fuelCost = store.seasonFuelCostPerLitre
        let operatorCategories = store.operatorCategories
        let users = store.selectedVineyard?.users ?? []
        let includeCostings = accessControl?.canViewFinancials ?? false
        let exportTimeZone = store.settings.resolvedTimeZone
        let formatter = store.settings.regionFormatter

        Task.detached {
            let url = SprayProgramExportService.generateProgramPDF(
                records: records,
                trips: trips,
                paddocks: paddocks,
                vineyardName: vineyardName,
                logoData: logoData,
                tractors: tractors,
                machines: machines,
                sprayEquipment: sprayEquipment,
                seasonFuelCostPerLitre: fuelCost,
                operatorCategories: operatorCategories,
                vineyardUsers: users,
                includeCostings: includeCostings,
                timeZone: exportTimeZone,
                formatter: formatter
            )
            await MainActor.run {
                sharePDFURL = ShareURL(url: url)
                isExporting = false
            }
        }
    }

    @ViewBuilder
    private func recordRow(_ record: SprayRecord) -> some View {
        let trip = tripForRecord(record)
        let status = recordStatus(record)

        Button {
            selectedRecord = record
        } label: {
            HStack {
                statusIcon(record: record, status: status)

                VStack(alignment: .leading, spacing: 5) {
                    if !record.sprayReference.isEmpty {
                        Text(record.sprayReference)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }

                    Label(record.date.formattedTZ(date: .abbreviated, time: .omitted, in: store.settings.resolvedTimeZone), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let paddockName = trip?.paddockName, !paddockName.isEmpty {
                        Label { Text(paddockName) } icon: { GrapeLeafIcon(size: 12) }
                            .font(.caption)
                            .foregroundStyle(VineyardTheme.olive)
                    }

                    let chemicalNames = record.tanks.flatMap { $0.chemicals }
                        .map { $0.name }
                        .filter { !$0.isEmpty }
                    if !chemicalNames.isEmpty {
                        Text(chemicalNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(record.tanks.count) tank\(record.tanks.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    RecordSyncBadge(
                        state: RecordSyncState.forSprayRecord(record.id, spraySync: sprayRecordSync),
                        showsLabel: false
                    )
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if accessControl?.canDelete ?? false {
                Button(role: .destructive) {
                    recordToDelete = record
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(record: SprayRecord, status: SprayStatusFilter) -> some View {
        if record.isTemplate {
            Image(systemName: "doc.on.doc.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 28)
        } else if status == .inProgress {
            Image(systemName: "record.circle")
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 28)
        } else if status == .notStarted {
            Image(systemName: "clock")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
        } else if status == .completed {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(VineyardTheme.leafGreen)
                .frame(width: 28)
        }
    }
}
