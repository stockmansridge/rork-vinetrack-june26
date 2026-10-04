package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.ui.AppUiState
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChemicalInventoryTraceabilityTest {
    @Test fun ownerAndManagerCanOpenAndMutate() = runBlocking {
        for (role in listOf("owner", "manager")) {
            val state = AppUiState(selectedVineyardId = "vineyard", currentUserId = "user",
                members = listOf(VineyardMember(userId = "user", vineyardId = "vineyard", role = role)))
            assertTrue(state.canManageInventory)
            var wrote = false; var refreshed = false
            CatalogueInventoryMutation.perform(state.canManageInventory, CatalogueInventoryMutation.PURCHASE, "chemical",
                mutate = { wrote = true }, refresh = { refreshed = true })
            assertTrue(wrote && refreshed)
        }
    }
    @Test fun supervisorAndOperatorCannotMutate() = runBlocking {
        for (role in listOf("supervisor", "operator")) {
            val state = AppUiState(selectedVineyardId = "vineyard", currentUserId = "user", isSystemAdmin = true,
                members = listOf(VineyardMember(userId = "user", vineyardId = "vineyard", role = role)))
            assertFalse(state.canManageInventory)
            var wrote = false
            try {
                CatalogueInventoryMutation.perform(state.canManageInventory, "chemical_inventory_mark_finished", "chemical",
                    mutate = { wrote = true }, refresh = {})
                fail("Denied membership must not write")
            } catch (_: IllegalStateException) { }
            assertFalse(wrote)
        }
    }
    @Test fun adminStatusAloneAndOtherVineyardMembershipDoNotGrantAccess() {
        assertFalse(AppUiState(selectedVineyardId = "vineyard", currentUserId = "user", isSystemAdmin = true).canManageInventory)
        assertFalse(AppUiState(currentUserId = "user", isSystemAdmin = true,
            members = listOf(VineyardMember(userId = "user", role = "manager"))).canManageInventory)
        assertFalse(AppUiState(selectedVineyardId = "vineyard", currentUserId = "user", isSystemAdmin = true,
            members = listOf(VineyardMember(userId = "user", vineyardId = "other", role = "manager"))).canManageInventory)
    }
    @Test fun exactSharedRPCKeysTrimTextAndPreserveManufacturerDate() {
        val fields = ChemicalInventoryTraceability.fields(" LOT-A ", "2025-12-01", " SN-A/007 ")
        assertEquals(setOf("p_batch_number", "p_batch_date", "p_serial_number"), fields.keys)
        assertEquals("LOT-A", fields["p_batch_number"]!!.jsonPrimitive.content)
        assertEquals("2025-12-01", fields["p_batch_date"]!!.jsonPrimitive.content)
        assertEquals("SN-A/007", fields["p_serial_number"]!!.jsonPrimitive.content)
        assertEquals(fields, Json.parseToJsonElement(fields.toString()).jsonObject)
        assertEquals(JsonNull, ChemicalInventoryTraceability.nullableText(" \n "))
    }
    @Test fun unsetFieldsAndLegacyHistoryRemainNull() {
        val fields = ChemicalInventoryTraceability.fields("", null, " ")
        assertEquals(JsonNull, fields["p_batch_date"]); assertEquals(JsonNull, fields["p_serial_number"])
        val legacy = CatalogueRow(Json.parseToJsonElement("""{"purchase_id":"legacy","quantity":8,"unit":"kg","batch_date":null,"serial_number":null}""").jsonObject)
        assertTrue(ChemicalInventoryTraceability.display(legacy).isEmpty())
        assertEquals("8 kg total", CatalogueInventoryContainer.historyText(legacy))
    }
    @Test fun historyKeepsSeparateRowsAndDisplaysPresentMetadata() {
        val rows = Json.parseToJsonElement("""[{"purchase_id":"one","batch_number":"LOT-A","batch_date":"2025-12-01","serial_number":"SN-A/007"},{"purchase_id":"two","batch_number":"LOT-A","batch_date":"2025-12-01","serial_number":"SN-A/007"}]""").jsonArray.map { CatalogueRow(it.jsonObject) }
        assertEquals(2, rows.size); assertNotEquals(rows[0].id, rows[1].id)
        assertEquals(listOf("Batch / Lot number: LOT-A", "Production / Batch date: 2025-12-01", "Serial number (if applicable): SN-A/007"), ChemicalInventoryTraceability.display(rows[0]))
        val latest = CatalogueRow(buildJsonObject { put("latest_batch_date", "2025-12-01"); put("latest_serial_number", "SN-A/007") })
        assertEquals(2, ChemicalInventoryTraceability.display(latest, true).size)
    }
    @Test fun containerCalculationContractsRemainSeparate() {
        assertEquals("2 × 20 L = 40 L total", CatalogueInventoryContainer.preview(2.0, 20.0, "L"))
        assertEquals("12", CatalogueInventoryContainer.openingQuantity("2", "20", "12", true))
        val fields = CatalogueInventoryContainer.fields(2.0, 20.0, "L")
        assertEquals(2.0, fields["p_container_count"]!!.jsonPrimitive.double, 0.0)
        assertEquals(20.0, fields["p_container_size"]!!.jsonPrimitive.double, 0.0)
        assertFalse(fields.containsKey("p_quantity")); assertFalse(fields.containsKey("p_percent_remaining"))
    }
}
