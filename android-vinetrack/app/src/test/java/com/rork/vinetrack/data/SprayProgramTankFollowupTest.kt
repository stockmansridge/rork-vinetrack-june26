package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class SprayProgramTankFollowupTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    @Test fun programCachePreservesCanonicalInputsWithoutConfirmingTodaysCanopy() {
        val inputs = SprayProgramCalculatorInputs("Large", "High", "l_per_100m", 20.02, 16.8)
        val record = SprayRecord(id = "program", vineyardId = "vineyard", isTemplate = true,
            sprayEquipmentId = "equipment", tractorId = "tractor", targets = listOf("botrytis"),
            tanks = listOf(SprayTank(id = "tank", tankNumber = 1, waterVolume = 750.0, sprayRatePerHa = 600.0,
                chemicals = listOf(SprayChemical(id = "line", name = "Product", ratePer100L = 125.0, unit = "g")))),
            programCalculatorInputs = inputs, templateGrowthStageCode = "EL12")
        val restored = SprayProgramTemplateCache.decode(SprayProgramTemplateCache.encode(listOf(record))).single()
        assertEquals(inputs, restored.programCalculatorInputs)
        assertEquals("EL12", restored.templateGrowthStageCode)
        assertEquals(SprayCalculator.CanopySize.LARGE, restored.prefillCanopy?.size)
        assertEquals(SprayCalculator.CanopyDensity.HIGH, restored.prefillCanopy?.density)
        assertFalse(restored.prefillCanopy!!.isConfirmed)
        assertEquals(record.tanks, restored.tanks)
        assertEquals(record.sprayEquipmentId, restored.sprayEquipmentId)
        assertEquals(record.tractorId, restored.tractorId)
        val encodedRecord = json.encodeToString(restored)
        assertFalse(encodedRecord.contains("programCalculatorInputs"))
        assertNull(SprayProgramCalculatorInputs().canopy)
        assertNull(SprayProgramTemplateCache.decode("[$encodedRecord]").single().programCalculatorInputs)
        for (fmt in listOf(RegionFormatter(), RegionFormatter(RegionCountry.UnitedStates.recommendedPreset))) {
            assertEquals(16.8, fmt.volumePer100LengthToCanonical(fmt.volumePer100LengthValue(16.8)), 1e-9)
            assertEquals(600.0, fmt.volumePerAreaToCanonical(fmt.volumePerAreaValue(600.0)), 1e-9)
        }
    }

    @Test fun programDiluteIsAnInputToExistingDecisionNotAnotherEngine() {
        val canopy = SprayProgramCalculatorInputs("Large", "High").canopy!!
        val unreviewed = SprayVolumeDecisionResolver.decide(canopy, false, CanopyWaterRates.defaults, 2.8,
            SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE, 600.0, SprayCarrierBasis.LITRES_PER_HECTARE, 20.02)
        assertNull(unreviewed.recommendation)
        val decision = SprayVolumeDecisionResolver.decide(canopy.confirm(), true, CanopyWaterRates.defaults, 2.8,
            SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE, 600.0, SprayCarrierBasis.LITRES_PER_HECTARE, 20.02)
        assertEquals(715.0, decision.recommendedLitresPerHectare!!, 1e-9)
        assertEquals(715.0 / 600, decision.concentrationFactor, 1e-9)
    }

    @Test fun completionUsesTrueActiveIdentityAndReplayKeepsEvidence() {
        var trip = Trip(id = "trip", vineyardId = "vineyard", paddockName = "Synthetic", isActive = true,
            startTime = "2026-10-14T00:00:00Z", rowSequence = listOf(1.5, 2.5), totalTanks = 2)
        val first = TankSessionLifecycle.startResult(trip, "2026-10-14T00:01:00Z", 1.5, listOf(1, 2))!!
        trip = TankPathAttribution.recordCompletion(first.trip, 1.5)
        trip = TankPathAttribution.recordCompletion(trip, 1.5)
        trip = TankSessionLifecycle.end(trip, "2026-10-14T00:02:00Z", 2.5)
        val second = TankSessionLifecycle.startResult(trip, "2026-10-14T00:03:00Z", 2.5, listOf(1, 2))!!
        trip = TankPathAttribution.recordCompletion(second.trip, 2.5)
        val restored = json.decodeFromString<Trip>(json.encodeToString(trip))
        assertEquals(listOf(first.tankSessionId, second.tankSessionId), restored.tankSessions.map { it.id })
        assertEquals(listOf(1, 2), restored.tankSessions.map { it.tankNumber })
        assertEquals(listOf(listOf(1.5), listOf(2.5)), restored.tankSessions.map { it.pathsCovered })
        val stale = restored.copy(tankSessions = restored.tankSessions.map { it.copy(pathsCovered = emptyList()) })
        assertEquals(restored.tankSessions, TankSessionReplayMerge.merge(restored, stale)!!.sessions)
        val repeated = stale.copy(rowSequence = listOf(2.5, 2.5))
        assertEquals(repeated, TankPathAttribution.recordCompletion(repeated, 2.5))
        val duplicate = stale.copy(tankSessions = stale.tankSessions + stale.tankSessions.last().copy(id = "other"))
        assertNull(TankPathAttribution.activeSession(duplicate))
    }

    @Test fun historicalCaseShapesNeverCreatePlannedTankTwoOrHistoricLinks() {
        // Owner-described structural reproductions, not the original private production rows.
        for ((day, count) in listOf("2026-10-14" to 2, "2026-09-04" to 1, "2026-09-23" to 1)) {
            val trip = Trip(id = day, vineyardId = "vineyard", paddockName = "History", isActive = false,
                startTime = "${day}T00:00:00Z", endTime = "${day}T01:00:00Z", totalTanks = 2,
                rowSequence = listOf(1.5, 2.5), tankSessions = (1..count).map {
                    TankSession("$day-$it", it, "${day}T00:00:00Z", "${day}T00:30:00Z", startRow = 1.5, endRow = 2.5)
                })
            val actuals = trip.tankSessions.map { SprayTankActual(id = "actual-${it.id}", vineyardId = "vineyard",
                tripId = trip.id, sprayRecordId = "spray", tankSessionId = it.id, tankNumber = it.tankNumber,
                waterVolumeL = 750.0, chemicals = emptyList(), confirmedAt = "${day}T00:00:00Z", confirmedBy = "operator") }
            val bytes = json.encodeToString(trip)
            val restored = json.decodeFromString<Trip>(bytes)
            assertEquals(bytes, json.encodeToString(TankPathAttribution.recordCompletion(restored, 1.5)))
            assertEquals(count, restored.tankSessions.size)
            assertEquals(actuals.map { it.tankSessionId }, restored.tankSessions.map { it.id })
            assertEquals(actuals.map { it.tankNumber }, restored.tankSessions.map { it.tankNumber })
            assertTrue(restored.tankSessions.all { it.pathsCovered.isEmpty() })
            val planned = SprayRecord(id = "spray", vineyardId = "vineyard", tanks = listOf(
                SprayTank("planned1", tankNumber = 1, waterVolume = 750.0), SprayTank("planned2", tankNumber = 2, waterVolume = 750.0)))
            val report = com.rork.vinetrack.data.reporting.SprayReportPayloadV1.offlineProjection(restored, planned,
                "Synthetic", "UTC", emptyList(), emptyList(), emptyList(), actuals, 0)
            assertTrue(report.rows.all { it.tank == kotlinx.serialization.json.JsonNull })
        }
    }
}
