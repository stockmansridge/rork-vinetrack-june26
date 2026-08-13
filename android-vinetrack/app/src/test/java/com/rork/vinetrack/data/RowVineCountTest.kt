package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.PaddockRowRegeneration
import com.rork.vinetrack.data.model.PaddockRowVineCount
import com.rork.vinetrack.data.model.PieceRateCosting
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import kotlin.math.abs

/**
 * PER-ROW VINE COUNTS (sql/188) — the Android twin of `RowVineCountTests.swift`.
 * Both suites assert the SAME fixtures from the SAME coordinates, so any
 * divergence between the platforms fails a build.
 *
 * THE rule under test:
 * ```text
 * calculatedVineCount = round(row length in metres / vine spacing in metres)
 * effectiveVineCount  = vineCountOverride ?: calculatedVineCount
 * ```
 *
 * Both inputs already exist in the app — the row's own start/end geometry and
 * the BLOCK's vine spacing — so a grower who only ever uses the phone gets a
 * vine count for every row without typing anything.
 */
class RowVineCountTest {

    // ---- Shared fixtures (identical on iOS) ----

    /** The block's vine spacing. Everything below divides by this. */
    private val vineSpacing = 1.5

    private val baseLatitude = -34.5121
    private val baseLongitude = 138.7128

    /**
     * Metres per degree of latitude — the constant the production geometry
     * helpers use. Building rows that run due north/south makes their length
     * exact regardless of the longitude scale factor.
     */
    private val metresPerDegreeLatitude = 111_320.0

    /**
     * A realistic vineyard row: runs due north for [lengthMetres], offset east
     * by [index] row widths. Real coordinates, not hand-fed distances.
     */
    private fun row(
        number: Int,
        lengthMetres: Double,
        index: Int,
        override: Int? = null,
        id: String = UUID.randomUUID().toString(),
    ): PaddockRow {
        val longitude = baseLongitude + index * 0.000027
        return PaddockRow(
            id = id,
            number = number,
            startPoint = CoordinatePoint(baseLatitude, longitude),
            endPoint = CoordinatePoint(
                baseLatitude + lengthMetres / metresPerDegreeLatitude,
                longitude,
            ),
            vineCountOverride = override,
        )
    }

    private fun block(rows: List<PaddockRow>, spacing: Double? = vineSpacing): Paddock = Paddock(
        id = "22222222-2222-4222-8222-222222222222",
        vineyardId = "11111111-1111-4111-8111-111111111111",
        name = "Piece Rate Fixture",
        vineSpacing = spacing,
        rows = rows,
    )

    /**
     * THE fixture block, shared verbatim with the iOS suite:
     *
     * ```text
     * Row 42 — 240 m -> 160 calculated, manual override 158
     * Row 43 — 252 m -> 168 calculated
     * Row 44 — 250 m -> 166.67 -> 167 calculated
     * ```
     */
    private fun fixtureBlock(): Paddock = block(
        listOf(
            row(number = 42, lengthMetres = 240.0, index = 0, override = 158),
            row(number = 43, lengthMetres = 252.0, index = 1),
            row(number = 44, lengthMetres = 250.0, index = 2),
        ),
    )

    private fun Paddock.rowNumbered(number: Int): PaddockRow =
        rows.orEmpty().first { it.number == number }

    // ---- 1. The calculation happens automatically ----

    @Test
    fun `a rows vines are calculated from its own geometry and the blocks vine spacing`() {
        val paddock = fixtureBlock()
        val row44 = paddock.rowNumbered(44)

        // The row is 250 m of real mapped geometry.
        assertTrue(abs(paddock.rowLengthMetres(row44) - 250.0) < 0.01)

        // 250 / 1.5 = 166.67 -> 167 vines. Nothing was typed to get this.
        assertEquals(167, paddock.calculatedVineCount(row44))
    }

    @Test
    fun `the rounding rule is half away from zero on whole vines`() {
        // The worked example from the contract.
        assertEquals(167, PaddockRowVineCount.calculated(250.0, 1.5))
        // Exactly on a vine.
        assertEquals(168, PaddockRowVineCount.calculated(252.0, 1.5))
        // Just below the half — rounds down.
        assertEquals(166, PaddockRowVineCount.calculated(249.7, 1.5))
        // Exactly on the half — rounds away from zero.
        assertEquals(167, PaddockRowVineCount.calculated(249.75, 1.5))
        // The rounding primitive itself, including the negative direction
        // Kotlin has to mirror explicitly to match Swift.
        assertEquals(167, PaddockRowVineCount.roundVines(166.5))
        assertEquals(-167, PaddockRowVineCount.roundVines(-166.5))
        assertEquals(166, PaddockRowVineCount.roundVines(166.4999))
    }

    // ---- 2/3/4. Override precedence ----

    @Test
    fun `with no override the effective count is the calculated one`() {
        val paddock = fixtureBlock()
        val row44 = paddock.rowNumbered(44)
        assertNull(row44.vineCountOverride)
        assertEquals(167, paddock.calculatedVineCount(row44))
        assertEquals(167, paddock.effectiveVineCount(row44))
    }

    @Test
    fun `a manual override wins over the calculated count`() {
        val paddock = fixtureBlock()
        val row42 = paddock.rowNumbered(42)
        // 240 / 1.5 = 160 calculated, but the operator counted 158.
        assertEquals(160, paddock.calculatedVineCount(row42))
        assertEquals(158, paddock.effectiveVineCount(row42))
    }

    @Test
    fun `clearing the override returns to the calculated count`() {
        val paddock = fixtureBlock()
        assertEquals(158, paddock.effectiveVineCount(paddock.rowNumbered(42)))

        val cleared = paddock.copy(
            rows = paddock.rows.orEmpty().map {
                if (it.number == 42) it.copy(vineCountOverride = null) else it
            },
        )
        assertEquals(160, cleared.effectiveVineCount(cleared.rowNumbered(42)))
        assertEquals(160, cleared.calculatedVineCount(cleared.rowNumbered(42)))
    }

    @Test
    fun `zero and negative are not overrides at all`() {
        assertEquals(167, PaddockRowVineCount.effective(0, 250.0, 1.5))
        assertEquals(167, PaddockRowVineCount.effective(-5, 250.0, 1.5))
        assertNull(PaddockRowVineCount.sanitiseOverride(0))
        assertNull(PaddockRowVineCount.sanitiseOverride(-5))
    }

    // ---- 5. Each row is measured individually ----

    @Test
    fun `rows of different lengths get different vine counts`() {
        // An irregular boundary: every row a different length. The block
        // average would report the same number for all three, which is exactly
        // the bug this rule exists to prevent.
        val paddock = block(
            listOf(
                row(number = 1, lengthMetres = 120.0, index = 0),
                row(number = 2, lengthMetres = 250.0, index = 1),
                row(number = 3, lengthMetres = 318.0, index = 2),
            ),
        )
        val counts = paddock.rows.orEmpty().map { paddock.calculatedVineCount(it) }
        assertEquals(listOf(80, 167, 212), counts)

        // And the average-length shortcut would have been wrong for all three.
        val averageBased = PaddockRowVineCount.calculated((120.0 + 250.0 + 318.0) / 3.0, vineSpacing)
        assertEquals(153, averageBased)
        assertFalse(counts.contains(153))
    }

    // ---- 6/7. Missing data is "—", never 0 ----

    @Test
    fun `missing vine spacing makes the count unavailable rather than zero`() {
        val calculation = PaddockRowVineCount.calculation(250.0, 0.0)
        assertNull(calculation.value)
        assertEquals(PaddockRowVineCount.Unavailable.MISSING_VINE_SPACING, calculation.unavailable)
        assertEquals("Set vine spacing in block details to calculate vines.", calculation.message)

        assertNull(PaddockRowVineCount.calculated(250.0, null))
        assertNull(PaddockRowVineCount.calculated(250.0, -1.0))
        // A manual count still works with no spacing — it needs no calculation.
        assertEquals(158, PaddockRowVineCount.effective(158, 250.0, 0.0))
        // ...but with neither, there is genuinely nothing to show.
        assertNull(PaddockRowVineCount.effective(null, 250.0, 0.0))

        val paddock = block(listOf(row(number = 1, lengthMetres = 250.0, index = 0)), spacing = null)
        assertNull(paddock.calculatedVineCount(paddock.rowNumbered(1)))
    }

    @Test
    fun `invalid row geometry makes the count unavailable rather than zero`() {
        val calculation = PaddockRowVineCount.calculation(0.0, 1.5)
        assertNull(calculation.value)
        assertEquals(PaddockRowVineCount.Unavailable.INVALID_GEOMETRY, calculation.unavailable)

        // An unmapped row: start and end at the same place.
        val unmapped = PaddockRow(
            id = UUID.randomUUID().toString(),
            number = 9,
            startPoint = CoordinatePoint(baseLatitude, baseLongitude),
            endPoint = CoordinatePoint(baseLatitude, baseLongitude),
        )
        val paddock = block(listOf(unmapped))
        assertNull(paddock.calculatedVineCount(unmapped))
        assertNull(paddock.effectiveVineCount(unmapped))

        // A row with no geometry at all.
        val noGeometry = PaddockRow(id = UUID.randomUUID().toString(), number = 10)
        assertNull(block(listOf(noGeometry)).calculatedVineCount(noGeometry))
        assertNull(PaddockRowVineCount.calculated(Double.NaN, 1.5))
    }

    // ---- 8. The override survives save/reload ----

    @Test
    fun `a rows manual count survives a save and reload`() {
        val paddock = fixtureBlock()
        val json = Json { ignoreUnknownKeys = true }
        val encoded = json.encodeToString(paddock.rows.orEmpty())
        val reloaded = json.decodeFromString<List<PaddockRow>>(encoded)

        val row42 = reloaded.first { it.number == 42 }
        assertEquals(158, row42.vineCountOverride)
        // Its stable id came back too, so pruning progress stays attached.
        assertEquals(paddock.rowNumbered(42).stableId, row42.stableId)

        // Rows the operator never overrode keep the EXACT older JSON shape —
        // the key is absent, not null, so the portal parses them unchanged.
        assertEquals(1, encoded.split("vineCountOverride").size - 1)

        val rebuilt = paddock.copy(rows = reloaded)
        assertEquals(158, rebuilt.effectiveVineCount(row42))
    }

    // ---- 9. The override survives geometry regeneration ----

    @Test
    fun `a rows manual count survives ordinary geometry regeneration`() {
        val existing = fixtureBlock().rows.orEmpty()
        // The editor rebuilds every row from the boundary — fresh ids, slightly
        // different lengths, no overrides.
        val regenerated = listOf(
            row(number = 42, lengthMetres = 244.0, index = 0),
            row(number = 43, lengthMetres = 256.0, index = 1),
            row(number = 44, lengthMetres = 254.0, index = 2),
        )
        val preserved = PaddockRowRegeneration.preserveIdentity(regenerated, existing)

        val row42 = preserved.first { it.number == 42 }
        // Identity AND the manual count carried across.
        assertEquals(existing.first { it.number == 42 }.stableId, row42.stableId)
        assertEquals(158, row42.vineCountOverride)

        // The NEW geometry is in use, so untouched rows re-calculate.
        val paddock = block(preserved)
        assertEquals(163, paddock.calculatedVineCount(row42))
        assertEquals(158, paddock.effectiveVineCount(row42))
        assertEquals(169, paddock.effectiveVineCount(paddock.rowNumbered(44)))

        // A genuinely new row keeps its fresh id and has no manual count.
        val grown = PaddockRowRegeneration.preserveIdentity(
            regenerated + row(number = 45, lengthMetres = 250.0, index = 3),
            existing,
        )
        assertNull(grown.first { it.number == 45 }.vineCountOverride)
    }

    // ---- 10. Row-based block total ----

    @Test
    fun `the row based block total is the sum of the effective counts`() {
        val paddock = fixtureBlock()
        // 158 (manual) + 168 + 167 = 493
        assertEquals(493, paddock.rowsEffectiveVineCount)
        assertTrue(paddock.hasRowVineCountOverrides)

        // The BLOCK-level override is a separate number and is NOT touched by
        // any of this (sql/188 keeps the two independent).
        val withBlockOverride = paddock.copy(vineCountOverride = 500)
        assertEquals(500, withBlockOverride.effectiveVineCount)
        assertEquals(493, withBlockOverride.rowsEffectiveVineCount)
    }

    // ---- 11/12. Piece rate uses the effective counts automatically ----

    @Test
    fun `piece rate costs the selected rows at their effective counts`() {
        val paddock = fixtureBlock()
        val snapshot = PieceRateCosting.snapshotRows(
            workTaskId = UUID.randomUUID().toString(),
            vineyardId = paddock.vineyardId,
            paddock = paddock,
            selectedRowIds = paddock.rows.orEmpty().map { it.stableId }.toSet(),
            newId = { UUID.randomUUID().toString() },
        )

        // Row 42 manual 158, row 43 calculated 168, row 44 calculated 167.
        assertEquals(listOf(42, 43, 44), snapshot.map { it.rowNumber })
        assertEquals(listOf(158, 168, 167), snapshot.map { it.vineCount })

        // The operator selected rows and typed a rate — never a quantity.
        val vineCount = PieceRateCosting.vineCountForSelectedRows(snapshot)
        assertEquals(493, vineCount)

        val cost = PieceRateCosting.cost(vineCount, 1.27)
        assertNotNull(cost)
        assertEquals(626.11, cost!!, 0.0001)
        assertEquals("$626.11", PieceRateCosting.currencyLabel(cost))
        assertTrue(PieceRateCosting.isValid(1.27, vineCount))
    }

    @Test
    fun `selecting a subset costs only those rows`() {
        val paddock = fixtureBlock()
        val snapshot = PieceRateCosting.snapshotRows(
            workTaskId = UUID.randomUUID().toString(),
            vineyardId = paddock.vineyardId,
            paddock = paddock,
            selectedRowIds = setOf(paddock.rowNumbered(44).stableId),
            newId = { UUID.randomUUID().toString() },
        )
        assertEquals(listOf(167), snapshot.map { it.vineCount })
        assertEquals(167, PieceRateCosting.vineCountForSelectedRows(snapshot))
    }

    // ---- 13. The historical snapshot never re-prices ----

    @Test
    fun `later row edits never change a finished piece rate job`() {
        val paddock = fixtureBlock()
        val snapshot = PieceRateCosting.snapshotRows(
            workTaskId = UUID.randomUUID().toString(),
            vineyardId = paddock.vineyardId,
            paddock = paddock,
            selectedRowIds = emptySet(),
            newId = { UUID.randomUUID().toString() },
        )
        val quantityAtCostingTime = PieceRateCosting.vineCountForSelectedRows(snapshot)
        assertEquals(493, quantityAtCostingTime)

        // Six months later the block is re-surveyed: the spacing changes, the
        // rows are re-mapped longer, and the manual count is cleared.
        val resurveyed = paddock.copy(
            vineSpacing = 1.2,
            rows = listOf(
                row(number = 42, lengthMetres = 300.0, index = 0),
                row(number = 43, lengthMetres = 310.0, index = 1),
                row(number = 44, lengthMetres = 305.0, index = 2),
            ),
        )
        assertEquals(762, resurveyed.rowsEffectiveVineCount)

        // The finished job is costed from its SNAPSHOT, so it is unmoved.
        val resolved = PieceRateCosting.resolve(
            method = WorkTaskCostingMethod.PIECE_RATE,
            labourLines = emptyList(),
            pieceVineCount = quantityAtCostingTime,
            pieceRatePerVine = 1.27,
        )
        assertNotNull(resolved.cost)
        assertEquals(626.11, resolved.cost!!, 0.0001)
        assertEquals(listOf(158, 168, 167), snapshot.map { it.vineCount })

        // A NEW job started today does use today's numbers.
        val today = PieceRateCosting.snapshotRows(
            workTaskId = UUID.randomUUID().toString(),
            vineyardId = resurveyed.vineyardId,
            paddock = resurveyed,
            selectedRowIds = emptySet(),
            newId = { UUID.randomUUID().toString() },
        )
        assertEquals(762, PieceRateCosting.vineCountForSelectedRows(today))
    }

    // ---- Override input validation ----

    @Test
    fun `the override field takes whole positive numbers only`() {
        assertTrue(PaddockRowVineCount.parseOverride("") is PaddockRowVineCount.OverrideInput.Cleared)
        assertTrue(PaddockRowVineCount.parseOverride("   ") is PaddockRowVineCount.OverrideInput.Cleared)
        assertEquals(158, PaddockRowVineCount.parseOverride("158").value)
        assertEquals(158, PaddockRowVineCount.parseOverride(" 158 ").value)
        assertTrue(PaddockRowVineCount.parseOverride("158.5").isInvalid)
        assertTrue(PaddockRowVineCount.parseOverride("-5").isInvalid)
        assertTrue(PaddockRowVineCount.parseOverride("0").isInvalid)
        assertTrue(PaddockRowVineCount.parseOverride("abc").isInvalid)
        assertTrue(PaddockRowVineCount.parseOverride("100001").isInvalid)
        assertEquals(100_000, PaddockRowVineCount.parseOverride("100000").value)
    }
}
