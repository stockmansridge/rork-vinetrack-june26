import Foundation

/// The decision sequence the Re-verify Chemical screen runs.
///
/// This exists so the screen holds no logic of its own. A SwiftUI view cannot be
/// asserted on in this environment, and a rule that lives only inside a view is a
/// rule that drifts — so everything between "the lookup replied" and "this is the
/// record we would write" lives here, and both the view and the tests drive the
/// same code.
///
/// Nothing here writes anything. Every function is a pure transformation, which is
/// what makes Cancel safe by construction: cancelling simply means never calling
/// `accepted(_:with:)` or `confirmed(_:with:)`.
///
/// Mirrors `ChemicalReverifyFlow.kt` on Android.
nonisolated enum ChemicalReverifyFlow {

    /// What the operator should be shown after a successful lookup.
    nonisolated enum Result {
        /// Nothing about the product moved. `refreshed` is the evidence-only
        /// update to store, or `nil` when the record holds no structured
        /// intelligence — a no-change result must never become a record's FIRST
        /// structured write by materialising its legacy seed.
        case current(candidate: ChemicalIntelligence, refreshed: ChemicalIntelligence?)
        /// Something moved. `outcome` is reconciled once and both previewed and
        /// written, so the operator accepts exactly what they reviewed.
        case changes(
            candidate: ChemicalIntelligence,
            diff: ChemicalIntelligenceDiff,
            outcome: ChemicalEditOutcome
        )
        /// The lookup replied, but with nothing that can be acted on.
        case unusable(String)
    }

    static let noResultReason =
        "The register did not return usable information for this product."

    /// What the Chemical Store currently DISPLAYS for this product.
    ///
    /// The resolved value, not the raw stored column: the diff has to be measured
    /// against what the operator can actually see, or a legacy record that plainly
    /// reads "Azoxystrobin" would be told Azoxystrobin is being added.
    static func currentIntelligence(_ chemical: SavedChemical) -> ChemicalIntelligence? {
        let resolved = chemical.resolvedIntelligence
        return resolved.isEmpty ? nil : resolved
    }

    /// Classify a lookup candidate against the stored record.
    static func resolve(
        chemical: SavedChemical,
        candidate: ChemicalIntelligence,
        at date: Date = Date()
    ) -> Result {
        // An empty candidate is a FAILED check, not a product that has lost its
        // chemistry. Diffing it would propose deleting every active on the record.
        guard !candidate.isEmpty else { return .unusable(noResultReason) }

        let current = currentIntelligence(chemical)
        let diff = ChemicalIntelligenceDiffer.diff(current: current, candidate: candidate)

        if ChemicalReverification.isNoChangeResult(diff) {
            let stored = chemical.chemicalIntelligence
            let refreshed: ChemicalIntelligence?
            if let stored, !stored.isEmpty {
                refreshed = ChemicalReverification.confirmingCurrent(
                    current: stored,
                    candidate: candidate,
                    at: date
                )
            } else {
                refreshed = nil
            }
            return .current(candidate: candidate, refreshed: refreshed)
        }

        return .changes(
            candidate: candidate,
            diff: diff,
            outcome: ChemicalReverification.apply(
                candidate: candidate,
                to: current,
                at: date
            )
        )
    }

    /// The record as it will stand after an accepted update.
    ///
    /// Routed through `ChemicalReverification.updated`, so the structured values
    /// come from the reconciled outcome and the legacy scalars are re-derived from
    /// it. No spray record is read or written here, which is precisely why
    /// accepting an update cannot rewrite history.
    static func accepted(
        _ chemical: SavedChemical,
        with outcome: ChemicalEditOutcome
    ) -> SavedChemical {
        ChemicalReverification.updated(chemical, with: outcome)
    }

    /// The record after confirming a no-change result: refreshed evidence only.
    static func confirmed(
        _ chemical: SavedChemical,
        with refreshed: ChemicalIntelligence
    ) -> SavedChemical {
        var result = chemical
        result.chemicalIntelligence = refreshed
        return result
    }
}
