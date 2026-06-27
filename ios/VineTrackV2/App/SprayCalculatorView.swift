import SwiftUI
import CoreLocation

enum GrowthStageMode: String, CaseIterable {
    case same
    case perPaddock
}

/// Backend-safe Spray Calculator.
///
/// Restores the original spray-job setup workflow visually and functionally:
/// paddock selection, operation type, growth stage, equipment, water rate
/// (canopy size + density + row spacing), chemicals (rate per ha or per 100L),
/// optional manual weather, notes, calculation results and (when permitted)
/// costing summary.
///
/// Wired only to MigratedDataStore + TripTrackingService + BackendAccessControl.
/// No DataStore, AuthService, CloudSyncService, SupabaseManager or
/// WeatherDataService imports.
struct SprayCalculatorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripTrackingService.self) private var tracking
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(LocationService.self) private var locationService
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    // Selection
    @State private var sprayName: String = ""
    @State private var operationType: OperationType = .foliarSpray
    @State private var selectedPaddockIds: Set<UUID> = []
    @State private var selectedEquipmentId: UUID?
    @State private var selectedTractorId: UUID?
    @State private var canopySize: CanopySize = .medium
    @State private var canopyDensity: CanopyDensity = .low
    @State private var sharedGrowthStageId: UUID?
    @State private var growthStageMode: GrowthStageMode = .same
    @State private var paddockPhenologyStages: [UUID: UUID] = [:]
    @State private var chemicalLines: [ChemicalLine] = []
    @State private var showAddChemicalToList: Bool = false
    @State private var sprayRateText: String = ""
    @State private var hasEditedSprayRate: Bool = false
    @State private var notes: String = ""

    // Trip setup
    @State private var numberOfFansJets: String = ""
    @State private var trackingPatternChoice: TrackingPattern = .sequential
    /// Selected start path across the multi-block selection. Path X.5 sits
    /// between rows X and X+1; defaults snap to the first available path in
    /// `clampStartPath()` whenever the paddock selection changes.
    @State private var startPath: Double = 0.5
    /// Sequence direction. `true` = lower rows first (ascending), `false` =
    /// higher rows first (descending). Mirrors `StartTripSheet`'s
    /// `directionHigherFirst` so both flows share semantics.
    @State private var directionHigherFirst: Bool = true

    // Captured at job start
    @State private var capturedTemperature: Double?
    @State private var capturedWindSpeed: Double?
    @State private var capturedWindDirection: String = ""
    @State private var capturedHumidity: Double?

    // UI
    @State private var isPaddocksExpanded: Bool = true
    @State private var isEquipmentExpanded: Bool = true
    @State private var isGrowthStageExpanded: Bool = false
    @State private var showAddEquipment: Bool = false
    @State private var showSprayPaddockPicker: Bool = false
    @State private var calculationResult: SprayCalculationResult?
    @State private var showResults: Bool = false
    @State private var showSummary: Bool = false
    @State private var summaryMode: SprayCalculationSummaryMode = .savedForLater
    @State private var pendingTanks: [SprayTank] = []
    @State private var savedFeedback: Bool = false
    @State private var errorMessage: String?
    @State private var showStartConfirmation: Bool = false
    @State private var isStartingJob: Bool = false
    @State private var showWeatherDataSettings: Bool = false

    // Prefill (duplicate / template)
    private let prefillRecord: SprayRecord?
    @State private var prefillApplied: Bool = false

    init(prefillRecord: SprayRecord? = nil) {
        self.prefillRecord = prefillRecord
        if let r = prefillRecord {
            let baseName = r.sprayReference.isEmpty ? "" : r.sprayReference
            let prefilledName: String = {
                if r.isTemplate { return baseName }
                return baseName.isEmpty ? "" : "\(baseName) (Copy)"
            }()
            _sprayName = State(initialValue: prefilledName)
            _operationType = State(initialValue: r.operationType)
            _notes = State(initialValue: r.notes)
            _numberOfFansJets = State(initialValue: r.numberOfFansJets)
            if let firstTank = r.tanks.first, firstTank.sprayRatePerHa > 0 {
                _sprayRateText = State(initialValue: String(format: "%.0f", firstTank.sprayRatePerHa))
                _hasEditedSprayRate = State(initialValue: true)
            }
        }
    }

    // MARK: - Computed

    private var phenologyStages: [PhenologyStage] { PhenologyStage.allStages }

    private var selectedPaddocks: [Paddock] {
        store.paddocks.filter { selectedPaddockIds.contains($0.id) }
    }

    private var totalAreaHectares: Double {
        selectedPaddocks.reduce(0) { $0 + $1.areaHectares }
    }

    private var totalRowsAcrossSelection: Int {
        selectedPaddocks.reduce(0) { $0 + $1.rows.count }
    }

    private var totalVinesAcrossSelection: Int {
        selectedPaddocks.reduce(0) { $0 + $1.effectiveVineCount }
    }

    private var sharedGrowthStage: PhenologyStage? {
        guard let id = sharedGrowthStageId else { return nil }
        return phenologyStages.first(where: { $0.id == id })
    }

    private var growthStageSummary: String {
        if selectedPaddockIds.isEmpty { return "Select blocks first" }
        if growthStageMode == .same {
            if let stage = sharedGrowthStage {
                return "\(stage.code) — \(stage.name)"
            }
            return "Not set"
        }
        let count = paddockPhenologyStages.values.filter { _ in true }.count
        let assigned = selectedPaddockIds.compactMap { paddockPhenologyStages[$0] }.count
        return "Per block — \(assigned)/\(selectedPaddockIds.count) assigned (\(count >= 0 ? "" : ""))"
    }

    private var averageRowSpacing: Double {
        guard !selectedPaddocks.isEmpty else { return 2.5 }
        return selectedPaddocks.reduce(0) { $0 + $1.rowSpacingMetres } / Double(selectedPaddocks.count)
    }

    private var waterRateEntry: CanopyWaterRate.RateEntry {
        CanopyWaterRate.rate(
            size: canopySize,
            density: canopyDensity,
            rowSpacingMetres: averageRowSpacing,
            settings: store.settings.canopyWaterRates
        )
    }

    private var chosenSprayRate: Double {
        Double(sprayRateText) ?? waterRateEntry.litresPerHa
    }

    private var concentrationFactor: Double {
        guard chosenSprayRate > 0 else { return 1.0 }
        return waterRateEntry.litresPerHa / chosenSprayRate
    }

    private var formIsValid: Bool {
        !selectedPaddockIds.isEmpty && selectedEquipmentId != nil && !chemicalLines.isEmpty
    }

    /// Sorted set of selected paddocks (lowest-row-first), matching
    /// `StartTripSheet`. Drives every multi-block computation below.
    private var orderedSelectedPaddocks: [Paddock] {
        selectedPaddocks.sorted(by: TripRowSequencePlanner.rowOrderSort)
    }

    /// Total row count across every selected block. Replaces the old
    /// single-block `totalPreviewRows`.
    private var combinedTotalRows: Int {
        TripRowSequencePlanner.combinedTotalRows(in: orderedSelectedPaddocks)
    }

    /// Whether the selection has any row geometry at all.
    private var hasAnyRowGeometry: Bool {
        TripRowSequencePlanner.hasAnyRowGeometry(orderedSelectedPaddocks)
    }

    /// Available start paths across the full selection (e.g. 68.5, 69.5, ...).
    private var availablePaths: [Double] {
        TripRowSequencePlanner.availablePaths(in: orderedSelectedPaddocks)
    }

    /// Proposed row sequence shared by the preview card and trip start.
    private var pathSequencePreview: [Double] {
        guard hasAnyRowGeometry, trackingPatternChoice != .freeDrive else { return [] }
        return TripRowSequencePlanner.generateSequence(
            paddocks: orderedSelectedPaddocks,
            pattern: trackingPatternChoice,
            startPath: startPath,
            directionHigherFirst: directionHigherFirst
        )
    }

    private var selectedTractorName: String {
        selectedTractorId.flatMap { id in
            store.tractors.first(where: { $0.id == id })?.displayName
        } ?? "Not selected"
    }

    private var selectedEquipmentName: String {
        selectedEquipmentId.flatMap { id in
            store.sprayEquipment.first(where: { $0.id == id })?.name
        } ?? "Not selected"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    sprayNameSection
                    operationTypeSection
                    paddockSelection
                    growthStageSection
                    equipmentSelection
                    waterRateSection
                    chemicalLinesSection
                    notesSection
                    actionButtons

                    if showResults, let result = calculationResult {
                        ResultsCard(result: result)
                        if let costing = result.costingSummary, accessControl.canViewFinancials {
                            CostingsCard(summary: costing)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Spray Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.success, trigger: savedFeedback)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .sheet(isPresented: $showSummary, onDismiss: { dismiss() }) {
                if let result = calculationResult {
                    SprayCalculationSummarySheet(
                        result: result,
                        sprayName: sprayName,
                        mode: summaryMode,
                        canViewFinancials: accessControl.canViewFinancials,
                        onContinue: summaryMode == .readyToStart ? { finalizeStartFromMixSummary() } : nil
                    )
                }
            }
            .sheet(isPresented: $showAddEquipment) {
                EquipmentFormSheet(equipment: nil)
            }
            .sheet(isPresented: $showAddChemicalToList) {
                EditSavedChemicalSheet(chemical: nil)
            }
            .sheet(isPresented: $showStartConfirmation) {
                startConfirmationSheet
            }
            .onAppear {
                applyPrefillIfNeeded()
                autoSelectEquipmentIfSingle()
                clampStartPath()
            }
            .onChange(of: store.sprayEquipment.count) { _, _ in
                autoSelectEquipmentIfSingle()
            }
            .onChange(of: selectedPaddockIds) { _, _ in
                clampStartPath()
            }
        }
    }

    /// Auto-select the only available equipment so the operator can't
    /// accidentally skip the section. Multiple options always require an
    /// explicit choice.
    private func autoSelectEquipmentIfSingle() {
        guard selectedEquipmentId == nil else { return }
        let vineyardId = store.selectedVineyardId
        let available = store.sprayEquipment.filter { vineyardId == nil || $0.vineyardId == vineyardId }
        if available.count == 1 {
            selectedEquipmentId = available.first?.id
        }
    }

    /// Normalise a stored label URL so we can open it reliably.
    /// Accepts inputs that may be missing the `https://` scheme.
    private static func normalizedLabelURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        return URL(string: trimmed)
    }

    private func applyPrefillIfNeeded() {
        guard let r = prefillRecord, !prefillApplied else { return }
        prefillApplied = true

        if !r.equipmentType.isEmpty {
            selectedEquipmentId = store.sprayEquipment.first(where: { $0.name == r.equipmentType })?.id
        }
        if !r.tractor.isEmpty {
            selectedTractorId = store.tractors.first(where: { $0.displayName == r.tractor || $0.name == r.tractor })?.id
        }
        if let trip = store.trips.first(where: { $0.id == r.tripId }) {
            selectedPaddockIds = Set(trip.paddockIds)
        }

        if let firstTank = r.tanks.first {
            var lines: [ChemicalLine] = []
            for chem in firstTank.chemicals {
                guard let saved = store.savedChemicals.first(where: {
                    $0.name.caseInsensitiveCompare(chem.name) == .orderedSame
                }) else { continue }
                let basis: RateBasis = chem.ratePer100L > 0 ? .per100Litres : .perHectare
                let rate = saved.rates.first(where: { $0.basis == basis }) ?? saved.rates.first
                lines.append(
                    ChemicalLine(
                        chemicalId: saved.id,
                        selectedRateId: rate?.id ?? UUID(),
                        basis: rate?.basis ?? basis
                    )
                )
            }
            chemicalLines = lines
        }
    }

    // MARK: - Sections

    private var sprayNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Spray Name", icon: "tag")
            TextField("e.g. Downy Mildew Spray #3", text: $sprayName)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var operationTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Operation Type", icon: "gearshape.2")
            Menu {
                ForEach(OperationType.allCases, id: \.self) { type in
                    Button {
                        operationType = type
                    } label: {
                        HStack {
                            Image(systemName: type.iconName)
                            Text(type.rawValue)
                            if operationType == type {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(VineyardTheme.olive.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: operationType.iconName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VineyardTheme.olive)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Operation")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(operationType.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private var paddockSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Blocks", icon: "square.grid.2x2.fill")

            Button {
                showSprayPaddockPicker = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(VineyardTheme.leafGreen.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VineyardTheme.leafGreen)
                    }
                    if selectedPaddockIds.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No blocks selected")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(store.paddocks.isEmpty ? "No blocks configured" : "Tap to choose one or more blocks")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(collapsedPaddockSummary)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(selectedPaddocks.map(\.name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selectedPaddockIds.isEmpty ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)

            if !selectedPaddockIds.isEmpty {
                HStack(spacing: 0) {
                    paddockStatCell(value: "\(selectedPaddockIds.count)", label: selectedPaddockIds.count == 1 ? "Block" : "Blocks")
                    Divider().frame(height: 32)
                    paddockStatCell(value: String(format: "%.2f", totalAreaHectares), label: "Hectares")
                    Divider().frame(height: 32)
                    paddockStatCell(value: "\(totalRowsAcrossSelection)", label: "Rows")
                }
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $showSprayPaddockPicker) {
            SprayPaddockPickerSheet(selectedIds: $selectedPaddockIds)
        }
    }

    /// Contiguous row-number ranges across the currently selected paddocks.
    /// Sorted, deduplicated, and collapsed so e.g. [1,2,3,5,6] -> [(1,3),(5,6)].
    private func contiguousRowRanges(_ numbers: [Int]) -> [(Int, Int)] {
        let sorted = Array(Set(numbers)).sorted()
        guard !sorted.isEmpty else { return [] }
        var ranges: [(Int, Int)] = []
        var start = sorted[0]
        var prev = sorted[0]
        for n in sorted.dropFirst() {
            if n == prev + 1 { prev = n; continue }
            ranges.append((start, prev))
            start = n
            prev = n
        }
        ranges.append((start, prev))
        return ranges
    }

    /// Human-friendly row range across every selected paddock. Returns a
    /// single "Rows lo–hi" string when contiguous, a comma-separated list
    /// when there's room, or "Multiple row ranges" as a safe fallback.
    private var selectedRowRangeSummary: String {
        let nums = selectedPaddocks.flatMap { $0.rows.map(\.number) }
        let ranges = contiguousRowRanges(nums)
        guard !ranges.isEmpty else { return "Rows not set" }
        if ranges.count == 1 {
            let (lo, hi) = ranges[0]
            return lo == hi ? "Row \(lo)" : "Rows \(lo)–\(hi)"
        }
        let parts = ranges.map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0)–\($0.1)" }
        let joined = "Rows " + parts.joined(separator: ", ")
        return joined.count <= 48 ? joined : "Multiple row ranges"
    }

    /// Collapsed summary line shown in the paddock selector button after
    /// selection, e.g. "2 paddocks · 2.04 ha · 46 rows · Rows 1–46".
    private var collapsedPaddockSummary: String {
        var parts: [String] = []
        parts.append("\(selectedPaddockIds.count) paddock\(selectedPaddockIds.count == 1 ? "" : "s")")
        parts.append(String(format: "%.2f ha", totalAreaHectares))
        parts.append("\(totalRowsAcrossSelection) row\(totalRowsAcrossSelection == 1 ? "" : "s")")
        parts.append(selectedRowRangeSummary)
        return parts.joined(separator: " · ")
    }

    private func paddockStatCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private var growthStageSection: some View {
        let paddocksMissing = selectedPaddockIds.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Growth Stage", icon: "leaf.arrow.circlepath")

            Button {
                guard !paddocksMissing else { return }
                withAnimation(.spring(duration: 0.3)) { isGrowthStageExpanded.toggle() }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(VineyardTheme.leafGreen.opacity(paddocksMissing ? 0.08 : 0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "leaf.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VineyardTheme.leafGreen.opacity(paddocksMissing ? 0.5 : 1.0))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Growth Stage")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(growthStageSummary)
                            .font(.caption)
                            .foregroundStyle(paddocksMissing ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isGrowthStageExpanded && !paddocksMissing ? 90 : 0))
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(paddocksMissing ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(paddocksMissing ? "Select blocks first to choose a growth stage" : "Opens growth stage selector")

            if isGrowthStageExpanded && !paddocksMissing {
                Picker("", selection: $growthStageMode) {
                    Text("Same for All").tag(GrowthStageMode.same)
                    Text("Per Paddock").tag(GrowthStageMode.perPaddock)
                }
                .pickerStyle(.segmented)
                .onChange(of: growthStageMode) { _, newMode in
                    if newMode == .same, let shared = sharedGrowthStageId {
                        for pid in selectedPaddockIds {
                            paddockPhenologyStages[pid] = shared
                        }
                    }
                }

                if growthStageMode == .same {
                    sameGrowthStageList
                } else {
                    perPaddockGrowthStageList
                }
            }
        }
    }

    private var sameGrowthStageList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("E-L Growth Stages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Button {
                sharedGrowthStageId = nil
                for pid in selectedPaddockIds {
                    paddockPhenologyStages.removeValue(forKey: pid)
                }
            } label: {
                HStack {
                    Image(systemName: sharedGrowthStageId == nil ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(sharedGrowthStageId == nil ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                    Text("Not Set").foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider().padding(.leading, 40)

            ForEach(phenologyStages) { stage in
                let isSelected = sharedGrowthStageId == stage.id
                Button {
                    sharedGrowthStageId = stage.id
                    for pid in selectedPaddockIds {
                        paddockPhenologyStages[pid] = stage.id
                    }
                } label: {
                    HStack {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                        Text(stage.code)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 56, alignment: .leading)
                        Text(stage.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                if stage.id != phenologyStages.last?.id {
                    Divider().padding(.leading, 40)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var perPaddockGrowthStageList: some View {
        let paddocks = selectedPaddocks
        return VStack(spacing: 0) {
            ForEach(paddocks) { paddock in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paddock.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let stageId = paddockPhenologyStages[paddock.id],
                           let stage = phenologyStages.first(where: { $0.id == stageId }) {
                            Text("\(stage.name) (\(stage.code))")
                                .font(.caption2)
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                    Spacer()
                    Menu {
                        Button("Not Set") { paddockPhenologyStages.removeValue(forKey: paddock.id) }
                        ForEach(phenologyStages) { stage in
                            Button("\(stage.code) – \(stage.name)") {
                                paddockPhenologyStages[paddock.id] = stage.id
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let stageId = paddockPhenologyStages[paddock.id],
                               let stage = phenologyStages.first(where: { $0.id == stageId }) {
                                Text(stage.code).font(.caption.weight(.semibold))
                            } else {
                                Text("Select").font(.caption)
                            }
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .foregroundStyle(VineyardTheme.olive)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(VineyardTheme.olive.opacity(0.1))
                        .clipShape(.rect(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                if paddock.id != paddocks.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var equipmentSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Clean header row — title left, add (+) right. The selected
            // equipment value is shown in its own card below to avoid
            // overlap with the add button.
            HStack(spacing: 8) {
                SectionHeader(title: "Equipment", icon: "wrench.and.screwdriver")
                Spacer()
                Button {
                    showAddEquipment = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(VineyardTheme.olive)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Equipment")
            }

            // Selected equipment card — full-width, tappable to expand list.
            Button {
                withAnimation(.spring(duration: 0.3)) { isEquipmentExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(VineyardTheme.olive.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VineyardTheme.olive)
                    }
                    if let id = selectedEquipmentId,
                       let eq = store.sprayEquipment.first(where: { $0.id == id }) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(eq.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(eq.tankCapacityLitres, specifier: "%.0f") L tank")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.sprayEquipment.isEmpty ? "No equipment configured" : "Select equipment")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(store.sprayEquipment.isEmpty ? "Tap + to add equipment" : "Required to continue")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isEquipmentExpanded ? 90 : 0))
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selectedEquipmentId == nil ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)

            if isEquipmentExpanded {
                VStack(spacing: 0) {
                    if store.sprayEquipment.isEmpty {
                        Button {
                            showAddEquipment = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(VineyardTheme.olive)
                                Text("Add Equipment")
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(store.sprayEquipment) { item in
                        let isSelected = selectedEquipmentId == item.id
                        Button {
                            selectedEquipmentId = item.id
                        } label: {
                            HStack {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                                Text(item.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(item.tankCapacityLitres, specifier: "%.0f") L")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        if item.id != store.sprayEquipment.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
            }
        }
    }

    private var waterRateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Calculated Water Rate", icon: "drop.fill")
            Text("Based on row widths & canopy status")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VSP Canopy Size")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Canopy Size", selection: $canopySize) {
                        ForEach(CanopySize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(canopySize.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let imageURL = canopySize.referenceImageURL {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            case .failure:
                                Image(systemName: "leaf")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            case .empty:
                                ProgressView()
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .padding(8)
                        .background(Color.white)
                        .clipShape(.rect(cornerRadius: 8))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Canopy Density")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Canopy Density", selection: $canopyDensity) {
                        ForEach(CanopyDensity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.0f", waterRateEntry.litresPerHa)) L/ha")
                            .font(.title3.bold())
                            .foregroundStyle(VineyardTheme.olive)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Per 100m row")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.0f", waterRateEntry.litresPer100m)) L")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(12)
                .background(VineyardTheme.olive.opacity(0.08))
                .clipShape(.rect(cornerRadius: 10))

                Text("Row spacing: \(String(format: "%.1f", averageRowSpacing))m")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if operationType.useConcentrationFactor {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Spray Rate & Concentration Factor")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Chosen Spray Rate (L/ha)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("L/ha", text: $sprayRateText)
                                    .keyboardType(.decimalPad)
                                    .font(.body.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color(.tertiarySystemGroupedBackground))
                                    .clipShape(.rect(cornerRadius: 8))
                                    .onChange(of: sprayRateText) { _, _ in hasEditedSprayRate = true }
                            }
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("CF").font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.2f", concentrationFactor))
                                    .font(.title2.bold())
                                    .foregroundStyle(concentrationFactor == 1.0 ? VineyardTheme.olive : .orange)
                            }
                            .frame(minWidth: 60)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))
        }
        .onChange(of: waterRateEntry.litresPerHa) { _, newValue in
            if !hasEditedSprayRate {
                sprayRateText = String(format: "%.0f", newValue)
            }
        }
        .onAppear {
            if sprayRateText.isEmpty {
                sprayRateText = String(format: "%.0f", waterRateEntry.litresPerHa)
            }
        }
    }

    private var confirmTractorPicker: some View { mixTractorSection }

    private var confirmTripSetup: some View { mixTripSetupSection }

    // MARK: - Spray Tank Mixing — Maintenance-style sections
    //
    // These sections mirror the layout and mechanics of
    // `StartTripSheet` (Start Maintenance Trip Tracking) so the spray
    // trip setup feels identical to the maintenance trip setup.

    private var availableTractors: [Tractor] {
        let vineyardId = store.selectedVineyardId
        let filtered = store.tractors.filter { vineyardId == nil || $0.vineyardId == vineyardId }
        return filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedTractorLabel: String {
        if let id = selectedTractorId, let t = availableTractors.first(where: { $0.id == id }) {
            return t.displayName
        }
        return availableTractors.isEmpty ? "No tractors configured" : "No tractor selected"
    }

    @ViewBuilder
    private func mixSectionContainer<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            content()
        }
    }

    private var mixTractorSection: some View {
        mixSectionContainer(title: "Tractor", icon: "car.fill", tint: .indigo) {
            VStack(spacing: 10) {
                Menu {
                    Button {
                        selectedTractorId = nil
                    } label: {
                        HStack {
                            Text("No tractor")
                            if selectedTractorId == nil {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    if !availableTractors.isEmpty {
                        Divider()
                        ForEach(availableTractors) { tractor in
                            Button {
                                selectedTractorId = tractor.id
                            } label: {
                                HStack {
                                    Text(tractor.displayName)
                                    if selectedTractorId == tractor.id {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "car.fill")
                            .foregroundStyle(.indigo)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tractor")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(selectedTractorLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(availableTractors.isEmpty)

                if availableTractors.isEmpty {
                    Text("Add tractors in Equipment to enable fuel cost estimates.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else if selectedTractorId == nil {
                    Text("Optional — select a tractor so fuel cost can be estimated.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// Maintenance-style trip setup for the Spray Tank Mixing screen.
    /// Mirrors `StartTripSheet`: full-width pattern cards, Menu-based start
    /// row picker, segmented sequence direction, and a path sequence preview.
    private var mixTripSetupSection: some View {
        VStack(spacing: 20) {
            // No. Fans / Jets — keep as a single optional card.
            mixSectionContainer(title: "Equipment Settings", icon: "fan", tint: VineyardTheme.olive) {
                HStack(spacing: 12) {
                    Image(systemName: "fan")
                        .foregroundStyle(VineyardTheme.olive)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No. Fans / Jets")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Optional — recorded for compliance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("e.g. 6", text: $numberOfFansJets)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
            }

            // Tracking Pattern — large selection cards.
            mixSectionContainer(title: "Tracking Pattern", icon: "arrow.triangle.swap", tint: .purple) {
                VStack(spacing: 10) {
                    ForEach(TrackingPattern.allCases) { pattern in
                        mixPatternRow(pattern: pattern)
                    }
                }
            }

            // Start Path + Sequence Direction — matches Maintenance Trip.
            if hasAnyRowGeometry, trackingPatternChoice != .freeDrive {
                mixStartPathSection
                mixProposedSequenceSection
            } else if trackingPatternChoice == .freeDrive {
                mixSectionContainer(title: "Free Drive", icon: "scribble.variable", tint: .teal) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.teal)
                            Text("No planned row sequence")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text("Drive freely — the app detects the row/path you are in from GPS, ticks it off when covered, and keeps recording distance, pins and trip history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                }
            } else {
                mixSectionContainer(title: "Start Path & Direction", icon: "arrow.up.arrow.down", tint: .blue) {
                    Text("Row guidance unavailable — selected paddocks have no row geometry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                }
            }
        }
    }

    /// Start Path + Sequence Direction card, identical layout to
    /// `StartTripSheet.directionSection` so Maintenance and Spray match.
    private var mixStartPathSection: some View {
        mixSectionContainer(title: "Start Path & Direction", icon: "arrow.up.arrow.down", tint: .blue) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text(rowGuidanceHelperText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }

                Menu {
                    ForEach(availablePaths, id: \.self) { path in
                        Button {
                            startPath = path
                        } label: {
                            HStack {
                                Text(TripRowSequencePlanner.pathMenuLabel(path, paddocks: orderedSelectedPaddocks))
                                if abs(path - startPath) < 0.01 {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start path")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(TripRowSequencePlanner.pathMenuLabel(startPath, paddocks: orderedSelectedPaddocks))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sequence direction")
                        .font(.subheadline.weight(.semibold))
                    Picker("Sequence direction", selection: $directionHigherFirst) {
                        Text("Higher to lower").tag(false)
                        Text("Lower to higher").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
            }
        }
    }

    /// Proposed Row Sequence preview card, mirrors
    /// `StartTripSheet.sequencePreviewSection`.
    private var mixProposedSequenceSection: some View {
        mixSectionContainer(title: "Proposed Row Sequence", icon: "list.number", tint: .purple) {
            VStack(alignment: .leading, spacing: 8) {
                if let note = TripRowSequencePlanner.patternPreviewNote(trackingPatternChoice) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let sequence = pathSequencePreview
                if sequence.isEmpty {
                    Text("No sequence available for the current selection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                            Text(TripRowSequencePlanner.sequencePreviewText(sequence))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        Text("\(sequence.count) path\(sequence.count == 1 ? "" : "s") planned")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
        }
    }

    /// Helper line beneath the Start Path picker ("Row guidance follows all
    /// selected blocks (Rows 1–46 · Paths 0.5–46.5)").
    private var rowGuidanceHelperText: String {
        let n = combinedTotalRows
        guard n > 0 else { return "Row guidance unavailable for the selected blocks" }
        let range = TripRowSequencePlanner.combinedRangeLabel(orderedSelectedPaddocks)
        let paths = TripRowSequencePlanner.combinedPathsLabel(orderedSelectedPaddocks)
        if orderedSelectedPaddocks.count > 1 {
            return "Row guidance follows all selected blocks (\(range) · \(paths))"
        }
        return "Row guidance follows selected block (\(range) · \(paths))"
    }

    /// Snap `startPath` to a valid path in `availablePaths`. Called from
    /// onAppear and whenever the paddock selection changes.
    private func clampStartPath() {
        let paths = availablePaths
        guard let first = paths.first else { return }
        if !paths.contains(where: { abs($0 - startPath) < 0.01 }) {
            startPath = first
        } else {
            startPath = TripRowSequencePlanner.clampedStartPath(startPath, paddocks: orderedSelectedPaddocks)
        }
    }

    /// Single pattern selection card matching `StartTripSheet.patternRow`.
    private func mixPatternRow(pattern: TrackingPattern) -> some View {
        let isSelected = trackingPatternChoice == pattern
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                trackingPatternChoice = pattern
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill((isSelected ? Color.purple : Color.secondary).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: pattern.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isSelected ? .purple : .secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(pattern.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(pattern.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.purple : Color.secondary.opacity(0.5))
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.purple.opacity(0.5) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// Tank mix preview shown on the Spray Tank Mixing screen so the operator
    /// can review chemical quantities and label notes before tapping Start.
    @ViewBuilder
    private var tankMixPreviewSection: some View {
        if let result = calculationResult {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Tank Mix", icon: "drop.fill")

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    mixStatTile(
                        label: "Total Area",
                        value: String(format: "%.2f ha", result.totalAreaHectares),
                        icon: "square.dashed",
                        color: VineyardTheme.olive
                    )
                    mixStatTile(
                        label: "Total Water",
                        value: String(format: "%.0f L", result.totalWaterLitres),
                        icon: "drop.fill",
                        color: .blue
                    )
                    mixStatTile(
                        label: "Full Tanks",
                        value: "\(result.fullTankCount)",
                        icon: "fuelpump.fill",
                        color: VineyardTheme.earthBrown
                    )
                    mixStatTile(
                        label: "Last Tank",
                        value: String(format: "%.0f L", result.lastTankLitres),
                        icon: "drop.halffull",
                        color: .orange
                    )
                }

                ForEach(result.chemicalResults) { chemResult in
                    mixChemicalRow(chemResult)
                }

                if result.concentrationFactor != 1.0 {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Concentration Factor \(String(format: "%.2f", result.concentrationFactor))×")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(result.concentrationFactor > 1.0 ? "Concentrate" : "Dilute")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    .padding(10)
                    .background(.orange.opacity(0.08))
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
        }
    }

    private func mixStatTile(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold))
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func mixChemicalRow(_ chemResult: ChemicalCalculationResult) -> some View {
        let saved = chemResult.savedChemicalId.flatMap { id in
            store.savedChemicals.first(where: { $0.id == id })
        }
        let labelURL = saved?.labelURL ?? ""
        let productURL = saved?.productURL ?? ""
        let restrictions = saved?.restrictions ?? ""
        let isOverridden: Bool = chemicalLines.first(where: { $0.chemicalId == chemResult.savedChemicalId })?.overrideRate != nil

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                Text(chemResult.chemicalName)
                    .font(.subheadline.weight(.semibold))
                if isOverridden {
                    Text("Override")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
                if let url = Self.normalizedLabelURL(labelURL) {
                    Button {
                        #if DEBUG
                        print("[SprayMix] open label url=\(url.absoluteString) chem=\(chemResult.chemicalName)")
                        #endif
                        openURL(url) { accepted in
                            #if DEBUG
                            print("[SprayMix] openURL accepted=\(accepted) url=\(url.absoluteString)")
                            #endif
                        }
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(VineyardTheme.olive)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open chemical label")
                }
                // Manufacturer/product page — visually distinct (globe) and
                // never labelled "Label". Shown in addition to, or instead
                // of, the official label icon.
                if let url = Self.normalizedLabelURL(productURL) {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "globe")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open product page (not the official label)")
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rate").font(.caption2).foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", chemResult.unit.fromBase(chemResult.selectedRate))) \(chemResult.unit.rawValue)/\(chemResult.basis == .perHectare ? "ha" : "100L")")
                        .font(.caption.weight(.medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total").font(.caption2).foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", chemResult.unit.fromBase(chemResult.totalAmountRequired))) \(chemResult.unit.rawValue)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VineyardTheme.olive)
                }
            }
            if !restrictions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(restrictions)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var tractorSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Tractor (optional)", icon: "truck.pickup.side.fill")
            VStack(spacing: 0) {
                Button {
                    selectedTractorId = nil
                } label: {
                    HStack {
                        Image(systemName: selectedTractorId == nil ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedTractorId == nil ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                        Text("Not Set").foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                ForEach(store.tractors) { tractor in
                    let isSelected = selectedTractorId == tractor.id
                    Divider().padding(.leading, 40)
                    Button {
                        selectedTractorId = tractor.id
                    } label: {
                        HStack {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                            Text(tractor.displayName).foregroundStyle(.primary)
                            Spacer()
                            if tractor.fuelUsageLPerHour > 0 {
                                Text("\(String(format: "%.1f", tractor.fuelUsageLPerHour)) L/hr")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var chemicalLinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Chemicals", icon: "flask")

            ForEach($chemicalLines) { $line in
                CalcChemicalLineCard(
                    line: $line,
                    chemicals: store.savedChemicals
                ) {
                    chemicalLines.removeAll { $0.id == line.id }
                }
            }

            Button {
                if let chem = store.savedChemicals.first {
                    let rate = chem.rates.first
                    chemicalLines.append(
                        ChemicalLine(
                            chemicalId: chem.id,
                            selectedRateId: rate?.id ?? UUID(),
                            basis: rate?.basis ?? .perHectare
                        )
                    )
                }
            } label: {
                Label("Add Chemical", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VineyardTheme.olive)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(VineyardTheme.olive.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 10))
            }
            .disabled(store.savedChemicals.isEmpty)

            Button {
                showAddChemicalToList = true
            } label: {
                Label("Add New Chemical to List", systemImage: "flask.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(VineyardTheme.leafGreen.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 10))
            }

            if store.savedChemicals.isEmpty {
                Text("No chemicals configured. Tap “Add New Chemical to List” to create one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }


    private var weatherNoteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "cloud.sun.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weather captured automatically")
                        .font(.subheadline.weight(.semibold))
                    Text("Temperature, wind and humidity will be recorded when the job starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let label = sprayWeatherSourceLabel {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Button {
                        showWeatherDataSettings = true
                    } label: {
                        Text("Manage")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
        .sheet(isPresented: $showWeatherDataSettings) {
            NavigationStack {
                WeatherDataSettingsView()
            }
        }
    }

    private var sprayWeatherSourceLabel: String? {
        guard let vid = store.selectedVineyardId else { return nil }
        let status = WeatherProviderResolver.resolve(
            for: vid,
            weatherStationId: store.settings.weatherStationId
        )
        switch status.provider {
        case .automatic:
            return "Source: Automatic Forecast"
        case .wunderground:
            let id = status.detailLabel
            return id.isEmpty ? "Source: Weather Underground PWS" : "Source: Weather Underground PWS — \(id)"
        case .davis:
            return "Source: Davis WeatherLink configured — fetch currently uses fallback"
        }
    }

    @ViewBuilder
    private var startConfirmationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "drop.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(VineyardTheme.olive)
                        Text("Spray Tank Mixing")
                            .font(.title2.bold())
                        Text("Review the tank mix and trip setup before starting.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 12)

                    VStack(spacing: 0) {
                        confirmRow(label: "Operator", value: auth.userName?.isEmpty == false ? (auth.userName ?? "") : "—", icon: "person.fill")
                        Divider().padding(.leading, 44)
                        confirmRow(label: "Equipment", value: selectedEquipmentName, icon: "wrench.and.screwdriver.fill")
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                    .padding(.horizontal)

                    tankMixPreviewSection

                    confirmTractorPicker
                        .padding(.horizontal)

                    confirmTripSetup
                        .padding(.horizontal)

                    if !pathSequencePreview.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(VineyardTheme.olive)
                                Text("Path Sequence Preview")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(pathSequencePreview.count) paths")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(pathSequenceText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .clipShape(.rect(cornerRadius: 8))
                        }
                        .padding(.horizontal)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "cloud.sun.fill")
                            .foregroundStyle(.blue)
                        Text("Weather data will be captured automatically at the start.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(.rect(cornerRadius: 10))
                    .padding(.horizontal)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(.rect(cornerRadius: 8))
                            .padding(.horizontal)
                    }

                    VStack(spacing: 8) {
                        Button {
                            Task { await confirmAndStartJob() }
                        } label: {
                            HStack(spacing: 8) {
                                if isStartingJob {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text(isStartingJob ? "Starting…" : "Start Spray Trip")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(VineyardTheme.olive)
                        .disabled(isStartingJob)

                        Button("Cancel") {
                            showStartConfirmation = false
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .disabled(isStartingJob)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Spray Tank Mixing")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isStartingJob)
        }
    }

    private var pathSequenceText: String {
        TripRowSequencePlanner.sequencePreviewText(pathSequencePreview, maxItems: 40)
    }

    private func confirmRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(VineyardTheme.olive)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Notes", icon: "note.text")
            TextField("Add notes about this spray job...", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                saveAndStartJob()
            } label: {
                Label("Create Spray Job & View Tank Mix", systemImage: "flask.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(VineyardTheme.olive)
            .disabled(!formIsValid)

            Button {
                saveForLater()
            } label: {
                Label("Save Job for Future Use", systemImage: "clock.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .tint(VineyardTheme.leafGreen)
            .disabled(!formIsValid)
        }
    }

    // MARK: - Calculation & Save

    private func performCalculation(jobDurationHours: Double = 0) {
        guard let equipId = selectedEquipmentId,
              let equip = store.sprayEquipment.first(where: { $0.id == equipId }) else { return }

        let tractor: Tractor? = selectedTractorId.flatMap { id in
            store.tractors.first(where: { $0.id == id })
        }

        calculationResult = SprayCalculator.calculate(
            selectedPaddocks: selectedPaddocks,
            waterRateLitresPerHectare: chosenSprayRate,
            tankCapacity: equip.tankCapacityLitres,
            chemicalLines: chemicalLines,
            chemicals: store.savedChemicals,
            concentrationFactor: concentrationFactor,
            operationType: operationType,
            tractor: tractor,
            jobDurationHours: jobDurationHours,
            fuelCostPerLitre: store.seasonFuelCostPerLitre
        )
        withAnimation(.spring(duration: 0.4)) { showResults = true }
    }

    private func buildSprayTanks(result: SprayCalculationResult, tankCapacity: Double) -> [SprayTank] {
        let totalTanks = result.fullTankCount + (result.lastTankLitres > 0 ? 1 : 0)
        guard totalTanks > 0 else {
            return [SprayTank(tankNumber: 1, waterVolume: 0, sprayRatePerHa: chosenSprayRate, concentrationFactor: concentrationFactor)]
        }

        var tanks: [SprayTank] = []
        for i in 0..<totalTanks {
            let isLast = (i == totalTanks - 1)
            let waterVolume = isLast && result.lastTankLitres > 0 ? result.lastTankLitres : tankCapacity
            let chemicals: [SprayChemical] = result.chemicalResults.map { chemResult in
                let amount = isLast ? chemResult.amountInLastTank : chemResult.amountPerFullTank
                // Snapshot the saved chemical's costPerBaseUnit (if any) so
                // TripCostService can calculate chemical cost reliably without
                // having to re-resolve the saved chemical later.
                return SprayChemical(
                    name: chemResult.chemicalName,
                    volumePerTank: amount,
                    ratePerHa: chemResult.basis == .perHectare ? chemResult.selectedRate : 0,
                    ratePer100L: chemResult.basis == .per100Litres ? chemResult.selectedRate : 0,
                    costPerUnit: chemResult.costPerBaseUnit ?? 0,
                    unit: chemResult.unit,
                    savedChemicalId: chemResult.savedChemicalId
                )
            }
            tanks.append(
                SprayTank(
                    tankNumber: i + 1,
                    waterVolume: waterVolume,
                    sprayRatePerHa: chosenSprayRate,
                    concentrationFactor: concentrationFactor,
                    chemicals: chemicals
                )
            )
        }
        return tanks
    }

    private func currentWeatherSnapshot() -> (temperature: Double?, windSpeed: Double?, windDirection: String, humidity: Double?) {
        (capturedTemperature, capturedWindSpeed, capturedWindDirection, capturedHumidity)
    }

    private func resolveWeatherCoordinate() -> CLLocationCoordinate2D? {
        for paddock in selectedPaddocks {
            let pts = paddock.polygonPoints
            guard !pts.isEmpty else { continue }
            let lat = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
            let lon = pts.map(\.longitude).reduce(0, +) / Double(pts.count)
            if lat != 0 || lon != 0 {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return locationService.location?.coordinate
    }

    private func captureWeather() async {
        guard let coordinate = resolveWeatherCoordinate() else { return }
        let stationId = store.settings.weatherStationId
        let service = WeatherCurrentService()
        do {
            let snapshot = try await service.fetch(coordinate: coordinate, stationId: stationId)
            capturedTemperature = snapshot.temperatureC
            capturedWindSpeed = snapshot.windSpeedKmh
            if !snapshot.windDirection.isEmpty {
                capturedWindDirection = snapshot.windDirection
            }
            capturedHumidity = snapshot.humidityPercent
        } catch {
            // Weather capture is best-effort; ignore errors.
        }
    }

    private func saveAndStartJob() {
        guard formIsValid else { return }
        guard !accessControl.isLoading else { return }
        guard accessControl.canCreateOperationalRecords else {
            errorMessage = "Your role does not allow creating spray records."
            return
        }
        guard store.selectedVineyardId != nil else {
            errorMessage = "No vineyard selected."
            return
        }
        if tracking.activeTrip != nil {
            errorMessage = "A trip is already in progress. End it before starting a new spray."
            return
        }
        errorMessage = nil
        // Pre-compute the tank mix so the operator sees it on the Spray Tank
        // Mixing screen before tapping Start Spray Trip.
        performCalculation()
        if let equipId = selectedEquipmentId,
           let equip = store.sprayEquipment.first(where: { $0.id == equipId }),
           let result = calculationResult {
            pendingTanks = buildSprayTanks(result: result, tankCapacity: equip.tankCapacityLitres)
        }
        showStartConfirmation = true
    }

    private func confirmAndStartJob() async {
        guard formIsValid, !isStartingJob else { return }
        guard let equipId = selectedEquipmentId,
              let equip = store.sprayEquipment.first(where: { $0.id == equipId }) else { return }
        guard store.selectedVineyardId != nil else {
            errorMessage = "No vineyard selected."
            return
        }
        if tracking.activeTrip != nil {
            errorMessage = "A trip is already in progress. End it before starting a new spray."
            return
        }
        errorMessage = nil
        isStartingJob = true
        defer { isStartingJob = false }

        await captureWeather()
        performCalculation()

        if let result = calculationResult {
            pendingTanks = buildSprayTanks(result: result, tankCapacity: equip.tankCapacityLitres)
        }

        // Skip the intermediate readyToStart summary sheet — the Spray Tank
        // Mixing screen now shows the mix preview, so tapping Start Spray Trip
        // should begin live tracking directly.
        finalizeStartFromMixSummary()
        showStartConfirmation = false
    }

    private func finalizeStartFromMixSummary() {
        guard let equipId = selectedEquipmentId,
              let equip = store.sprayEquipment.first(where: { $0.id == equipId }) else { return }
        guard let vineyardId = store.selectedVineyardId else {
            errorMessage = "No vineyard selected."
            return
        }
        if tracking.activeTrip != nil {
            errorMessage = "A trip is already in progress."
            return
        }

        let firstPaddock = selectedPaddocks.first
        let paddockNames = selectedPaddocks.map { $0.name }.joined(separator: ", ")

        tracking.startTrip(
            type: .spray,
            paddockId: firstPaddock?.id,
            paddockName: paddockNames,
            trackingPattern: trackingPatternChoice,
            personName: auth.userName ?? "",
            tractorId: selectedTractorId,
            operatorUserId: auth.userId
        )

        guard let activeTrip = tracking.activeTrip else {
            errorMessage = tracking.errorMessage ?? "Could not start trip."
            return
        }

        let weather = currentWeatherSnapshot()
        let tanks = pendingTanks.isEmpty
            ? (calculationResult.map { buildSprayTanks(result: $0, tankCapacity: equip.tankCapacityLitres) } ?? [])
            : pendingTanks

        var tripWithTanks = activeTrip
        tripWithTanks.totalTanks = tanks.count
        let sequence = pathSequencePreview
        if let first = sequence.first {
            tripWithTanks.rowSequence = sequence
            tripWithTanks.sequenceIndex = 0
            tripWithTanks.currentRowNumber = first
            tripWithTanks.nextRowNumber = sequence.dropFirst().first ?? first
        }
        store.updateTrip(tripWithTanks)

        let tractorName = selectedTractorId.flatMap { id in
            store.tractors.first(where: { $0.id == id })?.displayName
        } ?? ""

        let record = SprayRecord(
            tripId: activeTrip.id,
            vineyardId: vineyardId,
            date: Date(),
            startTime: Date(),
            temperature: weather.temperature,
            windSpeed: weather.windSpeed,
            windDirection: weather.windDirection,
            humidity: weather.humidity,
            sprayReference: sprayName,
            tanks: tanks,
            notes: notes,
            numberOfFansJets: numberOfFansJets,
            equipmentType: equip.name,
            tractor: tractorName,
            isTemplate: false,
            operationType: operationType
        )
        store.addSprayRecord(record)

        savedFeedback.toggle()
        showSummary = false
        showStartConfirmation = false
        // Dismiss the Spray Calculator sheet so the live trip tracking UI
        // becomes visible to the operator.
        dismiss()
    }

    private func saveForLater() {
        guard formIsValid else { return }
        guard accessControl.canCreateOperationalRecords else {
            errorMessage = "Your role does not allow creating spray records."
            return
        }
        guard let equipId = selectedEquipmentId,
              let equip = store.sprayEquipment.first(where: { $0.id == equipId }) else { return }
        guard let vineyardId = store.selectedVineyardId else {
            errorMessage = "No vineyard selected."
            return
        }
        errorMessage = nil

        performCalculation()

        // Create a placeholder inactive trip so the record shows up under
        // "Not Started" in the spray program picker.
        let firstPaddock = selectedPaddocks.first
        let paddockNames = selectedPaddocks.map { $0.name }.joined(separator: ", ")
        let placeholderTrip = Trip(
            id: UUID(),
            vineyardId: vineyardId,
            paddockId: firstPaddock?.id,
            paddockName: paddockNames,
            paddockIds: selectedPaddocks.map { $0.id },
            startTime: Date(),
            endTime: nil,
            isActive: false
        )
        store.addInactiveTrip(placeholderTrip)

        let weather = currentWeatherSnapshot()
        let tanks: [SprayTank] = {
            guard let result = calculationResult else { return [] }
            return buildSprayTanks(result: result, tankCapacity: equip.tankCapacityLitres)
        }()

        let tractorName = selectedTractorId.flatMap { id in
            store.tractors.first(where: { $0.id == id })?.displayName
        } ?? ""

        let record = SprayRecord(
            tripId: placeholderTrip.id,
            vineyardId: vineyardId,
            date: Date(),
            startTime: Date(),
            temperature: weather.temperature,
            windSpeed: weather.windSpeed,
            windDirection: weather.windDirection,
            humidity: weather.humidity,
            sprayReference: sprayName,
            tanks: tanks,
            notes: notes,
            numberOfFansJets: numberOfFansJets,
            equipmentType: equip.name,
            tractor: tractorName,
            isTemplate: false,
            operationType: operationType
        )
        store.addSprayRecord(record)

        savedFeedback.toggle()
        summaryMode = .savedForLater
        showSummary = true
    }
}

// MARK: - Chemical Line Card

private struct CalcChemicalLineCard: View {
    @Binding var line: ChemicalLine
    let chemicals: [SavedChemical]
    let onDelete: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var overrideText: String = ""

    private static func normalizedLabelURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        return URL(string: trimmed)
    }

    private var selectedChemical: SavedChemical? {
        chemicals.first(where: { $0.id == line.chemicalId })
    }

    private var selectedRate: ChemicalRate? {
        selectedChemical?.rates.first(where: { $0.id == line.selectedRateId })
    }

    /// Recommended rate expressed in the chemical's display unit.
    private var recommendedRateDisplay: Double {
        guard let chem = selectedChemical, let rate = selectedRate else { return 0 }
        return chem.unit.fromBase(rate.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .font(.subheadline)
                Text(selectedChemical?.name ?? "Select Chemical")
                    .font(.subheadline.weight(.semibold))
                if let chem = selectedChemical,
                   let url = Self.normalizedLabelURL(chem.labelURL) {
                    Button {
                        #if DEBUG
                        print("[SprayCalc] open label url=\(url.absoluteString) for chem=\(chem.name)")
                        #endif
                        openURL(url) { accepted in
                            #if DEBUG
                            print("[SprayCalc] openURL accepted=\(accepted) url=\(url.absoluteString)")
                            #endif
                        }
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(VineyardTheme.olive)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open chemical label")
                }
                if let chem = selectedChemical,
                   let url = Self.normalizedLabelURL(chem.productURL) {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "globe")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open product page (not the official label)")
                }
                Spacer()
                if let chem = selectedChemical, !chem.rates.isEmpty {
                    Menu {
                        let haRates = chem.rates.filter { $0.basis == .perHectare }
                        let per100LRates = chem.rates.filter { $0.basis == .per100Litres }
                        if !haRates.isEmpty {
                            Section("Per Hectare") {
                                ForEach(haRates) { rate in
                                    Button {
                                        line.selectedRateId = rate.id
                                        line.basis = rate.basis
                                    } label: {
                                        Text("\(rate.label): \(String(format: "%.0f", chem.unit.fromBase(rate.value))) \(chem.unit.rawValue)/ha")
                                    }
                                }
                            }
                        }
                        if !per100LRates.isEmpty {
                            Section("Per 100L Water") {
                                ForEach(per100LRates) { rate in
                                    Button {
                                        line.selectedRateId = rate.id
                                        line.basis = rate.basis
                                    } label: {
                                        Text("\(rate.label): \(String(format: "%.0f", chem.unit.fromBase(rate.value))) \(chem.unit.rawValue)/100L")
                                    }
                                }
                            }
                        }
                    } label: {
                        let currentBasis = chem.rates.first(where: { $0.id == line.selectedRateId })?.basis ?? line.basis
                        HStack(spacing: 4) {
                            Text(currentBasis == .perHectare ? "Per Ha" : "Per 100L")
                                .font(.caption2.weight(.medium))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(currentBasis == .perHectare ? VineyardTheme.olive.opacity(0.15) : Color.blue.opacity(0.15))
                        .foregroundStyle(currentBasis == .perHectare ? VineyardTheme.olive : .blue)
                        .clipShape(Capsule())
                    }
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().padding(.leading, 14)

            VStack(alignment: .leading, spacing: 4) {
                Text("Chemical").font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(chemicals) { chem in
                        Button {
                            if line.chemicalId != chem.id {
                                line.chemicalId = chem.id
                                if let firstRate = chem.rates.first {
                                    line.selectedRateId = firstRate.id
                                    line.basis = firstRate.basis
                                }
                            }
                        } label: {
                            HStack {
                                Text(chem.name)
                                if line.chemicalId == chem.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedChemical?.name ?? "Select chemical")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let chem = selectedChemical, !chem.rates.isEmpty {
                let haRates = chem.rates.filter { $0.basis == .perHectare }
                let per100LRates = chem.rates.filter { $0.basis == .per100Litres }

                Divider().padding(.leading, 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Rate").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        if !haRates.isEmpty {
                            Section("Per Hectare") {
                                ForEach(haRates) { rate in
                                    Button {
                                        line.selectedRateId = rate.id
                                        line.basis = rate.basis
                                    } label: {
                                        HStack {
                                            Text("\(rate.label): \(String(format: "%.0f", chem.unit.fromBase(rate.value))) \(chem.unit.rawValue)/ha")
                                            if line.selectedRateId == rate.id {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if !per100LRates.isEmpty {
                            Section("Per 100L Water") {
                                ForEach(per100LRates) { rate in
                                    Button {
                                        line.selectedRateId = rate.id
                                        line.basis = rate.basis
                                    } label: {
                                        HStack {
                                            Text("\(rate.label): \(String(format: "%.0f", chem.unit.fromBase(rate.value))) \(chem.unit.rawValue)/100L")
                                            if line.selectedRateId == rate.id {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        let selectedRate = chem.rates.first(where: { $0.id == line.selectedRateId })
                        let label: String = {
                            guard let r = selectedRate else { return "Select rate" }
                            let suffix = r.basis == .perHectare ? "/ha" : "/100L"
                            return "\(r.label): \(String(format: "%.0f", chem.unit.fromBase(r.value))) \(chem.unit.rawValue)\(suffix)"
                        }()
                        HStack(spacing: 8) {
                            Text(label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider().padding(.leading, 14)

                overrideRateRow(chem: chem)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
        .onAppear { syncOverrideText() }
        .onChange(of: line.overrideRate) { _, _ in syncOverrideText() }
        .onChange(of: line.selectedRateId) { _, _ in
            // Switching the recommended rate clears any active override so
            // the operator can re-confirm before applying a manual value.
            if line.overrideRate != nil {
                line.overrideRate = nil
            }
        }
    }

    @ViewBuilder
    private func overrideRateRow(chem: SavedChemical) -> some View {
        let basisLabel = line.basis == .perHectare ? "/ha" : "/100L"
        let isOverridden = line.overrideRate != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Override Rate").font(.caption).foregroundStyle(.secondary)
                if isOverridden {
                    Text("Manual")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
                if isOverridden {
                    Button {
                        line.overrideRate = nil
                        overrideText = ""
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VineyardTheme.olive)
                }
            }
            HStack(spacing: 8) {
                TextField(
                    String(format: "%.1f", recommendedRateDisplay),
                    text: $overrideText
                )
                .keyboardType(.decimalPad)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
                .onChange(of: overrideText) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        line.overrideRate = nil
                    } else if let v = Double(trimmed), v > 0 {
                        line.overrideRate = v
                    }
                }
                Text("\(chem.unit.rawValue)\(basisLabel)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Recommended: \(String(format: "%.1f", recommendedRateDisplay)) \(chem.unit.rawValue)\(basisLabel)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func syncOverrideText() {
        if let value = line.overrideRate {
            let formatted = String(format: "%.2f", value)
            if overrideText != formatted, Double(overrideText) != value {
                overrideText = formatted
            }
        } else if !overrideText.isEmpty {
            overrideText = ""
        }
    }
}

// MARK: - Paddock Picker Sheet

/// Multi-select paddock picker used by the Spray Calculator. Mirrors the
/// Maintenance Trip's `MultiPaddockPickerSheet` UX so operators get the same
/// search-and-select experience across flows.
private struct SprayPaddockPickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIds: Set<UUID>
    @State private var searchText: String = ""

    /// Per-row meta line: "1.20 ha · 12 rows · Rows 1–12". Falls back to
    /// "Rows not set" when the paddock has no row geometry.
    static func metaLine(for paddock: Paddock) -> String {
        let ha = String(format: "%.2f ha", paddock.areaHectares)
        let rowCount = paddock.rows.count
        let nums = paddock.rows.map(\.number)
        guard let lo = nums.min(), let hi = nums.max() else {
            return "\(ha) · Rows not set"
        }
        let range = lo == hi ? "Row \(lo)" : "Rows \(lo)–\(hi)"
        return "\(ha) · \(rowCount) row\(rowCount == 1 ? "" : "s") · \(range)"
    }

    private var sortedPaddocks: [Paddock] {
        store.paddocks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var filtered: [Paddock] {
        guard !searchText.isEmpty else { return sortedPaddocks }
        return sortedPaddocks.filter { $0.name.localizedStandardContains(searchText) }
    }

    private var allSelected: Bool {
        !store.paddocks.isEmpty && selectedIds.count == store.paddocks.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.paddocks.isEmpty {
                    ContentUnavailableView {
                        Label("No Blocks", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Create blocks first to plan a spray.")
                    }
                } else {
                    List {
                        Section {
                            Button {
                                if allSelected {
                                    selectedIds.removeAll()
                                } else {
                                    selectedIds = Set(store.paddocks.map(\.id))
                                }
                            } label: {
                                HStack {
                                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(allSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.secondary))
                                    Text(allSelected ? "Deselect All" : "Select All")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(selectedIds.count) of \(store.paddocks.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Section {
                            ForEach(filtered) { paddock in
                                let isSelected = selectedIds.contains(paddock.id)
                                Button {
                                    if isSelected {
                                        selectedIds.remove(paddock.id)
                                    } else {
                                        selectedIds.insert(paddock.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(paddock.name)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text(SprayPaddockPickerSheet.metaLine(for: paddock))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, prompt: "Search blocks")
                }
            }
            .navigationTitle("Select Blocks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Results Card

private struct ResultsCard: View {
    let result: SprayCalculationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Results").font(.title2.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                CalcStatTile(title: "Total Area", value: "\(String(format: "%.2f", result.totalAreaHectares)) ha", icon: "square.dashed", color: VineyardTheme.olive)
                CalcStatTile(title: "Total Water", value: "\(String(format: "%.0f", result.totalWaterLitres)) L", icon: "drop.fill", color: .blue)
                CalcStatTile(title: "Full Tanks", value: "\(result.fullTankCount)", icon: "fuelpump.fill", color: VineyardTheme.earthBrown)
                CalcStatTile(title: "Last Tank", value: "\(String(format: "%.0f", result.lastTankLitres)) L", icon: "drop.halffull", color: .orange)
            }

            if result.concentrationFactor != 1.0 {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Concentration Factor")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(String(format: "%.2f", result.concentrationFactor))×")
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(result.concentrationFactor > 1.0 ? "Concentrate" : "Dilute")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.15))
                        .clipShape(.rect(cornerRadius: 6))
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
            }

            ForEach(result.chemicalResults) { chemResult in
                CalcChemicalResultRow(result: chemResult)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }
}

private struct CalcStatTile: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

private struct CalcChemicalResultRow: View {
    let result: ChemicalCalculationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                Text(result.chemicalName).font(.headline)
                Spacer()
                Text("\(result.unit.fromBase(result.totalAmountRequired), specifier: "%.1f") \(result.unit.rawValue)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VineyardTheme.olive)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Per full tank").font(.caption).foregroundStyle(.secondary)
                    Text("\(result.unit.fromBase(result.amountPerFullTank), specifier: "%.1f") \(result.unit.rawValue)")
                        .font(.subheadline.weight(.medium))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last tank").font(.caption).foregroundStyle(.secondary)
                    Text("\(result.unit.fromBase(result.amountInLastTank), specifier: "%.1f") \(result.unit.rawValue)")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                Text("\(String(format: "%.0f", result.unit.fromBase(result.selectedRate))) \(result.unit.rawValue)/\(result.basis == .perHectare ? "ha" : "100L")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

// MARK: - Costings Card

private struct CostingsCard: View {
    let summary: SprayCostingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.title3)
                    .foregroundStyle(VineyardTheme.vineRed)
                Text("Costings").font(.title2.bold())
            }

            ForEach(summary.chemicalCosts) { cost in
                HStack {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .font(.subheadline)
                    Text(cost.chemicalName).font(.subheadline.weight(.semibold))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$\(String(format: "%.2f", cost.totalCost))")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(VineyardTheme.vineRed)
                        Text("$\(String(format: "%.2f", cost.costPerHectare))/ha")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }

            if let fuel = summary.fuelCost {
                HStack {
                    Image(systemName: "fuelpump.fill")
                        .foregroundStyle(.orange)
                    Text("Fuel — \(fuel.tractorName)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("$\(String(format: "%.2f", fuel.totalFuelCost))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grand Total").font(.subheadline).foregroundStyle(.secondary)
                    Text("$\(String(format: "%.2f", summary.grandTotal))")
                        .font(.title.bold())
                        .foregroundStyle(VineyardTheme.vineRed)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Per Hectare").font(.subheadline).foregroundStyle(.secondary)
                    Text("$\(String(format: "%.2f", summary.grandTotalPerHectare))/ha")
                        .font(.title3.bold())
                        .foregroundStyle(VineyardTheme.earthBrown)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }
}
