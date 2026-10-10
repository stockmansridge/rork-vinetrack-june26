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
