package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalManualDraft
import com.rork.vinetrack.data.chemical.ChemicalManualEntry
import com.rork.vinetrack.data.chemical.ChemicalManualRateDraft
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSaveViolationCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChemicalManualMinimumSaveContractTest {
    @Test
    fun `manual single rate saves without optional metadata or registered uses`() {
        val draft = ChemicalManualDraft(
            productName = "Manual Wetter",
            productRates = listOf(
                ChemicalManualRateDraft(
                    basis = ChemicalLabelRateBasis.PER_HECTARE,
                    valueText = "2",
                    unit = "L",
                ),
            ),
        )
        val evaluation = ChemicalSaveContract.evaluateMinimumOperational(
            productName = draft.productName,
            productUnit = "Litres",
            rates = ChemicalManualEntry.operationalRates(draft),
        )

        assertTrue(evaluation.violations.toString(), evaluation.isSatisfied)
        assertTrue(ChemicalManualEntry.intelligenceForManualSave(draft).registeredUses.isEmpty())
        val slot = ChemicalManualEntry.defaultRatesForManualSave(draft)!!.perHectare!!
        assertEquals(2.0, slot.value!!, 0.0)
        assertEquals("manual", slot.entryMethod)
        assertTrue(slot.optionKey.isEmpty())
        assertTrue(slot.rateIds.isEmpty())
    }

    @Test
    fun `manual range requires both numeric bounds in order`() {
        val missingMaximum = ChemicalSaveContract.evaluateMinimumOperational(
            productName = "Manual Fungicide",
            productUnit = "Kg",
            rates = listOf(
                ChemicalLabelRate(
                    basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                    minValue = 0.5,
                    unit = "kg",
                ),
            ),
        )
        assertTrue(missingMaximum.violations.any { it.code == ChemicalSaveViolationCode.RATE_VALUE_INVALID })

        val valid = ChemicalSaveContract.evaluateMinimumOperational(
            productName = "Manual Fungicide",
            productUnit = "Kg",
            rates = listOf(
                ChemicalLabelRate(
                    basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                    minValue = 0.5,
                    maxValue = 1.0,
                    unit = "kg",
                ),
            ),
        )
        assertTrue(valid.violations.toString(), valid.isSatisfied)
        assertTrue(valid.violations.none { it.code == ChemicalSaveViolationCode.PRODUCT_CATEGORY_MISSING })
        assertTrue(valid.violations.none { it.code == ChemicalSaveViolationCode.GRAPEVINE_USE_MISSING })
    }

    @Test
    fun `name rate and product unit are the only minimum blockers`() {
        val evaluation = ChemicalSaveContract.evaluateMinimumOperational(" ", " ", emptyList())
        assertEquals(
            setOf(
                ChemicalSaveViolationCode.PRODUCT_NAME_MISSING,
                ChemicalSaveViolationCode.PRODUCT_UNIT_MISSING,
                ChemicalSaveViolationCode.USABLE_RATE_MISSING,
            ),
            evaluation.violations.map { it.code }.toSet(),
        )
    }
}
