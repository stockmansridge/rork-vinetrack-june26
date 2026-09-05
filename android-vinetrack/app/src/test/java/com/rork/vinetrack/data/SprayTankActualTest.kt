package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayTankActualChemical
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.model.chemicalUnitToBase
import com.rork.vinetrack.ui.screens.parseLocalizedNonNegativeDecimal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.text.NumberFormat
import java.util.Locale

class SprayTankActualTest {
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

    @Test fun strictLocaleParserAcceptsOnlyTheDeviceDecimalSeparator() {
        val formatter = NumberFormat.getNumberInstance(Locale.GERMANY)
        assertEquals(12.5, parseLocalizedNonNegativeDecimal("12,5", formatter)!!, 0.0)
        assertNull(parseLocalizedNonNegativeDecimal("12,5x", formatter))
        assertNull(parseLocalizedNonNegativeDecimal("12,,5", formatter))
    }
}
