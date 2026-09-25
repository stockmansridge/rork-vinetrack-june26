package com.rork.vinetrack.data

import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ElRipenessBlockDisplayTest {
    private fun row(id: String, el: String, block: String = "A", date: String = "2026-01-20",
                    vineyard: String = "vineyard", deleted: String? = null) = ElRipenessHeatmap.RawRecord(
        id = id, vineyardId = vineyard, paddockId = block, stageCode = el,
        latitude = -34.5, longitude = 138.5, date = date, deletedAt = deleted,
    )

    private fun block(records: List<ElRipenessHeatmap.RawRecord>, date: String = "2026-01-25"): ElRipenessHeatmap.BlockHeat {
        val normalized = ElRipenessHeatmap.toObservations(records, selectedVineyardId = "vineyard")
        val season = ElRipenessHeatmap.filterToVintage(normalized, "2025-07-01", "2026-06-30")
        val polygon = listOf(
            ElRipenessHeatmap.LatLng(-34.51, 138.49), ElRipenessHeatmap.LatLng(-34.51, 138.51),
            ElRipenessHeatmap.LatLng(-34.49, 138.51), ElRipenessHeatmap.LatLng(-34.49, 138.49),
        )
        return ElRipenessHeatmap.buildHeatModel(
            season, listOf(ElRipenessHeatmap.BlockInput("A", polygon = polygon)), date, resolution = 3,
        ).blocks.single()
    }

    @Test fun labelShowsHighestEligibleRecordedStageOnly() {
        val four = block(listOf(row("1", "15"), row("2", "17"), row("3", "18"), row("4", "21")))
        assertEquals(21.0, four.displayEl)
        assertEquals("E-L 21", ElRipenessHeatmap.formatEl(four.displayEl))
        assertEquals(17.5, four.medianEl)
        assertEquals(29.0, block(listOf(row("1", "27"), row("2", "27"), row("3", "29"))).displayEl)
        assertEquals(23.0, block(listOf(row("1", "23"))).displayEl)
        assertNull(block(emptyList()).displayEl)
    }

    @Test fun labelRespectsExistingScopingAndCurrentObservationRules() {
        val valid = row("valid", "21")
        assertEquals(21.0, block(listOf(valid, row("other-block", "47", block = "B"))).displayEl)
        assertEquals(21.0, block(listOf(valid, row("other-vintage", "47", date = "2024-01-20"))).displayEl)
        assertEquals(21.0, block(listOf(valid, row("future", "47", date = "2026-01-26"))).displayEl)
        assertEquals(21.0, block(listOf(valid, row("deleted", "47", deleted = "2026-01-21"))).displayEl)
        assertEquals(21.0, block(listOf(valid, row("invalid", "E-L 99"))).displayEl)
        assertEquals(21.0, block(listOf(valid, row("other-vineyard", "47", vineyard = "elsewhere"))).displayEl)
        assertNull(block(listOf(row("old", "47", date = "2025-09-01"))).displayEl)
    }
}
