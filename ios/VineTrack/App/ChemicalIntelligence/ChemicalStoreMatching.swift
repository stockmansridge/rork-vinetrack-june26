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
}
