package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.TaskWriteRecovery
import com.rork.vinetrack.data.WorkTaskWriteIntent
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import kotlinx.serialization.json.*

/** Read-only admission of explicitly authored editor evidence. Never retries or acknowledges a save. */
internal object RetainedPlanningContract {
    private val json = Json { ignoreUnknownKeys = false; encodeDefaults = true; explicitNulls = true }

    fun inspect(values: Map<String, *>, original: String?): Set<String> {
        if (values.isEmpty()) return emptySet()
        check(!original.isNullOrBlank())
        val scopes = mutableSetOf<String>()
        val intents = mutableMapOf<String, WorkTaskWriteIntent>()
        fun identity(author: String, vineyard: String) {
            check(author == original && vineyard.isNotBlank())
            scopes.add(vineyard)
        }
        fun baseline(raw: String?, task: String?, vineyard: String) {
            if (raw == null) { check(task == null); return }
            val row = json.parseToJsonElement(raw).jsonObject
            check(task != null && row["id"]?.jsonPrimitive?.contentOrNull == task &&
                row["vineyard_id"]?.jsonPrimitive?.contentOrNull == vineyard)
        }
        values.forEach { (key, raw) ->
            check(raw is String)
            when {
                key.startsWith("work-task-planning-") -> {
                    val draft = json.decodeFromString<WorkTaskPlanningDraft>(raw)
                    check(key == draft.persistenceKey && draft.isValid)
                    identity(draft.authorId, draft.vineyardId)
                    baseline(draft.baselineJson, draft.taskId, draft.vineyardId)
                }
                key.startsWith("work-task-write-") && !key.endsWith("-lifecycle") -> {
                    val intent = json.decodeFromString<WorkTaskWriteIntent>(raw)
                    identity(intent.authorId, intent.vineyardId)
                    check(intent.taskId.isNotBlank())
                    baseline(intent.baselineJson, intent.taskId.takeIf { intent.baselineJson != null }, intent.vineyardId)
                    val payload = intent.payload
                    check(payload["updated_by"]?.jsonPrimitive?.contentOrNull == original)
                    if (intent.baselineJson == null) {
                        check(payload["id"]?.jsonPrimitive?.contentOrNull == intent.taskId &&
                            payload["vineyard_id"]?.jsonPrimitive?.contentOrNull == intent.vineyardId &&
                            payload["created_by"]?.jsonPrimitive?.contentOrNull == original)
                    }
                    listOf("id" to intent.taskId, "vineyard_id" to intent.vineyardId,
                        "created_by" to original, "updated_by" to original).forEach { (field, expected) ->
                        payload[field]?.let { check(it.jsonPrimitive.contentOrNull == expected) }
                    }
                    val hash = java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())
                        .joinToString("") { "%02x".format(it) }
                    check(key == intent.persistenceKey || key == "${intent.persistenceKey}-history-$hash")
                    intents[key] = intent
                }
                else -> check(key.startsWith("work-task-write-") && key.endsWith("-lifecycle"))
            }
        }
        values.filterKeys { it.endsWith("-lifecycle") }.forEach { (key, raw) ->
            val state = json.decodeFromString<TaskWriteRecovery>(raw as String)
            val intent = checkNotNull(intents[key.removeSuffix("-lifecycle")])
            check(state.original.copy(acknowledged = false) == intent.copy(acknowledged = false))
            state.confirmed?.let { check(it.id == intent.taskId && it.vineyardId == intent.vineyardId) }
        }
        return scopes
    }
}
