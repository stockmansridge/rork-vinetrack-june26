import Foundation

/// Builds ONE editable Chemical Store record out of everything a lookup found.
///
/// # The rule this type exists to enforce
///
/// "Was the registration identity uniquely confirmed?" and "what did we learn
/// about this product?" are two different questions, and the flow used to
/// answer the second with the first. When the register could not confirm
/// Dithane Rainshield, the resolver correctly quarantined its AI-read chemistry
/// out of the *canonical* response — and the app then showed the operator an
/// empty form, as though Mancozeb had never been found. The information existed
/// the whole way through; nothing was populating it.
///
/// So the merge here is NON-DESTRUCTIVE: for every field it takes the strongest
/// value that is actually present, and a blank from a stronger tier never
/// erases a populated value from a weaker one.
///
/// ```text
/// 1. official register / manufacturer label   (canonical, server-merged)
/// 2. approved Master Catalogue                (canonical, server-merged)
/// 3. structured lookup canonical fields
/// 4. ai_suggestion — the resolver's own quarantined reading
/// 5. the selected search result
/// 6. the record already open in the editor
/// ```
///
/// Tiers 1–3 arrive already merged by the server in `intelligence()`; the
/// register wins on register-asserted facts there, and this type does not
/// second-guess that. What it adds is tiers 4–6, which the client was dropping.
///
/// # What it deliberately does NOT do
///
/// Populating a field is not the same as trusting it. Values that come from
/// tier 4 or 5 are written with `ai_interpretation` provenance and never with
/// an authoritative one, so `resolvedVerificationStatus` cannot be moved by
/// anything this merge does — a product whose identity was not confirmed still
/// saves as Unverified, with its chemistry filled in and editable. That is the
/// honest state: "here is what we found, nobody has confirmed it".
nonisolated enum ChemicalReviewMerge {

    /// The strongest non-empty string across the tiers, in order.
    private static func firstNonEmpty(_ candidates: [String?]) -> String {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Build the reviewable record.
    ///
    /// - Parameters:
    ///   - lookup: the structured response, or `nil` when the lookup failed.
    ///     A failed lookup still produces a useful draft from the search row.
    ///   - selected: the row the operator actually tapped. Its NAME is
    ///     authoritative for identity from the moment of selection — the typed
    ///     query is dead, so a search for "Dithaine rainshield" that resolves to
    ///     "Dithane Rainshield" saves the latter.
    ///   - existing: the record being matched (legacy cleanup), if any.
    ///   - countryCode: the vineyard's jurisdiction.
    static func reviewChemical(
        lookup: ChemicalStructuredLookup?,
        selected: ChemicalSearchResult?,
        existing: SavedChemical?,
        countryCode: String,
        vineyardId: UUID
    ) -> SavedChemical {
        let canonical = lookup?.intelligence()
        let advisory = lookup?.aiSuggestion

        var chemical = existing ?? SavedChemical(vineyardId: vineyardId)

        // ---- Identity -------------------------------------------------------
        chemical.name = firstNonEmpty([
            canonical?.registration?.registeredProductName,
            lookup?.productName,
            advisory?.productName,
            selected?.name,
            existing?.name
        ])

        chemical.manufacturer = firstNonEmpty([
            canonical?.registration?.registrant,
            advisory?.registrant,
            // The brand on the row the operator chose. Display metadata: it
            // cites no source and classifies nothing, so it cannot move trust.
            selected?.brand,
            existing?.manufacturer
        ])

        chemical.productCategory = firstNonEmpty([
            canonical?.productCategory,
            advisory?.productCategory,
            existing?.productCategory
        ])

        // ---- Chemistry ------------------------------------------------------
        let actives = mergedActives(
            canonical: canonical?.activeIngredients ?? [],
            advisory: advisory?.activeIngredients ?? [],
            searchText: selected?.activeIngredient,
            existing: existing?.chemicalIntelligence?.activeIngredients ?? []
        )

        // ---- Uses, rates, WHP, re-entry, restrictions ------------------------
        let uses = firstNonEmptyList([
            canonical?.registeredUses ?? [],
            advisory?.registeredUses ?? [],
            existing?.chemicalIntelligence?.registeredUses ?? []
        ])

        // ---- Registration ---------------------------------------------------
        // A number is never invented. When the register did not confirm one the
        // field stays blank, which is exactly what "Registration not confirmed"
        // means — and it costs the chemistry above nothing.
        let registration = mergedRegistration(
            canonical: canonical?.registration,
            existing: existing?.chemicalIntelligence?.registration,
            selected: selected,
            countryCode: countryCode
        )

        // ---- Evidence -------------------------------------------------------
        // Verbatim from the server. Not rebuilt, not upgraded: the sources,
        // conflicts and unresolved-field list are its account of what it could
        // establish, and populating the form does not change what was proved.
        let verification = canonical?.verification
            ?? existing?.chemicalIntelligence?.verification
            ?? ChemicalVerification()

        let intelligence = ChemicalIntelligence(
            activeIngredients: actives,
            registration: registration,
            verification: verification,
            registeredUses: uses,
            fieldProvenance: canonical?.fieldProvenance
                ?? existing?.chemicalIntelligence?.fieldProvenance,
            productCategory: chemical.productCategory,
            activityGroupTableVersion: canonical?.activityGroupTableVersion
                ?? AuthoritativeActivityGroups.tableVersion,
            schemaVersion: canonical?.schemaVersion ?? ChemicalIntelligence.currentSchemaVersion
        )
        chemical.chemicalIntelligence = intelligence.isEmpty ? existing?.chemicalIntelligence : intelligence

        // ---- Presentation fields the store already has -----------------------
        if let reference = registration?.labelReference, !reference.isEmpty {
            chemical.labelURL = LabelURLValidator.sanitize(reference)
        }
        if let unit = productUnit(formType: lookup?.formType, actives: actives) {
            chemical.unit = unit
        }
        if chemical.use.isEmpty {
            chemical.use = firstNonEmpty([selected?.primaryUse, existing?.use])
        }
        if chemical.modeOfAction.isEmpty {
            chemical.modeOfAction = firstNonEmpty([selected?.modeOfAction, existing?.modeOfAction])
        }

        // Legacy scalars stay a DERIVED mirror of the structured record, so old
        // clients and the existing API keep rendering something familiar.
        let projection = chemical.legacyProjection
        chemical.activeIngredient = projection.activeIngredient.isEmpty
            ? firstNonEmpty([selected?.activeIngredient, existing?.activeIngredient])
            : projection.activeIngredient
        chemical.chemicalGroup = projection.chemicalGroup.isEmpty
            ? firstNonEmpty([selected?.chemicalGroup, existing?.chemicalGroup])
            : projection.chemicalGroup

        return chemical
    }

    // MARK: - Actives

    /// The strongest populated set of actives.
    ///
    /// Whole-list rather than field-by-field, because actives are a SET: taking
    /// the register's Mancozeb and the model's second active would assert a
    /// mixture nobody described. An empty canonical list is "the register did
    /// not tell us", never "this product has no actives", so it falls through
    /// instead of winning.
    static func mergedActives(
        canonical: [ChemicalActiveIngredient],
        advisory: [ChemicalActiveIngredient],
        searchText: String?,
        existing: [ChemicalActiveIngredient]
    ) -> [ChemicalActiveIngredient] {
        if !canonical.isEmpty { return canonical }
        if !advisory.isEmpty { return advisory.map(asUnverified) }
        let parsed = parseActives(searchText).map(asUnverified)
        if !parsed.isEmpty { return parsed }
        return existing
    }

    /// Restate an active as the unverified reading it is.
    ///
    /// This is the guard that keeps populating the form from laundering into
    /// trust. `hasAuthoritativeGroup` reads `groupSource`, and
    /// `resolvedStatus` promotes to Partially Verified the moment ONE active
    /// carries an authoritative group — so an AI-read active must never claim
    /// one, however confidently the on-device table could classify its name.
    /// The value is shown and editable; the certainty is not fabricated.
    private static func asUnverified(_ active: ChemicalActiveIngredient) -> ChemicalActiveIngredient {
        ChemicalActiveIngredient(
            name: active.name,
            concentration: active.concentration,
            concentrationUnit: active.concentrationUnit,
            activityGroup: active.activityGroup,
            groupSource: active.activityGroup == nil ? nil : .aiInterpretation,
            identitySource: .aiInterpretation
        )
    }

    /// Read `"Mancozeb 750 g/kg"` or `"Spinetoram 120 g/L + Pyraclostrobin 200 g/L"`
    /// off a search row.
    ///
    /// The weakest tier, and the only one that has to guess at structure. It
    /// takes a name and — only when the text plainly states one — a
    /// concentration. A number it cannot read confidently is left off rather
    /// than approximated: a wrong concentration silently mis-doses.
    static func parseActives(_ raw: String?) -> [ChemicalActiveIngredient] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let parts = raw
            .components(separatedBy: CharacterSet(charactersIn: "+,;/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [ChemicalActiveIngredient] = []
        var seen = Set<String>()
        for part in parts {
            guard let active = parseActive(part) else { continue }
            guard seen.insert(active.name.lowercased()).inserted else { continue }
            out.append(active)
        }
        return out
    }

    private static func parseActive(_ text: String) -> ChemicalActiveIngredient? {
        // Split at the first digit: everything before is the name, everything
        // from there is the concentration and its unit.
        guard let digitIndex = text.firstIndex(where: \.isNumber) else {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2 else { return nil }
            return ChemicalActiveIngredient(name: name, identitySource: .aiInterpretation)
        }
        let name = String(text[text.startIndex..<digitIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return nil }

        let remainder = String(text[digitIndex...])
        let numberText = remainder.prefix { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: ".")
        let unitText = remainder.dropFirst(numberText.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let concentration = Double(numberText)
        let unit = ChemicalConcentrationUnit.parse(unitText)
        // A number with no readable unit is not a concentration — "750" alone
        // could be g/kg or g/L, and the two are different products.
        guard let concentration, let unit else {
            return ChemicalActiveIngredient(name: name, identitySource: .aiInterpretation)
        }
        return ChemicalActiveIngredient(
            name: name,
            concentration: concentration,
            concentrationUnit: unit,
            identitySource: .aiInterpretation
        )
    }

    // MARK: - Registration

    /// Merge registration identity WITHOUT ever inventing one.
    ///
    /// The country is always known (it is the vineyard's), so a registration
    /// block exists to hold it even when nothing else was confirmed. The number,
    /// scheme, registered name, label reference and label version each survive
    /// only if some tier actually supplied them.
    static func mergedRegistration(
        canonical: ChemicalRegistration?,
        existing: ChemicalRegistration?,
        selected: ChemicalSearchResult?,
        countryCode: String
    ) -> ChemicalRegistration? {
        let country = firstNonEmpty([
            canonical?.countryCode,
            existing?.countryCode,
            countryCode
        ])
        // The selected candidate's number is a POINTER the resolver was asked to
        // verify. It is carried into the form so the operator can see and edit
        // what was tried, but it is never presented as confirmed: the scheme
        // below only comes from a tier that actually established one.
        let number = firstNonEmpty([
            canonical?.registrationNumber,
            existing?.registrationNumber,
            selected?.registrationNumber
        ])
        let registeredName = firstNonEmpty([
            canonical?.registeredProductName,
            existing?.registeredProductName
        ])
        let reference = firstNonEmpty([
            canonical?.labelReference,
            existing?.labelReference
        ])
        let version = firstNonEmpty([
            canonical?.labelVersion,
            existing?.labelVersion
        ])
        let registrant = firstNonEmpty([
            canonical?.registrant,
            existing?.registrant
        ])

        if country.isEmpty && number.isEmpty && registeredName.isEmpty { return nil }

        return ChemicalRegistration(
            countryCode: country,
            // No number means no scheme: a scheme on its own would claim the
            // product is registered somewhere without saying as what.
            scheme: number.isEmpty
                ? nil
                : (canonical?.scheme ?? existing?.scheme
                   ?? ChemicalRegistrationScheme.schemes(forCountryCode: country).first),
            registrationNumber: number.isEmpty ? nil : number,
            registrant: registrant.isEmpty ? nil : registrant,
            registeredProductName: registeredName.isEmpty ? nil : registeredName,
            labelReference: reference.isEmpty ? nil : reference,
            labelVersion: version.isEmpty ? nil : version
        )
    }

    // MARK: - Helpers

    private static func firstNonEmptyList<T>(_ lists: [[T]]) -> [T] {
        for list in lists where !list.isEmpty { return list }
        return []
    }

    /// The product unit the Chemical Store should default to.
    ///
    /// Read from the formulation where the lookup stated one, else inferred
    /// from the actives' concentration unit — g/L is a liquid, g/kg is a solid.
    /// Only ever a DEFAULT: the operator can change it, and rates are quoted
    /// against it rather than converted by it.
    static func productUnit(
        formType: String?,
        actives: [ChemicalActiveIngredient]
    ) -> ChemicalUnit? {
        let form = (formType ?? "").lowercased()
        if !form.isEmpty {
            if form.contains("liquid") { return .litres }
            if form.contains("solid") || form.contains("granul") || form.contains("powder")
                || form.contains("wettable") || form.contains("wdg") || form.contains("wg") {
                return .kilograms
            }
        }
        switch actives.compactMap(\.concentrationUnit).first {
        case .gramsPerLitre, .percentWeightPerVolume: return .litres
        case .gramsPerKilogram, .colonyFormingUnitsPerGram: return .kilograms
        default: return nil
        }
    }
}
