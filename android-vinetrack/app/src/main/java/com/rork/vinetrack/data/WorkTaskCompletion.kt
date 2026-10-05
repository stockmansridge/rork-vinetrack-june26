package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Vineyard-calendar completion rules; business dates never replace audit instants. */
object WorkTaskCompletion {
    fun localDate(value: String?, zone: ZoneId): LocalDate? = value?.let {
        runCatching { Instant.parse(it).atZone(zone).toLocalDate() }.getOrNull()
            ?: runCatching { java.time.OffsetDateTime.parse(it).atZoneSameInstant(zone).toLocalDate() }.getOrNull()
            ?: runCatching { LocalDate.parse(it.take(10)) }.getOrNull()
    }

    fun workDate(task: WorkTask, zone: ZoneId): LocalDate? = localDate(task.startDate ?: task.date, zone)

    fun completedDate(task: WorkTask, zone: ZoneId): LocalDate? =
        if (task.isFinalized) localDate(task.endDate, zone) ?: localDate(task.finalizedAt, zone) else null

    fun isValid(task: WorkTask, selected: LocalDate, zone: ZoneId, now: Instant): Boolean =
        !selected.isAfter(now.atZone(zone).toLocalDate()) &&
            (workDate(task, zone)?.let { !selected.isBefore(it) } ?: true)

    fun complete(task: WorkTask, selected: LocalDate, zone: ZoneId, now: Instant, userId: String): WorkTask {
        require(isValid(task, selected, zone, now)) { "Completed Date must be between Work Date and today." }
        return task.copy(isFinalized = true, endDate = selected.atStartOfDay(zone).toInstant().toString(),
            finalizedAt = now.toString(), finalizedBy = userId)
    }

    fun editDate(task: WorkTask, selected: LocalDate, zone: ZoneId, now: Instant): WorkTask {
        require(task.isFinalized && isValid(task, selected, zone, now))
        return task.copy(endDate = selected.atStartOfDay(zone).toInstant().toString())
    }

    fun reopen(task: WorkTask): WorkTask = task.copy(isFinalized = false, endDate = null, finalizedAt = null, finalizedBy = null)
}
