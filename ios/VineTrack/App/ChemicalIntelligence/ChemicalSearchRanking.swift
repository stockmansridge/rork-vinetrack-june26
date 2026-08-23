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
    /// A row whose only connection to the query is an incidental word buried in
    /// its registered name, shown BELOW everything else because a strong,
    /// exact candidate also exists.
    case weakMatch = 4

    static func < (lhs: ChemicalSearchTier, rhs: ChemicalSearchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .alreadyInStore: return "In your Chemical Store"
        case .approvedMaster: return "VineTrack Master catalogue"
        case .officialRegister: return "Official register"
        case .suggestion: return "Unverified suggestion"
        case .weakMatch: return "Other register matches"
        }
    }
}

/// How well a candidate's NAME answers the query.
///
/// # Why name relevance is scored on the client, deterministically
///
/// The APVMA register is a legal list, not a vineyard catalogue: it contains
/// household insecticides, veterinary medicines and technical-grade actives
/// alongside SWITCH FUNGICIDE. Its full-text search matches whole words in ANY
/// column, so a query of "Switch" legitimately returns both `SWITCH FUNGICIDE`
/// and `MORTEIN PEACEFUL NIGHTS … WITH AUTO SWITCH OFF TECHNOLOGY`. The
/// register is not wrong; presenting the two side by side as equal candidates
/// is.
///
/// This is deliberately a string rule and NOT a classifier. Nothing here asks a
/// model what a product is for, because search must give the same answer for
/// the same query every time — and because a rule that decided which products
/// were "mainstream enough" would quietly bury the regional adjuvants,
/// biostimulants and fertilisers a vineyard actually buys.
nonisolated enum ChemicalNameRelevance: Int, Sendable, Comparable, CaseIterable {
    /// The registered name IS the query.
    case exactName = 0
    /// The query is the leading run of the name and everything after it is a
    /// formulation word: `Chateau` → `CHATEAU HERBICIDE`, `Switch` →
    /// `SWITCH FUNGICIDE`.
    case leadingProductName = 1
    /// The query starts the name, but the remainder is not a formulation word:
    /// `Kocide` → `KOCIDE BLUE XTRA`.
    case leadingToken = 2
    /// The query's words appear as whole words, contiguously, somewhere other
    /// than the start: `Copper` → `TRI-BASE BLUE COPPER FUNGICIDE`.
    case containedPhrase = 3
    /// The query's words appear, but scattered or only as a fragment. This is
    /// where `…AUTO SWITCH OFF TECHNOLOGY` lands.
    case incidental = 4
    /// No name connection at all — matched on the holder, the active or the
    /// formulation text.
    case unrelated = 5

    static func < (lhs: ChemicalNameRelevance, rhs: ChemicalNameRelevance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether a row at this relevance may stand as a primary candidate.
    ///
    /// `containedPhrase` counts as strong: "copper" genuinely describes
    /// `TRI-BASE BLUE COPPER FUNGICIDE`, and demoting it would hide the
    /// products an operator searching by chemistry is looking for.
    var isStrong: Bool { self <= .containedPhrase }
}

/// Words that describe a product's FORM rather than its identity, so
/// `CHATEAU HERBICIDE` still reads as the product "Chateau".
private let formulationTokens: Set<String> = [
    "herbicide", "fungicide", "insecticide", "miticide", "acaricide",
    "nematicide", "bactericide", "molluscicide", "rodenticide",
    "adjuvant", "surfactant", "wetter", "spreader", "sticker", "penetrant",
    "fertiliser", "fertilizer", "biostimulant", "inoculant",
    "concentrate", "solution", "suspension", "emulsion",
    "wg", "wp", "sc", "ec", "sl", "df", "wdg", "ew", "od", "me", "cs", "gr",
    "granules", "granule", "liquid", "dust", "powder", "spray", "plus",
    "product", "technical", "grade"
]

nonisolated enum ChemicalNameRelevanceScorer {

    /// Splits a name into lowercased alphanumeric word tokens.
    static func tokens(_ value: String) -> [String] {
        value
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func score(query: String, name: String) -> ChemicalNameRelevance {
        let queryTokens = tokens(query)
        let nameTokens = tokens(name)
        guard !queryTokens.isEmpty, !nameTokens.isEmpty else { return .unrelated }

        if queryTokens == nameTokens { return .exactName }

        if nameTokens.count > queryTokens.count,
           Array(nameTokens.prefix(queryTokens.count)) == queryTokens {
            let remainder = nameTokens.dropFirst(queryTokens.count)
            return remainder.allSatisfy(formulationTokens.contains)
                ? .leadingProductName
                : .leadingToken
        }

        // The query's whole words, contiguously, somewhere inside the name.
        if containsRun(nameTokens, queryTokens) { return .containedPhrase }

        // Every query word present as a whole word, but not contiguously, OR a
        // single query word appearing anywhere that is not the start. Both are
        // incidental: the operator's word is in there, but the name is not
        // about it.
        if queryTokens.allSatisfy(nameTokens.contains) { return .incidental }

        // A fragment: the query is a prefix of some token (`chat` → `chateau`).
        if queryTokens.count == 1,
           let first = queryTokens.first,
           nameTokens.contains(where: { $0.hasPrefix(first) || first.hasPrefix($0) }) {
            return .incidental
        }

        return .unrelated
    }

    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}

/// One ranked search row.
nonisolated struct ChemicalSearchRow: Identifiable, Sendable, Hashable {
    let result: ChemicalSearchResult
    let tier: ChemicalSearchTier
    /// The vineyard's existing record this row matches, when it matches one.
    let existing: SavedChemical?
    /// How well the registered name answers the query.
    let relevance: ChemicalNameRelevance

    init(
        result: ChemicalSearchResult,
        tier: ChemicalSearchTier,
        existing: SavedChemical?,
        relevance: ChemicalNameRelevance = .exactName
    ) {
        self.result = result
        self.tier = tier
        self.existing = existing
        self.relevance = relevance
    }

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
/// C. official-register candidates, best NAME match first
/// D. everything else
/// E. incidental word matches, only ever below a strong candidate
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
/// the drum — it simply loses the authority it did not earn.
///
/// Nothing is ever REMOVED. Demotion moves a row to its own labelled section;
/// an operator searching for a regional adjuvant by a generic word still finds
/// it, just below the product whose name they actually typed.
nonisolated enum ChemicalSearchRanking {

    static func ordered(
        results: [ChemicalSearchResult],
        savedChemicals: [SavedChemical],
        vineyardCountry: String,
        query: String = ""
    ) -> [ChemicalSearchRow] {
        let country = ChemicalRegistration.normaliseCountry(vineyardCountry)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let scored = results.map { result -> ChemicalSearchRow in
            let existing = existingMatch(for: result, in: savedChemicals)
            let relevance = trimmedQuery.isEmpty
                ? ChemicalNameRelevance.exactName
                : ChemicalNameRelevanceScorer.score(query: trimmedQuery, name: result.name)
            return ChemicalSearchRow(
                result: result,
                tier: tier(for: result, vineyardCountry: country, isInStore: existing != nil),
                existing: existing,
                relevance: relevance
            )
        }

        // Demotion is CONDITIONAL. With no strong candidate the operator's only
        // lead may well be a weak one, and hiding it would leave them with an
        // empty screen for a product that is genuinely in the register.
        let hasStrongCandidate = scored.contains { $0.relevance.isStrong }
        let rows = scored.map { row -> ChemicalSearchRow in
            guard hasStrongCandidate,
                  !row.relevance.isStrong,
                  row.tier == .officialRegister || row.tier == .suggestion
            else { return row }
            return ChemicalSearchRow(
                result: row.result,
                tier: .weakMatch,
                existing: row.existing,
                relevance: row.relevance
            )
        }

        // Within a tier: best name match first, then the server's own order —
        // it already ranked by its register match and re-sorting on name
        // alphabetically would throw that away.
        return rows.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.tier != rhs.element.tier { return lhs.element.tier < rhs.element.tier }
                if lhs.element.relevance != rhs.element.relevance {
                    return lhs.element.relevance < rhs.element.relevance
                }
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
