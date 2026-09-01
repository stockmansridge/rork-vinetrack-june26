package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningCalculator
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.PruningSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.TimeZone

/**
 * The completion date shown under a finished pruning row's tick:
 * [PruningCalculator.segmentCompletionDates] must attribute each quarter to
 * the LATEST entry that touched it, and [RegionFormatter.formatDateShort]
 * must render it in the vineyard's regional order with a two-digit year.
 */
class PruningRowCompletionDateTest {

    private val au = RegionCountry.Australia.recommendedPreset
    private val us = RegionCountry.UnitedStates.recommendedPreset

    @Before
    fun fixTimeZone() {
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
    }

    private fun row(number: Int, id: String? = null) = PruningRowRef(
        rowId = id,
        number = number,
        label = number.toString(),
        lengthMetres = null,
        vines = 100.0,
        isFallback = id == null,
    )

    private fun entry(date: String, segments: List<PruningSegment>) = PruningEntry(
        id = "e-$date-${segments.size}",
        vineyardId = "v1",
        paddockId = "p1",
        date = date,
        segments = segments,
    )

    // ------------------------------------------- segment completion dates

    @Test
    fun `each quarter carries the latest entry date that touched it`() {
        val rows = listOf(row(1))
        val entries = listOf(
            entry("2026-08-30", listOf(PruningSegment(1, 1), PruningSegment(1, 2))),
            entry("2026-09-01", listOf(PruningSegment(1, 2), PruningSegment(1, 3), PruningSegment(1, 4))),
        )
        val dates = PruningCalculator.segmentCompletionDates(entries, rows)

        assertEquals("2026-08-30", dates[PruningSegment(1, 1)])
        // Quarter 2 was touched twice — the LATER day wins.
        assertEquals("2026-09-01", dates[PruningSegment(1, 2)])
        assertEquals("2026-09-01", dates[PruningSegment(1, 3)])
    }

    @Test
    fun `a row finished across several days completes on the last day`() {
        val rows = listOf(row(1))
        val entries = listOf(
            entry("2026-08-30", listOf(PruningSegment(1, 1), PruningSegment(1, 2))),
            entry("2026-09-01", listOf(PruningSegment(1, 3), PruningSegment(1, 4))),
        )
        val dates = PruningCalculator.segmentCompletionDates(entries, rows)
        val completion = (1..4).mapNotNull { dates[PruningSegment(1, it)] }.maxOrNull()

        assertEquals("2026-09-01", completion)
    }

    @Test
    fun `segments are canonicalised by row id exactly like completedSegments`() {
        val rowId = "0c1d2e3f-aaaa-bbbb-cccc-000000000001"
        val rows = listOf(row(101, rowId))
        val entries = listOf(
            entry("2026-09-01", listOf(PruningSegment(row = 999, quarter = 1, rowId = rowId))),
        )
        val dates = PruningCalculator.segmentCompletionDates(entries, rows)

        // Attributed to the ACTUAL row record, not the stale stored number.
        assertEquals("2026-09-01", dates[rows.first().segment(1)])
        // A segment for a row this block doesn't have is dropped, not adopted.
        assertNull(
            PruningCalculator.segmentCompletionDates(
                listOf(entry("2026-09-01", listOf(PruningSegment(7, 1, "0c1d2e3f-aaaa-bbbb-cccc-999999999999")))),
                rows,
            )[rows.first().segment(1)],
        )
    }

    // ------------------------------------------------- short date rendering

    @Test
    fun `short date follows the vineyard regional order with two-digit year`() {
        val sep1 = Instant.parse("2026-09-01T00:00:00Z").toEpochMilli()
        assertEquals("01/09/26", RegionFormatter(au).formatDateShort(sep1))
        assertEquals("09/01/26", RegionFormatter(us).formatDateShort(sep1))
        val iso = au.copy(dateFormat = RegionDateFormat.IsoYearMonthDay.raw)
        assertEquals("26-09-01", RegionFormatter(iso).formatDateShort(sep1))
    }

    @Test
    fun `short date from an ISO entry date never shifts the calendar day`() {
        assertEquals("01/09/26", RegionFormatter(au).formatDateShort("2026-09-01"))
        assertEquals("09/01/26", RegionFormatter(us).formatDateShort("2026-09-01"))
        // Bad data is returned untouched rather than crashing the row list.
        assertEquals("not-a-date", RegionFormatter(au).formatDateShort("not-a-date"))
    }
}
