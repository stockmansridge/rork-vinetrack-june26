import Foundation

/// A resistance-critical fact about a chemical.
///
/// These are the fields a resistance decision actually depends on. If one of
/// them is changed by hand, the evidence that previously stood behind the record
/// no longer stands behind the NEW value, and the verification claim has to be
/// re-derived rather than carried over.
///
/// Deliberately an explicit, closed list. Everything NOT named here — purchase
/// price, pack size, price per pack, stock on hand, supplier, operator notes,
/// application notes, the grower's own preferred application rate, label/product
/// URLs — is operational metadata. An edit confined to those fields must leave
/// verification exactly as it was, or growers learn that touching anything
/// destroys trust and stop maintaining their store.
nonisolated enum ChemicalResistanceField: String, Codable, Sendable, CaseIterable, Hashable {
    case country
    case registrationScheme = "registration_scheme"
    case registrationIdentifier = "registration_identifier"
    case productIdentity = "product_identity"
    case activeIngredients = "active_ingredients"
    case activeConcentration = "active_concentration"
    case activityGroupScheme = "activity_group_scheme"
    case activityGroupCode = "activity_group_code"
    case labelRates = "label_rates"
    case registeredUses = "registered_uses"

    nonisolated var label: String {
        switch self {
        case .country: return "Country"
        case .registrationScheme: return "Registration scheme"
        case .registrationIdentifier: return "Registration number"
        case .productIdentity: return "Product identity"
        case .activeIngredients: return "Active ingredients"
        case .activeConcentration: return "Active concentrations"
        case .activityGroupScheme: return "Activity group scheme"
        case .activityGroupCode: return "Activity group"
        case .labelRates: return "Label rates"
        case .registeredUses: return "Registered uses"
        }
    }

    /// The fields that, on their own, invalidate a group-level verification
    /// claim. Used only to choose the operator-facing warning copy.
    static let chemistryCritical: Set<ChemicalResistanceField> = [
        .activeIngredients,
        .activeConcentration,
        .activityGroupScheme,
        .activityGroupCode,
    ]
}

/// The result of putting a proposed edit through the evidence model.
///
/// Carries the reconciled intelligence plus WHY its trust level moved, so the UI
/// can explain the consequence instead of silently changing a badge.
nonisolated struct ChemicalEditOutcome: Sendable {
    let intelligence: ChemicalIntelligence
    let changedFields: [ChemicalResistanceField]
    let previousStatus: ChemicalVerificationStatus

    /// The status the reconciled evidence supports. Never asserted by the UI.
    nonisolated var resolvedStatus: ChemicalVerificationStatus {
        intelligence.resolvedVerificationStatus
    }

    nonisolated var hasResistanceCriticalChange: Bool { !changedFields.isEmpty }

    /// Whether trust actually fell as a result of this edit.
    nonisolated var isDowngrade: Bool {
        resolvedStatus.confidenceRank < previousStatus.confidenceRank
    }

    /// Concise operator-facing consequence, or `nil` when verification is
    /// unaffected. Deliberately states the outcome rather than asking
    /// permission: a correction must never be blocked, only explained.
    nonisolated var warning: String? {
        guard hasResistanceCriticalChange, isDowngrade else { return nil }
        let subject = changedFields.contains(where: { ChemicalResistanceField.chemistryCritical.contains($0) })
            ? "Changing active ingredients or activity groups"
            : "Changing this product's registered identity"
        return "\(subject) means this product can no longer keep its "
            + "\(previousStatus.label.lowercased()) status unless the new information is "
            + "supported by verification evidence. It will be recorded as "
            + "\(resolvedStatus.label.lowercased())."
    }
}

/// Re-derives a chemical's verification from its evidence after a manual edit.
///
/// This closes the trust hole where a record could keep a stored `verified`
/// status after a human changed the very value that was verified. The rule is
/// not "an edit unverifies a product" — that would be a UI rule bolted on top of
/// the model. The rule is that evidence belongs to a VALUE: when the value
/// changes by hand, the authoritative citation that supported the old value is
/// withdrawn, the operator's own entry is recorded in its place, and
/// `ChemicalVerification.resolvedStatus(actives:hasRegistration:)` is left to
/// reach whatever conclusion the remaining evidence actually supports.
///
/// That is why a group edit on a two-active product can legitimately land on
/// `.partiallyVerified` (the other active is still authoritatively classified)
/// or on `.conflict` (the reference table positively disagrees with what was
/// typed) — the outcome is computed, never assigned.
///
/// Mirrors `ChemicalEditReconciliation.kt` on Android field for field, because
/// both apps write the same Supabase rows and a resistance decision must not
/// depend on which phone recorded the edit.
nonisolated enum ChemicalEditReconciler {

    // MARK: - Structured proposals

    /// Reconcile a structured proposal against what the record previously held.
    ///
    /// - Parameters:
    ///   - existing: the record's current intelligence, or `nil` for a new product.
    ///   - proposed: the values the operator wants to store.
    ///   - editSource: how the proposed values arrived. Manual entry by default;
    ///     a future re-verify flow passes its own authoritative sources instead.
    ///   - editedAt: when the edit happened, stamped onto the recorded citation.
    static func reconcile(
        existing: ChemicalIntelligence?,
        proposed: ChemicalIntelligence,
        editSource: ChemicalDataSourceKind = .manualEntry,
        editedAt: Date? = nil
    ) -> ChemicalEditOutcome {
        let previousStatus = existing?.resolvedVerificationStatus ?? .unverified
        var changed: [ChemicalResistanceField] = []

        let reconciledActives = reconcileActives(
            existing: existing?.activeIngredients ?? [],
            proposed: proposed.activeIngredients,
            editSource: editSource,
            changed: &changed
        )

        // Activity-group conflicts are recomputed from scratch for every active
        // on every reconcile, so correcting a bad value CLEARS the conflict it
        // caused. Conflicts about anything else are preserved untouched: this
        // function did not look at those fields and has no basis to dismiss them.
        let groupConflicts = reconciledActives.compactMap {
            conflict(for: $0, editSource: editSource)
        }
        let otherConflicts = (existing?.verification.conflicts ?? [])
            .filter { $0.field != "activity_group" }

        let registration = reconcileRegistration(
            existing: existing?.registration,
            proposed: proposed.registration,
            changed: &changed
        )

        let existingUses = existing?.registeredUses ?? []
        if proposed.registeredUses != existingUses {
            note(.registeredUses, in: &changed)
            let existingRates = existingUses.flatMap(\.rates)
            if proposed.registeredUses.flatMap(\.rates) != existingRates {
                note(.labelRates, in: &changed)
            }
        }

        let verification = reconcileVerification(
            existing: existing?.verification,
            proposed: proposed.verification,
            changed: changed,
            conflicts: deduplicated(groupConflicts + otherConflicts),
            editSource: editSource,
            editedAt: editedAt
        )

        var result = proposed
        result.activeIngredients = reconciledActives
        result.registration = registration
        result.verification = verification
        result.activityGroupTableVersion = AuthoritativeActivityGroups.tableVersion

        return ChemicalEditOutcome(
            intelligence: result,
            changedFields: changed,
            previousStatus: previousStatus
        )
    }

    // MARK: - Legacy free-text edits

    /// Reconcile an edit made through the LEGACY scalar form, which offers only
    /// free-text `Active Ingredient`, `Chemical Group`, `Mode of Action` and
    /// `Manufacturer` boxes.
    ///
    /// The comparison is made against the record's own legacy PROJECTIONS. If
    /// the operator did not touch those boxes, the text still equals what the
    /// structured data projects, nothing resistance-critical changed, and `nil`
    /// is returned — an edit to price, stock or notes through this form must not
    /// disturb a verified product.
    ///
    /// If the text HAS changed, the operator has hand-authored chemistry. It is
    /// taken seriously — their value is stored — but as `.manualEntry`, and
    /// cross-checked against the reference table so a positive disagreement
    /// surfaces as a conflict rather than being quietly accepted.
    ///
    /// - Returns: `nil` when nothing resistance-critical moved, which the caller
    ///   must read as "leave the stored intelligence exactly as it is".
    static func reconcileLegacyEdit(
        existing: ChemicalIntelligence?,
        activeIngredientText: String,
        chemicalGroupText: String,
        modeOfActionText: String,
        productCategory: String,
        registrantText: String,
        editedAt: Date? = nil
    ) -> ChemicalEditOutcome? {
        guard let current = existing, !current.isEmpty else { return nil }

        let activesChanged = !sameFreeText(activeIngredientText, current.legacyActiveIngredient)
        let groupChanged = !sameFreeText(chemicalGroupText, current.legacyChemicalGroup)
        let trimmedRegistrant = registrantText.trimmingCharacters(in: .whitespacesAndNewlines)
        let registrantChanged = !trimmedRegistrant.isEmpty
            && !sameFreeText(trimmedRegistrant, current.registration?.registrant ?? "")

        guard activesChanged || groupChanged || registrantChanged else { return nil }

        let category = productCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? current.productCategory
            : productCategory

        let proposedActives: [ChemicalActiveIngredient]
        if activesChanged || groupChanged {
            proposedActives = manualActives(
                activeIngredientText: activeIngredientText,
                chemicalGroupText: chemicalGroupText,
                modeOfActionText: modeOfActionText,
                productCategory: category,
                existing: current.activeIngredients
            )
        } else {
            proposedActives = current.activeIngredients
        }

        var proposedRegistration = current.registration
        if registrantChanged {
            var reg = current.registration ?? ChemicalRegistration(countryCode: "")
            reg.registrant = trimmedRegistrant
            proposedRegistration = reg
        }

        var proposed = current
        proposed.activeIngredients = proposedActives
        proposed.registration = proposedRegistration
        proposed.productCategory = category

        return reconcile(
            existing: current,
            proposed: proposed,
            editSource: .manualEntry,
            editedAt: editedAt
        )
    }

    /// Build structured actives from the legacy free-text boxes.
    ///
    /// Positional pairing only when the counts line up exactly — the same rule
    /// `ChemicalIntelligence.legacySeed` uses, for the same reason: guessing
    /// which active in a mixture owns a single typed group would invent
    /// chemistry. Concentrations already known for an active that was NOT
    /// renamed are carried across, because the free-text box never held them.
    private static func manualActives(
        activeIngredientText: String,
        chemicalGroupText: String,
        modeOfActionText: String,
        productCategory: String,
        existing: [ChemicalActiveIngredient]
    ) -> [ChemicalActiveIngredient] {
        let scheme = ChemicalActivityGroupScheme.implied(byProductCategory: productCategory)
        var codes = ChemicalActivityGroup.parseLegacyText(chemicalGroupText, assumedScheme: scheme)
        if codes.isEmpty {
            codes = ChemicalActivityGroup.parseLegacyText(modeOfActionText, assumedScheme: scheme)
        }

        let names = ChemicalIntelligence.splitActiveNames(activeIngredientText)
        if names.isEmpty {
            return codes.map { group in
                ChemicalActiveIngredient(
                    name: "",
                    activityGroup: group,
                    groupSource: .manualEntry,
                    identitySource: .manualEntry
                )
            }
        }

        return names.enumerated().map { index, name in
            let prior = existing.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return ChemicalActiveIngredient(
                name: name,
                concentration: prior?.concentration,
                concentrationUnit: prior?.concentrationUnit,
                activityGroup: names.count == codes.count ? codes[index] : prior?.activityGroup,
                groupSource: .manualEntry,
                // The free-text box never held the concentration, so an active whose
                // name still matches has not had its IDENTITY restated — only its
                // group. Inheriting the prior identity provenance is what keeps a
                // looked-up product identified after a hand-edited group, instead of
                // the record forgetting a register ever confirmed which product it is.
                identitySource: prior?.identitySource ?? .manualEntry
            )
        }
    }

    // MARK: - Per-value reconciliation

    /// Pair proposed actives with what the record already held and decide, per
    /// active, whether the old provenance still applies.
    ///
    /// Provenance survives ONLY where the value is unchanged. A changed group, a
    /// changed concentration or a brand-new active all take the edit's own
    /// source, which is what stops the reference table's classification of
    /// Azoxystrobin-as-FRAC-11 from appearing to endorse a hand-typed FRAC 3.
    private static func reconcileActives(
        existing: [ChemicalActiveIngredient],
        proposed: [ChemicalActiveIngredient],
        editSource: ChemicalDataSourceKind,
        changed: inout [ChemicalResistanceField]
    ) -> [ChemicalActiveIngredient] {
        var existingByName: [String: ChemicalActiveIngredient] = [:]
        for active in existing { existingByName[normalisedKey(active.name)] = active }

        if Set(existing.map { normalisedKey($0.name) }) != Set(proposed.map { normalisedKey($0.name) }) {
            note(.activeIngredients, in: &changed)
        }

        var out: [ChemicalActiveIngredient] = []
        for active in proposed {
            guard let prior = existingByName[normalisedKey(active.name)] else {
                // A newly named active carries no inherited authority.
                var fresh = active
                fresh.groupSource = active.groupSource ?? editSource
                fresh.identitySource = active.identitySource ?? editSource
                out.append(fresh)
                continue
            }

            let groupMoved = prior.activityGroup != active.activityGroup
            if groupMoved {
                if prior.activityGroup?.scheme != active.activityGroup?.scheme {
                    note(.activityGroupScheme, in: &changed)
                }
                if prior.activityGroup?.code != active.activityGroup?.code {
                    note(.activityGroupCode, in: &changed)
                }
            }
            let concentrationMoved = prior.concentration != active.concentration
                || prior.concentrationUnit != active.concentrationUnit
            if concentrationMoved {
                note(.activeConcentration, in: &changed)
            }

            var merged = active
            // Withdraw the old citation for a value it no longer describes.
            merged.groupSource = groupMoved ? editSource : (active.groupSource ?? prior.groupSource)
            merged.identitySource = concentrationMoved
                ? editSource
                : (active.identitySource ?? prior.identitySource)
            out.append(merged)
        }
        return out
    }

    /// Country, scheme and registration number ARE the product's identity, so
    /// any change to them means the record now claims to be a different
    /// registered product and cannot inherit the previous registration's
    /// authority.
    ///
    /// A changed registrant NAME is treated as an identity change too, but a
    /// changed product name is not: once a registration number is known, that
    /// number is the identity and the display name is just a label the grower is
    /// free to keep tidy ("Amistar 250 (old stock)").
    private static func reconcileRegistration(
        existing: ChemicalRegistration?,
        proposed: ChemicalRegistration?,
        changed: inout [ChemicalResistanceField]
    ) -> ChemicalRegistration? {
        guard let existing, let proposed else {
            if existing?.identityKey != proposed?.identityKey {
                note(.registrationIdentifier, in: &changed)
            }
            return proposed
        }
        if existing.countryCode.caseInsensitiveCompare(proposed.countryCode) != .orderedSame {
            note(.country, in: &changed)
        }
        if existing.scheme != proposed.scheme {
            note(.registrationScheme, in: &changed)
        }
        if existing.registrationNumber != proposed.registrationNumber {
            note(.registrationIdentifier, in: &changed)
        }
        if !sameFreeText(existing.registrant ?? "", proposed.registrant ?? "") {
            note(.productIdentity, in: &changed)
        }
        return proposed
    }

    /// Rebuild the verification block around the reconciled values.
    ///
    /// When nothing resistance-critical moved the block is left alone apart from
    /// the recomputed conflicts. When something did move, every authoritative
    /// citation is withdrawn — it was evidence for the OLD value — the edit's
    /// own source is recorded, and the stored claim is lowered so
    /// `resolvedStatus` cannot read a stale `verified` back out. Confidence is
    /// only ever reduced here, never raised.
    private static func reconcileVerification(
        existing: ChemicalVerification?,
        proposed: ChemicalVerification,
        changed: [ChemicalResistanceField],
        conflicts: [ChemicalVerificationConflict],
        editSource: ChemicalDataSourceKind,
        editedAt: Date?
    ) -> ChemicalVerification {
        var base = existing ?? proposed
        guard !changed.isEmpty else {
            base.conflicts = conflicts
            return base
        }

        let citation = ChemicalDataSource(
            kind: editSource,
            name: editSource == .manualEntry
                ? "Edited in VineTrack"
                : (proposed.sources.strongest?.name ?? "Chemical lookup"),
            retrievedAt: editedAt
        )

        // An authoritative source cited for the PREVIOUS value must not be
        // carried forward as though it endorsed the new one.
        let retained = editSource.isAuthoritative
            ? proposed.sources
            : base.sources.filter { !$0.kind.isAuthoritative }

        let loweredStatus: ChemicalVerificationStatus
        if !conflicts.isEmpty {
            loweredStatus = .conflict
        } else if editSource.isAuthoritative {
            loweredStatus = proposed.status
        } else if base.status == .needsMatch {
            // A record that was never matched stays "needs match": that is a
            // lower claim than verified, and re-labelling it would lose the
            // distinction the audit depends on.
            loweredStatus = .needsMatch
        } else {
            // Never keep a verified/partially-verified CLAIM across a manual
            // change. `resolvedStatus` may still compute `.partiallyVerified`
            // from surviving evidence, which is a conclusion, not a claim.
            loweredStatus = .unverified
        }

        base.status = loweredStatus
        base.sources = deduplicatedSources(retained + [citation])
        base.conflicts = conflicts
        base.verifiedAt = editSource.isAuthoritative ? proposed.verifiedAt : nil
        base.unresolvedFields = proposed.unresolvedFields
        return base
    }

    /// Cross-check one active's group against the reference table.
    ///
    /// Only the conflict is taken: the operator's typed value stays stored, so a
    /// correction is never silently overwritten by the table. What changes is
    /// that the disagreement becomes visible instead of being accepted.
    private static func conflict(
        for active: ChemicalActiveIngredient,
        editSource: ChemicalDataSourceKind
    ) -> ChemicalVerificationConflict? {
        guard !active.name.isEmpty else { return nil }
        guard let group = active.activityGroup, group.isResistanceRelevant else { return nil }
        return AuthoritativeActivityGroups.reconcile(
            activeNamed: active.name,
            extracted: group,
            extractedSource: active.groupSource ?? editSource
        ).conflict
    }

    // MARK: - Helpers

    private static func note(
        _ field: ChemicalResistanceField,
        in changed: inout [ChemicalResistanceField]
    ) {
        guard !changed.contains(field) else { return }
        changed.append(field)
    }

    private static func deduplicated(
        _ conflicts: [ChemicalVerificationConflict]
    ) -> [ChemicalVerificationConflict] {
        var seen = Set<String>()
        return conflicts.filter { seen.insert($0.id).inserted }
    }

    private static func deduplicatedSources(
        _ sources: [ChemicalDataSource]
    ) -> [ChemicalDataSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }

    private static func normalisedKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Case- and whitespace-insensitive comparison of two operator-typed
    /// strings. Retyping `" azoxystrobin  250 g/L "` over
    /// `"Azoxystrobin 250 g/L"` is not evidence of anything and must not cost a
    /// product its verification.
    private static func sameFreeText(_ a: String, _ b: String) -> Bool {
        collapseWhitespace(a).caseInsensitiveCompare(collapseWhitespace(b)) == .orderedSame
    }

    private static func collapseWhitespace(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
