package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import kotlinx.serialization.json.Json

/** Local editor storage isolated from outboxes; failed commit is never reported as saved. */
class WorkTaskPlanningDraftStore(
    private val read: (String) -> String?,
    private val write: (String, String) -> Boolean,
    private val remove: (String) -> Boolean = { false },
) {
    private constructor(preferences: android.content.SharedPreferences) : this(
        { key -> preferences.getString(key, null) },
        { key, value -> preferences.edit().putString(key, value).commit() },
        { key -> preferences.edit().remove(key).commit() },
    )
    private constructor(context: Context, access: com.rork.vinetrack.data.auth.FieldStoreAccess) : this(
        { key -> context.applicationContext.getSharedPreferences("vinetrack_local_planning", Context.MODE_PRIVATE).getString(key, null) },
        { key, value -> access.admitted {
            access.preferences(context.applicationContext.getSharedPreferences("vinetrack_local_planning", Context.MODE_PRIVATE))
                .edit().putString(key, value).commit()
        } },
        { key -> access.admitted {
            access.preferences(context.applicationContext.getSharedPreferences("vinetrack_local_planning", Context.MODE_PRIVATE))
                .edit().remove(key).commit()
        } },
    )
    constructor(context: Context) : this(context, com.rork.vinetrack.data.auth.FieldStoreAccess(context))
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = true }
    fun save(draft: WorkTaskPlanningDraft) {
        require(draft.isValid)
        check(write(draft.persistenceKey, json.encodeToString(draft))) { "Draft could not be saved to this device" }
    }
    fun archiveCreatedDraft(draft: WorkTaskPlanningDraft, taskId: String) {
        if (draft.taskId != null) return
        save(draft.copy(taskId = taskId))
        check(remove(draft.persistenceKey)) { "Saved task draft retained; local cleanup unavailable" }
    }
    fun discardPlanningDraft(author: String, vineyard: String, task: String?) {
        check(remove("work-task-planning-$author-$vineyard-${task ?: "new"}"))
    }

    fun saveIntent(intent: WorkTaskWriteIntent) {
        check(write(intent.persistenceKey, json.encodeToString(intent))) { "Request could not be saved to this device" }
    }
    fun loadIntent(author: String, vineyard: String, task: String): WorkTaskWriteIntent? =
        read("work-task-write-$author-$vineyard-$task")?.let { json.decodeFromString<WorkTaskWriteIntent>(it) }?.also {
            check(it.authorId == author && it.vineyardId == vineyard && it.taskId == task)
        }

    fun recovery(intent: WorkTaskWriteIntent): TaskWriteRecovery? =
        read("${intent.persistenceKey}-lifecycle")?.let { json.decodeFromString<TaskWriteRecovery>(it) }?.also {
            check(it.original.copy(acknowledged = false) == intent.copy(acknowledged = false)) { "Retained request differs from lifecycle evidence" }
        }

    fun saveRecovery(state: TaskWriteRecovery) {
        check(write("${state.original.persistenceKey}-lifecycle", json.encodeToString(state))) { "Request lifecycle could not be saved" }
    }

    fun archiveIntent(intent: WorkTaskWriteIntent) {
        val text = json.encodeToString(intent)
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
        check(write("${intent.persistenceKey}-history-$hash", text)) { "Original request could not be archived" }
        recovery(intent)?.let { check(write("${intent.persistenceKey}-history-$hash-lifecycle", json.encodeToString(it))) }
    }

    fun load(author: String, vineyard: String, task: String?): WorkTaskPlanningDraft? {
        val key = "work-task-planning-$author-$vineyard-${task ?: "new"}"
        val text = read(key) ?: return null
        val draft = json.decodeFromString<WorkTaskPlanningDraft>(text)
        check(draft.authorId == author && draft.vineyardId == vineyard && draft.taskId == task)
        return draft
    }
}
