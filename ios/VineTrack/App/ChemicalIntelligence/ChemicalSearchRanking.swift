import Foundation

/// Where a search row sits in the order, and why.
///
/// Search is DISCOVERY: one list mixes the vineyard's own store, the approved
/// master catalogue, official-register candidates and model suggestions. An
/// operator who cannot tell those apart has no way to anticipate which one will
/// survive verification, so the tier is both the sort key and the label.
nonisolated enum ChemicalSearchTier: Int, Sendable, Comparable, CaseIterable {
    /// Already in this vineyard's Chemical Store. Shown first to stop the
    /// operator creating a second copy of a product they already stock.
    case alreadyInStore = 0
    /// An APPROVED master catalogue product for this vineyard's country.
    case approvedMaster = 1
    /// A candidate from the jurisdiction's official register.
    case officialRegister = 2
    /// Everything else, including model suggestions and any master row that
    /// failed the approval or country test.
    case suggestion = 3

    static func < (lhs: ChemicalSearchTier, rhs: ChemicalSearchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .alreadyInStore: return "In your Chemical Store"
        case .approvedMaster: return "VineTrack Master catalogue"
        case .officialRegister: return "Official register"
        case .suggestion: return "Unverified suggestion"
        }
    }
}

/// One ranked search row.
nonisolated struct ChemicalSearchRow: Identifiable, Sendable, Hashable {
    let result: ChemicalSearchResult
    let tier: ChemicalSearchTier
    /// The vineyard's existing record this row matches, when it matches one.
    let existing: SavedChemical?

    var id: String { result.id }

    /// True when selecting this row would edit a product the vineyard already
    /// has, rather than add a new one.
    var isDuplicate: Bool { existing != nil }
}

/// Orders chemical search results.
///
/// # The rule
///
/// ```text
/// A. an exact match already in this vineyard's Chemical Store
/// B. an APPROVED master catalogue product for this vineyard's country
/// C. official-register candidates
/// D. everything else
/// ```
///
/// # What it refuses to do
///
/// A master row is only treated as a master when it is BOTH approved and
/// registered in the vineyard's own country. A candidate row is an unreviewed
/// draft — sql/199 seeds them deliberately — and presenting one as a verified
/// catalogue product would mean the word "verified" had been earned by nothing.
/// A retired row is a product that was withdrawn. An AU master shown to an NZ
/// vineyard is a different registration with different label law.
///
/// In all three cases the row is not hidden — it may still be the product on
/// the drum — it simply loses the authority it did not earn and sorts with the
/// ordinary suggestions.
///
/// Zero approved masters is the expected state today and is NOT a failure: tier
/// B is empty and the list is register candidates and suggestions, in that
/// order.
nonisolated enum ChemicalSearchRanking {

    static func ordered(
        results: [ChemicalSearchResult],
        savedChemicals: [SavedChemical],
        vineyardCountry: String
    ) -> [ChemicalSearchRow] {
        let country = ChemicalRegistration.normaliseCountry(vineyardCountry)
        let rows = results.map { result -> ChemicalSearchRow in
            let existing = existingMatch(for: result, in: savedChemicals)
            return ChemicalSearchRow(
                result: result,
                tier: tier(for: result, vineyardCountry: country, isInStore: existing != nil),
                existing: existing
            )
        }
        // Stable within a tier: the server already ordered by its own relevance
        // and re-sorting on name would throw that away.
        return rows.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.tier != rhs.element.tier { return lhs.element.tier < rhs.element.tier }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func tier(
        for result: ChemicalSearchResult,
        vineyardCountry: String,
        isInStore: Bool
    ) -> ChemicalSearchTier {
        if isInStore { return .alreadyInStore }
        if result.source == ChemicalSearchResult.masterSource {
            return isUsableMaster(result, vineyardCountry: vineyardCountry)
                ? .approvedMaster
                : .suggestion
        }
        if result.source == ChemicalSearchResult.officialRegisterSource { return .officialRegister }
        return .suggestion
    }

    /// Whether a master row may be presented with catalogue authority.
    ///
    /// Both tests must pass. Absent metadata is read as "the server already
    /// applied its own rule": sql/199's RLS only returns approved rows to
    /// ordinary users, and search is country-scoped at the request. This client
    /// check exists so a server that starts sending the fields — or a future
    /// one that relaxes either rule — cannot quietly promote a row here.
    static func isUsableMaster(
        _ result: ChemicalSearchResult,
        vineyardCountry: String
    ) -> Bool {
        if let status = result.reviewStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !status.isEmpty,
           status != "approved" {
            return false
        }
        let country = ChemicalRegistration.normaliseCountry(vineyardCountry)
        if let rowCountry = result.countryCode.map(ChemicalRegistration.normaliseCountry),
           !rowCountry.isEmpty,
           !country.isEmpty,
           rowCountry != country {
            return false
        }
        return true
    }

    /// The vineyard's own record for this product, if it has one.
    ///
    /// Registration identity first — that is the only exact answer. A name
    /// comparison is a fallback for the many records that predate structured
    /// identity, and is deliberately strict (case- and whitespace-insensitive
    /// equality, never a substring) because a loose match here would offer to
    /// overwrite the wrong product.
    static func existingMatch(
        for result: ChemicalSearchResult,
        in savedChemicals: [SavedChemical]
    ) -> SavedChemical? {
        if let number = result.registrationNumber?.trimmedNonEmpty {
            let byIdentity = savedChemicals.first { chemical in
                chemical.chemicalIntelligence?.registration?.registrationNumber?.trimmedNonEmpty == number
            }
            if let byIdentity { return byIdentity }
        }
        guard let name = result.name.trimmedNonEmpty?.lowercased() else { return nil }
        return savedChemicals.first { $0.name.trimmedNonEmpty?.lowercased() == name }
    }
}
