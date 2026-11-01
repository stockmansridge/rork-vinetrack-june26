package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.DomainCacheRepository
import com.rork.vinetrack.data.RecoverySnapshotStore
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.model.Pin
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.HttpStatusCode
import io.ktor.http.encodedPath
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic isolated installation only. No real account, real backend, Activity or store upload. */
@RunWith(AndroidJUnit4::class)
class ProfileInstallerRecoveryAndroidTest {
    private lateinit var fixture: FixtureContext
    private lateinit var root: File
    private val owner = "00000000-0000-0000-0000-0000000000a1"
    private val foreign = "00000000-0000-0000-0000-0000000000b2"
    private val marker get() = File(fixture.filesDir, ProfileInstallerSkipContract.FILE_NAME)
    private val packageInfo get() = fixture.packageManager.getPackageInfo(fixture.packageName, 0)

    @Before fun setup() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        root = File(base.filesDir, "profile-recovery-${UUID.randomUUID()}").also { check(it.mkdir()) }
        fixture = FixtureContext(base, root, "profile_recovery_${UUID.randomUUID()}_")
    }

    @After fun cleanup() {
        if (!::fixture.isInitialized) return
        check(fixture.prefix.startsWith("profile_recovery_") && root.name.startsWith("profile-recovery-"))
        check(root.canonicalPath.startsWith(fixture.base.filesDir.canonicalPath + File.separator))
        fixture.names.forEach { fixture.base.deleteSharedPreferences(fixture.prefix + it) }
        check(root.deleteRecursively())
    }

    @Test fun actualAndroidXWriterDoesNotBlockInitialAdmissionOrCleanExit() {
        // Exercise the installed AndroidX writer, not merely a hand-invented marker fixture.
        val writer = Class.forName("androidx.profileinstaller.ProfileInstaller")
            .getDeclaredMethod("noteProfileWrittenFor", PackageInfo::class.java, File::class.java)
        writer.isAccessible = true
        writer.invoke(null, packageInfo, fixture.filesDir)
        val before = marker.readBytes()
        assertEquals(8, before.size)
        val inspector = AccountTransitionEvidence(fixture)
        assertNotNull("AndroidX installer marker rejected: ${inspector.failureDiagnostic}", inspector.inspect())
        assertNotNull(inspector.inspectCleanExit())
        assertArrayEquals(before, marker.readBytes())
    }

    @Test fun originalAccountRecoversPopulatedStateWithBothRuntimeMarkersAfterUpdate() = runBlocking {
        val session = populatedLockedSession()
        marker.writeBytes(skipBytes(packageInfo.lastUpdateTime - 1L))
        writeVerifierMarker()
        val filesBefore = filesSnapshot()
        val recordsBefore = retainedSnapshot()
        assertTrue(AuthRecoveryRepository { client(owner) }.recover(session, "synthetic@example.invalid", "synthetic-password"))
        assertFalse(session.retentionGuard.isLocked)
        assertEquals(owner, session.userId)
        assertEquals(filesBefore, filesSnapshot())
        assertEquals(recordsBefore, retainedSnapshot())
        assertEquals("original-pin", DomainCacheRepository(fixture).loadPins(owner, "vineyard")!!.single().id)
        assertTrue(SessionStore(fixture).hasSession)
        assertFalse(SessionStore(fixture).retentionGuard.isLocked)
    }

    @Test fun runtimeMarkerDoesNotAdmitWrongVerifiedAccount() = runBlocking {
        val session = populatedLockedSession()
        marker.writeBytes(skipBytes(packageInfo.lastUpdateTime))
        val before = retainedSnapshot()
        val filesBefore = filesSnapshot()
        assertTrue(runCatching {
            AuthRecoveryRepository { client(foreign) }.recover(session, "synthetic@example.invalid", "synthetic-password")
        }.isFailure)
        assertTrue(session.retentionGuard.isLocked)
        assertFalse(session.hasSession)
        assertEquals(before, retainedSnapshot())
        assertEquals(filesBefore, filesSnapshot())
    }

    @Test fun runtimeMarkerDoesNotAdmitRevokedVineyardMembership() = runBlocking {
        val session = populatedLockedSession()
        marker.writeBytes(skipBytes(packageInfo.lastUpdateTime))
        val before = retainedSnapshot()
        val filesBefore = filesSnapshot()
        assertTrue(runCatching {
            AuthRecoveryRepository { client(owner, member = false) }.recover(session, "synthetic@example.invalid", "synthetic-password")
        }.isFailure)
        assertTrue(session.retentionGuard.isLocked)
        assertFalse(session.hasSession)
        assertEquals(before, retainedSnapshot())
        assertEquals(filesBefore, filesSnapshot())
    }

    @Test fun malformedOrFutureMarkersStayProtectedAndUnchanged() {
        val valid = skipBytes(packageInfo.lastUpdateTime)
        val variants = listOf(byteArrayOf(), valid.copyOf(7), valid + byteArrayOf(0), ByteArray(24),
            skipBytes(0), skipBytes(-1), skipBytes(packageInfo.lastUpdateTime + 1L), "12345678".toByteArray())
        variants.forEach { bytes ->
            marker.writeBytes(bytes)
            val inspector = AccountTransitionEvidence(fixture)
            assertNull(inspector.inspect(owner))
            assertEquals("PROFILE_INSTALLER_MARKER_CONTRACT", inspector.failureDiagnostic?.rule)
            assertArrayEquals(bytes, marker.readBytes())
            val diagnostics = RecoveryDiagnostics.format("RETAINED_EVIDENCE", inspector.failureDiagnostic)
            assertFalse(diagnostics.contains(marker.name))
            assertFalse(diagnostics.contains(owner))
        }
    }

    @Test fun symbolicAndHardLinksAreNotAdmittedOrChanged() {
        val target = File(root, "synthetic-target").also { it.writeBytes(skipBytes(packageInfo.lastUpdateTime)) }
        val before = target.readBytes()
        listOf("symbolic", "hard", "dangling").forEach { kind ->
            when (kind) {
                "symbolic" -> Os.symlink(target.path, marker.path)
                "hard" -> Os.link(target.path, marker.path)
                else -> Os.symlink(File(root, "missing-target").path, marker.path)
            }
            val inspector = AccountTransitionEvidence(fixture)
            assertNull(inspector.inspect(owner))
            assertEquals("PROFILE_INSTALLER_MARKER_CONTRACT", inspector.failureDiagnostic?.rule)
            assertArrayEquals(before, target.readBytes())
            if (kind != "hard") assertTrue(Os.readlink(marker.path).isNotBlank())
            check(marker.delete()) // Only the synthetic fixture link is removed between cases.
        }
    }

    @Test fun directoryUsingMarkerNameCannotHideRetainedWork() {
        check(marker.mkdir())
        val evidence = File(marker, "private-note").also { it.writeText("synthetic retained work") }
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals("PROFILE_INSTALLER_MARKER_CONTRACT", inspector.failureDiagnostic?.rule)
        assertEquals("synthetic retained work", evidence.readText())
    }

    @Test fun validMarkerDoesNotExemptOtherUnknownFiles() {
        marker.writeBytes(skipBytes(packageInfo.lastUpdateTime))
        val evidence = File(fixture.filesDir, "private-note").also { it.writeText("synthetic retained work") }
        val before = filesSnapshot()
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals("FILES_UNREVIEWED_CONTENT", inspector.failureDiagnostic?.rule)
        assertEquals(before, filesSnapshot())
        assertFalse(RecoveryDiagnostics.format("RETAINED_EVIDENCE", inspector.failureDiagnostic).contains(evidence.name))
    }

    @Test fun validMarkerDoesNotReleaseRetainedPhotoFiles() {
        marker.writeBytes(skipBytes(packageInfo.lastUpdateTime))
        val directory = File(fixture.filesDir, "pending_pin_photos").also { check(it.mkdir()) }
        File(directory, "synthetic-photo.jpg").writeBytes(byteArrayOf(1, 2, 3))
        val before = filesSnapshot()
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals("FILES_PENDING_PIN_PHOTOS_RETAINED", inspector.failureDiagnostic?.rule)
        assertEquals(before, filesSnapshot())
    }

    @Test fun similarlyNamedOrBackupFilesAreNotExempted() {
        val lookalike = File(fixture.filesDir, ProfileInstallerSkipContract.FILE_NAME + ".bak")
        val before = skipBytes(packageInfo.lastUpdateTime)
        lookalike.writeBytes(before)
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals("FILES_UNREVIEWED_CONTENT", inspector.failureDiagnostic?.rule)
        assertArrayEquals(before, lookalike.readBytes())
    }

    private fun populatedLockedSession(): SessionStore {
        val session = SessionStore(fixture)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        DomainCacheRepository(fixture).savePins(owner, "vineyard", listOf(Pin("original-pin", "vineyard", createdBy = owner)))
        assertTrue(RecoverySnapshotStore.captureBeforeMutation(fixture, "vineyard").isPreserved)
        session.clear()
        assertTrue(session.retentionGuard.isLocked)
        return session
    }

    private fun retainedSnapshot(): Map<String, Map<String, *>> =
        listOf("vinetrack_domain_cache", "vinetrack_recovery_snapshots_v2", "vinetrack_pending_writes", "vinetrack_local_planning")
            .associateWith { fixture.getSharedPreferences(it, 0).all.toMap() }

    private fun filesSnapshot(): Map<String, List<Byte>> = fixture.filesDir.walkTopDown().filter { it.isFile }
        .associate { it.relativeTo(fixture.filesDir).path to it.readBytes().toList() }

    private fun skipBytes(time: Long): ByteArray = ByteArrayOutputStream().use { bytes ->
        DataOutputStream(bytes).use { it.writeLong(time) }
        bytes.toByteArray()
    }

    private fun writeVerifierMarker() {
        DataOutputStream(File(fixture.filesDir, "profileInstalled").outputStream()).use {
            it.writeInt(1); it.writeInt(0); it.writeLong(packageInfo.lastUpdateTime - 1L); it.writeLong(0L)
        }
    }

    private fun client(account: String, member: Boolean = true): HttpClient = HttpClient(MockEngine { request ->
        val body = when {
            request.url.encodedPath.endsWith("/token") -> "{\"access_token\":\"returning-access\",\"refresh_token\":\"returning-refresh\"}"
            request.url.encodedPath.endsWith("/user") -> "{\"id\":\"$account\"}"
            request.url.encodedPath.endsWith("/vineyard_members") -> if (member) "[{\"vineyard_id\":\"vineyard\",\"role\":\"operator\"}]" else "[]"
            request.url.encodedPath.endsWith("/vineyards") -> "[{\"id\":\"vineyard\"}]"
            request.url.encodedPath.endsWith("/logout") -> "{}"
            else -> error("Unexpected recovery request")
        }
        respond(body, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
    }) { install(ContentNegotiation) { json(SupabaseClient.json) } }

    private class FixtureContext(val base: Context, val root: File, val prefix: String) : ContextWrapper(base) {
        val names = linkedSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = File(root, "files").also { check(it.mkdirs() || it.isDirectory) }
        override fun getCacheDir(): File = File(root, "cache").also { check(it.mkdirs() || it.isDirectory) }
        override fun getApplicationInfo(): ApplicationInfo = ApplicationInfo(base.applicationInfo).apply { dataDir = root.absolutePath }
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            return base.getSharedPreferences(prefix + name, mode)
        }
    }
}
