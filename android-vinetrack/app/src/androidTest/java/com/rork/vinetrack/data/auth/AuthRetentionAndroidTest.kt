package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.PendingPhotoRepository
import com.rork.vinetrack.data.PendingPhotoStore
import com.rork.vinetrack.data.PendingWriteRepository
import com.rork.vinetrack.data.PendingWriteStore
import com.rork.vinetrack.data.PinCreateSync
import com.rork.vinetrack.data.PinRepository
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import com.rork.vinetrack.data.SupabaseClient
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.HttpStatusCode
import io.ktor.http.encodedPath
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith

/** Real Android session/preferences adapter, confined to random hotfix-owned names; no Activity/network. */
@RunWith(AndroidJUnit4::class)
class AuthRetentionAndroidTest {
    private lateinit var context: FixtureContext
    private lateinit var root: File

    @Before fun setup() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        root = File(base.filesDir, "auth-retention-${UUID.randomUUID()}").also { check(it.mkdirs()) }
        context = FixtureContext(base, root, "auth_retention_${UUID.randomUUID()}_")
    }

    @After fun cleanup() {
        if (!::context.isInitialized) return
        check(context.prefix.startsWith("auth_retention_") && root.name.startsWith("auth-retention-"))
        context.names.forEach { context.base.deleteSharedPreferences(context.prefix + it) }
        check(root.canonicalPath.startsWith(context.base.filesDir.canonicalPath + File.separator))
        root.deleteRecursively()
    }

    @Test fun legitimateAdmissionContentionPersistsTripAndPhotoWithoutRevokingAuthority() {
        val session = SessionStore(context)
        session.save("synthetic-access", "synthetic-refresh", "account-A", null)
        val authority = requireNotNull(session.accountAccess())
        val trips = com.rork.vinetrack.data.ActiveTripStore(context)
        val photos = PendingPhotoRepository(context)
        val image = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        val jpeg = try {
            ByteArrayOutputStream().use { bytes ->
                check(image.compress(Bitmap.CompressFormat.JPEG, 90, bytes)); bytes.toByteArray()
            }
        } finally { image.recycle() }
        val stages = java.util.concurrent.CopyOnWriteArrayList<String>()
        val previousObserver = CleanExitDiagnostics.observer
        CleanExitDiagnostics.observer = stages::add
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val holderFailure = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
        val holder = Thread {
            try {
                check(session.withAccountAccess(authority) {
                    entered.countDown()
                    check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
                })
            } catch (failure: Throwable) { holderFailure.set(failure) }
        }
        val beforeSession = context.getSharedPreferences("vinetrack_session", 0).all.toMap()
        val waiting = java.util.concurrent.CountDownLatch(2)
        CleanExitDiagnostics.observer = { stage -> stages.add(stage); if (stage == "field.commit.waiting") waiting.countDown() }
        val failures = java.util.concurrent.CopyOnWriteArrayList<Throwable>()
        val done = java.util.concurrent.CountDownLatch(2)
        val trip = com.rork.vinetrack.data.model.Trip(
            "active", "vineyard", paddockId = "block", paddockName = "Original block", paddockIds = listOf("block", "block-2"),
            isActive = true, startTime = "2026-10-12T00:00:00Z", operatorUserId = "account-A",
            pathPoints = listOf(com.rork.vinetrack.data.model.CoordinatePoint(-33.12, 149.25), com.rork.vinetrack.data.model.CoordinatePoint(-33.13, 149.26)),
            totalDistance = 143.567, completedPaths = listOf(1.5), skippedPaths = listOf(2.5),
            rowSequence = listOf(1.5, 2.5, 3.5), sequenceIndex = 2, currentRowNumber = 3.5,
            tankSessions = listOf(com.rork.vinetrack.data.model.TankSession(id = "original-tank", tankNumber = 1, startTime = "2026-10-12T00:03:00Z")),
            activeTankNumber = 1, totalTanks = 2, startEngineHours = 123.45,
            tripTitle = "Original metadata", completionNotes = "Original notes", workTaskId = "original-task", clientUpdatedAt = "2026-10-12T00:04:00Z",
        )
        val workers = listOf(
            Thread { try { assertTrue(trips.saveDurably("account-A", "vineyard", trip)) } catch (failure: Throwable) { failures.add(failure) } finally { done.countDown() } },
            Thread { try { photos.enqueue("pending-pin", "vineyard", jpeg) } catch (failure: Throwable) { failures.add(failure) } finally { done.countDown() } },
        )
        try {
            holder.start()
            assertTrue("Authorised publication never acquired the lock", entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            workers.forEach(Thread::start)
            assertTrue("Original saves did not defer", waiting.await(2, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals("A save reported completion before admission", 2L, done.count)
            assertNull(trips.load())
            assertTrue(photos.list().isEmpty())
        } finally {
            release.countDown()
            holder.join(5_000)
            workers.forEach { it.join(5_000) }
            CleanExitDiagnostics.observer = previousObserver
        }
        assertFalse("Authorised publication did not finish", holder.isAlive)
        assertNull(holderFailure.get())
        assertTrue("Original field save failed: ${failures.map { it.javaClass.simpleName }}", failures.isEmpty())
        assertTrue(workers.none(Thread::isAlive))
        assertEquals(0L, done.count)
        assertFalse(stages.contains("field.commit.obsolete"))
        assertTrue(session.isAccountAccessCurrent(authority))
        assertFalse(session.retentionGuard.isLocked)
        assertTrue(session.hasSession)
        assertEquals(beforeSession, context.getSharedPreferences("vinetrack_session", 0).all)
        val snapshot = requireNotNull(com.rork.vinetrack.data.ActiveTripStore(context).load())
        assertEquals("account-A", snapshot.ownerUserId)
        assertEquals("vineyard", snapshot.vineyardId)
        assertEquals(trip, snapshot.trip)
        val photo = PendingPhotoRepository(context).list().single()
        assertEquals("pending-pin", photo.clientPinId)
        assertEquals("vineyard", photo.vineyardId)
        assertArrayEquals(jpeg, File(photo.localPath).readBytes())
        assertEquals(photos.list().single(), photo)
        assertTrue(File(root, "pending_pin_photos").listFiles().orEmpty().none { it.name.endsWith(".capture") })
    }

    @Test fun rejectedSessionPreservesRealQueuePhotoMetadataAndJpegAndBlocksReauthentication() {
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "account-A", "synthetic@example.invalid")
        val writes = PendingWriteRepository(PendingWriteStore(context))
        val row = PinCreateSync(writes).enqueue(PinRepository.PinInput("pin", "vineyard"))
        val image = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        val jpeg = try {
            ByteArrayOutputStream().use { bytes ->
                check(image.compress(Bitmap.CompressFormat.JPEG, 90, bytes)); bytes.toByteArray()
            }
        } finally { image.recycle() }
        val photos = PendingPhotoRepository(root, PendingPhotoStore(context))
        val photo = photos.enqueue("pin", "vineyard", jpeg)
        val rawWrites = context.getSharedPreferences("vinetrack_pending_writes", 0).all.toMap()
        val rawPhotos = context.getSharedPreferences("vinetrack_pending_photos", 0).all.toMap()
        session.clear()
        val recreated = SessionStore(context)
        assertTrue(recreated.retentionGuard.isLocked)
        assertFalse(recreated.hasSession)
        assertNull(recreated.userId)
        for (account in listOf("account-A", "account-B")) {
            denied { recreated.save("new-access", "new-refresh", account, "synthetic@example.invalid") }
        }
        assertEquals(rawWrites, context.getSharedPreferences("vinetrack_pending_writes", 0).all)
        assertEquals(rawPhotos, context.getSharedPreferences("vinetrack_pending_photos", 0).all)
        assertArrayEquals(jpeg, File(photo.localPath).readBytes())
        assertEquals(row, PendingWriteStore(context).load().single())
        assertNull(context.getSharedPreferences("vinetrack_session", 0).getString("access_token", null))
        assertTrue(context.getSharedPreferences("vinetrack_session", 0).getBoolean("field_recovery_locked_v1", false))
    }

    @Test fun differentAccountCannotOverwriteExistingSessionEvenWithoutUiSignOut() {
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "account-A", null)
        denied { SessionStore(context).save("access-B", "refresh-B", "account-B", null) }
        assertTrue(session.retentionGuard.isLocked)
        assertFalse(session.hasSession)
        assertFalse(context.getSharedPreferences("vinetrack_session", 0).all.containsValue("access-B"))
    }

    @Test fun sameAccountTokenRefreshRemainsAllowedBeforeRejection() {
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "account-A", null)
        SessionStore(context).save("refreshed-A", "refreshed-refresh-A", "account-A", null)
        assertEquals("refreshed-A", session.accessToken)
        assertFalse(session.retentionGuard.isLocked)
        assertFalse(session.retentionGuard.canSignOut())
    }

    @Test fun historicalTokenRemovalWithSurvivingContextLocksBeforeBusinessConstruction() {
        check(context.getSharedPreferences("vinetrack_session", 0).edit()
            .putString("vineyard_cache_owner", "account-A").commit())
        val session = SessionStore(context)
        assertTrue(session.retentionGuard.isLocked)
        denied { session.retentionGuard.requireUnlocked() }
        denied { session.save("access-B", "refresh-B", "account-B", null) }
    }

    @Test fun originalAccountCallbackScopeSurvivesRefreshButNotRevocationOrRecreation() {
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "account-A", null)
        val access = requireNotNull(session.accountAccess())
        SessionStore(context).save("new-A", "new-refresh-A", "account-A", null)
        var callbacks = 0
        assertTrue(SessionStore(context).withAccountAccess(access) { callbacks++ })
        session.clear()
        assertFalse(SessionStore(context).withAccountAccess(access) { callbacks++ })
        assertNull(SessionStore(context).accountAccess())
        assertEquals(1, callbacks)
        assertTrue(context.getSharedPreferences("vinetrack_session", 0).getBoolean("field_recovery_locked_v1", false))
    }

    @Test fun actualDelayedAcknowledgementAfterSessionClearRetainsRealPersistedMarker() {
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "account-A", null)
        val access = requireNotNull(session.accountAccess())
        val store = com.rork.vinetrack.data.SprayTankActualStore(context)
        store.configureAccountAccess(session::accountAccess)
        val actual = com.rork.vinetrack.data.model.SprayTankActual(
            "actual", "vineyard", "spray", "trip", "tank", 1, waterVolumeL = 123.45,
            chemicals = emptyList(), confirmedAt = "2026-10-10T00:00:00Z", confirmedBy = "account-A")
        assertTrue(store.save(actual))
        assertEquals(listOf(actual), store.pendingOwned(access))
        val prefs = context.getSharedPreferences("vinetrack_spray_tank_actuals", 0)
        val before = prefs.all.toMap()
        session.clear()
        assertFalse(session.withAccountAccess(access) { store.markSyncedIfCurrent(actual) })
        assertEquals(before, prefs.all)
        val recreated = com.rork.vinetrack.data.SprayTankActualStore(context)
        assertEquals(listOf(actual), recreated.pending())
        // Explicit original-confirmation authorship survives disk recreation, but the revoked
        // runtime scope still cannot acknowledge it. A freshly authenticated A is required.
        assertEquals(listOf(actual), recreated.pendingOwned(access))
        assertFalse(SessionStore(context).withAccountAccess(access) { recreated.markSyncedIfCurrent(actual) })
    }

    @Test fun rejectionAtomicallyRetainsOriginalSupabaseUuidAndNeverAdoptsCacheOwner() {
        val original = "11111111-1111-4111-8111-111111111111"
        val session = SessionStore(context)
        session.save("access", "refresh", original, "same@example.invalid")
        val field = context.getSharedPreferences("vinetrack_pin_capture_evidence", 0)
        check(field.edit().putString("pin_capture_evidence_json", "unreadable-retained-evidence").commit())
        session.clear()
        val prefs = context.getSharedPreferences("vinetrack_session", 0)
        assertTrue(prefs.getBoolean("field_recovery_locked_v1", false))
        assertEquals(original, prefs.getString("field_recovery_principal_v1", null))
        assertNull(prefs.getString("refresh_token", null))
        repeat(3) {
            val restartedAdapter = SessionStore(context)
            restartedAdapter.clear()
            assertEquals(original, restartedAdapter.recoveryPrincipal)
            denied { restartedAdapter.save("B-access", "B-refresh", "22222222-2222-4222-8222-222222222222", "same@example.invalid") }
        }
        assertEquals("unreadable-retained-evidence", field.getString("pin_capture_evidence_json", null))
    }

    @Test fun cacheOwnerWithoutSessionUuidNeverBecomesRecoveryPrincipal() {
        val prefs = context.getSharedPreferences("vinetrack_session", 0)
        check(prefs.edit().putString("vineyard_cache_owner", "11111111-1111-4111-8111-111111111111").commit())
        val session = SessionStore(context)
        assertTrue(session.retentionGuard.isLocked)
        assertNull(session.recoveryPrincipal)
        assertFalse(prefs.contains("field_recovery_principal_v1"))
    }

    @Test fun inconclusiveRefreshDenialsAndRateLimitsKeepProductionSession() = runBlocking {
        check(SupabaseClient.isConfigured)
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "11111111-1111-4111-8111-111111111111", null)
        for ((status, body) in listOf(
            400 to "{\"error\":\"invalid_grant\"}",
            401 to "<html>gateway denied</html>",
            403 to "{\"code\":\"insufficient_aal\"}",
            429 to "{\"code\":\"over_request_rate_limit\"}",
            503 to "{\"code\":\"refresh_token_not_found\"}",
            400 to "{\"message\":\"refresh token expired\"}",
        )) {
            val client = mockAuthClient { _, _ -> status to body }
            try {
                assertEquals(SessionValidity.Unreachable, AuthRepository(session, client).revalidateSession())
                assertEquals("access-A", session.accessToken)
                assertEquals("refresh-A", session.refreshToken)
                assertFalse(session.retentionGuard.isLocked)
            } finally { client.close() }
        }
    }

    @Test fun structuredRejectionUsesProductionRefreshAndRetainsPendingBytes() = runBlocking {
        check(SupabaseClient.isConfigured)
        val owner = "11111111-1111-4111-8111-111111111111"
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", owner, null)
        val writes = PendingWriteRepository(PendingWriteStore(context))
        PinCreateSync(writes).enqueue(PinRepository.PinInput("pin", "vineyard"))
        val before = context.getSharedPreferences("vinetrack_pending_writes", 0).all.toMap()
        val drafts = com.rork.vinetrack.data.WorkTaskPlanningDraftStore(context)
        val originalDraft = com.rork.vinetrack.data.model.WorkTaskPlanningDraft(
            null, "vineyard", owner, date = "2026-11-05T00:00:00Z", taskType = "pruning",
            assignmentName = "Greg Horner", durationText = "1", notes = "Need bamboo and loose tie onto it",
        )
        drafts.save(originalDraft)
        assertEquals(originalDraft, drafts.load(owner, "vineyard", null))
        val draftPreferences = context.names.associateWith { name -> context.getSharedPreferences(name, 0).all.toMap() }
        var requests = 0
        val client = mockAuthClient { _, _ ->
            requests++
            400 to "{\"code\":400,\"error_code\":\"refresh_token_not_found\"}"
        }
        try {
            val repository = AuthRepository(session, client)
            assertEquals(SessionValidity.Rejected, repository.revalidateSession())
            assertEquals(SessionValidity.Rejected, repository.revalidateSession())
            assertEquals("A retained rejection must not trigger repeated exchanges", 1, requests)
            assertTrue(session.retentionGuard.isLocked)
            assertEquals(owner, SessionStore(context).recoveryPrincipal)
            assertEquals(before, context.getSharedPreferences("vinetrack_pending_writes", 0).all)
            for ((name, bytes) in draftPreferences.filterKeys { it != "vinetrack_session" }) {
                assertEquals("Retained field preferences changed: $name", bytes, context.getSharedPreferences(name, 0).all)
            }
            assertEquals(originalDraft, com.rork.vinetrack.data.WorkTaskPlanningDraftStore(context).load(owner, "vineyard", null))
        } finally { client.close() }
    }

    @Test fun lateRefreshSuccessCannotPublishAfterProductionRevocation() = runBlocking {
        check(SupabaseClient.isConfigured)
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "11111111-1111-4111-8111-111111111111", null)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val client = mockAuthClient { _, _ ->
            entered.complete(Unit)
            withTimeout(5_000) { release.await() }
            200 to "{\"access_token\":\"late-access\",\"refresh_token\":\"late-refresh\",\"user\":{\"id\":\"11111111-1111-4111-8111-111111111111\"}}"
        }
        try {
            val repository = AuthRepository(session, client)
            val refresh = async { repository.revalidateSession() }
            withTimeout(5_000) { entered.await() }
            session.clear()
            val revoked = context.getSharedPreferences("vinetrack_session", 0).all.toMap()
            release.complete(Unit)
            assertEquals(SessionValidity.Rejected, withTimeout(5_000) { refresh.await() })
            assertEquals(revoked, context.getSharedPreferences("vinetrack_session", 0).all)
            assertFalse(context.getSharedPreferences("vinetrack_session", 0).all.containsValue("late-access"))
        } finally { release.complete(Unit); client.close() }
    }

    @Test fun obsoleteRejectionCannotRevokeNewerSameAccountRefresh() = runBlocking {
        check(SupabaseClient.isConfigured)
        val owner = "11111111-1111-4111-8111-111111111111"
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", owner, null)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val client = mockAuthClient { _, _ ->
            entered.complete(Unit)
            withTimeout(5_000) { release.await() }
            400 to "{\"code\":\"refresh_token_already_used\"}"
        }
        try {
            val repository = AuthRepository(session, client)
            val refresh = async { repository.revalidateSession() }
            withTimeout(5_000) { entered.await() }
            session.save("new-access", "new-refresh", owner, null)
            release.complete(Unit)
            assertEquals(SessionValidity.Unreachable, withTimeout(5_000) { refresh.await() })
            assertEquals("new-access", session.accessToken)
            assertFalse(session.retentionGuard.isLocked)
        } finally { release.complete(Unit); client.close() }
    }

    @Test fun missingAccessTokenStillRefreshesUnderOriginalProductionPrincipal() = runBlocking {
        check(SupabaseClient.isConfigured)
        val owner = "11111111-1111-4111-8111-111111111111"
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", owner, null)
        session.accessToken = null
        val client = mockAuthClient { _, _ ->
            200 to "{\"access_token\":\"fresh-access\",\"refresh_token\":\"fresh-refresh\"}"
        }
        try {
            assertEquals(SessionValidity.Valid, AuthRepository(session, client).revalidateSession())
            assertEquals(owner, session.userId)
            assertEquals("fresh-access", session.accessToken)
            assertFalse(session.retentionGuard.isLocked)
        } finally { client.close() }
    }

    @Test fun failedRecoveryTransactionMasksAuthorityWithoutDeletingOriginalSessionOrFieldBytes() {
        val original = "11111111-1111-4111-8111-111111111111"
        val raw = context.getSharedPreferences("vinetrack_session", 0)
        var failCommit = false
        val wrapped = object : SharedPreferences by raw {
            override fun edit(): SharedPreferences.Editor {
                val editor = raw.edit()
                return object : SharedPreferences.Editor by editor {
                    override fun commit(): Boolean = if (failCommit) false else editor.commit()
                }
            }
        }
        val faultContext = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                if (name == "vinetrack_session") wrapped else context.getSharedPreferences(name, mode)
        }
        val session = SessionStore(faultContext)
        session.save("access-A", "refresh-A", original, null)
        val authority = requireNotNull(session.accountAccess())
        val originalSession = raw.all.toMap()
        val retained = context.getSharedPreferences("vinetrack_manual_spray_drafts_v1", 0)
        check(retained.edit().putString("draft", "unreadable-kept").commit())
        failCommit = true
        session.clear()
        assertTrue(session.retentionGuard.isLocked)
        assertNull(session.accessToken)
        assertEquals(originalSession, raw.all)
        assertFalse(session.withAccountAccess(authority) { fail("Revoked callback executed") })
        assertEquals("unreadable-kept", retained.getString("draft", null))
        failCommit = false
        session.clear()
        assertEquals(original, session.recoveryPrincipal)
        assertNull(raw.getString("refresh_token", null))
    }

    @Test fun editAdmittedBeforeRevocationCannotCommitAfterItAndPreservesDraftBytes() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val raw = context.getSharedPreferences("vinetrack_manual_spray_drafts_v1", 0)
        check(raw.edit().putString("draft", "original-authorless-draft").commit())
        val guarded = FieldStoreAccess(context).preferences(raw)
        val editor = guarded.edit().putString("draft", "late-replacement")
        session.clear()
        assertFalse(editor.commit())
        assertEquals("original-authorless-draft", raw.getString("draft", null))
        assertTrue(SessionStore(context).retentionGuard.isLocked)
    }

    @Test fun actualManualAndPlanningDraftCallbacksCannotDiscardAfterRevocation() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val manual = com.rork.vinetrack.data.ManualSprayDraftStore(context)
        val planning = com.rork.vinetrack.data.WorkTaskPlanningDraftStore(context)
        val rawManual = context.getSharedPreferences("vinetrack_manual_spray_drafts_v1", 0)
        val rawPlanning = context.getSharedPreferences("vinetrack_local_planning", 0)
        check(rawManual.edit().putString("vineyard", "original-corrupt-draft").commit())
        val key = "work-task-planning-account-A-vineyard-new"
        check(rawPlanning.edit().putString(key, "original-corrupt-planning").commit())
        val beforeManual = rawManual.all.toMap()
        val beforePlanning = rawPlanning.all.toMap()
        session.clear()
        denied { manual.clear("vineyard") }
        denied { planning.discardPlanningDraft("account-A", "vineyard", null) }
        assertEquals(beforeManual, rawManual.all)
        assertEquals(beforePlanning, rawPlanning.all)
    }

    @Test fun suspendedLocationAdmissionDefersExitThenDeniesItsRevokedCallback() = runBlocking {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val operation = requireNotNull(session.fieldOperation())
        val release = CompletableDeferred<Unit>()
        var callbacks = 0
        val pending = async {
            withTimeout(5_000) { release.await() }
            session.withFieldOperation(operation) { callbacks++ }
        }
        var transitionChecks = 0
        assertFalse(session.retentionGuard.transitionIfIdle { transitionChecks++; true })
        assertEquals(0, transitionChecks)
        session.clear()
        release.complete(Unit)
        assertFalse(withTimeout(5_000) { pending.await() })
        operation.complete()
        operation.complete()
        assertFalse(session.retentionGuard.hasOutstandingOperations())
        assertEquals(0, callbacks)
    }

    @Test fun exitInspectionClosesReentrantWriterAndCallbackAdmission() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val access = requireNotNull(session.accountAccess())
        assertTrue(session.retentionGuard.transitionIfIdle {
            assertNull(session.fieldOperation())
            assertNull(session.accountAccess())
            assertFalse(session.withAccountAccess(access) { fail("Writer entered during inspection") })
            true
        })
        assertNotNull(session.accountAccess())
    }

    @Test fun busyAuthorityCannotDeadlockAnAlreadyLockedStorageCommit() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val raw = context.getSharedPreferences("vinetrack_pending_writes", 0)
        check(raw.edit().putString("pending_writes_json", "original").commit())
        val editor = FieldStoreAccess(context).preferences(raw).edit().putString("pending_writes_json", "replacement")
        val access = requireNotNull(session.accountAccess())
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            assertTrue(session.withAccountAccess(access) {
                val result = executor.submit<Throwable?> { runCatching { editor.commit() }.exceptionOrNull() }
                assertTrue(result.get(5, java.util.concurrent.TimeUnit.SECONDS) is FieldSaveBusy)
            })
            assertEquals("original", raw.getString("pending_writes_json", null))
            assertTrue(editor.commit())
            assertEquals("replacement", raw.getString("pending_writes_json", null))
        } finally { executor.shutdownNow() }
    }

    @Test fun realPhotoFileAndQueueSaveRemainIntactAfterRevocation() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val photos = PendingPhotoRepository(context)
        val photo = photos.enqueue("pin", "vineyard", byteArrayOf(1, 2, 3))
        val writes = PendingWriteStore(context)
        val raw = context.getSharedPreferences("vinetrack_pending_writes", 0)
        check(raw.edit().putString("pending_writes_json", "[]").commit())
        val metadata = context.getSharedPreferences("vinetrack_pending_photos", 0).all.toMap()
        session.clear()
        denied { photos.enqueue("pin", "vineyard", byteArrayOf(4, 5, 6)) }
        denied { photos.remove(photo.id) }
        assertFalse(writes.save(emptyList()))
        assertArrayEquals(byteArrayOf(1, 2, 3), File(photo.localPath).readBytes())
        assertEquals(metadata, context.getSharedPreferences("vinetrack_pending_photos", 0).all)
        assertEquals("[]", raw.getString("pending_writes_json", null))
    }

    @Test fun corruptActiveClaimCannotBeOverwrittenThroughProductionClaim() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val prefs = context.getSharedPreferences("vinetrack_active_trip", 0)
        check(prefs.edit().putString("active_trip_snapshot_json", "corrupt-original").commit())
        val store = com.rork.vinetrack.data.ActiveTripStore(context)
        assertTrue(store.hasActiveClaim())
        val replacement = com.rork.vinetrack.data.model.Trip(id = "new", vineyardId = "vineyard")
        assertFalse(store.claimIfAvailable("account-A", "vineyard", replacement))
        assertFalse(store.saveDurably("account-A", "vineyard", replacement))
        denied { store.clear() }
        assertEquals("corrupt-original", prefs.getString("active_trip_snapshot_json", null))
    }

    @Test fun actualScoutPhotoWriteAndCleanupAfterRevocationRetainOriginalBytes() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val files = com.rork.vinetrack.data.insights.ScoutPhotoFileStore(context)
        val path = requireNotNull(files.write(byteArrayOf(7, 8, 9), "vineyard", "observation", "photo"))
        val original = files.file(path)
        session.clear()
        assertNull(files.write(byteArrayOf(1, 2, 3), "vineyard", "observation", "photo"))
        files.remove(path)
        assertNull(files.read(path))
        assertArrayEquals(byteArrayOf(7, 8, 9), original.readBytes())
    }

    @Test fun corruptCaptureFallbackCannotDecodeToEmptyOrBeDeletedByAnAcknowledgement() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val prefs = context.getSharedPreferences("vinetrack_pin_capture_evidence", 0)
        check(prefs.edit().putString("pin_capture_evidence_json", "[]").commit())
        val backup = File(root, "pin_capture_evidence_recovery_v2.json.bak")
        backup.writeText("corrupt-capture-original")
        val store = com.rork.vinetrack.data.PinCaptureEvidenceStore(context)
        assertFalse("Corrupt evidence cannot be acknowledged", store.markUploaded("pin", 1))
        assertNotNull("Recovery hold must be surfaced", store.readIssue.value)
        assertEquals("corrupt-capture-original", backup.readText())
        assertFalse(File(root, "pin_capture_evidence_recovery_v2.json").exists())
        assertEquals("[]", prefs.getString("pin_capture_evidence_json", null))
    }

    @Test fun failedRealPhotoMetadataCommitRetainsPriorAttachmentAndBothCapturedByteSets() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val raw = context.getSharedPreferences("vinetrack_pending_photos", 0)
        var failCommit = false
        val wrapped = object : SharedPreferences by raw {
            override fun edit(): SharedPreferences.Editor {
                val editor = raw.edit()
                return object : SharedPreferences.Editor by editor {
                    override fun commit(): Boolean = if (failCommit) false else editor.commit()
                }
            }
        }
        val faultContext = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getFilesDir(): File = root
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                if (name == "vinetrack_pending_photos") wrapped else context.getSharedPreferences(name, mode)
        }
        val photos = PendingPhotoRepository(faultContext)
        val original = photos.enqueue("pin", "vineyard", byteArrayOf(1, 2, 3))
        val before = raw.all.toMap()
        failCommit = true
        denied { photos.enqueue("pin", "vineyard", byteArrayOf(4, 5, 6)) }
        assertEquals(before, raw.all)
        assertEquals(listOf(original), photos.list())
        assertArrayEquals(byteArrayOf(1, 2, 3), File(original.localPath).readBytes())
        val files = File(root, "pending_pin_photos").listFiles().orEmpty()
        assertEquals(2, files.count { it.name.endsWith(".jpg") })
        assertEquals(1, files.count { it.name.endsWith(".capture") })
        assertTrue(files.any { it.readBytes().contentEquals(byteArrayOf(4, 5, 6)) })
        failCommit = false
        val recovered = PendingPhotoRepository(faultContext).list().single()
        assertNotEquals(original.revision, recovered.revision)
        assertArrayEquals(byteArrayOf(4, 5, 6), File(recovered.localPath).readBytes())
        assertEquals(recovered, PendingPhotoRepository(faultContext).list().single())
        assertTrue(File(root, "pending_pin_photos").listFiles().orEmpty().none { it.name.endsWith(".capture") })
    }

    @Test fun actualUnscopedLateTankAcknowledgementNowFailsAtDurableStorage() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val store = com.rork.vinetrack.data.SprayTankActualStore(context)
        val actual = com.rork.vinetrack.data.model.SprayTankActual(
            "actual", "vineyard", "spray", "trip", "tank", 1, waterVolumeL = 123.45,
            chemicals = emptyList(), confirmedAt = "2026-10-12T00:00:00Z", confirmedBy = "account-A")
        assertTrue(store.save(actual))
        val prefs = context.getSharedPreferences("vinetrack_spray_tank_actuals", 0)
        val before = prefs.all.toMap()
        session.clear()
        assertFalse(store.markSyncedIfCurrent(actual))
        assertEquals(before, prefs.all)
        assertEquals(listOf(actual), com.rork.vinetrack.data.SprayTankActualStore(context).pending())
    }

    @Test fun productionActiveSnapshotCannotBeSavedUnderAnotherActor() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val store = com.rork.vinetrack.data.ActiveTripStore(context)
        val trip = com.rork.vinetrack.data.model.Trip(id = "trip", vineyardId = "vineyard", isActive = true)
        assertTrue(store.saveDurably("account-A", "vineyard", trip))
        val prefs = context.getSharedPreferences("vinetrack_active_trip", 0)
        val before = prefs.all.toMap()
        denied { store.saveDurably("account-B", "vineyard", trip.copy(tripTitle = "foreign")) }
        assertEquals(before, prefs.all)
    }

    @Test fun actualAuxiliaryWritersCannotPersistAfterTheirAccountIsRevoked() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val manual = com.rork.vinetrack.data.ManualSprayOperationStore(context)
        val materials = com.rork.vinetrack.data.material.WorkTaskMaterialStore(context)
        val irrigation = com.rork.vinetrack.data.IrrigationPrefsStore(context)
        val pruning = com.rork.vinetrack.data.PruningStore(context)
        val fertiliser = com.rork.vinetrack.data.FertiliserStore(context)
        val chemicals = com.rork.vinetrack.data.SavedChemicalLocalStore(context)
        val resistance = com.rork.vinetrack.data.resistance.ResistancePlanStore(context)
        val names = listOf("vinetrack_manual_spray_operations_v1", "vinetrack_work_task_materials",
            "vinetrack_irrigation", "vinetrack_pruning", "vinetrack_fertiliser",
            "vinetrack_saved_chemicals_local", "resistance_plans")
        val before = names.associateWith { name ->
            val prefs = context.getSharedPreferences(name, 0)
            check(prefs.edit().putString("unknown-original", "retained-$name").commit())
            prefs.all.toMap()
        }
        session.clear()
        assertFalse(manual.save(emptyList()))
        assertFalse(materials.clear())
        denied { irrigation.save(com.rork.vinetrack.data.IrrigationDefaults.factory) }
        denied { pruning.saveSetups("vineyard", emptyList()) }
        denied { fertiliser.saveRecords("vineyard", emptyList()) }
        assertFalse(chemicals.save("account-A", "vineyard", emptyList()))
        denied { resistance.savePending("vineyard", setOf("late")) }
        names.forEach { assertEquals(before[it], context.getSharedPreferences(it, 0).all) }
    }

    @Test fun photoAcquisitionSurvivesActivityRecreationUntilDurableAcknowledgement() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val receipt = requireNotNull(PhotoCaptureReceipt.begin(context, "camera"))
        File(receipt.path).writeBytes(byteArrayOf(1, 2, 3))
        assertTrue(session.retentionGuard.hasOutstandingOperations())
        assertFalse(session.retentionGuard.transitionIfIdle { true })
        val recreated = requireNotNull(PhotoCaptureReceipt.restore(context, receipt.id))
        assertEquals(receipt.path, recreated.path)
        assertFalse(recreated.cancelIfEmpty())
        assertTrue(recreated.persisted())
        assertFalse(session.retentionGuard.hasOutstandingOperations())
        val raw = context.getSharedPreferences(PhotoCaptureReceipt.PREFERENCES, 0).getString(receipt.id, null)!!
        assertTrue(raw.contains("\"completed\":true"))
        assertArrayEquals(byteArrayOf(1, 2, 3), File(receipt.path).readBytes())
    }

    @Test fun revokedPhotoReturnAndLostLiveTicketPreserveUncertainEvidenceWithoutRebinding() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val receipt = requireNotNull(PhotoCaptureReceipt.begin(context, "gallery"))
        assertTrue(receipt.recordExternalSource("content://synthetic/retained"))
        val prefs = context.getSharedPreferences(PhotoCaptureReceipt.PREFERENCES, 0)
        val before = prefs.all.toMap()
        File(receipt.path).writeBytes(byteArrayOf(4, 5, 6))
        requireNotNull(session.retentionGuard.operation(receipt.id)).complete()
        assertNull(PhotoCaptureReceipt.restore(context, receipt.id))
        session.clear()
        assertFalse(receipt.admitted { fail("Old return must not be delivered") })
        assertFalse(receipt.persisted())
        assertNull(PhotoCaptureReceipt.restore(context, receipt.id))
        assertEquals(before, prefs.all)
        assertArrayEquals(byteArrayOf(4, 5, 6), File(receipt.path).readBytes())
    }

    @Test fun failedPhotoReceiptPersistenceKeepsAcquisitionOutstandingAndSourceBytes() {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val receipt = requireNotNull(PhotoCaptureReceipt.begin(context, "camera"))
        File(receipt.path).writeBytes(byteArrayOf(7, 8, 9))
        val original = context.getSharedPreferences(PhotoCaptureReceipt.PREFERENCES, 0)
        val before = original.all.toMap()
        val failing = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                val prefs = context.getSharedPreferences(name, mode)
                if (name != PhotoCaptureReceipt.PREFERENCES) return prefs
                return object : SharedPreferences by prefs {
                    override fun edit(): SharedPreferences.Editor {
                        val editor = prefs.edit()
                        return object : SharedPreferences.Editor by editor { override fun commit(): Boolean = false }
                    }
                }
            }
        }
        assertFalse(requireNotNull(PhotoCaptureReceipt.restore(failing, receipt.id)).persisted())
        assertEquals(before, original.all)
        assertTrue(session.retentionGuard.hasOutstandingOperations())
        assertArrayEquals(byteArrayOf(7, 8, 9), File(receipt.path).readBytes())
        assertTrue(receipt.persisted())
    }

    @Test fun delayedCanopyDownloadCannotPromoteManifestOrFilesAfterRevocation() = runBlocking {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val root = File(root, "canopy")
        val slot = "canopy.vsp.small"
        var version = "v1"
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val repository = com.rork.vinetrack.data.spray.CanopyReferenceImageRepository(
            root = root,
            configSource = com.rork.vinetrack.data.spray.CanopyReferenceConfigSource {
                com.rork.vinetrack.data.spray.CanopyReferenceConfiguration("guide-images", images = mapOf(slot to
                    com.rork.vinetrack.data.spray.CanopyReferenceRemoteImage("guide-$version", version)))
            },
            downloader = com.rork.vinetrack.data.spray.CanopyReferenceImageDownloader { _, _ ->
                if (version == "v2") { entered.complete(Unit); release.await() }
                "IMG-$version".toByteArray()
            },
            validator = { it.decodeToString().startsWith("IMG-") },
            refreshAdmission = {
                session.fieldOperation()?.let { operation ->
                    com.rork.vinetrack.data.spray.CanopyReferenceImageRepository.RefreshAdmission(
                        { action -> session.withFieldOperation(operation, action) }, { operation.complete() })
                }
            },
        )
        repository.refresh()
        val image = requireNotNull(repository.localFile(slot))
        val original = image.readBytes()
        val manifest = File(root, "manifest.json").readBytes()
        version = "v2"
        val refresh = async { repository.refresh() }
        withTimeout(5_000) { entered.await() }
        assertFalse(session.retentionGuard.transitionIfIdle { true })
        session.clear()
        release.complete(Unit)
        withTimeout(5_000) { refresh.await() }
        assertArrayEquals(original, image.readBytes())
        assertArrayEquals(manifest, File(root, "manifest.json").readBytes())
        assertEquals(image, repository.localFile(slot))
        assertFalse(session.retentionGuard.hasOutstandingOperations())
    }

    @Test fun vintageDelayedReadRetainsOriginalPendingOperationAndRejectsPostRevocationPublication() = runBlocking {
        val session = SessionStore(context)
        val account = "11111111-1111-4111-8111-111111111111"
        session.save("access", "refresh", account, null)
        val file = File(root, "vintage-reports/$account/vineyard/2026.json")
        check(file.parentFile!!.mkdirs())
        val cache = com.rork.vinetrack.data.insights.VintageReportCache(pending =
            com.rork.vinetrack.data.insights.VintageReportCommand("generate", "original-operation", null, "2026-10-12", null))
        val codec = kotlinx.serialization.json.Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = true }
        val raw = codec.encodeToString(com.rork.vinetrack.data.insights.VintageReportCache.serializer(), cache)
        file.writeText(raw)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val client = HttpClient(MockEngine {
            entered.complete(Unit)
            release.await()
            respond("{\"report\":null,\"revisions\":[],\"requests\":[]}", HttpStatusCode.OK)
        })
        lateinit var viewModel: com.rork.vinetrack.data.insights.VintageReportViewModel
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            viewModel = com.rork.vinetrack.data.insights.VintageReportViewModel(context, account, "vineyard", 2026, http = client, canAccess = { true })
        }
        assertNull("Production-format report cache must be readable before the delayed request", viewModel.ui.value.message)
        withTimeout(5_000) { entered.await() }
        val displayed = viewModel.ui.value
        assertFalse(session.retentionGuard.transitionIfIdle { true })
        session.clear()
        release.complete(Unit)
        withTimeout(5_000) {
            while (session.retentionGuard.hasOutstandingOperations()) kotlinx.coroutines.delay(10)
        }
        assertEquals(raw, file.readText())
        assertEquals("original-operation", viewModel.ui.value.cache.pending?.operation)
        assertEquals(displayed, viewModel.ui.value)
        client.close()
    }

    @Test fun concurrentTripTankPinPhotoAndDraftWritesCompleteDurablyAfterContention() = runBlocking {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val access = requireNotNull(session.accountAccess())
        val trips = com.rork.vinetrack.data.ActiveTripStore(context)
        val tanks = com.rork.vinetrack.data.SprayTankActualStore(context)
        val pins = PendingWriteRepository(context)
        val pinInput = PinRepository.PinInput("pin", "vineyard", createdBy = "account-A")
        val growth = com.rork.vinetrack.data.model.GrowthStageRecord("growth", "vineyard", stageCode = "19", observedAt = "2026-10-12T00:00:00Z", notes = "original-growth", latitude = -33.12, longitude = 149.25)
        val growthSync = com.rork.vinetrack.data.GrowthRecordCreateSync(pins, { error("No network in save regression") }, { _, _ -> false })
        val tankSync = com.rork.vinetrack.data.TripTankSync(null, pins, trips)
        val photos = PendingPhotoRepository(context)
        val drafts = com.rork.vinetrack.data.WorkTaskPlanningDraftStore(context)
        val trip = com.rork.vinetrack.data.model.Trip("trip", "vineyard", isActive = true)
        val actual = com.rork.vinetrack.data.model.SprayTankActual(
            "actual", "vineyard", "spray", "trip", "tank", 1, waterVolumeL = 123.45,
            chemicals = emptyList(), confirmedAt = "2026-10-12T00:00:00Z", confirmedBy = "account-A")
        val draft = com.rork.vinetrack.data.model.WorkTaskPlanningDraft(null, "vineyard", "account-A",
            date = "2026-10-12T00:00:00Z", taskType = "pruning", notes = "recoverable-original-intent")
        val jpeg = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888).let { image ->
            try { ByteArrayOutputStream().use { out -> check(image.compress(Bitmap.CompressFormat.JPEG, 90, out)); out.toByteArray() } }
            finally { image.recycle() }
        }
        val before = listOf("vinetrack_active_trip", "vinetrack_spray_tank_actuals", "vinetrack_pending_writes",
            "vinetrack_pending_photos", "vinetrack_local_planning").associateWith { context.getSharedPreferences(it, 0).all.toMap() }
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val holder = async(kotlinx.coroutines.Dispatchers.Default) {
            session.withAccountAccess(access) {
                entered.complete(Unit)
                runBlocking { withTimeout(5_000) { release.await() } }
            }
        }
        withTimeout(5_000) { entered.await() }
        val waiting = java.util.concurrent.CountDownLatch(6)
        val observer = CleanExitDiagnostics.observer
        CleanExitDiagnostics.observer = { if (it == "field.commit.waiting") waiting.countDown() }
        val attempts = listOf(
            async(kotlinx.coroutines.Dispatchers.IO) { assertTrue(trips.saveDurably("account-A", "vineyard", trip)) },
            async(kotlinx.coroutines.Dispatchers.IO) { assertTrue(tanks.save(actual)); tankSync.enqueue(trip) },
            async(kotlinx.coroutines.Dispatchers.IO) { PinCreateSync(pins).enqueue(pinInput) },
            async(kotlinx.coroutines.Dispatchers.IO) { growthSync.enqueue(growth, "2026-10-12T00:00:00Z") },
            async(kotlinx.coroutines.Dispatchers.IO) { photos.enqueue("pin", "vineyard", jpeg) },
            async(kotlinx.coroutines.Dispatchers.IO) { drafts.save(draft) },
        )
        try {
            assertTrue(waiting.await(2, java.util.concurrent.TimeUnit.SECONDS))
            assertTrue(attempts.none { it.isCompleted })
            before.forEach { (name, original) -> assertEquals(original, context.getSharedPreferences(name, 0).all) }
        } finally { release.complete(Unit) }
        try {
            withTimeout(6_000) { holder.await(); attempts.forEach { it.await() } }
        } finally { CleanExitDiagnostics.observer = observer }
        assertEquals(trip, com.rork.vinetrack.data.ActiveTripStore(context).load()?.trip)
        assertEquals(listOf(actual), com.rork.vinetrack.data.SprayTankActualStore(context).pending())
        val retained = PendingWriteRepository(context).list()
        assertEquals(3, retained.size)
        assertEquals(3, retained.map { it.id }.distinct().size)
        assertEquals(pins.list().toSet(), retained.toSet())
        assertEquals("pin", retained.single { it.entityType == "pin" }.clientId)
        val retainedGrowth = retained.single { it.clientId == "growth" }
        val growthPayload = SupabaseClient.json.decodeFromString<com.rork.vinetrack.data.GrowthRecordCreateSync.Payload>(retainedGrowth.payloadJson)
        assertEquals("original-growth", growthPayload.notes)
        assertEquals(-33.12, requireNotNull(growthPayload.latitude), 0.0)
        assertEquals("vineyard", growthPayload.vineyardId)
        assertTrue(retained.any { it.entityType == com.rork.vinetrack.data.model.PendingEntityType.TRIP_TANK && it.clientId == trip.id })
        val photo = PendingPhotoRepository(context).list().single()
        assertArrayEquals(jpeg, File(photo.localPath).readBytes())
        assertEquals(draft, com.rork.vinetrack.data.WorkTaskPlanningDraftStore(context).load("account-A", "vineyard", null))
    }

    /** Successful production repository transition on a strict-empty fixture; not Activity/live-service acceptance. */
    @Test fun cleanExitRecreationSameAccountThenDifferentAccountUsesFreshAuthority() = runBlocking {
        val session = SessionStore(context)
        val account = "11111111-1111-4111-8111-111111111111"
        var returning = account
        val client = HttpClient(MockEngine { request ->
            val body = when {
                request.url.encodedPath.endsWith("/auth/v1/token") ->
                    "{\"access_token\":\"access-$returning\",\"refresh_token\":\"refresh-$returning\",\"user\":{\"id\":\"$returning\"}}"
                request.url.encodedPath.endsWith("/auth/v1/logout") -> {
                    assertEquals("local", request.url.parameters["scope"])
                    "{}"
                }
                else -> error("Unexpected request")
            }
            respond(body, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        try {
            val auth = AuthRepository(session, client)
            assertEquals(account, auth.signIn("synthetic@example.invalid", "synthetic-password").id)
            assertTrue(session.hasSession)
            assertFalse(com.rork.vinetrack.data.ActiveTripStore(context).hasActiveClaim())
            assertTrue(PendingWriteStore(context).loadForRecovery().items.isEmpty())
            assertTrue(PendingPhotoStore(context).load().isEmpty())
            assertFalse(session.retentionGuard.hasOutstandingOperations())
            val old = requireNotNull(session.accountAccess())
            assertTrue(auth.signOut())
            val restarted = SessionStore(context)
            assertFalse(restarted.retentionGuard.isLocked)
            assertFalse(restarted.hasSession)
            assertNull(restarted.selectedVineyardId)
            assertNull(restarted.defaultVineyardId)
            assertEquals(AuthRepository.RestoreResult.SignedOut, AuthRepository(restarted, client).restoreSession())
            assertEquals(account, AuthRepository(restarted, client).signIn("synthetic@example.invalid", "synthetic-password").id)
            assertFalse(restarted.withAccountAccess(old) { fail("Old A authority was reused") })
            assertTrue(AuthRepository(restarted, client).signOut())
            returning = "22222222-2222-4222-8222-222222222222"
            val next = SessionStore(context)
            assertEquals(returning, AuthRepository(next, client).signIn("other@example.invalid", "synthetic-password").id)
            assertTrue(next.hasSession)
            assertFalse(next.retentionGuard.isLocked)
            assertEquals(returning, next.userId)
            assertNull(next.selectedVineyardId)
            assertNull(next.defaultVineyardId)
            assertFalse(next.withAccountAccess(old) { fail("A result entered B") })
        } finally { client.close() }
    }

    /** Successful owned-snapshot recovery through production token/user/membership/admission code. */
    @Test fun originalAccountRecoveryRestoresFreshSessionAndPreservesOwnedTripBytes() = runBlocking {
        val session = SessionStore(context)
        val account = "11111111-1111-4111-8111-111111111111"
        session.save("original-access", "original-refresh", account, null)
        val snapshot = com.rork.vinetrack.data.ActiveTripStore(context)
        assertTrue(snapshot.saveDurably(account, "vineyard", com.rork.vinetrack.data.model.Trip(id = "trip", vineyardId = "vineyard", isActive = true)))
        val evidence = context.getSharedPreferences("vinetrack_active_trip", 0).all.toMap()
        val tank = com.rork.vinetrack.data.model.SprayTankActual(
            "actual", "vineyard", "spray", "trip", "tank", 1, waterVolumeL = 123.45,
            chemicals = emptyList(), confirmedAt = "2026-10-12T00:00:00Z", confirmedBy = account,
        )
        assertTrue(com.rork.vinetrack.data.SprayTankActualStore(context).save(tank))
        val tankEvidence = context.getSharedPreferences("vinetrack_spray_tank_actuals", 0).all.toMap()
        val obsolete = requireNotNull(session.accountAccess())
        session.clear()
        val requests = mutableListOf<String>()
        val client = HttpClient(MockEngine { request ->
            requests.add(request.url.encodedPath)
            val body = when {
                request.url.encodedPath.endsWith("/token") -> "{\"access_token\":\"returning-access\",\"refresh_token\":\"returning-refresh\"}"
                request.url.encodedPath.endsWith("/user") -> "{\"id\":\"$account\"}"
                request.url.encodedPath.endsWith("/vineyard_members") -> "[{\"vineyard_id\":\"vineyard\",\"role\":\"operator\"}]"
                request.url.encodedPath.endsWith("/vineyards") -> "[{\"id\":\"vineyard\"}]"
                request.url.encodedPath.endsWith("/logout") -> "{}"
                else -> error("Unexpected recovery request")
            }
            respond(body, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        assertTrue(AuthRecoveryRepository { client }.recover(session, "synthetic@example.invalid", "synthetic-password"))
        assertTrue(requests.any { it.endsWith("/user") })
        assertTrue(requests.any { it.endsWith("/vineyard_members") })
        assertFalse(requests.any { it.endsWith("/logout") })
        assertNull(session.recoveryPrincipal)
        assertTrue(session.hasSession)
        assertFalse(session.retentionGuard.isLocked)
        assertEquals(account, requireNotNull(session.accountAccess()).userId)
        assertFalse(session.withAccountAccess(obsolete) { fail("Rejected-session callback was revived") })
        assertEquals(evidence, context.getSharedPreferences("vinetrack_active_trip", 0).all)
        val reopened = SessionStore(context)
        assertTrue(reopened.hasSession)
        assertFalse(reopened.retentionGuard.isLocked)
        assertEquals("trip", com.rork.vinetrack.data.ActiveTripStore(context).load()?.trip?.id)
        assertEquals(tankEvidence, context.getSharedPreferences("vinetrack_spray_tank_actuals", 0).all)
        assertEquals(listOf(tank), com.rork.vinetrack.data.SprayTankActualStore(context).pending())
    }

    @Test fun delayedCleanLogoutCannotClearTheNextAccountSession() = runBlocking {
        val session = SessionStore(context)
        val a = "11111111-1111-4111-8111-111111111111"
        val b = "22222222-2222-4222-8222-222222222222"
        session.save("access-A", "refresh-A", a, null)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val client = HttpClient(MockEngine { request ->
            check(request.url.encodedPath.endsWith("/logout"))
            entered.complete(Unit)
            withTimeout(5_000) { release.await() }
            respond("{}", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        try {
            val logout = async { AuthRepository(session, client).signOut() }
            withTimeout(5_000) { entered.await() }
            assertFalse(session.hasSession)
            session.save("access-B", "refresh-B", b, null)
            release.complete(Unit)
            assertTrue(withTimeout(5_000) { logout.await() })
            assertEquals(b, session.userId)
            assertEquals("access-B", session.accessToken)
            assertFalse(session.retentionGuard.isLocked)
        } finally { release.complete(Unit); client.close() }
    }

    /** Refusal evidence only, not successful recovery acceptance. */
    @Test fun wrongIdentityMissingPermissionAndAuthorlessQueueRemainProtected() = runBlocking {
        val session = SessionStore(context)
        val a = "11111111-1111-4111-8111-111111111111"
        val b = "22222222-2222-4222-8222-222222222222"
        session.save("access-A", "refresh-A", a, null)
        assertTrue(com.rork.vinetrack.data.ActiveTripStore(context).saveDurably(a, "vineyard",
            com.rork.vinetrack.data.model.Trip(id = "trip", vineyardId = "vineyard", isActive = true)))
        session.clear()
        val before = context.getSharedPreferences("vinetrack_active_trip", 0).all.toMap()
        for (scenario in listOf("wrong-account", "missing-permission", "deleted-vineyard", "authorless-queue")) {
            if (scenario == "authorless-queue") check(context.getSharedPreferences("vinetrack_pending_writes", 0)
                .edit().putString("pending_writes_json", "[{\"id\":\"unattributed\"}]").commit())
            val queueBefore = context.getSharedPreferences("vinetrack_pending_writes", 0).all.toMap()
            var revoked = false
            val client = HttpClient(MockEngine { request ->
                val body = when {
                    request.url.encodedPath.endsWith("/token") -> "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\"}"
                    request.url.encodedPath.endsWith("/user") -> "{\"id\":\"${if (scenario == "wrong-account") b else a}\"}"
                    request.url.encodedPath.endsWith("/vineyard_members") -> if (scenario == "missing-permission") "[]"
                        else "[{\"vineyard_id\":\"vineyard\",\"role\":\"operator\"}]"
                    request.url.encodedPath.endsWith("/vineyards") -> if (scenario == "deleted-vineyard") "[]" else "[{\"id\":\"vineyard\"}]"
                    request.url.encodedPath.endsWith("/logout") -> { revoked = true; "{}" }
                    else -> error("Unexpected request")
                }
                respond(body, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            val restored = runCatching { AuthRecoveryRepository { client }.recover(session, "synthetic@example.invalid", "password") }.getOrDefault(false)
            assertFalse(scenario, restored)
            assertTrue(scenario, revoked)
            assertTrue(session.retentionGuard.isLocked)
            assertFalse(session.hasSession)
            assertEquals(a, session.recoveryPrincipal)
            assertEquals(before, context.getSharedPreferences("vinetrack_active_trip", 0).all)
            assertEquals(queueBefore, context.getSharedPreferences("vinetrack_pending_writes", 0).all)
        }
    }

    @Test fun retainedOutboxBlocksCleanExitWithoutDeletingAnything() = runBlocking {
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "11111111-1111-4111-8111-111111111111", null)
        val prefs = context.getSharedPreferences("vinetrack_domain_cache", 0)
        check(prefs.edit().putString("spray_target_outbox", "[{\"id\":\"unsent\"}]").commit())
        val before = prefs.all.toMap()
        val client = HttpClient(MockEngine { error("Blocked exit must not reach logout") })
        try {
            assertFalse(AuthRepository(session, client).signOut())
            assertEquals(before, prefs.all)
            assertTrue(session.hasSession)
            assertFalse(session.retentionGuard.isLocked)
        } finally { client.close() }
    }

    @Test fun accountViewModelLifetimeRestoresSameUserButDoesNotCarryAHandlesIntoB() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val app = instrumentation.targetContext.applicationContext as android.app.Application
            val a = com.rork.vinetrack.ui.auth.AccountViewModelOwner(app)
            val aWork = androidx.lifecycle.ViewModelProvider(a)[com.rork.vinetrack.ui.main.WorkContextViewModel::class.java]
            aWork.bindIdentity("account-A", "vineyard-A")
            aWork.setSelectedTripId("owned-trip")
            val saved = a.save()
            a.close()
            val same = com.rork.vinetrack.ui.auth.AccountViewModelOwner(app, saved)
            val sameWork = androidx.lifecycle.ViewModelProvider(same)[com.rork.vinetrack.ui.main.WorkContextViewModel::class.java]
            sameWork.bindIdentity("account-A", "vineyard-A")
            assertEquals("owned-trip", sameWork.selectedTripId.value)
            same.close()
            // An account transition creates a new owner, not an owner restored from A's bundle.
            val b = com.rork.vinetrack.ui.auth.AccountViewModelOwner(app)
            val bWork = androidx.lifecycle.ViewModelProvider(b)[com.rork.vinetrack.ui.main.WorkContextViewModel::class.java]
            bWork.bindIdentity("account-B", "vineyard-B")
            assertNull(bWork.selectedTripId.value)
            assertNotSame(aWork, bWork)
            b.close()
        }
    }

    /** Populated production stores, not Activity acceptance; caches stay byte-for-byte on exit. */
    @Test fun populatedReviewedCachesAndPreferencesExitWithoutEmptyingInstallation() = runBlocking {
        val a = "11111111-1111-4111-8111-111111111111"
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", a, null)
        val cache = com.rork.vinetrack.data.DomainCacheRepository(context)
        cache.saveVineyards(a, listOf(com.rork.vinetrack.data.model.Vineyard("vineyard", "Synthetic private vineyard")))
        cache.savePaddocks(a, "vineyard", listOf(com.rork.vinetrack.data.model.Paddock("block", "vineyard", "Synthetic block")))
        cache.savePins(a, "vineyard", listOf(com.rork.vinetrack.data.model.Pin("pin", "vineyard")))
        cache.saveTrips(a, "vineyard", listOf(com.rork.vinetrack.data.model.Trip("trip", "vineyard")))
        cache.saveGrowth(a, "vineyard", listOf(com.rork.vinetrack.data.model.GrowthStageRecord("growth", "vineyard", stageCode = "4")))
        cache.saveWorkTasks(a, "vineyard", listOf(com.rork.vinetrack.data.model.WorkTask("task", "vineyard")))
        com.rork.vinetrack.data.AppPreferencesStore(context).save(com.rork.vinetrack.data.AppPreferences())
        com.rork.vinetrack.data.MapPrefsStore(context).save(com.rork.vinetrack.data.MapDefaults())
        com.rork.vinetrack.data.HomePrefsStore(context).setInfoCardDismissed(true)
        com.rork.vinetrack.data.OnboardingStore(context).markCompleted()
        val before = context.getSharedPreferences("vinetrack_domain_cache", 0).all.toMap()
        val preferences = context.getSharedPreferences("vinetrack_app_prefs", 0).all.toMap()
        // Shared mirrors may be populated without creating private field evidence.
        val reference = File(root, "canopy_reference_images/reference.jpg")
        check(reference.parentFile!!.mkdirs()); reference.writeBytes(byteArrayOf(1, 2, 3))
        assertNotNull(AccountTransitionEvidence(context).inspectCleanExit())
        assertNull("Recovery assessment must retain its original strict rules", AccountTransitionEvidence(context).inspect(a))
        val old = requireNotNull(session.accountAccess())
        val client = HttpClient(MockEngine { respond("{}", HttpStatusCode.OK) })
        try {
            assertTrue(AuthRepository(session, client).signOut())
            assertEquals(before, context.getSharedPreferences("vinetrack_domain_cache", 0).all)
            assertEquals(preferences, context.getSharedPreferences("vinetrack_app_prefs", 0).all)
            assertArrayEquals(byteArrayOf(1, 2, 3), reference.readBytes())
            val reopened = SessionStore(context)
            assertFalse(reopened.hasSession)
            assertFalse(reopened.retentionGuard.isLocked)
            reopened.save("access-B", "refresh-B", "22222222-2222-4222-8222-222222222222", null)
            assertNull(com.rork.vinetrack.data.DomainCacheRepository(context).loadPins(reopened.userId, "vineyard"))
            assertFalse(reopened.withAccountAccess(old) { fail("A callback entered B") })
            assertEquals(before, context.getSharedPreferences("vinetrack_domain_cache", 0).all)
        } finally { client.close() }
    }

    @Test fun malformedPreferenceUnknownCacheKeyAndMissingTimestampRefuseWithoutRevocation() = runBlocking {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val client = HttpClient(MockEngine { error("Refusal cannot revoke the server session") })
        val scenarios = listOf(
            Triple("vinetrack_app_prefs", "row_tracking_enabled", "not-a-boolean"),
            Triple("vinetrack_app_prefs", "unreviewed_local_draft", "original"),
            Triple("vinetrack_domain_cache", "unreviewed_future_record", "original"),
            Triple("vinetrack_domain_cache", "pins_vineyard", "[]"),
        )
        try {
            scenarios.forEach { (name, key, value) ->
                val prefs = context.getSharedPreferences(name, 0)
                check(prefs.edit().putString(key, value).commit())
                val original = prefs.all.toMap()
                assertFalse(AuthRepository(session, client).signOut())
                assertEquals(original, prefs.all)
                assertTrue(session.hasSession)
                assertFalse(session.retentionGuard.isLocked)
                check(prefs.edit().remove(key).commit()) // Fixture-owned teardown only, never production repair.
            }
        } finally { client.close() }
    }

    @Test fun activeTripDraftPinAndPhotoRefusalsKeepAuthorityAndAllOriginalBytes() = runBlocking {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val authority = requireNotNull(session.accountAccess())
        val client = HttpClient(MockEngine { error("Unfinished work must prevent remote logout") })
        val cases: List<Pair<String, () -> Unit>> = listOf(
            "vinetrack_active_trip" to { check(com.rork.vinetrack.data.ActiveTripStore(context).saveDurably("account-A", "vineyard", com.rork.vinetrack.data.model.Trip("active", "vineyard", isActive = true))) },
            "vinetrack_local_planning" to { com.rork.vinetrack.data.WorkTaskPlanningDraftStore(context).save(com.rork.vinetrack.data.model.WorkTaskPlanningDraft(null, "vineyard", "account-A", date = "2026-10-12", taskType = "pruning", notes = "original")) },
            "vinetrack_pending_writes" to { check(PendingWriteStore(context).save(listOf(com.rork.vinetrack.data.model.PendingWrite("pending", "pin", "create", "{}", "pin", 1, 1)))) },
        )
        try {
            cases.forEach { (name, prepare) ->
                prepare()
                val prefs = context.getSharedPreferences(name, 0)
                val original = prefs.all.toMap()
                assertFalse(AuthRepository(session, client).signOut())
                assertEquals(original, prefs.all)
                assertTrue(session.isAccountAccessCurrent(authority))
                assertTrue(session.hasSession)
                assertFalse(session.retentionGuard.isLocked)
                check(prefs.edit().clear().commit()) // Isolated fixture only.
            }
            val jpeg = byteArrayOf(1, 2, 3, 4)
            val photo = PendingPhotoRepository(context).enqueue("pin", "vineyard", jpeg)
            val original = context.getSharedPreferences("vinetrack_pending_photos", 0).all.toMap()
            assertFalse(AuthRepository(session, client).signOut())
            assertArrayEquals(jpeg, File(photo.localPath).readBytes())
            assertEquals(original, context.getSharedPreferences("vinetrack_pending_photos", 0).all)
            assertTrue(session.isAccountAccessCurrent(authority))
            assertTrue(session.hasSession)
            assertFalse(session.retentionGuard.isLocked)
        } finally { client.close() }
    }

    @Test fun successfulExitCleanupCompletesDespiteCallerCancellationAndClosesLoginUntilDone() = runBlocking {
        val session = SessionStore(context)
        session.save("access", "refresh", "account-A", null)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var cleaned = false
        var revoked = false
        val client = HttpClient(MockEngine { revoked = true; respond("{}", HttpStatusCode.OK) })
        try {
            val job = async {
                AuthRepository(session, client).signOut {
                    entered.complete(Unit)
                    withTimeout(5_000) { release.await() }
                    cleaned = true
                }
            }
            withTimeout(5_000) { entered.await() }
            assertTrue(session.retentionGuard.finishingCleanExit.value)
            denied { session.save("access-B", "refresh-B", "account-B", null) }
            assertFalse(revoked)
            job.cancel()
            release.complete(Unit)
            withTimeout(5_000) { job.join() }
            assertTrue(cleaned)
            assertTrue(revoked)
            assertFalse(session.retentionGuard.finishingCleanExit.value)
            assertFalse(session.retentionGuard.isLocked)
            session.save("access-B", "refresh-B", "account-B", null)
            assertEquals("account-B", session.userId)
        } finally { release.complete(Unit); client.close() }
    }

    @Test fun delayedSignOutIntentCannotExitALaterAccount() = runBlocking {
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", "account-A", null)
        val oldIntent = requireNotNull(session.accountAccess())
        val client = HttpClient(MockEngine { respond("{}", HttpStatusCode.OK) })
        try {
            val auth = AuthRepository(session, client)
            assertTrue(auth.signOut(oldIntent))
            session.save("access-B", "refresh-B", "account-B", null)
            var cleaned = false
            assertFalse(auth.signOut(oldIntent) { cleaned = true })
            assertFalse(cleaned)
            assertEquals("account-B", session.userId)
            assertEquals("access-B", session.accessToken)
            assertFalse(session.retentionGuard.isLocked)
        } finally { client.close() }
    }

    @Test fun exactProfileVerifierMarkerIsPreservedAndRecoveryRulesStayStrict() {
        val marker = File(root, "profileInstalled")
        for (result in listOf(0, 1, 2, 3, 5 shl 16)) {
            val bytes = profileMarkerBytes(result = result)
            marker.writeBytes(bytes)
            assertNotNull(AccountTransitionEvidence(context).inspectCleanExit())
            assertNull(AccountTransitionEvidence(context).inspect())
            assertArrayEquals(bytes, marker.readBytes())
        }
    }

    @Test fun malformedOrLookalikeProfileMarkersRefuseWithoutChangingSessionOrBytes() {
        val session = SessionStore(context)
        session.save("access", "refresh", "11111111-1111-4111-8111-111111111111", null)
        val authority = requireNotNull(session.accountAccess())
        val marker = File(root, "profileInstalled")
        val samples = listOf(
            byteArrayOf(), profileMarkerBytes().copyOf(23), profileMarkerBytes() + byteArrayOf(0),
            profileMarkerBytes(schema = 2), profileMarkerBytes(result = 4),
            profileMarkerBytes(result = 1 shl 16), profileMarkerBytes(updated = 0),
            profileMarkerBytes(updated = Long.MAX_VALUE), profileMarkerBytes(size = -1),
        )
        samples.forEach { bytes ->
            marker.writeBytes(bytes)
            assertNull(session.cleanExit(authority))
            assertTrue(session.isAccountAccessCurrent(authority))
            assertTrue(session.hasSession)
            assertFalse(session.retentionGuard.isLocked)
            assertArrayEquals(bytes, marker.readBytes())
        }
        check(marker.delete()) // Isolated test-owned files only.
        val lookalike = File(root, "profileInstalled.bak")
        lookalike.writeBytes(profileMarkerBytes())
        assertNull(AccountTransitionEvidence(context).inspectCleanExit())
        assertArrayEquals(profileMarkerBytes(), lookalike.readBytes())
    }

    @Test fun profileMarkerDirectoriesLinksAndSpecialFilesAreRejected() {
        val marker = File(root, "profileInstalled")
        check(marker.mkdir())
        assertNull(AccountTransitionEvidence(context).inspectCleanExit())
        check(marker.delete())
        val target = File(root, "fixture-cache/framework-marker")
        check(target.parentFile!!.mkdirs() || target.parentFile!!.isDirectory)
        target.writeBytes(profileMarkerBytes())
        android.system.Os.symlink(target.path, marker.path)
        assertNull(AccountTransitionEvidence(context).inspectCleanExit())
        assertArrayEquals(profileMarkerBytes(), target.readBytes())
        check(marker.delete())
        android.system.Os.link(target.path, marker.path)
        assertNull(AccountTransitionEvidence(context).inspectCleanExit())
        check(marker.delete())
        android.system.Os.mkfifo(marker.path, 384)
        assertNull(AccountTransitionEvidence(context).inspectCleanExit())
        check(marker.delete())
        val nested = File(root, "nested/profileInstalled")
        check(nested.parentFile!!.mkdirs())
        nested.writeBytes(profileMarkerBytes())
        assertNull(AccountTransitionEvidence(context).inspectCleanExit())
    }

    @Test fun validPopulatedChemicalSnapshotsSurviveExitReloginAndRemainAccountScoped() {
        val a = "11111111-1111-4111-8111-111111111111"
        val b = "22222222-2222-4222-8222-222222222222"
        val session = SessionStore(context)
        session.save("access-A", "refresh-A", a, null)
        val store = com.rork.vinetrack.data.SavedChemicalLocalStore(context)
        val row = com.rork.vinetrack.data.model.SavedChemical("chemical-A", "vineyard-A", name = "Private A",
            vineyardPreferredRate = com.rork.vinetrack.data.chemical.VineyardPreferredRate(2.0, "L", "per_hectare"))
        assertTrue(store.save(a, "vineyard-A", listOf(row)))
        assertTrue(store.save(a, "empty-vineyard", emptyList()))
        val prefs = context.getSharedPreferences("vinetrack_saved_chemicals_local", 0)
        val before = prefs.all.toMap()
        assertNotNull(AccountTransitionEvidence(context).inspectCleanExit())
        assertNull(AccountTransitionEvidence(context).inspect(a))
        assertNotNull(session.cleanExit(requireNotNull(session.accountAccess())))
        session.retentionGuard.finishCleanExit()
        assertEquals(before, prefs.all)
        session.save("new-access-A", "new-refresh-A", a, null)
        assertEquals(listOf(row), com.rork.vinetrack.data.SavedChemicalLocalStore(context).load(a, "vineyard-A"))
        assertNotNull(session.cleanExit(requireNotNull(session.accountAccess())))
        session.retentionGuard.finishCleanExit()
        session.save("access-B", "refresh-B", b, null)
        val bStore = com.rork.vinetrack.data.SavedChemicalLocalStore(context)
        assertTrue(bStore.load(b, "vineyard-A").isEmpty())
        assertTrue(bStore.save(b, "vineyard-B", listOf(row.copy(id = "chemical-B", vineyardId = "vineyard-B", name = "Private B"))))
        assertNotNull(AccountTransitionEvidence(context).inspectCleanExit())
        before.forEach { (key, value) -> assertEquals(value, prefs.all[key]) }
    }

    @Test fun malformedUnknownOwnerAndMismatchedChemicalSnapshotsRefuseWithoutMutation() {
        val a = "11111111-1111-4111-8111-111111111111"
        val session = SessionStore(context)
        session.save("access", "refresh", a, null)
        val authority = requireNotNull(session.accountAccess())
        val prefs = context.getSharedPreferences("vinetrack_saved_chemicals_local", 0)
        val row = "{\"id\":\"chemical\",\"vineyard_id\":\"vineyard\"}"
        val cases = listOf(
            "vineyard" to "[]", "|vineyard" to "[]", "unknown|vineyard" to "[]", "$a|" to "[]", "$a|vineyard|extra" to "[]",
            "$a|vineyard" to "corrupt", "$a|vineyard" to "{}", "$a|vineyard" to "[{}]",
            "$a|vineyard" to "[{\"id\":\"chemical\",\"vineyard_id\":\"other\"}]",
            "$a|vineyard" to "[$row,$row]",
            "$a|vineyard" to "[{\"id\":\"chemical\",\"vineyard_id\":\"vineyard\",\"unknown_pending\":true}]",
            "$a|vineyard" to "[{\"id\":\"chemical\",\"vineyard_id\":\"vineyard\",\"rates\":[{\"unreadable\":true}]}]",
        )
        cases.forEach { (key, raw) ->
            check(prefs.edit().clear().putString(key, raw).commit())
            val before = prefs.all.toMap()
            assertNull(session.cleanExit(authority))
            assertEquals(before, prefs.all)
            assertTrue(session.isAccountAccessCurrent(authority))
            assertTrue(session.hasSession)
            assertFalse(session.retentionGuard.isLocked)
        }
        check(prefs.edit().clear().putInt("$a|vineyard", 1).commit())
        assertNull(session.cleanExit(authority))
        assertEquals(1, prefs.getInt("$a|vineyard", 0))
    }

    @Test fun unresolvedChemicalCreatesUpdatesAndUnreadableOutboxRefuseEvenWithValidSnapshot() {
        val a = "11111111-1111-4111-8111-111111111111"
        val session = SessionStore(context)
        session.save("access", "refresh", a, null)
        val authority = requireNotNull(session.accountAccess())
        assertTrue(com.rork.vinetrack.data.SavedChemicalLocalStore(context).save(a, "vineyard",
            listOf(com.rork.vinetrack.data.model.SavedChemical("chemical", "vineyard"))))
        val snapshots = context.getSharedPreferences("vinetrack_saved_chemicals_local", 0).all.toMap()
        val outbox = context.getSharedPreferences("vinetrack_pending_writes", 0)
        for (operation in listOf("create", "update")) for (status in listOf("pending", "in_progress", "failed", "blocked", "synced")) {
            check(PendingWriteStore(context).save(listOf(com.rork.vinetrack.data.model.PendingWrite(
                "operation", "saved_chemical", operation, "{}", "chemical", 1, 1, status = status))))
            val before = outbox.all.toMap()
            assertNull(session.cleanExit(authority))
            assertEquals(before, outbox.all)
            assertEquals(snapshots, context.getSharedPreferences("vinetrack_saved_chemicals_local", 0).all)
            assertTrue(session.isAccountAccessCurrent(authority))
        }
        check(outbox.edit().putString("pending_writes_json", "unreadable").commit())
        assertNull(session.cleanExit(authority))
        assertEquals("unreadable", outbox.getString("pending_writes_json", null))
        assertEquals(snapshots, context.getSharedPreferences("vinetrack_saved_chemicals_local", 0).all)
        assertTrue(session.hasSession)
        assertFalse(session.retentionGuard.isLocked)
    }

    private fun profileMarkerBytes(schema: Int = 1, result: Int = 0, updated: Long = 1L, size: Long = 0L): ByteArray =
        ByteArrayOutputStream().use { bytes ->
            java.io.DataOutputStream(bytes).use { out ->
                out.writeInt(schema); out.writeInt(result); out.writeLong(updated); out.writeLong(size)
            }
            bytes.toByteArray()
        }

    private fun mockAuthClient(
        response: suspend (String, String) -> Pair<Int, String>,
    ): HttpClient = HttpClient(MockEngine { request ->
        val (status, body) = response(request.url.encodedPath, request.url.parameters["grant_type"] ?: "")
        check(request.url.encodedPath.endsWith("/auth/v1/token"))
        check(request.url.parameters["grant_type"] == "refresh_token")
        respond(body, HttpStatusCode.fromValue(status), headersOf("Content-Type", "application/json"))
    }) {
        expectSuccess = false
        install(ContentNegotiation) { json(SupabaseClient.json) }
    }

    private fun denied(action: () -> Unit) {
        try { action(); fail("Unsafe account admission") } catch (_: IllegalStateException) { }
    }

    private class FixtureContext(val base: Context, val root: File, val prefix: String) : ContextWrapper(base) {
        val names = linkedSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = root
        override fun getCacheDir(): File = File(root, "fixture-cache").also { check(it.mkdirs() || it.isDirectory) }
        override fun getApplicationInfo(): android.content.pm.ApplicationInfo = android.content.pm.ApplicationInfo(base.applicationInfo).apply {
            dataDir = root.absolutePath
        }
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            return base.getSharedPreferences(prefix + name, mode)
        }
    }
}
