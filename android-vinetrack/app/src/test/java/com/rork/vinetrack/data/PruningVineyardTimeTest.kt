package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningWorkTiming
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId
import java.util.TimeZone

class PruningVineyardTimeTest {
    @Test fun vineyardWallTimesSaveAndReplayIndependentOfDeviceZone() {
        val previous = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("Europe/London"))
            val cases = mapOf("Australia/Sydney" to "2026-01-14T21:15:00Z", "America/Los_Angeles" to "2026-01-15T16:15:00Z", "Pacific/Auckland" to "2026-01-14T19:15:00Z")
            for ((zoneName, expected) in cases) {
                val zone = ZoneId.of(zoneName)
                val timing = PruningWorkTiming.capture("2026-01-15", "08:15", "16:30", zone)
                val draft = PruningActivityDraft(id = "activity", vineyardId = zoneName, date = "2026-01-15", startTime = "08:15", finishTime = "16:30", workTiming = timing)
                val saved = PruningSyncRepository.activityPayload(draft, zone)
                assertEquals(expected, saved.startTime)
                assertEquals("2026-01-15", saved.entryDate)
                TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Honolulu"))
                val replayed = Json.decodeFromString(PruningActivityDraft.serializer(), Json.encodeToString(PruningActivityDraft.serializer(), draft))
                assertEquals(saved, PruningSyncRepository.activityPayload(replayed, zone))
                assertEquals("08:15", PruningWorkTiming.wall(expected, zone))
            }
        } finally { TimeZone.setDefault(previous) }
    }

    @Test fun pulledLegacyInstantAndAuditValuesArePreservedOnUnrelatedEdit() {
        val raw = "2026-11-01T01:30:42-08:00"
        val zone = ZoneId.of("America/Los_Angeles")
        val row = PruningSyncRepository.EntryRow(id = "entry", vineyardId = "vineyard", pruningSeasonId = "season", paddockId = "block", entryDate = "2026-11-01", startTime = raw, createdAt = "2026-11-02T00:00:00Z")
        val entry = row.toModel(emptyList(), vineyardZone = zone)
        assertEquals("01:30", entry.startTime)
        assertEquals(raw, entry.workTiming?.resolve(entry.date, entry.startTime, entry.finishTime, zone)?.startInstant)
        assertEquals(1793577600000L, entry.createdAtMs)
        assertEquals("2026-11-01T10:00:00Z", entry.workTiming?.resolve(entry.date, "02:00", null, zone)?.startInstant)
    }

    @Test fun replaySnapshotSurvivesSettingsChangeAndUntouchedFinishSurvivesStartEdit() {
        val timing = PruningWorkTiming.capture("2026-01-15", "08:15", "16:30", ZoneId.of("Australia/Sydney"))
        val recovered = Json.decodeFromString(PruningWorkTiming.serializer(), Json.encodeToString(PruningWorkTiming.serializer(), timing))
        assertEquals(timing.startInstant, recovered.resolve(timing.date, timing.startWall, timing.finishWall, ZoneId.of("Pacific/Auckland")).startInstant)
        assertEquals(timing.finishInstant, recovered.resolve(timing.date, "09:15", timing.finishWall, ZoneId.of("Australia/Sydney")).finishInstant)
    }
}
