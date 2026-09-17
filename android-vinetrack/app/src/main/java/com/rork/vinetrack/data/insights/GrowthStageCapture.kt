package com.rork.vinetrack.data.insights

/**
 * The canonical Growth Stage capture contract shared by all three Android
 * entry points: the Growth Stage screen, the Unified Pin Composer, and
 * Vineyard Insights Scout.
 *
 * ## The defect this type exists to close
 *
 * Android previously had TWO divergent half-flows. The Growth screen wrote a
 * `growth_stage_records` row with `pin_id` hard-coded to null and no pin; the
 * Unified Pin Composer wrote a real Growth `pins` row and no record. Neither
 * produced the pair. `PinsScreen.synthesizeGrowthPins` then fabricated
 * display-only pins in memory so the Growth screen's records still appeared on
 * the map — which is why the gap survived so long. Those fabricated pins never
 * reach the database, never sync, and never appear on another device.
 *
 * iOS has always produced the pair (`createGrowthStagePin` →
 * `mirrorGrowthStagePin`). This type ports that behaviour rather than adding a
 * third writer.
 *
 * ## One capture, two rows, both IDs minted before anything is persisted
 *
 * [plan] is a pure function: given a request and whatever already exists, it
 * returns the ordered work. Both UUIDs are minted by the caller and travel
 * through the optimistic row, the local write, the outbox payload and the
 * eventual server insert unchanged — so a retry re-sends the SAME identities
 * and the server upsert collapses onto the existing rows instead of minting
 * duplicates.
 *
 * ## Ordering is a foreign-key requirement, not a preference
 *
 * `growth_stage_records.pin_id` references `pins(id)`. The pin must be queued
 * and pushed BEFORE its record or the dependent insert is rejected. [Paired]
 * therefore exposes the two halves in order and never as an unordered set.
 *
 * ## Partial replay completes the missing half only
 *
 * A capture whose pin reached the server but whose record did not must, on the
 * next attempt, push only the record. Re-pushing the pin would be wasted work
 * at best; minting a new pin id would strand the first one as an orphan the
 * operator can see but nothing references. [plan] is given the observed
 * server-side state and returns exactly the outstanding half.
 */
sealed interface GrowthStageCapture {

    /**
     * What one canonical capture asks for. Identity is supplied by the caller,
     * not generated here, so replay can re-present the same request verbatim.
     */
    data class Request(
        val pinId: String,
        val recordId: String,
        val vineyardId: String,
        val paddockId: String?,
        val stageCode: String,
        val stageLabel: String?,
        val variety: String?,
        val observedAtIso: String,
        val latitude: Double?,
        val longitude: Double?,
        val rowNumber: Int? = null,
        val notes: String? = null,
        /** Set when Scout initiated the capture, so the link can be written back. */
        val scoutObservationId: String? = null,
    )

    /** Which halves of a previous attempt are already durable server-side. */
    data class Progress(
        val pinPersisted: Boolean = false,
        val recordPersisted: Boolean = false,
    )

    /**
     * Create both halves, pin first.
     *
     * [needsPin] and [needsRecord] are what remains outstanding. Both true is a
     * fresh capture; exactly one true is a partial replay resuming.
     */
    data class Paired(
        val request: Request,
        val needsPin: Boolean,
        val needsRecord: Boolean,
    ) : GrowthStageCapture {

        /**
         * The local and outbox order. Pin before record, always — the record's
         * `pin_id` foreign key makes any other order a rejected insert.
         */
        val orderedSteps: List<Step>
            get() = buildList {
                if (needsPin) add(Step.PIN)
                if (needsRecord) add(Step.RECORD)
            }
    }

    /**
     * Amend the existing canonical pair in place. An edit must never mint a
     * second pin or a second record — the observation is the same event.
     */
    data class UpdateExisting(
        val pinId: String?,
        val recordId: String,
        val stageCode: String,
        val stageLabel: String?,
    ) : GrowthStageCapture

    /**
     * Both halves already exist and already carry this stage. A replay of an
     * applied capture is a no-op, which is what makes repeated replay safe.
     */
    data class AlreadyApplied(val pinId: String?, val recordId: String) : GrowthStageCapture

    enum class Step { PIN, RECORD }

    companion object {

        /**
         * Decide the outstanding work for a capture.
         *
         * @param existingRecordId a canonical record this capture already
         *   produced, if any. Its presence means this is an edit or a replay,
         *   never a new event.
         * @param existingPinId the pin that record references. Null on a
         *   HISTORICAL record written before this correction — see
         *   [isLegacyUnlinked].
         * @param existingStageCode the stage currently stored, used to tell a
         *   real edit from a replay of an applied capture.
         * @param progress which halves a previous attempt already delivered.
         */
        fun plan(
            request: Request,
            existingRecordId: String?,
            existingPinId: String?,
            existingStageCode: String?,
            progress: Progress = Progress(),
        ): GrowthStageCapture {
            if (existingRecordId == null) {
                // Fresh capture, or a replay resuming after a partial success.
                return Paired(
                    request = request,
                    needsPin = !progress.pinPersisted,
                    needsRecord = !progress.recordPersisted,
                )
            }
            if (existingStageCode == request.stageCode) {
                return AlreadyApplied(pinId = existingPinId, recordId = existingRecordId)
            }
            return UpdateExisting(
                // A historical record has no pin. The edit amends the record
                // alone rather than silently minting a pin for it — see
                // [isLegacyUnlinked].
                pinId = existingPinId,
                recordId = existingRecordId,
                stageCode = request.stageCode,
                stageLabel = request.stageLabel,
            )
        }

        /**
         * True for a record written before this correction, which has no pin.
         *
         * Editing one of these amends the RECORD ONLY. It deliberately does not
         * back-fill a pin: doing so would make an ordinary edit start writing a
         * new map pin at whatever position the device happens to report today,
         * for an observation made months ago somewhere else. The operator would
         * have no way to tell that pin apart from one they dropped themselves.
         * Historical records therefore stay pin-less and keep displaying through
         * the documented [legacyDisplayFallbackNotice] path.
         */
        fun isLegacyUnlinked(existingRecordId: String?, existingPinId: String?): Boolean =
            existingRecordId != null && existingPinId == null

        const val legacyDisplayFallbackNotice: String =
            "Recorded before Growth Stage pins were linked. Shown on the map from " +
                "the observation itself; editing updates the observation only."
    }
}
