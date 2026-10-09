package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.http.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

/** Narrow online existing-schema writes. No queue, save-time rebase or ambiguous-response retry. */
class WorkTaskPlanningRepository(private val session: SessionStore) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun baseline(task: WorkTask): String = withContext(Dispatchers.IO) {
        require(session.selectedVineyardId == task.vineyardId && (task.syncVersion ?: 0) > 0) { refreshMessage }
        val author = session.userId ?: error("Sign in required")
        val response = SupabaseClient.http.get(SupabaseClient.restUrl("work_tasks")) {
            auth(); parameter("select", observedKeys.joinToString(",")); parameter("id", "eq.${task.id}")
            parameter("vineyard_id", "eq.${task.vineyardId}"); parameter("sync_version", "eq.${task.syncVersion}"); parameter("deleted_at", "is.null")
        }
        check(response.status.isSuccess()) { refreshMessage }
        val row = json.parseToJsonElement(response.bodyAsText()).jsonArray.singleOrNull()?.jsonObject ?: error(refreshMessage)
        val typed = json.decodeFromJsonElement<WorkTask>(row)
        check(observedKeys.all { it in row } && typed.syncVersion == task.syncVersion &&
            typed.assignedTo == task.assignedTo && typed.assignedExternalResourceId == task.assignedExternalResourceId &&
            typed.scheduleBasis == task.scheduleBasis && typed.targetELStage == task.targetELStage &&
            typed.isFinalized == task.isFinalized && typed.status == task.status && typed.completedBy == task.completedBy &&
            typed.taskType == task.taskType && typed.notes == task.notes && typed.paddockId == task.paddockId && typed.paddockName == task.paddockName &&
            typed.durationHours == task.durationHours && typed.isArchived == task.isArchived &&
            sameInstant(typed.date, task.date) && sameInstant(typed.startDate, task.startDate) && sameInstant(typed.endDate, task.endDate) &&
            sameInstant(typed.completedAt, task.completedAt) && sameInstant(typed.finalizedAt, task.finalizedAt) && typed.finalizedBy == task.finalizedBy &&
            session.userId == author && session.selectedVineyardId == task.vineyardId) { refreshMessage }
        row.toString()
    }

    suspend fun saveSelection(draft: WorkTaskPlanningDraft): WorkTask = withContext(Dispatchers.IO) {
        require(session.userId == draft.authorId && session.selectedVineyardId == draft.vineyardId && draft.isValid)
        val row = draft.baselineJson?.let { json.parseToJsonElement(it).jsonObject } ?: error(refreshMessage)
        val expected = json.decodeFromJsonElement<WorkTask>(row)
        val version = expected.syncVersion ?: error(refreshMessage)
        require(observedKeys.all { it in row } && expected.id == draft.taskId && expected.vineyardId == draft.vineyardId &&
            expected.deletedAt == null && version > 0 && version < Long.MAX_VALUE && expected.scheduleBasis == draft.scheduleBasis) { refreshMessage }
        val membership = SupabaseClient.http.get(SupabaseClient.restUrl("vineyard_members")) {
            auth(); parameter("select", "role"); parameter("vineyard_id", "eq.${draft.vineyardId}"); parameter("user_id", "eq.${draft.authorId}")
        }
        check(membership.status.isSuccess()) { "Vineyard membership required" }
        val member = json.parseToJsonElement(membership.bodyAsText()).jsonArray.singleOrNull()?.jsonObject
        require(member?.get("role")?.jsonPrimitive?.content in listOf("owner", "manager", "supervisor", "operator"))
        val assignmentChanged = expected.assignedTo != draft.assignedTo || expected.assignedExternalResourceId != draft.externalId
        val stageChanged = draft.scheduleBasis == "el_stage" && expected.targetELStage != draft.targetStage
        require(assignmentChanged || stageChanged) { "No assignment or existing E-L target change. Other fields remain in your local draft." }
        if (assignmentChanged && draft.assignedTo != null) {
            val response = SupabaseClient.http.get(SupabaseClient.restUrl("vineyard_members")) {
                auth(); parameter("select", "user_id"); parameter("vineyard_id", "eq.${draft.vineyardId}"); parameter("user_id", "eq.${draft.assignedTo}")
            }
            check(response.status.isSuccess() && json.parseToJsonElement(response.bodyAsText()).jsonArray.size == 1) { "Choose a current vineyard member." }
        }
        if (assignmentChanged && draft.externalId != null) {
            check(ExternalResourceRepository(session).list(draft.vineyardId).any { it.id == draft.externalId && it.isActive && it.deletedAt == null }) { "Choose an active vineyard resource." }
        }
        require(session.userId == draft.authorId && session.selectedVineyardId == draft.vineyardId)
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("work_tasks")) {
            auth(); headers { append("Prefer", "return=representation") }; contentType(ContentType.Application.Json)
            observedKeys.forEach { key ->
                val value = row.getValue(key)
                parameter(key, if (value == JsonNull) "is.null" else "eq.${value.jsonPrimitive.content}")
            }
            setBody(selectionPatch(draft, assignmentChanged, stageChanged, version + 1).toString())
        }
        check(response.status.isSuccess()) { conflictMessage }
        val acknowledgement = json.parseToJsonElement(response.bodyAsText()).jsonArray.singleOrNull()?.jsonObject ?: error(conflictMessage)
        val changedKeys = setOf("updated_at", "sync_version") +
            (if (assignmentChanged) setOf("assigned_to", "assigned_external_resource_id") else emptySet()) +
            (if (stageChanged) setOf("target_el_stage") else emptySet())
        check(observedKeys.filterNot { it in changedKeys }.all { row[it] == acknowledgement[it] }) { conflictMessage }
        val saved = json.decodeFromJsonElement<WorkTask>(acknowledgement)
        check(saved.id == draft.taskId && saved.vineyardId == draft.vineyardId && saved.syncVersion == version + 1 &&
            saved.assignedTo == draft.assignedTo && saved.assignedExternalResourceId == draft.externalId &&
            (!stageChanged || saved.targetELStage == draft.targetStage) && session.userId == draft.authorId && session.selectedVineyardId == draft.vineyardId) { conflictMessage }
        saved
    }

    private fun HttpRequestBuilder.auth() {
        val token = session.accessToken ?: error("Sign in required")
        headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
    }

    companion object {
        private fun sameInstant(a: String?, b: String?): Boolean =
            if (a == null || b == null) a == b else runCatching { java.time.Instant.parse(a) == java.time.Instant.parse(b) }.getOrDefault(a == b)
        const val refreshMessage = "Refresh the task before a new online selection edit. This draft has no matching original baseline; it was not rebased or queued."
        const val conflictMessage = "Task changed, permission was lost, or save was not acknowledged. Local draft retained; review server state before resolving. No automatic retry."
        val observedKeys = listOf("id", "vineyard_id", "sync_version", "updated_at", "deleted_at", "is_archived",
            "assigned_to", "assigned_external_resource_id", "schedule_basis", "target_el_stage", "date", "start_date", "end_date", "vintage_year",
            "status", "is_finalized", "completed_by", "completed_at", "finalized_by", "finalized_at",
            "task_type", "description", "notes", "paddock_id", "paddock_name", "duration_hours")

        /** Deliberately excludes dates, lifecycle, costs, resource JSON and generated-task links. */
        fun selectionPatch(draft: WorkTaskPlanningDraft, assignmentChanged: Boolean, stageChanged: Boolean, version: Long): JsonObject = buildJsonObject {
            if (assignmentChanged) {
                put("assigned_to", draft.assignedTo?.let(::JsonPrimitive) ?: JsonNull)
                put("assigned_external_resource_id", draft.externalId?.let(::JsonPrimitive) ?: JsonNull)
            }
            if (stageChanged) put("target_el_stage", draft.targetStage?.let(::JsonPrimitive) ?: JsonNull)
            put("sync_version", version)
        }
    }
}
