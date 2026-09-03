package com.rork.vinetrack.data

import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.data.ripeness.ElRipenessObservationAdapter
import com.rork.vinetrack.data.ripeness.ElRipenessSeason
import com.rork.vinetrack.data.ripeness.RipenessObservationRow
import com.rork.vinetrack.ui.screens.VintageYearText
import com.rork.vinetrack.ui.screens.buildGrowthStageRecordEntries
import com.rork.vinetrack.data.model.GrowthStageRecord
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GrowthStageLiveDecodingTest {
    private val vineyardId = "11111111-1111-1111-1111-111111111111"
    private val paddockId = "22222222-2222-2222-2222-222222222222"

    private fun productionJson(count: Int = 3): String = (1..count).joinToString(",", "[", "]") { index ->
        """{"id":"00000000-0000-0000-0000-00000000000$index","vineyard_id":"$vineyardId","paddock_id":"$paddockId","pin_id":null,"stage_code":"EL2","stage_label":"E-L 2","variety":"Grüner Veltliner","variety_id":null,"observed_at":"2026-09-02T00:56:19.668Z","latitude":-33.312,"longitude":149.102,"row_number":null,"side":null,"notes":null,"photo_paths":[],"recorded_by_name":"Operator","created_by":null,"updated_by":null,"created_at":"2026-09-02T00:56:19.668Z","updated_at":"2026-09-02T00:56:19.668Z","source":"growth_stage_records"}"""
    }

    @Test
    fun `production view JSON decodes observed_at and preserves null pin identities`() {
        val rows = Json.decodeFromString<List<RipenessObservationRow>>(productionJson())
        val sources = rows.map { it.sourceRecord() }
        val observations = ElRipenessObservationAdapter.observations(sources, vineyardId)

        assertEquals(3, rows.size)
        assertTrue(rows.all { it.pinId == null && it.stageCode == "EL2" })
        assertEquals(3, sources.map { it.dedupeKey }.toSet().size)
        assertEquals(3, observations.size)
        assertTrue(observations.all { it.el == 2.0 && it.dateIso == "2026-09-02T00:56:19.668Z" })
        assertTrue(observations.all { it.assigned && it.paddockId == paddockId })
        assertEquals(2027, ElRipenessSeason.vintageForDayKey(observations.first().dateIso, 7, 1))
    }

    @Test
    fun `Stockmans fixture produces exact acceptance counts and a surface`() {
        val sources = Json.decodeFromString<List<RipenessObservationRow>>(productionJson()).map { it.sourceRecord() }
        val observations = ElRipenessObservationAdapter.observations(sources, vineyardId)
        val main = listOf(
            ElRipenessHeatmap.LatLng(-33.313, 149.101),
            ElRipenessHeatmap.LatLng(-33.313, 149.103),
            ElRipenessHeatmap.LatLng(-33.311, 149.103),
            ElRipenessHeatmap.LatLng(-33.311, 149.101),
        )
        val blocks = (0 until 8).map { index ->
            ElRipenessHeatmap.BlockInput(
                id = if (index == 0) paddockId else "block-$index",
                name = if (index == 0) "Grüner Veltliner" else "Block $index",
                polygon = if (index == 0) main else main.map { ElRipenessHeatmap.LatLng(it.lat + index, it.lng) },
            )
        }
        val heat = ElRipenessHeatmap.buildHeatModel(observations, blocks, "2026-09-02")
        val diagnostics = ElRipenessObservationAdapter.diagnosticCounts(sources, vineyardId, 3, "2026-09-02")

        assertEquals(3, heat.qualifying.size)
        assertEquals(3, heat.influencing.size)
        assertEquals(0, heat.stale.size)
        assertEquals(2.0, heat.medianEl!!, 0.0)
        assertEquals(ElRipenessHeatmap.Mode.SURFACE, heat.blocks.first().mode)
        assertEquals(3, heat.blocks.first().observations.size)
        assertEquals(8, blocks.count { it.polygon.size >= 3 })
        assertEquals(3, diagnostics.remoteRowsDecoded)
        assertEquals(3, diagnostics.qualifyingObservations)
    }

    @Test
    fun `Growth Stage export payload contains the three visible EL records`() {
        val records = Json { ignoreUnknownKeys = true }
            .decodeFromString<List<GrowthStageRecord>>(productionJson())
        val entries = buildGrowthStageRecordEntries(records, emptyList())

        assertEquals(3, entries.size)
        assertTrue(entries.all { it.stage == "EL2" })
        assertTrue(entries.all { it.blockName == "—" })
        assertTrue(entries.all { it.recorder == "Operator" })
        assertTrue(entries.all { it.observedAtEpochMs > 0L })
    }

    @Test
    fun `Vintage identifiers never use grouping`() {
        assertEquals("2027", VintageYearText.format(2027))
        assertEquals("2026", VintageYearText.format(2026))
        assertEquals("Vintage 2027", VintageYearText.label(2027))
        assertFalse(VintageYearText.label(2027).contains(','))
    }
}
