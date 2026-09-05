package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayTankActualChemical
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.model.chemicalUnitToBase
import org.junit.Assert.assertEquals
import org.junit.Test

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
}
