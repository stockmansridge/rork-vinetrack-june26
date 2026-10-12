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
        val client = mockAuthClient { _, _ -> 400 to "{\"code\":\"refresh_token_not_found\"}" }
        try {
            assertEquals(SessionValidity.Rejected, AuthRepository(session, client).revalidateSession())
            assertTrue(session.retentionGuard.isLocked)
            assertEquals(owner, SessionStore(context).recoveryPrincipal)
            assertEquals(before, context.getSharedPreferences("vinetrack_pending_writes", 0).all)
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
                val result = executor.submit<Boolean> { editor.commit() }
                assertFalse(result.get(5, java.util.concurrent.TimeUnit.SECONDS))
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
        denied { store.markUploaded("pin", 1) }
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
        assertEquals(2, files.size)
        assertTrue(files.any { it.readBytes().contentEquals(byteArrayOf(4, 5, 6)) })
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
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            return base.getSharedPreferences(prefix + name, mode)
        }
    }
}
