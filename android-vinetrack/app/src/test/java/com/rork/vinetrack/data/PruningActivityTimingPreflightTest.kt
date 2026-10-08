package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningActivityTimingPreflight
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId

class PruningActivityTimingPreflightTest {
    @Test fun `missing historical day blocks all task mutations even with no wall times`() {
        val missing = PruningActivityDraft(id = "activity", vineyardId = "vineyard", date = "")
        for (zone in listOf("Australia/Sydney", "America/Los_Angeles", "Pacific/Auckland")) {
            for (action in listOf("link", "unlink", "create", "update", "save")) {
                var mutations = 0
                val result = runCatching {
                    PruningActivityTimingPreflight.prepare(missing, ZoneId.of(zone))
                    mutations++
                }
                assertTrue(action, result.isFailure)
                assertEquals(0, mutations)
                assertEquals("", missing.date)
            }
        }
    }

    @Test fun `DST rejection precedes mutation and frozen replay retains business day and instant`() {
        val invalid = PruningActivityDraft(id = "activity", vineyardId = "vineyard", date = "2026-10-04", startTime = "02:30")
        assertTrue(runCatching { PruningActivityTimingPreflight.prepare(invalid, ZoneId.of("Australia/Sydney")) }.isFailure)
        val draft = invalid.copy(date = "2026-07-01", startTime = "08:15")
        val prepared = PruningActivityTimingPreflight.prepare(draft, ZoneId.of("Australia/Sydney"))
        val replay = Json.decodeFromString(PruningActivityDraft.serializer(), Json.encodeToString(PruningActivityDraft.serializer(), prepared))
        val retried = PruningActivityTimingPreflight.prepare(replay, ZoneId.of("America/Los_Angeles"))
        assertEquals("2026-07-01", retried.date)
        assertEquals(prepared.workTiming!!.startInstant, retried.workTiming!!.startInstant)
    }
}
