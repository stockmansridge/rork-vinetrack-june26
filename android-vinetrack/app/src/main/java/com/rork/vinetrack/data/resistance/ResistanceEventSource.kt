package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.spray.blockIds

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
 * Since sql/195 a spray record states which blocks it treated, on the frozen
 * application snapshot (`applicationGeometry.blocks`). This adapter reads that
 * directly — no caller-supplied resolver, no inference. One spray attributed to
 * blocks A and C becomes two events sharing the spray's application ID.
 *
 * Records written BEFORE sql/195 carry null attribution, which means "blocks not
 * recorded" and nothing else. Such a record produces NO events and is reported in
 * [Result.unresolvedBlockApplications] with everything a caller needs to judge
 * whether it could have mattered. It is never assigned to a block: not by row
 * number, not by name similarity, not by current geometry, not by "the vineyard
 * only has one block".
 *
 * `TankRowApplication` still holds only `id`, `startRow` and `endRow` on both
 * platforms. Row numbers are not unique across blocks and carry no block
 * reference, so they remain unusable as attribution and are not consulted.
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
    /**
     * A real application that cannot be placed on any block, carried with enough
     * context for a caller to decide whether it could have changed a block's
     * answer.
     *
     * This exists because of a specific, dangerous subtlety: an unattributed spray
     * happened SOMEWHERE in this vineyard. It is not irrelevant — it is
     * unplaceable. A block-specific evaluation that quietly ignored these could
     * report "no issue detected" for a block whose history is genuinely unknown.
     * Carrying the season, the declared targets and the frozen chemistry lets the
     * caller say "historical block attribution is incomplete" precisely when it
     * matters, instead of either crying wolf on every vineyard with legacy data or
     * staying silent.
     */
    data class UnresolvedBlockApplication(
        val applicationId: String,
        val vineyardId: String,
        val appliedAtEpochMs: Long,
        val seasonId: String,
        val kind: ResistanceEventKind,
        /** What the operator declared this spray was for, when they declared it. */
        val targets: List<ResistanceDisease>,
        val targetsRecorded: Boolean,
        val products: List<ResistanceProductLine>,
    ) {
        /**
         * True when this application could bear on [disease].
         *
         * Unrecorded targets count as possibly-relevant: the spray may well have
         * been for this disease and nothing establishes otherwise.
         */
        fun mayConcern(disease: ResistanceDisease): Boolean =
            !targetsRecorded || targets.contains(disease)
    }

    data class Result(
        val events: List<ResistanceApplicationEvent>,
        val deletedRecordIds: List<String>,
        val templateRecordIds: List<String>,
        val undatedRecordIds: List<String>,
        /** Real applications whose treated blocks were never recorded. */
        val unresolvedBlockApplications: List<UnresolvedBlockApplication>,
    ) {
        /** Record ids of the unresolved applications, in chronological order. */
        val unattributedToBlockRecordIds: List<String>
            get() = unresolvedBlockApplications.map { it.applicationId }

        /**
         * True when any real application in this history cannot be placed on a
         * block. A block-specific clean result must be qualified when this is true
         * and the unresolved applications could concern the disease evaluated.
         */
        val hasUnresolvedBlockAttribution: Boolean
            get() = unresolvedBlockApplications.isNotEmpty()

        /** The unresolved applications that could bear on [disease] in [seasonId]. */
        fun unresolvedApplications(
            disease: ResistanceDisease,
            seasonId: String? = null,
        ): List<UnresolvedBlockApplication> =
            unresolvedBlockApplications.filter {
                it.mayConcern(disease) && (seasonId == null || it.seasonId == seasonId)
            }

        val hasExclusions: Boolean
            get() = deletedRecordIds.isNotEmpty() || templateRecordIds.isNotEmpty() ||
                undatedRecordIds.isNotEmpty() || unresolvedBlockApplications.isNotEmpty()
    }

    /**
     * @param blockResolver How to find the blocks a record treated. Defaults to
     *   the record's own persisted attribution (sql/195), which is what normal
     *   records use — the caller supplies nothing. Returning null means "blocks
     *   not recorded" and is distinct from an empty list. The override exists for
     *   one legitimate case: an import or migration path that has established
     *   attribution from a genuinely authoritative external source. It is NOT a
     *   hook for inferring blocks from row numbers or names.
     */
    fun events(
        records: List<SprayRecord>,
        seasonCalendar: ResistanceSeasonCalendar,
        blockResolver: (SprayRecord) -> List<String>? = { record ->
            record.applicationGeometry?.blocks?.blockIds
        },
    ): Result {
        val events = mutableListOf<ResistanceApplicationEvent>()
        val deleted = mutableListOf<String>()
        val templates = mutableListOf<String>()
        val undated = mutableListOf<String>()
        val unresolved = mutableListOf<UnresolvedBlockApplication>()

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

            val blockIds = blockResolver(record).orEmpty().filter { it.isNotBlank() }.distinct()
            if (blockIds.isEmpty()) {
                // Unplaceable, NOT irrelevant. Reported with full context so a
                // block-specific evaluation can qualify its answer rather than
                // pretending this spray never happened.
                unresolved += UnresolvedBlockApplication(
                    applicationId = record.id,
                    vineyardId = record.vineyardId,
                    appliedAtEpochMs = epochMs,
                    seasonId = seasonId,
                    kind = kind,
                    targets = diseases,
                    targetsRecorded = targetsRecorded,
                    products = products,
                )
                return@forEach
            }

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
            unresolvedBlockApplications = unresolved.sortedWith(
                compareBy({ it.appliedAtEpochMs }, { it.applicationId }),
            ),
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
