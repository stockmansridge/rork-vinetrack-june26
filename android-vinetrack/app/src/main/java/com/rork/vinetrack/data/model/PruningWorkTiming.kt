package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Persisted work-time boundary, separate from all audit timestamps. */
@Serializable
data class PruningWorkTiming(
    val date: String,
    val startWall: String?,
    val finishWall: String?,
    val zoneId: String,
    val startInstant: String?,
    val finishInstant: String?,
) {
    /** Reuse exact server/save Instants, including seconds and DST overlap offsets, unless edited. */
    fun resolve(date: String, start: String?, finish: String?, zone: ZoneId): PruningWorkTiming =
        copy(
            date = date,
            startWall = start,
            finishWall = finish,
            zoneId = zone.id,
            startInstant = if (date == this.date && start == startWall) startInstant else instant(date, start, zone),
            finishInstant = if (date == this.date && finish == finishWall) finishInstant else instant(date, finish, zone),
        )

    companion object {
        fun capture(date: String, start: String?, finish: String?, zone: ZoneId): PruningWorkTiming =
            PruningWorkTiming(date, start, finish, zone.id, instant(date, start, zone), instant(date, finish, zone))

        fun fromServer(date: String, start: String?, finish: String?, zone: ZoneId): PruningWorkTiming =
            PruningWorkTiming(date, wall(start, zone), wall(finish, zone), zone.id, start, finish)

        fun wall(value: String?, zone: ZoneId): String? = value?.takeIf { it.isNotBlank() }?.let {
            OffsetDateTime.parse(it).atZoneSameInstant(zone).format(DateTimeFormatter.ofPattern("HH:mm"))
        }

        private fun instant(date: String, wall: String?, zone: ZoneId): String? {
            if (wall.isNullOrBlank()) return null
            val local = LocalDateTime.of(LocalDate.parse(date), LocalTime.parse(wall))
            val offsets = zone.rules.getValidOffsets(local)
            require(offsets.isNotEmpty()) { "This work time does not exist in the vineyard timezone. Choose another time." }
            // A newly entered overlap uses the earlier offset consistently; pulled Instants retain their exact offset.
            return local.toInstant(offsets.first()).toString()
        }
    }
}
