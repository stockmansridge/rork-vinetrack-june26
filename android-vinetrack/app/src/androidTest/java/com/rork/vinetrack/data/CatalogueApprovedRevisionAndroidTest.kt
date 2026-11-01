package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.chemical.CatalogueRepository
import com.rork.vinetrack.data.model.SavedChemical
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Production reader and scoped disk cache; GET-only synthetic transport, no live fallback. */
@RunWith(AndroidJUnit4::class)
class CatalogueApprovedRevisionAndroidTest {
    @Test fun approvedReferenceRefusesForeignMissingAndUnapprovedWithoutRelinkingSavedChemical() = runBlocking {
        withTimeout(30_000) {
            val base = InstrumentationRegistry.getInstrumentation().targetContext
            val prefix = "pr35_catalogue_${UUID.randomUUID()}_"
            val names = linkedSetOf<String>()
            val context = object : ContextWrapper(base) {
                override fun getApplicationContext(): Context = this
                override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                    names.add(name)
                    return base.getSharedPreferences(prefix + name, mode)
                }
            }
            val product = "35000000-0000-4000-8000-000000000001"
            val oldRevision = "35000000-0000-4000-8000-000000000002"
            val approved = "35000000-0000-4000-8000-000000000003"
            val foreign = "35000000-0000-4000-8000-000000000004"
            val owner = "35000000-0000-4000-8000-000000000005"
            val vineyard = "35000000-0000-4000-8000-000000000006"
            var productBody = "[]"
            var revisionBody = "[]"
            var revisionReads = 0
            val client = HttpClient(MockEngine { request ->
                assertEquals("Reference lookup must never mutate", HttpMethod.Get, request.method)
                val response = when {
                    request.url.encodedPath.endsWith("/chemical_v3_products") -> {
                        assertEquals("eq.$product", request.url.parameters["id"])
                        productBody
                    }
                    request.url.encodedPath.endsWith("/chemical_v3_product_revisions") -> {
                        revisionReads++
                        assertEquals("eq.$approved", request.url.parameters["id"])
                        revisionBody
                    }
                    else -> error("Unexpected route; no live fallback")
                }
                respond(response, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            })
            try {
                SessionStore(context).save("synthetic-access", "synthetic-refresh", owner, null)
                val original = SupabaseClient.json.decodeFromString<SavedChemical>("""{"id":"$foreign","vineyard_id":"$vineyard","name":"Synthetic sulphur","chemical_v3_product_id":"$product","chemical_v3_revision_id":"$oldRevision","notes":"Keep operator notes","inventory_quantity":7,"inventory_unit":"kg","vineyard_preferred_rate":{"amount":350,"unit":"g","basis":"per_100_litres","note":"Explicit synthetic preference"},"rate_per_ha":null}""")
                assertTrue(SavedChemicalLocalStore(context).save(owner, vineyard, listOf(original)))
                val before = names.associateWith { base.getSharedPreferences(prefix + it, Context.MODE_PRIVATE).all.toMap() }
                SupabaseClient.installInstrumentationTransport(client)
                val repository = CatalogueRepository(context)
                val approvedProduct = """[{"id":"$product","status":"approved","approved_revision_id":"$approved"}]"""
                val approvedRevision = """[{"id":"$approved","product_id":"$product","review_status":"approved","default_rate_options":{"per_100_litres":[{"min_value":200,"max_value":600,"unit":"g"},{"value":400,"unit":"g","condition":"Synthetic second option"}]}}]"""
                productBody = approvedProduct
                revisionBody = approvedRevision
                val reference = repository.approvedRevisionForProduct(product)!!
                assertEquals(approved, reference.id)
                assertEquals(2, reference.rateRows("per_100_litres").size)
                assertEquals(200.0, reference.rateRows("per_100_litres")[0].number("min_value")!!, 0.0)
                assertNull("Range is not an automatically chosen dose", reference.rateRows("per_100_litres")[0].number("value"))
                for ((productResponse, revisionResponse) in listOf(
                    "[]" to approvedRevision,
                    """[{"id":"$foreign","status":"approved","approved_revision_id":"$approved"}]""" to approvedRevision,
                    """[{"id":"$product","status":"pending_review","approved_revision_id":"$approved"}]""" to approvedRevision,
                    """[{"id":"$product","status":"approved","approved_revision_id":null}]""" to approvedRevision,
                    approvedProduct to """[{"id":"$approved","product_id":"$foreign","review_status":"approved"}]""",
                    approvedProduct to """[{"id":"$approved","product_id":"$product","review_status":"pending_review"}]"""
                )) {
                    productBody = productResponse
                    revisionBody = revisionResponse
                    assertNull(repository.approvedRevisionForProduct(product))
                }
                productBody = approvedProduct
                revisionBody = "[]"
                assertTrue("Missing revision must refuse, never substitute", runCatching { repository.approvedRevisionForProduct(product) }.isFailure)
                revisionBody = """[{"id":"$foreign","product_id":"$product","review_status":"approved"}]"""
                assertTrue("Mismatched revision identity must refuse", runCatching { repository.approvedRevisionForProduct(product) }.isFailure)
                val reads = revisionReads
                assertTrue(runCatching { repository.approvedRevisionForProduct("invalid-product") }.isFailure)
                assertEquals(reads, revisionReads)
                assertEquals(listOf(original), SavedChemicalLocalStore(context).load(owner, vineyard))
                assertEquals(before, names.associateWith { base.getSharedPreferences(prefix + it, Context.MODE_PRIVATE).all.toMap() })
            } finally {
                SupabaseClient.installInstrumentationTransport(null)
                client.close()
                names.forEach { base.deleteSharedPreferences(prefix + it) }
            }
        }
    }
}
