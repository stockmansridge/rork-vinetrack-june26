package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayApplicationMode
import com.rork.vinetrack.data.spray.SprayApplicationPlan
import com.rork.vinetrack.data.spray.SprayApplicationPlanner
import com.rork.vinetrack.data.spray.SprayApplicationSnapshot
import com.rork.vinetrack.data.spray.SprayBandWidth
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayCarrierVolumeCalculator
import com.rork.vinetrack.data.spray.SprayGeometryResolver
import com.rork.vinetrack.data.spray.SprayGeometrySource
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayTreatedAreaMethod
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Persistence contract for the canonical spray calculation snapshot
 * (sql/191 + sql/192).
 *
 * These tests protect three properties a compliance record must have and that
 * are easy to break silently:
 *
 *  1. **Calculate once.** The persisted values are a projection of ONE
 *     [SprayApplicationPlan], not a second derivation.
 *  2. **Gross and treated both survive.** Treated area never overwrites gross.
 *  3. **A completed record is frozen.** Editing the vineyard afterwards must not
 *     retroactively change what was recorded.
 *
 * The iOS suite `SprayApplicationSnapshotTests` asserts the same fixtures.
 */
class SprayApplicationSnapshotTest {

    private val tolerance = 0.0001
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /**
     * THE worked example from the spec: 10 ha gross, 31,250 m of row,
     * 0.8 m total band -> 2.5 ha treated.
     */
    private fun bandedPlan(
        rowLengthMetres: Double = 31_250.0,
        grossHectares: Double = 10.0,
        rowSpacing: Double = 3.2,
        bandWidth: Double = 0.8,
    ): SprayApplicationPlan {
        val block = SprayBlockInput(
            blockId = "A",
            grossAreaHectares = grossHectares,
            mappedRowLengthMetres = rowLengthMetres,
            rowSpacingMetres = rowSpacing,
        )
        val geometry = SprayGeometryResolver.resolve(listOf(block))
        val carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare = 500.0,
            areaHectares = grossHectares,
            rowLengthMetres = geometry.totalRowLengthMetres,
            rowSpacingMetres = geometry.uniformRowSpacingMetres,
        )
        return SprayApplicationPlanner.plan(
            blocks = listOf(block),
            mode = SprayApplicationMode.BANDED,
            bandWidth = SprayBandWidth.total(bandWidth),
            carrier = carrier,
            tankCapacityLitres = 2_000.0,
            productLines = emptyList(),
        )
    }

    private fun roundTrip(record: SprayRecord): SprayRecord =
        json.decodeFromString(SprayRecord.serializer(), json.encodeToString(SprayRecord.serializer(), record))

    private fun record(
        reference: String,
        geometry: SprayApplicationSnapshot? = null,
        tanks: List<SprayTank>? = null,
    ) = SprayRecord(
        id = "rec-1",
        vineyardId = "vine-1",
        sprayReference = reference,
        tanks = tanks,
        grossAreaHa = geometry?.grossAreaHa,
        treatedAreaHa = geometry?.treatedAreaHa,
        applicationMode = geometry?.applicationMode?.raw,
        treatedAreaMethod = geometry?.treatedAreaMethod?.raw,
        bandWidthTotalMetres = geometry?.bandWidthTotalMetres,
        bandWidthLeftMetres = geometry?.bandWidthLeftMetres,
        bandWidthRightMetres = geometry?.bandWidthRightMetres,
        canonicalRowLengthMetres = geometry?.canonicalRowLengthMetres,
        rowSpacingMetres = geometry?.rowSpacingMetres,
        geometrySource = geometry?.geometrySource?.raw,
        geometryQuality = geometry?.geometryQuality?.raw,
        carrierVolumeBasis = geometry?.carrierVolumeBasis?.raw,
        totalCarrierLitres = geometry?.totalCarrierLitres,
        carrierLitresPerHectare = geometry?.carrierLitresPerHectare,
        diluteLitresPer100m = geometry?.diluteLitresPer100m,
        appliedLitresPer100m = geometry?.appliedLitresPer100m,
        concentrationFactor = geometry?.concentrationFactor,
        // sql/195 block attribution travels with the rest of the snapshot, exactly
        // as the repository writes it. Omitting it here would let a record round
        // trip lose which blocks were treated and still pass.
        applicationBlocks = geometry?.blocks,
    )

    // ------------------------------------------------------- banded persistence

    @Test
    fun `banded spray persists BOTH gross and treated area`() {
        val snapshot = SprayApplicationSnapshot.from(bandedPlan())

        // Gross is NOT overwritten by treated.
        assertEquals(10.0, snapshot.grossAreaHa!!, tolerance)
        // 31,250 m × 0.8 m ÷ 10,000 = 2.5 ha
        assertEquals(2.5, snapshot.treatedAreaHa!!, tolerance)
        assertEquals(31_250.0, snapshot.canonicalRowLengthMetres!!, tolerance)
        assertEquals(0.8, snapshot.bandWidthTotalMetres!!, tolerance)
        assertEquals(SprayApplicationMode.BANDED, snapshot.applicationMode)
        assertEquals(SprayTreatedAreaMethod.CANONICAL_ROW_LENGTH, snapshot.treatedAreaMethod)
        assertEquals(SprayGeometrySource.MAPPED_ROWS, snapshot.geometrySource)
        assertTrue(snapshot.hasGenuineTreatedArea)
    }

    @Test
    fun `banded snapshot survives a full record round trip`() {
        val original = SprayApplicationSnapshot.from(bandedPlan())
        val reloaded = roundTrip(record("Banded pass", original))

        val geometry = reloaded.applicationGeometry!!
        assertEquals(10.0, geometry.grossAreaHa!!, tolerance)
        assertEquals(2.5, geometry.treatedAreaHa!!, tolerance)
        assertEquals(31_250.0, geometry.canonicalRowLengthMetres!!, tolerance)
        assertEquals(SprayApplicationMode.BANDED, geometry.applicationMode)
        assertEquals(SprayTreatedAreaMethod.CANONICAL_ROW_LENGTH, geometry.treatedAreaMethod)
        assertEquals(original, geometry)
    }

    // ----------------------------------- standard L/ha foliar stays unchanged

    @Test
    fun `whole block L per ha foliar records treated equals gross and no L per 100m values`() {
        val block = SprayBlockInput(
            blockId = "A",
            grossAreaHectares = 10.0,
            mappedRowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
        )
        val plan = SprayApplicationPlanner.plan(
            blocks = listOf(block),
            mode = SprayApplicationMode.WHOLE_BLOCK,
            carrier = SprayCarrierVolumeCalculator.perHectare(litresPerHectare = 500.0, areaHectares = 10.0),
            tankCapacityLitres = 2_000.0,
            productLines = emptyList(),
        )
        val snapshot = SprayApplicationSnapshot.from(plan)

        assertEquals(10.0, snapshot.grossAreaHa!!, tolerance)
        // Whole-canopy: the treated area legitimately IS the gross area.
        assertEquals(10.0, snapshot.treatedAreaHa!!, tolerance)
        assertEquals(SprayTreatedAreaMethod.WHOLE_BLOCK, snapshot.treatedAreaMethod)
        assertEquals(SprayCarrierBasis.LITRES_PER_HECTARE, snapshot.carrierVolumeBasis)
        assertEquals(5_000.0, snapshot.totalCarrierLitres!!, tolerance)
        assertEquals(500.0, snapshot.carrierLitresPerHectare!!, tolerance)
        // L/100 m columns belong to the other basis and must stay null.
        assertNull(snapshot.diluteLitresPer100m)
        assertNull(snapshot.appliedLitresPer100m)
        assertNull(snapshot.bandWidthTotalMetres)
    }

    // ------------------------------------- carrier volume (L/100 m) contract

    @Test
    fun `L per 100m carrier snapshot is reproducible without current block geometry`() {
        val block = SprayBlockInput(
            blockId = "A",
            grossAreaHectares = 10.0,
            mappedRowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
        )
        val geometry = SprayGeometryResolver.resolve(listOf(block))
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 8.0,
            diluteLitresPer100Metres = 16.0,
            rowLengthMetres = geometry.totalRowLengthMetres,
            rowSpacingMetres = geometry.uniformRowSpacingMetres,
        )!!
        val plan = SprayApplicationPlanner.plan(
            blocks = listOf(block),
            mode = SprayApplicationMode.WHOLE_BLOCK,
            carrier = carrier,
            tankCapacityLitres = 2_000.0,
            productLines = emptyList(),
        )
        val snapshot = SprayApplicationSnapshot.from(plan)

        // 31,250 m ÷ 100 × 8 L = 2,500 L actually applied.
        assertEquals(2_500.0, snapshot.totalCarrierLitres!!, tolerance)
        assertEquals(8.0, snapshot.appliedLitresPer100m!!, tolerance)
        assertEquals(16.0, snapshot.diluteLitresPer100m!!, tolerance)
        // 16 ÷ 8 = 2× concentrate.
        assertEquals(2.0, snapshot.concentrationFactor!!, tolerance)
        // 8 × 100 ÷ 3.2 = 250 L/ha derived.
        assertEquals(250.0, snapshot.carrierLitresPerHectare!!, tolerance)
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, snapshot.carrierVolumeBasis)
        // Row spacing is snapshotted so the derived L/ha stays explainable even
        // after the block's spacing is later edited.
        assertEquals(3.2, snapshot.rowSpacingMetres!!, tolerance)
        assertEquals(31_250.0, snapshot.canonicalRowLengthMetres!!, tolerance)
    }

    // ------------------------- snapshot immunity to later vineyard changes

    @Test
    fun `completed record is unchanged when block geometry is edited afterwards`() {
        // Spray is calculated and completed against today's geometry.
        val stored = roundTrip(record("Completed", SprayApplicationSnapshot.from(bandedPlan())))

        // The grower now corrects the block: an operator override roughly halves
        // the row length. Recalculating TODAY would give a different answer.
        val editedBlock = SprayBlockInput(
            blockId = "A",
            grossAreaHectares = 10.0,
            mappedRowLengthMetres = 31_250.0,
            operatorRowLengthOverrideMetres = 15_000.0,
            rowSpacingMetres = 3.2,
        )
        val recalculated = SprayGeometryResolver.resolve(listOf(editedBlock))
        assertEquals(15_000.0, recalculated.totalRowLengthMetres!!, tolerance)

        // The historical record must NOT move.
        val geometry = stored.applicationGeometry!!
        assertEquals(31_250.0, geometry.canonicalRowLengthMetres!!, tolerance)
        assertEquals(2.5, geometry.treatedAreaHa!!, tolerance)
        assertEquals(SprayGeometrySource.MAPPED_ROWS, geometry.geometrySource)
    }

    // --------------------------- legacy records: no backfill, no invention

    @Test
    fun `a pre sql 191 record decodes with a null snapshot not a guessed one`() {
        // Exactly what every historical row looks like: the columns are absent.
        val legacyJson = """
            {"id":"rec-legacy","vineyard_id":"vine-1","tanks":[]}
        """.trimIndent()
        val decoded = json.decodeFromString(SprayRecord.serializer(), legacyJson)
        assertNull(decoded.applicationGeometry)
        assertNull(decoded.grossAreaHa)
        assertNull(decoded.treatedAreaHa)
    }

    @Test
    fun `an all null snapshot normalises to null so absence has one representation`() {
        assertTrue(SprayApplicationSnapshot().isEmpty)
        // A record whose columns are all null must read back as "not recorded",
        // not as an object of nulls that looks recorded.
        assertNull(roundTrip(record("Empty geometry", SprayApplicationSnapshot())).applicationGeometry)
    }

    @Test
    fun `a banded job with no band width records gross but refuses to invent treated`() {
        val block = SprayBlockInput(
            blockId = "A",
            grossAreaHectares = 10.0,
            mappedRowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
        )
        val plan = SprayApplicationPlanner.plan(
            blocks = listOf(block),
            mode = SprayApplicationMode.BANDED,
            bandWidth = null,
            carrier = SprayCarrierVolumeCalculator.perHectare(litresPerHectare = 500.0, areaHectares = 10.0),
            tankCapacityLitres = 2_000.0,
            productLines = emptyList(),
        )
        val snapshot = SprayApplicationSnapshot.from(plan)

        assertEquals(10.0, snapshot.grossAreaHa!!, tolerance)
        // Never falls back to gross for a banded job — that would overstate the
        // treated area fourfold in this fixture.
        assertNull(snapshot.treatedAreaHa)
        assertEquals(SprayTreatedAreaMethod.UNAVAILABLE, snapshot.treatedAreaMethod)
        assertFalse(snapshot.hasGenuineTreatedArea)
    }

    @Test
    fun `zero valued measurements persist as null honouring the sql 191 positivity checks`() {
        val block = SprayBlockInput(blockId = "A", grossAreaHectares = 0.0, rowSpacingMetres = 3.2)
        val plan = SprayApplicationPlanner.plan(
            blocks = listOf(block),
            mode = SprayApplicationMode.WHOLE_BLOCK,
            carrier = SprayCarrierVolumeCalculator.perHectare(litresPerHectare = 0.0, areaHectares = 0.0),
            tankCapacityLitres = 2_000.0,
            productLines = emptyList(),
        )
        val snapshot = SprayApplicationSnapshot.from(plan)

        // A row length of 0 is not a measurement; it must be NULL so it can
        // never silently dose a tank.
        assertNull(snapshot.canonicalRowLengthMetres)
        assertNull(snapshot.bandWidthTotalMetres)
        // Non-negative columns may legitimately be 0.
        assertEquals(0.0, snapshot.grossAreaHa!!, tolerance)
        assertEquals(0.0, snapshot.totalCarrierLitres!!, tolerance)
    }

    // ------------------ templates: configuration intent, not historical output

    @Test
    fun `template keeps configuration and drops geometry dependent totals`() {
        val template = SprayApplicationSnapshot.from(bandedPlan()).templateConfiguration()!!

        // KEPT — reusable operator intent.
        assertEquals(SprayApplicationMode.BANDED, template.applicationMode)
        assertEquals(0.8, template.bandWidthTotalMetres!!, tolerance)
        assertEquals(SprayCarrierBasis.LITRES_PER_HECTARE, template.carrierVolumeBasis)
        // L/ha mode: the per-hectare figure is what the operator typed.
        assertEquals(500.0, template.carrierLitresPerHectare!!, tolerance)

        // CLEARED — recalculated against whatever blocks the next spray selects.
        assertNull(template.grossAreaHa)
        assertNull(template.treatedAreaHa)
        assertNull(template.canonicalRowLengthMetres)
        assertNull(template.rowSpacingMetres)
        assertNull(template.geometrySource)
        assertNull(template.geometryQuality)
        assertNull(template.totalCarrierLitres)
        assertNull(template.treatedAreaMethod)
    }

    @Test
    fun `template in L per 100m mode drops the derived L per ha but keeps entered rates`() {
        val block = SprayBlockInput(
            blockId = "A",
            grossAreaHectares = 10.0,
            mappedRowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
        )
        val geometry = SprayGeometryResolver.resolve(listOf(block))
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 8.0,
            diluteLitresPer100Metres = 16.0,
            rowLengthMetres = geometry.totalRowLengthMetres,
            rowSpacingMetres = geometry.uniformRowSpacingMetres,
        )!!
        val plan = SprayApplicationPlanner.plan(
            blocks = listOf(block),
            mode = SprayApplicationMode.WHOLE_BLOCK,
            carrier = carrier,
            tankCapacityLitres = 2_000.0,
            productLines = emptyList(),
        )
        val template = SprayApplicationSnapshot.from(plan).templateConfiguration()!!

        // Entered rates are intent and are reused.
        assertEquals(8.0, template.appliedLitresPer100m!!, tolerance)
        assertEquals(16.0, template.diluteLitresPer100m!!, tolerance)
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, template.carrierVolumeBasis)
        // In this mode L/ha was DERIVED from row spacing, so it is an output.
        assertNull(template.carrierLitresPerHectare)
        assertNull(template.rowSpacingMetres)
    }

    @Test
    fun `template inputs plus current geometry produce a fresh calculation snapshot`() {
        // Save a template from a 31,250 m season.
        val template = SprayApplicationSnapshot.from(bandedPlan()).templateConfiguration()!!

        // Next season the blocks are resurveyed shorter. Reusing the template's
        // CONFIG against CURRENT geometry must produce the new answer, not the
        // frozen one.
        val resurveyed = bandedPlan(
            rowLengthMetres = 20_000.0,
            grossHectares = 6.4,
            bandWidth = template.bandWidthTotalMetres!!,
        )
        val fresh = SprayApplicationSnapshot.from(resurveyed)

        // Configuration carried across unchanged.
        assertEquals(template.bandWidthTotalMetres!!, fresh.bandWidthTotalMetres!!, tolerance)
        assertEquals(template.applicationMode, fresh.applicationMode)
        // Geometry-dependent outputs are new: 20,000 × 0.8 ÷ 10,000 = 1.6 ha.
        assertEquals(20_000.0, fresh.canonicalRowLengthMetres!!, tolerance)
        assertEquals(1.6, fresh.treatedAreaHa!!, tolerance)
        assertEquals(6.4, fresh.grossAreaHa!!, tolerance)
    }

    // ------------------------------------------- offline outbox round trip

    @Test
    fun `snapshot survives the offline outbox payload round trip`() {
        // A spray created OFFLINE is queued as JSON and replayed later; the
        // geometry must not be lost in the queue.
        val original = SprayApplicationSnapshot.from(bandedPlan())
        val encoded = json.encodeToString(SprayApplicationSnapshot.serializer(), original)
        val decoded = json.decodeFromString(SprayApplicationSnapshot.serializer(), encoded)

        assertEquals(original, decoded)
        assertEquals(2.5, decoded.treatedAreaHa!!, tolerance)
        assertEquals(31_250.0, decoded.canonicalRowLengthMetres!!, tolerance)
        // Enums must serialise to their wire spellings so outbox JSON and the
        // database columns agree.
        assertTrue(encoded.contains("\"banded\""))
        assertTrue(encoded.contains("\"mapped_rows\""))
        assertTrue(encoded.contains("\"canonical_row_length\""))
    }

    @Test
    fun `deprecated stored_row_length geometry source still decodes from storage`() {
        val storedJson = """
            {"id":"rec-old","vineyard_id":"vine-1","tanks":[],
             "canonical_row_length_metres":12345,"geometry_source":"stored_row_length"}
        """.trimIndent()
        val decoded = json.decodeFromString(SprayRecord.serializer(), storedJson)
        val geometry = decoded.applicationGeometry!!

        assertEquals(SprayGeometrySource.STORED_ROW_LENGTH, geometry.geometrySource)
        assertEquals(12_345.0, geometry.canonicalRowLengthMetres!!, tolerance)
    }

    // --------------------- per-product rate basis (persisted per chemical line)

    @Test
    fun `one tank preserves a different rate basis on every chemical line`() {
        // The spec's mixed-basis tank: these three lines must stay individually
        // explainable, so the basis lives on the LINE, not on the job.
        val tank = SprayTank(
            id = "tank-1",
            tankNumber = 1,
            waterVolume = 6_250.0,
            sprayRatePerHa = 500.0,
            concentrationFactor = 1.0,
            chemicals = listOf(
                SprayChemical(id = "c1", name = "Kelp", ratePerHa = 2.0, rateBasis = "whole_block_area"),
                SprayChemical(id = "c2", name = "Herbicide", ratePerHa = 2.0, rateBasis = "treated_area"),
                SprayChemical(id = "c3", name = "Adjuvant", ratePer100L = 100.0, unit = "mL", rateBasis = "per_100_litres"),
            ),
        )
        val reloaded = roundTrip(record("Mixed", tanks = listOf(tank)))

        val chemicals = reloaded.tanks!!.first().chemicals
        assertEquals(3, chemicals.size)
        assertEquals(SprayProductRateBasis.WHOLE_BLOCK_AREA, chemicals[0].resolvedRateBasis)
        assertEquals(SprayProductRateBasis.TREATED_AREA, chemicals[1].resolvedRateBasis)
        assertEquals(SprayProductRateBasis.PER_100_LITRES, chemicals[2].resolvedRateBasis)
        // Each line keeps its own raw value, so a treated-area herbicide can
        // never be silently recomputed against gross hectares.
        assertEquals("treated_area", chemicals[1].rateBasis)
    }

    @Test
    fun `a legacy chemical line resolves to whole block area never treated area`() {
        val legacy = SprayChemical(id = "c1", name = "Old product", ratePerHa = 2.0)
        assertNull(legacy.rateBasis)
        // Reading it as treated area would silently under-dose it, because every
        // historical record multiplied the rate by GROSS hectares.
        assertEquals(SprayProductRateBasis.WHOLE_BLOCK_AREA, legacy.resolvedRateBasis)

        // A legacy stored spelling maps deterministically too.
        val imported = SprayChemical(id = "c2", name = "Imported", rateBasis = "per_hectare")
        assertEquals(SprayProductRateBasis.WHOLE_BLOCK_AREA, imported.resolvedRateBasis)
    }

    @Test
    fun `mixed bases produce the spec quantities from one shared snapshot`() {
        // Kelp      2 L/block ha   × 10 ha    = 20 L
        // Herbicide 2 L/treated ha × 2.5 ha   =  5 L
        // Adjuvant  100 mL/100 L   × 6,250 L  =  6.25 L (dilute-equivalent)
        val snapshot = SprayApplicationSnapshot.from(bandedPlan())
        assertNotNull(snapshot.grossAreaHa)
        assertNotNull(snapshot.treatedAreaHa)

        val kelp = 2.0 * snapshot.grossAreaHa!!
        val herbicide = 2.0 * snapshot.treatedAreaHa!!

        assertEquals(20.0, kelp, tolerance)
        assertEquals(5.0, herbicide, tolerance)
        // The two areas are genuinely different numbers on the SAME record,
        // which is the whole point of retaining both.
        assertTrue(snapshot.grossAreaHa!! > snapshot.treatedAreaHa!!)
    }
}
