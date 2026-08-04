package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.WorkTask
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
) {
    val trimmedType: String get() = taskType.trim()
    val trimmedNotes: String get() = notes.trim()

    /** A task needs a work type; everything else is optional. */
    val isValid: Boolean get() = trimmedType.isNotEmpty()
}

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
        )

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
