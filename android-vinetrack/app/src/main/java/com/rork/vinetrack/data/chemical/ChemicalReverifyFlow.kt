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
     * The IN-MEMORY result of accepting an update. Nothing is written.
     *
     * # Why a draft exists at all
     *
     * "Use updated information" used to call `updateSavedChemical` immediately,
     * so the moment an operator pressed it the record changed — before they
     * had seen the merged product, and with no way back except editing every
     * field by hand. A re-check is a question, and answering a question should
     * never be a write. The draft carries the merged record to the ordinary
     * chemical editor, where the operator reviews it and presses Save exactly
     * once, exactly as they would for any other edit.
     *
     * [chemical] preserves every customer-owned commercial field — purchase,
     * supplier, pack size and unit, price, cost, stock and notes — because
     * [ChemicalReverification.updated] copies the stored record and replaces
     * only chemical-intelligence fields.
     */
    data class Draft(
        /** The merged record as it WOULD stand. Never persisted by this type. */
        val chemical: SavedChemical,
        /**
         * The reconciled intelligence the final Save must write.
         *
         * Carried explicitly because the editor cannot re-derive it: opened on
         * the draft, its own "has the chemistry changed?" test compares the
         * draft against itself, finds no difference, and would omit the
         * intelligence columns from the write entirely.
         */
        val intelligence: ChemicalIntelligence,
        /**
         * Bases whose stored default cites a registered rate the refreshed
         * label no longer carries. The operator must confirm a rate again or
         * clear the slot before the draft can be saved.
         */
        val staleDefaultBases: List<ChemicalDefaultRateBasis>,
    )

    /**
     * Build the in-memory draft for an accepted update. Writes nothing.
     *
     * Staleness is measured against the REFRESHED grapevine directions: a
     * default is a claim about a registered direction, so if the direction it
     * cites has gone, the claim can no longer be shown to hold.
     */
    fun draftFor(chemical: SavedChemical, outcome: ChemicalEditOutcome): Draft {
        val updated = acceptedChemical(chemical, outcome)
        return Draft(
            chemical = updated,
            intelligence = outcome.intelligence,
            staleDefaultBases = chemical.defaultRates
                ?.staleBases(outcome.intelligence.registeredUses.viticultural())
                .orEmpty(),
        )
    }

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

    // NOTE: there is deliberately no `confirmedInput` any more.
    //
    // It built the write payload for a NO-CHANGE result, refreshing the stored
    // evidence and check date. Running a check is not new information about a
    // product: nothing about it moved, so nothing about it may be rewritten.
    // Storing a fresh "last checked" stamp also made the record look
    // re-attested when the only thing that had happened was somebody pressing
    // a button, so a no-change result now writes exactly nothing.
}
