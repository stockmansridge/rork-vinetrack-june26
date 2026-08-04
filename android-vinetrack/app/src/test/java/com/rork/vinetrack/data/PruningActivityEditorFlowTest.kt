package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningActivityListing
import com.rork.vinetrack.data.model.PruningAllocationEditor
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSegment
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The multi-block EDITOR + LIST wiring (sql/166) — the exact user journeys the
 * Pruning Tracker screens drive:
 *
 *  * create a one-block and a two-block activity,
 *  * switch blocks without losing selections,
 *  * save, reopen, add a third block, remove the primary block,
 *  * change the date across a year boundary,
 *  * replay one queued activity atomically,
 *  * adopt the COMPLETE canonical response,
 *  * report quarter conflicts instead of a clean success,
 *  * reverse the whole activity,
 *  * open a legacy single-block entry.
 */
class PruningActivityEditorFlowTest {

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val cabFranc = "22222222-2222-4222-8222-222222222222"
    private val sauvBlanc = "33333333-3333-4333-8333-333333333333"
    private val pinot = "44444444-4444-4444-8444-444444444444"
    private val activityId = "55555555-5555-4555-8555-555555555555"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun draft(date: String = "2026-08-04"): PruningActivityDraft =
        PruningActivityDraft(
            id = activityId,
            vineyardId = vineyard,
            date = date,
            worker = "Jon",
            method = "spur",
            startTime = "08:00",
            finishTime = "15:30",
            labourHours = 7.5,
            hourlyRate = 35.0,
            notes = "Cab Franc then Sauvignon Blanc",
        )

    private fun rows(vararg numbers: Int): List<PruningSegment> =
        numbers.flatMap { row -> (1..4).map { PruningSegment(row = row, quarter = it) } }

    // ---- create ------------------------------------------------------------

    @Test
    fun `create a one-block activity`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42, 43), "Cab Franc")

        assertTrue(d.canSave)
        assertEquals(1, d.blockCount)
        assertEquals(8, d.totalQuarters)
        assertEquals("Cab Franc", PruningActivityListing.blockLabel(d.activeAllocations.map { it.blockName }))
        assertEquals("42–43", PruningActivityListing.rowRangeLabel(d.activeAllocations.first().rows))
    }

    @Test
    fun `create a two-block activity with labour recorded once`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42, 43, 44), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66, 67), "Sauvignon Blanc")

        assertEquals(2, d.blockCount)
        assertEquals(20, d.totalQuarters)
        assertEquals(5.0, d.totalRowEquivalents, 0.0001)
        assertEquals(
            "Cab Franc + Sauvignon Blanc",
            PruningActivityListing.blockLabel(d.activeAllocations.map { it.blockName }),
        )
        // ONE payload, both allocations, labour on the parent only.
        val allocations = PruningSyncRepository.allocationPayloads(d)
        assertEquals(2, allocations.size)
        assertEquals(setOf(cabFranc, sauvBlanc), allocations.map { it.paddockId }.toSet())
        val activity = PruningSyncRepository.activityPayload(d)
        assertEquals(7.5, activity.labourHours!!, 0.0001)
        assertEquals(35.0, activity.hourlyRate!!, 0.0001)
    }

    @Test
    fun `switching blocks in the editor keeps every earlier selection`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.focus(d, sauvBlanc, "Sauvignon Blanc")
        d = PruningAllocationEditor.toggleSegment(d, sauvBlanc, PruningSegment(66, 2))
        d = PruningAllocationEditor.focus(d, cabFranc)

        assertEquals(cabFranc, d.focusedPaddockId)
        assertEquals(4, d.allocations.getValue(cabFranc).quarters)
        assertEquals(1, d.allocations.getValue(sauvBlanc).quarters)
        // Activity-level fields survive every focus change.
        assertEquals("Jon", d.worker)
        assertEquals(7.5, d.labourHours!!, 0.0001)
        assertEquals("08:00", d.startTime)
    }

    // ---- save / reopen / edit ---------------------------------------------

    @Test
    fun `save and reopen restores every block allocation`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42, 43), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")

        // The offline draft persists the COMPLETE activity, not just the block
        // that happened to be on screen.
        val stored = json.encodeToString(PruningActivityDraft.serializer(), PruningAllocationEditor.pruneEmptyBlocks(d))
        val reopened = json.decodeFromString(PruningActivityDraft.serializer(), stored)

        assertEquals(2, reopened.blockCount)
        assertEquals(listOf(42, 43), reopened.allocations.getValue(cabFranc).rows)
        assertEquals(listOf(66), reopened.allocations.getValue(sauvBlanc).rows)
        assertEquals(7.5, reopened.labourHours!!, 0.0001)
        assertEquals(d.blockSummary, reopened.blockSummary)
    }

    @Test
    fun `add a third block while editing`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        d = d.copy(serverAcknowledged = true)

        d = PruningAllocationEditor.setSegments(d, pinot, rows(21), "Pinot Noir")

        assertEquals(3, d.blockCount)
        assertEquals(12, d.totalQuarters)
        assertEquals(
            "Cab Franc + Sauvignon Blanc +1 more",
            PruningActivityListing.blockLabel(d.activeAllocations.map { it.blockName }),
        )
        // Full desired state: an edit sends every allocation, labour still once.
        assertEquals(3, PruningSyncRepository.allocationPayloads(d).size)
        assertEquals(1, PruningAllocationEditor.toLegacyEntries(d).count { it.labourHours != null })
    }

    @Test
    fun `removing the primary block retains the activity labour`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        val primary = d.activeAllocations.first().paddockId

        d = PruningAllocationEditor.removeBlock(d, primary)

        assertEquals(1, d.blockCount)
        assertNull(d.allocations[primary])
        assertEquals(7.5, d.labourHours!!, 0.0001)
        assertEquals(35.0, d.hourlyRate!!, 0.0001)
        assertEquals("08:00", d.startTime)
        assertEquals("15:30", d.finishTime)
        // The surviving allocation is promoted to carry the labour mirror.
        val legacy = PruningAllocationEditor.toLegacyEntries(d)
        assertEquals(1, legacy.size)
        assertEquals(7.5, legacy.first().labourHours!!, 0.0001)
    }

    @Test
    fun `changing the activity date across a year boundary re-files every allocation`() {
        var d = draft("2026-12-31")
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        assertEquals(2026, d.seasonYear)

        d = d.copy(date = "2027-01-01")

        assertEquals(2027, d.seasonYear)
        assertEquals(2, d.blockCount)
        assertEquals("2027-01-01", PruningSyncRepository.activityPayload(d).entryDate)
        assertTrue(PruningAllocationEditor.toLegacyEntries(d).all { it.date == "2027-01-01" })
    }

    // ---- offline replay + canonical adoption -------------------------------

    @Test
    fun `a queued activity replays as one atomic payload`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42, 43, 44), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66, 67), "Sauvignon Blanc")

        // ONE outbox payload carries the whole activity, so a retry can never
        // land one block without the other.
        val payload = json.encodeToString(PruningActivityDraft.serializer(), d)
        val replayed = json.decodeFromString(PruningActivityDraft.serializer(), payload)
        assertEquals(d.id, replayed.id)
        assertEquals(2, PruningSyncRepository.allocationPayloads(replayed).size)
        // Deterministic allocation ids — a replay recreates the same rows.
        assertEquals(
            PruningSyncRepository.allocationPayloads(d).map { it.id },
            PruningSyncRepository.allocationPayloads(replayed).map { it.id },
        )
    }

    @Test
    fun `the complete canonical response is adopted wholesale`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")

        val result = json.decodeFromString(
            PruningSyncRepository.ActivityResult.serializer(),
            """
            {
              "activity_id": "$activityId",
              "created": true,
              "allocation_results": [
                {"allocation_id":"a1","paddock_id":"$cabFranc","requested":4,"attributed":4,
                 "pruning_season_id":"s26","season_year":2026,"vintage_year":2027,"conflicts":[]},
                {"allocation_id":"a2","paddock_id":"$sauvBlanc","requested":4,"attributed":4,
                 "pruning_season_id":"s26b","season_year":2026,"vintage_year":2027,"conflicts":[]}
              ],
              "conflicts": [],
              "canonical": {
                "activity": {
                  "id":"$activityId","vineyard_id":"$vineyard","entry_date":"2026-08-04",
                  "worker_or_crew":"Server Crew","method":"cane","labour_hours":8.0,
                  "hourly_rate":40.0,"notes":"server note","season_year":2026,
                  "vintage_year":2027,"is_reversed":false
                },
                "allocations": [
                  {"id":"a1","allocation_index":0,"paddock_id":"$cabFranc","block_name":"Cab Franc",
                   "pruning_season_id":"s26","season_year":2026,"vintage_year":2027,
                   "quarters":4,"row_equivalents":1.0,"estimated_vines":210,
                   "segments":[{"row":42,"segment":1},{"row":42,"segment":2},
                               {"row":42,"segment":3},{"row":42,"segment":4}]},
                  {"id":"a2","allocation_index":1,"paddock_id":"$sauvBlanc","block_name":"Sauv Blanc",
                   "pruning_season_id":"s26b","season_year":2026,"vintage_year":2027,
                   "quarters":4,"row_equivalents":1.0,"estimated_vines":180,
                   "segments":[{"row":66,"segment":1},{"row":66,"segment":2},
                               {"row":66,"segment":3},{"row":66,"segment":4}]}
                ],
                "totals": {
                  "allocation_count":2,"block_summary":"Cab Franc + Sauv Blanc","quarters":8,
                  "row_equivalents":2.0,"estimated_vines":390,"labour_hours":8.0,
                  "hourly_rate":40.0,"labour_cost":320.0
                }
              }
            }
            """.trimIndent(),
        )

        val adopted = PruningAllocationEditor.adoptCanonical(d, result.canonical!!)
        assertEquals("Server Crew", adopted.worker)
        assertEquals("cane", adopted.method)
        assertEquals(8.0, adopted.labourHours!!, 0.0001)
        assertEquals(40.0, adopted.hourlyRate!!, 0.0001)
        assertEquals(2026, adopted.serverSeasonYear)
        assertEquals(2027, adopted.vintageYear)
        assertTrue(adopted.serverAcknowledged)
        assertEquals(2, adopted.blockCount)
        assertEquals("s26", adopted.allocations.getValue(cabFranc).serverSeasonId)
        assertEquals(210, adopted.allocations.getValue(cabFranc).estimatedVines)
        assertEquals(180, adopted.allocations.getValue(sauvBlanc).estimatedVines)

        // Fully synced: nothing refused.
        val reconciliation = PruningActivityReconciliations.from(
            result = result,
            blockNames = mapOf(cabFranc to "Cab Franc", sauvBlanc to "Sauv Blanc"),
            blockSummary = adopted.blockSummary,
        )
        assertTrue(reconciliation.isFullySynced)
        assertFalse(reconciliation.hasConflicts)
        assertEquals(8, reconciliation.quartersRecorded)
        assertEquals("Activity saved", reconciliation.headline)
    }

    // ---- conflicts ---------------------------------------------------------

    @Test
    fun `quarter conflicts are reported instead of a clean success`() {
        val result = json.decodeFromString(
            PruningSyncRepository.ActivityResult.serializer(),
            """
            {
              "activity_id": "$activityId",
              "created": true,
              "allocation_results": [
                {"allocation_id":"a1","paddock_id":"$cabFranc","requested":8,"attributed":6,
                 "conflicts":[{"paddock_id":"$cabFranc","row":42,"segment":3,"reason":"already_completed"},
                              {"paddock_id":"$cabFranc","row":42,"segment":4,"reason":"already_completed"}]}
              ],
              "conflicts": [
                {"paddock_id":"$cabFranc","row":42,"segment":3,"reason":"already_completed"},
                {"paddock_id":"$cabFranc","row":42,"segment":4,"reason":"already_completed"}
              ],
              "canonical": {
                "activity": {"id":"$activityId","entry_date":"2026-08-04","season_year":2026,"vintage_year":2027},
                "allocations": [],
                "totals": {"allocation_count":1,"block_summary":"Cab Franc","quarters":6}
              }
            }
            """.trimIndent(),
        )

        val reconciliation = PruningActivityReconciliations.from(
            result = result,
            blockNames = mapOf(cabFranc to "Cab Franc"),
            blockSummary = "Cab Franc",
        )

        assertTrue(reconciliation.hasConflicts)
        assertFalse(reconciliation.isFullySynced)
        assertEquals(6, reconciliation.quartersRecorded)
        assertEquals(2, reconciliation.quartersConflicted)
        assertEquals(listOf(cabFranc), reconciliation.conflictBlockIds)
        assertEquals(2, reconciliation.conflicts(cabFranc).size)
        assertEquals("Activity saved with conflicts", reconciliation.headline)
        assertTrue(reconciliation.detail.contains("6 quarters recorded"))
        assertTrue(reconciliation.detail.contains("already recorded elsewhere"))
        assertEquals("Row 42 · q3", reconciliation.conflicts(cabFranc).first().label)
    }

    @Test
    fun `an unacknowledged write is never reported as saved`() {
        val result = json.decodeFromString(
            PruningSyncRepository.ActivityResult.serializer(),
            """{"activity_id":"$activityId","error":"activity_not_found"}""",
        )
        val reconciliation = PruningActivityReconciliations.from(result, blockSummary = "Cab Franc")
        assertFalse(reconciliation.isFullySynced)
        assertEquals("Activity not saved yet", reconciliation.headline)
    }

    // ---- reversal ----------------------------------------------------------

    @Test
    fun `reversing the activity reverses every allocation once`() {
        val result = json.decodeFromString(
            PruningSyncRepository.ActivityResult.serializer(),
            """
            {"activity_id":"$activityId","reversed":true,"allocations_reversed":2,
             "quarters_released":20,
             "canonical":{"activity":{"id":"$activityId","entry_date":"2026-08-04","is_reversed":true},
                          "allocations":[],
                          "totals":{"allocation_count":2,"block_summary":"Cab Franc + Sauv Blanc","quarters":0}}}
            """.trimIndent(),
        )
        val reconciliation = PruningActivityReconciliations.from(
            result = result,
            blockSummary = "Cab Franc + Sauv Blanc",
            isReversal = true,
        )
        assertEquals("Activity reversed", reconciliation.headline)
        assertTrue(reconciliation.detail.contains("20 quarters reopened"))
        assertTrue(reconciliation.detail.contains("Cab Franc + Sauv Blanc"))
    }

    // ---- legacy ------------------------------------------------------------

    @Test
    fun `a legacy single-block entry opens in the multi-block editor`() {
        val entry = PruningEntry(
            id = "66666666-6666-4666-8666-666666666666",
            vineyardId = vineyard,
            paddockId = cabFranc,
            seasonId = "77777777-7777-4777-8777-777777777777",
            date = "2026-07-29",
            segments = rows(38, 39),
            worker = "Historic crew",
            labourHours = 6.0,
            method = "cane",
            estimatedVines = 320,
            serverSeasonId = "77777777-7777-4777-8777-777777777777",
            serverSeasonYear = 2026,
        )

        var d = PruningActivityDraft.fromLegacyEntry(entry, "Cab Franc")
        assertEquals(1, d.blockCount)
        assertEquals(entry.id, d.id)
        assertEquals("Cab Franc", PruningActivityListing.blockLabel(d.activeAllocations.map { it.blockName }))

        // ...and another block can be added to it without touching the labour.
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(58), "Sauv Blanc")
        assertEquals(2, d.blockCount)
        assertEquals(6.0, d.labourHours!!, 0.0001)
        assertEquals(1, PruningAllocationEditor.toLegacyEntries(d).count { it.labourHours != null })
    }

    // ---- list display ------------------------------------------------------

    @Test
    fun `the activity list labels one two and many blocks`() {
        assertEquals("Cab Franc", PruningActivityListing.blockLabel(listOf("Cab Franc")))
        assertEquals(
            "Cab Franc + Sauv Blanc",
            PruningActivityListing.blockLabel(listOf("Cab Franc", "Sauv Blanc")),
        )
        assertEquals(
            "Cab Franc + Sauv Blanc +2 more",
            PruningActivityListing.blockLabel(listOf("Cab Franc", "Sauv Blanc", "Pinot", "Shiraz")),
        )
        assertEquals("No blocks", PruningActivityListing.blockLabel(emptyList()))
        // A blank block name never renders as an empty label.
        assertEquals("Block", PruningActivityListing.blockLabel(listOf(" ")))
    }

    @Test
    fun `search matches the activity when any allocation matches`() {
        val blocks = listOf("Cab Franc", "Sauv Blanc")
        assertTrue(PruningActivityListing.matches("sauv", blocks, "Jon", "", listOf("66", "67")))
        assertTrue(PruningActivityListing.matches("jon", blocks, "Jon", "", emptyList()))
        assertTrue(PruningActivityListing.matches("67", blocks, "Jon", "", listOf("66", "67")))
        assertFalse(PruningActivityListing.matches("shiraz", blocks, "Jon", "", emptyList()))
        assertTrue(PruningActivityListing.matches("  ", blocks, "Jon", "", emptyList()))
    }

    @Test
    fun `row ranges collapse contiguous runs`() {
        assertEquals("42–44", PruningActivityListing.rowRangeLabel(listOf(42, 43, 44)))
        assertEquals("38–39, 42–44", PruningActivityListing.rowRangeLabel(listOf(44, 38, 43, 42, 39)))
        assertEquals("66", PruningActivityListing.rowRangeLabel(listOf(66)))
        assertEquals("—", PruningActivityListing.rowRangeLabel(emptyList()))
    }
}
