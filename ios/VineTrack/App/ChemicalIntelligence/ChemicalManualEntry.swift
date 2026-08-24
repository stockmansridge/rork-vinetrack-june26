import Foundation

/// One active ingredient as the operator is typing it.
///
/// Text rather than parsed numbers, because a half-typed `"20"` on the way to
/// `"200"` must not momentarily become a stored concentration. Parsing happens
/// once, in `ChemicalManualEntry`, when the draft is turned into structured
/// intelligence.
nonisolated struct ChemicalManualActiveDraft: Sendable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var concentrationText: String
    var concentrationUnit: ChemicalConcentrationUnit?
    /// `nil` means the operator has not said which classification system
    /// applies. That is a real state — "I don't know" — and is not the same as
    /// `.notApplicable`, which asserts the product HAS no resistance group.
    var scheme: ChemicalActivityGroupScheme?
    var groupCode: String

    init(
        id: UUID = UUID(),
        name: String = "",
        concentrationText: String = "",
        concentrationUnit: ChemicalConcentrationUnit? = nil,
        scheme: ChemicalActivityGroupScheme? = nil,
        groupCode: String = ""
    ) {
        self.id = id
        self.name = name
        self.concentrationText = concentrationText
        self.concentrationUnit = concentrationUnit
        self.scheme = scheme
        self.groupCode = groupCode
    }
}

/// One label rate as the operator is typing it.
nonisolated struct ChemicalManualRateDraft: Sendable, Hashable, Identifiable {
    let id: UUID
    /// What the label calls this rate, e.g. `"High disease pressure"`.
    var label: String
    var basis: ChemicalLabelRateBasis
    /// Used by the single-value bases.
    var valueText: String
    /// Used by the range bases.
    var minText: String
    var maxText: String
    /// The product unit the rate is quoted in: `"L"`, `"mL"`, `"kg"`, `"g"`.
    var unit: String
    /// Verbatim label wording, for a basis VineTrack has no shape for.
    var rawText: String

    init(
        id: UUID = UUID(),
        label: String = "",
        basis: ChemicalLabelRateBasis = .perHectare,
        valueText: String = "",
        minText: String = "",
        maxText: String = "",
        unit: String = "L",
        rawText: String = ""
    ) {
        self.id = id
        self.label = label
        self.basis = basis
        self.valueText = valueText
        self.minText = minText
        self.maxText = maxText
        self.unit = unit
        self.rawText = rawText
    }
}

/// One registered use as the operator is typing it.
nonisolated struct ChemicalManualUseDraft: Sendable, Hashable, Identifiable {
    let id: UUID
    var crop: String
    /// The target as the label words it. Free text on purpose: VineTrack's six
    /// spray targets assist entry, they do not bound what a label may register.
    var targetRaw: String
    var rates: [ChemicalManualRateDraft]
    var withholdingPeriodDaysText: String
    var reEntryPeriodHoursText: String
    var restrictions: String

    init(
        id: UUID = UUID(),
        crop: String = "Grapes",
        targetRaw: String = "",
        rates: [ChemicalManualRateDraft] = [],
        withholdingPeriodDaysText: String = "",
        reEntryPeriodHoursText: String = "",
        restrictions: String = ""
    ) {
        self.id = id
        self.crop = crop
        self.targetRaw = targetRaw
        self.rates = rates
        self.withholdingPeriodDaysText = withholdingPeriodDaysText
        self.reEntryPeriodHoursText = reEntryPeriodHoursText
        self.restrictions = restrictions
    }

    /// Whether this use concerns grapevines.
    ///
    /// An approved label may register forty crops — peaches, tobacco, turf,
    /// bananas — and every one of them is kept. This only decides what a
    /// vineyard operator is shown FIRST; nothing is filtered away or dropped.
    var isViticultural: Bool {
        let c = crop.lowercased()
        return c.contains("grape") || c.contains("vine")
    }
}

/// Everything the structured manual editor collects, before it becomes a
/// `ChemicalIntelligence`.
///
/// Deliberately a plain value type with no behaviour: the rules live in
/// `ChemicalManualEntry` so they can be tested without a view.
nonisolated struct ChemicalManualDraft: Sendable, Hashable {
    var productName: String
    /// ISO country code the product is registered/stocked in. Defaults from the
    /// vineyard, but editable — a vineyard may stock an imported product.
    var countryCode: String
    /// Product category key from the existing `ProductCategory` vocabulary.
    var productCategory: String
    var registrant: String
    var registrationScheme: ChemicalRegistrationScheme?
    var registrationNumber: String
    /// The official label URL/document reference.
    ///
    /// Held here rather than separately on `SavedChemical.labelURL`, because
    /// two independently editable label links is one too many: the structured
    /// registration held the URL a lookup found while the outer field sat
    /// blank, and the operator saw an app that had lost their label.
    var labelReference: String
    var actives: [ChemicalManualActiveDraft]
    /// Label rates that apply to the product generally, rather than to one
    /// specific registered use.
    var productRates: [ChemicalManualRateDraft]
    var uses: [ChemicalManualUseDraft]

    init(
        productName: String = "",
        countryCode: String = "",
        productCategory: String = "",
        registrant: String = "",
        registrationScheme: ChemicalRegistrationScheme? = nil,
        registrationNumber: String = "",
        labelReference: String = "",
        actives: [ChemicalManualActiveDraft] = [],
        productRates: [ChemicalManualRateDraft] = [],
        uses: [ChemicalManualUseDraft] = []
    ) {
        self.productName = productName
        self.countryCode = countryCode
        self.productCategory = productCategory
        self.registrant = registrant
        self.registrationScheme = registrationScheme
        self.registrationNumber = registrationNumber
        self.labelReference = labelReference
        self.actives = actives
        self.productRates = productRates
        self.uses = uses
    }
}

/// Turns structured manual entry into `ChemicalIntelligence`, and back again for
/// editing.
///
/// This is the replacement for the legacy scalar chemistry boxes. The operator
/// no longer types `"Tebuconazole 200 g/L + Azoxystrobin 120 g/L"` into one
/// field and `"3 + 11"` into another — they add two actives, each with its own
/// concentration and its own resistance group, and the structured record holds
/// two independent active→group relationships. `"3 + 11"` survives only as a
/// derived legacy projection for old clients.
///
/// Three rules are enforced here and nowhere else:
///
/// 1. **Manual entry is manual evidence.** Every active is stored with
///    `.manualEntry` provenance, so `hasAuthoritativeGroup` is false and no
///    amount of completeness can reach Verified.
/// 2. **Trust is computed.** The draft is put through
///    `ChemicalEditReconciler.reconcile`, which cross-checks each active against
///    `AuthoritativeActivityGroups` and lets `resolvedStatus` reach its own
///    conclusion. There is no manual status to set.
/// 3. **Operational data is untouched.** Price, pack, stock, supplier and notes
///    never enter this file, so rebuilding the chemistry cannot disturb them.
///
/// Mirrors `ChemicalManualEntry.kt` on Android decision for decision.
nonisolated enum ChemicalManualEntry {

    /// A `ChemicalRegisteredUse` carrying product-level label rates rather than
    /// a registered crop+target claim.
    ///
    /// The model attaches rates to uses, but an operator reading a label often
    /// knows the rate before they know which of the registered uses it belongs
    /// to. Rather than invent a crop and a target — which would tell the future
    /// Resistance Engine the product is registered against a disease nobody
    /// stated — the rates are held on a use with NO crop and NO target. It
    /// contributes to `labelRateBases` (which is rate information) and is
    /// excluded from `viticultural`/`viticulturalTargets` (which are use claims).
    static func isProductRateCarrier(_ use: ChemicalRegisteredUse) -> Bool {
        use.crop.isEmpty && use.targetRaw.isEmpty
    }

    // MARK: - Draft → structured

    /// Build the intelligence the draft PROPOSES, without reconciling it.
    ///
    /// Use `outcome(for:existing:at:)` to store a draft. This function exists so
    /// the proposal can be inspected and diffed separately from the trust
    /// decision made about it.
    static func proposedIntelligence(
        from draft: ChemicalManualDraft,
        existing: ChemicalIntelligence?
    ) -> ChemicalIntelligence {
        let country = ChemicalRegistration.normaliseCountry(draft.countryCode)
        let registrant = draft.registrant.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = draft.registrationNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let productName = draft.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelReference = draft.labelReference.trimmingCharacters(in: .whitespacesAndNewlines)

        // A registration is only built when the operator actually stated
        // something about identity. An empty block stays nil rather than being
        // materialised as an empty shell that later looks like a failed lookup.
        var registration: ChemicalRegistration?
        _ = productName
        if !country.isEmpty || !registrant.isEmpty || !number.isEmpty || !labelReference.isEmpty {
            registration = ChemicalRegistration(
                countryCode: country,
                scheme: draft.registrationScheme,
                registrationNumber: number.isEmpty ? nil : number,
                registrant: registrant.isEmpty ? nil : registrant,
                // The registered product name is the REGISTER's name for the
                // product. Only a lookup can establish that, so a manually
                // typed display name is never promoted into it.
                registeredProductName: existing?.registration?.registeredProductName,
                // The ONE label link, edited in one place on the Review screen.
                labelReference: labelReference.isEmpty ? nil : labelReference,
                labelVersion: existing?.registration?.labelVersion
            )
        }

        var uses = draft.productRates.isEmpty
            ? []
            : [ChemicalRegisteredUse(
                crop: "",
                targetRaw: "",
                rates: labelRates(from: draft.productRates)
            )]
        uses.append(contentsOf: draft.uses.compactMap(registeredUse))

        return ChemicalIntelligence(
            activeIngredients: draft.actives.compactMap(activeIngredient),
            registration: registration,
            // The claim carried in is the record's own; `reconcile` decides what
            // it becomes. A brand-new manual product starts from `.manual()`,
            // whose single cited source is the operator's own entry.
            verification: existing?.verification ?? .manual(),
            registeredUses: uses,
            productCategory: draft.productCategory.trimmingCharacters(in: .whitespacesAndNewlines),
            activityGroupTableVersion: AuthoritativeActivityGroups.tableVersion,
            schemaVersion: ChemicalIntelligence.currentSchemaVersion
        )
    }

    /// Reconcile a manual draft against what the record already held.
    ///
    /// Everything that makes manual entry safe happens inside
    /// `ChemicalEditReconciler.reconcile` with `.manualEntry` as the source:
    /// authoritative citations for values the operator changed are withdrawn,
    /// each active's group is cross-checked against the reference table, and the
    /// status is re-derived. A hand-typed FRAC 3 on Azoxystrobin therefore
    /// surfaces as a conflict instead of being quietly accepted, and the
    /// operator's own value is still what gets stored.
    static func outcome(
        for draft: ChemicalManualDraft,
        existing: ChemicalIntelligence?,
        at editedAt: Date? = nil
    ) -> ChemicalEditOutcome {
        // A record with no structured data yet has nothing to reconcile
        // against. Passing its legacy SEED as `existing` would make the seed
        // look like established prior evidence, so nil is passed instead.
        let prior = (existing?.isEmpty ?? true) ? nil : existing
        return ChemicalEditReconciler.reconcile(
            existing: prior,
            proposed: proposedIntelligence(from: draft, existing: prior),
            editSource: .manualEntry,
            editedAt: editedAt
        )
    }

    /// Reconcile a manual draft for a saved chemical.
    static func outcome(
        for draft: ChemicalManualDraft,
        chemical: SavedChemical?,
        at editedAt: Date? = nil
    ) -> ChemicalEditOutcome {
        outcome(for: draft, existing: chemical?.chemicalIntelligence, at: editedAt)
    }

    // MARK: - Structured → draft

    /// Repopulate the editor from a stored record.
    ///
    /// Every active, every concentration, every scheme and code, every label
    /// rate, every use, the withholding and re-entry periods, the identity and
    /// the country all come back. A record read into a draft and written
    /// straight back out is unchanged, which is what makes "add another active"
    /// safe on a product that already has two.
    ///
    /// A legacy record with no structured data is read through its
    /// `resolvedIntelligence` SEED, so the operator starts from what the old
    /// free-text fields implied rather than from an empty form — but the seed's
    /// `.legacyRecord` provenance is dropped, because saving the draft is the
    /// operator asserting these values themselves.
    static func draft(
        from chemical: SavedChemical?,
        fallbackCountry: String
    ) -> ChemicalManualDraft {
        guard let chemical else {
            return ChemicalManualDraft(
                countryCode: ChemicalRegistration.normaliseCountry(fallbackCountry),
                actives: [ChemicalManualActiveDraft()]
            )
        }
        let intel = chemical.resolvedIntelligence
        let country = intel.registration?.countryCode.isEmpty == false
            ? intel.registration!.countryCode
            : ChemicalRegistration.normaliseCountry(fallbackCountry)

        let actives = intel.activeIngredients.map { active in
            ChemicalManualActiveDraft(
                name: active.name,
                concentrationText: active.concentration
                    .map { ChemicalActiveIngredient.formatConcentration($0) } ?? "",
                concentrationUnit: active.concentrationUnit,
                scheme: active.activityGroup?.scheme,
                groupCode: active.activityGroup?.code ?? ""
            )
        }

        let carriers = intel.registeredUses.filter(isProductRateCarrier)
        let stated = intel.registeredUses.filter { !isProductRateCarrier($0) }

        return ChemicalManualDraft(
            productName: chemical.name,
            countryCode: country,
            productCategory: intel.productCategory.isEmpty
                ? chemical.productCategory
                : intel.productCategory,
            registrant: intel.registration?.registrant ?? chemical.manufacturer,
            registrationScheme: intel.registration?.scheme,
            registrationNumber: intel.registration?.registrationNumber ?? "",
            // Structured value first, then the legacy column. A one-way
            // hydration: from here on the structured reference is the truth.
            labelReference: intel.registration?.labelReference ?? chemical.labelURL,
            // An empty editor is not useful, so a product with no actives on
            // record opens with one blank row to fill in.
            actives: actives.isEmpty ? [ChemicalManualActiveDraft()] : actives,
            productRates: carriers.flatMap { $0.rates.map(rateDraft) },
            uses: stated.map(useDraft)
        )
    }

    // MARK: - Display

    /// `"FRAC 3 + 11"` — a product-level summary DERIVED from the per-active
    /// groups, for display only.
    ///
    /// This is the string the old editor made the operator type. It is now an
    /// output: the record holds Tebuconazole→FRAC 3 and Azoxystrobin→FRAC 11 as
    /// separate facts, and nothing parses this back.
    static func groupSummary(_ draft: ChemicalManualDraft) -> String {
        let groups = draft.actives.compactMap(activityGroup).canonicalised
            .filter(\.isResistanceRelevant)
        guard !groups.isEmpty else { return "" }
        let schemes = Set(groups.map(\.scheme))
        let codes = groups.map(\.code).joined(separator: " + ")
        guard schemes.count == 1, let scheme = schemes.first else {
            // Mixed schemes must stay qualified: "FRAC 3 + IRAC 3" collapsed to
            // "3 + 3" would read as one chemistry used twice.
            return groups.map(\.displayLabel).joined(separator: " + ")
        }
        return "\(scheme.label) \(codes)"
    }

    /// `"Tebuconazole + Azoxystrobin"` — names only, for compact rows.
    static func activesSummary(_ draft: ChemicalManualDraft) -> String {
        draft.actives
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " + ")
    }

    // MARK: - Validation

    /// Problems that would make the draft unstorable or misleading.
    ///
    /// Deliberately short. The editor's job is to record what the label says,
    /// including the parts the operator does not know yet — an incomplete
    /// product is Unverified, which is an honest state, not an error. Only
    /// genuine contradictions and unusable values are reported.
    static func problems(in draft: ChemicalManualDraft) -> [String] {
        var out: [String] = []
        if draft.productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("Product name is required.")
        }

        var seen = Set<String>()
        for active in draft.actives {
            let name = active.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if !seen.insert(name.lowercased()).inserted {
                out.append("\(name) is listed twice. Each active ingredient should appear once.")
            }
            if !active.concentrationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               parseDouble(active.concentrationText) == nil {
                out.append("\(name): concentration is not a number.")
            }
            let code = ChemicalActivityGroup.normaliseCode(active.groupCode)
            if !code.isEmpty, active.scheme == nil {
                out.append("\(name): choose which resistance group system \(code) belongs to.")
            }
        }

        for rate in draft.productRates + draft.uses.flatMap(\.rates) {
            if let problem = rateProblem(rate) { out.append(problem) }
        }
        return out
    }

    private static func rateProblem(_ rate: ChemicalManualRateDraft) -> String? {
        switch rate.basis {
        case .perHectare, .per100Litres:
            let text = rate.valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, parseDouble(text) == nil {
                return "Label rate \"\(text)\" is not a number."
            }
        case .rangePerHectare, .rangePer100Litres:
            let low = parseDouble(rate.minText)
            let high = parseDouble(rate.maxText)
            if let low, let high, low > high {
                return "Label rate range \(ChemicalActiveIngredient.formatConcentration(low))–"
                    + "\(ChemicalActiveIngredient.formatConcentration(high)) is back to front."
            }
        case .other:
            break
        }
        return nil
    }

    // MARK: - Element mapping

    private static func activeIngredient(
        _ draft: ChemicalManualActiveDraft
    ) -> ChemicalActiveIngredient? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = activityGroup(draft)
        // A row the operator started and abandoned carries no information.
        guard !name.isEmpty || group != nil else { return nil }
        let concentration = parseDouble(draft.concentrationText)
        return ChemicalActiveIngredient(
            name: name,
            concentration: concentration,
            // A bare number with no unit is not a concentration, and guessing
            // g/L would silently mis-state a solid product's loading.
            concentrationUnit: concentration == nil ? nil : draft.concentrationUnit,
            activityGroup: group,
            // Left unset on purpose so `ChemicalEditReconciler` assigns provenance
            // per value: `.manualEntry` for anything new or changed, and the prior
            // citation preserved for a value that did not move.
            //
            // Stamping `.manualEntry` here instead would mean merely OPENING this
            // editor and pressing Done stripped a verified product's authoritative
            // classification — a silent downgrade for doing nothing. A brand-new
            // manual product has no prior anything, so every active still lands on
            // `.manualEntry`, which is what keeps it Unverified.
            groupSource: nil,
            identitySource: nil
        )
    }

    private static func activityGroup(
        _ draft: ChemicalManualActiveDraft
    ) -> ChemicalActivityGroup? {
        guard let scheme = draft.scheme else { return nil }
        let code = ChemicalActivityGroup.normaliseCode(draft.groupCode)
        // "Not applicable" is an assertion in its own right — the product has no
        // resistance classification — so it is recorded without a code.
        if scheme == .notApplicable {
            return ChemicalActivityGroup(scheme: .notApplicable, code: "")
        }
        guard !code.isEmpty else { return nil }
        return ChemicalActivityGroup(scheme: scheme, code: code)
    }

    private static func labelRates(
        from drafts: [ChemicalManualRateDraft]
    ) -> [ChemicalLabelRate] {
        drafts.compactMap(labelRate)
    }

    /// The registered rate a draft represents, exactly as the label states it —
    /// original unit, original basis, no conversion.
    ///
    /// This is the ONLY formatter the Edit Chemical screen uses to show an
    /// already-captured registered rate back to the operator: it feeds the
    /// same `ChemicalLabelRate.displayRate` the Spray Calculator's own rate
    /// resolution reads, so the editor and the calculator can never disagree
    /// about what a stored rate says. Returns `nil` only when the draft has
    /// no value at all — never a fabricated or borrowed figure.
    static func displayRate(for draft: ChemicalManualRateDraft) -> String? {
        labelRate(draft)?.displayRate
    }

    private static func labelRate(_ draft: ChemicalManualRateDraft) -> ChemicalLabelRate? {
        let unit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = draft.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.basis {
        case .perHectare, .per100Litres:
            guard let value = parseDouble(draft.valueText) else { return nil }
            return ChemicalLabelRate(label: label, basis: draft.basis, value: value, unit: unit)
        case .rangePerHectare, .rangePer100Litres:
            guard let low = parseDouble(draft.minText),
                  let high = parseDouble(draft.maxText) else { return nil }
            // Stored low-to-high whichever way round it was typed, so
            // `proposedValue` cannot hand a calculation the top of the band.
            return ChemicalLabelRate(
                label: label,
                basis: draft.basis,
                minValue: min(low, high),
                maxValue: max(low, high),
                unit: unit
            )
        case .other:
            guard !raw.isEmpty else { return nil }
            return ChemicalLabelRate(label: label, basis: .other, unit: unit, rawText: raw)
        }
    }

    private static func registeredUse(_ draft: ChemicalManualUseDraft) -> ChemicalRegisteredUse? {
        let crop = draft.crop.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = draft.targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both blank would be indistinguishable from the product-rate carrier.
        guard !crop.isEmpty || !target.isEmpty else { return nil }
        return ChemicalRegisteredUse(
            crop: crop,
            targetRaw: target,
            // `target` is left to the model's own conservative mapping. Forcing
            // VineTrack's six targets onto label wording it does not match would
            // tell the Resistance Engine the wrong disease was managed.
            rates: labelRates(from: draft.rates),
            withholdingPeriodDays: parseInt(draft.withholdingPeriodDaysText),
            reEntryPeriodHours: parseInt(draft.reEntryPeriodHoursText),
            restrictions: draft.restrictions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func rateDraft(_ rate: ChemicalLabelRate) -> ChemicalManualRateDraft {
        ChemicalManualRateDraft(
            label: rate.label,
            basis: rate.basis,
            valueText: rate.value.map { ChemicalActiveIngredient.formatConcentration($0) } ?? "",
            minText: rate.minValue.map { ChemicalActiveIngredient.formatConcentration($0) } ?? "",
            maxText: rate.maxValue.map { ChemicalActiveIngredient.formatConcentration($0) } ?? "",
            unit: rate.unit,
            rawText: rate.rawText ?? ""
        )
    }

    private static func useDraft(_ use: ChemicalRegisteredUse) -> ChemicalManualUseDraft {
        ChemicalManualUseDraft(
            crop: use.crop,
            targetRaw: use.targetRaw,
            rates: use.rates.map(rateDraft),
            withholdingPeriodDaysText: use.withholdingPeriodDays.map(String.init) ?? "",
            reEntryPeriodHoursText: use.reEntryPeriodHours.map(String.init) ?? "",
            restrictions: use.restrictions ?? ""
        )
    }

    // MARK: - Parsing

    /// Accepts both decimal separators, because a comma is what half the world
    /// types and rejecting it silently would drop the value.
    static func parseDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    static func parseInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed) ?? parseDouble(trimmed).map { Int($0) }
    }
}

extension Array where Element == ChemicalRegisteredUse {
    /// Uses that state a real crop+target registration, excluding the carrier
    /// that only holds product-level label rates.
    var statedUses: [ChemicalRegisteredUse] {
        filter { !ChemicalManualEntry.isProductRateCarrier($0) }
    }

    /// Label rates recorded against the product rather than a specific use.
    var productLevelRates: [ChemicalLabelRate] {
        filter(ChemicalManualEntry.isProductRateCarrier).flatMap(\.rates)
    }
}
