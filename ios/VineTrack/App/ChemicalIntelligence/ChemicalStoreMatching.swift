import Foundation

/// The decisions the Search → Match → Verify → Confirm wizard makes when it
/// lands a product in the Chemical Store.
///
/// These live beside the models rather than inside the SwiftUI flow because
/// they are the rules that protect the store from corruption — duplicate
/// registrations silently merging two chemistries — and rules that matter that
/// much need to be tested directly rather than inferred from a screenshot of a
/// sheet. Mirrors `ChemicalStoreMatching.kt` on Android.
nonisolated enum ChemicalStoreMatching {

    /// Find an existing chemical that is THE SAME REGISTERED PRODUCT as
    /// `registration`.
    ///
    /// Identity is the country-scoped registration key (e.g. `AU:apvma:66541`)
    /// and nothing else. Name similarity is deliberately not consulted: two
    /// genuinely different registrations can carry near-identical marketing
    /// names ("Custodia" vs "Custodia Forte"), and the same registration is
    /// the same product no matter how the operator typed it. Fuzzy matching
    /// here would silently merge two chemicals, which in a resistance context
    /// means silently merging two chemistries.
    ///
    /// Returns `nil` when the candidate has no registration identity at all —
    /// an unregistered entry cannot be proven to duplicate anything, so the
    /// operator is left in control rather than being blocked by a guess.
    ///
    /// - Parameter excludingId: the record being updated in place, which must
    ///   never count as a duplicate of itself.
    static func findByRegistrationIdentity(
        in chemicals: [SavedChemical],
        registration: ChemicalRegistration?,
        excludingId: UUID? = nil
    ) -> SavedChemical? {
        guard let key = registration?.identityKey else { return nil }
        return chemicals.first { chemical in
            chemical.id != excludingId
                && chemical.resolvedIntelligence.registration?.identityKey == key
        }
    }

    // MARK: - Pre-research duplicate decision (item 5)

    /// Normalised form of a product name for SAME-PRODUCT comparison.
    ///
    /// Case, punctuation and run-together spacing are noise a grower should
    /// never be punished for: `"Kocide Blue Xtra"`, `"KOCIDE BLUE XTRA"` and
    /// `"Kocide-Blue Xtra"` are one product typed three ways. Pack-size and
    /// volume suffixes are deliberately NOT stripped, because `"Product 5 L"`
    /// and `"Product 20 L"` may be genuinely different registrations.
    static func normalisedName(_ raw: String) -> String {
        let scalars = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Whether two product names are the same or materially matching.
    ///
    /// Exact match after normalisation, or one name being a whole-token prefix
    /// of the other — which is how `"Kocide Blue"` finds the stored
    /// `"Kocide Blue Xtra"`. Deliberately NOT a fuzzy/edit-distance test: this
    /// decision only ever OFFERS a choice, and a false positive that pushes an
    /// operator toward the wrong existing record is worse than asking twice.
    static func namesMateriallyMatch(_ a: String, _ b: String) -> Bool {
        let left = normalisedName(a)
        let right = normalisedName(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let leftTokens = left.split(separator: " ").map(String.init)
        let rightTokens = right.split(separator: " ").map(String.init)
        let shorter = leftTokens.count <= rightTokens.count ? leftTokens : rightTokens
        let longer = leftTokens.count <= rightTokens.count ? rightTokens : leftTokens
        // A single token is too weak to claim a match on its own: "Blue" must
        // not adopt "Blue Shield".
        guard shorter.count >= 2 else { return false }
        return Array(longer.prefix(shorter.count)) == shorter
    }

    /// Existing chemicals whose name is the same or materially matching.
    ///
    /// Consulted BEFORE any remote lookup runs. The old order — research
    /// first, detect the duplicate on the confirm screen — spent the expensive
    /// call and the operator's wait before telling them they already owned the
    /// product, and left a half-finished record on screen if they backed out.
    ///
    /// Ordered so an exact name match leads, because that is the record the
    /// operator is most likely to have meant.
    static func findByProductName(
        in chemicals: [SavedChemical],
        query: String,
        excludingId: UUID? = nil
    ) -> [SavedChemical] {
        let normalisedQuery = normalisedName(query)
        guard !normalisedQuery.isEmpty else { return [] }
        let matches = chemicals.filter {
            $0.id != excludingId && namesMateriallyMatch($0.name, query)
        }
        // Exact name matches lead. Written as a stable partition rather than a
        // `sorted` predicate because "exact before inexact" is not a strict
        // weak ordering, and an unstable sort would reorder equal records
        // between redraws — which on this screen means the row an operator was
        // reaching for moves under their thumb.
        let exact = matches.filter { normalisedName($0.name) == normalisedQuery }
        let partial = matches.filter { normalisedName($0.name) != normalisedQuery }
        return exact + partial
    }

    /// The decision the operator is offered before research begins.
    ///
    /// Modelled as data rather than as sheet state so the "declining costs
    /// nothing" rule is testable: `.reviewExisting` and `.cancelled` both mean
    /// NO research call and NO write.
    enum Decision: Equatable, Sendable {
        /// Nothing matched; go straight to the register search.
        case proceed
        /// Open the record the operator already owns. Never researches.
        case reviewExisting(SavedChemical.ID)
        /// Deliberately create/search for a separate product.
        case createSeparate
        /// Backed out. Must cost exactly nothing.
        case cancelled
    }

    /// Whether this decision permits a remote chemical lookup to start.
    ///
    /// The acceptance rule in one place: only `.proceed` and `.createSeparate`
    /// may reach the network. Reviewing an existing record reads what is
    /// already stored, and cancelling does nothing at all.
    static func permitsResearch(_ decision: Decision) -> Bool {
        switch decision {
        case .proceed, .createSeparate: return true
        case .reviewExisting, .cancelled: return false
        }
    }

    /// Whether this decision permits any write to the Chemical Store.
    ///
    /// Separate from `permitsResearch` on purpose: "no network" and "no write"
    /// are two distinct promises, and the acceptance test checks both.
    static func permitsWrite(_ decision: Decision) -> Bool {
        switch decision {
        case .proceed, .createSeparate: return true
        case .reviewExisting, .cancelled: return false
        }
    }
}
