package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.BlockPruningSelection
import com.rork.vinetrack.data.model.PruningActivityCanonical
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningAllocationEditor
import com.rork.vinetrack.data.model.PruningAllocationIds
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSegment
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The multi-block pruning activity contract (sql/166).
 *
 * These lock in the two rules the whole feature rests on:
 *  1. selections in one block are NEVER lost by working on another block,
 *  2. labour, timing and rate live once on the parent activity and are never
 *     apportioned or duplicated across allocations.
 */
class PruningActivityAllocationTest {

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val cabFranc = "22222222-2222-4222-8222-222222222222"
    private val sauvBlanc = "33333333-3333-4333-8333-333333333333"
    private val pinot = "44444444-4444-4444-8444-444444444444"

    private fun draft(date: String = "2026-08-04"): PruningActivityDraft =
        PruningActivityDraft(
            id = "55555555-5555-4555-8555-555555555555",
            vineyardId = vineyard,
            date = date,
            worker = "Jon",
            method = "spur",
            startTime = "08:00",
            finishTime = "15:30",
            labourHours = 7.5,
            hourlyRate = 35.0,
            notes = "Finished Cab Franc and moved into Sauvignon Blanc",
        )

    private fun rows(vararg numbers: Int): List<PruningSegment> =
        numbers.flatMap { row -> (1..4).map { PruningSegment(row = row, quarter = it) } }

    // ---- selection state ---------------------------------------------------

    @Test
    fun `selecting rows in two blocks keeps both selections`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42, 43, 44), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66, 67), "Sauvignon Blanc")

        assertEquals(2, d.blockCount)
        assertEquals(listOf(42, 43, 44), d.allocations.getValue(cabFranc).rows)
        assertEquals(listOf(66, 67), d.allocations.getValue(sauvBlanc).rows)
        assertEquals(20, d.totalQuarters)
        assertEquals(5.0, d.totalRowEquivalents, 0.0001)
    }

    @Test
    fun `switching blocks never clears earlier selections`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.focus(d, sauvBlanc, "Sauvignon Blanc")
        assertEquals(sauvBlanc, d.focusedPaddockId)
        assertEquals(4, d.allocations.getValue(cabFranc).quarters)

        d = PruningAllocationEditor.toggleSegment(d, sauvBlanc, PruningSegment(66, 1))
        d = PruningAllocationEditor.focus(d, cabFranc)
        d = PruningAllocationEditor.focus(d, pinot, "Pinot Noir")
        d = PruningAllocationEditor.focus(d, sauvBlanc)

        assertEquals(4, d.allocations.getValue(cabFranc).quarters)
        assertEquals(1, d.allocations.getValue(sauvBlanc).quarters)
        // A block that was opened but never touched contributes nothing.
        assertTrue(d.allocations.getValue(pinot).isEmpty)
        assertEquals(2, d.blockCount)
    }

    @Test
    fun `toggling a quarter only affects its own block`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")

        d = PruningAllocationEditor.toggleSegment(d, cabFranc, PruningSegment(42, 1))
        assertEquals(3, d.allocations.getValue(cabFranc).quarters)
        assertEquals(4, d.allocations.getValue(sauvBlanc).quarters)

        d = PruningAllocationEditor.toggleSegment(d, cabFranc, PruningSegment(42, 1))
        assertEquals(4, d.allocations.getValue(cabFranc).quarters)
    }

    @Test
    fun `removing one block leaves the activity and the other blocks intact`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        d = PruningAllocationEditor.removeBlock(d, cabFranc)

        assertEquals(1, d.blockCount)
        assertNull(d.allocations[cabFranc])
        assertEquals(4, d.allocations.getValue(sauvBlanc).quarters)
        // Activity-level values are untouched by an allocation change.
        assertEquals(7.5, d.labourHours!!, 0.0001)
        assertEquals(35.0, d.hourlyRate!!, 0.0001)
        assertEquals("08:00", d.startTime)
        assertEquals(sauvBlanc, d.focusedPaddockId)
    }

    @Test
    fun `empty blocks are pruned before save`() {
        var d = draft()
        d = PruningAllocationEditor.focus(d, cabFranc, "Cab Franc")
        d = PruningAllocationEditor.focus(d, sauvBlanc, "Sauvignon Blanc")
        assertFalse(d.canSave)

        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        assertTrue(d.canSave)

        val cleaned = PruningAllocationEditor.pruneEmptyBlocks(d)
        assertEquals(1, cleaned.allocations.size)
        assertEquals(sauvBlanc, cleaned.focusedPaddockId)
    }

    @Test
    fun `block summary reads as one activity across blocks`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        assertEquals("Cab Franc + Sauvignon Blanc", d.blockSummary)
    }

    // ---- labour lives once -------------------------------------------------

    @Test
    fun `labour and timing are recorded once for the whole activity`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42, 43, 44), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66, 67), "Sauvignon Blanc")
        d = PruningAllocationEditor.setSegments(d, pinot, listOf(PruningSegment(5, 1)), "Pinot Noir")

        assertEquals(7.5, d.durationHours!!, 0.0001)
        assertEquals(7.5 * 35.0, d.labourCost!!, 0.0001)

        val legacy = PruningAllocationEditor.toLegacyEntries(d)
        assertEquals(3, legacy.size)
        // Exactly ONE allocation mirrors labour, so any legacy sum counts it once.
        assertEquals(1, legacy.count { it.labourHours != null })
        assertEquals(7.5, legacy.sumOf { it.labourHours ?: 0.0 }, 0.0001)
        assertEquals(1, legacy.count { it.startTime != null })
        assertEquals(1, legacy.count { it.finishTime != null })
    }

    @Test
    fun `changing labour never moves a quarter`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        val before = d.allocations

        d = d.copy(labourHours = 9.25, hourlyRate = 38.0)
        assertEquals(before, d.allocations)
        assertEquals(8, d.totalQuarters)
        assertEquals(9.25 * 38.0, d.labourCost!!, 0.0001)
    }

    @Test
    fun `vine estimates stay per block`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        d = PruningAllocationEditor.setEstimatedVines(d, cabFranc, 400)
        d = PruningAllocationEditor.setEstimatedVines(d, sauvBlanc, 250)

        assertEquals(400, d.allocations.getValue(cabFranc).estimatedVines)
        assertEquals(250, d.allocations.getValue(sauvBlanc).estimatedVines)
        assertEquals(650, d.totalEstimatedVines)
    }

    // ---- season / vintage --------------------------------------------------

    @Test
    fun `season year is the year of the work for every allocation`() {
        assertEquals(2026, draft("2026-07-15").seasonYear)
        assertEquals(2026, draft("2026-08-04").seasonYear)
        assertEquals(2026, draft("2026-12-31").seasonYear)
        assertEquals(2027, draft("2027-01-01").seasonYear)
    }

    @Test
    fun `changing the activity date re-points every allocation season`() {
        var d = draft("2026-12-31")
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(70), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, pinot, rows(21), "Pinot Noir")
        assertEquals(2026, d.seasonYear)

        d = d.copy(date = "2027-01-04")
        val legacy = PruningAllocationEditor.toLegacyEntries(d)
        assertEquals(2, legacy.size)
        assertTrue(legacy.all { it.date == "2027-01-04" })
        // Each allocation resolves its OWN block season for the new year.
        assertEquals(2, legacy.map { it.seasonId }.distinct().size)
    }

    // ---- backwards compatibility ------------------------------------------

    @Test
    fun `an existing single-block entry opens as one allocation`() {
        val entry = PruningEntry(
            id = "66666666-6666-4666-8666-666666666666",
            vineyardId = vineyard,
            paddockId = cabFranc,
            seasonId = "77777777-7777-4777-8777-777777777777",
            date = "2026-07-29",
            segments = rows(38, 39),
            worker = "Historic crew",
            labourHours = 6.0,
            startTime = "07:30",
            finishTime = "13:30",
            method = "cane",
            notes = "legacy",
            estimatedVines = 320,
            workTaskId = "88888888-8888-4888-8888-888888888888",
            serverSeasonId = "77777777-7777-4777-8777-777777777777",
            serverSeasonYear = 2026,
        )

        val d = PruningActivityDraft.fromLegacyEntry(entry, blockName = "Cab Franc")
        assertEquals(entry.id, d.id)
        assertEquals(1, d.blockCount)
        assertEquals(8, d.totalQuarters)
        assertEquals("2026-07-29", d.date)
        assertEquals("cane", d.method)
        assertEquals(6.0, d.labourHours!!, 0.0001)
        assertEquals(entry.workTaskId, d.workTaskId)
        assertEquals(320, d.allocations.getValue(cabFranc).estimatedVines)
        assertTrue(d.serverAcknowledged)

        // ...and it round-trips back to the SAME entry id and values.
        val legacy = PruningAllocationEditor.toLegacyEntries(d)
        assertEquals(1, legacy.size)
        assertEquals(entry.id, legacy.first().id)
        assertEquals(entry.seasonId, legacy.first().seasonId)
        assertEquals(entry.labourHours, legacy.first().labourHours)
        assertEquals(entry.segments.size, legacy.first().segments.size)
    }

    @Test
    fun `editing an existing single-block entry can add another block`() {
        val entry = PruningEntry(
            id = "66666666-6666-4666-8666-666666666666",
            vineyardId = vineyard,
            paddockId = cabFranc,
            date = "2026-07-29",
            segments = rows(38),
            worker = "Jon",
            labourHours = 5.0,
        )
        var d = PruningActivityDraft.fromLegacyEntry(entry, "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(58), "Sauvignon Blanc")

        assertEquals(2, d.blockCount)
        // The original allocation keeps its ORIGINAL id (never re-keyed).
        assertEquals(entry.id, d.allocations.getValue(cabFranc).allocationIdFor(d.id))
        // The new one uses the deterministic (activity, block) id.
        assertEquals(
            PruningAllocationIds.make(d.id, sauvBlanc),
            d.allocations.getValue(sauvBlanc).allocationIdFor(d.id),
        )
        val legacy = PruningAllocationEditor.toLegacyEntries(d)
        assertEquals(1, legacy.count { it.labourHours != null })
        assertEquals(5.0, legacy.sumOf { it.labourHours ?: 0.0 }, 0.0001)
    }

    @Test
    fun `allocation ids are deterministic so an offline retry cannot duplicate a block`() {
        val a = PruningAllocationIds.make("55555555-5555-4555-8555-555555555555", cabFranc)
        val b = PruningAllocationIds.make("55555555-5555-4555-8555-555555555555", cabFranc)
        assertEquals(a, b)
        assertTrue(a != PruningAllocationIds.make("55555555-5555-4555-8555-555555555555", sauvBlanc))
        // MD5 v3 shape, matching derive_pruning_allocation_id in SQL.
        assertEquals('3', a[14])
        assertTrue(a[19] in "89ab")
    }

    // ---- offline persistence ----------------------------------------------

    @Test
    fun `an offline draft round-trips every block allocation`() {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42, 43), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        d = PruningAllocationEditor.setEstimatedVines(d, cabFranc, 600)

        val restored = json.decodeFromString(
            PruningActivityDraft.serializer(),
            json.encodeToString(PruningActivityDraft.serializer(), d),
        )
        assertEquals(d, restored)
        assertEquals(2, restored.blockCount)
        assertEquals(600, restored.allocations.getValue(cabFranc).estimatedVines)
        assertEquals(7.5, restored.labourHours!!, 0.0001)
    }

    // ---- adopting the canonical server state ------------------------------

    @Test
    fun `the canonical server response replaces the local activity and allocations`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")

        val canonical = PruningActivityCanonical(
            activity = PruningActivityCanonical.CanonicalActivity(
                id = d.id,
                vineyardId = vineyard,
                entryDate = "2026-08-04",
                workerOrCrew = "Jon",
                method = "spur",
                labourHours = 7.5,
                hourlyRate = 35.0,
                notes = "server note",
                seasonYear = 2026,
                vintageYear = 2027,
                isReversed = false,
            ),
            allocations = listOf(
                PruningActivityCanonical.CanonicalAllocation(
                    id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                    allocationIndex = 0,
                    paddockId = cabFranc,
                    blockName = "Cab Franc",
                    pruningSeasonId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                    seasonYear = 2026,
                    quarters = 2,
                    segments = listOf(
                        PruningActivityCanonical.CanonicalSegment(row = 42, segment = 1),
                        PruningActivityCanonical.CanonicalSegment(row = 42, segment = 2),
                    ),
                    estimatedVines = 210,
                ),
            ),
        )

        val adopted = PruningAllocationEditor.adoptCanonical(d, canonical)
        // The server dropped the Sauvignon Blanc allocation — the client follows.
        assertEquals(1, adopted.blockCount)
        assertNull(adopted.allocations[sauvBlanc])
        assertEquals(2, adopted.totalQuarters)
        assertEquals(2026, adopted.serverSeasonYear)
        assertEquals(2027, adopted.vintageYear)
        assertEquals(210, adopted.allocations.getValue(cabFranc).estimatedVines)
        assertEquals(
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            adopted.allocations.getValue(cabFranc).serverSeasonId,
        )
        assertTrue(adopted.serverAcknowledged)
        // Labour still exists exactly once.
        assertEquals(7.5, adopted.labourHours!!, 0.0001)
        assertEquals(1, PruningAllocationEditor.toLegacyEntries(adopted).count { it.labourHours != null })
    }

    @Test
    fun `an unacknowledged activity is never counted as synced`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        val legacy = PruningAllocationEditor.toLegacyEntries(d)
        val status = PruningSyncIntegrity.evaluate(
            entries = legacy,
            queuedEntryIds = emptySet(),
            queuedWrites = 0,
        )
        assertFalse(status.isFullySynced)
        assertEquals(1, status.awaitingAck)
        assertTrue(status.percentSynced < 100)
    }

    @Test
    fun `a queued activity holds every one of its allocations back from synced`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        val legacy = PruningAllocationEditor.toLegacyEntries(d)
        val status = PruningSyncIntegrity.evaluate(
            entries = legacy,
            queuedEntryIds = legacy.map { it.id }.toSet(),
            queuedWrites = 1,
        )
        assertEquals(2, status.queued)
        assertEquals(0, status.confirmed)
        assertFalse(status.isFullySynced)
    }

    // ---- payload shape -----------------------------------------------------

    @Test
    fun `the upload payload carries labour once and every allocation`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42, 43), "Cab Franc")
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, rows(66), "Sauvignon Blanc")
        d = PruningAllocationEditor.focus(d, pinot, "Pinot Noir") // opened, never selected

        val activity = PruningSyncRepository.activityPayload(d)
        assertEquals("2026-08-04", activity.entryDate)
        assertEquals(7.5, activity.labourHours!!, 0.0001)
        assertEquals(35.0, activity.hourlyRate!!, 0.0001)

        val allocations = PruningSyncRepository.allocationPayloads(d)
        assertEquals(2, allocations.size)
        assertEquals(setOf(cabFranc, sauvBlanc), allocations.map { it.paddockId }.toSet())
        assertEquals(8, allocations.first { it.paddockId == cabFranc }.quarters)
        assertEquals(4, allocations.first { it.paddockId == sauvBlanc }.quarters)
        assertEquals(12, allocations.sumOf { it.segments.size })
        // Every segment belongs to an allocation that carries its own block.
        assertTrue(allocations.all { alloc -> alloc.segments.isNotEmpty() && alloc.paddockId.isNotBlank() })
    }

    @Test
    fun `a block with no selection never reaches the payload`() {
        var d = draft()
        d = PruningAllocationEditor.focus(d, cabFranc, "Cab Franc")
        assertTrue(PruningSyncRepository.allocationPayloads(d).isEmpty())
        assertFalse(d.canSave)
    }

    @Test
    fun `duplicate quarters are collapsed before upload`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(
            d,
            cabFranc,
            listOf(
                PruningSegment(42, 1),
                PruningSegment(42, 1),
                PruningSegment(42, 2),
            ),
            "Cab Franc",
        )
        assertEquals(2, d.allocations.getValue(cabFranc).quarters)
        assertEquals(2, PruningSyncRepository.allocationPayloads(d).first().segments.size)
    }

    @Test
    fun `a selection built by copying one block into another keeps them independent`() {
        var d = draft()
        d = PruningAllocationEditor.setSegments(d, cabFranc, rows(42), "Cab Franc")
        val copied = d.allocations.getValue(cabFranc).segments
        d = PruningAllocationEditor.setSegments(d, sauvBlanc, copied, "Sauvignon Blanc")
        d = PruningAllocationEditor.toggleSegment(d, sauvBlanc, PruningSegment(42, 1))

        assertEquals(4, d.allocations.getValue(cabFranc).quarters)
        assertEquals(3, d.allocations.getValue(sauvBlanc).quarters)
    }

    @Test
    fun `an allocation exposes rows quarters row equivalents and vines`() {
        val selection = BlockPruningSelection(
            paddockId = cabFranc,
            blockName = "Cab Franc",
            segments = rows(42, 43) + listOf(PruningSegment(44, 1)),
            estimatedVines = 700,
        )
        assertEquals(listOf(42, 43, 44), selection.rows)
        assertEquals(9, selection.quarters)
        assertEquals(2.25, selection.rowEquivalents, 0.0001)
        assertEquals(700, selection.estimatedVines)
    }
}
