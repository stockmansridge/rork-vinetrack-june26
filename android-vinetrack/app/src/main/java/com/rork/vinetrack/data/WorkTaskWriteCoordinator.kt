package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import kotlinx.coroutines.sync.Mutex

/** Durable original request, explicit send admission and read-only acknowledgement recovery. */
class WorkTaskWriteCoordinator(private val drafts: WorkTaskPlanningDraftStore) {
    companion object { private val admission = Mutex() }

    // Compatibility for callers without a transport boundary: conservatively uncertain before send.
    suspend fun submit(intent: WorkTaskWriteIntent, canWrite: () -> Boolean, send: suspend (WorkTaskWriteIntent) -> WorkTask): WorkTask =
        submitTracked(intent, canWrite) { original, dispatch, _ -> dispatch(); send(original) }

    suspend fun submitTracked(
        intent: WorkTaskWriteIntent, canWrite: () -> Boolean, retryOriginal: Boolean = false,
        send: suspend (WorkTaskWriteIntent, () -> Unit, (TaskWriteStage) -> Unit) -> WorkTask,
    ): WorkTask = exclusive {
        var stage = TaskWriteStage.VALIDATION
        var state = TaskWriteRecovery(intent, TaskWritePhase.UNSENT, stage)
        var saved: WorkTask? = null
        var ownsEvidence = false
        try {
            OperationalWrites.requireWrite(intent.vineyardId)
            check(canWrite()) { "Original account, vineyard or write permission unavailable" }
            val prior = drafts.loadIntent(intent.authorId, intent.vineyardId, intent.taskId)
            if (prior != null && prior.acknowledged && (retryOriginal || prior.copy(acknowledged = false) == intent.copy(acknowledged = false))) {
                throw TaskWriteFailure(TaskWriteStage.SERVER_REVIEW, TaskWritePhase.CONFIRMED, code = "ALREADY_ACKNOWLEDGED")
            }
            if (prior != null && !prior.acknowledged) {
                val old = drafts.recovery(prior) ?: TaskWriteRecovery(prior)
                if (!retryOriginal || old.phase !in setOf(TaskWritePhase.UNSENT, TaskWritePhase.REJECTED) ||
                    old.code == "VERSION_CONFLICT" || prior != intent) {
                    throw TaskWriteFailure(TaskWriteStage.SERVER_REVIEW, old.phase, old.status, old.code)
                }
                state = old
                ownsEvidence = true
            } else {
                if (prior != null) drafts.archiveIntent(prior)
                stage = TaskWriteStage.INTENT_PERSISTENCE
                drafts.saveIntent(intent)
                ownsEvidence = true
                // A crash between these writes leaves an old-format UNKNOWN, never permission to resend.
                drafts.saveRecovery(state)
            }
            saved = send(intent, {
                check(canWrite()) { "Original scope changed before dispatch" }
                stage = TaskWriteStage.INTENT_PERSISTENCE
                val next = state.copy(phase = TaskWritePhase.DISPATCHED, stage = TaskWriteStage.TRANSPORT, status = null, code = null, detail = null)
                drafts.saveRecovery(next) // Must commit before HTTP execution.
                state = next
                stage = TaskWriteStage.TRANSPORT
            }, { stage = it })
            stage = TaskWriteStage.ACKNOWLEDGEMENT
            check(canWrite() && saved.id == intent.taskId && saved.vineyardId == intent.vineyardId)
            state = state.copy(phase = TaskWritePhase.CONFIRMED, stage = stage, confirmed = saved)
            stage = TaskWriteStage.LOCAL_PERSISTENCE
            drafts.saveRecovery(state)
            drafts.saveIntent(intent.copy(acknowledged = true))
            saved
        } catch (error: Exception) {
            if (error is TaskWriteFailure && stage == TaskWriteStage.VALIDATION) throw error
            val failure = error as? TaskWriteFailure
            val phase = if (saved != null) TaskWritePhase.CONFIRMED else failure?.phase ?: state.phase
            val result = TaskWriteFailure(if (error is BackendError.Unauthorized) TaskWriteStage.SESSION else failure?.stage ?: stage, phase, failure?.status, failure?.code, error, saved)
            // Never erase the original request, even if diagnostics cannot be persisted.
            try { if (ownsEvidence) drafts.saveRecovery(state.copy(phase = phase, stage = result.stage, status = result.status, code = result.code, detail = result.diagnostic(), confirmed = saved)) }
            catch (storage: Exception) { result.addSuppressed(storage) }
            throw result
        }
    }

    suspend fun recover(intent: WorkTaskWriteIntent, isCurrent: () -> Boolean, lookup: suspend (WorkTaskWriteIntent) -> WorkTask): WorkTask = exclusive {
        check(isCurrent()) { "Return to the original account and vineyard" }
        val original = drafts.loadIntent(intent.authorId, intent.vineyardId, intent.taskId) ?: error("Original request unavailable")
        check(original.copy(acknowledged = false) == intent.copy(acknowledged = false))
        val state = drafts.recovery(original) ?: TaskWriteRecovery(original)
        var saved: WorkTask? = null
        try {
            saved = lookup(original) // Always positive, exact-scope verified server evidence, never cached absence.
            check(isCurrent() && saved.id == original.taskId && saved.vineyardId == original.vineyardId)
            drafts.saveRecovery(state.copy(phase = TaskWritePhase.CONFIRMED, stage = TaskWriteStage.LOCAL_PERSISTENCE, confirmed = saved, code = null, detail = null))
            drafts.saveIntent(original.copy(acknowledged = true))
            saved
        } catch (error: Exception) {
            val failure = error as? TaskWriteFailure
            val result = TaskWriteFailure(if (saved != null) TaskWriteStage.LOCAL_PERSISTENCE else failure?.stage ?: TaskWriteStage.SERVER_REVIEW,
                if (saved != null) TaskWritePhase.CONFIRMED else state.phase, failure?.status, failure?.code, error, saved)
            try { drafts.saveRecovery(state.copy(stage = result.stage, status = result.status, code = result.code, detail = result.diagnostic(), confirmed = saved ?: state.confirmed)) }
            catch (storage: Exception) { result.addSuppressed(storage) }
            throw result
        }
    }

    private suspend fun <T> exclusive(block: suspend () -> T): T {
        if (!admission.tryLock()) throw TaskWriteFailure(TaskWriteStage.VALIDATION, TaskWritePhase.UNKNOWN, code = "REQUEST_IN_PROGRESS")
        try { return block() } finally { admission.unlock() }
    }
}
