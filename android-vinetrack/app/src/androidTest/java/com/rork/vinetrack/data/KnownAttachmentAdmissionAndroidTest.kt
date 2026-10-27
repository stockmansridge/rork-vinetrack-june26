package com.rork.vinetrack.data

import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.CleanExitFixtureApplication
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.chemical.ChemicalLabelAttachmentV2Repository
import com.rork.vinetrack.data.insights.VineyardInsightsSyncRepository
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

/** Bounded known families only; real repositories with no live transport fallback. */
class KnownAttachmentAdmissionAndroidTest {
    private val a = "11111111-1111-4111-8111-111111111111"
    private val b = "22222222-2222-4222-8222-222222222222"
    private val record = "33333333-3333-4333-8333-333333333333"
    private val owner = "44444444-4444-4444-8444-444444444444"

    @Test fun knownHeldFamiliesSendNoMutationsWithWritableOtherVineyardSelected() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            session.selectedVineyardId = b
            val gate = requireNotNull(OperationalWrites.authority)
            gate.handleServerCode("VT_READ_ONLY", a)
            gate.verified(b, VineyardOperationalAccess(true, true), true)
            var mutations = 0
            val client = HttpClient(MockEngine { request ->
                if (request.method != HttpMethod.Get) mutations++
                respond("[{\"id\":\"$record\",\"vineyard_id\":\"$a\"}]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                val logo = VineyardLogoRepository(session)
                val growth = GrowthStageImageRepository(session)
                val scout = VineyardInsightsSyncRepository(session)
                val labelPath = "$a/$record/$record.jpg"
                val operations: List<suspend () -> Unit> = listOf(
                    { logo.upload(a, byteArrayOf(1)); Unit },
                    { logo.delete(logo.storagePath(a)) },
                    { growth.uploadObject(a, "4", byteArrayOf(2)); Unit },
                    { growth.upsertImage(a, "4", growth.storagePath(a, "4")); Unit },
                    { growth.softDeleteImage(record) },
                    { growth.deleteObject(growth.storagePath(a, "4")) },
                    { scout.uploadPhotoBytes("$a/$record/photo.jpg", byteArrayOf(3)); Unit },
                    { scout.removePhotoObject("$a/$record/photo.jpg") },
                    { ChemicalLabelAttachmentV2Repository(session).upload(byteArrayOf(4), a, record, record, labelPath) },
                )
                for (operation in operations) {
                    var denied = false
                    try { operation() } catch (_: VineyardWriteAuthority.Restricted) { denied = true }
                    assertTrue("Known held family did not return a typed hold", denied)
                    assertEquals("Known held attachment reached mutation transport", 0, mutations)
                }
                assertFalse(gate.canWrite(a))
                assertTrue(gate.canWrite(b))
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun logoReceiptDuringExpiryCannotAuthorizeGrowthFollowup() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            val gate = requireNotNull(OperationalWrites.authority)
            var sends = 0
            val client = HttpClient(MockEngine { request ->
                assertEquals(owner, request.attributes[SupabaseClient.accountRequestScope].userId)
                assertEquals(a, request.attributes[SupabaseClient.operationalWriteVineyard])
                sends++
                gate.handleServerCode("VT_READ_ONLY", a)
                respond("{}", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                assertEquals("$a/logo.jpg", VineyardLogoRepository(session).upload(a, byteArrayOf(1)))
                try { GrowthStageImageRepository(session).upsertImage(a, "4", "$a/el-stages/4.jpg"); fail("Follow-up escaped expiry") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                assertEquals(1, sends)
                val restored = SessionStore(app)
                try { VineyardLogoRepository(restored).delete("$a/logo.jpg"); fail("Recreation released hold") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                assertEquals(1, sends)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }
}
