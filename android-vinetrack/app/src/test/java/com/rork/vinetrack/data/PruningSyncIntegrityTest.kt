package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSeasonIds
import com.rork.vinetrack.data.model.PruningSeasonSelection
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * ANDROID WRITE-PATH SEASON RULES + the sync-integrity contract.
 *
 * Canonical rule (sql/161, enforced server-side and mirrored here):
 *  * pruning season year = calendar year of the ACTIVITY DATE — never the
 *    device clock at sync time, never the selected setup season, never the
 *    first or highest season row the database returns, never the vintage,
 *  * vintage year = the season-start resolver (sql/119),
 *  * so 29 July 2026 work is Season 2026 · Vintage 2027.
 *
 * "100% synced" additionally requires the SERVER to have acknowledged the
 * record and this device to have adopted the season the server resolved.
 */
class PruningSyncIntegrityTest {

    private val vineyardId = "11111111-1111-4111-8111-111111111111"
    private val blockId = "22222222-2222-4222-8222-222222222222"
    private val json = Json { ignoreUnknownKeys = true }

    private fun setup(year: Int) = PruningBlockSetup(
        id = PruningSeasonIds.make(vineyardId, blockId, year),
        vineyardId = vineyardId,
        paddockId = blockId,
        seasonYear = year,
    )

    private fun entry(
        id: String,
        date: String,
        seasonId: String,
        serverSeasonId: String? = null,
        serverSeasonYear: Int? = null,
        reversedAtMs: Long = 0L,
    ) = PruningEntry(
        id = id,
        vineyardId = vineyardId,
        paddockId = blockId,
        seasonId = seasonId,
        date = date,
        serverSeasonId = serverSeasonId,
        serverSeasonYear = serverSeasonYear,
        reversedAtMs = reversedAtMs,
    )

    // MARK: The rule — season from the activity date, vintage separately

    @Test
    fun `july 2026 work is season 2026 vintage 2027`() {
        assertEquals(2026, PruningSeasonIds.seasonYearFor("2026-07-29"))
        assertEquals(2027, VintageResolver.vintageYear(LocalDate.of(2026, 7, 29), 7, 1))
    }

    @Test
    fun `august 2026 work is season 2026 vintage 2027`() {
        assertEquals(2026, PruningSeasonIds.seasonYearFor("2026-08-02"))
        assertEquals(2027, VintageResolver.vintageYear(LocalDate.of(2026, 8, 2), 7, 1))
    }

    @Test
    fun `january 2027 work is season 2027`() {
        assertEquals(2027, PruningSeasonIds.seasonYearFor("2027-01-04"))
        assertEquals(2026, PruningSeasonIds.seasonYearFor("2026-12-31"))
    }

    // MARK: Resolution before upload

    @Test
    fun `a new entry resolves the cached season row for its own year`() {
        val setups = listOf(setup(2027), setup(2026)) // stray future row FIRST
        assertEquals(
            setup(2026).id,
            PruningSeasonSelection.canonicalSeasonId(setups, vineyardId, blockId, "2026-08-02"),
        )
    }

    @Test
    fun `an offline entry for an unconfigured year uses the deterministic server id`() {
        // The device only knows a 2027 row — the 2026 work must NOT borrow it.
        val setups = listOf(setup(2027))
        val resolved = PruningSeasonSelection.canonicalSeasonId(setups, vineyardId, blockId, "2026-08-02")
        assertEquals(PruningSeasonIds.make(vineyardId, blockId, 2026), resolved)
        assertNotEquals(setup(2027).id, resolved)
    }

    @Test
    fun `replaying an older build payload re-points to the activity date`() {
        // Payload written by a build that stored the vintage-keyed 2027 row.
        val queued = entry("e1", "2026-08-02", seasonId = setup(2027).id)
        val resolved = PruningSeasonSelection.canonicalSeasonId(
            listOf(setup(2027)), vineyardId, blockId, queued.date,
        )
        assertNotEquals(queued.seasonId, resolved)
        assertEquals(PruningSeasonIds.make(vineyardId, blockId, 2026), resolved)
    }

    @Test
    fun `editing 31 december 2026 to 1 january 2027 changes the linked season`() {
        val setups = listOf(setup(2026), setup(2027))
        val before = PruningSeasonSelection.canonicalSeasonId(setups, vineyardId, blockId, "2026-12-31")
        val after = PruningSeasonSelection.canonicalSeasonId(setups, vineyardId, blockId, "2027-01-01")
        assertEquals(setup(2026).id, before)
        assertEquals(setup(2027).id, after)
        assertNotEquals(before, after)
    }

    @Test
    fun `an entry date that stays inside the year keeps its season`() {
        val setups = listOf(setup(2026))
        assertEquals(
            PruningSeasonSelection.canonicalSeasonId(setups, vineyardId, blockId, "2026-07-29"),
            PruningSeasonSelection.canonicalSeasonId(setups, vineyardId, blockId, "2026-12-31"),
        )
    }

    // MARK: The server's answer wins

    @Test
    fun `the server canonical season overrides a stale local season`() {
        val stale = entry("e1", "2026-08-02", seasonId = setup(2027).id)
        assertFalse(PruningSyncIntegrity.isServerConfirmed(stale))

        val canonical = setup(2026).id
        val adopted = stale.copy(seasonId = canonical, serverSeasonId = canonical, serverSeasonYear = 2026)
        assertTrue(PruningSyncIntegrity.isServerConfirmed(adopted))
        assertEquals(canonical, adopted.seasonId)
        // Nothing else about the record moves.
        assertEquals(stale.date, adopted.date)
        assertEquals(stale.id, adopted.id)
    }

    @Test
    fun `an acknowledgement for the wrong season year is never counted as confirmed`() {
        // The historical defect: the server confirms the row, but that row is
        // season 2027 for 2026 work. Only a reviewed correction may fix it.
        val mismatched = entry(
            "e1", "2026-08-02",
            seasonId = setup(2027).id,
            serverSeasonId = setup(2027).id,
            serverSeasonYear = 2027,
        )
        assertFalse(PruningSyncIntegrity.isServerConfirmed(mismatched))
    }

    // MARK: What "100% synced" means

    @Test
    fun `an empty queue alone is not 100 percent synced`() {
        val entries = listOf(
            entry("e1", "2026-08-02", setup(2026).id, setup(2026).id, 2026),
            entry("e2", "2026-08-03", setup(2026).id), // never acknowledged
        )
        val status = PruningSyncIntegrity.evaluate(entries, emptySet(), queuedWrites = 0)
        assertFalse(status.isFullySynced)
        assertEquals(1, status.awaitingAck)
        assertEquals(1, status.confirmed)
        assertEquals(50, status.percentSynced)
    }

    @Test
    fun `all records confirmed on the canonical season is 100 percent`() {
        val entries = listOf(
            entry("e1", "2026-08-02", setup(2026).id, setup(2026).id, 2026),
            entry("e2", "2026-12-31", setup(2026).id, setup(2026).id, 2026),
            entry("e3", "2027-01-04", setup(2027).id, setup(2027).id, 2027),
        )
        val status = PruningSyncIntegrity.evaluate(entries, emptySet(), queuedWrites = 0)
        assertTrue(status.isFullySynced)
        assertEquals(100, status.percentSynced)
        assertEquals(3, status.confirmed)
    }

    @Test
    fun `a queued write keeps the tracker below 100 even when every record is confirmed`() {
        val entries = listOf(entry("e1", "2026-08-02", setup(2026).id, setup(2026).id, 2026))
        val status = PruningSyncIntegrity.evaluate(entries, emptySet(), queuedWrites = 1)
        assertFalse(status.isFullySynced)
        assertEquals(99, status.percentSynced)
    }

    @Test
    fun `offline creation then sync moves a record from queued to confirmed`() {
        val offline = entry("e1", "2026-08-02", setup(2026).id)
        val queued = PruningSyncIntegrity.evaluate(listOf(offline), setOf("e1"), queuedWrites = 1)
        assertEquals(1, queued.queued)
        assertEquals(0, queued.confirmed)
        assertFalse(queued.isFullySynced)

        val synced = offline.copy(serverSeasonId = setup(2026).id, serverSeasonYear = 2026)
        val after = PruningSyncIntegrity.evaluate(listOf(synced), emptySet(), queuedWrites = 0)
        assertTrue(after.isFullySynced)
        assertEquals(1, after.confirmed)
    }

    @Test
    fun `a wrongly filed record is surfaced even with an empty queue`() {
        val entries = listOf(
            entry("e1", "2026-08-02", setup(2027).id, setup(2027).id, 2027),
            entry("e2", "2026-08-02", setup(2026).id, setup(2026).id, 2026),
        )
        val status = PruningSyncIntegrity.evaluate(entries, emptySet(), queuedWrites = 0)
        assertEquals(1, status.seasonMismatched)
        assertFalse(status.isFullySynced)
        assertTrue(status.needsAttention)
    }

    @Test
    fun `reversed entries are audit history and never counted`() {
        val entries = listOf(
            entry("e1", "2026-08-02", setup(2026).id, setup(2026).id, 2026),
            entry("e2", "2026-07-20", setup(2027).id, reversedAtMs = 1L),
        )
        val status = PruningSyncIntegrity.evaluate(entries, emptySet(), queuedWrites = 0)
        assertEquals(1, status.recordCount)
        assertTrue(status.isFullySynced)
    }

    @Test
    fun `a vineyard with no pruning records is fully synced`() {
        val status = PruningSyncIntegrity.evaluate(emptyList(), emptySet(), queuedWrites = 0)
        assertTrue(status.isFullySynced)
        assertEquals(100, status.percentSynced)
    }

    @Test
    fun `an app restart keeps the acknowledgement because it is cached on the entry`() {
        val confirmed = entry("e1", "2026-08-02", setup(2026).id, setup(2026).id, 2026)
        val roundTripped = json.decodeFromString(
            PruningEntry.serializer(),
            json.encodeToString(PruningEntry.serializer(), confirmed),
        )
        assertEquals(setup(2026).id, roundTripped.serverSeasonId)
        assertEquals(2026, roundTripped.serverSeasonYear)
        assertTrue(PruningSyncIntegrity.isServerConfirmed(roundTripped))
    }

    @Test
    fun `an entry cached by an older build decodes as awaiting confirmation`() {
        val legacy = """
            {"id":"e1","vineyardId":"$vineyardId","paddockId":"$blockId",
             "seasonId":"${setup(2027).id}","date":"2026-08-02"}
        """.trimIndent()
        val decoded = json.decodeFromString(PruningEntry.serializer(), legacy)
        assertEquals(null, decoded.serverSeasonId)
        assertFalse(PruningSyncIntegrity.isServerConfirmed(decoded))
    }

    // MARK: RPC responses

    @Test
    fun `the update response carries the canonical season for a year crossing edit`() {
        val body = """
            {
              "entry_id": "e1",
              "season_id": "${setup(2027).id}",
              "season_year": 2027,
              "season_changed": true,
              "vintage_year": 2027,
              "requested": 1,
              "attributed": 1,
              "removed": 0,
              "added": 0,
              "conflicts": [],
              "stale": false
            }
        """.trimIndent()
        val result = json.decodeFromString(PruningSyncRepository.UpdateEntryResult.serializer(), body)
        assertEquals(2027, result.seasonYear)
        assertEquals(true, result.seasonChanged)
        assertEquals(setup(2027).id, result.seasonId)
    }

    @Test
    fun `a pulled row is its own acknowledgement`() {
        val row = PruningSyncRepository.EntryRow(
            id = "e1",
            vineyardId = vineyardId,
            pruningSeasonId = setup(2026).id,
            paddockId = blockId,
            entryDate = "2026-08-02",
        )
        val model = row.toModel(segments = emptyList(), serverSeasonYear = 2026)
        assertEquals(setup(2026).id, model.serverSeasonId)
        assertEquals(2026, model.serverSeasonYear)
        assertTrue(PruningSyncIntegrity.isServerConfirmed(model))
    }
}
