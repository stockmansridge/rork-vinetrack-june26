package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import kotlinx.serialization.json.Json

/** Local editor storage isolated from outboxes; failed commit is never reported as saved. */
class WorkTaskPlanningDraftStore(
    private val read: (String) -> String?,
    private val write: (String, String) -> Boolean,
) {
    constructor(context: Context) : this(
        { key -> context.applicationContext.getSharedPreferences("vinetrack_local_planning", Context.MODE_PRIVATE).getString(key, null) },
        { key, value -> context.applicationContext.getSharedPreferences("vinetrack_local_planning", Context.MODE_PRIVATE).edit().putString(key, value).commit() },
    )
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = true }
    fun save(draft: WorkTaskPlanningDraft) {
        require(draft.isValid)
        check(write(draft.persistenceKey, json.encodeToString(draft))) { "Draft could not be saved to this device" }
    }
    fun load(author: String, vineyard: String, task: String?): WorkTaskPlanningDraft? {
        val key = "work-task-planning-$author-$vineyard-${task ?: "new"}"
        val text = read(key) ?: return null
        val draft = json.decodeFromString<WorkTaskPlanningDraft>(text)
        check(draft.authorId == author && draft.vineyardId == vineyard && draft.taskId == task)
        return draft
    }
}
