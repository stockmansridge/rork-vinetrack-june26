package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask

/** One-shot durable initiation; an unknown outcome is never retried or overwritten implicitly. */
class WorkTaskWriteCoordinator(private val drafts: WorkTaskPlanningDraftStore) {
    suspend fun submit(intent: WorkTaskWriteIntent, canWrite: () -> Boolean, send: suspend (WorkTaskWriteIntent) -> WorkTask): WorkTask {
        check(canWrite())
        val prior = drafts.loadIntent(intent.authorId, intent.vineyardId, intent.taskId)
        check(prior == null || prior.acknowledged) { "Earlier save unconfirmed. Review server state; no retry or rebase." }
        drafts.saveIntent(intent)
        val saved = send(intent)
        check(canWrite() && saved.id == intent.taskId && saved.vineyardId == intent.vineyardId)
        drafts.saveIntent(intent.copy(acknowledged = true))
        return saved
    }
}
