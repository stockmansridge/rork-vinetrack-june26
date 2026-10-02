package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.CatalogueFrontLabelResolver
import com.rork.vinetrack.data.chemical.CatalogueRow
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class CatalogueFrontLabelTest {
    private fun row(json: String): CatalogueRow = CatalogueRow(Json.parseToJsonElement(json).jsonObject)

    @Test fun exactApprovedSupersededAndPendingImagesWinWithoutFallbackRequests() = runBlocking {
        for (example in listOf("Belanty", "Greenshield", "Sprayseal", "superseded", "pending_review")) {
            val status = if (example in listOf("superseded", "pending_review")) example else "approved"
            val exact = row("""{"id":"exact","product_id":"product","review_status":"$status","front_label_image_path":"labels/$example.jpg"}""")
            var calls = 0
            val path = CatalogueFrontLabelResolver.resolve(exact,
                product = { calls++; exact }, revision = { calls++; exact })
            assertEquals("labels/$example.jpg", path)
            assertEquals(0, calls)
        }
    }

    @Test fun miravisAndKocideFallbackChangesOnlyImageNotSavedIdentityOrExactCatalogueFields() = runBlocking {
        for (name in listOf("MIRAVIS", "Kocide")) {
            val saved = SavedChemical(id = "saved-id", vineyardId = "vineyard", name = name, chemicalV3RevisionId = "exact")
            val before = saved.copy()
            val exact = row("""{"id":"exact","product_id":"product","review_status":"superseded","manufacturer":"Original manufacturer","manufacturer_label_url":"https://example.com/exact-label","activity_group_scheme":"frac","activity_groups":["7"],"vineyard_uses":[{"targets":["Original target"]}],"default_rate_options":{"per_hectare":[{"value":2,"unit":"L"}]}}""")
            val originalFields = exact.fields
            val requests = mutableListOf<String>()
            val path = CatalogueFrontLabelResolver.resolve(exact, product = { id ->
                requests.add("product:$id")
                row("""{"id":"$id","approved_revision_id":"approved"}""")
            }, revision = { id ->
                requests.add("revision:$id")
                row("""{"id":"$id","product_id":"product","front_label_image_path":"labels/$name-current.jpg","activity_groups":["99"],"review_status":"approved"}""")
            })
            assertEquals("labels/$name-current.jpg", path)
            assertEquals(listOf("product:product", "revision:approved"), requests)
            assertEquals(originalFields, exact.fields)
            assertEquals("FRAC 7", exact.groupText)
            assertEquals(listOf("Original target"), exact.targets)
            assertEquals(2.0, exact.rateRows("per_hectare").single().number("value")!!, 0.0)
            assertEquals("superseded", exact.text("review_status"))
            assertEquals("Original manufacturer", exact.text("manufacturer"))
            assertEquals("https://example.com/exact-label", exact.text("manufacturer_label_url"))
            assertEquals(before, saved)
            assertEquals("saved-id", saved.id)
            assertEquals("exact", saved.chemicalV3RevisionId)
        }
    }

    @Test fun neitherRevisionHasImageKeepsPlaceholder() = runBlocking {
        for (blank in listOf(null, "", " \n ")) {
            val exact = CatalogueRow(buildJsonObject { put("id", "exact"); put("product_id", "product"); put("front_label_image_path", blank?.let(::JsonPrimitive) ?: JsonNull) })
            val path = CatalogueFrontLabelResolver.resolve(exact,
                product = { id -> row("""{"id":"$id","approved_revision_id":"approved"}""") },
                revision = { id -> CatalogueRow(buildJsonObject { put("id", id); put("product_id", "product"); put("front_label_image_path", blank?.let(::JsonPrimitive) ?: JsonNull) }) })
            assertNull(path)
        }
    }

    @Test fun missingProductOrApprovedPointerDoesNotFetchOtherRevisions() = runBlocking {
        var revisionCalls = 0
        val missingProduct = row("""{"id":"exact"}""")
        assertNull(CatalogueFrontLabelResolver.resolve(missingProduct,
            product = { error("No product lookup expected") }, revision = { revisionCalls++; missingProduct }))
        val exact = row("""{"id":"exact","product_id":"product"}""")
        for (pointer in listOf(null, "exact")) {
            assertNull(CatalogueFrontLabelResolver.resolve(exact,
                product = { id -> CatalogueRow(buildJsonObject { put("id", id); put("approved_revision_id", pointer?.let(::JsonPrimitive) ?: JsonNull) }) },
                revision = { revisionCalls++; exact }))
        }
        assertEquals(0, revisionCalls)
    }

    @Test fun anotherProductsImageIsNeverUsed() = runBlocking {
        val exact = row("""{"id":"exact","product_id":"product"}""")
        val path = CatalogueFrontLabelResolver.resolve(exact,
            product = { id -> row("""{"id":"$id","approved_revision_id":"approved"}""") },
            revision = { id -> row("""{"id":"$id","product_id":"other-product","front_label_image_path":"labels/wrong.jpg"}""") })
        assertNull(path)
    }

    @Test fun failedFallbackLeavesExactDataAvailable() = runBlocking {
        val exact = row("""{"id":"exact","product_id":"product","activity_group_scheme":"frac","activity_groups":["7"]}""")
        val path = runCatching { CatalogueFrontLabelResolver.resolve(exact,
            product = { throw IllegalStateException("Unavailable") }, revision = { error("No revision expected after failure") }) }.getOrNull()
        assertNull(path)
        assertEquals("FRAC 7", exact.groupText)
    }
}
