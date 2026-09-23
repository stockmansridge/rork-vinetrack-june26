package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLabelIdentityOCR
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSearchV2Rank
import com.rork.vinetrack.data.chemical.ChemicalSearchV2OperationalDefaults
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalSearchV2RequestGate
import com.rork.vinetrack.data.chemical.MasterChemicalV2Repository
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalSearchV2Duplicate
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalDataSource
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.SavedChemicalEntrySource
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.screens.ChemicalSearchV2ManualDetails
import com.rork.vinetrack.ui.screens.ChemicalSearchV2ManualPrefill
import com.rork.vinetrack.data.chemical.ViticultureRates
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test

class ChemicalSearchV2Test {
    @Test fun provenanceAndQueuedV2RepairUseEvidenceNotScreenVersion() {
        val unverified = ChemicalIntelligence()
        val verified = ChemicalIntelligence(
            registration = ChemicalRegistration(countryCode = "AU", scheme = ChemicalRegistrationScheme.APVMA, registrationNumber = "59688"),
            verification = ChemicalVerification(sources = listOf(ChemicalDataSource(kind = ChemicalDataSourceKind.OFFICIAL_REGISTER, name = "APVMA"))),
        )
        assertEquals("customer_entered", SavedChemicalEntrySource.reviewed(true, false, verified))
        assertEquals("master_catalogue", SavedChemicalEntrySource.reviewed(false, true, verified))
        assertEquals("register_lookup", SavedChemicalEntrySource.reviewed(false, false, verified))
        assertEquals("label_lookup", SavedChemicalEntrySource.reviewed(false, false, unverified))
        assertEquals("customer_entered", SavedChemicalEntrySource.repaired("manual_v2", null))
        assertEquals("master_catalogue", SavedChemicalEntrySource.repaired("master_catalogue_v2", null))
        assertEquals("register_lookup", SavedChemicalEntrySource.repaired("label_lookup_v2", verified))
        assertEquals("label_lookup", SavedChemicalEntrySource.repaired("label_lookup_v2", unverified))
        assertNull(SavedChemicalEntrySource.repaired(null, verified))
    }
    @Test fun deterministicRankingCoversExactPrefixRegistrationAndActive() {
        val args = arrayOf("Kocide Blue Xtra", listOf("kocide blue"), "62764", listOf("copper hydroxide"), "Corteva")
        assertEquals(1, ChemicalSearchV2Rank.rank("Kocide Blue Xtra", args[0] as String, args[1] as List<String>, args[2] as String, args[3] as List<String>, args[4] as String))
        assertEquals(2, ChemicalSearchV2Rank.rank("Kocide", args[0] as String, args[1] as List<String>, args[2] as String, args[3] as List<String>, args[4] as String))
        assertEquals(5, ChemicalSearchV2Rank.rank("62764", args[0] as String, args[1] as List<String>, args[2] as String, args[3] as List<String>, args[4] as String))
        assertEquals(6, ChemicalSearchV2Rank.rank("hydroxide", args[0] as String, args[1] as List<String>, args[2] as String, args[3] as List<String>, args[4] as String))
    }

    @Test fun staleRequestCannotReplaceNewResults() {
        assertFalse(ChemicalSearchV2RequestGate.accepts("old", "new"))
        assertTrue(ChemicalSearchV2RequestGate.accepts("new", "new"))
    }

    @Test fun missingRegisteredUseDoesNotBlockReviewSave() {
        val rate = ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 2.0, unit = "L")
        assertTrue(ChemicalSaveContract.evaluateMinimumOperational("Test", "Litres", listOf(rate)).isSatisfied)
    }

    @Test fun photoApvmaIdentityComesBeforeExternalFallback() {
        assertEquals("62764", ChemicalLabelIdentityOCR.apvmaNumber("APVMA Product No. 62764"))
        assertEquals("62764", ChemicalLabelIdentityOCR.proposedQuery("62764", "Dithane Rainshield"))
    }

    @Test fun headingsCannotSilentlyBecomePhotoQueries() {
        listOf("WARNING", "CAUTION").forEach { heading ->
            val text = "$heading\nDITHANE RAINSHIELD\nFUNGICIDE"
            assertNull(ChemicalLabelIdentityOCR.apvmaNumber(text))
            assertNull(ChemicalLabelIdentityOCR.proposedQuery(null, null))
            assertEquals("DITHANE RAINSHIELD", ChemicalLabelIdentityOCR.proposedQuery(null, "DITHANE RAINSHIELD"))
        }
        assertEquals("Corrected name", ChemicalSearchV2ManualPrefill.productName(" Corrected name "))
    }

    @Test fun viticultureRatesKeepBothBasesAndSeparateOptions() {
        val rates = ViticultureRates.fromRegisteredUses(listOf(
            ChemicalRegisteredUse(crop = "ORCHARDS, PLANTATIONS AND VINEYARDS", rates = listOf(
                ChemicalLabelRate(basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE, minValue = 2.4, maxValue = 3.2, unit = "L"),
                ChemicalLabelRate(basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES, minValue = 240.0, maxValue = 320.0, unit = "mL"),
            )),
            ChemicalRegisteredUse(crop = "Grapes", rates = listOf(
                ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_100_LITRES, value = 40.0, unit = "mL"),
            )),
        ))
        assertEquals(1, rates.perHectare.size)
        assertEquals(2, rates.per100Litres.size)
    }

    @Test fun unambiguousPerHectareRateInitialisesAndEnablesSave() {
        val rate = ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 2.4, unit = "L")
        val defaults = ChemicalSearchV2OperationalDefaults.unambiguousRates(
            ViticultureRates(perHectare = listOf(rate)),
        )
        assertEquals(rate, defaults[ChemicalDefaultRateBasis.PER_HECTARE])
        assertTrue(ChemicalSaveContract.evaluateMinimumOperational("Test", "Litres", defaults.values.toList()).isSatisfied)
    }

    @Test fun unambiguousPer100LitresRateInitialisesAndEnablesSave() {
        val rate = ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_100_LITRES, value = 240.0, unit = "mL")
        val defaults = ChemicalSearchV2OperationalDefaults.unambiguousRates(
            ViticultureRates(per100Litres = listOf(rate)),
        )
        assertEquals(rate, defaults[ChemicalDefaultRateBasis.PER_100_LITRES])
        assertTrue(ChemicalSaveContract.evaluateMinimumOperational("Test", "mL", defaults.values.toList()).isSatisfied)
    }

    @Test fun oneRatePerBasisPersistsBothWithoutChangingRangeOrUnit() {
        val perHa = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            minValue = 2.4, maxValue = 3.2, unit = "L",
        )
        val per100 = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            minValue = 240.0, maxValue = 320.0, unit = "mL",
        )
        val masterRates = ViticultureRates(listOf(perHa), listOf(per100))
        val snapshot = masterRates.copy()
        val initial = ChemicalSearchV2OperationalDefaults.unambiguousRates(masterRates)
        val effective = ChemicalSearchV2OperationalDefaults.effectiveRates(initial, null)
        val stored = ChemicalSearchV2OperationalDefaults.storedDefaults(effective, "2026-09-18T00:00:00Z")

        assertEquals(2, effective.size)
        assertEquals(null, stored?.perHectare?.value)
        assertEquals(2.4, stored?.perHectare?.minValue)
        assertEquals(3.2, stored?.perHectare?.maxValue)
        assertEquals("L", stored?.perHectare?.unit)
        assertEquals(null, stored?.per100Litres?.value)
        assertEquals(240.0, stored?.per100Litres?.minValue)
        assertEquals(320.0, stored?.per100Litres?.maxValue)
        assertEquals("mL", stored?.per100Litres?.unit)
        assertEquals(snapshot, masterRates)
    }

    @Test fun multipleAlternativesAreNotSelectedAndManualOverrideRemainsAvailable() {
        val low = ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 2.0, unit = "L")
        val high = ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 3.0, unit = "L")
        val initial = ChemicalSearchV2OperationalDefaults.unambiguousRates(
            ViticultureRates(perHectare = listOf(low, high)),
        )
        assertFalse(initial.containsKey(ChemicalDefaultRateBasis.PER_HECTARE))

        val manual = ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 2.5, unit = "L")
        val effective = ChemicalSearchV2OperationalDefaults.effectiveRates(initial, manual)
        assertEquals(listOf(manual), effective)
        assertTrue(ChemicalSaveContract.evaluateMinimumOperational("Test", "Litres", effective).isSatisfied)
    }

    @Test fun punctuationNormalisationFindsSpraySeed() {
        val name = "SPRAY.SEED 250 HERBICIDE"
        assertEquals(2, ChemicalSearchV2Rank.rank("Spray Seed 250", name, emptyList(), "46516", emptyList(), null))
        assertEquals(2, ChemicalSearchV2Rank.rank("Spray.Seed 250", name, emptyList(), "46516", emptyList(), null))
    }

    @Test fun normalMasterSearchDoesNotInvokeAI() {
        assertFalse(MasterChemicalV2Repository.INVOKES_AI)
    }

    @Test fun manualEntryPrefillsTypedSearchAndStaysVineyardOnly() {
        assertEquals("My Local Sulphur", ChemicalSearchV2ManualPrefill.productName("  My Local Sulphur  "))
        val details = ChemicalSearchV2ManualDetails(
            manufacturer = "Local supplier",
            productCategory = "fungicide",
            activeIngredient = "Sulphur",
            activityGroupScheme = com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme.FRAC,
            activityGroupCode = "M02",
            notes = "Optional note",
        )
        val intelligence = details.intelligence(
            "My Local Sulphur",
            com.rork.vinetrack.data.chemical.ChemicalManualRateDraft(
                basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
                minText = "200", maxText = "400", unit = "g",
            ),
        )

        assertTrue(intelligence.registeredUses.isEmpty())
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, intelligence.resolvedVerificationStatus)
        assertEquals(listOf("Sulphur"), intelligence.activeIngredients.map { it.name })
    }

    @Test fun manualSingleAndRangePersistToExactDefaultRateBasis() {
        val single = ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 2.0, unit = "L")
        val range = ChemicalLabelRate(basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES, minValue = 200.0, maxValue = 400.0, unit = "g")
        val area = ChemicalSearchV2OperationalDefaults.storedDefaults(listOf(single), "2026-09-19T00:00:00Z")!!.perHectare!!
        val volume = ChemicalSearchV2OperationalDefaults.storedDefaults(listOf(range), "2026-09-19T00:00:00Z")!!.per100Litres!!

        assertEquals(2.0, area.value!!, 0.0)
        assertEquals("L", area.unit)
        assertEquals(200.0, volume.minValue!!, 0.0)
        assertEquals(400.0, volume.maxValue!!, 0.0)
        assertEquals("g", volume.unit)
        assertEquals("manual", area.entryMethod)
        assertEquals("manual", volume.entryMethod)
    }

    @Test fun optionalDetailsAndRegisteredUsesDoNotBlockManualSave() {
        val rate = ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_100_LITRES, value = 200.0, unit = "g")
        val evaluation = ChemicalSaveContract.evaluateMinimumOperational("Wettable Sulphur", "g", listOf(rate))
        assertTrue(evaluation.violations.toString(), evaluation.isSatisfied)
    }

    @Test fun manualDuplicateUsesExactNormalisedVineyardNameOnly() {
        val existing = SavedChemical(id = "existing", vineyardId = "vineyard", name = "Wettable Sulphur")
        val intelligence = com.rork.vinetrack.data.chemical.ChemicalIntelligence(
            verification = com.rork.vinetrack.data.chemical.ChemicalVerification.manual(),
        )
        assertEquals(existing, ChemicalSearchV2Duplicate.existing(null, intelligence, "wettable-sulphur", listOf(existing)))
        assertNull(ChemicalSearchV2Duplicate.existing(null, intelligence, "Wettable Sulphur Plus", listOf(existing)))
    }
}
