package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalManualDraft
import com.rork.vinetrack.data.chemical.ChemicalManualEntry
import com.rork.vinetrack.data.chemical.ChemicalManualRateConfirmation
import com.rork.vinetrack.data.chemical.ChemicalManualRateDraft
import com.rork.vinetrack.data.chemical.ChemicalManualUseDraft
import com.rork.vinetrack.data.chemical.ChemicalSnapshotCapture
import com.rork.vinetrack.data.chemical.ChemicalSprayDefaultHandoff
import com.rork.vinetrack.data.chemical.ChemicalSprayRateResolution
import com.rork.vinetrack.data.chemical.SprayConfirmedRateSeeding
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRate
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRates
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayApplicationMode
import com.rork.vinetrack.data.spray.SprayApplicationPlanner
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCarrierVolumeCalculator
import com.rork.vinetrack.data.spray.SprayGuidedTankBuilder
import com.rork.vinetrack.data.spray.SprayProductLineInput
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The manual-rate contract exercised through the PRODUCTION code path:
 *
 * ```text
 * manual entry (ChemicalManualEntry draft → proposedIntelligence)
 *   → confirm (ChemicalManualRateConfirmation — the Rates section's button)
 *   → Save Chemical (registered_uses + default_rates on the row)
 *   → reload Chemical Store (JSON round trip through the shared client config)
 *   → select in Spray Program (SprayConfirmedRateSeeding.seedFor / rangeFor)
 *   → choose an application rate inside the range (gatedRate / rejection)
 *   → plan + save spray (SprayApplicationPlanner + SprayGuidedTankBuilder with
 *       SprayConfirmedRateSeeding.snapshotWithProvenance)
 *   → reload spray (SprayTank JSON round trip)
 * ```
 *
 * Mirrors iOS `ChemicalManualRateProductionPathTests`.
 */
class ChemicalManualRateProductionPathTest {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
    }

    private fun manualDraft(rate: ChemicalManualRateDraft): ChemicalManualDraft =
        ChemicalManualEntry.draft(null, "AU").copy(
            productName = "Stifle",
            uses = listOf(ChemicalManualUseDraft(crop = "Grapes", targetRaw = "Powdery mildew", rates = listOf(rate))),
        )

    /** What the Chemical Store save writes: the intelligence and the confirmed default. */
    private fun saveChemical(draft: ChemicalManualDraft, defaults: StoredChemicalDefaultRates?): SavedChemical {
        val intelligence = ChemicalManualEntry.proposedIntelligence(draft, null)
        return SavedChemical(
            id = "chem-1",
            vineyardId = "vy-1",
            name = "Stifle",
            unit = "Litres",
            activeIngredients = intelligence.activeIngredients,
            registeredUses = intelligence.registeredUses,
            defaultRates = defaults,
        )
    }

    private fun reload(chemical: SavedChemical): SavedChemical =
        json.decodeFromString(SavedChemical.serializer(), json.encodeToString(SavedChemical.serializer(), chemical))

    /** The production planner over one 1 ha block at 1000 L/ha. */
    private fun plan(chemical: SavedChemical, rate: Double, unit: String, basis: SprayProductRateBasis) =
        SprayApplicationPlanner.plan(
            blocks = listOf(SprayBlockInput(blockId = "b1", grossAreaHectares = 1.0)),
            mode = SprayApplicationMode.WHOLE_BLOCK,
            carrier = SprayCarrierVolumeCalculator.perHectare(litresPerHectare = 1000.0, areaHectares = 1.0),
            tankCapacityLitres = 1000.0,
            productLines = listOf(
                SprayProductLineInput(
                    productId = chemical.id,
                    name = chemical.name,
                    unit = unit,
                    basis = basis,
                    rate = rate,
                ),
            ),
        )

    /** EXACTLY what `buildInput()` does for one line, then the `tanks` JSONB round trip. */
    private fun saveAndReloadSpray(
        chemical: SavedChemical,
        appliedRate: Double,
        unit: String,
        basis: SprayProductRateBasis,
        isOverride: Boolean,
    ): SprayTank {
        val captured = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = chemical.id,
            productName = null,
            library = listOf(chemical),
            capturedAt = "2026-09-03T00:00:00Z",
        ).snapshot
        val snapshot = SprayConfirmedRateSeeding.snapshotWithProvenance(
            base = captured,
            chemical = chemical,
            basis = basis,
            appliedRate = appliedRate,
            unit = unit,
            isOverride = isOverride,
            capturedAt = "2026-09-03T00:00:00Z",
        )
        val tanks = SprayGuidedTankBuilder.build(
            plan = plan(chemical, appliedRate, unit, basis),
            chosenSprayRate = 1000.0,
            snapshots = mapOf(chemical.id to snapshot!!),
        )
        val encoded = json.encodeToString(SprayTank.serializer(), tanks.first())
        return json.decodeFromString(SprayTank.serializer(), encoded)
    }

    // ---- Range: 2–3 L/100 L, sprayed at 2.5 -------------------------------

    @Test
    fun manualRangeReachesDefaultRatesThenSprayAtTwoPointFive() {
        // 1. Manual entry.
        val draft = manualDraft(
            ChemicalManualRateDraft(basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES, minText = "2", maxText = "3", unit = "L"),
        )
        val intelligence = ChemicalManualEntry.proposedIntelligence(draft, null)
        val candidates = ChemicalManualRateConfirmation.candidates(intelligence)
        assertEquals(1, candidates.size)
        val candidate = candidates.single()
        assertTrue(candidate.isRange)
        assertEquals("2–3 L/100 L", candidate.display)

        // 2. Confirm — the Rates section's button.
        val defaults = ChemicalManualRateConfirmation.confirm(null, candidate)
        assertTrue(ChemicalManualRateConfirmation.isConfirmed(defaults, candidate))

        // 3. Save Chemical → reload Chemical Store.
        val saved = saveChemical(draft, defaults)
        val slot = saved.defaultRates!!.per100Litres!!
        assertEquals("", slot.optionKey)
        assertTrue(slot.rateIds.isEmpty())
        assertEquals("per_100_litres", slot.basis)
        assertEquals("L", slot.unit)
        assertNull(slot.value)
        assertEquals(2.0, slot.minValue!!, 0.0)
        assertEquals(3.0, slot.maxValue!!, 0.0)
        assertEquals("operator", slot.source)
        assertEquals("manual", slot.entryMethod)
        assertNotNull(slot.selectedAt)
        assertNull(saved.defaultRates!!.perHectare)

        val encoded = json.encodeToString(StoredChemicalDefaultRates.serializer(), saved.defaultRates!!)
        assertTrue(encoded, encoded.contains("\"entry_method\":\"manual\""))
        for (fake in listOf("default_option_v1_", "rate_v1_", "manual_rate", "user_rate", "custom")) {
            assertFalse("must not mint $fake", encoded.contains(fake))
        }

        val reloaded = reload(saved)
        assertEquals(saved.defaultRates, reloaded.defaultRates)
        // Reopen: the same candidate reads as confirmed, and re-confirming
        // rewrites the identical slot.
        val reopenedCandidates = ChemicalManualRateConfirmation.candidates(reloaded.storedIntelligence)
        assertTrue(ChemicalManualRateConfirmation.isConfirmed(reloaded.defaultRates, reopenedCandidates.single()))
        assertEquals(
            reloaded.defaultRates,
            ChemicalManualRateConfirmation.confirm(reloaded.defaultRates, reopenedCandidates.single()),
        )
        assertEquals(listOf("2–3 L/100 L (user-confirmed)"), ChemicalManualRateConfirmation.confirmedDisplays(reloaded.defaultRates))

        // 5. Select in Spray Program.
        val seed = SprayConfirmedRateSeeding.seedFor(reloaded)!!
        assertEquals(SprayCalculator.RateBasis.PER_100L, seed.basis)
        assertEquals("L", seed.rateUnit)
        assertNull("no endpoint or midpoint is pre-selected", seed.rateAmount)
        val range = SprayConfirmedRateSeeding.rangeFor(reloaded, seed.basis)!!
        assertEquals(2.0, range.min, 0.0)
        assertEquals(3.0, range.max, 0.0)
        assertTrue(range.isUserEntered)
        assertTrue(ChemicalSprayDefaultHandoff.isSprayReady(reloaded.defaultRates))
        assertTrue(ChemicalSprayDefaultHandoff.resolutionFor(reloaded.defaultRates) is ChemicalSprayRateResolution.RequiresSelection)

        // 6. Application-rate field: the gate the card applies.
        assertNull(SprayConfirmedRateSeeding.gatedRate(range, ""))
        assertNull(SprayConfirmedRateSeeding.gatedRate(range, "1.5"))
        assertNull(SprayConfirmedRateSeeding.gatedRate(range, "3.5"))
        assertNotNull(SprayConfirmedRateSeeding.rejection(range, "3.5"))
        assertNull(SprayConfirmedRateSeeding.rejection(range, "2.5"))
        assertEquals(2.5, SprayConfirmedRateSeeding.gatedRate(range, "2.5")!!, 0.0)
        // What the screen hands the production planner while no in-range dose
        // exists: an unresolved line, which the guided flow refuses to save.
        val gated = SprayConfirmedRateSeeding.plannerRate(range, "3.5")
        assertTrue(plan(reloaded, gated, "L", SprayProductRateBasis.PER_100_LITRES).productLines.single().isUnresolved)
        assertEquals(2.5, SprayConfirmedRateSeeding.plannerRate(range, "2.5"), 0.0)

        // 7. Save spray → reload spray.
        val tank = saveAndReloadSpray(reloaded, 2.5, "L", SprayProductRateBasis.PER_100_LITRES, isOverride = true)
        val snapshot = tank.chemicals.single().chemicalSnapshot!!
        assertEquals(2.5, snapshot.appliedRate!!, 0.0)
        assertEquals("L", snapshot.appliedRateUnit)
        assertEquals("per_100_litres", snapshot.appliedRateBasis)
        assertEquals("manual", snapshot.rateEntryMethod)
        assertTrue(snapshot.isUserEnteredRate)
        assertEquals(2.0, snapshot.rateRangeMin!!, 0.0)
        assertEquals(3.0, snapshot.rateRangeMax!!, 0.0)
        assertEquals(reloaded.id, snapshot.savedChemicalId)

        // The Chemical Store's band is untouched by the spray.
        assertEquals(2.0, reloaded.defaultRates!!.per100Litres!!.minValue!!, 0.0)
        assertEquals(3.0, reloaded.defaultRates!!.per100Litres!!.maxValue!!, 0.0)
        assertNull(reloaded.defaultRates!!.per100Litres!!.value)
    }

    // ---- Scalar: 2 L/100 L populates the line -----------------------------

    @Test
    fun manualScalarPopulatesTheSprayLineAndRecordsProvenance() {
        val draft = manualDraft(
            ChemicalManualRateDraft(basis = ChemicalLabelRateBasis.PER_100_LITRES, valueText = "2", unit = "L"),
        )
        val candidate = ChemicalManualRateConfirmation.candidates(ChemicalManualEntry.proposedIntelligence(draft, null)).single()
        assertFalse(candidate.isRange)
        val saved = saveChemical(draft, ChemicalManualRateConfirmation.confirm(null, candidate))
        val slot = saved.defaultRates!!.per100Litres!!
        assertEquals(2.0, slot.value!!, 0.0)
        assertNull(slot.minValue)
        assertNull(slot.maxValue)
        assertEquals("manual", slot.entryMethod)
        assertEquals("", slot.optionKey)

        val reloaded = reload(saved)
        val seed = SprayConfirmedRateSeeding.seedFor(reloaded)!!
        assertEquals(SprayCalculator.RateBasis.PER_100L, seed.basis)
        assertEquals(2.0, seed.rateAmount!!, 0.0)
        assertEquals("L", seed.rateUnit)
        assertNull(seed.range)
        assertTrue(SprayConfirmedRateSeeding.prefillFor(reloaded, seed.basis)!!.isUserEntered)

        val tank = saveAndReloadSpray(reloaded, 2.0, "L", SprayProductRateBasis.PER_100_LITRES, isOverride = false)
        val snapshot = tank.chemicals.single().chemicalSnapshot!!
        assertEquals(2.0, snapshot.appliedRate!!, 0.0)
        assertEquals("L", snapshot.appliedRateUnit)
        assertEquals("per_100_litres", snapshot.appliedRateBasis)
        assertEquals("manual", snapshot.rateEntryMethod)
        assertNull(snapshot.rateRangeMin)
        assertNull(snapshot.rateRangeMax)
    }

    // ---- Canonical behaviour unchanged --------------------------------------

    @Test
    fun aRateWithAServerRateIdIsNeverOfferedAsManual() {
        val draft = manualDraft(
            ChemicalManualRateDraft(basis = ChemicalLabelRateBasis.PER_100_LITRES, valueText = "2", unit = "L"),
        )
        val intelligence = ChemicalManualEntry.proposedIntelligence(draft, null)
        val lookedUp = intelligence.copy(
            registeredUses = intelligence.registeredUses.map { use ->
                use.copy(rates = use.rates.map { it.copy(rateId = "rate_v1_abc") })
            },
        )
        assertTrue(ChemicalManualRateConfirmation.candidates(lookedUp).isEmpty())
    }

    @Test
    fun canonicalScalarSprayRecordsCanonicalProvenance() {
        val canonical = StoredChemicalDefaultRate(
            optionKey = "default_option_v1_abc",
            rateIds = listOf("rate_v1_a"),
            basis = "per_100_litres",
            unit = "L",
            value = 2.0,
            source = StoredChemicalDefaultRate.SOURCE_OPERATOR,
        )
        val chemical = SavedChemical(
            id = "chem-2",
            vineyardId = "vy-1",
            name = "Official",
            unit = "Litres",
            defaultRates = StoredChemicalDefaultRates(
                version = StoredChemicalDefaultRates.DEFAULT_RATES_VERSION,
                per100Litres = canonical,
            ),
        )
        val seed = SprayConfirmedRateSeeding.seedFor(chemical)!!
        assertEquals(2.0, seed.rateAmount!!, 0.0)
        assertFalse(SprayConfirmedRateSeeding.prefillFor(chemical, seed.basis)!!.isUserEntered)
        val tank = saveAndReloadSpray(chemical, 2.0, "L", SprayProductRateBasis.PER_100_LITRES, isOverride = false)
        val snapshot = tank.chemicals.single().chemicalSnapshot!!
        assertEquals("canonical", snapshot.rateEntryMethod)
        assertFalse(snapshot.isUserEnteredRate)
    }
}
