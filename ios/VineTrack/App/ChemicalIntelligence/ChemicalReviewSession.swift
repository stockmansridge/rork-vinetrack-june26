import Foundation

/// Whether the product is measured as a liquid or a solid.
///
/// Lives here rather than inside the editor view because the review session is
/// seeded and tested without a view, and the form/unit pairing is part of the
/// product record rather than part of the screen.
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

/// Everything the Chemical Store editor holds for one editing session.
///
/// # Why this exists
///
/// The editor used to keep this as ~25 independent `@State` properties, each
/// seeded in `init` from the record being edited. That made the form's contents
/// a function of how often SwiftUI decided to rebuild the view rather than a
/// function of what the operator had done: a redraw, a sheet closing, a scene
/// change or a screenshot could re-run seeding, and a populated Review Chemical
/// form could quietly empty itself while the operator was reading it.
///
/// Collapsing the whole form into ONE value gives the session a single owner
/// and a single lifetime. The editor holds exactly one `@State` and seeds it
/// exactly once, at `make(...)`; from that moment nothing but the operator
/// changes it, and Cancel discards it whole.
///
/// It is a plain value type with no view dependencies, so "does a lookup
/// populate every field it found?" is answerable in a test instead of on a
/// device.
nonisolated struct ChemicalReviewSession: Sendable, Hashable {

    // MARK: Identity & product

    var name: String
    var manufacturer: String
    var productCategory: ProductCategory?
    var formType: ChemicalFormType
    var unit: ChemicalUnit

    // MARK: Structured chemistry (sql/194) — the source of truth

    /// Actives, concentrations, groups, registration identity, registered uses,
    /// rates, WHP, re-entry and restrictions, as structure.
    var chemistryDraft: ChemicalManualDraft

    // MARK: Legacy display projections

    /// Compatibility mirrors of the structured chemistry above. Never a source
    /// of truth, never a calculation input — kept so older clients and the
    /// existing API keep rendering something familiar.
    var activeIngredient: String
    var chemicalGroup: String
    var modeOfAction: String

    // MARK: Details

    var use: String
    var problem: String
    var notes: String
    var labelURL: String
    var productURL: String

    // MARK: Rates

    var ratePerHaText: String
    var ratePer100LText: String
    let existingPerHaRateId: UUID?
    let existingPer100LRateId: UUID?

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

    // MARK: Provenance carried through the session

    /// The structured chemistry this session OPENED with.
    ///
    /// Reconciliation needs it: without it every prefilled value would look
    /// freshly hand-typed, and a register-confirmed product would save with its
    /// authoritative citations withdrawn simply because the operator pressed
    /// Save without editing anything.
    let seedIntelligence: ChemicalIntelligence?

    /// Set only when the product came from an APPROVED master catalogue row.
    /// `nil` is valid forever — it means nobody claimed a master reference.
    var masterChemicalId: UUID?
    var masterSourceRevision: Int?

    /// True when this session is reviewing a looked-up product rather than
    /// editing something already on file.
    let isReviewingLookup: Bool

    // MARK: - Seeding

    /// Build the session ONCE.
    ///
    /// - Parameters:
    ///   - chemical: the stored record being edited, or `nil` when creating.
    ///   - prefill: a populated but unsaved draft from a lookup — the Review
    ///     Chemical case. Displayed identically to a stored record; only what
    ///     Save does differs.
    ///   - fallbackCountry: the vineyard's country, used only when the record
    ///     does not already name one. An imported product's own country must
    ///     never be overwritten just because it was opened.
    static func make(
        chemical: SavedChemical?,
        prefill: SavedChemical?,
        fallbackCountry: String
    ) -> ChemicalReviewSession {
        guard let source = chemical ?? prefill else {
            return ChemicalReviewSession(
                blankWithCountry: fallbackCountry,
                isReviewingLookup: false
            )
        }

        var chemistry = ChemicalManualEntry.draft(from: source, fallbackCountry: fallbackCountry)
        // Applied here, once, rather than in an `onAppear` that can fire again
        // on every re-appearance of the sheet.
        if chemistry.countryCode.isEmpty {
            chemistry.countryCode = ChemicalRegistration.normaliseCountry(fallbackCountry)
        }

        let stored = source.chemicalIntelligence.flatMap { $0.isEmpty ? nil : $0 }
        let perHa = source.rates.first { $0.basis == .perHectare }
        let per100L = source.rates.first { $0.basis == .per100Litres }

        // The product's own statement of its form outranks whatever unit a rate
        // happens to be quoted in.
        let formType = ChemicalFormType.stated(source.productForm)
            ?? ChemicalFormType.from(unit: source.unit)

        var perHaText = ""
        if let perHa {
            perHaText = formatRate(source.unit.fromBase(perHa.value))
        } else if source.ratePerHa > 0 {
            perHaText = formatRate(source.ratePerHa)
        }

        return ChemicalReviewSession(
            isReviewingLookup: chemical == nil && prefill != nil,
            name: source.name,
            manufacturer: source.manufacturer,
            // Parsed rather than raw-value-matched, so a lookup that answers
            // "Fungicide" or "fungicides" still lands on Fungicide instead of
            // silently falling through to Uncategorised.
            productCategory: ProductCategory.parse(
                chemistry.productCategory.isEmpty ? source.productCategory : chemistry.productCategory
            ),
            formType: formType,
            unit: source.unit,
            chemistryDraft: chemistry,
            // Derived from structure whenever structure exists; the record's own
            // text only survives on a record that has never been structured.
            activeIngredient: stored?.legacyActiveIngredient.trimmedNonEmpty ?? source.activeIngredient,
            chemicalGroup: stored?.legacyChemicalGroup.trimmedNonEmpty ?? source.chemicalGroup,
            modeOfAction: source.modeOfAction,
            use: source.use,
            problem: source.problem,
            notes: source.notes,
            labelURL: source.labelURL,
            productURL: source.productURL,
            ratePerHaText: perHaText,
            ratePer100LText: per100L.map { formatRate(source.unit.fromBase($0.value)) } ?? "",
            existingPerHaRateId: perHa?.id,
            existingPer100LRateId: per100L?.id,
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
            masterChemicalId: source.masterChemicalId,
            masterSourceRevision: source.masterSourceRevision
        )
    }

    /// An empty session for hand-entering a product from nothing.
    private init(blankWithCountry country: String, isReviewingLookup: Bool) {
        self.init(
            isReviewingLookup: isReviewingLookup,
            chemistryDraft: ChemicalManualEntry.draft(from: nil, fallbackCountry: country)
        )
    }

    /// Explicit rather than synthesised, so the blank case above can delegate
    /// to it and every field has one stated default.
    init(
        isReviewingLookup: Bool = false,
        name: String = "",
        manufacturer: String = "",
        productCategory: ProductCategory? = nil,
        formType: ChemicalFormType = .liquid,
        unit: ChemicalUnit = .litres,
        chemistryDraft: ChemicalManualDraft = ChemicalManualDraft(),
        activeIngredient: String = "",
        chemicalGroup: String = "",
        modeOfAction: String = "",
        use: String = "",
        problem: String = "",
        notes: String = "",
        labelURL: String = "",
        productURL: String = "",
        ratePerHaText: String = "",
        ratePer100LText: String = "",
        existingPerHaRateId: UUID? = nil,
        existingPer100LRateId: UUID? = nil,
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
        masterChemicalId: UUID? = nil,
        masterSourceRevision: Int? = nil
    ) {
        self.isReviewingLookup = isReviewingLookup
        self.name = name
        self.manufacturer = manufacturer
        self.productCategory = productCategory
        self.formType = formType
        self.unit = unit
        self.chemistryDraft = chemistryDraft
        self.activeIngredient = activeIngredient
        self.chemicalGroup = chemicalGroup
        self.modeOfAction = modeOfAction
        self.use = use
        self.problem = problem
        self.notes = notes
        self.labelURL = labelURL
        self.productURL = productURL
        self.ratePerHaText = ratePerHaText
        self.ratePer100LText = ratePer100LText
        self.existingPerHaRateId = existingPerHaRateId
        self.existingPer100LRateId = existingPer100LRateId
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
        self.masterChemicalId = masterChemicalId
        self.masterSourceRevision = masterSourceRevision
    }

    // MARK: - Re-search

    /// Replace this session's product data with a freshly reviewed lookup.
    ///
    /// Used by "Search the register again" inside the editor. It goes through
    /// the SAME `ChemicalReviewMerge` contract as the Add Chemical flow — there
    /// is one lookup→merge→review implementation, and this is a caller of it,
    /// not a second copy of it.
    ///
    /// Operational data the operator owns — price, pack, stock, supplier, notes
    /// — is deliberately untouched: re-identifying a product says nothing about
    /// what it cost or how much is in the shed.
    mutating func apply(reviewed: SavedChemical, fallbackCountry: String) {
        let refreshed = ChemicalReviewSession.make(
            chemical: nil,
            prefill: reviewed,
            fallbackCountry: fallbackCountry
        )
        name = refreshed.name
        manufacturer = refreshed.manufacturer
        productCategory = refreshed.productCategory ?? productCategory
        formType = refreshed.formType
        unit = refreshed.unit
        chemistryDraft = refreshed.chemistryDraft
        activeIngredient = refreshed.activeIngredient
        chemicalGroup = refreshed.chemicalGroup
        modeOfAction = refreshed.modeOfAction.trimmedNonEmpty ?? modeOfAction
        use = refreshed.use.trimmedNonEmpty ?? use
        problem = refreshed.problem.trimmedNonEmpty ?? problem
        labelURL = refreshed.labelURL.trimmedNonEmpty ?? labelURL
        productURL = refreshed.productURL.trimmedNonEmpty ?? productURL
        if let perHa = refreshed.ratePerHaText.trimmedNonEmpty { ratePerHaText = perHa }
        if let per100L = refreshed.ratePer100LText.trimmedNonEmpty { ratePer100LText = per100L }
        masterChemicalId = refreshed.masterChemicalId
        masterSourceRevision = refreshed.masterSourceRevision
    }

    // MARK: - Derived

    /// Actives with something actually in them, for display.
    var populatedActives: [ChemicalManualActiveDraft] {
        chemistryDraft.actives.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether the operator has authored any structured chemistry.
    ///
    /// A record whose chemistry was never populated has nothing structured to
    /// write, so editing a price on a legacy chemical must not materialise its
    /// free-text seed as its first structured write.
    var hasAuthoredChemistry: Bool {
        !ChemicalManualEntry
            .proposedIntelligence(from: chemistryDraft, existing: seedIntelligence)
            .isEmpty
    }

    /// Re-resolved verification for the chemistry in this session, or `nil`
    /// when nothing structured changed.
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
    /// without this fallback an entire looked-up record would save as an empty
    /// shell — the original data-loss bug in a new place.
    var intelligenceToPersist: ChemicalIntelligence? {
        editOutcome?.intelligence ?? seedIntelligence
    }

    /// A reviewed lookup whose registration number could not be established.
    ///
    /// Only meaningful while reviewing: a hand-entered product has no
    /// registration because nobody looked one up, which is not news.
    var registrationNotConfirmed: Bool {
        guard isReviewingLookup else { return false }
        return chemistryDraft.registrationNumber
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
}

extension String {
    /// The string, or `nil` when it is blank. Lets a merge express "keep what
    /// we had" without a scatter of `isEmpty` checks.
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
    /// English ("Fungicide") and registers vary ("fungicides", "growth
    /// regulator"). Matching only the exact raw value is why a product the
    /// resolver plainly categorised was still showing as Uncategorised.
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
            // "fungicides" -> fungicide. Only ever a trailing plural: nothing
            // here may turn one category into a different one.
            if collapsed == key + "s" || collapsed == label + "s" { return option }
        }
        return nil
    }
}
