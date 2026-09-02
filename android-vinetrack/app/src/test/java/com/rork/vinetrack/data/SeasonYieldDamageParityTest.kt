package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.DamageRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos

/**
 * The shared cross-platform damage contract from
 * `docs/season-yield-damage-parity-fixtures.md`, mirroring
 * `SeasonYieldDamageParityTests.swift` on iOS.
 *
 * Two tolerances, deliberately:
 *  * **Arithmetic fixtures — `1e-9`.** Areas are supplied, so the loss
 *    fraction, reduction and adjusted tonnes are pure arithmetic every platform
 *    must reproduce exactly.
 *  * **Geometry fixtures — `1e-6`.** Hectares come from each platform's own
 *    implementation of the sql/095 projection; identical coordinates still
 *    differ in the last bits across Postgres numeric and Kotlin `Double`.
 *
 * Fixture 2 is the defect distinguisher: the retired multiplicative engine
 * returned a *remaining* factor of 0.8 and an adjusted 1.728 t for a 20% record
 * over 10% of a block. The correct answer is a 2% loss → 2.1168 t.
 */
class SeasonYieldDamageParityTest {

    /** Arithmetic must agree exactly. */
    private val arithmetic = 1e-9

    /** Polygon → hectares only agrees to a practical tolerance. */
    private val geometry = 1e-6

    private val blockA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val blockB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val vineyardId = "11111111-1111-4111-8111-111111111111"

    // Shared block fixtures (§2 of the contract doc).
    private val blockAAreaHa = 2.0
    private val blockBAreaHa = 1.5
    private val blockABase = 2.16       // V2027
    private val blockABaseV2026 = 1.8
    private val blockBBase = 3.6

    private fun mapped(areaHectares: Double, damagePercent: Double) =
        SeasonYieldDamage.MappedRecord(areaHectares, damagePercent)

    private fun damage(
        block: String,
        areaHa: Double,
        records: List<SeasonYieldDamage.MappedRecord>,
        excluded: Int = 0,
    ) = SeasonYieldDamage.blockDamage(
        paddockId = block,
        blockAreaHectares = areaHa,
        mappedRecords = records,
        excludedRecordCount = excluded,
    )

    /**
     * Loss fraction and remaining multiplier must always be complements —
     * reading one under the other's name inverts the answer.
     */
    private fun assertComplementary(result: SeasonYieldDamage.BlockDamage) {
        assertEquals(
            "loss fraction and remaining multiplier must sum to 1",
            1.0,
            result.damageLossFraction + result.remainingYieldMultiplier,
            arithmetic,
        )
    }

    // ---- Fixture 1 — No damage ---------------------------------------------

    @Test
    fun `fixture 1 - no damage leaves the base untouched`() {
        val result = damage(blockA, blockAAreaHa, emptyList())

        assertEquals(0, result.eligibleRecordCount)
        assertEquals(0.0, result.mappedAreaHectares, arithmetic)
        assertEquals(0.0, result.effectiveLossHectares, arithmetic)
        assertEquals(0.0, result.damageLossFraction, arithmetic)
        assertEquals(1.0, result.remainingYieldMultiplier, arithmetic)
        assertEquals(0.0, result.reductionTonnes(blockABase), arithmetic)
        assertEquals(2.16, result.adjustedTonnes(blockABase), arithmetic)
        assertTrue(result.warnings.isEmpty())
        assertComplementary(result)
    }

    // ---- Fixture 2 — the defect distinguisher ------------------------------

    @Test
    fun `fixture 2 - 20 percent over a tenth of the block is a 2 percent loss`() {
        val result = damage(blockA, blockAAreaHa, listOf(mapped(0.2, 20.0)))

        assertEquals(1, result.eligibleRecordCount)
        assertEquals(0.2, result.mappedAreaHectares, arithmetic)
        assertEquals(0.04, result.effectiveLossHectares, arithmetic)
        assertEquals(0.02, result.damageLossFraction, arithmetic)
        assertEquals(0.98, result.remainingYieldMultiplier, arithmetic)
        assertEquals(0.0432, result.reductionTonnes(blockABase), arithmetic)
        assertEquals(2.1168, result.adjustedTonnes(blockABase), arithmetic)
        assertComplementary(result)

        // The retired multiplicative engine's answer, explicitly rejected.
        assertTrue(
            "must not reproduce the old multiplicative 1.728 t",
            kotlin.math.abs(result.adjustedTonnes(blockABase) - 1.728) > 1e-6,
        )
    }

    // ---- Fixture 3 — multiple non-overlapping records ----------------------

    @Test
    fun `fixture 3 - multiple records sum their effective loss areas`() {
        val result = damage(blockA, blockAAreaHa, listOf(mapped(0.2, 20.0), mapped(0.3, 10.0)))

        assertEquals(2, result.eligibleRecordCount)
        assertEquals(0.5, result.mappedAreaHectares, arithmetic)
        assertEquals(0.07, result.effectiveLossHectares, arithmetic)
        assertEquals(0.035, result.damageLossFraction, arithmetic)
        assertEquals(0.965, result.remainingYieldMultiplier, arithmetic)
        assertEquals(0.0756, result.reductionTonnes(blockABase), arithmetic)
        assertEquals(2.0844, result.adjustedTonnes(blockABase), arithmetic)
        assertComplementary(result)
    }

    // ---- Fixture 4 — capped at 100% per block ------------------------------

    @Test
    fun `fixture 4 - combined loss is capped at the whole block`() {
        // 2.0 ha @ 100% + 2.0 ha @ 30% = 2.6 ha on a 2.0 ha block → 1.3, capped.
        val result = damage(blockA, blockAAreaHa, listOf(mapped(2.0, 100.0), mapped(2.0, 30.0)))

        assertEquals(4.0, result.mappedAreaHectares, arithmetic)
        assertEquals(2.6, result.effectiveLossHectares, arithmetic)
        assertEquals(1.0, result.damageLossFraction, arithmetic)
        assertEquals(0.0, result.remainingYieldMultiplier, arithmetic)
        assertEquals(2.16, result.reductionTonnes(blockABase), arithmetic)
        assertEquals(0.0, result.adjustedTonnes(blockABase), arithmetic)
        assertTrue(result.adjustedTonnes(blockABase) >= 0.0)
        assertComplementary(result)
    }

    @Test
    fun `fixture 4 - whole block at full intensity loses exactly everything`() {
        val result = damage(blockA, blockAAreaHa, listOf(mapped(2.0, 100.0)))

        assertEquals(2.0, result.mappedAreaHectares, arithmetic)
        assertEquals(2.0, result.effectiveLossHectares, arithmetic)
        assertEquals(1.0, result.damageLossFraction, arithmetic)
        assertEquals(0.0, result.adjustedTonnes(blockABase), arithmetic)
        assertComplementary(result)
    }

    // ---- Fixture 5 — two vintages, damage in only one ----------------------

    @Test
    fun `fixture 5 - damage applies only to its own vintage`() {
        val v2026 = damage(blockA, blockAAreaHa, listOf(mapped(0.2, 20.0)))
        assertEquals(0.02, v2026.damageLossFraction, arithmetic)
        assertEquals(0.036, v2026.reductionTonnes(blockABaseV2026), arithmetic)
        assertEquals(1.764, v2026.adjustedTonnes(blockABaseV2026), arithmetic)

        val v2027 = damage(blockA, blockAAreaHa, emptyList())
        assertEquals(0.0, v2027.damageLossFraction, arithmetic)
        assertEquals(2.16, v2027.adjustedTonnes(blockABase), arithmetic)
    }

    @Test
    fun `damage records are filtered by the server resolved vintage`() {
        val synced2027 = record(vintage = 2027, date = "2027-03-01")
        // date says 2027; the SERVER says 2026 — the server wins.
        val synced2026 = record(vintage = 2026, date = "2027-03-01")
        val otherVineyard = record(vintage = 2027, date = "2027-03-01", vineyard = "other")

        val scoped = SeasonYieldProjection.damageRecords(
            records = listOf(synced2027, synced2026, otherVineyard),
            vineyardId = vineyardId,
            vintage = 2027,
            seasonStartMonth = 9,
            seasonStartDay = 1,
        )

        assertEquals(1, scoped.size)
        assertEquals(synced2027.id, scoped.first().id)
    }

    @Test
    fun `unsynced record falls back to the local season resolver`() {
        // 2 Sep 2026 with a 1 Sep season start is vineyard-local Vintage 2027.
        val unsynced = record(vintage = null, date = "2026-09-02")
        assertEquals(2027, unsynced.resolvedVintage(9, 1))
    }

    // ---- Fixture 6 / 9 — ineligible and invalid records --------------------

    @Test
    fun `fixture 6 - a polygonless record is excluded and warns`() {
        val result = damage(blockA, blockAAreaHa, emptyList(), excluded = 1)

        assertEquals(0, result.eligibleRecordCount)
        assertEquals(1, result.excludedRecordCount)
        assertEquals(0.0, result.mappedAreaHectares, arithmetic)
        assertEquals(0.0, result.damageLossFraction, arithmetic)
        assertEquals(2.16, result.adjustedTonnes(blockABase), arithmetic)
        assertTrue(result.warnings.contains(SeasonYieldDamage.WARNING_RECORD_WITHOUT_POLYGON))
    }

    @Test
    fun `fixture 9 - invalid polygons are all rejected before any area maths`() {
        val twoPoints = listOf(point(-33.0, 149.0), point(-33.0, 149.002))
        val nonFinite = listOf(point(-33.0, 149.0), point(-33.0, Double.NaN), point(-33.002, 149.002))
        val latOutOfRange = listOf(point(-91.5, 149.0), point(-33.0, 149.002), point(-33.002, 149.002))
        val lonOutOfRange = listOf(point(-33.0, 149.0), point(-33.0, 180.5), point(-33.002, 149.002))
        val infinite = listOf(
            point(-33.0, 149.0),
            point(Double.POSITIVE_INFINITY, 149.002),
            point(-33.002, 149.002),
        )

        listOf(twoPoints, nonFinite, latOutOfRange, lonOutOfRange, infinite).forEach { polygon ->
            assertFalse(SeasonYieldDamage.isValidPolygon(polygon))
            assertEquals(0.0, SeasonYieldDamage.areaHectares(polygon), arithmetic)
        }

        val records = listOf(twoPoints, nonFinite, latOutOfRange, lonOutOfRange).map { polygon ->
            record(vintage = 2027, date = "2027-03-01", percent = 50.0, polygon = polygon)
        }
        val result = SeasonYieldDamage.blockDamage(
            paddockId = blockA,
            blockAreaHectares = blockAAreaHa,
            records = records,
        )

        assertEquals(0, result.eligibleRecordCount)
        assertEquals(4, result.excludedRecordCount)
        assertEquals(0.0, result.mappedAreaHectares, arithmetic)
        assertEquals(0.0, result.damageLossFraction, arithmetic)
        assertEquals(2.16, result.adjustedTonnes(blockABase), arithmetic)
        assertTrue(result.warnings.contains(SeasonYieldDamage.WARNING_RECORD_WITHOUT_POLYGON))
    }

    @Test
    fun `a block without area warns and keeps its base figures`() {
        val result = damage(blockA, 0.0, listOf(mapped(0.2, 20.0)))

        assertNull(result.blockAreaHectares)
        assertTrue(result.isAreaUnavailable)
        assertEquals(0.0, result.damageLossFraction, arithmetic)
        assertEquals(2.16, result.adjustedTonnes(blockABase), arithmetic)
        assertTrue(result.warnings.contains(SeasonYieldDamage.WARNING_BLOCK_AREA_UNAVAILABLE))
    }

    // ---- Fixture 7 — two blocks, only one damaged --------------------------

    @Test
    fun `fixture 7 - blocks are calculated independently then summed`() {
        val a = damage(blockA, blockAAreaHa, listOf(mapped(0.2, 20.0)))
        val b = damage(blockB, blockBAreaHa, emptyList())

        assertEquals(0.02, a.damageLossFraction, arithmetic)
        assertEquals(0.0, b.damageLossFraction, arithmetic)

        val adjustedA = a.adjustedTonnes(blockABase)
        val adjustedB = b.adjustedTonnes(blockBBase)
        assertEquals(2.1168, adjustedA, arithmetic)
        assertEquals(3.6, adjustedB, arithmetic)

        // Vineyard totals are sums of per-block figures; no vineyard-wide loss
        // fraction is ever computed.
        assertEquals(5.76, blockABase + blockBBase, arithmetic)
        assertEquals(5.7168, adjustedA + adjustedB, arithmetic)
    }

    // ---- Fixture 8 — mixed-variety block -----------------------------------

    @Test
    fun `fixture 8 - the block loss fraction applies to every planting group`() {
        val block = damage(blockA, blockAAreaHa, listOf(mapped(0.2, 20.0)))
        val multiplier = block.remainingYieldMultiplier

        val shiraz = 1.296      // 60%
        val cabernet = 0.648    // 30%
        val unallocated = 0.216 // 10%

        assertEquals(1.27008, shiraz * multiplier, arithmetic)
        assertEquals(0.63504, cabernet * multiplier, arithmetic)
        assertEquals(0.21168, unallocated * multiplier, arithmetic)

        assertEquals(0.02592, shiraz * block.damageLossFraction, arithmetic)
        assertEquals(0.01296, cabernet * block.damageLossFraction, arithmetic)
        assertEquals(0.00432, unallocated * block.damageLossFraction, arithmetic)

        // The groups still sum to the block total.
        assertEquals(2.1168, (shiraz + cabernet + unallocated) * multiplier, arithmetic)
        assertEquals(blockABase, shiraz + cabernet + unallocated, arithmetic)
    }

    // ---- Geometry (practical tolerance) ------------------------------------

    @Test
    fun `polygon area matches the shared projection`() {
        // A ~200 m × 100 m rectangle near Mudgee, NSW.
        val polygon = listOf(
            point(-32.5, 149.5),
            point(-32.5, 149.502),
            point(-32.501, 149.502),
            point(-32.501, 149.5),
        )

        val mPerDegLat = 111_320.0
        val mPerDegLon = 111_320.0 * cos(-32.5005 * Math.PI / 180.0)
        val expected = (0.002 * mPerDegLon) * (0.001 * mPerDegLat) / 10_000.0

        assertEquals(expected, SeasonYieldDamage.areaHectares(polygon), geometry)
    }

    @Test
    fun `the polygon path matches the arithmetic core`() {
        val polygon = listOf(
            point(-32.5, 149.5),
            point(-32.5, 149.502),
            point(-32.501, 149.502),
            point(-32.501, 149.5),
        )
        val area = SeasonYieldDamage.areaHectares(polygon)

        val viaPolygon = SeasonYieldDamage.blockDamage(
            paddockId = blockA,
            blockAreaHectares = blockAAreaHa,
            records = listOf(record(vintage = 2027, date = "2027-03-01", percent = 20.0, polygon = polygon)),
        )
        val viaArithmetic = damage(blockA, blockAAreaHa, listOf(mapped(area, 20.0)))

        assertEquals(viaArithmetic.damageLossFraction, viaPolygon.damageLossFraction, geometry)
        assertEquals(
            viaArithmetic.adjustedTonnes(blockABase),
            viaPolygon.adjustedTonnes(blockABase),
            geometry,
        )
    }

    // ---- Intensity clamping ------------------------------------------------

    @Test
    fun `intensity is clamped to 0 to 100`() {
        val over = damage(blockA, blockAAreaHa, listOf(mapped(0.2, 150.0)))
        assertEquals(0.2, over.effectiveLossHectares, arithmetic)

        val under = damage(blockA, blockAAreaHa, listOf(mapped(0.2, -20.0)))
        assertEquals(0.0, under.effectiveLossHectares, arithmetic)
    }

    // ---- Fixtures ----------------------------------------------------------

    private fun point(latitude: Double, longitude: Double) =
        CoordinatePoint(latitude = latitude, longitude = longitude)

    private var recordSeq = 0

    private fun record(
        vintage: Int?,
        date: String,
        percent: Double = 20.0,
        polygon: List<CoordinatePoint>? = null,
        vineyard: String = vineyardId,
    ): DamageRecord {
        recordSeq++
        return DamageRecord(
            id = "record-$recordSeq",
            vineyardId = vineyard,
            paddockId = blockA,
            date = date,
            damagePercent = percent,
            polygonPoints = polygon,
            vintage = vintage,
        )
    }
}
