import SwiftUI
import CoreLocation

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
    /// Growth stage (guided Step 4).
    ///
    /// One value holds the mode, the shared decision and the per-block
    /// decisions. It replaces the previous trio of loose state variables in
    /// which `nil` had to mean both "unanswered" and "deliberately Not Set" —
    /// which is exactly why choosing the visible `Not Set` option could never
    /// complete the step.
    @State private var growthStage: SprayGrowthStageSelection = SprayGrowthStageSelection()
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

    // Guided flow — Step 3 Target, Step 6 Carrier
    @State private var sprayTargets: Set<SprayTarget> = []
    /// Targets carried in from a Program Step that VineTrack has no typed case
    /// for. Not editable in Step 3 — there is no control for a target the app
    /// cannot name — but carried onto the saved spray so the application still
    /// states what it was for.
    @State private var customSprayTargets: [String] = []
    @State private var sprayHeadTarget: SprayHeadTarget?
    @State private var bandWidthText: String = ""
    @State private var carrierBasisChoice: SprayCarrierBasis = .litresPerHectare
    @State private var diluteLitresPer100mText: String = ""
    @State private var appliedLitresPer100mText: String = ""
    /// Per-product-line area basis for banded jobs. Keyed by `ChemicalLine.id`
    /// because the decision belongs to the individual product, never the job.
    @State private var productAreaBasis: [UUID: SprayProductRateBasis] = [:]
    /// The section the operator has explicitly opened. `nil` follows the flow's
    /// own `activeStep`, so the screen advances by itself as decisions are made.
    @State private var openedStep: SprayGuidedStep?

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
    /// Stage 5B: the `spray_jobs` row this calculator run is executing. Every
    /// record saved from this session carries it as `sprayJobId`, which is
    /// what writes `spray_records.spray_job_id` on sync — the job-originated
    /// completion link. Nil for ad-hoc and template-originated runs.
    private let originSprayJobId: UUID?
    /// Blocks the originating plan/job proposes — applied once at prefill,
    /// fully editable afterwards.
    private let prefillPaddockIds: [UUID]
    /// Program Step configuration: declared intent and identities the operator
    /// already chose once (growth stage, targets, equipment, tractor).
    ///
    /// Configuration ONLY. No chemistry travels through here — products are
    /// still resolved against today's Chemical Store below, and the snapshot is
    /// captured fresh at save time.
    private let prefillProgram: SprayProgramPrefill?
    @State private var prefillApplied: Bool = false
    /// Template/duplicate products that no longer resolve to a saved chemical.
    /// Surfaced so a missing product is a visible gap, never a silent one.
    @State private var unresolvedPrefillProducts: [String] = []

    init(
        prefillRecord: SprayRecord? = nil,
        originSprayJobId: UUID? = nil,
        prefillPaddockIds: [UUID] = [],
        prefillProgram: SprayProgramPrefill? = nil
    ) {
        self.prefillRecord = prefillRecord
        self.originSprayJobId = originSprayJobId
        self.prefillPaddockIds = prefillPaddockIds
        self.prefillProgram = prefillProgram
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
        guard let id = growthStage.sharedStageId else { return nil }
        return phenologyStages.first(where: { $0.id == id })
    }

    private func phenologyStage(_ id: UUID) -> PhenologyStage? {
        phenologyStages.first(where: { $0.id == id })
    }

    /// The collapsed Step 4 line. An unanswered step says so; an explicit
    /// Not Set reads "Not Set" and is a finished state, not an error.
    private var growthStageSummary: String {
        growthStage.summary(selectedBlockIds: selectedPaddockIds) { id in
            guard let stage = phenologyStage(id) else { return nil }
            return "\(stage.code) — \(stage.name)"
        }
    }

    /// Canonical geometry for the current selection — the single source of
    /// truth for row length and row spacing in this screen.
    private var applicationGeometry: SprayApplicationGeometry {
        SprayGeometryResolver.resolve(selectedPaddocks.map { SprayBlockInput.from(paddock: $0) })
    }

    /// Row spacing for the selection, ONLY when every selected block has an
    /// explicitly entered spacing and they agree.
    ///
    /// Deliberately returns `nil` rather than falling back to 2.5 m or
    /// averaging differing spacings. Both of those silently mis-dose the tank:
    /// L/ha is derived as `L/100m × 10_000 / rowSpacing / 100`, so an assumed
    /// spacing propagates straight into the water rate and every product
    /// quantity computed from it.
    private var resolvedRowSpacingMetres: Double? {
        applicationGeometry.uniformRowSpacingMetres
    }

    /// Litres per 100 m of row — independent of row spacing, so it is always
    /// displayable even when spacing is unknown.
    private var litresPer100mValue: Double {
        CanopyWaterRate.litresPer100m(
            size: canopySize,
            density: canopyDensity,
            settings: store.settings.canopyWaterRates
        )
    }

    /// `nil` when row spacing could not be resolved, so callers must handle the
    /// unavailable case instead of receiving a confidently wrong number.
    private var waterRateEntry: CanopyWaterRate.RateEntry? {
        guard let spacing = resolvedRowSpacingMetres else { return nil }
        return CanopyWaterRate.rate(
            size: canopySize,
            density: canopyDensity,
            rowSpacingMetres: spacing,
            settings: store.settings.canopyWaterRates
        )
    }

    private var chosenSprayRate: Double {
        Double(sprayRateText) ?? (waterRateEntry?.litresPerHa ?? 0)
    }

    private var concentrationFactor: Double {
        guard chosenSprayRate > 0, let diluteRate = waterRateEntry?.litresPerHa else { return 1.0 }
        return diluteRate / chosenSprayRate
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

    // MARK: - Guided flow

    /// The vineyard's spray profile — read from the vineyard, never re-derived
    /// here.
    ///
    /// `Vineyard.sprayProfile` owns the whole resolution order (stored sql/192
    /// value → country fallback → safe default), so this screen must NOT inspect
    /// country or region settings itself: a vineyard that has deliberately
    /// chosen the AU profile while sitting in NZ would otherwise be silently
    /// forced back onto SWNZ by its own address.
    ///
    /// The region country is used ONLY when no vineyard is selected at all,
    /// which is the same safe default the vineyard accessor would apply.
    /// Resolution never writes anything back to the database.
    private var sprayProfile: SprayVineyardProfile {
        store.selectedVineyard?.sprayProfile
            ?? SprayVineyardProfile(countryCode: store.settings.regionSettings.countryCode)
    }

    /// The carrier workflow actually in force, resolved exactly as the engine
    /// resolves it: the operator's choice when the vineyard profile allows
    /// either, and the profile's mandate when it does not.
    ///
    /// Read directly rather than through `flow.effectiveCarrierBasis` so a
    /// prefill loop does not build a whole application plan per product line.
    private var effectiveCarrierBasis: SprayCarrierBasis {
        sprayProfile.allows(carrierBasisChoice)
            ? carrierBasisChoice
            : sprayProfile.defaultCarrierBasis
    }

    /// The label rate bases this vineyard's workflow starts from, strongest
    /// first. A 100 m runoff job prefers the label's per-100 L rate; an L/ha
    /// job prefers its per-hectare rate. Neither suppresses the other, and
    /// neither is ever converted into the other.
    private var preferredRateBases: [ChemicalRateBasis] {
        SprayRateBasisPreference.order(for: effectiveCarrierBasis)
    }

    /// The tank capacity of the selected spray unit — the only figure the tank
    /// split may be derived from.
    private var selectedTankCapacityLitres: Double {
        selectedEquipmentId
            .flatMap { id in store.sprayEquipment.first(where: { $0.id == id }) }?
            .tankCapacityLitres ?? 0
    }

    /// Maps the operator's chemical lines onto engine product inputs.
    ///
    /// Each line carries its OWN rate basis: a per-100 L label stays per-100 L,
    /// and an area-rated label resolves to whole-block unless the operator chose
    /// the treated band for that specific line.
    private var guidedProductLines: [SprayProductLineInput] {
        chemicalLines.compactMap { line -> SprayProductLineInput? in
            guard let chemical = store.savedChemicals.first(where: { $0.id == line.chemicalId })
            else { return nil }
            // Structured `registeredUses[].rates` are authoritative; the
            // resolver falls back to the legacy `rates` array only when the
            // record carries no structured rate at all. It also refuses a rate
            // whose basis disagrees with the line's, so a per-hectare rate can
            // never be dosed against carrier volume (or the reverse), and a
            // range or a reference-only entry never seeds a dose — the operator
            // establishes those through the override field.
            let seededRate = SprayRegisteredUseRates.seedValue(
                for: chemical,
                rateId: line.selectedRateId,
                basis: line.basis
            )
            // The legacy `ratePerHa` scalar is the last-resort fallback for
            // pre-Chemical-Intelligence records, and is a PER-HECTARE number:
            // it is never valid for a per-100 L line, and never consulted once
            // the record carries structured rates.
            let legacyScalarRate: Double? = SprayRegisteredUseRates.hasStructuredRates(chemical)
                ? nil
                : (line.basis == .perHectare ? chemical.ratePerHa : nil)
            let rate = line.overrideRate ?? seededRate ?? legacyScalarRate ?? 0
            let chosenAreaBasis = productAreaBasis[line.id]
            let basis: SprayProductRateBasis = {
                switch line.basis {
                case .per100Litres:
                    return .per100Litres
                case .perHectare:
                    // Legacy `per_hectare` means WHOLE BLOCK — never treated area.
                    return chosenAreaBasis ?? .wholeBlockArea
                }
            }()
            return SprayProductLineInput(
                productId: chemical.id.uuidString,
                name: chemical.name,
                unit: chemical.unit.rawValue,
                basis: basis,
                rate: rate,
                costPerUnit: chemical.purchase?.costPerBaseUnit,
                // Whole block is what the screen SHOWS until the operator
                // chooses, but on a banded pass it is not yet a decision. The
                // flag keeps that distinction so the flow can insist on an
                // answer instead of persisting an unconfirmed default.
                isAreaBasisExplicit: chosenAreaBasis != nil
            )
        }
    }

    /// Everything the operator has entered, as plain data.
    private var guidedInputs: SprayGuidedInputs {
        var inputs = SprayGuidedInputs()
        inputs.sprayName = sprayName
        inputs.operationType = operationType
        inputs.blocks = selectedPaddocks.map { SprayBlockInput.from(paddock: $0) }
        inputs.targets = sprayTargets
        inputs.customTargets = customSprayTargets
        inputs.sprayHeadTarget = sprayHeadTarget
        inputs.bandWidthTotalMetres = Double(bandWidthText)
        inputs.isGrowthStageResolved = isGrowthStageResolved
        inputs.isEquipmentSelected = selectedEquipmentId != nil
        inputs.tankCapacityLitres = selectedTankCapacityLitres
        inputs.carrierBasis = carrierBasisChoice
        inputs.litresPerHectare = Double(sprayRateText)
        inputs.diluteLitresPerHectare = waterRateEntry?.litresPerHa
        inputs.diluteLitresPer100Metres = Double(diluteLitresPer100mText)
        inputs.appliedLitresPer100Metres = Double(appliedLitresPer100mText)
        inputs.products = guidedProductLines
        inputs.notes = notes
        return inputs
    }

    /// THE single bridge to `SprayApplicationPlanner.plan`. Every calculated
    /// figure this screen displays is read back off `flow.plan` — the View does
    /// no arithmetic of its own.
    private var flow: SprayGuidedFlow {
        SprayGuidedFlow(inputs: guidedInputs, profile: sprayProfile)
    }

    // MARK: - Live Resistance Check
    //
    // This screen owns NO resistance rules. It assembles the spray being composed and
    // hands it to `SprayResistanceCheck`, which routes it through the same Planner and
    // Engine the standalone Resistance Planner uses. Groups detected, previous uses,
    // repeat warnings, severity and recommendations therefore come from one
    // implementation — a vineyard shown "good fit" here and "would exceed strategy"
    // in the Planner would have no reason to believe either.

    private var resistanceSeasonCalendar: ResistanceSeasonCalendar {
        ResistanceSeasonCalendar(
            startMonth: store.settings.seasonStartMonth,
            startDay: store.settings.seasonStartDay,
            timeZoneIdentifier: store.settings.timezone.isEmpty
                ? TimeZone.current.identifier
                : store.settings.timezone
        )
    }

    /// From the VINEYARD's stored country — never the phone locale. An Australian
    /// operator managing a New Zealand vineyard must not drag the Australian strategy
    /// across the Tasman.
    private var resistanceJurisdiction: ResistanceJurisdiction {
        ResistanceJurisdiction.fromCountryCode(store.selectedVineyard?.country)
    }

    /// The live check for the spray as currently composed.
    ///
    /// Evaluated once per render of the chemicals section and shared across the
    /// product lines, rather than per line: the history scan is over every spray
    /// record the vineyard holds.
    private var resistanceCheck: SprayResistanceCheck.Result {
        let diseases = SprayResistanceCheck.diseases(from: sprayTargets)
        guard !diseases.isEmpty, let vineyardId = store.selectedVineyardId else {
            return .notApplicable
        }
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let products = chemicalLines.compactMap { line -> ResistancePlannedProduct? in
            guard let chemical = store.savedChemicals.first(where: { $0.id == line.chemicalId })
            else { return nil }
            return SprayResistanceCheck.product(
                from: chemical,
                lineId: line.id.uuidString,
                // Registered-use evidence is disease-specific, so it is only stated
                // when this spray targets exactly one disease. Otherwise it stays
                // unknown rather than being asserted for the wrong one.
                disease: diseases.count == 1 ? diseases[0] : nil
            )
        }
        // The SAME history adapter the Planner uses, so neither surface can be
        // reading a different set of past applications.
        let inputs = store.sprayRecords.map { ResistanceEventSource.input(from: $0) }
        let history = ResistanceEventSource.events(
            from: inputs,
            seasonCalendar: resistanceSeasonCalendar
        )
        return SprayResistanceCheck.evaluate(
            SprayResistanceCheck.Request(
                vineyardId: vineyardId.uuidString,
                blockIds: selectedPaddocks.map { $0.id.uuidString },
                diseases: diseases,
                products: products,
                jurisdiction: resistanceJurisdiction,
                season: resistanceSeasonCalendar.season(epochMs: nowMs),
                seasonCalendar: resistanceSeasonCalendar,
                events: history.events,
                unresolvedApplications: history.unresolvedBlockApplications,
                nowMs: nowMs
            )
        )
    }

    /// Whether the growth-stage DECISION has been made for the current block
    /// selection — not whether an E-L stage exists.
    ///
    /// `EL12 / EL9 / Not Set` across three blocks is a complete answer.
    private var isGrowthStageResolved: Bool {
        growthStage.isResolved(selectedBlockIds: selectedPaddockIds)
    }

    /// Mode switch. Copying a REAL shared stage down to the blocks is preserved;
    /// an unresolved shared answer copies nothing, so switching modes can never
    /// classify an untouched block as though someone decided about it.
    private var growthStageModeBinding: Binding<GrowthStageMode> {
        Binding(
            get: { growthStage.mode },
            set: { growthStage.setMode($0, selectedBlockIds: selectedPaddockIds) }
        )
    }

    /// The section currently expanded: the operator's explicit choice, otherwise
    /// whatever the flow says still needs attention.
    private var expandedStep: SprayGuidedStep {
        openedStep ?? flow.activeStep
    }

    private func toggle(_ step: SprayGuidedStep) {
        withAnimation(.spring(duration: 0.3)) {
            openedStep = expandedStep == step ? nil : step
        }
    }

    @ViewBuilder
    private func guidedCard<Content: View>(
        _ step: SprayGuidedStep,
        _ index: Int,
        summary: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GuidedStepCard(
            step: step,
            index: index,
            isLocked: !flow.isUnlocked(step),
            isDone: flow.isComplete(step),
            isExpanded: expandedStep == step,
            summary: summary,
            onToggle: { toggle(step) },
            content: content
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    guidedCard(.application, 1, summary: applicationSummary) {
                        sprayNameSection
                        operationTypeSection
                    }
                    guidedCard(.blocks, 2, summary: blocksSummary) {
                        paddockSelection
                        blockGeometrySummary
                    }
                    guidedCard(.target, 3, summary: targetSummary) {
                        targetSection
                    }
                    guidedCard(.growthStage, 4, summary: growthStageSummaryLine) {
                        growthStageSection
                    }
                    guidedCard(.equipment, 5, summary: equipmentSummary) {
                        equipmentSelection
                        tractorSelection
                        mixTripSetupSection
                    }
                    guidedCard(.carrier, 6, summary: carrierSummary) {
                        carrierVolumeSection
                    }
                    guidedCard(.products, 7, summary: productsSummary) {
                        chemicalLinesSection
                    }
                    guidedCard(.review, 8, summary: reviewSummary) {
                        reviewSection
                    }

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
                // Search → Select → Review → Save, the same single flow the
                // Chemical Store and the Spray Program use. Adding a product
                // starts with identifying it, never with a blank form.
                ChemicalMatchFlowView()
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
            .onChange(of: selectedPaddockIds) { _, newValue in
                clampStartPath()
                // Decisions for blocks that are no longer selected are dropped;
                // decisions for blocks that remain are kept, and a newly added
                // block simply has no entry, so it starts unresolved.
                growthStage.prune(to: newValue)
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

        // Equipment and tractor by IDENTITY first, display name only as the
        // legacy fallback. A renamed spray unit still resolves, and a name that
        // matches nothing simply leaves the step for the operator.
        let equipmentId = r.sprayEquipmentId ?? prefillProgram?.equipmentId
        if let equipmentId, store.sprayEquipment.contains(where: { $0.id == equipmentId }) {
            selectedEquipmentId = equipmentId
        } else if !r.equipmentType.isEmpty {
            selectedEquipmentId = store.sprayEquipment.first(where: { $0.name == r.equipmentType })?.id
        }
        let tractorId = r.tractorId ?? prefillProgram?.tractorId
        if let tractorId, store.tractors.contains(where: { $0.id == tractorId }) {
            selectedTractorId = tractorId
        } else if !r.tractor.isEmpty {
            selectedTractorId = store.tractors.first(where: { $0.displayName == r.tractor || $0.name == r.tractor })?.id
        }

        // Targets (guided Step 3). Taken from the Program Step's declared
        // intent, falling back to the record's own frozen targets. This feeds
        // the EXISTING `sprayTargets` state — there is no second target model
        // and no alternative calculation path.
        //
        // `sprayHeadTarget` is deliberately NOT prefilled: no Program Step
        // source carries it, and defaulting where the head is aimed would
        // silently decide a banded application's treated area.
        let programTargets = prefillProgram?.targets ?? []
        let recordTargets = r.applicationGeometry?.targets ?? []
        let resolvedTargets = programTargets.isEmpty ? recordTargets : programTargets
        if !resolvedTargets.isEmpty {
            sprayTargets = Set(resolvedTargets)
        }

        // The vineyard's own targets travel too. They have no Step 3 control —
        // the calculator can only draw a chip for a target it has a case for —
        // but dropping them would silently change what a Phomopsis spray claims
        // to be for. They are never mapped onto a built-in target.
        let programCustomTargets = prefillProgram?.customTargets ?? []
        let recordCustomTargets = r.applicationGeometry?.customTargets ?? []
        customSprayTargets = programCustomTargets.isEmpty ? recordCustomTargets : programCustomTargets

        // Growth stage (guided Step 4) from the canonical `growth_stage_code`,
        // mapped onto the calculator's own stage state rather than appended to
        // notes. Compared as STAGE NUMBERS through the existing parser so
        // "EL12", "E-L 12" and "el 12" all land on the same stage.
        //
        // A Program Step that STATES a stage has answered the question, so the
        // decision is resolved as well as valued. A Program Step that states
        // nothing leaves Step 4 unresolved on purpose: "the Program did not
        // specify a stage" is not "the operator chose no stage for this
        // application".
        growthStage.applyProgramPrefill(
            code: prefillProgram?.growthStageCode,
            stages: phenologyStages.map { (id: $0.id, code: $0.code) },
            selectedBlockIds: selectedPaddockIds
        )

        if !prefillPaddockIds.isEmpty {
            // Plan/job prefill: only the blocks the plan genuinely proposed.
            selectedPaddockIds = Set(prefillPaddockIds)
        } else if let trip = store.trips.first(where: { $0.id == r.tripId }) {
            // A generic Program Step has no trip and no block scope, so this
            // resolves to nothing and the operator still chooses at Step 2.
            // Blocks are never invented from the vineyard's current paddocks.
            selectedPaddockIds = Set(trip.paddockIds)
        }

        if let firstTank = r.tanks.first {
            var lines: [ChemicalLine] = []
            var unresolved: [String] = []
            for chem in firstTank.chemicals {
                // Resolve the product the TEMPLATE POINTS AT, not the chemistry
                // it was recorded with. A template is configuration: reusing it
                // in November must pick up November's classification, so only
                // the identity is carried across and the snapshot is captured
                // fresh at save time by `chemicalSnapshot(for:)`.
                let (saved, _) = ChemicalSnapshotCapture.resolve(
                    savedChemicalId: chem.savedChemicalId,
                    productName: chem.name,
                    registrationIdentityKey: chem.chemicalSnapshot?.registrationIdentityKey,
                    in: store.savedChemicals
                )
                guard let saved else {
                    // The calculator can only price a line against a saved
                    // chemical, so an unresolvable product cannot become a
                    // line here. Name it instead of dropping it in silence —
                    // an operator who can see what went missing can re-add it;
                    // one who can't will ship a spray with a hole in it.
                    let name = chem.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    unresolved.append(name.isEmpty ? "Unnamed product" : name)
                    continue
                }
                // An EXPLICIT basis recorded on the template line is a decision
                // the operator already made; a vineyard-level preference must
                // never overrule it. Only a line that never recorded one falls
                // through to the workflow's preference.
                //
                // The rule this replaces read the legacy `ratePer100L` scalar,
                // which the consolidated Chemical Store no longer edits: a
                // product whose only label rate is per-100 L projects 0 into
                // that column, so every prefill silently chose per hectare.
                let explicitBasis: RateBasis? = chem.rateBasis.map { basis in
                    basis == .per100Litres ? .per100Litres : .perHectare
                }
                let preferredOrder: [RateBasis] = explicitBasis.map { [$0] } ?? preferredRateBases
                let preferredBasis: RateBasis = explicitBasis
                    ?? SprayRateBasisPreference.fallbackBasis(for: effectiveCarrierBasis)
                // Structured registered-use rates first, legacy rates only when
                // the record has none.
                let selection = SprayRegisteredUseRates.defaultSelection(
                    for: saved, preferring: preferredOrder
                )
                lines.append(
                    ChemicalLine(
                        chemicalId: saved.id,
                        selectedRateId: selection?.id ?? UUID(),
                        basis: selection?.basis ?? preferredBasis
                    )
                )
            }
            chemicalLines = lines
            unresolvedPrefillProducts = unresolved
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
                Picker("", selection: growthStageModeBinding) {
                    Text("Same for All").tag(GrowthStageMode.same)
                    Text("Per Paddock").tag(GrowthStageMode.perPaddock)
                }
                .pickerStyle(.segmented)

                if growthStage.mode == .same {
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

            // Not Set is a real answer, so it is only shown as chosen once the
            // operator has actually chosen it. Before that the radio is empty:
            // an unanswered step must never look answered.
            let isNotSetSelected = growthStage.shared == .notSet
            Button {
                growthStage.selectSharedNotSet(selectedBlockIds: selectedPaddockIds)
            } label: {
                HStack {
                    Image(systemName: isNotSetSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isNotSetSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                    Text(SprayGrowthStageCopy.notSet).foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider().padding(.leading, 40)

            ForEach(phenologyStages) { stage in
                let isSelected = growthStage.sharedStageId == stage.id
                Button {
                    growthStage.selectShared(stageId: stage.id, selectedBlockIds: selectedPaddockIds)
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
                        if let stageId = growthStage.perBlock[paddock.id]?.stageId,
                           let stage = phenologyStage(stageId) {
                            Text("\(stage.name) (\(stage.code))")
                                .font(.caption2)
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                    Spacer()
                    Menu {
                        // Explicit Not Set for THIS block — recorded as a
                        // decision, not as the absence of one.
                        Button(SprayGrowthStageCopy.notSet) {
                            growthStage.select(blockId: paddock.id, decision: .notSet)
                        }
                        ForEach(phenologyStages) { stage in
                            Button("\(stage.code) – \(stage.name)") {
                                growthStage.select(blockId: paddock.id, decision: .stage(stage.id))
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            // "Select" means unanswered; an explicit Not Set
                            // shows as "Not Set".
                            Text(growthStage.blockLabel(for: paddock.id) { phenologyStage($0)?.code })
                                .font(growthStage.perBlock[paddock.id]?.stageId == nil
                                      ? .caption
                                      : .caption.weight(.semibold))
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
                        if let perHa = waterRateEntry?.litresPerHa {
                            Text("\(String(format: "%.0f", perHa)) L/ha")
                                .font(.title3.bold())
                                .foregroundStyle(VineyardTheme.olive)
                        } else {
                            Text("—")
                                .font(.title3.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Per 100m row")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.0f", litresPer100mValue)) L")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(12)
                .background(VineyardTheme.olive.opacity(0.08))
                .clipShape(.rect(cornerRadius: 10))

                if let spacing = resolvedRowSpacingMetres {
                    Text("Row spacing: \(String(format: "%.1f", spacing))m")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Label(
                        selectedPaddocks.count > 1
                            ? "Selected blocks have missing or differing row spacing — set a matching row spacing in block details to calculate L/ha."
                            : "Set row spacing in block details to calculate L/ha.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

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
        .onChange(of: waterRateEntry?.litresPerHa) { _, newValue in
            if !hasEditedSprayRate, let newValue {
                sprayRateText = String(format: "%.0f", newValue)
            }
        }
        .onAppear {
            if sprayRateText.isEmpty, let perHa = waterRateEntry?.litresPerHa {
                sprayRateText = String(format: "%.0f", perHa)
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
        let line = chemicalLines.first(where: { $0.chemicalId == chemResult.savedChemicalId })
        // Restrictions belong to the registered use the operator actually
        // picked a rate from. The product-level field is the fallback for
        // records with no structured uses, never a substitute for a use that
        // states its own — a second crop's wording is not this job's law.
        let selectedUse: ChemicalRegisteredUse? = {
            guard let saved, let line else { return nil }
            return SprayRegisteredUseRates.registeredUse(for: saved, rateId: line.selectedRateId)
        }()
        let useRestrictions = selectedUse?.restrictions?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let restrictions = useRestrictions.isEmpty ? (saved?.restrictions ?? "") : useRestrictions
        let isOverridden: Bool = line?.overrideRate != nil

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
                    Text("\(SprayRateFormatter.format(chemResult.unit.fromBase(chemResult.selectedRate))) \(chemResult.unit.rawValue)/\(chemResult.basis == .perHectare ? "ha" : "100L")")
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
                // Verbatim, with the shared expand control. A two-line clamp
                // used to hide the rest of a legal statement at the one moment
                // the operator is deciding what to put in the tank.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    ChemicalUseRestrictionsView(text: restrictions)
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

    /// The plan's calculated line for each chemical line on screen.
    ///
    /// Built by walking `chemicalLines` in the SAME order and with the same skip
    /// rule as `guidedProductLines`, so two lines using one chemical stay
    /// distinct — matching on product id alone would collapse them.
    private var planLinesByChemicalLineId: [UUID: SprayProductLineResult] {
        let planLines = flow.plan.productLines
        var mapped: [UUID: SprayProductLineResult] = [:]
        var index = 0
        for line in chemicalLines {
            guard store.savedChemicals.contains(where: { $0.id == line.chemicalId }) else { continue }
            if index < planLines.count { mapped[line.id] = planLines[index] }
            index += 1
        }
        return mapped
    }

    /// Whether this line must ask the Whole Block vs Treated Band question.
    ///
    /// Asked ONLY for an area-rated label on a banded pass. A per-100 L product
    /// is never asked — its basis is the carrier, not the ground. A whole-block
    /// pass is never asked either, because treated and gross are the same thing.
    private func showsAreaBasisPicker(for line: ChemicalLine) -> Bool {
        flow.requiresBandWidth && line.basis == .perHectare
    }

    private var chemicalLinesSection: some View {
        // Evaluated once here and shared by every line below, rather than recomputed
        // per product: the check reads the vineyard's whole spray history.
        let check = resistanceCheck
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Chemicals", icon: "flask")

            ForEach($chemicalLines) { $line in
                VStack(alignment: .leading, spacing: 8) {
                    CalcChemicalLineCard(
                        line: $line,
                        chemicals: store.savedChemicals,
                        preferredRateBases: preferredRateBases
                    ) {
                        chemicalLines.removeAll { $0.id == line.id }
                    }

                    if showsAreaBasisPicker(for: line) {
                        GuidedProductBasisPicker(
                            selected: productAreaBasis[line.id] ?? .wholeBlockArea
                        ) { basis in
                            withAnimation(.snappy(duration: 0.2)) {
                                productAreaBasis[line.id] = basis
                            }
                        }
                        if productAreaBasis[line.id] == nil {
                            Text("Choose an area basis for this product before continuing.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    // The calculated explanation, straight off the plan.
                    if let planLine = planLinesByChemicalLineId[line.id] {
                        GuidedProductCalculationRow(line: planLine)
                    }

                    // The Live Resistance Check, immediately beneath the chemistry
                    // it judges. Shows only the findings that concern the groups
                    // THIS product carries; silence is never dressed up as a pass.
                    ResistanceCheckSlot(
                        isApplicable: flow.isResistanceCheckApplicable,
                        findings: check.findings(forProductId: line.id.uuidString)
                    )
                }
                .padding(.bottom, 4)
            }

            Button {
                if let chem = store.savedChemicals.first {
                    // A product added by hand seeds from the same workflow
                    // preference as everything else on this screen.
                    let selection = SprayRegisteredUseRates.defaultSelection(
                        for: chem, preferring: preferredRateBases
                    )
                    chemicalLines.append(
                        ChemicalLine(
                            chemicalId: chem.id,
                            selectedRateId: selection?.id ?? UUID(),
                            basis: selection?.basis
                                ?? SprayRateBasisPreference.fallbackBasis(for: effectiveCarrierBasis)
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

    // MARK: - Guided step summaries
    //
    // One-line recaps shown when a completed step collapses, so the operator can
    // see every decision made so far without scrolling the whole form.

    private var applicationSummary: String {
        let name = sprayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? operationType.rawValue : "\(operationType.rawValue) — \(name)"
    }

    private var blocksSummary: String {
        guard !selectedPaddocks.isEmpty else { return "No blocks selected" }
        let names = selectedPaddocks.map(\.name).joined(separator: ", ")
        return "\(names) — \(SprayGuidedFormat.hectares(flow.plan.grossAreaHectares)) gross"
    }

    private var targetSummary: String {
        guard !sprayTargets.isEmpty else { return "Not set" }
        let names = SprayTarget.presentationOrder
            .filter { sprayTargets.contains($0) }
            .map(\.label)
            .joined(separator: ", ")
        if operationType == .bandedSpray, let treated = flow.plan.treatedAreaHectares {
            return "\(names) — \(SprayGuidedFormat.hectares(treated)) treated"
        }
        if let head = sprayHeadTarget {
            return "\(names) — \(head.label)"
        }
        return names
    }

    private var growthStageSummaryLine: String { growthStageSummary }

    private var equipmentSummary: String {
        guard selectedEquipmentId != nil else { return "Not selected" }
        let jets = numberOfFansJets.trimmingCharacters(in: .whitespacesAndNewlines)
        return jets.isEmpty
            ? selectedEquipmentName
            : "\(selectedEquipmentName) — \(jets) fans/jets"
    }

    private var carrierSummary: String {
        guard flow.isCarrierResolved else { return "Not set" }
        let carrier = flow.plan.carrier
        switch carrier.basis {
        case .litresPerHectare:
            return "\(SprayGuidedFormat.litresPerHectare(carrier.litresPerHectare)) — \(SprayGuidedFormat.litres(carrier.totalLitres)) total"
        case .litresPer100Metres:
            return "\(SprayGuidedFormat.litresPer100m(carrier.appliedLitresPer100Metres)) — \(SprayGuidedFormat.litres(carrier.totalLitres)) total"
        }
    }

    private var productsSummary: String {
        let lines = flow.plan.productLines
        guard !lines.isEmpty else { return "No products added" }
        let unresolved = lines.filter(\.isUnresolved).count
        let base = lines.count == 1 ? "1 product" : "\(lines.count) products"
        return unresolved > 0 ? "\(base) — \(unresolved) unavailable" : base
    }

    private var reviewSummary: String {
        flow.isComplete ? "Ready to save or start" : (flow.firstBlocker?.title ?? "Incomplete")
    }

    // MARK: - Step 2 — calculated block geometry

    /// Compact, READ-ONLY geometry recap straight from the canonical resolver.
    /// The operator never types these numbers.
    @ViewBuilder
    private var blockGeometrySummary: some View {
        let plan = flow.plan
        let geometry = plan.geometry

        if !selectedPaddocks.isEmpty {
            GuidedCalculatedPanel(title: "Calculated from block setup") {
                VStack(spacing: 8) {
                    GuidedCalculatedRow(
                        label: "Gross area",
                        value: SprayGuidedFormat.hectares(plan.grossAreaHectares),
                        emphasis: true
                    )
                    if let metres = geometry.totalRowLengthMetres {
                        GuidedCalculatedRow(
                            label: "Total row / trellis length",
                            value: SprayGuidedFormat.metres(metres),
                            caption: SprayGuidedFormat.geometrySourceLabel(geometry.source)
                        )
                    }
                    if let spacing = geometry.uniformRowSpacingMetres {
                        GuidedCalculatedRow(
                            label: "Row spacing",
                            value: SprayGuidedFormat.metres(spacing, decimals: 1)
                        )
                    } else if selectedPaddocks.count > 1 {
                        GuidedCalculatedRow(label: "Row spacing", value: "Mixed across blocks")
                    }
                }
            }
        }

        if let blocker = flow.blocker(for: .blocks), blocker != .noBlocksSelected {
            GuidedBlockerBanner(blocker: blocker) { showSprayPaddockPicker = true }
        }
    }

    // MARK: - Step 3 — Target

    @ViewBuilder
    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What are you targeting?")
                    .font(.subheadline.weight(.semibold))
                Text("Select every pest, disease or purpose this spray addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(SprayTarget.presentationOrder) { target in
                        GuidedChip(
                            label: target.label,
                            icon: target.iconName,
                            isSelected: sprayTargets.contains(target)
                        ) {
                            withAnimation(.snappy(duration: 0.2)) {
                                if sprayTargets.contains(target) {
                                    sprayTargets.remove(target)
                                } else {
                                    sprayTargets.insert(target)
                                }
                            }
                        }
                    }
                }
            }

            // The application-specific question. Foliar asks where the head is
            // aimed; banded asks for the treated width; spreader asks neither.
            if flow.requiresSprayHeadTarget {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Spray Head Target")
                        .font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(SprayHeadTarget.allCases) { head in
                            GuidedChip(
                                label: head.label,
                                icon: nil,
                                isSelected: sprayHeadTarget == head
                            ) {
                                withAnimation(.snappy(duration: 0.2)) { sprayHeadTarget = head }
                            }
                        }
                    }
                    if let detail = sprayHeadTarget?.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if flow.requiresBandWidth {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Total Treated Band Width")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("0.80", text: $bandWidthText)
                            .keyboardType(.decimalPad)
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                        Text("m")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("Total sprayed width per row, both sides combined.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    // Gross and treated BOTH come from the plan the moment a
                    // band width exists. The View computes neither.
                    if flow.bandWidth != nil {
                        GuidedCalculatedPanel(title: "Application geometry") {
                            VStack(spacing: 8) {
                                GuidedCalculatedRow(
                                    label: "Gross area",
                                    value: SprayGuidedFormat.hectares(flow.plan.grossAreaHectares)
                                )
                                GuidedCalculatedRow(
                                    label: "Treated area",
                                    value: SprayGuidedFormat.hectares(flow.plan.treatedAreaHectares),
                                    emphasis: true
                                )
                            }
                        }
                    }
                }
            }

            if let blocker = flow.blocker(for: .target) {
                GuidedBlockerBanner(blocker: blocker) { showSprayPaddockPicker = true }
            }
        }
    }

    // MARK: - Step 6 — Carrier Volume

    @ViewBuilder
    private var carrierVolumeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Only offer a choice when the vineyard profile genuinely allows one.
            // An NZ/SWNZ vineyard is locked to L/100 m and sees no L/ha option.
            if flow.isCarrierBasisLocked {
                Label(
                    "This vineyard records carrier volume in \(SprayGuidedFormat.carrierBasisLabel(flow.effectiveCarrierBasis)).",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Carrier volume basis")
                        .font(.subheadline.weight(.semibold))
                    Picker("Carrier basis", selection: $carrierBasisChoice) {
                        Text("L/100 m").tag(SprayCarrierBasis.litresPer100Metres)
                        Text("L/ha").tag(SprayCarrierBasis.litresPerHectare)
                    }
                    .pickerStyle(.segmented)
                }
            }

            if flow.effectiveCarrierBasis == .litresPer100Metres {
                litresPer100mFields
            } else {
                waterRateSection
            }

            if let blocker = flow.blocker(for: .carrier) {
                GuidedBlockerBanner(blocker: blocker) { showSprayPaddockPicker = true }
            }
        }
    }

    /// Row-length carrier entry. The operator enters ONLY the two L/100 m rates;
    /// concentration factor, total litres and equivalent L/ha are all read back
    /// from the plan.
    @ViewBuilder
    private var litresPer100mFields: some View {
        let carrier = flow.plan.carrier

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dilute / Runoff Volume")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    TextField("40", text: $diluteLitresPer100mText)
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 8))
                    Text("L/100 m").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Actual Applied Volume")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    TextField("20", text: $appliedLitresPer100mText)
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 8))
                    Text("L/100 m").font(.caption).foregroundStyle(.secondary)
                }
            }

            if flow.isCarrierResolved {
                GuidedCalculatedPanel(title: "Calculated carrier volume") {
                    VStack(spacing: 8) {
                        GuidedCalculatedRow(
                            label: "Concentration factor",
                            value: SprayGuidedFormat.factor(carrier.concentrationFactor)
                        )
                        GuidedCalculatedRow(
                            label: "Total carrier",
                            value: SprayGuidedFormat.litres(carrier.totalLitres),
                            emphasis: true
                        )
                        if let perHa = carrier.litresPerHectare {
                            GuidedCalculatedRow(
                                label: "Equivalent applied volume",
                                value: SprayGuidedFormat.litresPerHectare(perHa),
                                caption: "Derived from row spacing — not entered"
                            )
                        } else {
                            GuidedCalculatedRow(
                                label: "Equivalent applied volume",
                                value: "—",
                                caption: "Needs one matching row spacing across blocks"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step 10 — Review

    /// A REVIEW, not another editable form. Every figure is assembled from the
    /// one `SprayApplicationPlan`; each group offers a jump back to its section.
    @ViewBuilder
    private var reviewSection: some View {
        let plan = flow.plan
        let carrier = plan.carrier

        VStack(alignment: .leading, spacing: 10) {
            GuidedReviewGroup(title: "Application", onEdit: { toggle(.application) }) {
                VStack(alignment: .leading, spacing: 6) {
                    GuidedReviewRow(label: "Method", value: operationType.rawValue)
                    if !sprayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        GuidedReviewRow(label: "Name", value: sprayName)
                    }
                }
            }

            GuidedReviewGroup(title: "Blocks & geometry", onEdit: { toggle(.blocks) }) {
                VStack(alignment: .leading, spacing: 6) {
                    GuidedReviewRow(
                        label: "Blocks",
                        value: selectedPaddocks.map(\.name).joined(separator: ", ")
                    )
                    GuidedReviewRow(
                        label: "Gross area",
                        value: SprayGuidedFormat.hectares(plan.grossAreaHectares)
                    )
                    if let metres = plan.geometry.totalRowLengthMetres {
                        GuidedReviewRow(
                            label: "Canonical row length",
                            value: SprayGuidedFormat.metres(metres)
                        )
                    }
                }
            }

            GuidedReviewGroup(title: "Target", onEdit: { toggle(.target) }) {
                VStack(alignment: .leading, spacing: 6) {
                    GuidedReviewRow(
                        label: "Target(s)",
                        value: SprayTarget.presentationOrder
                            .filter { sprayTargets.contains($0) }
                            .map(\.label)
                            .joined(separator: ", ")
                    )
                    if let head = sprayHeadTarget, flow.requiresSprayHeadTarget {
                        GuidedReviewRow(label: "Spray head", value: head.label)
                    }
                    if flow.requiresBandWidth {
                        GuidedReviewRow(
                            label: "Band width",
                            value: SprayGuidedFormat.metres(
                                plan.treatedArea.bandWidth?.totalMetres,
                                decimals: 2
                            )
                        )
                        GuidedReviewRow(
                            label: "Treated area",
                            value: SprayGuidedFormat.hectares(plan.treatedAreaHectares)
                        )
                    }
                }
            }

            GuidedReviewGroup(title: "Growth stage", onEdit: { toggle(.growthStage) }) {
                GuidedReviewRow(label: "Stage", value: growthStageSummary)
            }

            GuidedReviewGroup(title: "Equipment", onEdit: { toggle(.equipment) }) {
                VStack(alignment: .leading, spacing: 6) {
                    GuidedReviewRow(label: "Spray unit", value: selectedEquipmentName)
                    GuidedReviewRow(
                        label: "Fans / jets",
                        value: numberOfFansJets.isEmpty ? "Not set" : numberOfFansJets,
                        isMuted: numberOfFansJets.isEmpty
                    )
                    GuidedReviewRow(label: "Tractor", value: selectedTractorName)
                }
            }

            GuidedReviewGroup(title: "Carrier volume", onEdit: { toggle(.carrier) }) {
                VStack(alignment: .leading, spacing: 6) {
                    GuidedReviewRow(
                        label: "Basis",
                        value: SprayGuidedFormat.carrierBasisLabel(carrier.basis)
                    )
                    if carrier.basis == .litresPer100Metres {
                        GuidedReviewRow(
                            label: "Dilute / runoff",
                            value: SprayGuidedFormat.litresPer100m(carrier.diluteLitresPer100Metres)
                        )
                        GuidedReviewRow(
                            label: "Actual applied",
                            value: SprayGuidedFormat.litresPer100m(carrier.appliedLitresPer100Metres)
                        )
                    }
                    GuidedReviewRow(
                        label: "Concentration",
                        value: SprayGuidedFormat.factor(carrier.concentrationFactor)
                    )
                    GuidedReviewRow(
                        label: "Total carrier",
                        value: SprayGuidedFormat.litres(carrier.totalLitres)
                    )
                    GuidedReviewRow(
                        label: "Equivalent L/ha",
                        value: SprayGuidedFormat.litresPerHectare(carrier.litresPerHectare)
                    )
                    GuidedReviewRow(
                        label: "Tanks",
                        value: "\(plan.tankSplit.totalTanks) × \(SprayGuidedFormat.litres(plan.tankSplit.tankCapacityLitres))"
                    )
                }
            }

            GuidedReviewGroup(title: "Products", onEdit: { toggle(.products) }) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.productLines, id: \.productId) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(line.name)
                                    .font(.footnote.weight(.semibold))
                                Spacer()
                                Text(SprayGuidedFormat.quantity(line.totalQuantity, unit: line.unit))
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(line.isUnresolved ? .orange : VineyardTheme.olive)
                                    .monospacedDigit()
                            }
                            Text(SprayGuidedFormat.productBasisLabel(line.basis))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            // The same arithmetic the Products step showed, from
                            // the same plan — Review never recalculates.
                            if let calculation = SprayGuidedFormat.productCalculation(line) {
                                Text(calculation)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let perTank = line.quantityPerFullTank, plan.tankSplit.totalTanks > 1 {
                                Text("Per full tank: \(SprayGuidedFormat.quantity(perTank, unit: line.unit))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                GuidedReviewGroup(title: "Notes") {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let blocker = flow.firstBlocker {
                GuidedBlockerBanner(blocker: blocker)
            }
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

    /// The rate basis to FREEZE onto a saved chemical line.
    ///
    /// A per-100 L label is per-100 L wherever it is used. An area rate takes
    /// whatever the operator chose for that specific line, defaulting to whole
    /// block — the legacy `per_hectare` meaning — so historical behaviour is
    /// never restated. On a banded pass the flow will not let the spray be saved
    /// until that choice has actually been made.
    private func persistedRateBasis(for chemResult: ChemicalCalculationResult) -> SprayProductRateBasis {
        if chemResult.basis == .per100Litres { return .per100Litres }
        guard let savedId = chemResult.savedChemicalId,
              let line = chemicalLines.first(where: { $0.chemicalId == savedId })
        else { return .wholeBlockArea }
        return productAreaBasis[line.id] ?? .wholeBlockArea
    }

    /// Freezes the product's resistance classification onto this spray line.
    ///
    /// Read from the saved chemical AS IT IS NOW, at the moment the spray is
    /// recorded, and stored on the line itself. If that chemical is corrected —
    /// or archived — years from now, this spray still reports the classification
    /// VineTrack actually used when the application happened, instead of
    /// silently adopting the new one and rewriting the vineyard's history.
    ///
    /// Returns `nil` for a product with nothing structured, so a line stays
    /// honestly empty rather than implying knowledge that never existed.
    private func chemicalSnapshot(for chemResult: ChemicalCalculationResult) -> ChemicalLineSnapshot? {
        ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: chemResult.savedChemicalId,
            productName: chemResult.chemicalName,
            library: store.savedChemicals,
            // Identity only. Every line on this screen was either picked from the
            // Chemical Store (so it carries an id) or deliberately typed, and a
            // job created from a group-only plan position is NAMED for its group
            // ("FRAC 3"). Allowing a name match here would let such a line adopt a
            // library product's authoritative chemistry — promoting a planned
            // stipulation into a verified classification nobody established.
            allowNameMatch: false
        ).snapshot
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
                    // Snapshot the basis the operator actually chose for THIS
                    // line. Without it a banded treated-band quantity would
                    // reload as a whole-block one and silently restate itself.
                    rateBasis: persistedRateBasis(for: chemResult),
                    savedChemicalId: chemResult.savedChemicalId,
                    chemicalSnapshot: chemicalSnapshot(for: chemResult)
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
            operationType: operationType,
            // Projection of the SAME plan the Review step displayed. The 17
            // sql/191 + sql/192 columns are never populated from UI state.
            applicationGeometry: flow.snapshot,
            // Job-originated completion: the record fulfils this spray job.
            sprayJobId: originSprayJobId
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
            operationType: operationType,
            // Projection of the SAME plan the Review step displayed.
            applicationGeometry: flow.snapshot,
            // Job-originated completion: the record fulfils this spray job.
            sprayJobId: originSprayJobId
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
    /// The vineyard workflow's label rate-basis preference, strongest first.
    /// Passed in rather than re-derived: one rule, decided once, so swapping a
    /// product here seeds the same basis the rest of the screen would.
    let preferredRateBases: [ChemicalRateBasis]
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

    /// Every rate this product offers — structured registered-use rates when
    /// the record has them, the legacy `rates` array only when it does not.
    private var offeredRates: [SpraySelectableRate] {
        guard let chem = selectedChemical else { return [] }
        return SprayRegisteredUseRates.rates(for: chem)
    }

    private var selectedOfferedRate: SpraySelectableRate? {
        offeredRates.first { $0.id == line.selectedRateId }
    }

    /// Offered rates grouped by the registered use they belong to.
    ///
    /// A rate detached from its crop and target is just a number, so the menu
    /// keeps them under their own heading rather than pooling everything into
    /// one anonymous list.
    private var rateGroups: [RateGroup] {
        var order: [String] = []
        var byTitle: [String: [SpraySelectableRate]] = [:]
        for rate in offeredRates {
            let key = rate.useTitle ?? ""
            if byTitle[key] == nil { order.append(key) }
            byTitle[key, default: []].append(rate)
        }
        return order.map { key in
            RateGroup(id: key, title: key.isEmpty ? nil : key, rates: byTitle[key] ?? [])
        }
    }

    private struct RateGroup: Identifiable {
        let id: String
        let title: String?
        let rates: [SpraySelectableRate]
    }

    /// The seedable rate in the chemical's display unit, when the current
    /// selection actually provides one. `nil` for a range, a reference-only
    /// entry or an unresolved rate — all of which the operator must resolve.
    private var recommendedRateDisplay: Double? {
        guard let chem = selectedChemical,
              let base = selectedOfferedRate?.seed.seedableValue else { return nil }
        return chem.unit.fromBase(base)
    }

    /// The rate menu, shared by the compact basis chip and the Rate row.
    @ViewBuilder
    private func rateMenuItems(showsCheckmark: Bool) -> some View {
        ForEach(rateGroups) { group in
            Section(group.title ?? "Saved rates") {
                ForEach(group.rates) { rate in
                    if rate.isSelectable {
                        Button {
                            line.selectedRateId = rate.id
                            if let basis = rate.basis { line.basis = basis }
                        } label: {
                            HStack {
                                Text(rate.menuText)
                                if showsCheckmark, line.selectedRateId == rate.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    } else {
                        // Reference-only (`basis:"other"`) and number-less rates
                        // are SHOWN so the operator can read what the label
                        // actually says, but they can never be chosen as an
                        // application rate.
                        Button {} label: {
                            Label(rate.menuText, systemImage: "info.circle")
                        }
                        .disabled(true)
                    }
                }
            }
        }
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
                if !offeredRates.isEmpty {
                    Menu {
                        rateMenuItems(showsCheckmark: false)
                    } label: {
                        let currentBasis = selectedOfferedRate?.basis ?? line.basis
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
                                // Re-seed from the NEW product's own rates. Left
                                // alone, a stale `selectedRateId` keeps pointing
                                // at the previous product's rate and the line
                                // silently keeps that product's basis.
                                let selection = SprayRegisteredUseRates
                                    .defaultSelection(for: chem, preferring: preferredRateBases)
                                line.selectedRateId = selection?.id ?? UUID()
                                if let basis = selection?.basis { line.basis = basis }
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

            if let chem = selectedChemical, !offeredRates.isEmpty {
                Divider().padding(.leading, 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Rate").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        rateMenuItems(showsCheckmark: true)
                    } label: {
                        let label: String = selectedOfferedRate?.menuText ?? "Select rate"
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
                    recommendedRateDisplay.map { SprayRateFormatter.format($0) } ?? "Enter rate",
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
            rateGuidanceText(chem: chem, basisLabel: basisLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// What the field is being measured against.
    ///
    /// A single label rate reads as a recommendation. A RANGE deliberately does
    /// not: the band is shown verbatim and the operator is asked for the rate
    /// they are actually applying, because picking a point inside a registered
    /// range is their decision and never VineTrack's. A reference-only
    /// (`basis:"other"`) entry says so in the label's own words.
    @ViewBuilder
    private func rateGuidanceText(chem: SavedChemical, basisLabel: String) -> some View {
        if let recommendedRateDisplay {
            Text("Recommended: \(SprayRateFormatter.format(recommendedRateDisplay)) "
                 + "\(chem.unit.rawValue)\(basisLabel)")
        } else if let rate = selectedOfferedRate, rate.requiresOperatorRate {
            Text("Label rate: \(rate.displayText) — enter the rate you are applying.")
        } else if let rate = selectedOfferedRate {
            Text("\(rate.displayText) — enter the rate you are applying.")
        } else {
            Text("Enter the rate you are applying.")
        }
    }

    private func syncOverrideText() {
        if let value = line.overrideRate {
            let formatted = SprayRateFormatter.format(value)
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
                Text("\(SprayRateFormatter.format(result.unit.fromBase(result.selectedRate))) \(result.unit.rawValue)/\(result.basis == .perHectare ? "ha" : "100L")")
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
