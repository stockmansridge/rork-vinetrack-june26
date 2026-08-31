import Foundation

/// Whether the product is measured as a liquid or a solid.
nonisolated enum ChemicalFormType: String, CaseIterable, Identifiable, Sendable {
    case liquid = "Liquid"
    case solid = "Solid"

    var id: String { rawValue }

    var units: [ChemicalUnit] {
        switch self {
        case .liquid: return [.litres, .millilitres]
        case .solid: return [.kilograms, .grams]
        }
    }

    static func from(unit: ChemicalUnit) -> ChemicalFormType {
        switch unit {
        case .litres, .millilitres: return .liquid
        case .kilograms, .grams: return .solid
        }
    }

    /// The form the record explicitly STATES, if it states one.
    ///
    /// `product_form` is the product's own description of itself; `unit` is
    /// only how a rate happens to be quoted. Reading the explicit value first
    /// stops a millilitre rate on a wettable granule from re-describing the
    /// product as a liquid.
    static func stated(_ productForm: String) -> ChemicalFormType? {
        switch productForm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "liquid": return .liquid
        case "solid": return .solid
        default: return nil
        }
    }
}

extension ChemicalUnit {
    /// The short token label rates are quoted in (`"L"`, `"mL"`, `"kg"`, `"g"`).
    nonisolated var labelRateToken: String {
        switch self {
        case .litres: return "L"
        case .millilitres: return "mL"
        case .kilograms: return "kg"
        case .grams: return "g"
        }
    }

    nonisolated static func fromLabelRateToken(_ raw: String) -> ChemicalUnit? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "l", "litre", "litres", "liter", "liters": return .litres
        case "ml", "millilitre", "millilitres": return .millilitres
        case "kg", "kilogram", "kilograms": return .kilograms
        case "g", "gram", "grams": return .grams
        default: return nil
        }
    }
}

/// Everything the Chemical Store editor holds for one editing session.
///
/// # One record, one representation
///
/// The Review screen used to show the operator two editable copies of the same
/// product. The outer form had `Use / Problem`, `Target Problem`, `Rate per ha`
/// and `Rate per 100L`; a second full editor behind an "Edit Chemistry &
/// Identity" button had crop, target, structured rates, WHP and re-entry. On a
/// real Dithane Rainshield lookup the inner screen held `2.5 kg/ha` while the
/// outer one displayed `Rate per ha: 0` — not two records, but two UIs over one
/// record, disagreeing.
///
/// So the structured sql/194 chemistry is now the ONLY representation the
/// operator edits. The fields that overlapped it are gone from the form, and
/// the legacy scalars they wrote are produced from the structured record at
/// save time. The direction of truth runs one way:
///
/// ```text
/// structured Chemical Intelligence  →  legacy compatibility scalars
/// ```
///
/// and never back. Product name, manufacturer, category and the label link are
/// computed views onto `chemistryDraft`, so there is literally no second stored
/// copy of them that could drift.
///
/// # One lifetime
///
/// The session is seeded exactly once, by `make(...)`. Nothing re-seeds on
/// redraw, scroll, `onAppear`, scene change or sheet dismissal — once Review
/// Chemical is open its values change only when the operator changes them.
nonisolated struct ChemicalReviewSession: Sendable, Hashable {

    // MARK: The structured record (sql/194) — the source of truth

    /// Actives, concentrations, groups, registration identity, the label link,
    /// registered uses, rates, WHP, re-entry and restrictions.
    var chemistryDraft: ChemicalManualDraft

    // MARK: Product presentation

    var formType: ChemicalFormType
    var unit: ChemicalUnit
    var modeOfAction: String
    var notes: String

    // MARK: Legacy fallbacks for records with no structured uses

    /// Free-text use, editable ONLY while the record has no structured
    /// registered uses. Once structured uses exist they are authoritative and
    /// this becomes a derived projection.
    var use: String
    var problem: String

    // MARK: Purchase

    var trackPurchase: Bool
    var containerSizeText: String
    var containerUnit: ChemicalUnit
    var costText: String

    // MARK: Fertiliser / pack / inventory

    var packSizeText: String
    var packPriceText: String
    var densityText: String
    var nitrogenText: String
    var phosphorusText: String
    var potassiumText: String
    var analysisBasis: FertiliserAnalysisBasis
    var organicCertified: Bool
    var inventoryText: String
    var applicationNotes: String

    // MARK: Carried through, never displayed

    /// The structured chemistry this session OPENED with. Reconciliation needs
    /// it: without it every prefilled value would look freshly hand-typed, and
    /// a register-confirmed product would save with its authoritative citations
    /// withdrawn simply because the operator pressed Save without editing.
    let seedIntelligence: ChemicalIntelligence?
    /// The record's original free-text chemistry, kept ONLY so a product with
    /// no structured chemistry at all is not blanked by the act of saving it.
    let seedActiveIngredientText: String
    let seedChemicalGroupText: String
    /// Stable ids for the projected legacy rate rows, so a save does not churn
    /// identities that other records may reference.
    let existingPerHaRateId: UUID?
    let existingPer100LRateId: UUID?

    var masterChemicalId: UUID?
    var masterSourceRevision: Int?

    /// The operator's OPERATIONAL default rate, per basis, as an option id.
    ///
    /// # Two separate concepts, deliberately
    ///
    /// `chemistryDraft` holds the AUTHORITATIVE registered rates — every one
    /// the label states, with its condition. This holds which ONE of them this
    /// vineyard has decided to dose by. Choosing a default must never edit,
    /// narrow or delete the registered list: the label does not change because
    /// a grower picked a number off it.
    ///
    /// Empty means "not chosen yet", which is a real state — see
    /// `ChemicalDefaultRatePlan`, where several applicable rates require the
    /// operator to answer before anything is defaulted.
    var selectedDefaultRateIds: [ChemicalDefaultRateBasis: String]

    /// The EXACT dose this vineyard uses, per basis, when the registered rate
    /// it was chosen from is a band.
    ///
    /// # Why this is stored apart from the label
    ///
    /// A label printing `100–200 g/100 L` authorises every dose between those
    /// ends; a vineyard still has to pour one number. That number is an
    /// OPERATIONAL decision and it is held here, never written back into
    /// `chemistryDraft`. Narrowing the registered range to the grower's own
    /// figure would destroy label evidence — the next operator, the
    /// re-verification comparison and the audit trail would all be told the
    /// label says `150` when it says `100–200`.
    ///
    /// Only ever set to a value the selected option actually authorises (see
    /// `setDefaultRateValue`), so it cannot carry a dose off the label.
    /// Absent means "start from the bottom of the band", which is the safe end.
    var defaultRateValues: [ChemicalDefaultRateBasis: Double]

    /// The vineyard's state/territory, when it is known.
    ///
    /// Drives step 1 of the recommendation rule. `nil` is honest and safe: it
    /// skips straight to "is there exactly one rate at all?", which is a
    /// weaker answer but never a wrong one, and can never recommend a rate
    /// registered for somewhere else.
    var jurisdiction: ChemicalRateJurisdiction?

    /// The SERVER's canonical default-rate options for the product under
    /// review, when a structured lookup supplied them.
    ///
    /// `nil` on the plain edit path, where no fresh lookup has run. A default
    /// can only be PERSISTED from a server option (see
    /// `StoredChemicalDefaultRate.confirmed`), so this is what separates "the
    /// operator may confirm a new default" from "this record can only carry
    /// forward the default it already had".
    var serverDefaultRateOptions: ChemicalServerDefaultRateOptions?

    /// True when reviewing a looked-up product rather than editing something
    /// already on file.
    let isReviewingLookup: Bool

    /// The save-contract violations the record ALREADY had when this session
    /// opened (task §11).
    ///
    /// # Why a baseline exists rather than a flat rule
    ///
    /// The mandatory contract must stop a NEW chemical entering the store
    /// unusable. Applied flatly it would also strand every legacy record: a
    /// pre-Chemical-Intelligence product has no structured grapevine use and
    /// no structured rate, so an operator opening one to fix a typo or update
    /// a price would find Save permanently disabled — and would lose the edit.
    /// A record that cannot be saved cannot be repaired, which makes the data
    /// worse rather than better.
    ///
    /// So the rule is "never make it worse": a violation blocks Save only if
    /// the record did not already have it. A legacy chemical stays editable
    /// and can be brought up to contract a field at a time; a compliant
    /// chemical can never be edited INTO non-compliance; and a brand-new
    /// chemical has an empty baseline, so the full contract applies.
    let baselineViolationCodes: Set<ChemicalSaveViolationCode>

    // MARK: - One value, one place: computed views onto the structured draft

    /// The product name. Stored once, in the structured record.
    var name: String {
        get { chemistryDraft.productName }
        set { chemistryDraft.productName = newValue }
    }

    /// The manufacturer/registrant. ONE editable value — the structured
    /// registrant — projected onto `SavedChemical.manufacturer` at save.
    var manufacturer: String {
        get { chemistryDraft.registrant }
        set { chemistryDraft.registrant = newValue }
    }

    /// The REGULATOR's approved label link (APVMA and equivalents).
    ///
    /// ONE editable value: whatever the lookup found in
    /// `registration.regulatorLabelURL` IS what the operator sees.
    var labelURL: String {
        get { chemistryDraft.labelReference }
        set { chemistryDraft.labelReference = newValue }
    }

    /// The manufacturer-hosted label — the PRIMARY "Open label" link.
    ///
    /// Separate from `labelURL` because the regulator document must stay
    /// available even when the manufacturer's rendering is the one a grower
    /// reads. Leading with the practical label never means discarding the
    /// authoritative one.
    var manufacturerLabelURL: String {
        get { chemistryDraft.manufacturerLabelReference }
        set { chemistryDraft.manufacturerLabelReference = newValue }
    }

    /// The registrant's PRODUCT page — marketing, never a label.
    ///
    /// A computed view onto the structured draft for the same reason the two
    /// label links are: a second stored copy is a second thing that can drift,
    /// and the drift that matters here is a page quietly becoming a label.
    var productURL: String {
        get { chemistryDraft.productReference }
        set { chemistryDraft.productReference = newValue }
    }

    var productCategory: ProductCategory? {
        get { ProductCategory.parse(chemistryDraft.productCategory) }
        set { chemistryDraft.productCategory = newValue?.rawValue ?? "" }
    }

    /// The country whose register this product belongs to.
    var countryCode: String {
        get { chemistryDraft.countryCode }
        set { chemistryDraft.countryCode = ChemicalRegistration.normaliseCountry(newValue) }
    }

    // MARK: - Seeding

    /// Build the session ONCE.
    ///
    /// - Parameters:
    ///   - chemical: the stored record being edited, or `nil` when creating.
    ///   - prefill: a populated but unsaved draft from a lookup — the Review
    ///     Chemical case.
    ///   - fallbackCountry: the vineyard's country, used only when the record
    ///     does not already name one. An imported product's own country is
    ///     never overwritten just because it was opened.
    ///
    /// # The prefill wins, when there is one
    ///
    /// `prefill` is not a second, weaker copy of `chemical` — it IS `chemical`
    /// after `ChemicalReviewMerge` folded the lookup into it. Reading `chemical`
    /// first therefore threw away every field the lookup had just established,
    /// silently, on the one path where a lookup had definitely run: Match &
    /// Verify on a product already in the store. `chemical` still decides what
    /// Save does (update, not create); it no longer decides what is displayed.
    ///   - jurisdiction: the vineyard's state/territory, when known. Used ONLY
    ///     to recommend a default rate; it never filters, edits or hides a
    ///     registered rate.
    static func make(
        chemical: SavedChemical?,
        prefill: SavedChemical?,
        fallbackCountry: String,
        jurisdiction: ChemicalRateJurisdiction? = nil,
        serverDefaultRateOptions: ChemicalServerDefaultRateOptions? = nil
    ) -> ChemicalReviewSession {
        guard let source = prefill ?? chemical else {
            return ChemicalReviewSession(
                chemistryDraft: ChemicalManualEntry.draft(from: nil, fallbackCountry: fallbackCountry),
                jurisdiction: jurisdiction,
                serverDefaultRateOptions: serverDefaultRateOptions
            )
        }

        var chemistry = ChemicalManualEntry.draft(from: source, fallbackCountry: fallbackCountry)
        if chemistry.countryCode.isEmpty {
            chemistry.countryCode = ChemicalRegistration.normaliseCountry(fallbackCountry)
        }

        // Legacy → structured, ONCE. An old record whose only rate lives in the
        // scalar columns gets it lifted into the structured label rates, so the
        // operator edits it in the one place the rest of the app now reads. From
        // this save onwards the structured value is the truth.
        if chemistry.productRates.isEmpty, chemistry.uses.allSatisfy({ $0.rates.isEmpty }) {
            chemistry.productRates = legacyRateDrafts(from: source)
        }

        let stored = source.chemicalIntelligence.flatMap { $0.isEmpty ? nil : $0 }
        let perHa = source.rates.first { $0.basis == .perHectare }
        let per100L = source.rates.first { $0.basis == .per100Litres }

        // Measure the record AS OPENED, before the operator touches anything.
        // Only a record already on file earns a baseline: a lookup being
        // reviewed for the first time is a NEW chemical and must satisfy the
        // contract in full, however complete the lookup happened to be.
        let recovered = recoveredDefaults(from: source, chemistry: chemistry, stored: stored)

        let baseline: Set<ChemicalSaveViolationCode> = chemical == nil
            ? []
            : Set(
                ChemicalSaveContract.evaluate(
                    productName: source.name,
                    productCategory: chemistry.productCategory,
                    intelligence: ChemicalManualEntry.proposedIntelligence(
                        from: chemistry, existing: stored
                    ),
                    intent: .sprayReady
                ).violations.map(\.code)
            )

        return ChemicalReviewSession(
            isReviewingLookup: chemical == nil && prefill != nil,
            chemistryDraft: chemistry,
            // The product's own statement of its form outranks whatever unit a
            // rate happens to be quoted in.
            formType: ChemicalFormType.stated(source.productForm)
                ?? ChemicalFormType.from(unit: source.unit),
            unit: source.unit,
            modeOfAction: source.modeOfAction,
            notes: source.notes,
            use: source.use,
            problem: source.problem,
            trackPurchase: source.purchase != nil,
            containerSizeText: source.purchase.map { formatRate($0.containerSizeML) } ?? "",
            containerUnit: source.purchase?.containerUnit ?? source.unit,
            costText: source.purchase.flatMap { $0.costDollars > 0 ? formatRate($0.costDollars) : nil } ?? "",
            packSizeText: source.packSize.map(formatRate) ?? "",
            packPriceText: source.pricePerPack.map(formatRate) ?? "",
            densityText: source.density.map(formatRate) ?? "",
            nitrogenText: source.nitrogenPercent.map(formatRate) ?? "",
            phosphorusText: source.phosphorusPercent.map(formatRate) ?? "",
            potassiumText: source.potassiumPercent.map(formatRate) ?? "",
            analysisBasis: FertiliserAnalysisBasis(rawValue: source.analysisBasis) ?? .elemental,
            organicCertified: source.organicCertified,
            inventoryText: source.inventoryQuantity.map(formatRate) ?? "",
            applicationNotes: source.applicationNotes,
            seedIntelligence: stored,
            seedActiveIngredientText: source.activeIngredient,
            seedChemicalGroupText: source.chemicalGroup,
            existingPerHaRateId: perHa?.id,
            existingPer100LRateId: per100L?.id,
            masterChemicalId: source.masterChemicalId,
            masterSourceRevision: source.masterSourceRevision,
            // A default the operator already chose is RECOVERED, never
            // re-decided. Re-running the recommendation on open would
            // overwrite a deliberate choice every time the record was viewed.
            selectedDefaultRateIds: recovered.ids,
            defaultRateValues: recovered.values,
            jurisdiction: jurisdiction,
            serverDefaultRateOptions: serverDefaultRateOptions,
            baselineViolationCodes: baseline
        )
    }

    /// Recover the operator's stored default selection from the legacy rate
    /// columns.
    ///
    /// The chosen default persists into `SavedChemical.rates` (see
    /// `legacyProjection`), which is what the Spray Tool already reads. Coming
    /// back the other way is a MATCH against the authoritative options, never a
    /// reconstruction: a stored value that no longer corresponds to any
    /// registered rate — because the label was re-verified and moved on —
    /// selects nothing, and the recommendation rule applies again.
    private static func recoveredDefaults(
        from source: SavedChemical,
        chemistry: ChemicalManualDraft,
        stored: ChemicalIntelligence?
    ) -> (ids: [ChemicalDefaultRateBasis: String], values: [ChemicalDefaultRateBasis: Double]) {
        let grapevine = ChemicalManualEntry
            .proposedIntelligence(from: chemistry, existing: stored)
            .registeredUses.statedUses.viticultural
        guard !grapevine.isEmpty else { return ([:], [:]) }

        var ids: [ChemicalDefaultRateBasis: String] = [:]
        var values: [ChemicalDefaultRateBasis: Double] = [:]

        // The CONFIRMED default (sql/214) is the authority when one exists.
        //
        // It records which registered rate a human actually chose, so it is
        // read before the legacy `rates` projection below — those are only
        // numbers, and matching a number back to a direction is inference. A
        // stored option whose supporting direction no longer exists on the
        // current label recovers NOTHING, which is the correct outcome: the
        // operator is asked to confirm again rather than silently dosed off a
        // rate the label has withdrawn.
        if let confirmed = source.defaultRates {
            for basis in ChemicalDefaultRateBasis.allCases {
                guard let slot = confirmed.slot(basis) else { continue }
                let options = ChemicalDefaultRate.options(basis, from: grapevine)
                // Re-matching a STORED slot to a display option.
                //
                // This used to re-mint the option key from the label and
                // compare the result to `slot.optionKey`. That is the local
                // identity generation this release removes: a device-side
                // mirror of the server's hashing only agrees for as long as
                // nobody edits either side, and when it drifts the stored
                // default silently stops matching its own option.
                //
                // The stored slot already CARRIES the canonical identity, so
                // nothing needs computing. It is matched on what the operator
                // can actually see — same unit, and an amount the option still
                // authorises — and the slot's own `option_key`/`rate_ids` are
                // then carried forward verbatim, so re-confirming an untouched
                // record rewrites the identity to exactly what it already was.
                let storedUnit = slot.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                let match = options.first { option in
                    guard option.rate.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                        == storedUnit
                    else { return false }
                    guard let stored = slot.value else { return false }
                    return option.authorises(stored)
                }
                guard var match else { continue }
                // Carry the STORED identity, never a recomputed one.
                match.server = ChemicalServerDefaultRateOption(
                    optionKey: slot.optionKey,
                    rateIds: slot.rateIds,
                    basis: slot.basis,
                    unit: slot.unit,
                    value: match.rate.value,
                    minValue: match.rate.minValue,
                    maxValue: match.rate.maxValue
                )
                ids[basis] = match.id
                // The operator's exact dose inside a band, kept only while the
                // band still authorises it.
                if let value = slot.value, match.isLabelRange, match.authorises(value) {
                    values[basis] = value
                }
            }
        }

        for row in source.rates {
            let basis: ChemicalDefaultRateBasis =
                row.basis == .perHectare ? .perHectare : .per100Litres
            // A confirmed choice already recovered for this basis is never
            // second-guessed by the legacy projection: a human's decision
            // outranks a number matched back to a direction by inference.
            if ids[basis] != nil { continue }
            let options = ChemicalDefaultRate.options(basis, from: grapevine)

            // Compared through the SAME base scale the legacy column was
            // written in, so a rate stored from a millilitre label still
            // matches the option it came from instead of missing it.
            let exact = options.first { option in
                guard let unit = ChemicalUnit.fromLabelRateToken(option.rate.unit),
                      let value = option.rate.proposedValue
                else { return false }
                return abs(unit.toBase(value) - row.value) < 0.000_001
            }
            if let exact {
                ids[basis] = exact.id
                continue
            }

            // A stored dose the operator picked from INSIDE a label band does
            // not equal any option's starting value, so the plain comparison
            // above misses it. Recovering it is a match against the band the
            // label authorises, never a reconstruction: a value no registered
            // rate covers any more selects nothing and the rule runs again.
            let banded = options.first { option in
                guard option.isLabelRange,
                      let unit = ChemicalUnit.fromLabelRateToken(option.rate.unit)
                else { return false }
                return option.authorises(unit.fromBase(row.value))
            }
            if let banded, let unit = ChemicalUnit.fromLabelRateToken(banded.rate.unit) {
                ids[basis] = banded.id
                values[basis] = unit.fromBase(row.value)
            }
        }
        return (ids, values)
    }

    /// Lift a legacy record's scalar rates into structured label rates.
    private static func legacyRateDrafts(from source: SavedChemical) -> [ChemicalManualRateDraft] {
        var drafts: [ChemicalManualRateDraft] = []
        let token = source.unit.labelRateToken

        if let perHa = source.rates.first(where: { $0.basis == .perHectare }) {
            drafts.append(ChemicalManualRateDraft(
                label: perHa.label,
                basis: .perHectare,
                valueText: formatRate(source.unit.fromBase(perHa.value)),
                unit: token
            ))
        } else if source.ratePerHa > 0 {
            drafts.append(ChemicalManualRateDraft(
                basis: .perHectare,
                valueText: formatRate(source.ratePerHa),
                unit: token
            ))
        }

        if let per100L = source.rates.first(where: { $0.basis == .per100Litres }) {
            drafts.append(ChemicalManualRateDraft(
                label: per100L.label,
                basis: .per100Litres,
                valueText: formatRate(source.unit.fromBase(per100L.value)),
                unit: token
            ))
        }
        return drafts
    }

    init(
        isReviewingLookup: Bool = false,
        chemistryDraft: ChemicalManualDraft = ChemicalManualDraft(),
        formType: ChemicalFormType = .liquid,
        unit: ChemicalUnit = .litres,
        modeOfAction: String = "",
        notes: String = "",
        use: String = "",
        problem: String = "",
        trackPurchase: Bool = false,
        containerSizeText: String = "",
        containerUnit: ChemicalUnit = .litres,
        costText: String = "",
        packSizeText: String = "",
        packPriceText: String = "",
        densityText: String = "",
        nitrogenText: String = "",
        phosphorusText: String = "",
        potassiumText: String = "",
        analysisBasis: FertiliserAnalysisBasis = .elemental,
        organicCertified: Bool = false,
        inventoryText: String = "",
        applicationNotes: String = "",
        seedIntelligence: ChemicalIntelligence? = nil,
        seedActiveIngredientText: String = "",
        seedChemicalGroupText: String = "",
        existingPerHaRateId: UUID? = nil,
        existingPer100LRateId: UUID? = nil,
        masterChemicalId: UUID? = nil,
        masterSourceRevision: Int? = nil,
        selectedDefaultRateIds: [ChemicalDefaultRateBasis: String] = [:],
        defaultRateValues: [ChemicalDefaultRateBasis: Double] = [:],
        jurisdiction: ChemicalRateJurisdiction? = nil,
        serverDefaultRateOptions: ChemicalServerDefaultRateOptions? = nil,
        baselineViolationCodes: Set<ChemicalSaveViolationCode> = []
    ) {
        self.serverDefaultRateOptions = serverDefaultRateOptions
        self.isReviewingLookup = isReviewingLookup
        self.baselineViolationCodes = baselineViolationCodes
        self.chemistryDraft = chemistryDraft
        self.formType = formType
        self.unit = unit
        self.modeOfAction = modeOfAction
        self.notes = notes
        self.use = use
        self.problem = problem
        self.trackPurchase = trackPurchase
        self.containerSizeText = containerSizeText
        self.containerUnit = containerUnit
        self.costText = costText
        self.packSizeText = packSizeText
        self.packPriceText = packPriceText
        self.densityText = densityText
        self.nitrogenText = nitrogenText
        self.phosphorusText = phosphorusText
        self.potassiumText = potassiumText
        self.analysisBasis = analysisBasis
        self.organicCertified = organicCertified
        self.inventoryText = inventoryText
        self.applicationNotes = applicationNotes
        self.seedIntelligence = seedIntelligence
        self.seedActiveIngredientText = seedActiveIngredientText
        self.seedChemicalGroupText = seedChemicalGroupText
        self.existingPerHaRateId = existingPerHaRateId
        self.existingPer100LRateId = existingPer100LRateId
        self.masterChemicalId = masterChemicalId
        self.masterSourceRevision = masterSourceRevision
        self.selectedDefaultRateIds = selectedDefaultRateIds
        self.defaultRateValues = defaultRateValues
        self.jurisdiction = jurisdiction
    }

    // MARK: - Re-search

    /// Replace this session's product data with a freshly reviewed lookup.
    ///
    /// Goes through the SAME `ChemicalReviewMerge` contract as the Add Chemical
    /// flow. Operational data the operator owns — price, pack, stock, notes —
    /// is untouched: re-identifying a product says nothing about what it cost.
    mutating func apply(
        reviewed: SavedChemical,
        serverDefaultRateOptions: ChemicalServerDefaultRateOptions? = nil,
        fallbackCountry: String
    ) {
        let previousIdentity = productIdentityKey
        let refreshed = ChemicalReviewSession.make(
            chemical: nil,
            prefill: reviewed,
            fallbackCountry: fallbackCountry,
            serverDefaultRateOptions: serverDefaultRateOptions
        )
        // Replaced wholesale, never merged: these identities belong to the
        // product just resolved. A re-search that came back degraded clears
        // them, which fails closed rather than carrying the old product's
        // register rates onto the new one.
        self.serverDefaultRateOptions = serverDefaultRateOptions
        // The structured draft carries name, manufacturer, category, country,
        // label link, actives, uses and rates in one assignment — there are no
        // separate copies of those to keep in step.
        chemistryDraft = refreshed.chemistryDraft
        formType = refreshed.formType
        unit = refreshed.unit
        modeOfAction = refreshed.modeOfAction.trimmedNonEmpty ?? modeOfAction
        use = refreshed.use.trimmedNonEmpty ?? use
        problem = refreshed.problem.trimmedNonEmpty ?? problem
        masterChemicalId = refreshed.masterChemicalId
        masterSourceRevision = refreshed.masterSourceRevision

        // A dose decision belongs to the product it was taken for.
        //
        // Option ids are content-addressed on basis, unit and value, so two
        // DIFFERENT products that both register `3 L/100 L` share an id. Left
        // alone, changing product would silently re-adopt the previous
        // product's default under the new label's conditions. Changing the
        // product therefore retires the decision and the recommendation rule
        // runs again from the new label.
        if productIdentityKey != previousIdentity {
            selectedDefaultRateIds = [:]
            defaultRateValues = [:]
        } else {
            // Same product, re-verified. A choice survives only while the new
            // label still states the rate it was made from, and an exact dose
            // survives only while that rate still authorises it.
            retainOnlyAuthorisedDefaults()
        }
    }

    /// What makes this session "the same product" across a re-search.
    ///
    /// Registration identity first, because that is what a register actually
    /// establishes; product name only carries the comparison for records that
    /// have no identifier yet.
    var productIdentityKey: String {
        [
            ChemicalRegistration.normaliseCountry(chemistryDraft.countryCode),
            chemistryDraft.registrationNumber
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
            chemistryDraft.productName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
        ].joined(separator: "|")
    }

    /// Drop any default selection or exact dose the current label no longer
    /// supports. Never edits the label itself.
    private mutating func retainOnlyAuthorisedDefaults() {
        let plan = defaultRatePlan
        selectedDefaultRateIds = selectedDefaultRateIds.filter { basis, id in
            plan.group(basis).options.contains { $0.id == id }
        }
        defaultRateValues = defaultRateValues.filter { basis, value in
            guard let option = resolvedDefaultOption(for: basis) else { return false }
            return option.authorises(value)
        }
    }

    // MARK: - Derived: chemistry

    /// Actives with something actually in them.
    var populatedActives: [ChemicalManualActiveDraft] {
        chemistryDraft.actives.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether the record states any registered use (a crop and/or a target).
    ///
    /// When it does, the structured uses are authoritative and the legacy
    /// `Use / Problem` boxes are not offered — two editable answers to "what is
    /// this for?" is exactly the duplication being removed.
    var hasStructuredUses: Bool { !chemistryDraft.uses.isEmpty }

    var hasAuthoredChemistry: Bool {
        !ChemicalManualEntry
            .proposedIntelligence(from: chemistryDraft, existing: seedIntelligence)
            .isEmpty
    }

    var editOutcome: ChemicalEditOutcome? {
        guard hasAuthoredChemistry else { return nil }
        let outcome = ChemicalManualEntry.outcome(for: chemistryDraft, existing: seedIntelligence)
        if let stored = seedIntelligence, stored == outcome.intelligence { return nil }
        return outcome
    }

    /// The structured chemistry Save should persist.
    ///
    /// Falls back to the seed when the operator changed nothing: `editOutcome`
    /// is nil in that case because there is nothing NEW to reconcile, and
    /// without this an entire looked-up record would save as an empty shell.
    var intelligenceToPersist: ChemicalIntelligence? {
        editOutcome?.intelligence ?? seedIntelligence
    }

    // MARK: - Derived: registration identity

    /// The wording this jurisdiction uses, or `nil` where VineTrack supports no
    /// register and the identifier must not be shown at all.
    var registrationTerms: ChemicalRegistrationTerminology.Terms? {
        ChemicalRegistrationTerminology.terms(forCountryCode: countryCode)
    }

    /// The compact read-only line: `"APVMA registration: 34540"`, or
    /// `"Registration not confirmed"`, or `nil` outside a supported country.
    var registrationCompactLine: String? {
        ChemicalRegistrationTerminology.compactLine(
            countryCode: countryCode,
            registrationNumber: chemistryDraft.registrationNumber
        )
    }

    /// Whether an identifier is actually on record.
    var hasRegistrationNumber: Bool {
        chemistryDraft.registrationNumber.trimmedNonEmpty != nil
    }

    var registrationNotConfirmed: Bool { !hasRegistrationNumber }

    /// Whether a missing registration identifier is worth raising YET.
    ///
    /// # Why this is gated rather than always shown
    ///
    /// The identifier is something VineTrack FILLS IN from a lookup — the
    /// operator is never asked for it, because the only place they can read one
    /// is the drum, under a national name the generic wording never uses.
    /// Raising "a verified product needs its registration number" on a form
    /// where no registered product has been selected reports a gap the operator
    /// has had no opportunity to close, on a screen that has not yet offered
    /// them the means to close it. It reads as a fault in what they just typed.
    ///
    /// So the notice waits until the record is actually making a registration
    /// claim: a candidate has been reviewed, an identifier is already present,
    /// or the record carries structured chemistry that a register should back.
    /// A blank manual entry stays silent until it has something to be silent
    /// about.
    var showsRegistrationIssues: Bool {
        if hasRegistrationNumber { return true }
        if isReviewingLookup { return true }
        return hasAuthoredChemistry
    }

    // MARK: - Derived: rates

    /// Every label rate on record — product-level carriers plus each use's.
    var allLabelRates: [ChemicalLabelRate] {
        proposedIntelligence.registeredUses.flatMap(\.rates)
    }

    /// The intelligence the draft currently proposes. One computation, reused.
    private var proposedIntelligence: ChemicalIntelligence {
        ChemicalManualEntry.proposedIntelligence(
            from: chemistryDraft, existing: seedIntelligence
        )
    }

    // MARK: - Derived: grapevine-first presentation (task §3)

    /// The GRAPEVINE registered uses — what the normal review view shows.
    ///
    /// A vineyard operator scrolling past peach, plum, nectarine, almond and
    /// pome fruit to reach the rate they actually need is being made to work
    /// for the app. Every one of those uses is still on the record; they are
    /// simply not the vineyard workflow.
    var grapevineUses: [ChemicalRegisteredUse] {
        proposedIntelligence.registeredUses.statedUses.viticultural
    }

    /// Every other crop on the same label. RETAINED, shown under Advanced.
    ///
    /// Never discarded: they are authoritative label content, they are what
    /// makes a re-verification comparable, and a grower checking whether a drum
    /// they already own covers something else deserves to find the answer.
    var otherCropUses: [ChemicalRegisteredUse] {
        proposedIntelligence.registeredUses.statedUses.filter { !$0.isViticultural }
    }

    /// True when the label registers this product on grapevines at all.
    var isRegisteredForGrapevine: Bool { !grapevineUses.isEmpty }

    // MARK: - Derived: the default-rate decision (task §5)

    /// The per-basis default-rate decision, built ONLY from authoritative
    /// grapevine rates.
    var defaultRatePlan: ChemicalDefaultRatePlan {
        // The SERVER's options when a structured lookup supplied them. Their
        // `option_key` and `rate_ids` are the register's, so a choice made here
        // can be persisted with an identity every other client recognises.
        if let serverDefaultRateOptions {
            return ChemicalDefaultRate.plan(
                serverOptions: serverDefaultRateOptions,
                jurisdiction: jurisdiction
            )
        }
        // The edit path, where no fresh lookup has run. These options are for
        // DISPLAY: they carry no server identity, so confirming one cannot
        // create a new stored default. An existing default is still shown and
        // carried forward — `recoveredDefaults` re-attaches the stored slot's
        // own identity, so re-saving an untouched record rewrites exactly what
        // it already had.
        return ChemicalDefaultRate.plan(grapevineUses: grapevineUses, jurisdiction: jurisdiction)
    }

    /// The default in force for a basis: the operator's choice if they made
    /// one, otherwise the recommendation, otherwise nothing.
    ///
    /// Returning `nil` is a real answer and the whole point of step 3: when
    /// several conditional rates apply and nobody has chosen, there IS no
    /// default, and manufacturing one would dose off a condition never checked.
    func resolvedDefaultOption(
        for basis: ChemicalDefaultRateBasis
    ) -> ChemicalDefaultRateOption? {
        let group = defaultRatePlan.group(basis)
        if let selectedId = selectedDefaultRateIds[basis],
           let chosen = group.options.first(where: { $0.id == selectedId }) {
            return chosen
        }
        return group.recommendedOption
    }

    /// Adopt a default rate for a basis. Never touches the registered rates.
    mutating func selectDefaultRate(
        _ option: ChemicalDefaultRateOption,
        for basis: ChemicalDefaultRateBasis
    ) {
        selectedDefaultRateIds[basis] = option.id
        // Switching to a different registered rate retires any exact dose
        // taken from the previous one: `150` chosen inside `100–200` is not a
        // dose the option beside it authorises.
        defaultRateValues[basis] = nil
    }

    /// The exact dose in force for a basis, in the RATE's own unit.
    ///
    /// The operator's figure when they named one, otherwise the bottom of the
    /// band — never the top, and never a number outside it.
    func resolvedDefaultValue(for basis: ChemicalDefaultRateBasis) -> Double? {
        guard let option = resolvedDefaultOption(for: basis) else { return nil }
        if let chosen = defaultRateValues[basis], option.authorises(chosen) {
            return chosen
        }
        return option.startingValue
    }

    /// Set this vineyard's exact dose inside the registered band.
    ///
    /// Returns `false` — and changes nothing — when the value is not one the
    /// selected registered rate authorises. The label is the authority on what
    /// may be applied; this only records which authorised number gets poured.
    /// The registered rates are NEVER edited here: `chemistryDraft` is not
    /// touched, so `100–200 g/100 L` stays `100–200 g/100 L` on the record
    /// however this vineyard chooses to dose it.
    @discardableResult
    mutating func setDefaultRateValue(
        _ value: Double,
        for basis: ChemicalDefaultRateBasis
    ) -> Bool {
        guard let option = resolvedDefaultOption(for: basis) else { return false }
        guard option.authorises(value) else { return false }
        // An option in force only by RECOMMENDATION becomes an explicit choice
        // the moment a dose is named against it, so the two cannot disagree
        // later about which registered rate the number came from.
        selectedDefaultRateIds[basis] = option.id
        defaultRateValues[basis] = value
        return true
    }

    /// Clear this vineyard's exact dose, returning to the bottom of the band.
    mutating func clearDefaultRateValue(for basis: ChemicalDefaultRateBasis) {
        defaultRateValues[basis] = nil
    }

    /// The CONFIRMED operational default, in the shape `saved_chemicals.default_rates`
    /// stores (sql/214).
    ///
    /// Returns `nil` when nothing has been confirmed on either basis, so the
    /// column is omitted from the write and a default recorded elsewhere
    /// survives untouched. Clearing a default is a separate, deliberate act —
    /// never a side effect of saving an unrelated edit.
    ///
    /// Only EXPLICIT choices are persisted. `resolvedDefaultOption` deliberately
    /// falls back to the recommendation so the UI can show one, but a
    /// recommendation nobody confirmed is not a decision and must never reach
    /// the database — that is the difference between suggesting a rate and
    /// claiming the operator chose it.
    var storedDefaultRates: StoredChemicalDefaultRates? {
        let uses = grapevineUses
        guard !uses.isEmpty else { return nil }
        let labelVersion = intelligenceToPersist?.registration?.labelVersion

        var stored = StoredChemicalDefaultRates()
        for basis in ChemicalDefaultRateBasis.allCases {
            guard let selectedId = selectedDefaultRateIds[basis] else { continue }
            let group = defaultRatePlan.group(basis)
            guard let option = group.options.first(where: { $0.id == selectedId }) else { continue }
            let slot = StoredChemicalDefaultRate.confirmed(
                option: option,
                basis: basis,
                grapevineUses: uses,
                confirmedValue: defaultRateValues[basis],
                labelVersion: labelVersion
            )
            stored = stored.withSlot(basis, slot)
        }
        return stored.isEmpty ? nil : stored
    }

    // MARK: - The first-add rate confirmation gate

    /// Whether the operator has EXPLICITLY confirmed a default on this basis.
    ///
    /// # Why "in force" is not the same as "confirmed"
    ///
    /// `resolvedDefaultOption` falls back to the recommendation so a screen has
    /// something to show. A recommendation is VineTrack's reading of the label,
    /// not the grower's decision, and a first add that saves one has recorded a
    /// dose nobody chose. So three things must all be true:
    ///
    /// ```text
    /// selected     the operator picked this option, not the badge
    /// server       the option carries the register's own identity
    /// resolved     a band additionally needs the exact dose typed inside it
    /// ```
    ///
    /// A band with no number is UNRESOLVED, not "the bottom of the band":
    /// `560–700 g/ha` names no dose, and choosing 560 on the operator's behalf
    /// is exactly the silent under-application this gate exists to stop.
    func isDefaultRateConfirmed(for basis: ChemicalDefaultRateBasis) -> Bool {
        guard let selectedId = selectedDefaultRateIds[basis] else { return false }
        let group = defaultRatePlan.group(basis)
        guard let option = group.options.first(where: { $0.id == selectedId }) else { return false }
        // A device-assembled option carries no register identity and can never
        // be persisted, so confirming one would enable a Save that then wrote
        // no default at all.
        guard let server = option.server, server.isValid, server.decisionBasis == basis else {
            return false
        }
        if option.isLabelRange {
            guard let value = defaultRateValues[basis] else { return false }
            return option.authorises(value)
        }
        return option.startingValue != nil
    }

    /// True once at least one basis carries a confirmed, persistable default.
    var hasConfirmedDefaultRate: Bool {
        ChemicalDefaultRateBasis.allCases.contains { isDefaultRateConfirmed(for: $0) }
    }

    /// True when THIS save must not proceed without a confirmed default rate.
    ///
    /// Scoped deliberately to a first add from the register: a looked-up
    /// product with grapevine uses is exactly the case where the label states
    /// the rate, the operator is looking at it, and letting them save without
    /// answering produces a chemical whose spray calculations start from a
    /// number nobody chose.
    ///
    /// Everything else is exempt, for reasons that are not softness:
    ///
    /// ```text
    /// manual entry      never went near the register; there is nothing
    ///                   canonical to confirm and no server option to offer
    /// existing record   already saved. Blocking a price or note edit behind a
    ///                   rate question would strand the record unrepairable
    /// no grapevine use  nothing to dose by; the label says so plainly
    /// ```
    var requiresDefaultRateConfirmation: Bool {
        isReviewingLookup && isRegisteredForGrapevine
    }

    /// True when the gate is currently blocking Save.
    var isAwaitingDefaultRateConfirmation: Bool {
        requiresDefaultRateConfirmation && !hasConfirmedDefaultRate
    }

    /// Bases the operator still has to answer before a default exists.
    var basesAwaitingDefaultChoice: [ChemicalDefaultRateBasis] {
        ChemicalDefaultRateBasis.allCases.filter { basis in
            defaultRatePlan.group(basis).requiresChoice
                && selectedDefaultRateIds[basis] == nil
        }
    }

    /// The per-hectare rate as display text, or `nil` when the label states
    /// none.
    ///
    /// Never `"0"`. Zero is a legitimate number that would read as "the label
    /// says apply nothing", and the old form printed it for every product whose
    /// rate had not been copied into the legacy column.
    var perHectareRateDisplay: String? {
        rateDisplay(matching: \.isAreaBased)
    }

    var per100LitreRateDisplay: String? {
        rateDisplay(matching: \.isVolumeBased)
    }

    private func rateDisplay(matching predicate: (ChemicalLabelRateBasis) -> Bool) -> String? {
        // The operator's chosen (or recommended) grapevine default leads, so
        // the legacy scalar the Spray Tool reads is the rate they actually
        // decided on rather than whichever registered row happened to be
        // parsed first.
        let basis: ChemicalDefaultRateBasis = predicate(.perHectare) ? .perHectare : .per100Litres
        if let option = resolvedDefaultOption(for: basis),
           let value = ChemicalReviewSession.displayValue(
               option.rate,
               productUnit: unit,
               overrideValue: resolvedDefaultValue(for: basis)
           ),
           let text = formatRate(value).trimmedNonEmpty {
            return text
        }
        // Fallback for records with no grapevine use at all — a legacy or
        // manually entered product still projects its rate exactly as before.
        for rate in allLabelRates where predicate(rate.basis) {
            guard let value = ChemicalReviewSession.displayValue(rate, productUnit: unit) else { continue }
            return formatRate(value).trimmedNonEmpty
        }
        return nil
    }

    /// Convert a label rate into the product's own display unit.
    ///
    /// Returns `nil` rather than guessing when the two are different states of
    /// matter: litres and kilograms share a base scale here, so a blind
    /// conversion would silently restate `2.5 L/ha` as `2.5 kg/ha`.
    /// - Parameter overrideValue: the vineyard's own dose, in the RATE's unit.
    ///   Supplied only after `setDefaultRateValue` proved the label authorises
    ///   it, so this can never smuggle an off-label number into the projection.
    static func displayValue(
        _ rate: ChemicalLabelRate,
        productUnit: ChemicalUnit,
        overrideValue: Double? = nil
    ) -> Double? {
        guard let rateUnit = ChemicalUnit.fromLabelRateToken(rate.unit) else { return nil }
        guard ChemicalFormType.from(unit: rateUnit) == ChemicalFormType.from(unit: productUnit) else {
            return nil
        }
        // A range projects at its LOWER bound: handing a calculation the top of
        // the band would over-apply by default.
        guard let value = overrideValue ?? rate.value ?? rate.minValue else { return nil }
        return productUnit.fromBase(rateUnit.toBase(value))
    }

    // MARK: - Legacy compatibility projection

    /// The legacy scalar values this session should write, DERIVED from the
    /// structured record.
    ///
    /// One direction only. A stale legacy scalar can never travel back into the
    /// structured chemistry, because nothing on this screen edits one.
    nonisolated struct LegacyProjection: Sendable, Hashable {
        var rates: [ChemicalRate]
        /// Display-unit per-hectare rate. `0` means "no rate on record" — the
        /// storage default, never rendered as a rate in the UI.
        var ratePerHa: Double
        var activeIngredient: String
        var chemicalGroup: String
        var use: String
        var problem: String
        var labelURL: String
        var manufacturer: String
    }

    func legacyProjection() -> LegacyProjection {
        let structured = intelligenceToPersist
        let perHa = perHectareRateDisplay.flatMap(Double.init)
        let per100L = per100LitreRateDisplay.flatMap(Double.init)

        var rates: [ChemicalRate] = []
        if let perHa, perHa > 0 {
            rates.append(ChemicalRate(
                id: existingPerHaRateId ?? UUID(),
                // The label's own CONDITION for the chosen default, so the
                // stored operational rate says which registered condition it
                // came from instead of a generic "Per Ha".
                label: defaultRateLabel(for: .perHectare, fallback: "Per Ha"),
                value: unit.toBase(perHa),
                basis: .perHectare
            ))
        }
        if let per100L, per100L > 0 {
            rates.append(ChemicalRate(
                id: existingPer100LRateId ?? UUID(),
                label: defaultRateLabel(for: .per100Litres, fallback: "Per 100L"),
                value: unit.toBase(per100L),
                basis: .per100Litres
            ))
        }

        // The scalars stay a faithful mirror where structure exists, and the
        // record's original text survives untouched where it does not — saving
        // a note on a never-structured chemical must not blank its chemistry.
        let projectedActive = structured?.legacyActiveIngredient ?? ""
        let projectedGroup = structured?.legacyChemicalGroup ?? ""

        let statedUses = chemistryDraft.uses
        let projectedProblem = statedUses
            .compactMap { $0.targetRaw.trimmedNonEmpty }
            .first
        let projectedUse = statedUses.isEmpty
            ? use
            : (productCategory?.label ?? use)

        return LegacyProjection(
            rates: rates,
            ratePerHa: perHa ?? 0,
            activeIngredient: projectedActive.isEmpty ? seedActiveIngredientText : projectedActive,
            chemicalGroup: projectedGroup.isEmpty ? seedChemicalGroupText : projectedGroup,
            use: projectedUse,
            problem: projectedProblem ?? problem,
            // The structured registration reference IS the label link.
            labelURL: labelURL,
            manufacturer: manufacturer
        )
    }

    /// The condition wording to store beside a projected default rate.
    private func defaultRateLabel(
        for basis: ChemicalDefaultRateBasis,
        fallback: String
    ) -> String {
        guard let option = resolvedDefaultOption(for: basis) else { return fallback }
        let condition = ChemicalDefaultRate.conditionText(for: option.rate)
        return condition.isEmpty ? fallback : condition
    }

    // MARK: - Save contract (task §11)

    /// The record as it stands, measured against the shared mandatory
    /// contract.
    ///
    /// The contract itself lives in `ChemicalSaveContract`, mirroring the edge
    /// function's `save_contract.ts` so iOS and the Portal cannot disagree
    /// about what "ready to use" means.
    var saveEvaluation: ChemicalSaveEvaluation {
        ChemicalSaveContract.evaluate(
            productName: name,
            productCategory: chemistryDraft.productCategory,
            intelligence: proposedIntelligence,
            intent: .sprayReady
        )
    }

    /// Violations that must be fixed before THIS save.
    ///
    /// Pre-existing faults are excluded — see `baselineViolationCodes`. What
    /// remains is everything this edit would ADD, plus everything a brand-new
    /// record is missing.
    var blockingViolations: [ChemicalSaveViolation] {
        saveEvaluation.violations.filter { !baselineViolationCodes.contains($0.code) }
    }

    /// Faults the record arrived with. Shown as guidance, never as a block, so
    /// a legacy product can be repaired incrementally.
    var carriedOverViolations: [ChemicalSaveViolation] {
        saveEvaluation.violations.filter { baselineViolationCodes.contains($0.code) }
    }

    /// True when a calculation must ask which conditional rate applies before
    /// using this product (task §5).
    ///
    /// Never blocks Save: the label genuinely states those rates, and only the
    /// operator can say which condition they are spraying under today.
    var requiresRateConditionChoice: Bool {
        saveEvaluation.requiresRateConditionChoice
    }

    /// The resistance state this record will persist.
    var resistanceState: ChemicalResistanceState { saveEvaluation.resistanceState }

    /// The ONE rule the Save button asks.
    ///
    /// The rate-confirmation gate lives HERE rather than in the view, so there
    /// can be no second, view-only opinion about whether this record may be
    /// saved — a screen that disabled Save on its own would leave every other
    /// caller of `isValid` writing the record the gate refused.
    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard blockingViolations.isEmpty else { return false }
        return !isAwaitingDefaultRateConfirmation
    }

    // MARK: - Formatting

    static func formatRate(_ value: Double) -> String {
        if value == 0 { return "" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    func formatRate(_ value: Double) -> String { ChemicalReviewSession.formatRate(value) }
}

extension String {
    /// The string, or `nil` when it is blank.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ProductCategory {
    /// Read a category out of whatever the lookup, the register or an older
    /// record called it.
    ///
    /// The stored representation is the raw key, but a lookup answers in
    /// English ("Fungicide") and registers vary ("fungicides"). Matching only
    /// the exact raw value is why a product the resolver plainly categorised
    /// still showed as Uncategorised.
    static func parse(_ raw: String) -> ProductCategory? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }

        let collapsed = cleaned.filter { $0.isLetter || $0.isNumber }
        for option in ProductCategory.allCases {
            let key = option.rawValue.lowercased().filter { $0.isLetter || $0.isNumber }
            let label = option.label.lowercased().filter { $0.isLetter || $0.isNumber }
            if collapsed == key || collapsed == label { return option }
            // "fungicides" -> fungicide. A trailing plural only: nothing here
            // may turn one category into a different one.
            if collapsed == key + "s" || collapsed == label + "s" { return option }
        }
        return nil
    }
}
