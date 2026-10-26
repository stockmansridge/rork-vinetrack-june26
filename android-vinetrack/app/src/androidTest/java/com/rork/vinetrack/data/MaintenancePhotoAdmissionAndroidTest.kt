package com.rork.vinetrack.data

import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.CleanExitFixtureApplication
import com.rork.vinetrack.data.auth.SessionStore
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

/** Real repositories; no live network fallback and no retained customer data. */
class MaintenancePhotoAdmissionAndroidTest {
    private val a = "11111111-1111-4111-8111-111111111111"
    private val b = "22222222-2222-4222-8222-222222222222"
    private val log = "33333333-3333-4333-8333-333333333333"
    private val owner = "44444444-4444-4444-8444-444444444444"

    @Test fun heldForegroundCoalescingAndCancellationRetainExactOriginalQueue() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
        app.resetFixture()
        val session = SessionStore(app)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        val pending = PendingWriteRepository(app)
        val repo = MaintenanceLogRepository(session)
        val creates = MaintenanceLogCreateSync(repo, pending)
        val updates = MaintenanceLogUpdateSync(repo, pending)
        val deletes = MaintenanceLogDeleteSync(repo, pending)
        val input = MaintenanceLogRepository.MaintenanceInput("Original", null, null, 2.0, null, "Retain", "", 1.0, 3.0, "2026-10-24T00:00:00Z")
        creates.enqueue(log, a, input, "2026-10-24T00:00:00Z")
        val frozen = pending.list().toList()
        val disk = app.getSharedPreferences("vinetrack_pending_writes", android.content.Context.MODE_PRIVATE).all.toMap()
        requireNotNull(OperationalWrites.authority).handleServerCode("VT_READ_ONLY", a)
        val operations = listOf<() -> Unit>(
            { creates.foldEdit(log, input.copy(itemName = "Replace"), "later"); Unit },
            { creates.enqueue(log, a, input, "later"); Unit },
            { updates.enqueue(log, a, input, "later"); Unit },
            { deletes.cancelLocalCreate(log); Unit },
        )
        for (operation in operations) {
            try { operation() } catch (_: VineyardWriteAuthority.Restricted) { }
            assertEquals("Held foreground path changed the original queue", frozen, pending.list())
            assertEquals(disk, app.getSharedPreferences("vinetrack_pending_writes", android.content.Context.MODE_PRIVATE).all)
        }
    }

    @Test fun heldUploadDeleteAndReferenceSendZeroMutations() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            session.selectedVineyardId = b
            val gate = requireNotNull(OperationalWrites.authority)
            gate.handleServerCode("VT_READ_ONLY", a)
            gate.verified(b, VineyardOperationalAccess(true, true), true)
            val repo = MaintenancePhotoRepository(session)
            val path = repo.storagePath(a, log)
            val bytes = byteArrayOf(1, 2, 3)
            var mutations = 0
            val client = HttpClient(MockEngine { request ->
                if (request.method != HttpMethod.Get) mutations++
                respond("[{\"id\":\"$log\",\"vineyard_id\":\"$a\"}]", HttpStatusCode.OK,
                    headersOf("Content-Type", "application/json"))
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                val operations: List<suspend () -> Unit> = listOf(
                    { repo.upload(a, log, bytes); Unit },
                    { repo.delete(path) },
                    { MaintenanceLogRepository(session).updatePhotoPath(log, null); Unit },
                )
                for (operation in operations) {
                    var held = false
                    try { operation() } catch (_: VineyardWriteAuthority.Restricted) { held = true }
                    assertEquals("Held maintenance mutation reached transport", 0, mutations)
                    assertTrue("Held original was not classified separately", held)
                }
                assertArrayEquals(byteArrayOf(1, 2, 3), bytes)
                val restored = MaintenancePhotoRepository(SessionStore(app))
                try { restored.delete(path); fail("Restart released held work") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                assertEquals(0, mutations)
                requireNotNull(OperationalWrites.authority).verified(a, VineyardOperationalAccess(true, true), true)
                assertEquals(path, restored.upload(a, log, bytes))
                assertEquals(1, mutations)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun receiptSurvivesExpiryButReferenceAndDeleteRemainHeld() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            val gate = requireNotNull(OperationalWrites.authority)
            val repo = MaintenancePhotoRepository(session)
            val path = repo.storagePath(a, log)
            var mutations = 0
            val client = HttpClient(MockEngine { request ->
                assertEquals(owner, request.attributes[SupabaseClient.accountRequestScope].userId)
                if (request.method == HttpMethod.Get) {
                    respond("[{\"id\":\"$log\",\"vineyard_id\":\"$a\"}]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
                } else {
                    mutations++
                    assertEquals(a, request.attributes[SupabaseClient.operationalWriteVineyard])
                    gate.handleServerCode("VT_READ_ONLY", a)
                    respond("{}", HttpStatusCode.OK)
                }
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                assertEquals(path, repo.upload(a, log, byteArrayOf(4, 5)))
                try { MaintenanceLogRepository(session).updatePhotoPath(log, path); fail("Reference escaped expiry") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                try { repo.delete(path); fail("Delete escaped expiry") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                assertEquals(1, mutations)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun structuredExpiryIsHeldButOrdinaryAndStaleErrorsDoNotRetargetAuthority() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            val gate = requireNotNull(OperationalWrites.authority)
            val repo = MaintenancePhotoRepository(session)
            var mode = "ordinary"
            var mutations = 0
            val client = HttpClient(MockEngine { request ->
                assertEquals(owner, request.attributes[SupabaseClient.accountRequestScope].userId)
                if (request.method == HttpMethod.Get) {
                    respond("[{\"id\":\"$log\",\"vineyard_id\":\"$a\"}]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
                } else {
                    mutations++
                    assertEquals(a, request.attributes[SupabaseClient.operationalWriteVineyard])
                    if (mode == "stale") session.userId = b
                    respond(if (mode == "ordinary") "{\"code\":\"42501\",\"message\":\"VT_READ_ONLY\"}" else "{\"code\":\"VT_READ_ONLY\"}", HttpStatusCode.Forbidden)
                }
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                try { repo.upload(a, log, byteArrayOf(1)); fail("Expected ordinary rejection") }
                catch (_: BackendError.Unauthorized) { }
                assertTrue(gate.canWrite(a))
                mode = "expiry"
                try { repo.delete(repo.storagePath(a, log)); fail("Expected structured hold") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                assertFalse(gate.canWrite(a))
                gate.verified(a, VineyardOperationalAccess(true, true), true)
                mode = "stale"
                try { repo.upload(a, log, byteArrayOf(1)); fail("Expected stale rejection") }
                catch (_: BackendError.Unauthorized) { }
                assertTrue(gate.canWrite(a))
                session.userId = owner
                assertTrue(gate.canWrite(a))
                assertEquals(3, mutations)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun heldDeleteWithDependencyDoesNotRewriteOriginal() = runBlocking {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
        app.resetFixture()
        val session = SessionStore(app)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        val pending = PendingWriteRepository(app)
        pending.configureReplayScope { session.userId?.let { PendingWriteRepository.ReplayScope(it, 1) } }
        val repo = MaintenanceLogRepository(session)
        val input = MaintenanceLogRepository.MaintenanceInput("Pump", null, null, 0.0, null, "Service", "", 0.0, 0.0, "2026-10-01")
        MaintenanceLogCreateSync(repo, pending).enqueue(log, a, input, "2026-10-01T03:04:05Z")
        // Retained legacy ID-only bytes, not a newly admitted foreground delete.
        pending.enqueue(com.rork.vinetrack.data.model.PendingEntityType.MAINTENANCE_LOG,
            com.rork.vinetrack.data.model.PendingOpType.DELETE, "{\"maintenanceLogId\":\"$log\"}", log)
        val original = pending.list()
        requireNotNull(OperationalWrites.authority).handleServerCode("VT_READ_ONLY", a)
        val client = HttpClient(MockEngine { fail("Dependent held delete reached transport"); error("No live fallback") })
        SupabaseClient.installInstrumentationTransport(client)
        try {
            MaintenanceLogDeleteSync(repo, pending).replayAll { fail("Held delete published success") }
            assertEquals("Held dependency rewrote original queue evidence", original, pending.list())
        } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
    }

    @Test fun heldMetadataReplayRetainsOriginalThroughRepositoryRecreation() = runBlocking {
        exerciseMetadataReplay(initiallyHeld = true)
    }

    @Test fun structuredMetadataRejectionRestoresOriginalWithoutChargingRetries() = runBlocking {
        exerciseMetadataReplay(initiallyHeld = false)
    }

    private suspend fun exerciseMetadataReplay(initiallyHeld: Boolean) = withTimeout(20_000) {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
        app.resetFixture()
        val session = SessionStore(app)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        session.selectedVineyardId = b
        val gate = requireNotNull(OperationalWrites.authority)
        val repo = MaintenanceLogRepository(session)
        for (op in listOf("CREATE", "UPDATE", "DELETE")) {
            gate.verified(a, VineyardOperationalAccess(true, true), true)
            val pending = PendingWriteRepository(app)
            pending.configureReplayScope { session.userId?.let { PendingWriteRepository.ReplayScope(it, 1) } }
            val input = MaintenanceLogRepository.MaintenanceInput("Original pump", null, null, 2.5, 7.0,
                "Original service", "Original seal", 12.0, 8.0, "2026-10-01")
            val create = MaintenanceLogCreateSync(repo, pending)
            val update = MaintenanceLogUpdateSync(repo, pending)
            val delete = MaintenanceLogDeleteSync(repo, pending)
            val row = when (op) {
                "CREATE" -> create.enqueue(log, a, input, "2026-10-01T03:04:05Z")
                "UPDATE" -> update.enqueue(log, a, input, "2026-10-01T03:04:05Z")
                else -> pending.enqueue(com.rork.vinetrack.data.model.PendingEntityType.MAINTENANCE_LOG,
                    com.rork.vinetrack.data.model.PendingOpType.DELETE, "{\"maintenanceLogId\":\"$log\"}", log)
            }
            pending.incrementAttempt(row.id)
            pending.updateStatus(row.id, com.rork.vinetrack.data.model.PendingWriteStatus.FAILED, "Original error")
            val original = pending.list().single()
            var callbacks = 0
            var mutations = 0
            var reject = !initiallyHeld
            val client = HttpClient(MockEngine { request ->
                if (request.method == HttpMethod.Get) {
                    respond("[{\"id\":\"$log\",\"vineyard_id\":\"$a\"}]", HttpStatusCode.OK,
                        headersOf("Content-Type", "application/json"))
                } else {
                    mutations++
                    assertEquals(owner, request.attributes[SupabaseClient.accountRequestScope].userId)
                    assertEquals(a, request.attributes[SupabaseClient.operationalWriteVineyard])
                    respond(if (reject) "{\"code\":\"VT_READ_ONLY\"}" else
                        "[{\"id\":\"$log\",\"vineyard_id\":\"$a\",\"item_name\":\"Original pump\"}]",
                        if (reject) HttpStatusCode.Forbidden else HttpStatusCode.OK,
                        headersOf("Content-Type", "application/json"))
                }
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            suspend fun replay(queue: PendingWriteRepository) {
                when (op) {
                    "CREATE" -> MaintenanceLogCreateSync(repo, queue).replayAll { callbacks++ }
                    "UPDATE" -> MaintenanceLogUpdateSync(repo, queue).replayAll { callbacks++ }
                    else -> MaintenanceLogDeleteSync(repo, queue).replayAll { callbacks++ }
                }
            }
            try {
                if (initiallyHeld) gate.handleServerCode("VT_READ_ONLY", a)
                replay(pending)
                assertEquals("$op changed original after hold", listOf(original), pending.list())
                assertEquals(if (initiallyHeld) 0 else 1, mutations)
                assertEquals(0, callbacks)
                reject = false
                gate.verified(b, VineyardOperationalAccess(true, true), true)
                val recreated = PendingWriteRepository(app)
                recreated.configureReplayScope { session.userId?.let { PendingWriteRepository.ReplayScope(it, 1) } }
                replay(recreated)
                assertEquals("$op lost original on recreation", listOf(original), recreated.list())
                assertEquals(if (initiallyHeld) 0 else 1, mutations)
                gate.verified(a, VineyardOperationalAccess(true, true), true)
                replay(recreated)
                replay(recreated)
                assertTrue("$op did not acknowledge original", recreated.list().isEmpty())
                assertEquals(if (initiallyHeld) 1 else 2, mutations)
                assertEquals(1, callbacks)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun staleAccountMetadataSuccessDoesNotAcknowledgeQueueOrPublishCallback() = runBlocking {
        withTimeout(20_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            for (op in listOf("CREATE", "UPDATE", "DELETE")) {
                app.resetFixture()
                val session = SessionStore(app)
                session.save("synthetic-access", "synthetic-refresh", owner, null)
                val pending = PendingWriteRepository(app)
                pending.configureReplayScope { session.userId?.let { PendingWriteRepository.ReplayScope(it, 1) } }
                val repo = MaintenanceLogRepository(session)
                val input = MaintenanceLogRepository.MaintenanceInput("Pump", null, null, 0.0, null,
                    "Service", "", 0.0, 0.0, "2026-10-01")
                when (op) {
                    "CREATE" -> MaintenanceLogCreateSync(repo, pending).enqueue(log, a, input, "2026-10-01T03:04:05Z")
                    "UPDATE" -> MaintenanceLogUpdateSync(repo, pending).enqueue(log, a, input, "2026-10-01T03:04:05Z")
                    else -> MaintenanceLogDeleteSync(repo, pending).enqueue(log, a)
                }
                var claimed: com.rork.vinetrack.data.model.PendingWrite? = null
                var callbacks = 0
                var mutations = 0
                val client = HttpClient(MockEngine { request ->
                    if (request.method != HttpMethod.Get) {
                        mutations++
                        claimed = pending.list().single()
                        session.userId = b
                    }
                    respond("[{\"id\":\"$log\",\"vineyard_id\":\"$a\"}]", HttpStatusCode.OK,
                        headersOf("Content-Type", "application/json"))
                }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
                SupabaseClient.installInstrumentationTransport(client)
                try {
                    when (op) {
                        "CREATE" -> MaintenanceLogCreateSync(repo, pending).replayAll { callbacks++ }
                        "UPDATE" -> MaintenanceLogUpdateSync(repo, pending).replayAll { callbacks++ }
                        else -> MaintenanceLogDeleteSync(repo, pending).replayAll { callbacks++ }
                    }
                    assertEquals(1, mutations)
                    assertNotNull(claimed)
                    assertEquals(listOf(claimed), pending.list())
                    assertEquals(0, callbacks)
                } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
            }
        }
    }

    @Test fun malformedPathsAndMismatchedRecordNeverMutate() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            var mutations = 0
            val client = HttpClient(MockEngine { request ->
                if (request.method != HttpMethod.Get) mutations++
                respond("[{\"id\":\"$log\",\"vineyard_id\":\"$b\"}]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                val repo = MaintenancePhotoRepository(session)
                for (path in listOf("$a/maintenance/../photo.jpg", "$a/maintenance/$log/photo.jpg?x=$b", "$a/maintenance/$log/photo.jpg")) {
                    try { repo.delete(path); fail("Invalid or wrong-owner path admitted") }
                    catch (_: VineyardWriteAuthority.Restricted) { }
                }
                try { repo.upload(a, log, byteArrayOf(8)); fail("Wrong-owner upload admitted") }
                catch (_: VineyardWriteAuthority.Restricted) { }
                assertEquals(0, mutations)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }
}
