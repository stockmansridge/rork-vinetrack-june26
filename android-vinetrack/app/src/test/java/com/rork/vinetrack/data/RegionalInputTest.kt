package com.rork.vinetrack.data

import org.junit.Assert.*
import org.junit.Test

class RegionalInputTest {
    @Test fun auAndUsValveAndPresetValuesRemainCanonical() {
        for (settings in listOf(RegionCountry.Australia.recommendedPreset, RegionCountry.UnitedStates.recommendedPreset)) {
            val fmt = RegionFormatter(settings)
            val flow = RegionalInput.seed(1500.123456789, fmt::volumeValue)
            assertEquals(1500.123456789, flow.resolve(flow.text, fmt::volumeToCanonical)!!, 0.0)
            assertEquals(2000.0, flow.resolve(fmt.volumeValue(2000.0).toString(), fmt::volumeToCanonical)!!, 1e-9)
            val rate = RegionalInput.seed(750.123456789, fmt::volumePerAreaValue)
            assertEquals(750.123456789, rate.resolve(rate.text, fmt::volumePerAreaToCanonical)!!, 0.0)
            assertEquals(500.0, rate.resolve(fmt.volumePerAreaValue(500.0).toString(), fmt::volumePerAreaToCanonical)!!, 1e-9)
        }
    }

    @Test fun soilCompoundUnitsAndRootZoneCapacityRoundTrip() {
        for (settings in listOf(RegionCountry.Australia.recommendedPreset, RegionCountry.UnitedStates.recommendedPreset)) {
            val fmt = RegionFormatter(settings)
            val awc = RegionalInput.seed(150.123456, fmt::soilWaterCapacityValue)
            val depth = RegionalInput.seed(0.654321, fmt::lengthValue)
            assertEquals(150.123456, awc.resolve(awc.text, fmt::soilWaterCapacityToCanonical)!!, 0.0)
            assertEquals(0.654321, depth.resolve(depth.text, fmt::lengthToCanonical)!!, 0.0)
            val editedAwc = awc.resolve(fmt.soilWaterCapacityValue(180.0).toString(), fmt::soilWaterCapacityToCanonical)!!
            val editedDepth = depth.resolve(fmt.lengthValue(0.8).toString(), fmt::lengthToCanonical)!!
            assertEquals(144.0, editedAwc * editedDepth, 1e-9)
        }
        val us = RegionFormatter(RegionCountry.UnitedStates.recommendedPreset)
        assertEquals("in/ft", us.soilWaterCapacityUnit)
        assertEquals(1.8, us.soilWaterCapacityValue(150.0), 1e-8)
    }

    @Test fun tripRatesAndDepthKeepMassAndCanonicalCentimetres() {
        val fmt = RegionFormatter(RegionCountry.UnitedStates.recommendedPreset)
        val rate = RegionalInput.seed(20.123456, fmt::perAreaValue)
        assertEquals(20.123456, rate.resolve(rate.text, fmt::perAreaToCanonical)!!, 0.0)
        assertEquals(24.71053814672, rate.resolve("10", fmt::perAreaToCanonical)!!, 1e-9)
        assertEquals("kg/ac", fmt.yieldPerAreaUnit("kg"))
        val depth = RegionalInput.seed(2.54, fmt::smallLengthValue)
        assertEquals(5.08, depth.resolve("2", fmt::smallLengthToCanonical)!!, 1e-9)
    }

    @Test fun editedPresetAndTripCacheReplayCanonicalUnits() {
        val fmt = RegionFormatter(RegionCountry.UnitedStates.recommendedPreset)
        val water = RegionalInput.seed(1500.123456, fmt::volumeValue)
        val rate = RegionalInput.seed(750.123456, fmt::volumePerAreaValue)
        val preset = com.rork.vinetrack.data.model.SavedSprayPreset(
            id = "preset", vineyardId = "vineyard",
            waterVolume = water.resolve(water.text, fmt::volumeToCanonical)!!,
            sprayRatePerHa = rate.resolve(fmt.volumePerAreaValue(500.0).toString(), fmt::volumePerAreaToCanonical)!!,
            concentrationFactor = 2.5,
        )
        val json = kotlinx.serialization.json.Json
        val replay = json.decodeFromString(com.rork.vinetrack.data.model.SavedSprayPreset.serializer(), json.encodeToString(com.rork.vinetrack.data.model.SavedSprayPreset.serializer(), preset))
        assertEquals(1500.123456, replay.waterVolume, 0.0)
        assertEquals(500.0, replay.sprayRatePerHa, 1e-9)
        assertEquals(2.5, replay.concentrationFactor, 0.0)
        val details = com.rork.vinetrack.data.model.SeedingDetails(
            frontBox = com.rork.vinetrack.data.model.SeedingBox(ratePerHa = fmt.perAreaToCanonical(10.0), seedVolumeKg = 40.0),
            sowingDepthCm = fmt.smallLengthToCanonical(2.0),
        )
        val restored = json.decodeFromString(com.rork.vinetrack.data.model.SeedingDetails.serializer(), json.encodeToString(com.rork.vinetrack.data.model.SeedingDetails.serializer(), details))
        assertEquals(24.71053814672, restored.frontBox!!.ratePerHa!!, 1e-9)
        assertEquals(40.0, restored.frontBox!!.seedVolumeKg!!, 0.0)
        assertEquals(5.08, restored.sowingDepthCm!!, 1e-9)
    }

    @Test fun nullClearingAndNonFiniteInputAreSafe() {
        val input = RegionalInput.seed(null) { it }
        assertNull(input.resolve("", { it }))
        assertNull(input.resolve("NaN", { it }))
        assertNull(input.resolve("Infinity", { it }))
        assertNull(input.resolve("2", { Double.POSITIVE_INFINITY }))
        assertEquals(1.25, input.resolve("1,25", { it })!!, 0.0)
        assertNull(RegionalInput.seed(3.0) { it }.resolve("", { it }))
    }
}
