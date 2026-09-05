import SwiftUI

/// Sort options for the operational **Sprays** tab.
///
/// Date sorting lives here and only here. The Program tab uses
/// `SprayProgramStepSortOption`, which deliberately has no date option because
/// a reusable Program Step is not dated.
nonisolated enum SprayProgramSortOption: String, CaseIterable, Sendable {
    case newestFirst = "newest"
    case oldestFirst = "oldest"
    case elStageAscending = "elStageAsc"
    case elStageDescending = "elStageDesc"
    case nameAZ = "nameAZ"
    case nameZA = "nameZA"

    var label: String {
        switch self {
        case .newestFirst: return "Newest"
        case .oldestFirst: return "Oldest"
        case .elStageAscending: return "E-L Stage (Low \u{2192} High)"
        case .elStageDescending: return "E-L Stage (High \u{2192} Low)"
        case .nameAZ: return "Name (A\u{2013}Z)"
        case .nameZA: return "Name (Z\u{2013}A)"
        }
    }

    var icon: String {
        switch self {
        case .newestFirst, .oldestFirst: return "calendar"
        case .elStageAscending, .elStageDescending: return "leaf"
        case .nameAZ, .nameZA: return "textformat"
        }
    }
}

/// Operational record status. Unchanged semantics — only the *wording* of
/// `notStarted` changes in the UI, where it now reads "Upcoming".
nonisolated enum SprayStatusFilter: String, CaseIterable, Sendable {
    case all = "All"
    case templates = "Templates"
    case inProgress = "In Progress"
    case notStarted = "Not Started"
    case completed = "Completed"
}

/// The two halves of the Spray Program.
///
/// This is the whole point of the restructure: the vineyard's reusable program
/// and the sprays actually applied are different kinds of thing, and mixing
/// them behind one status filter made every reusable step look like a record
/// that had a date, a tank count and a completion state.
nonisolated enum SprayProgramTab: String, CaseIterable, Sendable, Identifiable {
    case program = "Program"
    case sprays = "Sprays"

    nonisolated var id: String { rawValue }
}

/// Operational sub-filter within Sprays. Presentation only — each case maps
/// onto the existing record semantics, and no backend status is added.
nonisolated enum SpraysStatusTab: String, CaseIterable, Sendable, Identifiable {
    case upcoming = "Upcoming"
    case inProgress = "In Progress"
    case completed = "Completed"
    case all = "All"

    nonisolated var id: String { rawValue }
}

struct SprayProgramView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SprayRecordSyncService.self) private var sprayRecordSync
    @Environment(SprayJobTemplateService.self) private var portalTemplates
    @Environment(\.accessControl) private var accessControl

    // Navigation
    /// Opens on Program: the master spray program is the primary landing view.
    @State private var tab: SprayProgramTab = .program
    @State private var spraysStatus: SpraysStatusTab = .all
    @State private var searchText: String = ""

    // Selection
    @State private var selectedRecord: SprayRecord?
    @State private var selectedStep: SprayProgramStep?
    /// The Program Step being taken into the guided calculator.
    @State private var planningStep: SprayProgramStep?
    @State private var recordToDelete: SprayRecord?

    // Creation routes
    @State private var showBlankCalculator: Bool = false
    @State private var showProgramStepForm: Bool = false
    @State private var showManualRecordForm: Bool = false
    @State private var showProgramPicker: Bool = false

    // Export
    @State private var sharePDFURL: ShareURL?
    @State private var isExporting: Bool = false
    @State private var exportError: String?

    @AppStorage("sprayProgramSortOption") private var sortOptionRaw: String = SprayProgramSortOption.newestFirst.rawValue
    /// Program defaults to phenological order, not date.
    @AppStorage("sprayProgramStepSortOption") private var programSortRaw: String = SprayProgramStepSortOption.elStageAscending.rawValue

    private var sortOption: SprayProgramSortOption {
        SprayProgramSortOption(rawValue: sortOptionRaw) ?? .newestFirst
    }

    private var programSortOption: SprayProgramStepSortOption {
        SprayProgramStepSortOption(rawValue: programSortRaw) ?? .elStageAscending
    }

    private var sortSelection: Binding<SprayProgramSortOption> {
        Binding(get: { sortOption }, set: { sortOptionRaw = $0.rawValue })
    }

    private var programSortSelection: Binding<SprayProgramStepSortOption> {
        Binding(get: { programSortOption }, set: { programSortRaw = $0.rawValue })
    }

    // MARK: - Program data source

    /// Local Program Steps (`spray_records` with `is_template`) merged with
    /// read-only portal steps (`spray_jobs`), deduped by id — the same merged
    /// source the existing pickers use. Portal records are never copied into
    /// the local collection.
    private var allProgramSteps: [SprayProgramStep] {
        SprayProgramCatalog.steps(
            localRecords: store.sprayRecords,
            portalRecords: portalTemplates.templateRecords,
            portalRows: portalTemplates.templates
        )
    }

    private var programSteps: [SprayProgramStep] {
        SprayProgramCatalog.sorted(
            SprayProgramCatalog.filtered(allProgramSteps, query: searchText),
            by: programSortOption
        )
    }

    // MARK: - Sprays data source

    private func tripForRecord(_ record: SprayRecord) -> Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    private func recordStatus(_ record: SprayRecord) -> SprayStatusFilter {
        if record.endTime != nil { return .completed }
        if let trip = tripForRecord(record), trip.isActive { return .inProgress }
        return .notStarted
    }

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
            let keyed = records.map { record -> (record: SprayRecord, stage: Int?) in
                let stage = ELStageParser.stageNumber(inText: record.sprayReference)
                    ?? ELStageParser.stageNumber(inText: record.notes)
                return (record, stage)
            }
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

    /// Operational spray records ONLY. Program Steps are never injected here.
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

    private var filteredSprays: [SprayRecord] {
        switch spraysStatus {
        case .all: return operationalRecords
        case .completed: return operationalRecords.filter { recordStatus($0) == .completed }
        case .inProgress: return operationalRecords.filter { recordStatus($0) == .inProgress }
        case .upcoming: return operationalRecords.filter { recordStatus($0) == .notStarted }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(SprayProgramTab.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 8)

                if tab == .sprays {
                    statusFilterStrip
                }

                List {
                    if tab == .program {
                        ForEach(programSteps) { step in
                            Button {
                                selectedStep = step
                            } label: {
                                SprayProgramStepRow(step: step, formatter: store.settings.regionFormatter)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Portal steps are managed in the admin portal —
                                // no delete on mobile. Unchanged boundary.
                                if (accessControl?.canDelete ?? false) && !step.isPortalManaged {
                                    Button(role: .destructive) {
                                        recordToDelete = step.record
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } else {
                        ForEach(filteredSprays) { sprayRow($0) }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Spray Program")
            .searchable(
                text: $searchText,
                prompt: tab == .program ? "Search program" : "Search sprays"
            )
            .onAppear {
                // Hydrate portal steps from the offline cache so Program is
                // populated before the next network sync.
                portalTemplates.loadCached(for: store.selectedVineyardId)
            }
            .toolbar { toolbarContent }
            .overlay { emptyState }
            .alert("Delete", isPresented: .init(
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
                Text("This cannot be undone.")
            }
            .sheet(item: $selectedRecord) { record in
                NavigationStack {
                    SprayRecordDetailView(record: record)
                }
            }
            .sheet(item: $selectedStep) { step in
                NavigationStack {
                    SprayProgramStepDetailView(step: step) { chosen in
                        selectedStep = nil
                        // Let the detail sheet finish dismissing before the
                        // calculator is presented.
                        DispatchQueue.main.async { planningStep = chosen }
                    }
                }
            }
            .sheet(item: $planningStep) { step in
                NavigationStack {
                    // THE shared Program -> Calculator route. Both the Program
                    // tab and the + menu land here, so there is exactly one
                    // prefill implementation.
                    SprayCalculatorView(
                        prefillRecord: step.record,
                        prefillProgram: step.calculatorPrefill
                    )
                }
            }
            .sheet(isPresented: $showBlankCalculator) {
                NavigationStack { SprayCalculatorView() }
            }
            .sheet(isPresented: $showProgramStepForm) {
                NavigationStack {
                    SprayRecordFormView(
                        tripId: UUID(),
                        paddockIds: [],
                        createsProgramStep: true
                    )
                }
            }
            .sheet(isPresented: $showManualRecordForm) {
                NavigationStack {
                    SprayRecordFormView(tripId: UUID(), paddockIds: [])
                }
            }
            .sheet(isPresented: $showProgramPicker) {
                SprayProgramStepPickerSheet(steps: allProgramSteps) { chosen in
                    DispatchQueue.main.async { planningStep = chosen }
                }
            }
            .sheet(item: $sharePDFURL) { wrapper in
                ShareSheet(items: [wrapper.url])
            }
            .alert("Export Failed", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    // MARK: - Status strip (Sprays only)

    private var statusFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SpraysStatusTab.allCases) { filter in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { spraysStatus = filter }
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(spraysStatus == filter ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(spraysStatus == filter ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                            .foregroundStyle(spraysStatus == filter ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .contentMargins(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                createMenu
                optionsMenu
            }
        }
    }

    /// The + no longer drops straight into a blank calculator. Planning from
    /// the program is the primary workflow; manual record entry is last.
    private var createMenu: some View {
        Menu {
            Button {
                showProgramPicker = true
            } label: {
                Label("Plan from Program", systemImage: "list.bullet.rectangle.portrait")
            }
            .disabled(allProgramSteps.isEmpty)

            Button {
                showBlankCalculator = true
            } label: {
                Label("One-off Spray", systemImage: "drop.fill")
            }

            Divider()

            Button {
                showProgramStepForm = true
            } label: {
                Label("Add Program Step", systemImage: "plus.rectangle.on.folder")
            }

            Button {
                showManualRecordForm = true
            } label: {
                Label("Log Spray Record", systemImage: "square.and.pencil")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    private var optionsMenu: some View {
        Menu {
            if tab == .program {
                Picker("Sort By", selection: programSortSelection) {
                    ForEach(SprayProgramStepSortOption.allCases, id: \.self) { option in
                        Label(option.label, systemImage: option.icon).tag(option)
                    }
                }
            } else {
                Picker("Sort By", selection: sortSelection) {
                    ForEach(SprayProgramSortOption.allCases, id: \.self) { option in
                        Label(option.label, systemImage: option.icon).tag(option)
                    }
                }
            }

            // Exports describe APPLICATIONS, so they stay attached to the
            // operational record set regardless of which tab is showing.
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
                    exportImportCSV()
                } label: {
                    // Named for what it is — a blank import sheet. "Template"
                    // now means a Program Step everywhere else in this screen.
                    Label("Download Import CSV", systemImage: "arrow.down.doc")
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

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        if tab == .program && programSteps.isEmpty {
            ContentUnavailableView {
                Label("No Program Steps", systemImage: "list.bullet.rectangle.portrait")
            } description: {
                Text("Build your vineyard spray program by adding reusable spray steps, or create them in the Admin Portal.")
            } actions: {
                if searchText.isEmpty {
                    Button {
                        showProgramStepForm = true
                    } label: {
                        Label("Add Program Step", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else if tab == .sprays && filteredSprays.isEmpty {
            ContentUnavailableView {
                Label("No Sprays", systemImage: "drop")
            } description: {
                Text("Plan a spray from your Program or create a one-off spray.")
            } actions: {
                Button {
                    if allProgramSteps.isEmpty {
                        showBlankCalculator = true
                    } else {
                        showProgramPicker = true
                    }
                } label: {
                    Label("Plan Spray", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Sprays row

    @ViewBuilder
    private func sprayRow(_ record: SprayRecord) -> some View {
        let trip = tripForRecord(record)
        let status = recordStatus(record)

        Button {
            selectedRecord = record
        } label: {
            HStack {
                statusIcon(status: status)

                VStack(alignment: .leading, spacing: 5) {
                    if !record.sprayReference.isEmpty {
                        Text(record.sprayReference)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }

                    Label(
                        record.date.formattedTZ(date: .abbreviated, time: .omitted, in: store.settings.resolvedTimeZone),
                        systemImage: "calendar"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let blocks = blockSummary(record, trip: trip) {
                        Label { Text(blocks) } icon: { GrapeLeafIcon(size: 12) }
                            .font(.caption)
                            .foregroundStyle(VineyardTheme.olive)
                    }

                    let chemicalNames = record.tanks.flatMap { $0.chemicals }
                        .map(\.name)
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
                    Text(statusLabel(status))
                        .font(.caption2.weight(.medium))
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
        .buttonStyle(.plain)
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

    /// Recorded block attribution first (sql/195), the linked trip's label only
    /// as a fallback — never the vineyard's current blocks.
    private func blockSummary(_ record: SprayRecord, trip: Trip?) -> String? {
        let recorded = SprayBlockAttributionDisplay.namesCell(
            record.applicationGeometry?.blocks,
            paddocks: store.paddocks
        )
        if !recorded.isEmpty { return recorded }
        let name = trip?.paddockName ?? ""
        return name.isEmpty ? nil : name
    }

    private func statusLabel(_ status: SprayStatusFilter) -> String {
        switch status {
        case .completed: return "Completed"
        case .inProgress: return "In Progress"
        default: return "Upcoming"
        }
    }

    @ViewBuilder
    private func statusIcon(status: SprayStatusFilter) -> some View {
        switch status {
        case .inProgress:
            Image(systemName: "record.circle")
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 28)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(VineyardTheme.leafGreen)
                .frame(width: 28)
        default:
            Image(systemName: "clock")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
        }
    }

    // MARK: - Export

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
            tractors: includeCostings ? store.currentTractors : [],
            fuelPurchases: includeCostings ? store.currentFuelPurchases : [],
            operatorCategories: includeCostings ? store.operatorCategories : [],
            operatorCategoryForName: includeCostings ? { store.operatorCategoryForName($0) } : nil,
            savedChemicals: includeCostings ? store.savedChemicals : [],
            paddocks: includeCostings ? store.paddocks : [],
            historicalYieldRecords: includeCostings ? store.historicalYieldRecords : []
        )
        sharePDFURL = ShareURL(url: url)
    }

    private func exportImportCSV() {
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
        // Reference data for resolving the exported records' own equipment.
        // The records being exported all belong to the selected vineyard, so
        // the selected-vineyard slice is the correct — and only safe — lookup
        // table here.
        let tractors = store.currentTractors
        let machines = store.currentVineyardMachines
        let sprayEquipment = store.sprayEquipment
        let fuelCost = store.seasonFuelCostPerLitre
        let operatorCategories = store.operatorCategories
        let users = store.selectedVineyard?.users ?? []
        let includeCostings = accessControl?.canViewFinancials ?? false
        let exportTimeZone = store.settings.resolvedTimeZone
        let formatter = store.settings.regionFormatter
        let tankActuals = SprayTankActualStore.shared.records.filter { actual in records.contains { $0.id == actual.sprayRecordId } }

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
                tankActuals: tankActuals,
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
}
