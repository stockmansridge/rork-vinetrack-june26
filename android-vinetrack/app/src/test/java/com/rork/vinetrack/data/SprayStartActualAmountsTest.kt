package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.SprayStartActualAmounts
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class SprayStartActualAmountsTest {
    private val tanks = listOf(SprayTank("tank-1", tankNumber = 1, waterVolume = 294.7,
        chemicals = listOf(SprayChemical("chemical-1", name = "Greenshield", volumePerTank = 700.0,
            unit = "Kg", ratePerHa = 1400.0, savedChemicalId = "saved"))),
        SprayTank("tank-2", tankNumber = 2, waterVolume = 294.7,
            chemicals = listOf(SprayChemical("chemical-2", name = "Greenshield", volumePerTank = 700.0,
                unit = "Kg", ratePerHa = 1400.0, savedChemicalId = "saved"))))

    private fun parse(text: Map<String, String>) = SprayStartActualAmounts.parse(tanks, text, locale = Locale.US)

    @Test fun blankActualsCannotConfirmCalculatedAmounts() {
        assertNull(parse(emptyMap()))
        assertNull(parse(mapOf("water" to "300")))
        assertNull(parse(mapOf("chemical:0" to "0.75")))
    }

    @Test fun firstTankUsesPositiveNumberOrderAndRejectsAmbiguousIdentities() {
        assertEquals(tanks.first(), SprayStartActualAmounts.firstTank(tanks.reversed()))
        assertNull(SprayStartActualAmounts.firstTank(emptyList()))
        assertNull(SprayStartActualAmounts.firstTank(tanks.map { it.copy(tankNumber = 1) }))
        assertNull(SprayStartActualAmounts.firstTank(tanks.map { it.copy(id = "duplicate") }))
        assertNull(SprayStartActualAmounts.firstTank(tanks.map { it.copy(id = " ") }))
        assertNull(SprayStartActualAmounts.firstTank(listOf(tanks.first().copy(tankNumber = 0))))
        assertNull(SprayStartActualAmounts.firstTank(listOf(tanks.first().copy(tankNumber = -1))))
    }

    @Test fun enteredAmountsAreSeparateFromPlanAndOnlyCoverTheTankMixedNow() {
        val amounts = requireNotNull(parse(mapOf("water" to "300", "chemical:0" to "0.75")))
        assertEquals(300.0, amounts.waterLitres, 0.0)
        assertEquals(mapOf("chemical-1" to 750.0), amounts.amountsFor(tanks))
        assertEquals(294.7, tanks.first().waterVolume, 0.0)
        assertEquals(700.0, tanks.first().chemicals.single().volumePerTank, 0.0)
        assertFalse(amounts.amountsFor(tanks)!!.containsKey("chemical-2"))
    }

    @Test fun explicitZeroChemicalIsRecordedAndMissingIsNotZero() {
        assertEquals(0.0, parse(mapOf("water" to "300", "chemical:0" to "0"))!!.chemicalAmountsBase.single(), 0.0)
        assertNull(parse(mapOf("water" to "300", "chemical:0" to "")))
        assertNull(parse(mapOf("water" to "0", "chemical:0" to "0.7")))
    }

    @Test fun invalidTextNeverEnablesStarting() {
        for (text in listOf("", "-1", "NaN", "Infinity", "1.2.3", "3x", " 1")) {
            assertNull(text, parse(mapOf("water" to text, "chemical:0" to "0.75")))
            assertNull(text, parse(mapOf("water" to "300", "chemical:0" to text)))
        }
    }

    @Test fun regionWaterAndLocaleDecimalConvertExactlyOnce() {
        val actual = SprayStartActualAmounts.parse(tanks, mapOf("water" to "10,5", "chemical:0" to "0,75"),
            waterToLitres = { it * 3.785411784 }, locale = Locale.GERMANY)!!
        assertEquals(39.746823732, actual.waterLitres, 0.00000001)
        assertEquals(750.0, actual.chemicalAmountsBase.single(), 0.0)
    }

    @Test fun recipeChangeOrProductChangeRejectsStaleActuals() {
        val actual = parse(mapOf("water" to "300", "chemical:0" to "0.75"))!!
        assertNull(actual.amountsFor(tanks.map { it.copy(waterVolume = 400.0) }))
        assertNull(actual.amountsFor(tanks.map { it.copy(chemicals = it.chemicals.map { c -> c.copy(savedChemicalId = "other") }) }))
        assertNull(actual.copy(chemicalAmountsBase = emptyList()).amountsFor(tanks))
    }

    @Test fun regeneratedPreviewIdsRemapOnlyTheIdenticalOrderedRecipe() {
        val actual = parse(mapOf("water" to "300", "chemical:0" to "0.75"))!!
        val frozen = tanks.map { it.copy(id = "frozen-${it.id}", chemicals = it.chemicals.map { c -> c.copy(id = "frozen-${c.id}") }) }
        assertEquals(mapOf("frozen-chemical-1" to 750.0), actual.amountsFor(frozen))
        val draft = actual.retainedDraft(frozen)!!
        assertEquals(actual, SprayStartActualAmounts.fromRetainedDraft(frozen, draft))
        // A retained exact-trip payload cannot be applied to newly generated chemical IDs.
        assertNull(SprayStartActualAmounts.fromRetainedDraft(tanks, draft))
    }

    @Test fun retainedDraftRoundTripKeepsAmountsAndRejectsMissingOrChangedRecipe() {
        val actual = parse(mapOf("water" to "300.123456", "chemical:0" to "0.712345"))!!
        val retained = actual.retainedDraft(tanks)!!
        assertEquals(actual, SprayStartActualAmounts.fromRetainedDraft(tanks, retained))
        assertNull(SprayStartActualAmounts.fromRetainedDraft(tanks, retained - "@chemicalBase:chemical-1"))
        assertNull(SprayStartActualAmounts.fromRetainedDraft(tanks, retained + ("@recipe" to "different")))
    }

    @Test fun productOrderAndDuplicateIdsCannotMisattributeActuals() {
        val first = tanks.first()
        val two = listOf(first.copy(chemicals = first.chemicals + first.chemicals.single().copy(id = "second", name = "Second", savedChemicalId = "second")))
        val actual = SprayStartActualAmounts.parse(two, mapOf("water" to "300", "chemical:0" to "0.75", "chemical:1" to "0.2"), locale = Locale.US)!!
        assertNull(actual.amountsFor(two.map { it.copy(chemicals = it.chemicals.reversed()) }))
        assertNull(actual.amountsFor(two.map { it.copy(chemicals = it.chemicals.map { c -> c.copy(id = "duplicate") }) }))
    }

    @Test fun importedDisplayQuantitiesDoNotCauseActualDoubleConversion() {
        val display = tanks.map { it.copy(chemicals = it.chemicals.map { c -> c.copy(volumePerTank = 0.7, ratePerHa = 1.4, quantityBasis = "display") }) }
        val actual = SprayStartActualAmounts.parse(display, mapOf("water" to "300", "chemical:0" to "0.75"), locale = Locale.US)!!
        assertEquals(750.0, actual.chemicalAmountsBase.single(), 0.0)
    }

    @Test fun onlyMatchingCanonicalOrRegionBoundRawInputCanBeConsumed() {
        val actual = parse(mapOf("water" to "300", "chemical:0" to "0.75"))!!
        val values = actual.amountsFor(tanks)!!
        val canonical = actual.retainedDraft(tanks)!!
        assertTrue(SprayStartActualAmounts.matchesTankDraft(tanks.first(), canonical, 300.0, values))
        assertFalse(SprayStartActualAmounts.matchesTankDraft(tanks.first(), canonical, 301.0, values))
        val raw = canonical + mapOf("water" to "10,5", "chemical-1" to "0,75",
            "@locale" to "de-DE", "@volumeToLitres" to "3.785411784")
        assertTrue(SprayStartActualAmounts.matchesTankDraft(tanks.first(), raw, 39.746823732, values))
        assertFalse(SprayStartActualAmounts.matchesTankDraft(tanks.first(), raw, 300.0, values))
        assertFalse(SprayStartActualAmounts.matchesTankDraft(tanks.first(), raw - "@locale", 39.746823732, values))
    }
}
