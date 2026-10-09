package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Durable original request, isolated from replay queues. */
@Serializable
data class WorkTaskWriteIntent(
    val taskId: String, val vineyardId: String, val authorId: String,
    val baselineJson: String?, val payload: JsonObject, val acknowledged: Boolean = false,
) {
    val persistenceKey: String get() = "work-task-write-$authorId-$vineyardId-$taskId"
}

/** Portal contract at immutable commit 2bed6ee35f44be381c5b5ae87dbae4c9c5065046. */
object WorkTaskWriteContract {
    fun schedule(basis: String, stage: Int?, day: LocalDate, existingDate: JsonElement?): JsonObject {
        require(basis in listOf("date", "el_stage"))
        return buildJsonObject {
            put("schedule_basis", basis)
            if (basis == "el_stage") {
                require(stage in com.rork.vinetrack.data.model.WorkTaskPlanning.supportedStages)
                put("target_el_stage", stage?.let(::JsonPrimitive) ?: JsonNull); put("start_date", JsonNull)
                existingDate?.let { put("date", it) }
            } else {
                put("target_el_stage", JsonNull); put("start_date", day.toString()); put("date", day.toString())
            }
        }
    }
    fun completion(action: String, task: WorkTask, selected: LocalDate?, zone: ZoneId, now: Instant, author: String): JsonObject {
        require(if (action == "complete") !task.isFinalized else task.isFinalized)
        return buildJsonObject {
            if (action == "reopen") {
                put("is_finalized", false)
                listOf("end_date", "finalized_at", "finalized_by", "completed_by", "completed_at").forEach { put(it, JsonNull) }
            } else {
                require(action in listOf("complete", "completion_date") && selected != null && WorkTaskCompletion.isValid(task, selected, zone, now))
                put("is_finalized", true); put("end_date", selected.toString())
                if (action == "complete") {
                    put("finalized_at", now.toString()); put("completed_at", now.toString())
                    put("finalized_by", author); put("completed_by", author)
                }
            }
        }
    }
    fun planning(draft: WorkTaskPlanningDraft, id: String, day: LocalDate, now: Instant, paddockId: String?, paddockName: String, area: Double): WorkTaskWriteIntent {
        require(draft.isValid && draft.taskType.isNotBlank())
        val baseline = draft.baselineJson?.let { Json.parseToJsonElement(it).jsonObject }
        require(draft.taskId == null || baseline != null)
        val payload = buildJsonObject {
            put("task_type", draft.taskType); put("notes", draft.notes)
            put("duration_hours", draft.durationText.replace(',', '.').toDoubleOrNull() ?: 0.0)
            put("paddock_id", paddockId?.let(::JsonPrimitive) ?: JsonNull); put("paddock_name", paddockName)
            put("client_updated_at", now.toString()); put("updated_by", draft.authorId)
            if (baseline != null && area > 0 && baseline["paddock_name"]?.jsonPrimitive?.contentOrNull != paddockName) put("area_ha", area)
            val assignment = draft.assignedTo?.let(::JsonPrimitive) ?: JsonNull
            val external = draft.externalId?.let(::JsonPrimitive) ?: JsonNull
            if (baseline == null || baseline["assigned_to"] != assignment || baseline["assigned_external_resource_id"] != external) {
                put("assigned_to", assignment); put("assigned_external_resource_id", external)
            }
            val currentDay = (baseline?.get("start_date").takeUnless { it == JsonNull } ?: baseline?.get("date"))?.jsonPrimitive?.contentOrNull?.take(10)
            if (baseline == null || baseline["schedule_basis"]?.jsonPrimitive?.content != draft.scheduleBasis ||
                (if (draft.scheduleBasis == "el_stage") baseline["target_el_stage"]?.jsonPrimitive?.intOrNull != draft.targetStage else currentDay != day.toString())) {
                schedule(draft.scheduleBasis, draft.targetStage, day, baseline?.get("date")).forEach { (k, v) -> put(k, v) }
            }
            if (baseline != null) {
                val version = baseline.getValue("sync_version").jsonPrimitive.long
                require(version > 0 && version < Long.MAX_VALUE); put("sync_version", version + 1)
            } else {
                put("id", id); put("vineyard_id", draft.vineyardId); put("sync_version", 1)
                put("created_by", draft.authorId); put("is_finalized", false); put("is_archived", false)
                put("end_date", JsonNull); put("description", ""); put("deleted_at", JsonNull); put("area_ha", area)
            }
        }
        return WorkTaskWriteIntent(id, draft.vineyardId, draft.authorId, draft.baselineJson, payload)
    }
    fun equivalent(a: JsonElement?, b: JsonElement?, key: String): Boolean {
        if (a == null || b == null) return false
        if (a == b) return true
        if (a == JsonNull || b == JsonNull) return false
        val x = a.jsonPrimitive.content; val y = b.jsonPrimitive.content
        if (key in listOf("date", "start_date", "end_date") && (x.length == 10 || y.length == 10)) return x.take(10) == y.take(10)
        if (key.endsWith("_at") || key in listOf("date", "start_date", "end_date")) return runCatching { Instant.parse(x) == Instant.parse(y) }.getOrDefault(false)
        if (key == "id" || key.endsWith("_id") || key in listOf("assigned_to", "completed_by", "finalized_by", "created_by", "updated_by")) return x.equals(y, ignoreCase = true)
        return a.jsonPrimitive.doubleOrNull?.let { it == b.jsonPrimitive.doubleOrNull } ?: false
    }
    fun predicates(baseline: JsonObject, observedKeys: List<String>): Map<String, String> {
        val version = baseline["sync_version"]?.jsonPrimitive?.longOrNull
        require(observedKeys.all { it in baseline } && version != null && version > 0 && version < Long.MAX_VALUE && baseline["deleted_at"] == JsonNull)
        return observedKeys.associateWith { key -> baseline.getValue(key).let { if (it == JsonNull) "is.null" else "eq.${it.jsonPrimitive.content}" } }
    }
    fun verify(baseline: JsonObject?, payload: JsonObject, row: JsonObject, observedKeys: List<String>) {
        check(payload.all { (key, value) -> equivalent(value, row[key], key) }) { WorkTaskPlanningRepository.conflictMessage }
        if (baseline != null) check(observedKeys.filter { it !in payload && it != "updated_at" && !(it == "vintage_year" && "date" in payload && !equivalent(payload["date"], baseline["date"], "date")) }
            .all { equivalent(baseline[it], row[it], it) }) { WorkTaskPlanningRepository.conflictMessage }
        check(row["vintage_year"]?.jsonPrimitive?.intOrNull != null) { WorkTaskPlanningRepository.conflictMessage }
    }
}
