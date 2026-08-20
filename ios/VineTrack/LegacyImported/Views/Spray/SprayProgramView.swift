import SwiftUI

nonisolated enum SprayProgramSortOption: String, CaseIterable, Sendable {
    case elStageAscending = "elStageAsc"
    case elStageDescending = "elStageDesc"
    case newestFirst = "newest"
    case oldestFirst = "oldest"
    case nameAZ = "nameAZ"
    case nameZA = "nameZA"

    var label: String {
        switch self {
        case .elStageAscending: return "E-L Stage (Low \u{2192} High)"
        case .elStageDescending: return "E-L Stage (High \u{2192} Low)"
        case .newestFirst: return "Newest"
        case .oldestFirst: return "Oldest"
        case .nameAZ: return "Name (A\u{2013}Z)"
        case .nameZA: return "Name (Z\u{2013}A)"
        }
    }

    var icon: String {
        switch self {
        case .elStageAscending, .elStageDescending: return "leaf"
        case .newestFirst, .oldestFirst: return "calendar"
        case .nameAZ, .nameZA: return "textformat"
        }
    }
}

/// Extracts a numeric E-L (Eichhorn–Lorenz) stage for sorting.
///
/// "EL12", "EL 12", "E-L 12" and "el-7" all resolve to their stage number, so
/// sorting follows the real phenological order (EL 7 < EL 12 < EL 31) rather
/// than the alphabetical order of the display text ("EL 12" < "EL 7").
nonisolated enum ELStageParser {
    /// Parse a canonical `growth_stage_code` such as "EL12".
    static func stageNumber(fromCode code: String?) -> Int? {
        guard let code, !code.isEmpty else { return nil }
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 3, let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// Scan free text (spray reference / notes) for an E-L mention.
    static func stageNumber(inText text: String) -> Int? {
        let chars = Array(text.lowercased())
        var i = 0
        while i < chars.count {
            guard chars[i] == "e" else { i += 1; continue }
            // "EL" must start a word — the preceding character can't be
            // alphanumeric (avoids matching "Model 3", "Diesel 5", ...).
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { i += 1; continue }
            var j = i + 1
            if j < chars.count, chars[j] == "-" { j += 1 }
            guard j < chars.count, chars[j] == "l" else { i += 1; continue }
            j += 1
            while j < chars.count, chars[j] == " " || chars[j] == "-" || chars[j] == "." { j += 1 }
            var digits = ""
            while j < chars.count, chars[j].isNumber, digits.count < 3 {
                digits.append(chars[j])
                j += 1
            }
            if let value = Int(digits), value > 0 { return value }
            i = max(j, i + 1)
        }
        return nil
    }
}

nonisolated enum SprayStatusFilter: String, CaseIterable, Sendable {
    // Order defines the tab order: Templates sits immediately after All
    // because Templates hold the vineyard's master spray program.
    case all = "All"
    case templates = "Templates"
    case inProgress = "In Progress"
    case notStarted = "Not Started"
    case completed = "Completed"
}

struct SprayProgramView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SprayRecordSyncService.self) private var sprayRecordSync
    @Environment(SprayJobTemplateService.self) private var portalTemplates
    @Environment(\.accessControl) private var accessControl

    @State private var selectedRecord: SprayRecord?
    @State private var searchText: String = ""
    /// Persisted so the chosen sort survives tab switches and view reloads
    /// while working in the Spray Program.
    @AppStorage("sprayProgramSortOption") private var sortOptionRaw: String = SprayProgramSortOption.newestFirst.rawValue
    @State private var statusFilter: SprayStatusFilter = .all
    @State private var recordToDelete: SprayRecord?
    @State private var showCreateForm: Bool = false
    @State private var sharePDFURL: ShareURL?
    @State private var isExporting: Bool = false
    @State private var exportError: String?

    private var sortOption: SprayProgramSortOption {
        SprayProgramSortOption(rawValue: sortOptionRaw) ?? .newestFirst
    }

    private var sortSelection: Binding<SprayProgramSortOption> {
        Binding(
            get: { sortOption },
            set: { sortOptionRaw = $0.rawValue }
        )
    }

    private func tripForRecord(_ record: SprayRecord) -> Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    /// Portal templates carry the canonical E-L code
    /// (`spray_jobs.growth_stage_code`) — the authoritative stage for the
    /// vineyard's master program rows.
    private var portalTemplateStageByID: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for template in portalTemplates.templates {
            if let value = ELStageParser.stageNumber(fromCode: template.growthStageCode) {
                map[template.id] = value
            }
        }
        return map
    }

    private func elStageValue(for record: SprayRecord, stageByID: [UUID: Int]) -> Int? {
        if let mapped = stageByID[record.id] { return mapped }
        if let fromReference = ELStageParser.stageNumber(inText: record.sprayReference) { return fromReference }
        return ELStageParser.stageNumber(inText: record.notes)
    }

    /// Applies the selected sort. E-L sorts numerically by actual stage value;
    /// records with no known stage always sink to the bottom in either
    /// direction (newest-first among themselves).
    private func applySort(_ records: [SprayRecord]) -> [SprayRecord] {
        switch sortOption {
        case .newestFirst:
            return records.sorted { $0.date > $1.date }
        case .oldestFirst:
            return records.sorted { $0.date < $1.date }
        case .nameAZ:
            return records.sorted { $0.sprayReference.lowercased() < $1.sprayReference.lowercased() }
        case .nameZA:
            return records.sorted { $0.sprayReference.lowercased() > $1.sprayReference.lowercased() }
        case .elStageAscending, .elStageDescending:
            let ascending = sortOption == .elStageAscending
            let stageByID = portalTemplateStageByID
            let keyed = records.map { (record: $0, stage: elStageValue(for: $0, stageByID: stageByID)) }
            return keyed.sorted { a, b in
                switch (a.stage, b.stage) {
                case let (x?, y?) where x != y:
                    return ascending ? x < y : x > y
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return a.record.date > b.record.date
                }
            }.map(\.record)
        }
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
        return applySort(records)
    }

    /// Merged template list: legacy templates stored in `spray_records` plus
    /// read-only portal templates from `spray_jobs` (Lovable-created), deduped
    /// by id — the same source the Start from Template pickers use.
    private var templateRecords: [SprayRecord] {
        let local = store.sprayRecords.filter { $0.isTemplate }
        let localIds = Set(local.map(\.id))
        let portal = portalTemplates.templateRecords.filter { !localIds.contains($0.id) }
        var records = local + portal
        if !searchText.isEmpty {
            records = records.filter { record in
                let chemicalNames = record.tanks.flatMap { $0.chemicals }.map { $0.name }.joined(separator: " ")
                let combined = "\(record.sprayReference) \(chemicalNames) \(record.notes)"
                return combined.localizedStandardContains(searchText)
            }
        }
        return applySort(records)
    }

    /// Portal templates come from `spray_jobs` and are read-only on mobile.
    private func isPortalTemplate(_ record: SprayRecord) -> Bool {
        !store.sprayRecords.contains(where: { $0.id == record.id }) &&
            portalTemplates.templateRecords.contains(where: { $0.id == record.id })
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
            .onAppear {
                // Hydrate portal templates from the offline cache so the
                // Templates tab is populated even before the next network sync.
                portalTemplates.loadCached(for: store.selectedVineyardId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showCreateForm = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        if !filteredRecords.isEmpty || !templateRecords.isEmpty {
                            Menu {
                                Picker("Sort By", selection: sortSelection) {
                                    ForEach(SprayProgramSortOption.allCases, id: \.self) { option in
                                        Label(option.label, systemImage: option.icon)
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
                        Text("Create templates in the admin portal or mark a spray record as a template to reuse it for future spray jobs.")
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

                    if isPortalTemplate(record) {
                        Label("Admin portal template", systemImage: "lock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
            // Portal templates are managed in the admin portal — no delete on mobile.
            if (accessControl?.canDelete ?? false) && !isPortalTemplate(record) {
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
