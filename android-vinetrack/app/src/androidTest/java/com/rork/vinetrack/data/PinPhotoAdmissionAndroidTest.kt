package com.rork.vinetrack.data

import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.CleanExitFixtureApplication
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

/** Production storage repository, disposable preferences, synthetic HTTP only. */
class PinPhotoAdmissionAndroidTest {
    private val a = "11111111-1111-4111-8111-111111111111"
    private val b = "22222222-2222-4222-8222-222222222222"
    private val pin = "33333333-3333-4333-8333-333333333333"
    private val owner = "44444444-4444-4444-8444-444444444444"

    @Test fun idOnlyPhotoAndDeleteResolveHeldActualAInsteadOfSelectedB() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            session.selectedVineyardId = b
            val gate = requireNotNull(OperationalWrites.authority)
            gate.handleServerCode("VT_READ_ONLY", a)
            gate.verified(b, VineyardOperationalAccess(true, true), true)
            var writes = 0
            val client = HttpClient(MockEngine { request ->
                if (request.method == io.ktor.http.HttpMethod.Get) {
                    respond("[{\"id\":\"$pin\",\"vineyard_id\":\"$a\"}]", HttpStatusCode.OK,
                        io.ktor.http.headersOf("Content-Type", "application/json"))
                } else {
                    writes++
                    respond("[]", HttpStatusCode.OK, io.ktor.http.headersOf("Content-Type", "application/json"))
                }
            }) { install(io.ktor.client.plugins.contentnegotiation.ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                val pins = PinRepository(session)
                val growth = GrowthStageRecordRepository(session)
                val operations: List<suspend () -> Unit> = listOf(
                    { pins.updatePhotoPath(pin, "$a/pins/$pin/photo.jpg"); Unit },
                    { growth.updatePhotoPaths(pin, listOf("$a/growth/$pin/photo.jpg")); Unit },
                    { pins.softDeletePin(pin) },
                    { growth.softDeleteGrowthStageRecord(pin) },
                    { pins.setRowSegments(pin, emptyList()) },
                )
                for (operation in operations) {
                    var held = false
                    try { operation() }
                    catch (_: VineyardWriteAuthority.Restricted) { held = true }
                    catch (_: BackendError) { /* A post-send failure is not safe admission. */ }
                    assertEquals("ID-only mutation sent before checking actual ownership", 0, writes)
                    assertTrue("ID-only mutation escaped actual owning vineyard", held)
                }
                assertEquals(0, writes)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun structuredStorageRejectionAndReceiptKeepExactScopeAndAccount() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            val gate = requireNotNull(OperationalWrites.authority)
            val repo = PinPhotoRepository(session)
            val path = repo.growthStoragePath(a, pin, "original-revision")
            val bytes = byteArrayOf(5, 6, 7)
            var sends = 0
            var mode = "ordinary"
            val client = HttpClient(MockEngine { request ->
                sends++
                assertEquals(a, request.attributes[SupabaseClient.operationalWriteVineyard])
                assertEquals(owner, request.attributes[SupabaseClient.accountRequestScope].userId)
                assertEquals("/storage/v1/object/${PinPhotoRepository.BUCKET}/$path", request.url.encodedPath)
                when (mode) {
                    "ordinary" -> respond("{\"code\":\"42501\"}", HttpStatusCode.Forbidden)
                    "expiry" -> respond("{\"code\":\"VT_READ_ONLY\"}", HttpStatusCode.Forbidden)
                    "stale" -> {
                        session.userId = b
                        respond("{\"code\":\"VT_READ_ONLY\"}", HttpStatusCode.Forbidden)
                    }
                    else -> {
                        assertArrayEquals(bytes, (request.body as io.ktor.http.content.ByteArrayContent).bytes())
                        gate.handleServerCode("VT_READ_ONLY", a)
                        respond("{}", HttpStatusCode.OK)
                    }
                }
            })
            SupabaseClient.installInstrumentationTransport(client)
            try {
                try { repo.delete(path); fail("Expected ordinary permission failure") }
                catch (_: BackendError.Unauthorized) { }
                assertTrue(gate.canWrite(a))
                mode = "expiry"
                try { repo.uploadAtPath(path, bytes); fail("Expected structured hold") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                assertFalse(gate.canWrite(a))
                assertTrue(gate.canWrite(b))
                gate.verified(a, VineyardOperationalAccess(true, true), true)
                mode = "stale"
                try { repo.delete(path); fail("Expected stale account rejection") }
                catch (_: BackendError.Unauthorized) { }
                assertTrue(gate.canWrite(a)) // New account did not inherit the old rejection.
                session.userId = owner
                assertTrue(gate.canWrite(a))
                mode = "receipt"
                assertEquals(path, repo.uploadAtPath(path, bytes))
                val afterSuccess = sends
                try { repo.delete(path); fail("Subsequent mutation escaped the hold") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                assertEquals(afterSuccess, sends)
                for (invalid in listOf("$a/pins/../photo.jpg", "$a/pins/$pin/photo.jpg?scope=$b", "$a/growth/$pin/../photo.jpg")) {
                    try { repo.uploadAtPath(invalid, bytes); fail("Unresolved object scope reached HTTP") }
                    catch (_: VineyardWriteAuthority.Restricted) { }
                }
                assertEquals(afterSuccess, sends)
                assertArrayEquals(byteArrayOf(5, 6, 7), bytes)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun heldUploadAndDeleteNeverReachTransportOrBorrowWritableB() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            val gate = requireNotNull(OperationalWrites.authority)
            val repo = PinPhotoRepository(session)
            val path = repo.storagePath(a, pin, "original-revision")
            val bytes = byteArrayOf(1, 2, 3)
            var sends = 0
            val client = HttpClient(MockEngine { sends++; respond("{}", HttpStatusCode.OK) })
            SupabaseClient.installInstrumentationTransport(client)
            try {
                gate.handleServerCode("VT_READ_ONLY", a)
                gate.verified(b, VineyardOperationalAccess(true, true), true)
                for (delete in listOf(false, true)) {
                    var held = false
                    try { if (delete) repo.delete(path) else repo.uploadAtPath(path, bytes) }
                    catch (_: VineyardWriteAuthority.Restricted) { held = true }
                    assertTrue("Held storage mutation escaped admission", held)
                }
                assertEquals(0, sends)
                assertArrayEquals(byteArrayOf(1, 2, 3), bytes)
                // Reconstruct the authority from its durable ledger; cache absence is not release.
                val restoredSession = SessionStore(app)
                val restoredRepo = PinPhotoRepository(restoredSession)
                var heldAfterRestart = false
                try { restoredRepo.uploadAtPath(path, bytes) }
                catch (_: VineyardWriteAuthority.Restricted) { heldAfterRestart = true }
                assertTrue(heldAfterRestart)
                assertEquals(0, sends)
                requireNotNull(OperationalWrites.authority).verified(a, VineyardOperationalAccess(true, true), true)
                assertEquals(path, restoredRepo.uploadAtPath(path, bytes))
                assertEquals(1, sends)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }
}
