package com.rork.vinetrack.data

import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The available-vintage list is derived from EVERY non-deleted record on the
 * surface, computed BEFORE the selected vintage is applied.
 *
 * This is the rule that makes the selector usable: if the options were derived
 * from the already-filtered rows, selecting 2027 would leave 2027 as the only
 * option and the operator could never get back to 2026. These fixtures pin that
 * behaviour down on both platforms (iOS mirror:
 * `SeasonScopeOptionsTests.swift`).
 *
 * Season start here is 1 July, so vintage 2027 runs 1 Jul 2026 – 30 Jun 2027.
 */
class SeasonScopeOptionsTest {

    private val zone: ZoneId = ZoneId.of("Australia/Adelaide")
    private val startMonth = 7
    private val startDay = 1

    private fun ms(date: String): Long =
        LocalDate.parse(date).atStartOfDay(zone).toInstant().toEpochMilli()

    /** Records spanning three seasons plus one undated row. */
    private val allRecords: List<Long?> = listOf(
        ms("2024-11-04"), // vintage 2025
        ms("2026-02-18"), // vintage 2026
        ms("2026-06-30"), // vintage 2026 — final day of the season
        ms("2026-07-01"), // vintage 2027 — first day of the season
        ms("2027-01-09"), // vintage 2027
        null, // undated: contributes no option, reachable only via All
    )

    private fun scope(selection: SeasonSelection, dates: List<Long?> = allRecords): SeasonScope =
        SeasonScope.resolve(dates, selection, startMonth, startDay, zone)

    @Test
    fun `2026 stays selectable while viewing 2027`() {
        // The operator is looking at the 2027 season...
        val viewing2027 = scope(SeasonSelection.Vintage(2027))
        assertEquals(2027, viewing2027.vintage)

        // ...and 2026 is still offered, because the option list is built from
        // all of the surface's records rather than the visible subset.
        assertTrue("2026 must remain selectable while 2027 is applied", 2026 in viewing2027.available)
        assertEquals(listOf(2027, 2026, 2025), viewing2027.available)

        // And it can actually be selected: switching to it resolves to 2026.
        val switched = scope(SeasonSelection.Vintage(2026))
        assertEquals(2026, switched.vintage)
        assertTrue("2027 must remain selectable in turn", 2027 in switched.available)
        assertEquals(viewing2027.available, switched.available)
    }

    @Test
    fun `option list is identical whichever vintage is applied`() {
        val options = listOf(
            SeasonSelection.All,
            SeasonSelection.Automatic,
            SeasonSelection.Vintage(2025),
            SeasonSelection.Vintage(2026),
            SeasonSelection.Vintage(2027),
        ).map { scope(it).available }

        options.forEach { assertEquals(listOf(2027, 2026, 2025), it) }
    }

    @Test
    fun `options come from all records, not the filtered rows`() {
        // Simulating the bug: deriving options from the rows left after the
        // 2027 filter would offer only 2027.
        val filteredTo2027 = allRecords.filter { scope(SeasonSelection.Vintage(2027)).contains(it) }
        val wrong = SeasonScope.resolve(filteredTo2027, SeasonSelection.Vintage(2027), startMonth, startDay, zone)
        assertEquals(listOf(2027), wrong.available)

        // The real call passes the unfiltered list and keeps every season.
        assertEquals(listOf(2027, 2026, 2025), scope(SeasonSelection.Vintage(2027)).available)
    }

    @Test
    fun `season boundaries are half-open on the vineyard's own day`() {
        val season2027 = scope(SeasonSelection.Vintage(2027))
        assertTrue(season2027.contains(ms("2026-07-01")))
        assertTrue(season2027.contains(ms("2027-06-30")))
        assertFalse("30 Jun 2026 belongs to vintage 2026", season2027.contains(ms("2026-06-30")))
        assertFalse("1 Jul 2027 opens vintage 2028", season2027.contains(ms("2027-07-01")))
    }

    @Test
    fun `all vintages applies no date restriction and reaches undated records`() {
        val all = scope(SeasonSelection.All)
        assertEquals(null, all.vintage)
        assertTrue(all.isAll)
        assertEquals(SeasonScope.ALL_TITLE, all.title)
        allRecords.forEach { assertTrue("All vintages must pass every record", all.contains(it)) }
    }

    @Test
    fun `a scoped view hides undated records`() {
        assertFalse(scope(SeasonSelection.Vintage(2027)).contains(null))
    }

    @Test
    fun `a vintage with no records falls back to all rather than stranding the screen`() {
        val gone = scope(SeasonSelection.Vintage(2019))
        assertEquals(null, gone.vintage)
        assertTrue(gone.isAll)
        // The real seasons are still offered so the operator can pick one.
        assertEquals(listOf(2027, 2026, 2025), gone.available)
    }

    @Test
    fun `automatic rests on the current season only when it holds records`() {
        val onlyOldRecords = listOf<Long?>(ms("2024-11-04"))
        val auto = SeasonScope.resolve(onlyOldRecords, SeasonSelection.Automatic, startMonth, startDay, zone)
        if (auto.currentVintage != 2025) {
            // Today's season holds nothing, so the screen opens on All.
            assertEquals(null, auto.vintage)
            assertTrue(auto.isAll)
        }
        assertEquals(listOf(2025), auto.available)
    }

    @Test
    fun `undated records never create a phantom option`() {
        val scope = SeasonScope.resolve(
            listOf(null, null),
            SeasonSelection.Automatic,
            startMonth,
            startDay,
            zone,
        )
        assertTrue(scope.available.isEmpty())
        assertTrue(scope.isAll)
    }
}
