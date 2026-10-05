package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.ZoneId

/** Vineyard-calendar completion rules; business dates never replace audit instants. */
object WorkTaskCompletion {
    /** Material picker milliseconds encode a UTC calendar day, not a vineyard instant. */
    fun workDateFromPicker(utcMillis: Long, zone: ZoneId): Instant =
        Instant.ofEpochMilli(utcMillis).atZone(ZoneOffset.UTC).toLocalDate().atStartOfDay(zone).toInstant()

    private fun parseInstant(value: String): Instant? =
        runCatching { Instant.parse(value) }.getOrNull()
            ?: runCatching { java.time.OffsetDateTime.parse(value).toInstant() }.getOrNull()

    /** Preserve legacy UTC-midnight business days without modifying stored rows. */
    fun localDate(value: String?, zone: ZoneId): LocalDate? = value?.let {
        val instant = parseInstant(it)
        if (instant != null) {
            val utc = instant.atZone(ZoneOffset.UTC)
            if (utc.toLocalTime() == LocalTime.MIDNIGHT) utc.toLocalDate() else instant.atZone(zone).toLocalDate()
        } else runCatching { LocalDate.parse(it.take(10)) }.getOrNull()
    }

    fun workDate(task: WorkTask, zone: ZoneId): LocalDate? = localDate(task.startDate ?: task.date, zone)

    fun completedDate(task: WorkTask, zone: ZoneId): LocalDate? =
        if (task.isFinalized) localDate(task.endDate, zone)
            ?: task.finalizedAt?.let { parseInstant(it)?.atZone(zone)?.toLocalDate() } else null

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
