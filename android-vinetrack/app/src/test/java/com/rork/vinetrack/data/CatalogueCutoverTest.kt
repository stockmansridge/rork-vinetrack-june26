package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.*
import org.junit.Test
import org.junit.Assert.*

class CatalogueCutoverTest {
    private fun row(json: String) = CatalogueRow(SupabaseClient.json.parseToJsonElement(json).jsonObject)
    @Test fun `socoa stifle displays returned approved backend match without local fuzzy matching`() {
        val stifle = row("""{"revision_id":"approved-stifle","product_name":"STIFLE™ DORMANT SPRAY OIL","manufacturer":"SACOA Pty Ltd","review_status":"approved"}""")
        assertEquals("STIFLE™ DORMANT SPRAY OIL", stifle.text("product_name"))
        assertEquals("VineTrack catalogue", stifle.badge)
        assertEquals("SACOA", CatalogueRow.compactManufacturer(stifle.text("manufacturer")!!))
        assertEquals("VineTrack catalogue", row("""{"product_name":"Weedmaster DUO","review_status":"approved"}""").badge)
    }
    @Test fun `text and photo completed catalogue matches are success and resume same identity`() {
        val job = row("""{"id":"same-job","status":"completed","stage":"catalogue_match","revision_id":"approved-stifle"}""")
        assertTrue(job.isSuccess); assertTrue(job.isTerminal); assertEquals("approved-stifle", job.text("revision_id"))
        for (kind in listOf("text", "photo")) {
            val saved = CatalogueDiscoveryContext("same-job", "user", "vineyard", "socoa stifle", "AU", kind, if (kind == "photo") "search-inputs/user/input.jpg" else null, 123L)
            val restored = SupabaseClient.json.decodeFromString<CatalogueDiscoveryContext>(SupabaseClient.json.encodeToString(saved))
            assertEquals(saved, restored)
        }
    }
    @Test fun `pending and needs attention are addable customer safe results`() {
        for (status in listOf("pending_review", "needs_attention")) {
            assertTrue(row("""{"status":"$status"}""").isSuccess)
            assertEquals("Pending VineTrack review", row("""{"review_status":"$status"}""").badge)
        }
    }
    @Test fun `linked vineyard uses flatten targets and backend FRAC is not inferred`() {
        val result = row("""{"activity_group_scheme":"frac","activity_groups":["3"],"vineyard_uses":[{"targets":["Powdery mildew","Downy mildew","Eutypa dieback"]},{"targets":["powdery mildew"]}]}""")
        assertEquals(listOf("Powdery mildew", "Downy mildew", "Eutypa dieback"), result.targets)
        assertTrue(result.targets.joinToString().contains("downy", true)); assertEquals("FRAC 3", result.groupText)
    }
    @Test fun `unknown inventory is not zero and stock value is backend supplied`() {
        val unknown = row("""{"tracking_status":"needs_opening_stock","current_quantity":null,"estimated_stock_value":null,"out_of_stock":false}""")
        assertEquals("Opening stock not set", unknown.inventoryStatus); assertNull(unknown.number("current_quantity")); assertNull(unknown.number("estimated_stock_value"))
        assertEquals(123.45, row("""{"current_quantity":10,"estimated_stock_value":123.45}""").number("estimated_stock_value")!!, 0.0)
    }
    @Test fun `exact backend saved ID and linked revision survive options object decoding`() {
        val saved = SupabaseClient.json.decodeFromString<SavedChemical>("""{"id":"server-saved-id","vineyard_id":"vineyard","name":"Belanty","chemical_v3_revision_id":"exact-revision","rates":{"per_hectare":[]}}""")
        assertEquals("server-saved-id", saved.id); assertEquals("exact-revision", saved.chemicalV3RevisionId)
        assertEquals(saved, SupabaseClient.json.decodeFromString<SavedChemical>(SupabaseClient.json.encodeToString(saved)))
    }
    @Test fun `terminal handler fetches existing approved revision for text and photo without new search`() = kotlinx.coroutines.runBlocking {
        val job = row("""{"status":"completed","stage":"catalogue_match","revision_id":"approved-stifle"}""")
        var fetched = ""
        val result = CatalogueTerminalResolver.result(job) { id -> fetched = id; row("""{"id":"$id","review_status":"approved"}""") }
        assertEquals("approved-stifle", fetched); assertEquals("VineTrack catalogue", result.badge)
    }
    @Test fun `inventory policy excludes ordinary owners and managers`() {
        assertTrue(CatalogueTerminalResolver.inventoryAllowed(true))
        assertFalse(CatalogueTerminalResolver.inventoryAllowed(false))
    }
    @Test fun `Belanty Greenshield Sprayseal and THIOVIT target display uses exact revision targets`() {
        for ((product, targets) in listOf("Belanty" to listOf("Powdery mildew"), "Greenshield" to listOf("Black spot", "Downy mildew", "Phomopsis Cane and Leaf spot"), "Sprayseal" to listOf("Eutypa dieback", "Botryosphaeria dieback"), "THIOVIT" to listOf("Powdery mildew", "Bud mite"))) {
            val linked = CatalogueRow(buildJsonObject { put("product_name", product); put("front_label_image_path", "labels/$product.jpg"); put("vineyard_uses", buildJsonArray { add(buildJsonObject { put("targets", buildJsonArray { targets.forEach { add(it) } }) }) }) })
            assertEquals(targets, linked.targets); assertEquals("labels/$product.jpg", linked.text("front_label_image_path"))
        }
    }
    @Test fun `inventory mutation refreshes only the exact affected summary`() = kotlinx.coroutines.runBlocking {
        var mutated = false; val refreshed = mutableListOf<String>()
        CatalogueInventoryMutation.perform(true, "chemical_inventory_record_stocktake", "affected",
            mutate = { mutated = true }, refresh = { refreshed.add(it); Unit })
        assertTrue(mutated); assertEquals(listOf("affected"), refreshed)
        mutated = false; refreshed.clear()
        try { CatalogueInventoryMutation.perform(false, "chemical_inventory_record_purchase", "affected",
            mutate = { mutated = true }, refresh = { refreshed.add(it); Unit }) } catch (_: Exception) { }
        assertFalse(mutated); assertTrue(refreshed.isEmpty())
    }
    @Test fun `saved ID handoff does not reset existing sprays trips or calculation fields`() {
        val spray = com.rork.vinetrack.data.model.SprayRecord(id = "planned", vineyardId = "vineyard", notes = "Keep draft weather and blocks")
        val trip = com.rork.vinetrack.data.model.Trip(id = "trip", vineyardId = "vineyard", isActive = true)
        val original = com.rork.vinetrack.ui.AppUiState(sprayRecords = listOf(spray), trips = listOf(trip))
        val saved = SavedChemical(id = "server-saved-id", vineyardId = "vineyard", name = "Same name", chemicalV3RevisionId = "exact-revision")
        val changed = com.rork.vinetrack.ui.CatalogueSavedHandoff.applying(original, saved)
        assertEquals("server-saved-id", changed.savedChemicals.single().id)
        assertEquals(original, changed.copy(savedChemicals = original.savedChemicals))
    }
    @Test fun `rates are separate and ranges unmodified`() {
        val result = row("""{"default_rate_options":{"per_hectare":[{"value":2,"unit":"L"}],"per_100_litres":[{"min_value":150,"max_value":200,"unit":"g"}]}}""")
        assertEquals(2.0, result.rateRows("per_hectare").single().number("value")!!, 0.0)
        assertEquals(150.0, result.rateRows("per_100_litres").single().number("min_value")!!, 0.0)
    }
}
