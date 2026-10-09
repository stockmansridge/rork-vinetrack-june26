package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneId

/** Portal order, without interpreting an E-L compatibility date as a plan. */
object WorkTaskPlanning {
    val supportedStages: List<Int> get() = GrowthStage.allStages.mapNotNull { it.code.removePrefix("EL").toIntOrNull() }.filter { it in 1..43 }

    fun canSaveDraft(draft: WorkTaskPlanningDraft, signedInUser: String?, selectedVineyard: String?, membershipRole: String?): Boolean =
        draft.isValid && draft.authorId == signedInUser && draft.vineyardId == selectedVineyard && membershipRole in listOf("owner", "manager", "supervisor", "operator")

    fun canSelect(resource: VineyardExternalResource, vineyard: String): Boolean = resource.vineyardId == vineyard && resource.isActive && resource.deletedAt == null

    fun completingUser(task: WorkTask, trips: List<Trip>, verifiedMemberIds: Set<String>): String? {
        if (!task.isFinalized) return null
        task.completedBy?.let { return it }
        val linked = trips.filter { it.vineyardId == task.vineyardId && it.workTaskId == task.id && !it.isActive && it.endTime != null }
        val operators = linked.mapNotNull { it.operatorUserId }.toSet()
        if (linked.isNotEmpty() && linked.all { it.operatorUserId != null } && operators.size == 1) return operators.single()
        return task.finalizedBy?.takeIf { it in verifiedMemberIds }
    }

    fun ordered(tasks: List<WorkTask>, now: Instant, zone: ZoneId): List<WorkTask> {
        val today = now.atZone(zone).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli()
        return tasks.sortedWith { lhs, rhs ->
            val lc = lhs.isFinalized
            val rc = rhs.isFinalized
            when {
                lc != rc -> if (lc) 1 else -1
                lhs.isStageScheduled != rhs.isStageScheduled -> if (lhs.isStageScheduled) -1 else 1
                lhs.isStageScheduled -> compareValues(rhs.targetELStage ?: 0, lhs.targetELStage ?: 0).takeIf { it != 0 } ?: lhs.id.compareTo(rhs.id)
                else -> {
                    val ld = (lhs.startDate ?: lhs.date)?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() } ?: Long.MIN_VALUE
                    val rd = (rhs.startDate ?: rhs.date)?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() } ?: Long.MIN_VALUE
                    val lu = ld >= today
                    val ru = rd >= today
                    when {
                        lu != ru -> if (lu) -1 else 1
                        ld != rd -> if (lu) ld.compareTo(rd) else rd.compareTo(ld)
                        else -> lhs.id.compareTo(rhs.id)
                    }
                }
            }
        }
    }
}

/** Durable local-only snapshot, never consumed by Work Task replay. */
@Serializable
data class WorkTaskPlanningDraft(
    val taskId: String?,
    val vineyardId: String,
    val authorId: String,
    val assignedTo: String? = null,
    val externalId: String? = null,
    val assignmentName: String = "",
    val scheduleBasis: String = "date",
    val targetStage: Int? = null,
    val date: String,
    val endDate: String? = null,
    val taskType: String,
    val blockIds: Set<String> = emptySet(),
    val durationText: String = "",
    val notes: String = "",
    /** Original server read, never refreshed implicitly when resuming a draft. */
    val baselineJson: String? = null,
    val creationId: String? = null,
) {
    val isValid: Boolean get() = !(assignedTo != null && externalId != null) &&
        (scheduleBasis == "el_stage" || endDate == null || runCatching { !Instant.parse(endDate).isBefore(Instant.parse(date)) }.getOrDefault(false)) &&
        (scheduleBasis == "date" || (scheduleBasis == "el_stage" && targetStage in WorkTaskPlanning.supportedStages))
    val persistenceKey: String get() = "work-task-planning-$authorId-$vineyardId-${taskId ?: "new"}"
}
