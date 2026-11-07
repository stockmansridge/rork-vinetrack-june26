package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayTank
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Field report (3.2.0 build 1794000010): every Free Drive spray Start failed with
 * the legacy-save MESSAGE. Diagnostics showed the just-written save being set aside
 * with "Unsupported concentration unit in strict chemical codec" — the store wrote
 * chemical label wording (e.g. "%") that its own strict reader then refused.
 */
class LegacySpraySaveChemicalReadbackTest {
    private val trip = "11111111-1111-4111-8111-111111111111"
    private val record = "22222222-2222-4222-8222-222222222222"
    private val actor = "33333333-3333-4333-8333-333333333333"
    private val vineyard = "44444444-4444-4444-8444-444444444444"

    private fun attempt(): LegacySpraySaveStore.Attempt {
        val snapshot = ChemicalLineSnapshot(productName = "Synthetic 500",
            activeIngredients = listOf(ChemicalActiveIngredient(name = "Synthetic active", concentration = 50.0,
                unresolvedConcentrationUnit = "%")))
        val tank = SprayTank(id = "55555555-5555-4555-8555-555555555555", tankNumber = 1, waterVolume = 1000.0,
            chemicals = listOf(SprayChemical(id = "66666666-6666-4666-8666-666666666666", name = "Synthetic 500",
                ratePer100L = 100.0, chemicalSnapshot = snapshot)))
        val input = SprayRecordRepository.SprayInput(
            date = "2026-11-06T00:00:00Z", startTime = "2026-11-06T00:00:00Z",
            temperature = null, windSpeed = null, windDirection = null, humidity = null,
            sprayReference = "Job", notes = null, numberOfFansJets = null, averageSpeed = null,
            equipmentType = null, tractor = null, tractorGear = null, machineId = null,
            sprayEquipmentId = null, operationType = null, tripId = trip, tanks = listOf(tank))
        return LegacySpraySaveStore.Attempt(actorId = actor, identityEpoch = 1,
            trip = LegacySpraySaveStore.TripIntent(trip, vineyard, null, emptyList(), null, null,
                "2026-11-06T00:00:00Z", null, actor, "freeDrive", emptyList(), 1, "2026-11-06T00:00:00Z"),
            recordId = record, input = input, startRequested = true)
    }

    @Test fun aSaveWithPercentConcentrationReadsBackUnchanged() {
        val written = LegacySpraySaveStore.CODEC.encodeToJsonElement(LegacySpraySaveStore.Attempt.serializer(), attempt())
        // The old strict reader refused exactly this (the field failure).
        val strict = Json { encodeDefaults = true; ignoreUnknownKeys = false }
        assertTrue(runCatching { strict.decodeFromJsonElement(LegacySpraySaveStore.Attempt.serializer(), written) }.isFailure)
        val read = LegacySpraySaveStore.decodeLossless(written)
        assertEquals(attempt(), read)
        assertEquals("%", read.input.tanks.single().chemicals.single().chemicalSnapshot!!.activeIngredients.single().unresolvedConcentrationUnit)
    }

    @Test fun aRowThatWouldLoseDataOnRewriteIsStillRefused() {
        val written = LegacySpraySaveStore.CODEC.encodeToJsonElement(LegacySpraySaveStore.Attempt.serializer(), attempt()).jsonObject
        val withOpaqueField = JsonObject(written + ("futurePrivate" to JsonPrimitive("kept")))
        assertTrue(runCatching { LegacySpraySaveStore.decodeLossless(withOpaqueField) }.isFailure)
    }
}
