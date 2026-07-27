package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * SHARED IRRIGATION CALCULATION FIXTURE — mirrors
 * `IrrigationCalculatorFixtureTests.swift` (iOS) and the assert block at the
 * end of `sql/125_irrigation_records.sql` (the authoritative implementation).
 * All three must produce these exact values before display formatting.
 *
 * Fixture: one valve at 2,000 L/h, 3.5 h (210 min) duration → 7,000 L total.
 * Two connected blocks:
 *   Block A — 60%, 20,000 m² (2 ha), 2,000 vines, 90% efficiency
 *   Block B — 40%, no area, no vine count, no efficiency
 */
class IrrigationCalculatorFixtureTest {

    private val fixture = listOf(
        IrrigationAllocationConfig(
            blockId = "00000000-0000-0000-0000-000000000001",
            blockName = "Block A",
            allocationPercentage = 60.0,
            servicedAreaM2 = 20_000.0,
            servicedVineCount = 2_000,
            efficiencyPercent = 90.0,
        ),
        IrrigationAllocationConfig(
            blockId = "00000000-0000-0000-0000-000000000002",
            blockName = "Block B",
            allocationPercentage = 40.0,
        ),
    )

    @Test
    fun `configured flow whole and partial hours`() {
        assertEquals(7000.0, IrrigationLocalCalc.totalVolume("configured_flow", 2000.0, 210, null, null, null), 0.0001)
        assertEquals(1500.0, IrrigationLocalCalc.totalVolume("session_flow", 1000.0, 90, null, null, null), 0.0001)
    }

    @Test
    fun `meter difference`() {
        assertEquals(3600.0, IrrigationLocalCalc.totalVolume("meter_readings", null, 60, 5000.0, 8600.0, null), 0.0001)
    }

    @Test
    fun `manual total volume preserved`() {
        assertEquals(4200.0, IrrigationLocalCalc.totalVolume("total_volume", null, 60, null, null, 4200.0), 0.0001)
    }

    @Test
    fun `invalid inputs rejected`() {
        assertThrows(IrrigationLocalCalc.CalcException::class.java) {
            IrrigationLocalCalc.totalVolume("session_flow", 0.0, 60, null, null, null)
        }
        assertThrows(IrrigationLocalCalc.CalcException::class.java) {
            IrrigationLocalCalc.totalVolume("session_flow", -5.0, 60, null, null, null)
        }
        assertThrows(IrrigationLocalCalc.CalcException::class.java) {
            IrrigationLocalCalc.totalVolume("configured_flow", 2000.0, 0, null, null, null)
        }
        assertThrows(IrrigationLocalCalc.CalcException::class.java) {
            IrrigationLocalCalc.totalVolume("meter_readings", null, 60, 8600.0, 5000.0, null)
        }
    }

    @Test
    fun `two block allocation fixture`() {
        val result = IrrigationLocalCalc.allocate(7000.0, fixture)

        assertEquals(2, result.blocks.size)
        val blockA = result.blocks[0]
        val blockB = result.blocks[1]

        assertEquals(4200.0, blockA.allocatedVolumeLitres, 0.0001)
        assertEquals(2800.0, blockB.allocatedVolumeLitres, 0.0001)
        assertEquals(2.1, blockA.waterLitresPerVine!!, 0.0001)
        assertEquals(2100.0, blockA.waterLitresPerHectare!!, 0.0001)
        assertEquals(0.21, blockA.irrigationDepthMm!!, 0.0001)
        assertEquals(3780.0, blockA.effectiveVolumeLitres!!, 0.0001)

        // Missing data → null, never zero.
        assertNull(blockB.waterLitresPerVine)
        assertNull(blockB.waterLitresPerHectare)
        assertNull(blockB.irrigationDepthMm)
        assertNull(blockB.effectiveVolumeLitres)

        // Session effective is null when any block lacks efficiency.
        assertNull(result.effectiveVolumeLitres)
        assertTrue(result.warnings.size >= 2)
    }

    @Test
    fun `allocation totals must be 100`() {
        assertThrows(IrrigationLocalCalc.CalcException::class.java) {
            IrrigationLocalCalc.allocate(1000.0, listOf(fixture[0])) // 60% only
        }
        assertThrows(IrrigationLocalCalc.CalcException::class.java) {
            IrrigationLocalCalc.allocate(
                1000.0,
                listOf(fixture[0], fixture[0]), // 120%
            )
        }
        assertThrows(IrrigationLocalCalc.CalcException::class.java) {
            IrrigationLocalCalc.allocate(1000.0, emptyList())
        }
    }

    @Test
    fun `decimal percentages`() {
        val result = IrrigationLocalCalc.allocate(
            1000.0,
            listOf(
                IrrigationAllocationConfig(blockId = "a", blockName = "A", allocationPercentage = 33.33),
                IrrigationAllocationConfig(blockId = "b", blockName = "B", allocationPercentage = 66.67),
            ),
        )
        assertEquals(333.3, result.blocks[0].allocatedVolumeLitres, 0.0001)
        assertEquals(666.7, result.blocks[1].allocatedVolumeLitres, 0.0001)
    }

    @Test
    fun `unit conversions`() {
        assertEquals(264.172052, 1000 * IrrigationLocalCalc.US_GALLONS_PER_LITRE, 0.0001)
        assertEquals(219.969157, 1000 * IrrigationLocalCalc.IMPERIAL_GALLONS_PER_LITRE, 0.0001)
        assertTrue(abs(IrrigationLocalCalc.litresPerHectareToGallonsPerAcre(2100.0, usGallon = true) - 224.504) < 0.01)
        assertEquals(1.0, 25.4 / IrrigationLocalCalc.MM_PER_INCH, 0.000001)
    }

    // ------------------------------------------------------------------------
    // Row-based weighting fixture — mirrors the assert block in
    // sql/126_irrigation_row_allocations.sql and IrrigationCalculatorFixtureTests.swift.
    // ------------------------------------------------------------------------

    private fun row(
        rowId: String,
        blockId: String,
        blockName: String,
        number: Int,
        emitters: Int? = null,
        vines: Int? = null,
        length: Double? = null,
        emitterBasis: String? = null,
        vineBasis: String? = null,
    ) = IrrigationAvailableRow(
        rowId = rowId, blockId = blockId, blockName = blockName,
        rowNumber = number, emitterCount = emitters, vineCount = vines,
        rowLengthMetres = length,
        emitterCountBasis = emitterBasis, vineCountBasis = vineBasis,
    )

    @Test
    fun `row weighting emitter basis totals exactly 100`() {
        val result = IrrigationLocalCalc.rowWeighting(
            listOf(
                row("a1", "00000000-0000-0000-0000-000000000001", "Block 1A", 1, emitters = 130, vines = 65, length = 100.0),
                row("a2", "00000000-0000-0000-0000-000000000001", "Block 1A", 2, emitters = 70, vines = 35, length = 60.0),
                row("b1", "00000000-0000-0000-0000-000000000002", "Block 1B", 1, emitters = 100, vines = 50, length = 80.0),
            ),
        )
        assertEquals("emitter_count", result.basis)
        assertEquals(66.6667, result.blocks[0].percentage, 0.0001)
        assertEquals(33.3333, result.blocks[1].percentage, 0.0001)
        assertEquals(100.0, result.blocks.sumOf { it.percentage }, 0.0)
    }

    @Test
    fun `row weighting never mixes units - falls back to common basis`() {
        // One row missing emitters but all rows have vines → vine basis.
        val vines = IrrigationLocalCalc.rowWeighting(
            listOf(
                row("a1", "00000000-0000-0000-0000-000000000001", "A", 1, emitters = 130, vines = 60, length = 100.0),
                row("b1", "00000000-0000-0000-0000-000000000002", "B", 1, vines = 40, length = 80.0),
            ),
        )
        assertEquals("vine_count", vines.basis)
        assertEquals(60.0, vines.blocks[0].percentage, 0.0001)

        // Lengths only → row-length basis.
        val lengths = IrrigationLocalCalc.rowWeighting(
            listOf(
                row("a1", "00000000-0000-0000-0000-000000000001", "A", 1, length = 150.0),
                row("b1", "00000000-0000-0000-0000-000000000002", "B", 1, length = 50.0),
            ),
        )
        assertEquals("row_length", lengths.basis)
        assertEquals(75.0, lengths.blocks[0].percentage, 0.0001)
    }

    @Test
    fun `row weighting equal rows fallback`() {
        // Non-sequential selection 1,2,5 + 8 stays explicit rows; A 3 rows, B 1 row → 75 / 25.
        val result = IrrigationLocalCalc.rowWeighting(
            listOf(
                row("a1", "00000000-0000-0000-0000-000000000001", "A", 1),
                row("a2", "00000000-0000-0000-0000-000000000001", "A", 2),
                row("a5", "00000000-0000-0000-0000-000000000001", "A", 5),
                row("b8", "00000000-0000-0000-0000-000000000002", "B", 8),
            ),
        )
        assertEquals("equal_rows", result.basis)
        assertEquals(75.0, result.blocks[0].percentage, 0.0001)
        assertEquals(3, result.blocks[0].rowCount)
        assertEquals(25.0, result.blocks[1].percentage, 0.0001)
    }

    // ------------------------------------------------------------------------
    // SQL 127 basis-honesty fixture — mirrors the assert block in
    // sql/127_irrigation_row_estimates.sql and IrrigationCalculatorFixtureTests.swift.
    // ------------------------------------------------------------------------

    @Test
    fun `spacing-derived emitter estimates keep the row-length basis`() {
        val result = IrrigationLocalCalc.rowWeighting(
            listOf(
                row(
                    "a1", "00000000-0000-0000-0000-000000000001", "A", 1,
                    emitters = 430, vines = 103, length = 215.01,
                    emitterBasis = "row_length_spacing", vineBasis = "row_length_spacing",
                ),
                row(
                    "b1", "00000000-0000-0000-0000-000000000002", "B", 1,
                    emitters = 143, vines = 34, length = 71.67,
                    emitterBasis = "row_length_spacing", vineBasis = "row_length_spacing",
                ),
            ),
        )
        assertEquals("row_length", result.basis)
        assertEquals(75.0, result.blocks[0].percentage, 0.0001)
    }

    @Test
    fun `reconciled block-total vines are a valid vine basis`() {
        val result = IrrigationLocalCalc.rowWeighting(
            listOf(
                row(
                    "a1", "00000000-0000-0000-0000-000000000001", "A", 1,
                    emitters = 200, vines = 120, length = 100.0,
                    emitterBasis = "row_length_spacing", vineBasis = "block_total_proportional",
                ),
                row(
                    "b1", "00000000-0000-0000-0000-000000000002", "B", 1,
                    emitters = 200, vines = 40, length = 100.0,
                    emitterBasis = "row_length_spacing", vineBasis = "block_total_proportional",
                ),
            ),
        )
        assertEquals("vine_count", result.basis)
        assertEquals(75.0, result.blocks[0].percentage, 0.0001)
    }

    @Test
    fun `exact emitter basis still wins and legacy rows stay exact`() {
        val exact = IrrigationLocalCalc.rowWeighting(
            listOf(
                row(
                    "a1", "00000000-0000-0000-0000-000000000001", "A", 1,
                    emitters = 300, length = 100.0, emitterBasis = "exact",
                ),
                row(
                    "b1", "00000000-0000-0000-0000-000000000002", "B", 1,
                    emitters = 100, length = 100.0, emitterBasis = "exact",
                ),
            ),
        )
        assertEquals("emitter_count", exact.basis)
        assertEquals(75.0, exact.blocks[0].percentage, 0.0001)

        // Rows without basis metadata keep the legacy exact interpretation
        // (covered by the SQL 126 fixtures above) — spot check:
        val legacy = IrrigationLocalCalc.rowWeighting(
            listOf(
                row("a1", "00000000-0000-0000-0000-000000000001", "A", 1, emitters = 130, length = 100.0),
                row("b1", "00000000-0000-0000-0000-000000000002", "B", 1, emitters = 70, length = 60.0),
            ),
        )
        assertEquals("emitter_count", legacy.basis)
    }

    @Test
    fun `missing row length with spacing-derived data falls back to equal rows`() {
        val result = IrrigationLocalCalc.rowWeighting(
            listOf(
                row(
                    "a1", "00000000-0000-0000-0000-000000000001", "A", 1,
                    emitters = 200, vines = 50, length = 100.0,
                    emitterBasis = "row_length_spacing", vineBasis = "row_length_spacing",
                ),
                row(
                    "b69", "00000000-0000-0000-0000-000000000002", "B", 69,
                    emitterBasis = "unavailable", vineBasis = "unavailable",
                ),
            ),
        )
        assertEquals("equal_rows", result.basis)
        assertEquals(50.0, result.blocks[0].percentage, 0.0001)
    }

    @Test
    fun `row range summary compresses only contiguous runs`() {
        // 1,2,5,8 must display as "1–2, 5, 8" — never "1–8".
        assertEquals("1–2, 5, 8", IrrigationLocalCalc.rangeSummary(listOf(1, 2, 5, 8)))
        assertEquals("1–2, 5, 8", IrrigationLocalCalc.rangeSummary(listOf(8, 5, 2, 1)))
        assertEquals("1–4", IrrigationLocalCalc.rangeSummary(listOf(1, 2, 3, 4)))
        assertEquals("7", IrrigationLocalCalc.rangeSummary(listOf(7)))
        assertEquals("1, 10, 13–15, 18, 22–25", IrrigationLocalCalc.rangeSummary(listOf(1, 10, 13, 14, 15, 18, 22, 23, 24, 25)))
        assertEquals("", IrrigationLocalCalc.rangeSummary(emptyList()))
        assertEquals("3–4", IrrigationLocalCalc.rangeSummary(listOf(3, 3, 4)))
    }
}
