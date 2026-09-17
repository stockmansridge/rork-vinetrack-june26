package com.rork.vinetrack.data.insights

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class VineyardInsightsHistoryTest {
    private fun visit(id: String, vineyard: String, vintage: Int, date: String, updated: String): ScoutVisit =
        ScoutVisit(
            id = id,
            vineyardId = vineyard,
            vintageYear = vintage,
            scoutDateIso = date,
            scoutUserId = "observer",
            scoutNameSnapshot = "Observer",
            clientUpdatedAtIso = updated,
        )

    private fun note(id: String, vineyard: String, vintage: Int, date: String, created: String): VintageNote =
        VintageNote(
            id = id,
            vineyardId = vineyard,
            noteDateIso = date,
            vintageYear = vintage,
            noteTypeId = "frost",
            noteTypeLabelSnapshot = "Frost",
            notes = id,
            observedByUserId = "observer",
            observerNameSnapshot = "Observer",
            createdAtIso = created,
            updatedAtIso = created,
            clientUpdatedAtIso = created,
        )

    @Test
    fun `three scouts including same date remain separate scoped and newest first`() {
        val visits = listOf(
            visit("a", "v1", 2026, "2026-02-01", "2026-02-01T08:00:00Z"),
            visit("b", "v1", 2026, "2026-02-01", "2026-02-01T09:00:00Z"),
            visit("c", "v1", 2026, "2026-03-01", "2026-03-01T08:00:00Z"),
            visit("other", "v2", 2026, "2026-04-01", "2026-04-01T08:00:00Z"),
        )

        assertEquals(listOf("c", "b", "a"), ScoutHistoryPolicy.select(visits, "v1", 2026).map { it.id })
        assertEquals(3, ScoutHistoryPolicy.select(visits, "v1", null).size)
    }

    @Test
    fun `three notes including same date and type remain separate scoped and newest first`() {
        val notes = listOf(
            note("a", "v1", 2026, "2026-02-01", "2026-02-01T08:00:00Z"),
            note("b", "v1", 2026, "2026-02-01", "2026-02-01T09:00:00Z"),
            note("c", "v1", 2026, "2026-03-01", "2026-03-01T08:00:00Z"),
            note("other", "v2", 2026, "2026-04-01", "2026-04-01T08:00:00Z"),
        )

        assertEquals(listOf("c", "b", "a"), VintageNoteRules.history(notes, "v1", 2026).map { it.id })
        assertNotEquals(notes[0].id, notes[1].id)
    }
}
