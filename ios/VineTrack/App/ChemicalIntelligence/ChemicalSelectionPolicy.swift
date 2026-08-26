import Foundation

/// Whether the app may bind a product without asking, or must let the operator
/// choose (task Phase 8).
///
/// # The inference this replaces
///
/// The rule everyone reaches for is "one result means one answer". It is
/// wrong, and the way it is wrong is dangerous: a single row is produced just
/// as easily by *certainty* as by *starvation*. A query that matched one exact
/// registered product returns one row. So does a query that matched one
/// incidental word in one product's name because a contaminated alias was the
/// only thing that got through — which is precisely what
/// "Hortitrol winter oil" did, returning one confident-looking row for a
/// product whose registered name shares not a single word with the query.
///
/// The row count cannot tell those apart. Only the server can: it knows which
/// register the row came from, how the name scored against the query, and
/// whether anything else was credible enough to be a rival. So the app stops
/// inferring and starts reading.
///
/// # It fails closed
///
/// Every uncertainty — an absent ranking block, an older server, a malformed
/// payload, a row without a registration — resolves to `.requiresChoice`.
/// Showing a picker when one was not strictly needed costs a tap. Binding the
/// wrong registration costs a spray applied under the wrong withholding
/// period.
nonisolated enum ChemicalSelectionOutcome: Sendable, Equatable {
    /// The identity is proven. This exact candidate may be applied directly.
    case autoSelect(ChemicalSearchResult)
    /// A human must choose. Carries the candidates to show, in served order.
    case requiresChoice([ChemicalSearchResult])
    /// Nothing to choose from.
    case empty
}

nonisolated enum ChemicalSelectionPolicy {

    /// How many candidates a picker shows before it stops being a choice and
    /// starts being a list to wade through. The server ranks; the app shows
    /// the top of that ranking.
    static let maxPresentedCandidates: Int = 5

    /// Decide what to do with a search answer.
    ///
    /// Three conditions must ALL hold before the app binds a product on the
    /// operator's behalf. They are separate on purpose — each has failed
    /// independently in production:
    ///
    ///   1. the server says `auto_select_allowed`;
    ///   2. exactly one candidate is register- or catalogue-backed;
    ///   3. that candidate carries a registration number.
    ///
    /// (2) and (3) are not redundant with (1). They are the app refusing to
    /// bind something it could not identify even if the server said it was
    /// safe to — an answer with no registration number cannot be locked, and a
    /// lookup that cannot be locked is a lookup that can drift.
    static func decide(
        results: [ChemicalSearchResult],
        ranking: ChemicalSearchRankingSummary?
    ) -> ChemicalSelectionOutcome {
        guard !results.isEmpty else { return .empty }

        let presented = Array(results.prefix(maxPresentedCandidates))

        // (1) The server's verdict. Absent ranking = an older server = ask.
        guard ranking?.autoSelectAllowed == true else {
            return .requiresChoice(presented)
        }

        // (2) Exactly one authoritative candidate in the WHOLE answer, not
        //     just in the presented slice — a second register row hiding at
        //     position six is still a rival.
        let authoritative = results.filter(\.isAuthoritativeCandidate)
        guard authoritative.count == 1, let candidate = authoritative.first else {
            return .requiresChoice(presented)
        }

        // (3) It must be identifiable.
        let number = candidate.registrationNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !number.isEmpty else {
            return .requiresChoice(presented)
        }

        // If the server named an exact registration, it must be THIS one.
        // Disagreement between the two things the server told us is not a
        // tiebreak to resolve on device; it is a reason to ask.
        if let exact = ranking?.exactRegistrationNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !exact.isEmpty,
            exact.caseInsensitiveCompare(number) != .orderedSame {
            return .requiresChoice(presented)
        }

        return .autoSelect(candidate)
    }
}

/// What a candidate row shows an operator who has to choose.
///
/// Registered name, registration number, registrant, active ingredient,
/// category and vineyard relevance — the facts a viticulturist actually
/// decides on, all of which are printed on the drum in their hand.
///
/// Deliberately NOT a confidence percentage. A model's self-reported certainty
/// is not evidence, it cannot be checked against anything physical, and
/// presenting it as the primary signal invites the operator to defer to the
/// machine on exactly the decision the machine has already proven it can get
/// wrong.
nonisolated struct ChemicalCandidateSummary: Sendable, Equatable {
    let name: String
    /// e.g. "APVMA 33182". Empty when the row carries no registration.
    let registrationLabel: String
    let registrant: String
    let activeIngredient: String
    let category: String
    /// Grapevine relevance in the label's terms, or nil when unknown.
    let grapevineNote: String?

    init(result: ChemicalSearchResult, country: String = "") {
        name = result.name
        let number = result.registrationNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if number.isEmpty {
            registrationLabel = ""
        } else {
            let scheme = ChemicalCandidateSummary.schemeLabel(
                result.registrationScheme,
                country: result.countryCode ?? country
            )
            registrationLabel = scheme.isEmpty ? number : "\(scheme) \(number)"
        }
        registrant = (result.registrant ?? result.brand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        activeIngredient = result.activeIngredient
            .trimmingCharacters(in: .whitespacesAndNewlines)
        category = (result.productCategory ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Three states, three sentences. "Unknown" is silent rather than
        // negative: a register listing carries no use table, and drawing that
        // as "no grapevine uses" would libel a product that has plenty.
        switch result.hasGrapevineUse {
        case .some(true): grapevineNote = "Grapevine uses found"
        case .some(false): grapevineNote = "No grapevine uses found"
        case .none: grapevineNote = nil
        }
    }

    /// The register's display name for a scheme code.
    private static func schemeLabel(_ scheme: String?, country: String) -> String {
        let raw = (scheme ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !raw.isEmpty { return raw.uppercased() }
        // Fall back to the country's register only when the row named no
        // scheme — never override one it did name.
        switch country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "AU": return "APVMA"
        case "NZ": return "ACVM"
        default: return ""
        }
    }
}
