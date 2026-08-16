package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.model.SprayRecord

/**
 * Turns stored spray history into canonical [ResistanceApplicationEvent]s.
 *
 * WHICH RECORD STATES COUNT AS RESISTANCE HISTORY
 *
 * Included:
 * - Records with no `deleted_at` and `is_template == false`, that have a usable
 *   date, classified as [ResistanceEventKind.ACTUAL] when an `end_time` is
 *   present.
 *
 * Excluded, and why:
 * - `deleted_at != null` — soft-deleted via the `soft_delete_spray_record` RPC. A
 *   deleted record is a retracted claim; counting it would let a mistaken entry
 *   permanently consume a group's seasonal allowance.
 * - `is_template == true` — a template is a reusable recipe, not an application.
 *   It was never sprayed on a vine.
 * - No parseable date — resistance rules are entirely sequence-based, and an
 *   event with no position in the chronology cannot be evaluated. Surfaced via
 *   [Result.undatedRecordIds] rather than dropped silently.
 * - `end_time == null` — classified [ResistanceEventKind.PLANNED] rather than
 *   discarded. VineTrack has no separate cancelled/reversed state; an unfinished
 *   record is the closest thing, and the engine excludes planned events from
 *   counting by default while still reporting that it did so.
 *
 * BLOCK ATTRIBUTION
 *
 * Spray records do not currently record which blocks they covered. `SprayTank`
 * carries `rowApplications`, but `TankRowApplication` holds only `id`, `startRow`
 * and `endRow` — no block reference — on BOTH platforms, and it is never
 * constructed with block linkage. Rather than guess, this adapter requires the
 * caller to supply [blockResolver]. A resolver returning no blocks yields no
 * events for that record, and the record ID is reported in
 * [Result.unattributedToBlockRecordIds] so the omission is visible.
 *
 * Mirrors iOS `ResistanceEventSource.swift`.
 */
object ResistanceEventSource {

    /**
     * Events plus an explicit account of everything that did NOT become an event.
     *
     * The exclusions are returned rather than logged because a resistance report
     * built on a silently-filtered history is exactly the false clean result this
     * work exists to prevent.
     */
    data class Result(
        val events: List<ResistanceApplicationEvent>,
        val deletedRecordIds: List<String>,
        val templateRecordIds: List<String>,
        val undatedRecordIds: List<String>,
        val unattributedToBlockRecordIds: List<String>,
    ) {
        val hasExclusions: Boolean
            get() = deletedRecordIds.isNotEmpty() || templateRecordIds.isNotEmpty() ||
                undatedRecordIds.isNotEmpty() || unattributedToBlockRecordIds.isNotEmpty()
    }

    /**
     * @param blockResolver Blocks a record applied to. Required — see the class
     *   note on block attribution.
     */
    fun events(
        records: List<SprayRecord>,
        seasonCalendar: ResistanceSeasonCalendar,
        blockResolver: (SprayRecord) -> List<String>,
    ): Result {
        val events = mutableListOf<ResistanceApplicationEvent>()
        val deleted = mutableListOf<String>()
        val templates = mutableListOf<String>()
        val undated = mutableListOf<String>()
        val unattributed = mutableListOf<String>()

        records.forEach { record ->
            if (record.deletedAt != null) {
                deleted += record.id
                return@forEach
            }
            if (record.isTemplate) {
                templates += record.id
                return@forEach
            }
            val epochMs = record.dateEpochMs
            if (epochMs == null) {
                undated += record.id
                return@forEach
            }
            val blockIds = blockResolver(record).distinct()
            if (blockIds.isEmpty()) {
                unattributed += record.id
                return@forEach
            }

            val kind = if (record.endTime?.isNotBlank() == true) {
                ResistanceEventKind.ACTUAL
            } else {
                ResistanceEventKind.PLANNED
            }
            val products = productLines(record)
            // Null targets means the question was never asked (pre-sql/193). An
            // empty list means the operator recorded "no disease target". Those
            // are different facts and must not collapse.
            val targetsRecorded = record.targets != null
            val diseases = record.targets.orEmpty()
                .mapNotNull { ResistanceDisease.fromSprayTargetRaw(it) }
                .distinct()
            val seasonId = seasonCalendar.season(epochMs).id

            blockIds.forEach { blockId ->
                events += ResistanceApplicationEvent(
                    // One spray across three blocks becomes three events, each
                    // keeping the spray's own ID so a warning can always point
                    // back to the record the operator recognises.
                    applicationId = record.id,
                    kind = kind,
                    appliedAtEpochMs = epochMs,
                    seasonId = seasonId,
                    vineyardId = record.vineyardId,
                    blockId = blockId,
                    targets = diseases,
                    targetsRecorded = targetsRecorded,
                    products = products,
                )
            }
        }

        return Result(
            events = events.sortedWith(ResistanceApplicationEvent.chronological),
            deletedRecordIds = deleted,
            templateRecordIds = templates,
            undatedRecordIds = undated,
            unattributedToBlockRecordIds = unattributed,
        )
    }

    /**
     * Product lines built from the FROZEN snapshot on each chemical line.
     *
     * Never re-reads the live Chemical Store record. A classification corrected in
     * 2029 must not retroactively change what the 2026 rotation is said to have
     * been, or every rotation decision made from that history becomes unstable.
     */
    private fun productLines(record: SprayRecord): List<ResistanceProductLine> =
        record.tanks.orEmpty().flatMap { tank ->
            tank.chemicals.map { chemical ->
                val snapshot = chemical.chemicalSnapshot
                ResistanceProductLine(
                    lineId = chemical.id,
                    productName = snapshot?.productName ?: chemical.name.takeIf { it.isNotBlank() },
                    savedChemicalId = chemical.savedChemicalId,
                    groups = ResistanceGroupSignature.of(snapshot?.activityGroupCodes.orEmpty()),
                    availability = availability(snapshot),
                )
            }
        }

    /**
     * How far a line's frozen chemistry can be trusted.
     *
     * A missing snapshot is [ChemicalIntelligenceAvailability.UNAVAILABLE] — never
     * "no groups". Legitimate VineTrack history predates Chemical Intelligence,
     * and reading that silence as an absence of chemistry would hand back a green
     * rotation report for a season nobody can account for.
     */
    private fun availability(snapshot: ChemicalLineSnapshot?): ChemicalIntelligenceAvailability =
        ChemicalIntelligenceAvailability.resolve(snapshot)
}
