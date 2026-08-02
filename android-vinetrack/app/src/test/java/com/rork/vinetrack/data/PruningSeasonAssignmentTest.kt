package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSeasonIds
import com.rork.vinetrack.data.model.PruningSeasonSelection
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * SHARED SEASON-ASSIGNMENT FIXTURE — the same cases exist as
 * `PruningSeasonAssignmentTests.swift` in the iOS test target, and as T3–T12
 * of `sql/tests/161_pruning_season_canonical_tests.sql`.
 *
 * Canonical rule under test (sql/161):
 *  * pruning season year = calendar year of the ENTRY DATE (the year the
 *    winter pruning happened) — never the vintage, never the device clock,
 *  * vintage year        = the season-start resolver (sql/119), unchanged,
 *  * so 2 Aug 2026 → "2026 Winter Pruning · Vintage 2027".
 */
class PruningSeasonAssignmentTest {

    private val vineyardId = "11111111-1111-4111-8111-111111111111"
    private val blockId = "22222222-2222-4222-8222-222222222222"
    private val otherBlockId = "33333333-3333-4333-8333-333333333333"

    private val json = Json { ignoreUnknownKeys = true }

    // MARK: The rule itself

    @Test
    fun `august 2026 work is season 2026 with vintage 2027`() {
        assertEquals(2026, PruningSeasonIds.seasonYearFor("2026-08-02"))
        assertEquals(2026, PruningSeasonIds.seasonYearFor(LocalDate.of(2026, 8, 2)))
        // The costing vintage for a 1 July season start is the NEXT year — the
        // two values must never be conflated.
        assertEquals(2027, VintageResolver.vintageYear(LocalDate.of(2026, 8, 2), 7, 1))
    }

    @Test
    fun `december 2026 work is still season 2026`() {
        assertEquals(2026, PruningSeasonIds.seasonYearFor("2026-12-31"))
        assertEquals(2027, PruningSeasonIds.seasonYearFor("2027-01-01"))
    }

    @Test
    fun `season id is derived from the entry date`() {
        assertEquals(
            PruningSeasonIds.make(vineyardId, blockId, 2026),
            PruningSeasonIds.makeForDate(vineyardId, blockId, "2026-08-02"),
        )
        assertNotEquals(
            PruningSeasonIds.makeForDate(vineyardId, blockId, "2026-12-31"),
            PruningSeasonIds.makeForDate(vineyardId, blockId, "2027-01-04"),
        )
    }

    @Test
    fun `a backdated entry keeps the season of the work not of the device clock`() {
        // Recorded in 2027 for work done on 31 Dec 2026.
        assertEquals(2026, PruningSeasonIds.seasonYearFor("2026-12-31"))
        assertEquals(
            PruningSeasonIds.make(vineyardId, blockId, 2026),
            PruningSeasonIds.makeForDate(vineyardId, blockId, "2026-12-31"),
        )
    }

    @Test
    fun `an invalid date falls back to today rather than throwing`() {
        assertEquals(LocalDate.now().year, PruningSeasonIds.seasonYearFor("not-a-date"))
    }

    @Test
    fun `the deterministic id matches the iOS name string`() {
        // Byte-for-byte parity vector shared with iOS `PruningSeasonId.make`
        // and the sql/161 `derive_pruning_season_id` validation block.
        val id = PruningSeasonIds.make(vineyardId, blockId, 2026)
        assertEquals('3', id[14])                       // UUID version 3
        assertTrue(id[19] in "89ab")                    // IETF variant
        assertEquals(id, PruningSeasonIds.make(vineyardId.uppercase(), blockId.uppercase(), 2026))
    }

    // MARK: Season selection

    @Test
    fun `a stray next-year season never hijacks the current season`() {
        val current = setup(PruningSeasonIds.currentSeasonYear())
        val future = setup(PruningSeasonIds.currentSeasonYear() + 1)
        // Future row FIRST — the old `firstOrNull` rule picked whatever came first.
        val setups = listOf(future, current)
        assertEquals(current.id, PruningSeasonSelection.setupFor(setups, blockId)?.id)
    }

    @Test
    fun `selection falls back to the most recent past season`() {
        val past = setup(PruningSeasonIds.currentSeasonYear() - 1)
        val older = setup(PruningSeasonIds.currentSeasonYear() - 3)
        val setups = listOf(older, past)
        assertEquals(past.id, PruningSeasonSelection.setupFor(setups, blockId)?.id)
    }

    @Test
    fun `recording looks up the season of the entry date only`() {
        val s2026 = setup(2026)
        val s2027 = setup(2027)
        val setups = listOf(s2026, s2027)
        assertEquals(s2026.id, PruningSeasonSelection.setupOnDate(setups, blockId, "2026-08-02")?.id)
        assertEquals(s2027.id, PruningSeasonSelection.setupOnDate(setups, blockId, "2027-01-04")?.id)
        assertNull(PruningSeasonSelection.setupOnDate(setups, blockId, "2025-08-02"))
    }

    @Test
    fun `two blocks recorded on the same day resolve to the same season year`() {
        val a = PruningSeasonIds.makeForDate(vineyardId, blockId, "2026-08-02")
        val b = PruningSeasonIds.makeForDate(vineyardId, otherBlockId, "2026-08-02")
        assertNotEquals(a, b) // different blocks…
        assertEquals(
            PruningSeasonIds.seasonYearFor("2026-08-02"),
            PruningSeasonIds.seasonYearFor("2026-08-02"),
        ) // …same season year
    }

    @Test
    fun `iOS and Android agree on the same season id for the same work`() {
        // iOS: PruningSeasonId.make(vineyard, paddock, seasonYear(for: date))
        // Android: PruningSeasonIds.makeForDate(vineyard, paddock, isoDate)
        assertEquals(
            PruningSeasonIds.make(vineyardId, blockId, 2026),
            PruningSeasonIds.makeForDate(vineyardId, blockId, "2026-08-02"),
        )
    }

    // MARK: Adopting the server's canonical season

    @Test
    fun `adopting the server season replaces the local guess`() {
        val wrong = PruningSeasonIds.make(vineyardId, blockId, 2027)
        val canonical = PruningSeasonIds.make(vineyardId, blockId, 2026)
        val entry = PruningEntry(
            id = "44444444-4444-4444-8444-444444444444",
            vineyardId = vineyardId,
            paddockId = blockId,
            seasonId = wrong,
            date = "2026-08-02",
        )
        val adopted = entry.copy(seasonId = canonical)
        assertEquals(canonical, adopted.seasonId)
        assertEquals(entry.date, adopted.date)
        assertEquals(entry.id, adopted.id)
    }

    @Test
    fun `record entry result decodes the canonical season fields`() {
        val body = """
            {
              "entry_id": "44444444-4444-4444-8444-444444444444",
              "season_id": "55555555-5555-4555-8555-555555555555",
              "season_year": 2026,
              "season_year_requested": 2027,
              "season_corrected": true,
              "season_mismatch": false,
              "vintage_year": 2027,
              "requested": 2,
              "attributed": 2,
              "deleted": false,
              "an_unexpected_future_field": "ignored"
            }
        """.trimIndent()
        val result = json.decodeFromString(PruningSyncRepository.RecordEntryResult.serializer(), body)
        assertEquals(2026, result.seasonYear)
        assertEquals(2027, result.seasonYearRequested)
        assertEquals(true, result.seasonCorrected)
        assertEquals(2027, result.vintageYear)
        assertEquals("55555555-5555-4555-8555-555555555555", result.seasonId)
    }

    @Test
    fun `a minimal response from an older server still decodes`() {
        val body = """{"entry_id":"44444444-4444-4444-8444-444444444444","requested":1,"attributed":1}"""
        val result = json.decodeFromString(PruningSyncRepository.RecordEntryResult.serializer(), body)
        assertNull(result.seasonId)
        assertNull(result.seasonYear)
        assertEquals(1, result.attributed)
    }

    // MARK: Display label

    @Test
    fun `the dashboard label pairs the season year with the vintage`() {
        val day = LocalDate.of(2026, 8, 2)
        val label = "${PruningSeasonIds.seasonYearFor(day)} Winter Pruning · " +
            "Vintage ${VintageResolver.vintageYear(day, 7, 1)}"
        assertEquals("2026 Winter Pruning · Vintage 2027", label)
    }

    private fun setup(year: Int) = PruningBlockSetup(
        id = PruningSeasonIds.make(vineyardId, blockId, year),
        vineyardId = vineyardId,
        paddockId = blockId,
        seasonYear = year,
    )
}
