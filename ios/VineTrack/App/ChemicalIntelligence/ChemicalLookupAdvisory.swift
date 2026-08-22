import Foundation

/// The resolver's own UNVERIFIED reading of a product, quarantined.
///
/// # Why this type exists
///
/// The structured resolver has a fail-closed gate: when a jurisdiction's
/// official register is successfully consulted and cannot uniquely verify the
/// product, every AI-derived product fact is stripped out of the canonical
/// response and moved into an `ai_suggestion` advisory. The canonical fields
/// then honestly read "unresolved".
///
/// That gate is correct and this type does not weaken it. The defect was that
/// iOS decoded the emptied canonical fields and silently DISCARDED the
/// advisory, so the operator saw the search screen say "Mancozeb" and the
/// verify screen say "No active ingredients were identified", with nothing on
/// screen to reconcile the two. The evidence had been deliberately withheld and
/// the app could not say so.
///
/// Nothing here is EVIDENCE. It is a reading, and it is treated as one:
/// `ChemicalReviewMerge` populates the editable review draft from it so the
/// operator can see and correct what was found, but every value it contributes
/// is written with `ai_interpretation` provenance, so it can never move
/// `resolvedVerificationStatus`. Populating a field and trusting a field are
/// different acts, and only the first one happens here.
nonisolated struct ChemicalLookupAdvisory: Sendable, Hashable {
    /// The resolver's own wording for why nothing here is a product fact.
    let note: String
    let productName: String?
    let registrant: String?
    let productCategory: String?
    /// The actives the model read off the product — UNVERIFIED. This is the
    /// "Mancozeb" that used to vanish between Search and Verify.
    let activeIngredients: [ChemicalActiveIngredient]
    /// Registered uses, rates, WHP, re-entry and restrictions the model read —
    /// UNVERIFIED. Carried for the same reason the actives are: an operator
    /// holding the label can confirm them in seconds, and cannot confirm a
    /// field they were never shown.
    let registeredUses: [ChemicalRegisteredUse]

    var hasContent: Bool {
        !activeIngredients.isEmpty
            || !registeredUses.isEmpty
            || (productName?.isEmpty == false)
            || (registrant?.isEmpty == false)
    }

    /// The unverified actives as a single readable line.
    var activeIngredientSummary: String {
        activeIngredients.map(\.name).filter { !$0.isEmpty }.joined(separator: " + ")
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case note
        case productName = "product_name"
        case registrant
        case productCategory = "product_category"
        case activeIngredients = "active_ingredients"
        case registeredUses = "registered_uses"
    }
}

extension ChemicalLookupAdvisory: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) as? String ?? ""
        productName = try? c.decodeIfPresent(String.self, forKey: .productName)
        registrant = try? c.decodeIfPresent(String.self, forKey: .registrant)
        productCategory = try? c.decodeIfPresent(String.self, forKey: .productCategory)
        // Tolerant: a malformed advisory costs the advisory, never the lookup.
        // It is decoration on a refusal; it must not become a second way for
        // the whole Match & Verify flow to fail.
        activeIngredients = ((try? c.decodeIfPresent(
            [ChemicalActiveIngredient].self, forKey: .activeIngredients
        )) ?? []) ?? []
        registeredUses = ((try? c.decodeIfPresent(
            [ChemicalRegisteredUse].self, forKey: .registeredUses
        )) ?? []) ?? []
    }
}

/// What the jurisdiction's register did when this lookup ran.
///
/// The distinction the resolver draws, preserved verbatim on the client,
/// because "we checked and could not confirm it" and "we could not check"
/// require different things of the operator and must not read the same.
nonisolated struct ChemicalDiscoveryEnvelope: Sendable, Hashable, Codable {
    /// Which register adapter ran, e.g. `"apvma"`. `nil` when none did.
    let adapter: String?
    /// `resolved` | `unresolved` | `ambiguous` | `source_unavailable`
    /// | `not_supported` | `no_country`.
    let outcome: String?
    let errorCategory: String?
    /// An AI-guessed registration number the resolver tried as a pointer and
    /// then threw away because the register did not confirm it.
    let discardedRegistrationHint: String?

    nonisolated enum CodingKeys: String, CodingKey {
        case adapter
        case outcome
        case errorCategory = "error_category"
        case discardedRegistrationHint = "ai_registration_hint_discarded"
    }

    /// The register answered, and the answer was "not this product".
    ///
    /// The only outcome that justifies withholding evidence. An outage did not
    /// disprove anything.
    var wasCheckedAndUnverified: Bool {
        outcome == "unresolved" || outcome == "ambiguous"
    }

    var wasUnavailable: Bool { outcome == "source_unavailable" }

    var wasNeverConsulted: Bool {
        outcome == "not_supported" || outcome == "no_country" || outcome == nil
    }
}

/// Why the Verify screen is showing less than the Search screen did.
///
/// Computed from the resolver's own envelope plus what the operator actually
/// selected, so the explanation is derived from evidence rather than written
/// into the UI as a guess.
nonisolated enum ChemicalEvidenceWithholdingReason: Sendable, Hashable {
    /// The register was consulted and could not uniquely verify the product,
    /// so its AI-read chemistry was quarantined. Working as designed.
    case registerCheckedAndUnverified(registerName: String?)
    /// The operator picked a row that the register itself returned moments
    /// ago, and the strict resolver then could not re-verify that same
    /// identity. Search and the resolver disagree about one product — a
    /// contract misalignment worth surfacing rather than absorbing.
    case selectedRegisterCandidateNotReVerified(registrationNumber: String?)
    /// The register could not be reached. Nothing was disproved.
    case registerUnavailable
    /// No register covers this jurisdiction, so there was nothing to check.
    case registerNotConsulted

    var headline: String {
        switch self {
        case .registerCheckedAndUnverified:
            return "Chemistry not established"
        case .selectedRegisterCandidateNotReVerified:
            return "Register entry could not be re-confirmed"
        case .registerUnavailable:
            return "Register could not be reached"
        case .registerNotConsulted:
            return "No official register for this country"
        }
    }

    var detail: String {
        switch self {
        case .registerCheckedAndUnverified(let register):
            let name = register.map { "the \($0) register" } ?? "the official register"
            return "\(name) was checked and could not uniquely confirm this product, so its chemistry is not treated as established. The reading below is the lookup's own suggestion, not a product fact."
        case .selectedRegisterCandidateNotReVerified(let number):
            let identifier = number.map { " (\($0))" } ?? ""
            return "This product was listed by the official register during search\(identifier), but the strict identity check could not confirm the same registration. Nothing has been recorded as verified. Try selecting a different entry, or enter the product manually."
        case .registerUnavailable:
            return "The official register could not be reached, so nothing could be confirmed. Anything shown is unverified until the lookup succeeds."
        case .registerNotConsulted:
            return "No official register is available for this vineyard's country, so this product cannot be verified here."
        }
    }
}

nonisolated enum ChemicalEvidenceWithholding {
    /// Explain a lookup that came back with no established chemistry.
    ///
    /// Returns `nil` when there is nothing to explain — either the lookup
    /// established actives, or the resolver withheld nothing.
    ///
    /// - Parameters:
    ///   - discovery: the resolver's own account of what the register did.
    ///   - hasEstablishedActives: whether the canonical response carried actives.
    ///   - selectedSource: `ChemicalSearchResult.source` for the row the
    ///     operator picked.
    ///   - selectedRegistrationNumber: the number that row carried, if any.
    ///   - registerName: display name for the jurisdiction's register.
    static func reason(
        discovery: ChemicalDiscoveryEnvelope?,
        hasEstablishedActives: Bool,
        selectedSource: String?,
        selectedRegistrationNumber: String?,
        registerName: String? = nil
    ) -> ChemicalEvidenceWithholdingReason? {
        guard !hasEstablishedActives else { return nil }
        guard let discovery else { return nil }

        if discovery.wasCheckedAndUnverified {
            // An official-register row that will not re-verify is a different
            // event from an AI guess that never verified, and the operator
            // should not be given the same explanation for both.
            if selectedSource == ChemicalSearchResult.officialRegisterSource {
                return .selectedRegisterCandidateNotReVerified(
                    registrationNumber: selectedRegistrationNumber
                )
            }
            return .registerCheckedAndUnverified(registerName: registerName)
        }
        if discovery.wasUnavailable { return .registerUnavailable }
        if discovery.wasNeverConsulted { return .registerNotConsulted }
        return nil
    }
}
