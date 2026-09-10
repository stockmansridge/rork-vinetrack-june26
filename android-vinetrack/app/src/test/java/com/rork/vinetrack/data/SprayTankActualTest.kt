package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.SprayTankActualChemical
import com.rork.vinetrack.data.model.areSprayTankActualsComplete
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.model.chemicalUnitToBase
import com.rork.vinetrack.ui.screens.actualPlannedDifference
import com.rork.vinetrack.ui.screens.parseLocalizedNonNegativeDecimal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.text.NumberFormat
import java.util.Locale

class SprayTankActualTest {
    @Test fun sharedRepositoryChemicalFixtureDecodesCompleteContract() {
        val fixtureFile = listOf(
            File("ios/VineTrackTests/Fixtures/spray_tank_actual_chemical.json"),
            File("../ios/VineTrackTests/Fixtures/spray_tank_actual_chemical.json"),
            File("../../ios/VineTrackTests/Fixtures/spray_tank_actual_chemical.json"),
        ).first { it.exists() }
        val fixture = fixtureFile.readText()
        val decoded = SupabaseClient.json.decodeFromString(SprayTankActualChemical.serializer(), fixture)
        assertEquals("10000000-0000-4000-8000-000000000002", decoded.plannedChemicalId)
        assertEquals("10000000-0000-4000-8000-000000000003", decoded.savedChemicalId)
        assertEquals(1250.5, decoded.actualAmountBase, 0.0)
        assertEquals("mL", decoded.unit)
    }

    @Test fun sharedChemicalJsonDecodesConfirmedZero() {
        val json = """{"id":"10000000-0000-4000-8000-000000000001","plannedChemicalId":null,"savedChemicalId":null,"name":"Product","actualAmountBase":0,"unit":"Litres"}"""
        val decoded = SupabaseClient.json.decodeFromString(SprayTankActualChemical.serializer(), json)
        assertEquals(0.0, decoded.actualAmountBase, 0.0)
    }

    @Test fun liquidAndSolidConversionsPreserveBaseValues() {
        assertEquals(3500.0, chemicalUnitToBase("Litres", 3.5), 0.0)
        assertEquals(1.125, chemicalUnitFromBase("Kg", 1125.0), 0.0)
    }

    @Test fun strictLocaleParserConsumesTheEntireEnglishInput() {
        val formatter = NumberFormat.getNumberInstance(Locale.US)
        assertEquals(12.5, parseLocalizedNonNegativeDecimal("12.5", formatter)!!, 0.0)
        assertEquals(0.0, parseLocalizedNonNegativeDecimal("0", formatter)!!, 0.0)
        listOf("", " 1", "1 ", "1x", "x1", "1.2.3", "-1", "NaN", "Infinity").forEach {
            assertNull(it, parseLocalizedNonNegativeDecimal(it, formatter))
        }
    }

    @Test fun signedDifferenceKeepsMissingDistinctFromExplicitZero() {
        assertNull(actualPlannedDifference(null, 500.0))
        assertEquals(-500.0, actualPlannedDifference(0.0, 500.0)!!, 0.0)
        assertEquals(25.0, actualPlannedDifference(525.0, 500.0)!!, 0.0)
    }

    @Test fun completenessRequiresWaterAndExactIdentityButAcceptsAdditionalAndSubstitutionLines() {
        val plannedId = "planned"
        val tank = SprayTank("tank", 1, 500.0, chemicals = listOf(SprayChemical(plannedId, "Product", 1000.0, unit = "mL")))
        val substitution = SprayTankActualChemical("sub", null, null, "Replacement", 900.0, "mL", plannedId, "substitution")
        val addition = SprayTankActualChemical("add", null, null, "Addition", 250.0, "mL", usageKind = "additional")
        val actual = SprayTankActual("actual", "vineyard", "spray", "trip", "session", 1, 0.0, listOf(substitution, addition), "2026-09-10T00:00:00Z", "user")
        assertTrue(areSprayTankActualsComplete(listOf(tank), listOf(actual), "vineyard", "spray", "trip", mapOf(1 to setOf("session"))))
        assertFalse(areSprayTankActualsComplete(listOf(tank), listOf(actual.copy(waterVolumeL = null)), "vineyard", "spray", "trip", mapOf(1 to setOf("session"))))
        assertFalse(areSprayTankActualsComplete(listOf(tank), listOf(actual, actual.copy(id = "other", tankSessionId = "other-session")), "vineyard", "spray", "trip", mapOf(1 to setOf("session", "other-session"))))
        assertFalse(areSprayTankActualsComplete(listOf(tank), listOf(actual), "vineyard", "spray", "trip", emptyMap()))
        val unmatchedTank = actual.copy(id = "extra", tankSessionId = "extra-session", tankNumber = 2)
        assertFalse(areSprayTankActualsComplete(listOf(tank), listOf(actual, unmatchedTank), "vineyard", "spray", "trip", mapOf(1 to setOf("session"))))
        val duplicateAddition = actual.copy(chemicals = actual.chemicals + addition)
        assertFalse(areSprayTankActualsComplete(listOf(tank), listOf(duplicateAddition), "vineyard", "spray", "trip", mapOf(1 to setOf("session"))))
        val zeroPlanned = SprayTankActualChemical("zero", plannedId, null, "Product", 0.0, "mL")
        assertTrue(areSprayTankActualsComplete(listOf(tank), listOf(actual.copy(chemicals = listOf(zeroPlanned, substitution, addition))), "vineyard", "spray", "trip", mapOf(1 to setOf("session"))))
    }

    @Test fun strictLocaleParserAcceptsOnlyTheDeviceDecimalSeparator() {
        val formatter = NumberFormat.getNumberInstance(Locale.GERMANY)
        assertEquals(12.5, parseLocalizedNonNegativeDecimal("12,5", formatter)!!, 0.0)
        assertNull(parseLocalizedNonNegativeDecimal("12,5x", formatter))
        assertNull(parseLocalizedNonNegativeDecimal("12,,5", formatter))
    }
}
