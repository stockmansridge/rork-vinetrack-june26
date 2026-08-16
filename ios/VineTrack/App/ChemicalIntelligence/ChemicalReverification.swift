import Foundation

/// Re-verifying an already-structured chemical against the register.
///
/// This is a different act from Match & Verify. Match & Verify answers "which
/// registered product IS this?" for a record that has never been identified.
/// Re-verification starts from an identity VineTrack already holds and asks "has
/// the official information moved since we last looked?" — so it must never throw
/// that identity away and start over with a brand-name search, and it must never
/// write anything until the operator has seen what changed.
///
/// Mirrors `ChemicalReverification.kt` on Android.
nonisolated enum ChemicalReverification {

    /// How strongly VineTrack can identify the product before it asks the
    /// register anything. Higher is better; the flow always uses the strongest
    /// available.
    nonisolated enum IdentityStrength: Int, Sendable, Comparable {
        /// A country-scoped registration key, e.g. `"AU:apvma:62764"`. Exact.
        case registrationIdentity = 4
        /// A structured registration (country + scheme, or a bare number)
        /// without a full authoritative identity key.
        case structuredIdentity = 3
        /// Product name + registrant + country. Strong, but not an identifier.
        case productRegistrantCountry = 2
        /// Product name alone. Ambiguous across manufacturers and countries.
        case productNameOnly = 1
        /// Not even a usable name.
        case none = 0

        nonisolated static func < (lhs: IdentityStrength, rhs: IdentityStrength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        nonisolated var label: String {
            switch self {
            case .registrationIdentity: return "Registration number"
            case .structuredIdentity: return "Registration details"
            case .productRegistrantCountry: return "Product, registrant and country"
            case .productNameOnly: return "Product name"
            case .none: return "No usable identity"
            }
        }

        /// What the operator is told the lookup will key on.
        nonisolated var detail: String {
            switch self {
            case .registrationIdentity:
                return "Re-checking the exact registration VineTrack already holds."
            case .structuredIdentity:
                return "Re-checking using this product's registration details."
            case .productRegistrantCountry:
                return "Re-checking using the product name, registrant and country."
            case .productNameOnly:
                return "Only the product name is known, so the result must be confirmed against your label."
            case .none:
                return "This product cannot be re-verified yet."
            }
        }
    }

    /// Everything the lookup needs, plus how confident the starting identity is.
    nonisolated struct Plan: Sendable, Hashable {
        let productName: String
        let countryCode: String
        let registrationNumber: String?
        let scheme: ChemicalRegistrationScheme?
        let registrant: String?
        /// `"AU:apvma:62764"` when known.
        let identityKey: String?
        let strength: IdentityStrength

        /// Whether Re-verify should be offered at all.
        nonisolated var isSupported: Bool { strength != .none }

        /// The term the structured lookup is keyed on.
        ///
        /// A held registration number goes in verbatim rather than being
        /// discarded in favour of the brand name — starting a fresh name search
        /// when the exact APVMA number is already known is how a re-check ends
        /// up on a different product's label.
        nonisolated var lookupQuery: String {
            if let registrationNumber, !registrationNumber.isEmpty {
                if let scheme, scheme != .other {
                    return "\(scheme.label) \(registrationNumber) \(productName)"
                        .trimmingCharacters(in: .whitespaces)
                }
                return "\(registrationNumber) \(productName)".trimmingCharacters(in: .whitespaces)
            }
            if let registrant, !registrant.isEmpty, strength == .productRegistrantCountry {
                return "\(productName) \(registrant)".trimmingCharacters(in: .whitespaces)
            }
            return productName
        }
    }

    // MARK: - Phase 1/2: is it offered, and on what identity

    /// Build the re-verification plan for a stored chemical.
    ///
    /// - Parameter fallbackCountry: the vineyard's country, used only when the
    ///   record itself carries none. Country is part of product identity, so a
    ///   lookup with no country at all is refused rather than guessed at.
    static func plan(for chemical: SavedChemical, fallbackCountry: String = "") -> Plan {
        let intel = chemical.resolvedIntelligence
        let registration = intel.registration
        let name = (registration?.registeredProductName ?? chemical.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let country = ChemicalRegistration.normaliseCountry(
            registration?.countryCode.isEmpty == false
                ? (registration?.countryCode ?? "")
                : fallbackCountry
        )
        let number = registration?.registrationNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let registrant = (registration?.registrant ?? chemical.manufacturer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let strength: IdentityStrength
        if name.isEmpty {
            strength = .none
        } else if registration?.isAuthoritativeIdentity == true, registration?.identityKey != nil {
            strength = .registrationIdentity
        } else if number != nil {
            strength = .structuredIdentity
        } else if registrant != nil, !country.isEmpty {
            strength = .productRegistrantCountry
        } else {
            strength = .productNameOnly
        }

        return Plan(
            productName: name,
            countryCode: country,
            registrationNumber: number,
            scheme: registration?.scheme,
            registrant: registrant,
            identityKey: registration?.identityKey,
            strength: strength
        )
    }

    /// Whether the Re-verify Chemical action belongs on this record.
    ///
    /// Offered for every status INCLUDING `.needsMatch`, but for needs-match only
    /// when a registration number is actually held. A true legacy product with
    /// nothing but a typed name has no identity to re-check — sending it through
    /// re-verification would silently become a fresh brand-name search wearing
    /// the wrong label, and Match & Verify is the honest action for it.
    static func isOffered(for chemical: SavedChemical, fallbackCountry: String = "") -> Bool {
        let plan = plan(for: chemical, fallbackCountry: fallbackCountry)
        guard plan.isSupported else { return false }
        guard !plan.countryCode.isEmpty else { return false }
        if chemical.verificationStatus == .needsMatch {
            return plan.strength >= .structuredIdentity
        }
        return true
    }

    /// Why Re-verify is unavailable, for the action's disabled footnote.
    static func unavailableReason(for chemical: SavedChemical, fallbackCountry: String = "") -> String? {
        let plan = plan(for: chemical, fallbackCountry: fallbackCountry)
        if plan.productName.isEmpty {
            return "Give this product a name before re-verifying it."
        }
        if plan.countryCode.isEmpty {
            return "Set your vineyard's country so this product can be checked against the right national register."
        }
        if chemical.verificationStatus == .needsMatch, plan.strength < .structuredIdentity {
            return "This product has no registration details yet. Use Match & Verify to identify it first."
        }
        return nil
    }

    // MARK: - Phase 6: nothing changed

    /// Whether the lookup found nothing worth showing the operator.
    ///
    /// Evidence-only differences count as "current": a new retrieval timestamp or
    /// a re-cited source is not a change to the product, and reporting it as one
    /// would teach operators to click through update screens without reading.
    static func isNoChangeResult(_ diff: ChemicalIntelligenceDiff) -> Bool {
        diff.isEmpty || diff.isEvidenceOnly
    }

    /// Record a successful re-check that found no changes.
    ///
    /// The product's VALUES are left exactly as they are — nothing about the
    /// chemistry moved, so nothing about the chemistry is rewritten. What updates
    /// is the evidence: the sources consulted, and when. The stored status claim
    /// is only ever adopted from the candidate when the candidate cited an
    /// authoritative source; `resolvedVerificationStatus` still has the final say
    /// on what is displayed and frozen into future sprays.
    static func confirmingCurrent(
        current: ChemicalIntelligence,
        candidate: ChemicalIntelligence,
        at date: Date = Date()
    ) -> ChemicalIntelligence {
        var result = current
        var verification = current.verification

        let candidateIsAuthoritative = candidate.verification.sources.containsAuthoritative
        verification.sources = mergedSources(current.verification.sources, candidate.verification.sources)
        // Conflicts come from the fresh evidence: a disagreement that has been
        // resolved upstream must be allowed to clear, and a new one must land.
        verification.conflicts = candidate.verification.conflicts
        verification.unresolvedFields = candidate.verification.unresolvedFields
        if candidateIsAuthoritative {
            verification.status = candidate.verification.status
            verification.verifiedAt = date
        }
        result.verification = verification

        // Keep the label pointer fresh even on a no-change result: it is
        // provenance, not chemistry.
        if let candidateRegistration = candidate.registration, var registration = result.registration {
            registration.labelReference = candidateRegistration.labelReference ?? registration.labelReference
            registration.labelVersion = candidateRegistration.labelVersion ?? registration.labelVersion
            result.registration = registration
        }
        return result
    }

    // MARK: - Phase 7/9: accept the candidate

    /// Apply an accepted candidate to the stored record.
    ///
    /// Runs through `ChemicalEditReconciler` rather than assigning the candidate
    /// wholesale, for two reasons. Provenance is reconciled per value, so an
    /// authoritative lookup that confirms one active's group does not silently
    /// endorse another value it never mentioned. And the resulting trust level is
    /// COMPUTED from the merged evidence — there is deliberately no code path
    /// here that can set `.verified`, which is what makes a lookup returning an
    /// unresolved conflict incapable of producing a Verified record.
    static func apply(
        candidate: ChemicalIntelligence,
        to current: ChemicalIntelligence?,
        at date: Date = Date()
    ) -> ChemicalEditOutcome {
        // The lookup's own strongest citation decides whether this edit carries
        // authority. An AI-only answer reconciles as a non-authoritative edit and
        // therefore cannot raise trust, however complete it looks.
        let editSource = candidate.verification.sources.strongest?.kind ?? .aiInterpretation
        let outcome = ChemicalEditReconciler.reconcile(
            existing: current,
            proposed: candidate,
            editSource: editSource,
            editedAt: date
        )
        return carryingLookupConflicts(outcome, from: candidate)
    }

    /// Carry a lookup's own unresolved conflicts into the reconciled outcome.
    ///
    /// `ChemicalEditReconciler` recomputes activity-group conflicts from the
    /// reference table and otherwise preserves the EXISTING record's conflicts,
    /// because it was built for a manual edit where the proposal carries no
    /// evidence of its own. A re-verification candidate does carry evidence: the
    /// lookup can report a disagreement it could not resolve, and silently
    /// dropping that would let a conflicted lookup present itself as Verified.
    ///
    /// Activity-group conflicts are deliberately NOT carried over. The reference
    /// table is the authority there, and re-adding a stale one would resurrect a
    /// conflict the table says no longer exists.
    private static func carryingLookupConflicts(
        _ outcome: ChemicalEditOutcome,
        from candidate: ChemicalIntelligence
    ) -> ChemicalEditOutcome {
        let lookupConflicts = candidate.verification.conflicts.filter {
            $0.field != "activity_group"
        }
        guard !lookupConflicts.isEmpty else { return outcome }

        var seen = Set<String>()
        let merged = (outcome.intelligence.verification.conflicts + lookupConflicts)
            .filter { seen.insert($0.id).inserted }
        var intelligence = outcome.intelligence
        intelligence.verification.conflicts = merged
        return ChemicalEditOutcome(
            intelligence: intelligence,
            changedFields: outcome.changedFields,
            previousStatus: outcome.previousStatus
        )
    }

    /// Write an accepted outcome onto the saved chemical, keeping the legacy
    /// scalar mirrors in step.
    ///
    /// Only the current record is touched. No spray record is read, rewritten or
    /// even loaded here — a completed application's frozen snapshot is not this
    /// function's business, and that is exactly why re-verification cannot
    /// rewrite history.
    static func updated(
        _ chemical: SavedChemical,
        with outcome: ChemicalEditOutcome
    ) -> SavedChemical {
        var result = chemical
        result.chemicalIntelligence = outcome.intelligence
        if let registrant = outcome.intelligence.registration?.registrant, !registrant.isEmpty {
            result.manufacturer = registrant
        }
        if !outcome.intelligence.productCategory.isEmpty {
            result.productCategory = outcome.intelligence.productCategory
        }
        if let reference = outcome.intelligence.registration?.labelReference, !reference.isEmpty {
            result.labelURL = LabelURLValidator.sanitize(reference)
        }
        let projection = result.legacyProjection
        result.activeIngredient = projection.activeIngredient
        result.chemicalGroup = projection.chemicalGroup
        return result
    }

    // MARK: - Helpers

    /// Union of cited sources, candidate first, de-duplicated by identity.
    private static func mergedSources(
        _ current: [ChemicalDataSource],
        _ candidate: [ChemicalDataSource]
    ) -> [ChemicalDataSource] {
        var seen = Set<String>()
        return (candidate + current).filter { seen.insert($0.id).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
