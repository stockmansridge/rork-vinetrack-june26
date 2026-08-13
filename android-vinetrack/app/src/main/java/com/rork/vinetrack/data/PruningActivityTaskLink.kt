package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PieceRateCosting
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import com.rork.vinetrack.data.model.WorkTaskPieceRateRow
import kotlin.math.abs
import kotlin.math.floor
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Draft of a Work Task being created from inside the pruning activity editor.
 *
 * The task belongs to the WHOLE activity: its date is the activity date, its
 * blocks are every block in the activity, and its duration is the activity's
 * shared labour hours. Nothing here is ever stored per allocation.
 */
data class PruningWorkTaskLinkDraft(
    val taskType: String = PruningActivityTaskLink.DEFAULT_TASK_TYPE,
    val notes: String = "",
    /** Completed tasks are the norm: the pruning already happened. */
    val markCompleted: Boolean = true,
    // ---------------------------------------------------------------------
    // Costing (sql/188)
    //
    // The task is created COMPLETE: its costing basis is agreed HERE, in the
    // same flow, rather than left to a second edit somewhere else. HOURLY is
    // the default, so a user who ignores this section creates exactly the task
    // this flow has always created.
    // ---------------------------------------------------------------------
    val costingMethod: WorkTaskCostingMethod = WorkTaskCostingMethod.HOURLY,
    // Hourly basis — the SAME inputs as a standard Work Task labour line, so
    // creating from pruning writes an ordinary labour line and never a
    // pruning-specific cost record.
    val operatorCategoryId: String? = null,
    val workerType: String = "",
    val workerCount: Int = 1,
    val hoursPerWorker: Double? = null,
    val hourlyRate: Double? = null,
    // Piece-rate basis — the agreed rate and the quantity it applies to.
    val ratePerVine: Double? = null,
    val vineCount: Int = 0,
) {
    val trimmedType: String get() = taskType.trim()
    val trimmedNotes: String get() = notes.trim()

    val isPieceRate: Boolean get() = costingMethod == WorkTaskCostingMethod.PIECE_RATE

    /**
     * True when enough was entered to write a real labour line. Hourly labour
     * stays OPTIONAL at creation: a task may legitimately be created before the
     * crew's hours are known.
     */
    val recordsHourlyLabour: Boolean
        get() = workerCount > 0 && (hoursPerWorker ?: 0.0) > 0.0

    /**
     * The cost this job will be created with, under its chosen method ONLY —
     * the two bases are never summed.
     */
    val estimatedCost: Double?
        get() = when {
            isPieceRate -> PieceRateCosting.cost(vineCount, ratePerVine)
            !recordsHourlyLabour -> null
            else -> WorkTaskLabourCosting.lineCost(workerCount, hoursPerWorker ?: 0.0, hourlyRate)
        }

    /**
     * Person-hours this job will be created with. Present for BOTH methods —
     * hours on a piece-rate job are operational history and never drive cost.
     */
    val personHours: Double
        get() = WorkTaskLabourCosting.personHours(workerCount, hoursPerWorker ?: 0.0)

    /**
     * A task needs a work type. A PIECE-RATE task additionally needs a complete
     * agreement, because its cost has no other source — an hourly task can be
     * created now and costed later from its labour lines.
     */
    val isValid: Boolean
        get() = when {
            trimmedType.isEmpty() -> false
            !isPieceRate -> true
            else -> PieceRateCosting.isValid(ratePerVine, vineCount)
        }
}

/**
 * The hourly labour line a newly created Work Task should be born with.
 *
 * Carried INTO the create call rather than written afterwards, so the labour
 * line is only ever inserted once its parent task exists —
 * `work_task_labour_lines.work_task_id` is a real foreign key.
 */
data class WorkTaskLabourSeed(
    val workDate: String,
    val operatorCategoryId: String?,
    val workerType: String,
    val workerCount: Int,
    val hoursPerWorker: Double,
    val hourlyRate: Double?,
)

/**
 * ACTIVITY-LEVEL Work Task linkage for the multi-block pruning editor
 * (sql/166).
 *
 * The link lives on exactly one field — [PruningActivityDraft.workTaskId] — and
 * NEVER on a `BlockPruningSelection`. Every mutation here goes through
 * `copy(workTaskId = …)`, so the allocation map (rows, quarters, row
 * equivalents, vines per block) is carried through untouched: creating,
 * linking, changing or unlinking a task can never disturb a block selection.
 *
 * The offline rule this object also encodes: `pruning_activities.work_task_id`
 * is a real foreign key, so an activity that references a Work Task created
 * offline must WAIT for that task to reach the server. The link is never
 * dropped to make the pruning upload succeed.
 */
object PruningActivityTaskLink {
    const val DEFAULT_TASK_TYPE: String = "Pruning"

    // MARK: Draft mutations (allocation-preserving by construction)

    /** Links [taskId] to the parent activity, preserving every allocation. */
    fun link(draft: PruningActivityDraft, taskId: String): PruningActivityDraft =
        draft.copy(workTaskId = taskId)

    /**
     * Removes the link. The activity, its labour and every block allocation
     * stay exactly as they are — `update_pruning_activity` receives
     * `clear_work_task = true` and clears only the parent's column.
     */
    fun unlink(draft: PruningActivityDraft): PruningActivityDraft =
        draft.copy(workTaskId = null)

    /** The linked task, when this device has it cached. */
    fun linkedTask(draft: PruningActivityDraft, tasks: List<WorkTask>): WorkTask? =
        draft.workTaskId?.let { id -> tasks.firstOrNull { it.id == id } }

    /**
     * True when the draft references a task this device cannot resolve — a task
     * created on another device and not yet pulled, or one that was deleted.
     * Surfaced as a warning; never auto-cleared.
     */
    fun hasUnresolvableLink(draft: PruningActivityDraft, tasks: List<WorkTask>): Boolean =
        draft.workTaskId != null && linkedTask(draft, tasks) == null

    // MARK: Existing-task picker

    /**
     * Searchable, newest-first candidates for linking. Matches the work type,
     * the block snapshot, the notes or the date, so the operator can find the
     * task by whatever they remember about it. Deleted and archived tasks are
     * never offered.
     */
    fun search(tasks: List<WorkTask>, query: String): List<WorkTask> {
        val needle = query.trim().lowercase()
        return tasks
            .asSequence()
            .filter { it.deletedAt == null && !it.isArchived }
            .filter { task ->
                needle.isEmpty() ||
                    task.taskType?.lowercase()?.contains(needle) == true ||
                    task.paddockName?.lowercase()?.contains(needle) == true ||
                    task.notes?.lowercase()?.contains(needle) == true ||
                    task.date?.lowercase()?.contains(needle) == true
            }
            .sortedByDescending { it.date.orEmpty() }
            .toList()
    }

    /** One-line description of a linkable task: work type · block · date. */
    fun label(task: WorkTask): String = listOfNotNull(
        task.displayLabel,
        task.paddockName?.takeIf { it.isNotBlank() },
        task.date?.takeIf { it.isNotBlank() }?.take(10),
    ).joinToString(" · ")

    // MARK: Creating a task for the activity

    /**
     * Seeds the create form from the activity itself, so the operator normally
     * only has to confirm. The notes carry the block summary, so the Work Task
     * records WHICH blocks the shared labour covered.
     */
    fun createDraft(draft: PruningActivityDraft): PruningWorkTaskLinkDraft =
        PruningWorkTaskLinkDraft(
            taskType = DEFAULT_TASK_TYPE,
            notes = composedNotes(draft),
            hoursPerWorker = draft.labourHours?.takeIf { it > 0 },
            // The piece-rate quantity is seeded from the activity's OWN vine
            // total — the same `499 vines` the Activity Summary shows — so
            // choosing Piece Rate never asks the operator to re-enter a
            // quantity the app already derived from the selected quarters.
            vineCount = vineCount(draft),
        )

    /**
     * THE piece-rate quantity for an activity: exactly the vine total the
     * Activity Summary displays.
     *
     * Quarter-aware by construction — each allocation's `estimatedVines` was
     * derived from its SELECTED QUARTERS through `PruningCalculator.vines`, so
     * selecting 8 quarters across 2 rows prices 8 quarters, never 2 whole rows.
     */
    fun vineCount(draft: PruningActivityDraft): Int = draft.totalEstimatedVines

    /**
     * The labour line a task created from this draft should be born with, or
     * null when no hours were entered.
     *
     * On a PIECE-RATE job the hourly rate is deliberately dropped: the hours are
     * kept as operational history, and letting a rate ride along would give the
     * job a second, competing cost basis.
     */
    fun labourSeed(task: PruningWorkTaskLinkDraft, date: String): WorkTaskLabourSeed? {
        if (!task.recordsHourlyLabour) return null
        return WorkTaskLabourSeed(
            workDate = date,
            operatorCategoryId = task.operatorCategoryId,
            workerType = task.workerType.trim(),
            workerCount = task.workerCount,
            hoursPerWorker = task.hoursPerWorker ?: 0.0,
            hourlyRate = if (task.isPieceRate) null else task.hourlyRate,
        )
    }

    /**
     * Rounds a vine quantity half away from zero — the same rule the per-row
     * vine-count calculation uses, so no platform reports a vine another does
     * not. (`kotlin.math.round` delegates to `Math.rint`, which is ties-to-even
     * and would disagree with Swift on exact halves.)
     */
    fun roundVines(value: Double): Int {
        if (!value.isFinite()) return 0
        val magnitude = floor(abs(value) + 0.5).toInt()
        return if (value < 0) -magnitude else magnitude
    }

    /**
     * Builds the HISTORICAL per-row snapshot behind a piece-rate job (sql/188)
     * from the quarters actually selected in each block.
     *
     * A row with 2 of its 4 quarters selected contributes HALF its vines, so
     * the breakdown matches what was really pruned. These rows are supporting
     * audit detail: the authoritative priced quantity is the task's own
     * `piece_vine_count`, which is why per-row rounding here may differ from
     * the total by a vine or two without changing what anyone is paid.
     *
     * @param rowsByPaddock each block's rows, already resolved through
     *   `PruningCalculator.rowRefs` so the grid, the vine estimate and this
     *   snapshot all agree.
     * @param newId supplies a fresh client-generated row id.
     */
    fun pieceRateRows(
        activity: PruningActivityDraft,
        workTaskId: String,
        vineyardId: String,
        rowsByPaddock: Map<String, List<PruningRowRef>>,
        newId: () -> String,
    ): List<WorkTaskPieceRateRow> {
        val snapshot = mutableListOf<WorkTaskPieceRateRow>()
        for (allocation in activity.activeAllocations) {
            val rows = rowsByPaddock[allocation.paddockId] ?: continue
            val quartersByRowKey = HashMap<String, Int>()
            for (segment in allocation.segments) {
                quartersByRowKey[segment.rowKey] = (quartersByRowKey[segment.rowKey] ?: 0) + 1
            }
            for (row in rows) {
                val quarters = quartersByRowKey[row.key] ?: continue
                if (quarters <= 0) continue
                snapshot += WorkTaskPieceRateRow(
                    id = newId(),
                    workTaskId = workTaskId,
                    vineyardId = vineyardId,
                    paddockId = allocation.paddockId,
                    paddockRowId = row.rowId,
                    rowNumber = row.number,
                    vineCount = roundVines(row.vines * quarters / 4.0),
                )
            }
        }
        return snapshot
    }

    fun composedNotes(draft: PruningActivityDraft): String {
        val blocks = draft.blockSummary.takeIf { it.isNotBlank() }
        val quarters = "${draft.totalQuarters} quarters (${trim(draft.totalRowEquivalents)} row equivalents)"
        val head = listOfNotNull(blocks, quarters).joinToString(" — ")
        val notes = draft.notes.trim()
        return if (notes.isEmpty()) head else "$head\n$notes"
    }

    /**
     * Duration for the created task = the activity's SHARED labour hours,
     * counted once for the whole job and never apportioned per block.
     */
    fun durationHours(draft: PruningActivityDraft): Double = draft.labourHours ?: 0.0

    /** Every block in the activity — the task spans them all. */
    fun paddockIds(draft: PruningActivityDraft): List<String> =
        draft.activeAllocations.map { it.paddockId }.ifEmpty {
            draft.allocations.keys.sorted()
        }

    // MARK: Offline dependency

    /**
     * Ids of Work Tasks whose CREATE has not been acknowledged by the server.
     * An activity referencing one of these cannot be pushed yet: the
     * `work_task_id` foreign key would reject the whole atomic write.
     */
    fun unresolvedTaskCreateIds(writes: List<PendingWrite>): Set<String> = writes
        .filter {
            it.entityType == PendingEntityType.WORK_TASK &&
                it.opType == PendingOpType.CREATE &&
                it.status in PendingWriteStatus.unresolved
        }
        .map { it.clientId }
        .toSet()

    /**
     * Ids of Work Tasks with ANY unresolved dependency, in the mandatory order
     * the pruning push relies on:
     *
     *   1. the Work Task header (`work_task_id` is a real foreign key),
     *   2. its block associations,
     *   3. its labour lines — the authoritative labour record,
     *   4. only then the Pruning Activity that references the task.
     *
     * A pruning activity referencing any of these ids is held back with its
     * `work_task_id` INTACT: the link is never stripped to force the upload, and
     * the activity is never reported as fully synced while a labour line it
     * depends on is still local (a report would otherwise read a half-written
     * labour record).
     *
     * Child writes are keyed by their own row id, so the caller supplies the
     * child -> parent-task maps ([labourLineTaskIds], [workTaskPaddockTaskIds]).
     */
    fun unresolvedDependencyIds(
        writes: List<PendingWrite>,
        labourLineTaskIds: Map<String, String> = emptyMap(),
        workTaskPaddockTaskIds: Map<String, String> = emptyMap(),
    ): Set<String> {
        val ids = unresolvedTaskCreateIds(writes).toMutableSet()
        for (write in writes) {
            if (write.status !in PendingWriteStatus.unresolved) continue
            val taskId = when (write.entityType) {
                PendingEntityType.WORK_TASK_LABOUR ->
                    labourLineTaskIds[write.clientId] ?: payloadWorkTaskId(write)
                PendingEntityType.WORK_TASK_PADDOCK ->
                    workTaskPaddockTaskIds[write.clientId] ?: payloadWorkTaskId(write)
                else -> null
            }
            if (taskId != null) ids += taskId
        }
        return ids
    }

    /**
     * Best-effort parent-task id from a queued child write's payload, so the
     * coordinator does not need to keep its own child -> task index. Every child
     * payload ([WorkTaskLabourSync.UpsertPayload] / `DeletePayload`, and the
     * work-task-paddock equivalents) carries `workTaskId`.
     */
    private fun payloadWorkTaskId(write: PendingWrite): String? = runCatching {
        val element = Json.parseToJsonElement(write.payloadJson)
        element.jsonObject["workTaskId"]?.jsonPrimitive?.contentOrNull
    }.getOrNull()

    /**
     * Whether an activity write must wait. The pruning activity is held back —
     * with its `work_task_id` intact — until the linked task, its block links and
     * its labour lines have all landed.
     */
    fun isWaitingForTask(workTaskId: String?, unresolvedTaskCreateIds: Set<String>): Boolean =
        workTaskId != null && workTaskId in unresolvedTaskCreateIds

    /** Operator-facing reason shown on the held write. */
    const val WAITING_REASON: String =
        "Waiting for the linked Work Task and its labour lines to reach the server — the pruning activity will sync straight after."

    private fun trim(value: Double): String =
        if (value % 1.0 == 0.0) value.toInt().toString() else String.format("%.2f", value).trimEnd('0').trimEnd('.')
}
