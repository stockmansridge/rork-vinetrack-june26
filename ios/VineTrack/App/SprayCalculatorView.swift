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
    /// Whether the operator has CONFIRMED equipment for this spray.
    ///
    /// A Program Step prefills the spray unit, and completion used to be read
    /// straight off `selectedEquipmentId != nil` — so Equipment was already
    /// complete before the screen appeared and the guided flow skipped it
    /// entirely. The operator never saw the tractor, which is optional and so
    /// has no other prompt anywhere in the flow.
    @State private var isEquipmentConfirmed: Bool = false
    /// The block whose setup the operator asked to edit from a blocker banner.
    @State private var blockDetailsTarget: Paddock?
    /// Offending blocks to choose between when a blocker names more than one.
    @State private var blockDetailsChoices: [Paddock] = []
    /// The canopy, together with whether anybody actually chose it.
    ///
    /// Was two plain `@State` defaults (`.medium` / `.low`). A segmented picker
    /// always shows a selection, so those defaults looked like an answer from
    /// the moment the screen opened — and a canopy nobody chose was setting the
    /// dilute rate that every per-100 L product is measured against.
    @State private var canopy: SprayCanopySelection = .unconfirmed
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
    /// Presents the product picker for a NEW spray line.
    ///
    /// "Add Chemical" used to append `savedChemicals.first` — whichever product
    /// happened to sort first in the store — so a line arrived pre-bound to a
    /// product nobody chose. Adding a line now starts by asking which product.
    @State private var showAddChemicalPicker: Bool = false
    /// The chemical line whose product is currently open in the Chemical
    /// Store editor, so the sheet's dismissal/save handler knows which
    /// `ChemicalLine` to re-validate.
    @State private var inspectingChemicalLineId: UUID?
    /// The Chemical Store record open in that sheet. `Identifiable`, so
    /// `.sheet(item:)` presents it without a second boolean to keep in sync.
    @State private var inspectingChemical: SavedChemical?
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
    /// Whether the sprayer applies the canopy's recommended dilute volume, or
    /// its own calibrated output. Starts undecided — pre-selecting either would
    /// put a volume nobody chose into the calculation.
    @State private var sprayVolumeChoice: SprayVolumeChoice = .undecided
    /// The machine's calibrated output, as typed. Held as text so a part-typed
    /// figure is never read as a rate, and retained across canopy changes so
    /// re-choosing a canopy does not wipe what the operator entered.
    @State private var customSprayerRateText: String = ""
    /// Manual mode: the total water the operator intends to mix or apply, as
    /// typed. Text for the same reason as the sprayer rate — a half-entered
    /// "4" must never be read as a 4 L job.
    @State private var manualTotalLitresText: String = ""
    /// Per-product-line area basis for banded jobs. Keyed by `ChemicalLine.id`
    /// because the decision belongs to the individual product, never the job.
    @State private var productAreaBasis: [UUID: SprayProductRateBasis] = [:]
    /// The section the operator has explicitly opened. `nil` follows the flow's
    /// own `activeStep`, so the screen advances by itself as decisions are made.
    @State private var openedStep: SprayGuidedStep?
    /// Whether the initial section has been opened. Guards a one-time seed, so
    /// a redraw cannot re-open a section the operator deliberately closed.
    @State private var hasSeededOpenedStep: Bool = false

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
        canopy.litresPer100m(settings: store.settings.canopyWaterRates)
    }

    /// The dilute / runoff reference the canopy model establishes, in L/100 m.
    ///
    /// This is the SAME number as `litresPer100mValue` — the canopy table is a
    /// per-100 m table — named for the role it plays in the row-length
    /// workflow. Row spacing is not involved, so unlike the L/ha figure it is
    /// always available, even for a block that has never had a spacing entered.
    private var canopyDiluteLitresPer100m: Double { litresPer100mValue }

    /// The operator's own dilute / runoff figure, when they have typed one.
    ///
    /// An empty field is NOT an override — it means "use the canopy". Keeping
    /// the override in the text field itself, rather than mirroring the canopy
    /// value into it, is what makes a manual entry survive canopy changes and
    /// redraws: nothing ever writes into this field except the operator.
    private var manualDiluteLitresPer100m: Double? {
        SprayDiluteReference.manualLitresPer100m(from: diluteLitresPer100mText)
    }

    /// The dilute / runoff rate actually fed to the engine, in L/100 m.
    ///
    /// A spreader has no canopy, so it has no canopy-derived dilute either: a
    /// granular pass is not a concentration of anything, and inventing a
    /// reference for it would multiply every per-100 L product on the job.
    private var effectiveDiluteLitresPer100m: Double? {
        SprayDiluteReference.effectiveLitresPer100m(
            manualText: diluteLitresPer100mText,
            canopyLitresPer100m: canopyDiluteLitresPer100m,
            supportsCanopy: operationType != .spreader
        )
    }

    /// `nil` when row spacing could not be resolved, so callers must handle the
    /// unavailable case instead of receiving a confidently wrong number.
    private var waterRateEntry: CanopyWaterRate.RateEntry? {
        guard let spacing = resolvedRowSpacingMetres else { return nil }
        return CanopyWaterRate.rate(
            size: canopy.size,
            density: canopy.density,
            rowSpacingMetres: spacing,
            settings: store.settings.canopyWaterRates
        )
    }

    private var chosenSprayRate: Double {
        Double(sprayRateText) ?? (waterRateEntry?.litresPerHa ?? 0)
    }

    /// THE concentration factor, read from the one engine that defines it.
    ///
    /// # Why this is no longer computed here
    ///
    /// This property used to be `dilute ÷ chosen`, with no floor, and it is
    /// what the L/ha carrier screen displayed. The L/100 m screen displayed
    /// `flow.plan.carrier.concentrationFactor`, which is `max(1.0, dilute ÷
    /// actual)`. So the same physical relationship — dilute 357 L/ha against
    /// actual 714 L/ha, and dilute 10 L/100 m against actual 20 L/100 m — read
    /// as `CF 0.50` on one screen and `CF 1.00` on the other.
    ///
    /// The engine was never wrong: both its branches already floored at 1.0.
    /// The defect was a second, unfloored definition living in the view, which
    /// also reached the legacy `SprayCalculator` and could halve a per-100 L
    /// dose on a dilute job. One definition now, in `SprayCarrierConversion`.
    private var concentrationFactor: Double {
        flow.plan.carrier.concentrationFactor
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
            store.currentTractors.first(where: { $0.id == id })?.displayName
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
            //
            // D2 unit boundary. `SavedChemical.ratePerHa` is stored in the
            // product's OWN DISPLAY unit — it is rendered straight beside
            // `unit.rawValue` in Chemicals Management and Spray Presets, with no
            // `fromBase` in between. Everything downstream of `rate` here is in
            // BASE units (mL/g): `seedValue` is documented as base, and the
            // label descriptor below re-derives its shown figure with
            // `chemical.unit.fromBase(rate)`.
            //
            // Handing the display scalar over unconverted therefore dosed a
            // 2 L/ha legacy product as 2 mL/ha — a 1000x under-dose on every
            // litre- and kilogram-quoted pre-intelligence record, and silently,
            // because 2 is a perfectly plausible number to read on the screen.
            // Millilitre and gram products were unaffected, which is exactly why
            // this survived: `toBase` is the identity for them.
            //
            // Structured rates are NOT converted here — they are already base,
            // and converting them would be the same defect in the other
            // direction.
            // A nil `ratePerHa` means there is no valid per-hectare scalar at
            // all (sql/222) — a confirmed 2–3 L/100 L rate, for instance. That
            // stays nil here rather than collapsing to zero, so the line falls
            // through to "operator must choose" instead of silently seeding a
            // tank with a rate nobody confirmed.
            let legacyScalarRate: Double? = SprayRegisteredUseRates.hasStructuredRates(chemical)
                ? nil
                : (line.basis == .perHectare
                    ? chemical.ratePerHa.map { chemical.unit.toBase($0) }
                    : nil)
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
            // THE label rate, carried verbatim into the plan.
            //
            // `rate` above is a BASE-unit number (grams, millilitres) and
            // `chemical.unit` is the drum's stock unit. Composing a rate string
            // from those two is what printed an authoritative `150 g/100 L` as
            // `150 Kg/100 L` on the product card. The regulator's number and
            // the regulator's unit now travel together so nothing downstream
            // has to reconstruct them.
            let selectedRate = SprayRegisteredUseRates.rate(
                for: chemical,
                id: line.selectedRateId
            )
            let labelUnit = selectedRate?.labelUnit.trimmedNonEmpty ?? chemical.unit.rawValue
            let labelRate: SprayLabelRateDescriptor? = {
                guard rate > 0 else { return nil }
                let shown = SprayRegisteredUseRates.displayValue(
                    rate,
                    labelUnit: labelUnit,
                    chemical: chemical
                ) ?? chemical.unit.fromBase(rate)
                return SprayLabelRateDescriptor(value: shown, unit: labelUnit, basis: basis)
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
                isAreaBasisExplicit: chosenAreaBasis != nil,
                labelRate: labelRate,
                // TOTALS are the operator's stock unit's business — 0.53 Kg,
                // not 526.5 of something unstated. This is the only place base
                // units are converted, and it happens at the display edge.
                unitDisplay: SprayProductUnitDisplay(
                    displayUnit: chemical.unit.rawValue,
                    baseUnitsPerDisplayUnit: chemical.unit.toBase(1)
                )
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
        inputs.isEquipmentConfirmed = isEquipmentConfirmed
        inputs.tankCapacityLitres = selectedTankCapacityLitres
        inputs.isCanopyConfirmed = canopy.isConfirmed
        inputs.canopy = canopy
        inputs.canopyWaterRates = store.settings.canopyWaterRates
        inputs.sprayVolumeChoice = sprayVolumeChoice
        inputs.customSprayerRate = Double(
            customSprayerRateText.trimmingCharacters(in: .whitespaces)
        )
        // The figure is entered in whichever unit the operator chose for spray
        // volume, and converted centrally. There is one sprayer output, not an
        // L/ha one and an L/100 m one that could disagree.
        //
        // Read from `effectiveCarrierBasis`, NEVER from `flow`. `flow` is built
        // FROM `guidedInputs`, so reaching for it here is unbounded recursion:
        // guidedInputs → flow → guidedInputs → … until the thread runs off its
        // stack guard page and the app is killed with SIGSEGV. That is the
        // build-64 crash on opening a spray from a Program. The two properties
        // resolve identically — same profile, same policy, same choice — so
        // this is the same answer without the cycle.
        inputs.customSprayerBasis = effectiveCarrierBasis
        inputs.carrierBasis = carrierBasisChoice
        inputs.manualTotalLitres = Double(
            manualTotalLitresText.trimmingCharacters(in: .whitespaces)
        )
        inputs.litresPerHectare = Double(sprayRateText)
        // The canopy's dilute demand, stated per hectare. The SAME canopy
        // answer the row-length branch reads per 100 m — one table, one
        // requirement, two ways of writing it down.
        inputs.diluteLitresPerHectare = waterRateEntry?.litresPerHa
        // The canopy drives dilute in BOTH carrier bases. Before this, the
        // row-length path had no canopy at all, so this stayed nil, the
        // concentration factor fell back to 1.0, and every per-100 L product
        // on an SWNZ job was dosed as though the spray were dilute.
        inputs.diluteLitresPer100Metres = effectiveDiluteLitresPer100m
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

    /// The section currently expanded — the operator's choice, and ONLY the
    /// operator's choice.
    ///
    /// # Why this no longer falls back to `flow.activeStep`
    ///
    /// It used to read `openedStep ?? flow.activeStep`, so whenever nothing was
    /// explicitly open the screen followed whichever step the flow considered
    /// outstanding. `activeStep` moves the instant a step validates — which is
    /// the moment the operator finishes answering it. Confirming a canopy,
    /// entering a sprayer rate or tapping a product rate therefore collapsed
    /// the section under their hands and opened the next one, mid-task.
    ///
    /// Completion and expansion are now separate concerns: `SprayGuidedFlow`
    /// still decides what is complete and what is unlocked, and this decides
    /// what is on screen. The one-time seed below is the only place they meet.
    private var expandedStep: SprayGuidedStep? {
        openedStep
    }

    /// Opens the first outstanding step, once per session.
    private func seedOpenedStepIfNeeded() {
        guard !hasSeededOpenedStep else { return }
        hasSeededOpenedStep = true
        openedStep = flow.activeStep
    }

    private func toggle(_ step: SprayGuidedStep) {
        withAnimation(.spring(duration: 0.3)) {
            // Tapping the open section closes it. Nothing reopens on its own.
            openedStep = openedStep == step ? nil : step
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
        // Addressable so opening a step can bring THIS card's header to the
        // top of the screen. See the scroll anchoring in `body`.
        .id(step)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
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
                            equipmentConfirmation
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
                    // Opening a step must land on its HEADING, not somewhere in
                    // the middle of it.
                    //
                    // Without this the scroll offset simply stays where it was:
                    // the section that was open collapses, everything below it
                    // slides up by that height, and the card the operator just
                    // tapped ends up with its header pushed off the top of the
                    // screen — so they land at the BOTTOM of the section they
                    // opened and have to scroll back up to read it.
                    //
                    // Driven from `openedStep` rather than from the header tap,
                    // so the same anchoring applies however a step is opened —
                    // including the Products step's own "Continue" button.
                    // Collapsing (`nil`) deliberately leaves the scroll
                    // position alone: nothing new needs reading.
                    .onChange(of: openedStep) { _, step in
                        guard let step else { return }
                        withAnimation(.spring(duration: 0.3)) {
                            proxy.scrollTo(step, anchor: .top)
                        }
                    }
                }
            }
            .onAppear { seedOpenedStepIfNeeded() }
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
            .sheet(isPresented: $showAddChemicalPicker) {
                NavigationStack {
                    SprayLineChemicalPicker(selectedId: nil) { chosen in
                        showAddChemicalPicker = false
                        guard let chosen else { return }
                        appendChemicalLine(for: chosen)
                    }
                }
            }
            // Inspect / edit / re-verify a Products-step chemical WITHOUT
            // leaving the calculator. Reuses the existing Chemical Store
            // editor — the same screen `ChemicalsManagementView` opens — rather
            // than a second, parallel chemical editor. Dismissing (by any
            // route) returns straight to this same Products step: nothing
            // here touches `openedStep`, blocks, canopy, equipment, product
            // lines or the custom sprayer rate.
            .sheet(item: $inspectingChemical, onDismiss: { inspectingChemicalLineId = nil }) { chemical in
                EditSavedChemicalSheet(chemical: chemical) { saved in
                    revalidateSelectedRate(afterEditing: saved)
                }
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
        // Prefill is a NEW job draft, so it resolves against the selected
        // vineyard's tractors only. A prefill source that points at another
        // vineyard's tractor leaves the step unset for the operator rather
        // than quietly binding a machine this vineyard does not own.
        let tractorId = r.tractorId ?? prefillProgram?.tractorId
        if let tractorId, store.currentTractors.contains(where: { $0.id == tractorId }) {
            selectedTractorId = tractorId
        } else if !r.tractor.isEmpty {
            selectedTractorId = store.currentTractors.first(where: { $0.displayName == r.tractor || $0.name == r.tractor })?.id
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
        // "Edit block details" opens the block's OWN setup editor — the same
        // one Vineyard Setup uses. It was wired to the paddock PICKER, which
        // only re-selects which blocks are being sprayed and cannot change a
        // row spacing, so the link never did what its label promised.
        .sheet(item: $blockDetailsTarget) { paddock in
            EditPaddockSheet(paddock: paddock)
        }
        .confirmationDialog(
            "Which block needs setting up?",
            isPresented: Binding(
                get: { !blockDetailsChoices.isEmpty },
                set: { if !$0 { blockDetailsChoices = [] } }
            ),
            titleVisibility: .visible
        ) {
            // Several blocks are incomplete. Rather than guessing one, name
            // them and let the operator pick; each opens the same editor.
            ForEach(blockDetailsChoices) { paddock in
                Button(paddock.name) {
                    blockDetailsChoices = []
                    blockDetailsTarget = paddock
                }
            }
            Button("Cancel", role: .cancel) { blockDetailsChoices = [] }
        }
    }

    /// Opens block setup for whichever block the blocker is actually about.
    ///
    /// Resolution order: the blocks the blocker itself names, then the geometry
    /// resolver's own unresolved list, then the selected blocks. One match opens
    /// the editor directly; several offer a choice.
    private func openBlockDetails(for blocker: SprayGuidedBlocker) {
        let namedIds: [String] = {
            if case let .blockSetupRequired(_, blockIds) = blocker, !blockIds.isEmpty {
                return blockIds
            }
            let unresolved = applicationGeometry.unresolvedBlocks.map(\.blockId)
            if !unresolved.isEmpty { return unresolved }
            return selectedPaddocks.map { $0.id.uuidString }
        }()

        let matches = namedIds.compactMap { id in
            store.paddocks.first { $0.id.uuidString == id }
        }
        if matches.count == 1 {
            blockDetailsTarget = matches[0]
        } else if matches.count > 1 {
            blockDetailsChoices = matches
        } else {
            // Nothing identifiable to edit — the honest fallback is the block
            // selection the operator can actually act on.
            showSprayPaddockPicker = true
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
                SprayCanopyControls(selection: $canopy)

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

    /// THE tractor list — Equipment, Review and Tank Mixing all read this ONE
    /// property.
    ///
    /// Two rules had to hold at once, and they are not in tension:
    ///
    /// 1. *One list.* Tank Mixing used to compute its own, differently-filtered
    ///    list, so a tractor confirmed in Equipment could fall outside it and
    ///    Tank Mixing would report "No tractors configured" for a selection
    ///    that was never lost, only re-resolved through a stricter source.
    /// 2. *Selected vineyard only.* A new Spray Job must never be offered a
    ///    machine belonging to another vineyard.
    ///
    /// The earlier fix satisfied (1) by dropping the vineyard filter entirely,
    /// which broke (2). Both now hold because there is still exactly ONE list
    /// and it is the authoritative selected-vineyard accessor — every picker,
    /// the review step and Tank Mixing read it, so a confirmed
    /// `selectedTractorId` can never fall outside it. Historical Spray Records
    /// keep resolving their own equipment through the record-scoped historical
    /// resolvers, not through this new-job picker.
    private var availableTractors: [Tractor] {
        store.currentTractorsSorted
    }

    /// The confirmed tractor's name, resolved against the same single list the
    /// pickers use, so a valid `selectedTractorId` can never render as
    /// unresolved.
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

    /// The plan's product lines paired with the chemical line each came from,
    /// in the operator's own Products order.
    ///
    /// THE single chemistry source for Tank Mixing and for the tanks that get
    /// persisted. Mirrors `planLinesByChemicalLineId`, which Review already
    /// reads — so a product Review shows correctly calculated can no longer
    /// vanish downstream.
    ///
    /// The screen this replaced re-resolved chemistry through legacy
    /// `SprayCalculator.calculate`, which required
    /// `chemical.rates.first(where: { $0.id == line.selectedRateId })` — a
    /// lookup the guided Products path's structured registered-use rates do
    /// not populate. That mismatch, not a missing SwiftUI row, is why Tank
    /// Mixing showed water and tank counts but never the chemical itself, and
    /// why the persisted `SprayTank.chemicals` was equally empty.
    private var guidedTankLines: [(chemicalLine: ChemicalLine, planLine: SprayProductLineResult)] {
        let mapping = planLinesByChemicalLineId
        return chemicalLines.compactMap { line in
            guard let planLine = mapping[line.id] else { return nil }
            return (line, planLine)
        }
    }

    /// Tank mix preview shown on the Spray Tank Mixing screen so the operator
    /// can review chemical quantities and label notes before tapping Start.
    ///
    /// Every figure here is read straight off `flow.plan` — the SAME
    /// authoritative plan Review displays — so this screen cannot disagree
    /// with the one the operator already verified.
    @ViewBuilder
    private var tankMixPreviewSection: some View {
        let plan = flow.plan
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Tank Mix", icon: "drop.fill")

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                mixStatTile(
                    label: "Total Area",
                    value: SprayGuidedFormat.hectares(plan.grossAreaHectares),
                    icon: "square.dashed",
                    color: VineyardTheme.olive
                )
                mixStatTile(
                    label: "Total Water",
                    value: SprayGuidedFormat.litres(plan.totalCarrierLitres),
                    icon: "drop.fill",
                    color: .blue
                )
                mixStatTile(
                    label: "Full Tanks",
                    value: "\(plan.tankSplit.fullTankCount)",
                    icon: "fuelpump.fill",
                    color: VineyardTheme.earthBrown
                )
                mixStatTile(
                    label: "Last Tank",
                    value: SprayGuidedFormat.litres(plan.tankSplit.lastTankLitres),
                    icon: "drop.halffull",
                    color: .orange
                )
            }

            ForEach(guidedTankLines, id: \.chemicalLine.id) { entry in
                mixChemicalRow(
                    chemicalLine: entry.chemicalLine,
                    planLine: entry.planLine,
                    tankSplit: plan.tankSplit
                )
            }

            // A line the plan could not resolve must still be named here —
            // never silently dropped from the mix the operator is about to
            // measure out.
            ForEach(plan.unresolvedProductLines, id: \.productId) { unresolved in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unresolved.name)
                            .font(.subheadline.weight(.semibold))
                        Text(unresolved.unresolvedReason?.title ?? "Cannot be calculated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.orange.opacity(0.08))
                .clipShape(.rect(cornerRadius: 8))
            }

            if plan.concentrationFactor != 1.0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Concentration Factor \(SprayGuidedFormat.factor(plan.concentrationFactor))")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(plan.concentrationFactor > 1.0 ? "Concentrate" : "Dilute")
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

    /// One product's row on the Spray Tank Mixing screen.
    ///
    /// The total is the SAME `planLine.totalQuantity` Review already showed —
    /// nothing here recalculates a label rate. The per-tank amounts are that
    /// same total, already split by the planner using the authoritative tank
    /// water split (`quantityPerFullTank` / `quantityInLastTank`), so
    /// `sum(per-tank amounts) == planLine.totalQuantity` by construction. Only
    /// the rows that actually exist are shown: a job with one partial tank
    /// never shows a "Full tank" line, and a job with no partial tank never
    /// shows a "Last tank" line.
    @ViewBuilder
    private func mixChemicalRow(
        chemicalLine line: ChemicalLine,
        planLine: SprayProductLineResult,
        tankSplit: SprayTankSplit
    ) -> some View {
        let saved = store.savedChemicals.first(where: { $0.id == line.chemicalId })
        let labelURL = saved?.labelURL ?? ""
        let totalTanks = tankSplit.totalTanks

        // This card answers exactly three things: what product, how much to
        // add, and where the official label is if the operator needs the
        // full legal detail. Override state, the product's marketing page,
        // restriction text, the registered use and rate-basis workings,
        // WHP/REI and verification state all belong to the Chemical Store
        // record and the Products-step inspector — never duplicated on this
        // operational screen.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                Text(planLine.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let url = Self.normalizedLabelURL(labelURL) {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(VineyardTheme.olive)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open official label")
                }
            }

            if let total = planLine.totalQuantity {
                let displayUnit = planLine.unitDisplay.displayUnit
                HStack(alignment: .firstTextBaseline) {
                    Text(SprayGuidedFormat.quantity(planLine.unitDisplay.display(total), unit: displayUnit))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(VineyardTheme.olive)
                        .monospacedDigit()
                    Spacer()
                    if totalTanks <= 1 {
                        // The one-tank case: the whole amount goes in the one
                        // tank there is — named so the operator sees the tank
                        // size beside what goes in it, not just a bare total.
                        Text("\(SprayGuidedFormat.number(tankSplit.lastTankLitres > 0 ? tankSplit.lastTankLitres : tankSplit.tankCapacityLitres)) L tank")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Multi-tank jobs: how much goes in EACH tank, not only the
                // whole-job figure — this screen mixes tanks, not the job.
                if totalTanks > 1 {
                    VStack(alignment: .leading, spacing: 2) {
                        if tankSplit.fullTankCount > 0, let perFullTank = planLine.quantityPerFullTank {
                            Text("Full \(SprayGuidedFormat.number(tankSplit.tankCapacityLitres)) L tank\(tankSplit.fullTankCount > 1 ? "s" : "") (\(tankSplit.fullTankCount)): "
                                 + "\(SprayGuidedFormat.quantity(planLine.unitDisplay.display(perFullTank), unit: displayUnit)) each")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if tankSplit.lastTankLitres > 0, let inLastTank = planLine.quantityInLastTank {
                            Text("Last \(SprayGuidedFormat.number(tankSplit.lastTankLitres)) L tank: "
                                 + SprayGuidedFormat.quantity(planLine.unitDisplay.display(inLastTank), unit: displayUnit))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                ForEach(availableTractors) { tractor in
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
                        preferredRateBases: preferredRateBases,
                        onInspect: { openChemicalInspector(for: line) }
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
                // Ask which product. Appending `savedChemicals.first` put a
                // product in the tank list that the operator never picked.
                showAddChemicalPicker = true
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

            // Leaving Products is the operator's move, never the form's.
            //
            // Expansion no longer follows `flow.activeStep` at all, so this
            // button is the only thing that moves the screen forward. Adding a
            // second chemical, or changing a rate, leaves the operator exactly
            // where they were.
            Button {
                withAnimation(.spring(duration: 0.3)) { openedStep = .review }
            } label: {
                Text("Continue")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(
                        flow.isComplete(.products)
                            ? VineyardTheme.olive
                            : Color.secondary.opacity(0.25)
                    )
                    .foregroundStyle(flow.isComplete(.products) ? Color.white : Color.secondary)
                    .clipShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!flow.isComplete(.products))
            .padding(.top, 4)
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
        let base = jets.isEmpty
            ? selectedEquipmentName
            : "\(selectedEquipmentName) — \(jets) fans/jets"
        // A prefilled unit is not a confirmed one, and the summary must not
        // imply otherwise while the step is still outstanding.
        return isEquipmentConfirmed ? base : "\(base) — not confirmed"
    }

    /// The explicit Equipment confirmation.
    ///
    /// The spray unit is required; the tractor is NOT. This exists so the
    /// operator actually sees the tractor decision — including a deliberate
    /// "Not Set" — before the flow moves on, which a prefilled Program Step
    /// value would otherwise skip past silently.
    @ViewBuilder
    private var equipmentConfirmation: some View {
        let hasUnit = selectedEquipmentId != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Tractor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selectedTractorId == nil ? "Not Set" : selectedTractorLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selectedTractorId == nil ? .secondary : .primary)
            }
            Text("A tractor is optional — Not Set is a valid answer.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if isEquipmentConfirmed {
                Label("Equipment confirmed", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VineyardTheme.olive)
            } else {
                Button {
                    isEquipmentConfirmed = true
                } label: {
                    Text("Confirm Equipment")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(hasUnit ? VineyardTheme.olive : Color.secondary.opacity(0.25))
                        .foregroundStyle(hasUnit ? Color.white : Color.secondary)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!hasUnit)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
        // Changing either machine invalidates the confirmation. Otherwise
        // "confirm croplands → change tractor" would leave a confirmation
        // standing for a setup the operator never actually agreed to.
        .onChange(of: selectedEquipmentId) { _, _ in isEquipmentConfirmed = false }
        .onChange(of: selectedTractorId) { _, _ in isEquipmentConfirmed = false }
    }

    private var carrierSummary: String {
        guard flow.isCarrierResolved else { return "Not set" }
        let carrier = flow.plan.carrier
        switch carrier.basis {
        case .litresPerHectare:
            return "\(SprayGuidedFormat.litresPerHectare(carrier.litresPerHectare)) — \(SprayGuidedFormat.litres(carrier.totalLitres)) total"
        case .litresPer100Metres:
            return "\(SprayGuidedFormat.litresPer100m(carrier.appliedLitresPer100Metres)) — \(SprayGuidedFormat.litres(carrier.totalLitres)) total"
        case .manualTotalVolume:
            // No rate to quote — the operator gave the total directly, and
            // restating it as an implied L/ha would put a number on the summary
            // line that nobody entered.
            return "Manual — \(SprayGuidedFormat.litres(carrier.totalLitres)) total"
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
            GuidedBlockerBanner(blocker: blocker) { openBlockDetails(for: blocker) }
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
                GuidedBlockerBanner(blocker: blocker) { openBlockDetails(for: blocker) }
            }
        }
    }

    // MARK: - Step 6 — Canopy & Spray Volume

    @ViewBuilder
    private var carrierVolumeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Only offer a choice when the vineyard profile genuinely allows one.
            // An NZ/SWNZ vineyard is locked to L/100 m and sees no L/ha option.
            VStack(alignment: .leading, spacing: 8) {
                // "Spray volume", not "carrier volume" — and deliberately
                // NOT "rate per 100 L" / "rate per ha". These are units of
                // WATER. A product's registered rate basis is a different
                // question answered inside Products, and naming the two
                // controls alike is how an operator comes to believe that
                // choosing L/ha here changed their label's rate basis.
                HStack(spacing: 0) {
                    Text("Spray volume basis")
                        .font(.subheadline.weight(.semibold))
                    SprayFieldHelp(
                        title: "Spray volume basis",
                        message: SprayVolumeHelp.sprayVolumeBasis
                    )
                    Spacer(minLength: 0)
                }
                // Manual is ALWAYS present, including under a locked profile.
                // The lock governs which calibrated canopy workflow the
                // vineyard may use; it has no say over a knapsack job where the
                // operator already knows the litres in the drum.
                Picker("Spray volume basis", selection: $carrierBasisChoice) {
                    ForEach(availableCarrierBases, id: \.self) { basis in
                        Text(SprayGuidedFormat.volumeSourceLabel(basis)).tag(basis)
                    }
                }
                .pickerStyle(.segmented)
                if flow.isCarrierBasisLocked {
                    Label(
                        "This vineyard records calibrated spray volume in "
                            + "\(SprayGuidedFormat.carrierBasisLabel(flow.profile.defaultCarrierBasis)).",
                        systemImage: "lock.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            // Three paths, and the routing says which question each one asks.
            //
            // Manual comes FIRST because it overrides everything else: the
            // operator has already answered the only question this step has, so
            // no canopy, no calibrated rate and no row geometry is requested.
            if flow.effectiveCarrierBasis == .manualTotalVolume {
                manualTotalWaterFields
            } else if flow.requiresCanopyConfirmation {
                // A foliar pass is the case the canopy governs, and it gets the
                // canopy → recommendation → sprayer → concentration sequence.
                canopyAndSprayVolumeFields
            } else if flow.effectiveCarrierBasis == .litresPer100Metres {
                // A spreader has no canopy at all and a banded pass is governed
                // by its band width, so both keep the existing controls rather
                // than being asked a question that cannot change their
                // arithmetic.
                litresPer100mFields
            } else {
                waterRateSection
            }

            if let blocker = flow.blocker(for: .carrier) {
                GuidedBlockerBanner(blocker: blocker) { openBlockDetails(for: blocker) }
            }
        }
    }

    /// The foliar decision path, in the order the arithmetic runs:
    ///
    /// ```text
    /// canopy type → size → density
    ///   → recommended dilute volume (CF 1.00)
    ///   → does the sprayer apply that?
    ///   → concentration factor
    /// ```
    ///
    /// Each figure appears only after the one it is derived from. The screen
    /// computes none of them — every value is read off `flow.volumeDecision`,
    /// which is the same object the planner uses to build the carrier volume.
    @ViewBuilder
    private var canopyAndSprayVolumeFields: some View {
        let decision = flow.volumeDecision

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Canopy")
                    .font(.subheadline.weight(.semibold))
                SprayCanopyControls(selection: $canopy)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))

            if let decision, let recommendation = decision.recommendation {
                recommendedVolumePanel(recommendation)
                sprayVolumeChoiceControls(decision)
                if decision.isResolved {
                    concentrationFactorPanel(decision)
                }
            }
        }
    }

    /// The CF 1.00 reference. Read-only, and deliberately NOT called the
    /// operator's spray volume — that is the next question, not this one.
    @ViewBuilder
    private func recommendedVolumePanel(_ recommendation: SprayCanopyRecommendation) -> some View {
        GuidedCalculatedPanel(title: "Recommended spray volume — CF 1.00") {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    Text("Dilute / runoff volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SprayFieldHelp(
                        title: "Recommended spray volume",
                        message: SprayVolumeHelp.recommendedVolume
                    )
                    Spacer(minLength: 8)
                    Text(SprayGuidedFormat.litresPer100m(recommendation.diluteLitresPer100Metres))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(VineyardTheme.olive)
                        .monospacedDigit()
                }
                if let perHectare = recommendation.diluteLitresPerHectare,
                   let spacing = recommendation.rowSpacingMetres {
                    GuidedCalculatedRow(
                        label: "Equivalent",
                        value: SprayGuidedFormat.litresPerHectare(perHectare),
                        caption: "\(SprayGuidedFormat.number(recommendation.diluteLitresPer100Metres)) "
                            + "L/100 m × 100 ÷ \(String(format: "%.1f", spacing)) m row spacing"
                    )
                } else {
                    GuidedCalculatedRow(
                        label: "Equivalent",
                        value: "—",
                        caption: "Needs one matching row spacing across the selected blocks"
                    )
                }
            }
        }
    }

    /// The same sprayer output stated in the other unit — derived, never a
    /// second thing the operator maintains.
    private func equivalentOutputCaption(
        _ decision: SprayVolumeDecision,
        isPerHectare: Bool
    ) -> String {
        if isPerHectare {
            guard let per100m = decision.actualLitresPer100Metres else {
                return "Equivalent per 100 m needs one matching row spacing."
            }
            return "Equivalent: \(SprayGuidedFormat.litresPer100m(per100m))"
        }
        guard let perHa = decision.actualLitresPerHectare else {
            return "Equivalent per hectare needs one matching row spacing."
        }
        return "Equivalent: \(SprayGuidedFormat.litresPerHectare(perHa))"
    }

    /// "Spray at the recommended volume?" — exactly two answers, neither
    /// pre-selected.
    @ViewBuilder
    private func sprayVolumeChoiceControls(_ decision: SprayVolumeDecision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("Spray at the recommended volume?")
                    .font(.subheadline.weight(.medium))
                SprayFieldHelp(
                    title: "Actual sprayer output",
                    message: SprayVolumeHelp.actualSprayerOutput
                )
                Spacer(minLength: 0)
            }

            // Stacked, full width, one per line. Side by side these two chips
            // shrank to fit and truncated on a standard phone — "Different
            // sprayer rate" is not a label that survives half a screen width,
            // and a choice the operator cannot read is a choice they cannot
            // safely make.
            VStack(spacing: 8) {
                GuidedChip(
                    label: "Use recommended rate",
                    icon: sprayVolumeChoice == .useRecommended ? "checkmark" : nil,
                    isSelected: sprayVolumeChoice == .useRecommended
                ) {
                    sprayVolumeChoice = .useRecommended
                }
                GuidedChip(
                    label: "Set my own rate",
                    icon: sprayVolumeChoice == .useCustomSprayerRate ? "checkmark" : nil,
                    isSelected: sprayVolumeChoice == .useCustomSprayerRate
                ) {
                    sprayVolumeChoice = .useCustomSprayerRate
                }
            }

            if sprayVolumeChoice == .useCustomSprayerRate {
                // Entered in the vineyard's own spray volume basis. One number,
                // one unit — the equivalent in the other unit is derived below
                // rather than kept as a second editable field.
                let isPerHectare = flow.effectiveCarrierBasis == .litresPerHectare
                VStack(alignment: .leading, spacing: 6) {
                    Text("What is your sprayer set to apply?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(isPerHectare ? "600" : "16.8", text: $customSprayerRateText)
                            .keyboardType(.decimalPad)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                        Text(SprayGuidedFormat.carrierBasisLabel(flow.effectiveCarrierBasis))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("Your machine's calibrated water rate — not the chemical label rate.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if decision.isResolved {
                        Text(equivalentOutputCaption(decision, isPerHectare: isPerHectare))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func concentrationFactorPanel(_ decision: SprayVolumeDecision) -> some View {
        GuidedCalculatedPanel(title: "Spray volume & concentration") {
            VStack(spacing: 8) {
                if let actual = decision.actualLitresPerHectare {
                    GuidedCalculatedRow(
                        label: "Actual sprayer output",
                        value: SprayGuidedFormat.litresPerHectare(actual),
                        caption: decision.choice == .useRecommended
                            ? "Following the canopy recommendation"
                            : "Your sprayer's calibrated rate"
                    )
                }
                HStack(spacing: 0) {
                    Text("Concentration factor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SprayFieldHelp(
                        title: "Concentration factor",
                        message: SprayVolumeHelp.concentrationFactor
                    )
                    Spacer(minLength: 8)
                    Text(SprayGuidedFormat.factor(decision.concentrationFactor))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(decision.isConcentrated ? .orange : VineyardTheme.olive)
                        .monospacedDigit()
                }
                if flow.isCarrierResolved {
                    GuidedCalculatedRow(
                        label: "Total water",
                        value: SprayGuidedFormat.litres(flow.plan.carrier.totalLitres),
                        emphasis: true
                    )
                }
            }
        }
    }

    /// Row-length carrier entry, driven by the canopy model.
    ///
    /// # Why the canopy belongs here
    ///
    /// The dilute / runoff rate IS the canopy's answer: a small canopy wets out
    /// around 10 L/100 m and a full one around 75. Asking a row-length vineyard
    /// to type that figure from memory — while an L/ha vineyard has it computed
    /// for them off the very same table — meant the canopy model silently
    /// ceased to exist for every SWNZ grower. With no dilute reference the
    /// concentration factor defaulted to 1.0, and a concentrate pass dosed its
    /// per-100 L products as though it were spraying to runoff.
    ///
    /// So the canopy drives dilute in BOTH bases. The operator still owns the
    /// number: anything typed into the override field wins, and keeps winning
    /// through canopy changes and redraws, because nothing writes to that field
    /// except the operator.
    ///
    /// Ordering is deliberate: canopy → dilute → actual applied → concentration
    /// factor → totals. Each figure appears only after the one it is derived
    /// from.
    /// The bases the picker may offer.
    ///
    /// A locked vineyard still gets Manual — see `SprayCarrierVolumePolicy.allows`.
    private var availableCarrierBases: [SprayCarrierBasis] {
        if flow.isCarrierBasisLocked {
            return [flow.profile.defaultCarrierBasis, .manualTotalVolume]
        }
        return [.litresPer100Metres, .litresPerHectare, .manualTotalVolume]
    }

    /// Manual mode — ONE question, and nothing else.
    ///
    /// No canopy, no calibrated rate, no row spacing prompt. Every figure below
    /// the field is read-only reference derived from geometry that already
    /// exists; none of it is required, and none of it blocks the job.
    @ViewBuilder
    private var manualTotalWaterFields: some View {
        let carrier = flow.isCarrierResolved ? flow.plan.carrier : nil

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Text("Total spray water")
                        .font(.subheadline.weight(.semibold))
                    SprayFieldHelp(
                        title: "Total spray water",
                        message: SprayVolumeHelp.manualTotalWater
                    )
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    TextField("400", text: $manualTotalLitresText)
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 8))
                    Text("L")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("The whole job's water — what you'll actually mix. Product rates are dosed against this total.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))

            if let carrier {
                GuidedCalculatedPanel(title: "Spray volume") {
                    VStack(spacing: 8) {
                        GuidedCalculatedRow(
                            label: "Total spray water",
                            value: SprayGuidedFormat.litres(carrier.totalLitres),
                            emphasis: true,
                            caption: "As entered — not calculated"
                        )
                        // Reference only, and labelled as such. These are what
                        // the stated total WORKS OUT TO over the selected
                        // blocks; they were not used to arrive at it, and if the
                        // geometry is missing they simply do not appear.
                        if let perHectare = carrier.litresPerHectare {
                            GuidedCalculatedRow(
                                label: "Works out to",
                                value: SprayGuidedFormat.litresPerHectare(perHectare),
                                caption: "Across the selected blocks — for reference"
                            )
                        }
                        if let per100m = carrier.appliedLitresPer100Metres {
                            GuidedCalculatedRow(
                                label: "Works out to",
                                value: SprayGuidedFormat.litresPer100m(per100m),
                                caption: "Across the selected rows — for reference"
                            )
                        }
                        GuidedCalculatedRow(
                            label: "Concentration factor",
                            value: "Not used",
                            caption: "Manual volume isn't compared to a canopy recommendation"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var litresPer100mFields: some View {
        let carrier = flow.plan.carrier
        let canopyRate = canopyDiluteLitresPer100m
        let isOverridden = manualDiluteLitresPer100m != nil
        let supportsCanopy = operationType != .spreader

        VStack(alignment: .leading, spacing: 14) {
            if supportsCanopy {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Canopy / Runoff")
                        .font(.subheadline.weight(.semibold))
                    Text("The canopy sets the dilute / runoff rate this job is concentrated from.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SprayCanopyControls(selection: $canopy)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Dilute / Runoff Volume")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if isOverridden, supportsCanopy {
                        Button("Use calculated") {
                            diluteLitresPer100mText = SprayDiluteReference.clearedOverrideText
                        }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(VineyardTheme.olive)
                    }
                }

                if supportsCanopy {
                    HStack {
                        Text("Calculated from canopy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(String(format: "%.0f", canopyRate)) L/100 m")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOverridden ? .secondary : VineyardTheme.olive)
                            .monospacedDigit()
                    }
                    .padding(10)
                    .background(VineyardTheme.olive.opacity(isOverridden ? 0.05 : 0.10))
                    .clipShape(.rect(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    TextField(
                        supportsCanopy ? String(format: "%.0f", canopyRate) : "40",
                        text: $diluteLitresPer100mText
                    )
                    .keyboardType(.decimalPad)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 8))
                    Text("L/100 m").font(.caption).foregroundStyle(.secondary)
                }

                if supportsCanopy {
                    Text(isOverridden
                         ? "Using your entered rate instead of the canopy figure."
                         : "Leave blank to use the canopy figure, or type your own.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                            value: SprayGuidedFormat.factor(carrier.concentrationFactor),
                            caption: supportsCanopy && !isOverridden
                                ? "Canopy dilute ÷ actual applied"
                                : "Dilute ÷ actual applied"
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
                                Text(SprayGuidedFormat.productQuantity(line.totalQuantity, line: line))
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
                            if let derived = SprayGuidedFormat.productDerivedPerHectare(line) {
                                Text(derived)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let perTank = line.quantityPerFullTank, plan.tankSplit.totalTanks > 1 {
                                Text("Per full tank: \(SprayGuidedFormat.productQuantity(perTank, line: line))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            calculationReferenceGroup

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

    /// Every operand and result behind this spray, written out so the numbers
    /// can be checked against a calculator standing in the block.
    ///
    /// Built by `SprayCalculationReferenceBuilder` from the SAME plan and the
    /// SAME volume decision the rest of the screen reads. It recomputes
    /// nothing: a reference that derived its own operands could agree with
    /// itself perfectly while disagreeing with the spray actually recorded,
    /// which would verify nothing at all.
    @ViewBuilder
    private var calculationReferenceGroup: some View {
        let reference = SprayCalculationReferenceBuilder.make(flow: flow)
        if !reference.isEmpty {
            GuidedReviewGroup(title: "Calculation reference") {
                VStack(alignment: .leading, spacing: 14) {
                    referenceBlock("Canopy", lines: reference.canopy)
                    referenceBlock("Spray volume", lines: reference.volume)
                    referenceBlock("Water", lines: reference.water)
                    ForEach(reference.products) { product in
                        referenceBlock(product.name, lines: product.lines)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func referenceBlock(
        _ title: String,
        lines: [SprayCalculationReference.Line]
    ) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VineyardTheme.olive)
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(line.value)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        if let workings = line.workings {
                            Text(workings)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Adds a product line for a product the operator explicitly chose.
    ///
    /// The rate is seeded from the product's VINEYARD registered uses only, on
    /// this vineyard's preferred basis. When the label binds no usable
    /// grapevine rate the line still opens — with no rate selected — so the
    /// operator establishes it rather than inheriting another crop's.
    private func appendChemicalLine(for chemical: SavedChemical) {
        // The product's CONFIRMED rate (`default_rates`) leads: a confirmed
        // scalar populates the line, a confirmed band selects the band and
        // waits for the dose. Only when nothing is confirmed does the
        // registered-use seeding apply as before.
        chemicalLines.append(
            SprayConfirmedRateSeeding.seededLine(
                for: chemical,
                preferring: preferredRateBases,
                fallbackBasis: SprayRateBasisPreference.fallbackBasis(for: effectiveCarrierBasis)
            )
        )
    }

    /// Opens the Chemical Store record for a Products-step line.
    private func openChemicalInspector(for line: ChemicalLine) {
        guard let chemical = store.savedChemicals.first(where: { $0.id == line.chemicalId }) else { return }
        inspectingChemicalLineId = line.id
        inspectingChemical = chemical
    }

    /// Re-checks a line's selected rate after its product was edited or
    /// re-verified in the Chemical Store.
    ///
    /// The refreshed record is read straight from `store.savedChemicals` —
    /// `EditSavedChemicalSheet`'s Save already wrote it there before calling
    /// back — so this asks the SAME `SprayRegisteredUseRates.vineyardRates`
    /// the card itself offers. If the line's `selectedRateId` still resolves,
    /// it is left exactly alone. If re-verification moved or removed that
    /// registered use, the id is reset to a fresh one that matches nothing —
    /// the card then reads as "Select rate", the same unresolved state a brand
    /// new line starts in. It never borrows another crop's or another
    /// target's rate to keep the line looking complete.
    private func revalidateSelectedRate(afterEditing saved: SavedChemical) {
        guard let lineId = inspectingChemicalLineId,
              let index = chemicalLines.firstIndex(where: { $0.id == lineId }),
              chemicalLines[index].chemicalId == saved.id else { return }
        let stillResolves = SprayRegisteredUseRates.vineyardRates(for: saved)
            .contains { $0.id == chemicalLines[index].selectedRateId }
        if !stillResolves {
            chemicalLines[index].selectedRateId = UUID()
            chemicalLines[index].overrideRate = nil
        }
    }

    // MARK: - Calculation & Save

    private func performCalculation(jobDurationHours: Double = 0) {
        guard let equipId = selectedEquipmentId,
              let equip = store.sprayEquipment.first(where: { $0.id == equipId }) else { return }

        let tractor: Tractor? = selectedTractorId.flatMap { id in
            store.currentTractors.first(where: { $0.id == id })
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
    private func persistedRateBasis(for line: ChemicalLine, planLine: SprayProductLineResult) -> SprayProductRateBasis {
        if planLine.basis == .per100Litres { return .per100Litres }
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
    private func chemicalSnapshot(for line: ChemicalLine, planLine: SprayProductLineResult) -> ChemicalLineSnapshot? {
        let captured = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: line.chemicalId,
            productName: planLine.name,
            library: store.savedChemicals,
            // Identity only. Every line on this screen was either picked from the
            // Chemical Store (so it carries an id) or deliberately typed, and a
            // job created from a group-only plan position is NAMED for its group
            // ("FRAC 3"). Allowing a name match here would let such a line adopt a
            // library product's authoritative chemistry — promoting a planned
            // stipulation into a verified classification nobody established.
            allowNameMatch: false
        ).snapshot
        guard let chemical = store.savedChemicals.first(where: { $0.id == line.chemicalId }) else {
            return captured
        }
        // The applied dose and its provenance are frozen on the line (sql/222
        // contract): 2.5 chosen inside a confirmed 2–3 band is what went in
        // THIS tank, and the Chemical Store keeps its band untouched.
        return SprayConfirmedRateSeeding.snapshot(
            base: captured,
            chemical: chemical,
            line: line,
            planLine: planLine
        )
    }

    /// Builds the tanks that get persisted onto the started trip's
    /// `SprayRecord`.
    ///
    /// Reads chemistry EXCLUSIVELY from `guidedTankLines` — the same
    /// `SprayApplicationPlan.productLines` Review and Tank Mixing already
    /// display — and splits each product across tanks using the plan's own
    /// `quantityPerFullTank` / `quantityInLastTank`. The legacy
    /// `SprayCalculator.calculate` chemistry (`chemical.rates.first(where:
    /// { $0.id == line.selectedRateId })`) plays NO part here any more: that
    /// lookup is exactly what silently dropped a structured registered-use
    /// product from the persisted tanks even though Review had already
    /// resolved and displayed it correctly.
    private func buildSprayTanks(tankCapacity: Double) -> [SprayTank] {
        let split = flow.plan.tankSplit
        let totalTanks = split.totalTanks
        let lines = guidedTankLines
        guard totalTanks > 0 else {
            return [SprayTank(tankNumber: 1, waterVolume: 0, sprayRatePerHa: chosenSprayRate, concentrationFactor: concentrationFactor)]
        }

        var tanks: [SprayTank] = []
        for i in 0..<totalTanks {
            let isLast = (i == totalTanks - 1)
            let waterVolume = isLast && split.lastTankLitres > 0 ? split.lastTankLitres : tankCapacity
            let chemicals: [SprayChemical] = lines.compactMap { entry in
                let (line, planLine) = entry
                // A line the plan could not resolve carries no amount to put
                // in ANY tank — it must not silently contribute zero as though
                // it had been calculated and come out empty.
                guard let perFullTank = planLine.quantityPerFullTank,
                      let inLastTank = planLine.quantityInLastTank else { return nil }
                let amount = isLast ? inLastTank : perFullTank
                // Snapshot the saved chemical's costPerBaseUnit (if any) so
                // TripCostService can calculate chemical cost reliably without
                // having to re-resolve the saved chemical later.
                return SprayChemical(
                    name: planLine.name,
                    volumePerTank: amount,
                    ratePerHa: planLine.basis == .wholeBlockArea || planLine.basis == .treatedArea ? planLine.rate : 0,
                    ratePer100L: planLine.basis == .per100Litres ? planLine.rate : 0,
                    costPerUnit: planLine.costPerUnit ?? 0,
                    unit: ChemicalUnit(rawValue: planLine.unit) ?? .litres,
                    // Snapshot the basis the operator actually chose for THIS
                    // line. Without it a banded treated-band quantity would
                    // reload as a whole-block one and silently restate itself.
                    rateBasis: persistedRateBasis(for: line, planLine: planLine),
                    savedChemicalId: line.chemicalId,
                    chemicalSnapshot: chemicalSnapshot(for: line, planLine: planLine)
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
           let equip = store.sprayEquipment.first(where: { $0.id == equipId }) {
            pendingTanks = buildSprayTanks(tankCapacity: equip.tankCapacityLitres)
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

        pendingTanks = buildSprayTanks(tankCapacity: equip.tankCapacityLitres)

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
            ? buildSprayTanks(tankCapacity: equip.tankCapacityLitres)
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
            store.currentTractors.first(where: { $0.id == id })?.displayName
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
        let tanks: [SprayTank] = buildSprayTanks(tankCapacity: equip.tankCapacityLitres)

        let tractorName = selectedTractorId.flatMap { id in
            store.currentTractors.first(where: { $0.id == id })?.displayName
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
    /// Opens the existing Chemical Store record for THIS line's product, as a
    /// sheet over the calculator, so the operator can inspect, correct or
    /// re-verify it without leaving the spray they are composing.
    let onInspect: () -> Void
    let onDelete: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var overrideText: String = ""
    /// Why the typed dose was refused against the confirmed band, if it was.
    @State private var rangeRejection: String?

    /// The CONFIRMED rate governing this line's basis, from `default_rates`.
    private var confirmedResolution: ChemicalSprayRateHandoff.Resolution? {
        guard let chem = selectedChemical else { return nil }
        return SprayConfirmedRateSeeding.resolution(for: chem, basis: line.basis)
    }

    /// The confirmed band the operator must choose a dose inside, if any.
    private var confirmedRange: ChemicalSprayRateHandoff.RangeSelection? {
        confirmedResolution?.rangeSelection
    }

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

    /// The rates this product offers FOR A VINEYARD SPRAY.
    ///
    /// Scoped to grapevine registered uses. An approved label may register
    /// dozens of crops — Dithane Rainshield's carries tobacco blue mould,
    /// brown spot on mandarin and citrus black spot — and offering those here
    /// is how a tobacco `2.2 kg/ha` rate became selectable for a grapevine
    /// spray. Nothing is deleted: every other crop stays on the record and in
    /// the Chemical editor's own all-crops view.
    private var offeredRates: [SpraySelectableRate] {
        guard let chem = selectedChemical else { return [] }
        return SprayRegisteredUseRates.vineyardRates(for: chem)
    }

    /// True when the label registers this product on grapevines but bound no
    /// usable rate to any of those uses.
    ///
    /// Deliberately distinct from "not registered on grapevines": the two need
    /// different words in front of an operator, and an empty picker says
    /// neither.
    private var hasVineyardUseWithoutRate: Bool {
        guard let chem = selectedChemical else { return false }
        return offeredRates.isEmpty && SprayRegisteredUseRates.hasVineyardUse(chem)
    }

    private var selectedOfferedRate: SpraySelectableRate? {
        offeredRates.first { $0.id == line.selectedRateId }
    }

    // MARK: - P6 — rate basis as a primary control

    /// True when a GRAPEVINE registered use states a real per-100 L rate.
    ///
    /// This is the whole 100 m recommendation rule. A per-100 L rate is what
    /// makes the dilute/runoff calculation lawful: litres per 100 m of row come
    /// from the canopy, and the label's concentration turns those litres into
    /// product. A per-hectare rate contains no concentration, so deriving a
    /// per-100 L figure from one would be inventing a label rate that the
    /// regulator never approved.
    private var hasGenuinePer100LVineyardRate: Bool {
        offeredRates.contains { $0.isSelectable && $0.basis == .per100Litres }
    }

    private var hasGenuinePerHectareVineyardRate: Bool {
        offeredRates.contains { $0.isSelectable && $0.basis == .perHectare }
    }

    /// 100 m is recommended only where the label supports it.
    private var recommendsHundredMetres: Bool { hasGenuinePer100LVineyardRate }

    /// Move the line onto a basis by selecting a rate that genuinely states it.
    ///
    /// Deliberately a no-op when no offered rate carries the basis: flipping
    /// `line.basis` on its own would reinterpret the CURRENT rate under a
    /// different denominator, which is exactly the cross-conversion this
    /// control exists to prevent.
    private func selectBasis(_ basis: ChemicalRateBasis) {
        guard let rate = offeredRates.first(where: { $0.isSelectable && $0.basis == basis })
        else { return }
        line.selectedRateId = rate.id
        line.basis = basis
    }

    /// The `[ Per 100 L ] [ Per ha ]` control — the PRODUCT'S LABEL RATE BASIS.
    ///
    /// # This is not the carrier control, and it used to look like one
    ///
    /// It was headed "Application basis" and its buttons read `100 m` and
    /// `Per ha` — the exact words on the Carrier Volume step's own selector.
    /// So a Dithane line, whose label states `150–200 g/100 L` and no
    /// per-hectare grapevine rate at all, rendered as `[100 m — Recommended]`
    /// beside a greyed-out `[Per ha]`, and read as VineTrack refusing to let
    /// the operator spray that product on a hectare basis. It was never saying
    /// that. It was saying the LABEL has no per-hectare rate.
    ///
    /// The two are genuinely independent:
    ///
    /// ```text
    /// carrier basis   L/100 m  or  L/ha     — how this vineyard measures water
    /// label rate basis  /100 L  or  /ha     — what the regulator printed
    /// ```
    ///
    /// A `150–200 g/100 L` label is calculated identically from either carrier
    /// basis: the concentration is multiplied by the dilute carrier volume,
    /// whether that volume was reached through row metres or through hectares.
    /// Nothing here converts one into the other, and greying out a button on
    /// this control never restricts the carrier workflow.
    @ViewBuilder
    private var rateBasisControl: some View {
        let current = selectedOfferedRate?.basis ?? line.basis
        VStack(alignment: .leading, spacing: 8) {
            Text("Label rate basis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                basisOption(
                    .per100Litres,
                    title: "Per 100 L",
                    isCurrent: current == .per100Litres,
                    isAvailable: hasGenuinePer100LVineyardRate,
                    isRecommended: recommendsHundredMetres
                )
                basisOption(
                    .perHectare,
                    title: "Per ha",
                    isCurrent: current == .perHectare,
                    isAvailable: hasGenuinePerHectareVineyardRate,
                    isRecommended: !recommendsHundredMetres && hasGenuinePerHectareVineyardRate
                )
            }

            Text("What the label's rate is measured against. Your water volume "
                 + "basis is chosen in Carrier Volume and is not changed by this.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !hasGenuinePer100LVineyardRate {
                Text("This label states no per-100 L grapevine rate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !hasGenuinePerHectareVineyardRate {
                Text("This label states no per-hectare grapevine rate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func basisOption(
        _ basis: ChemicalRateBasis,
        title: String,
        isCurrent: Bool,
        isAvailable: Bool,
        isRecommended: Bool
    ) -> some View {
        Button {
            selectBasis(basis)
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if isRecommended {
                    Text("Recommended")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(
                isCurrent
                    ? VineyardTheme.leafGreen.opacity(0.18)
                    : Color(.tertiarySystemGroupedBackground)
            )
            .foregroundStyle(isCurrent ? VineyardTheme.leafGreen : Color.secondary)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isCurrent ? VineyardTheme.leafGreen : Color.clear,
                        lineWidth: 1.5
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.4)
        .accessibilityLabel(
            isRecommended ? "\(title), recommended" : title
        )
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

        /// True when VineTrack derived selectable points from this use's band.
        /// The band itself then becomes context rather than an option, because
        /// choosing "150–200" calculates nothing.
        var hasPresets: Bool { rates.contains { $0.isRangePreset } }
    }

    /// The unit the applied-rate field reads and writes in.
    ///
    /// The LABEL's unit whenever the selected rate states one that converts,
    /// otherwise the product's Chemical Store unit. A label that says
    /// `150–200 g/100 L` must be answered in grams: asking an operator to
    /// express `175 g` as `0.175 Kg`, because the drum happens to be stocked
    /// in kilograms, is an invitation to enter a rate 1000× wrong.
    private var appliedRateUnit: String {
        guard let chem = selectedChemical else { return "" }
        // A confirmed rate's own unit leads: the operator confirmed `2–3 L`
        // and must answer in litres.
        if let confirmed = confirmedResolution {
            let unit = confirmed.prefill?.unit ?? confirmed.rangeSelection?.unit ?? ""
            if !unit.isEmpty,
               SprayRegisteredUseRates.baseValue(1, labelUnit: unit, chemical: chem) != nil {
                return unit
            }
        }
        if let labelUnit = selectedOfferedRate?.labelUnit.trimmedNonEmpty,
           SprayRegisteredUseRates.baseValue(1, labelUnit: labelUnit, chemical: chem) != nil {
            return labelUnit
        }
        return chem.unit.rawValue
    }

    /// The label's stated band behind the current selection, e.g.
    /// `"150–200 g/100 L"`.
    ///
    /// Present for the band itself AND for a point chosen inside it: an
    /// operator who picked 175 still needs to see what the label actually
    /// permits, because 175 is VineTrack's arithmetic and 150–200 is the
    /// regulator's.
    private var appliedRateRangeText: String? {
        selectedOfferedRate?.labelRangeText
    }

    /// The applied rate in BASE units — manual entry first, otherwise whatever
    /// the selected rate seeds. `nil` while the line is still unresolved.
    private var effectiveAppliedBaseValue: Double? {
        line.overrideRate ?? selectedOfferedRate?.seed.seedableValue
    }

    /// The applied rate as the operator should read it, in the label's unit.
    private var effectiveAppliedDisplay: Double? {
        guard let chem = selectedChemical, let base = effectiveAppliedBaseValue else { return nil }
        return SprayRegisteredUseRates.displayValue(
            base,
            labelUnit: appliedRateUnit,
            chemical: chem
        ) ?? chem.unit.fromBase(base)
    }

    /// The label-range warning, when a manual entry sits outside the band.
    private var appliedRateRangeWarning: String? {
        SprayLabelRangeCheck.warning(
            appliedBaseValue: effectiveAppliedBaseValue,
            rate: selectedOfferedRate
        )
    }

    /// The seedable rate in the applied-rate field's own unit, when the current
    /// selection actually provides one. `nil` for a range, a reference-only
    /// entry or an unresolved rate — all of which the operator must resolve.
    private var recommendedRateDisplay: Double? {
        guard let chem = selectedChemical,
              let base = selectedOfferedRate?.seed.seedableValue else { return nil }
        return SprayRegisteredUseRates.displayValue(
            base,
            labelUnit: appliedRateUnit,
            chemical: chem
        ) ?? chem.unit.fromBase(base)
    }

    /// The rate menu, shared by the compact basis chip and the Rate row.
    @ViewBuilder
    private func rateMenuItems(showsCheckmark: Bool) -> some View {
        ForEach(rateGroups) { group in
            Section(group.title ?? "Saved rates") {
                ForEach(group.rates) { rate in
                    // A band whose points are offered below it stops being an
                    // option and becomes the heading those points sit under.
                    // Leaving it selectable gave the operator a fourth choice
                    // that calculated nothing — which is the defect this whole
                    // change exists to remove.
                    let isBandWithPoints = rate.requiresOperatorRate && group.hasPresets
                    if rate.isSelectable, !isBandWithPoints {
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
                    } else if isBandWithPoints {
                        Button {} label: {
                            Label("Label range: \(rate.displayText)", systemImage: "ruler")
                        }
                        .disabled(true)
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
            // P5 — ROW 1: the product name owns the full card width.
            //
            // "DITHANE RAINSHIELD NEO TEC FUNGICIDE" was being squeezed into
            // whatever space the label, product-page, basis and remove controls
            // left over, which on a phone is a narrow column that truncates the
            // one string identifying what is about to be sprayed. Actions moved
            // to their own row below; the name is never shrunk to fit them.
            VStack(alignment: .leading, spacing: 10) {
                // The name itself opens the Chemical Store record — the
                // operator's one route to inspect, correct or re-verify this
                // product without leaving the calculator. Disabled while no
                // chemical is chosen: there is nothing yet to inspect.
                Button {
                    onInspect()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "flask.fill")
                            .foregroundStyle(VineyardTheme.leafGreen)
                            .font(.subheadline)
                        Text(selectedChemical?.name ?? "Select Chemical")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if selectedChemical != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(selectedChemical == nil)
                .accessibilityHint("Opens this product's Chemical Store record to review or edit")

                // P5 — ROW 2: actions.
                HStack(spacing: 2) {
                    if let chem = selectedChemical,
                       let url = Self.normalizedLabelURL(chem.labelURL) {
                        Button {
                            openURL(url)
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.subheadline)
                                .foregroundStyle(VineyardTheme.olive)
                                .frame(width: 44, height: 44)
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
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open product page (not the official label)")
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove product")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if !offeredRates.isEmpty {
                Divider().padding(.leading, 14)
                rateBasisControl
            }

            Divider().padding(.leading, 14)

            VStack(alignment: .leading, spacing: 4) {
                Text("Chemical").font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(chemicals) { chem in
                        Button {
                            if line.chemicalId != chem.id {
                                // Re-seed from the NEW product's confirmed rate,
                                // then its own registered rates. Left alone, a
                                // stale `selectedRateId` keeps pointing at the
                                // previous product's rate and the line silently
                                // keeps that product's basis.
                                SprayConfirmedRateSeeding.seed(
                                    &line,
                                    from: chem,
                                    preferring: preferredRateBases,
                                    fallbackBasis: line.basis
                                )
                                rangeRejection = nil
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

    /// The applied label rate the operator is using.
    ///
    /// # Why this is not called "Override Rate" any more
    ///
    /// For a fixed label rate it genuinely is an override. For a RANGE it is
    /// not: `150–200 g/100 L` is not a recommendation VineTrack is offering
    /// and the operator is overruling — it is a band the label requires them
    /// to choose a point inside. Heading that field "Override Rate" over an
    /// empty box, with the store's kilogram unit beside it, produced the
    /// summary `0.0 Kg/100 L — Unavailable` and gave no clue what was wanted.
    @ViewBuilder
    private func overrideRateRow(chem: SavedChemical) -> some View {
        let basisLabel = line.basis == .perHectare ? "/ha" : "/100 L"
        let unitLabel = appliedRateUnit
        let isOverridden = line.overrideRate != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Applied label rate")
                    .font(.caption).foregroundStyle(.secondary)
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

            // What is ACTUALLY being applied, resolved from wherever it came
            // from. Picking 175 from the menu and picking it by typing must
            // read identically here — the difference between them is
            // provenance, and provenance is what the Manual badge is for.
            if let applied = effectiveAppliedDisplay {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(SprayRateFormatter.format(applied)) \(unitLabel)\(basisLabel)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.olive)
                        .monospacedDigit()
                    Spacer()
                    Text(isOverridden ? "Entered manually" : "From selected rate")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VineyardTheme.olive.opacity(0.10))
                .clipShape(.rect(cornerRadius: 8))
            }

            if let range = confirmedRange {
                // The CONFIRMED band from the Chemical Store, named as such.
                // The operator must enter a rate inside it; nothing here
                // selects an endpoint or the midpoint on their behalf.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Confirmed rate range: \(SprayRateFormatter.format(range.min))–\(SprayRateFormatter.format(range.max)) \(range.unit)\(basisLabel)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(range.isUserEntered ? "User-confirmed" : "From label")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((range.isUserEntered ? Color.orange : VineyardTheme.leafGreen).opacity(0.14), in: Capsule())
                            .foregroundStyle(range.isUserEntered ? Color.orange : VineyardTheme.leafGreen)
                    }
                    Text("Enter the application rate you are using, within this range.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("confirmedRateRange")
            } else if let prefill = confirmedResolution?.prefill {
                HStack(spacing: 6) {
                    Text("Confirmed rate: \(SprayRateFormatter.format(prefill.rate)) \(prefill.unit)\(basisLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(prefill.isUserEntered ? "User-confirmed" : "From label")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(prefill.isUserEntered ? Color.orange : VineyardTheme.leafGreen)
                }
            } else if let rangeText = appliedRateRangeText {
                Text("Label range: \(rangeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField(
                    confirmedRange != nil
                        ? "Application rate"
                        : (recommendedRateDisplay.map { SprayRateFormatter.format($0) } ?? "Enter rate"),
                    text: $overrideText
                )
                .accessibilityIdentifier("applicationRateField")
                .keyboardType(.decimalPad)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
                .onChange(of: overrideText) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    let typed = Double(trimmed.replacingOccurrences(of: ",", with: "."))
                    if trimmed.isEmpty {
                        line.overrideRate = nil
                        rangeRejection = nil
                    } else if let range = confirmedRange {
                        // A confirmed band is a gate, not a warning: a dose
                        // outside it is refused and the line stays unresolved,
                        // so the spray cannot be saved off the confirmed range.
                        let outcome = SprayConfirmedRateSeeding.validate(typed: typed ?? 0, against: range)
                        if let accepted = outcome.acceptedValue {
                            line.overrideRate = SprayRegisteredUseRates.baseValue(
                                accepted,
                                labelUnit: unitLabel,
                                chemical: chem
                            ) ?? accepted
                            rangeRejection = nil
                        } else {
                            line.overrideRate = nil
                            rangeRejection = SprayConfirmedRateSeeding.rejectionMessage(
                                outcome, range: range, basisSuffix: basisLabel
                            )
                        }
                    } else if let typed, typed > 0 {
                        // Stored in BASE units, the same space
                        // `SprayRegisteredUseRates.seedValue` returns, so the
                        // typed and the seeded paths cannot mean different
                        // things by the same number.
                        line.overrideRate = SprayRegisteredUseRates.baseValue(
                            typed,
                            labelUnit: unitLabel,
                            chemical: chem
                        ) ?? typed
                    }
                }
                Text("\(unitLabel)\(basisLabel)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let rangeRejection {
                Label(rangeRejection, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("applicationRateRejection")
            }

            // An off-label rate is the operator's call to make and to record.
            // It is NOT presented as though the regulator sanctioned it, and
            // the band is never rewritten to fit what was typed.
            if rangeRejection == nil, let warning = appliedRateRangeWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
        if confirmedRange != nil {
            Text("This product's confirmed rate is a range. Type the rate you are "
                 + "applying in \(appliedRateUnit)\(basisLabel) — it must fall within the range.")
        } else if let rate = selectedOfferedRate, rate.isRangePreset {
            // The point came from VineTrack's arithmetic on the label's band,
            // and says so. Calling it "Recommended" would attribute a choice to
            // the regulator that the regulator explicitly left open.
            Text("A point inside the registered range, chosen by you. "
                 + "Type a different value to apply your own.")
        } else if let recommendedRateDisplay {
            Text("Recommended: \(SprayRateFormatter.format(recommendedRateDisplay)) "
                 + "\(appliedRateUnit)\(basisLabel)")
        } else if let rate = selectedOfferedRate, rate.requiresOperatorRate {
            // Named bounds, in the label's own unit, so the operator is never
            // left to work out what a valid answer looks like.
            Text("Choose a rate from the Rate menu, or type the rate you are "
                 + "applying in \(appliedRateUnit)\(basisLabel).")
        } else if let rate = selectedOfferedRate {
            Text("\(rate.displayText) — enter the rate you are applying.")
        } else if hasVineyardUseWithoutRate {
            // Registered on grapevines, but the label bound no rate to those
            // uses. Said plainly, because the alternative an operator reaches
            // for is another crop's rate off the same label.
            Text("Registered on grapevines, but this label states no grapevine "
                 + "rate in VineTrack. Check the approved label and enter the "
                 + "rate you are applying.")
        } else {
            Text("Enter the rate you are applying.")
        }
    }

    private func syncOverrideText() {
        if let value = line.overrideRate {
            let shown = selectedChemical.flatMap {
                SprayRegisteredUseRates.displayValue(
                    value,
                    labelUnit: appliedRateUnit,
                    chemical: $0
                )
            } ?? value
            let formatted = SprayRateFormatter.format(shown)
            if overrideText != formatted, Double(overrideText) != shown {
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
