package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.model.SavedChemical

/**
 * The decision sequence the Re-verify Chemical screen runs.
 *
 * This exists so the screen holds no logic of its own. A Compose sheet cannot be
 * asserted on in a unit test, and a rule that lives only inside a sheet is a rule
 * that drifts — so everything between "the lookup replied" and "this is the row we
 * would write" lives here, and both the sheet and the tests drive the same code.
 *
 * Nothing here writes anything. Every function is a pure transformation, which is
 * what makes Cancel safe by construction: cancelling simply means never calling
 * [acceptedInput] or [confirmedInput].
 *
 * Mirrors iOS `ChemicalReverifyFlow`.
 */
object ChemicalReverifyFlow {

    /** What the operator should be shown after a successful lookup. */
    sealed interface Result {
        /**
         * Nothing about the product moved. [refreshed] is the evidence-only update
         * to store, or null when the record holds no structured intelligence — a
         * no-change result must never become a record's FIRST structured write by
         * materialising its legacy seed.
         */
        data class Current(
            val candidate: ChemicalIntelligence,
            val refreshed: ChemicalIntelligence?,
        ) : Result

        /**
         * Something moved. [outcome] is reconciled once and both previewed and
         * written, so the operator accepts exactly what they reviewed.
         */
        data class Changes(
            val candidate: ChemicalIntelligence,
            val diff: ChemicalIntelligenceDiff,
            val outcome: ChemicalEditOutcome,
        ) : Result

        /** The lookup replied, but with nothing that can be acted on. */
        data class Unusable(val reason: String) : Result
    }

    const val NO_RESULT_REASON: String =
        "The register did not return usable information for this product."

    /**
     * What the Chemical Store currently DISPLAYS for this product.
     *
     * The resolved value, not the raw columns: the diff has to be measured against
     * what the operator can actually see, or a legacy record that plainly reads
     * "Azoxystrobin" would be told Azoxystrobin is being added.
     */
    fun currentIntelligence(chemical: SavedChemical): ChemicalIntelligence? =
        chemical.resolvedIntelligence.takeIf { !it.isEmpty }

    /**
     * Classify a lookup candidate against the stored record.
     *
     * @param at timestamp stamped onto refreshed evidence and reconciled citations.
     */
    fun resolve(
        chemical: SavedChemical,
        candidate: ChemicalIntelligence,
        at: String? = null,
    ): Result {
        // An empty candidate is a FAILED check, not a product that has lost its
        // chemistry. Diffing it would propose deleting every active on the record.
        if (candidate.isEmpty) return Result.Unusable(NO_RESULT_REASON)

        val current = currentIntelligence(chemical)
        val diff = ChemicalIntelligenceDiffer.diff(current, candidate)

        if (ChemicalReverification.isNoChangeResult(diff)) {
            val stored = chemical.storedIntelligence?.takeIf { !it.isEmpty }
            return Result.Current(
                candidate = candidate,
                refreshed = stored?.let {
                    ChemicalReverification.confirmingCurrent(
                        current = it,
                        candidate = candidate,
                        at = at,
                    )
                },
            )
        }

        return Result.Changes(
            candidate = candidate,
            diff = diff,
            outcome = ChemicalReverification.apply(
                candidate = candidate,
                current = current,
                at = at,
            ),
        )
    }

    /** The record as it will stand after an accepted update. */
    fun acceptedChemical(chemical: SavedChemical, outcome: ChemicalEditOutcome): SavedChemical =
        ChemicalReverification.updated(chemical, outcome)

    /**
     * The write payload for an accepted update.
     *
     * Routed through [ChemicalReverification.updated] and then
     * [ChemicalStoreMatching.inputFor], so the structured columns come from the
     * reconciled outcome, the legacy scalars are re-derived from it, and every
     * non-chemistry field the grower maintains — pack size, price, stock, notes —
     * is carried through untouched.
     */
    fun acceptedInput(
        chemical: SavedChemical,
        outcome: ChemicalEditOutcome,
    ): SavedChemicalRepository.ChemicalInput {
        val reconciled = acceptedChemical(chemical, outcome)
        return ChemicalStoreMatching.inputFor(reconciled, reconciled.name, outcome.intelligence)
    }

    /** The write payload for a confirmed no-change result (evidence only). */
    fun confirmedInput(
        chemical: SavedChemical,
        refreshed: ChemicalIntelligence,
    ): SavedChemicalRepository.ChemicalInput =
        ChemicalStoreMatching.inputFor(chemical, chemical.name, refreshed)
}
