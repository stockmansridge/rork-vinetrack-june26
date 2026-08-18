import Foundation

/// How much VineTrack trusts a chemical's resistance-critical information.
///
/// This is deliberately separate from "did the lookup return anything". An AI
/// answer is a lead, not a verification: a product only becomes `.verified`
/// when an authoritative source stands behind its identity AND behind every
/// active's activity group.
nonisolated enum ChemicalVerificationStatus: String, Codable, Sendable, CaseIterable, Hashable {
    /// Product identity and every active's activity group are confirmed
    /// against authoritative sources.
    case verified
    /// Product identity is established, but at least one resistance-relevant
    /// field is still unconfirmed.
    case partiallyVerified = "partially_verified"
    /// Operator-entered or legacy data, or too little evidence to classify.
    case unverified
    /// A legacy record that has never been put through the match step. It has
    /// data, but nobody has yet confirmed WHICH registered product it is.
    case needsMatch = "needs_match"
    /// Sources disagree about a resistance-critical field. Never silently
    /// resolved — a human decides.
    case conflict

    nonisolated var label: String {
        switch self {
        case .verified: return "Verified"
        case .partiallyVerified: return "Partially verified"
        case .unverified: return "Unverified"
        case .needsMatch: return "Needs match"
        case .conflict: return "Verification conflict"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .verified:
            return "Product identity and activity groups confirmed against authoritative sources."
        case .partiallyVerified:
            return "Product identified, but some resistance information is still unconfirmed."
        case .unverified:
            return "Entered manually or carried over from an older record. Not confirmed against a label."
        case .needsMatch:
            return "Not yet matched to a registered product for this country."
        case .conflict:
            return "Sources disagree. Resolve before relying on this product's resistance information."
        }
    }

    /// Whether the future Resistance Engine may treat this product's groups as
    /// dependable without warning the operator.
    nonisolated var isResistanceDependable: Bool { self == .verified }

    /// Ranking used when merging: a merge may only ever LOWER confidence.
    nonisolated var confidenceRank: Int {
        switch self {
        case .verified: return 4
        case .partiallyVerified: return 3
        case .needsMatch: return 2
        case .unverified: return 1
        case .conflict: return 0
        }
    }
}

/// A specific disagreement between two sources about one field.
///
/// Surfaced to the operator verbatim — VineTrack does not pick a winner, and
/// it certainly does not quietly keep the AI's answer.
nonisolated struct ChemicalVerificationConflict: Codable, Sendable, Hashable, Identifiable {
    /// Which field disagrees, e.g. `"activity_group"`, `"concentration"`.
    let field: String
    /// The active ingredient the disagreement concerns, when field-specific.
    let activeIngredientName: String?
    /// What the label/AI extraction claimed.
    let extractedValue: String
    /// What the authoritative classification says.
    let authoritativeValue: String
    /// Source that produced `extractedValue`.
    let extractedSource: ChemicalDataSourceKind
    /// Source that produced `authoritativeValue`.
    let authoritativeSource: ChemicalDataSourceKind

    nonisolated var id: String {
        "\(field)|\(activeIngredientName ?? "")|\(extractedValue)|\(authoritativeValue)"
    }

    init(
        field: String,
        activeIngredientName: String? = nil,
        extractedValue: String,
        authoritativeValue: String,
        extractedSource: ChemicalDataSourceKind = .aiInterpretation,
        authoritativeSource: ChemicalDataSourceKind = .authoritativeClassification
    ) {
        self.field = field
        self.activeIngredientName = activeIngredientName
        self.extractedValue = extractedValue
        self.authoritativeValue = authoritativeValue
        self.extractedSource = extractedSource
        self.authoritativeSource = authoritativeSource
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case field
        case activeIngredientName = "active_ingredient_name"
        case extractedValue = "extracted_value"
        case authoritativeValue = "authoritative_value"
        case extractedSource = "extracted_source"
        case authoritativeSource = "authoritative_source"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decodeIfPresent(String.self, forKey: .field) ?? ""
        activeIngredientName = try c.decodeIfPresent(String.self, forKey: .activeIngredientName)
        extractedValue = try c.decodeIfPresent(String.self, forKey: .extractedValue) ?? ""
        authoritativeValue = try c.decodeIfPresent(String.self, forKey: .authoritativeValue) ?? ""
        let ex = try c.decodeIfPresent(String.self, forKey: .extractedSource) ?? ""
        extractedSource = ChemicalDataSourceKind(rawValue: ex) ?? .aiInterpretation
        let au = try c.decodeIfPresent(String.self, forKey: .authoritativeSource) ?? ""
        authoritativeSource = ChemicalDataSourceKind(rawValue: au) ?? .authoritativeClassification
    }

    /// One-line operator-facing summary.
    nonisolated var summary: String {
        let subject = activeIngredientName.map { "\($0): " } ?? ""
        return "\(subject)\(extractedSource.label) says \(extractedValue); "
            + "\(authoritativeSource.label) says \(authoritativeValue)."
    }
}

/// The full verification picture for one chemical.
nonisolated struct ChemicalVerification: Codable, Sendable, Hashable {
    /// The stored status. Prefer `resolvedStatus(actives:hasRegistration:)`
    /// when deciding what to trust — it re-derives the claim from the evidence
    /// rather than believing a status somebody wrote down.
    var status: ChemicalVerificationStatus
    /// Every source consulted.
    var sources: [ChemicalDataSource]
    /// When verification last ran.
    var verifiedAt: Date?
    /// Unresolved disagreements. Non-empty forces `.conflict`.
    var conflicts: [ChemicalVerificationConflict]
    /// Fields the lookup explicitly could not resolve, named so the UI can
    /// show what is missing instead of an unexplained blank.
    var unresolvedFields: [String]

    init(
        status: ChemicalVerificationStatus = .unverified,
        sources: [ChemicalDataSource] = [],
        verifiedAt: Date? = nil,
        conflicts: [ChemicalVerificationConflict] = [],
        unresolvedFields: [String] = []
    ) {
        self.status = status
        self.sources = sources
        self.verifiedAt = verifiedAt
        self.conflicts = conflicts
        self.unresolvedFields = unresolvedFields
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case status, sources, conflicts
        case verifiedAt = "verified_at"
        case unresolvedFields = "unresolved_fields"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        // An unknown status from a newer build degrades to unverified. Erring
        // downward is the only safe direction for a trust claim.
        status = ChemicalVerificationStatus(rawValue: raw) ?? .unverified
        sources = try c.decodeIfPresent([ChemicalDataSource].self, forKey: .sources) ?? []
        // ISO-8601 string on the wire (edge function/portal), Date under a
        // strategy-configured decoder, or null — all must decode.
        verifiedAt = ChemicalWireDate.decode(from: c, key: .verifiedAt)
        conflicts = try c.decodeIfPresent([ChemicalVerificationConflict].self, forKey: .conflicts) ?? []
        unresolvedFields = try c.decodeIfPresent([String].self, forKey: .unresolvedFields) ?? []
    }

    /// The status the EVIDENCE supports, which may be lower than `status`.
    ///
    /// This is the gate that makes Phase 7 structural rather than advisory: a
    /// record can carry `status == .verified`, but if a conflict is present or
    /// an active's group is unconfirmed, this returns `.conflict` or
    /// `.partiallyVerified` and the product is not treated as dependable.
    /// Confidence can only ever be lowered here, never raised.
    func resolvedStatus(
        actives: [ChemicalActiveIngredient],
        hasRegistration: Bool
    ) -> ChemicalVerificationStatus {
        if !conflicts.isEmpty { return .conflict }
        if actives.isEmpty {
            return status == .needsMatch ? .needsMatch : .unverified
        }
        let everyGroupAuthoritative = actives.allSatisfy(\.hasAuthoritativeGroup)

        if status == .verified,
           everyGroupAuthoritative,
           hasRegistration,
           sources.containsAuthoritative,
           unresolvedFields.isEmpty {
            return .verified
        }

        // Partially verified means "we know WHICH product this is, but something
        // about it is still unconfirmed". It therefore requires real evidence:
        // an authoritative registered identity, an authoritative cited source, or
        // an active whose group an authoritative classification stands behind.
        //
        // Merely HAVING a group is not enough. A chemical someone typed by hand
        // has a group because they typed one, and that must stay Unverified —
        // otherwise manual entry quietly launders itself into partial trust.
        let hasAuthoritativeEvidence = hasRegistration
            || sources.containsAuthoritative
            || actives.contains(where: \.hasAuthoritativeGroup)

        if hasAuthoritativeEvidence {
            return status == .needsMatch ? .needsMatch : .partiallyVerified
        }
        return status == .needsMatch ? .needsMatch : .unverified
    }

    /// Records a disagreement and drops the status to `.conflict`.
    mutating func addConflict(_ conflict: ChemicalVerificationConflict) {
        guard !conflicts.contains(conflict) else { return }
        conflicts.append(conflict)
        status = .conflict
    }

    /// Verification state for a chemical the operator typed in themselves.
    static func manual() -> ChemicalVerification {
        ChemicalVerification(
            status: .unverified,
            sources: [ChemicalDataSource(kind: .manualEntry, name: "Entered in VineTrack")],
            verifiedAt: nil
        )
    }

    /// Verification state for a pre-Chemical-Intelligence record. It is not
    /// "unverified because it's wrong" — it simply has never been matched to a
    /// registered product, and the audit needs to be able to tell those apart.
    static func legacy() -> ChemicalVerification {
        ChemicalVerification(
            status: .needsMatch,
            sources: [ChemicalDataSource(kind: .legacyRecord, name: "Existing VineTrack chemical")],
            verifiedAt: nil
        )
    }
}
