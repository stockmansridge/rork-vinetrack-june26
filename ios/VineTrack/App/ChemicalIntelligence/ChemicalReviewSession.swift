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
    /// Marketing/manufacturer page. Deliberately separate from the label link:
    /// a product page is not an approved label and must never be shown as one.
    var productURL: String
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

    /// True when reviewing a looked-up product rather than editing something
    /// already on file.
    let isReviewingLookup: Bool

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

    /// The official label link. ONE editable value: whatever the lookup found
    /// in `registration.labelReference` IS what the operator sees.
    var labelURL: String {
        get { chemistryDraft.labelReference }
        set { chemistryDraft.labelReference = newValue }
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
    static func make(
        chemical: SavedChemical?,
        prefill: SavedChemical?,
        fallbackCountry: String
    ) -> ChemicalReviewSession {
        guard let source = prefill ?? chemical else {
            return ChemicalReviewSession(
                chemistryDraft: ChemicalManualEntry.draft(from: nil, fallbackCountry: fallbackCountry)
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

        return ChemicalReviewSession(
            isReviewingLookup: chemical == nil && prefill != nil,
            chemistryDraft: chemistry,
            // The product's own statement of its form outranks whatever unit a
            // rate happens to be quoted in.
            formType: ChemicalFormType.stated(source.productForm)
                ?? ChemicalFormType.from(unit: source.unit),
            unit: source.unit,
            productURL: source.productURL,
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
            masterSourceRevision: source.masterSourceRevision
        )
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
        productURL: String = "",
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
        masterSourceRevision: Int? = nil
    ) {
        self.isReviewingLookup = isReviewingLookup
        self.chemistryDraft = chemistryDraft
        self.formType = formType
        self.unit = unit
        self.productURL = productURL
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
    }

    // MARK: - Re-search

    /// Replace this session's product data with a freshly reviewed lookup.
    ///
    /// Goes through the SAME `ChemicalReviewMerge` contract as the Add Chemical
    /// flow. Operational data the operator owns — price, pack, stock, notes —
    /// is untouched: re-identifying a product says nothing about what it cost.
    mutating func apply(reviewed: SavedChemical, fallbackCountry: String) {
        let refreshed = ChemicalReviewSession.make(
            chemical: nil,
            prefill: reviewed,
            fallbackCountry: fallbackCountry
        )
        // The structured draft carries name, manufacturer, category, country,
        // label link, actives, uses and rates in one assignment — there are no
        // separate copies of those to keep in step.
        chemistryDraft = refreshed.chemistryDraft
        formType = refreshed.formType
        unit = refreshed.unit
        modeOfAction = refreshed.modeOfAction.trimmedNonEmpty ?? modeOfAction
        productURL = refreshed.productURL.trimmedNonEmpty ?? productURL
        use = refreshed.use.trimmedNonEmpty ?? use
        problem = refreshed.problem.trimmedNonEmpty ?? problem
        masterChemicalId = refreshed.masterChemicalId
        masterSourceRevision = refreshed.masterSourceRevision
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

    // MARK: - Derived: rates

    /// Every label rate on record — product-level carriers plus each use's.
    var allLabelRates: [ChemicalLabelRate] {
        let intel = ChemicalManualEntry.proposedIntelligence(
            from: chemistryDraft, existing: seedIntelligence
        )
        return intel.registeredUses.flatMap(\.rates)
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
    static func displayValue(
        _ rate: ChemicalLabelRate,
        productUnit: ChemicalUnit
    ) -> Double? {
        guard let rateUnit = ChemicalUnit.fromLabelRateToken(rate.unit) else { return nil }
        guard ChemicalFormType.from(unit: rateUnit) == ChemicalFormType.from(unit: productUnit) else {
            return nil
        }
        // A range projects at its LOWER bound: handing a calculation the top of
        // the band would over-apply by default.
        guard let value = rate.value ?? rate.minValue else { return nil }
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
                label: "Per Ha",
                value: unit.toBase(perHa),
                basis: .perHectare
            ))
        }
        if let per100L, per100L > 0 {
            rates.append(ChemicalRate(
                id: existingPer100LRateId ?? UUID(),
                label: "Per 100L",
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

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
