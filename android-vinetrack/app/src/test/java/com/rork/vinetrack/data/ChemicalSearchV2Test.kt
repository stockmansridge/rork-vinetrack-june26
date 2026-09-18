package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLabelIdentityOCR
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSearchV2Rank
import com.rork.vinetrack.data.chemical.ChemicalSearchV2RequestGate
import com.rork.vinetrack.data.chemical.MasterChemicalV2Repository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChemicalSearchV2Test {
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
    }

    @Test fun normalMasterSearchDoesNotInvokeAI() {
        assertFalse(MasterChemicalV2Repository.INVOKES_AI)
    }
}
