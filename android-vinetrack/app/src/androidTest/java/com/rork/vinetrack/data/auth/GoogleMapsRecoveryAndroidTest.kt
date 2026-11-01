package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.DomainCacheRepository
import com.rork.vinetrack.data.PruningStore
import com.rork.vinetrack.data.PruningYieldSettingsStore
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
import java.io.DataOutputStream
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Synthetic layout regression, NOT a capture of the original installation or current Maps writer.
 * The two pruning tests document remaining blockers; passing them does NOT close the incident.
 */
@RunWith(AndroidJUnit4::class)
class GoogleMapsRecoveryAndroidTest {
    private lateinit var fixture: FixtureContext
    private lateinit var root: File
    private val owner = "00000000-0000-0000-0000-0000000000a1"
    private val foreign = "00000000-0000-0000-0000-0000000000b2"

    @Before fun setup() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        root = File(base.cacheDir, "maps-recovery-${UUID.randomUUID()}").canonicalFile.also { check(it.mkdir()) }
        fixture = FixtureContext(base, root, "maps_recovery_${UUID.randomUUID()}_")
    }
    @After fun cleanup() {
        if (!::fixture.isInitialized) return
        check(root.name.startsWith("maps-recovery-") && fixture.prefix.startsWith("maps_recovery_"))
        fixture.names.forEach { fixture.base.deleteSharedPreferences(fixture.prefix + it) }
        check(root.deleteRecursively())
    }

    @Test fun threeRuntimeFilesDoNotLockTokenlessInitialAdmission() {
        writeRuntimeFiles()
        val before = filesSnapshot()
        assertNotNull(AccountTransitionEvidence(fixture).inspectCleanExit())
        assertFalse(SessionStore(fixture).retentionGuard.isLocked)
        assertEquals(before, filesSnapshot())
    }

    @Test fun originalAccountRecoversSyntheticSevenEntryLayoutAndRetainedPins() = runBlocking {
        val session = populatedSession()
        writeSevenEntryLayout()
        val beforeFiles = filesSnapshot()
        val beforeStores = retainedSnapshot()
        assertTrue(AuthRecoveryRepository { client(owner) }.recover(session, "synthetic@example.invalid", "synthetic-password"))
        assertFalse(session.retentionGuard.isLocked)
        assertEquals(owner, session.userId)
        assertEquals(beforeFiles, filesSnapshot())
        assertEquals(beforeStores, retainedSnapshot())
        assertEquals("original-pin", DomainCacheRepository(fixture).loadPins(owner, "vineyard")!!.single().id)
        assertTrue(SessionStore(fixture).hasSession)
    }

    @Test fun runtimeFilesCannotReleaseWrongAccount() = runBlocking {
        val session = populatedSession()
        writeSevenEntryLayout()
        val before = retainedSnapshot()
        val filesBefore = filesSnapshot()
        assertTrue(runCatching { AuthRecoveryRepository { client(foreign) }
            .recover(session, "synthetic@example.invalid", "synthetic-password") }.isFailure)
        assertTrue(session.retentionGuard.isLocked)
        assertEquals(before, retainedSnapshot())
        assertEquals(filesBefore, filesSnapshot())
    }

    @Test fun runtimeFilesCannotReleaseRevokedVineyardAccess() = runBlocking {
        val session = populatedSession()
        writeSevenEntryLayout()
        val before = retainedSnapshot()
        val filesBefore = filesSnapshot()
        assertTrue(runCatching { AuthRecoveryRepository { client(owner, member = false) }
            .recover(session, "synthetic@example.invalid", "synthetic-password") }.isFailure)
        assertTrue(session.retentionGuard.isLocked)
        assertEquals(before, retainedSnapshot())
        assertEquals(filesBefore, filesSnapshot())
    }

    @Test fun unknownFileStillBlocksAlongsideAllThreeRuntimeFiles() {
        writeSevenEntryLayout()
        File(fixture.filesDir, "private-work").writeText("synthetic unfinished work")
        val before = filesSnapshot()
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals("FILES_UNREVIEWED_CONTENT", inspector.failureDiagnostic?.rule)
        assertEquals(before, filesSnapshot())
    }

    @Test fun runtimeNameAsDirectoryProducesSpecificContractFailure() {
        val directory = File(fixture.filesDir, "_m_t").also { check(it.mkdir()) }
        val work = File(directory, "work").also { it.writeText("synthetic work") }
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals("MAPS_RUNTIME_FILE_CONTRACT", inspector.failureDiagnostic?.rule)
        assertEquals("synthetic work", work.readText())
    }

    @Test fun remainingBlockerEvenWriterProducedEmptyPruningCacheIsNotYetSupported() {
        val session = SessionStore(fixture)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        PruningStore(fixture).saveEntries("vineyard", emptyList())
        writeSevenEntryLayout()
        val before = fixture.getSharedPreferences("vinetrack_pruning", 0).all.toMap()
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals("vinetrack_pruning", inspector.failureCategory)
        assertEquals(before, fixture.getSharedPreferences("vinetrack_pruning", 0).all.toMap())
    }

    @Test fun remainingBlockerEvenWriterProducedEmptyYieldSettingsIsNotYetSupported() {
        val session = SessionStore(fixture)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        PruningYieldSettingsStore(fixture).save("vineyard", emptyList())
        writeSevenEntryLayout()
        val before = fixture.getSharedPreferences("vinetrack_pruning_yield_settings", 0).all.toMap()
        val inspector = AccountTransitionEvidence(fixture)
        assertNull(inspector.inspect(owner))
        assertEquals("vinetrack_pruning_yield_settings", inspector.failureCategory)
        assertEquals(before, fixture.getSharedPreferences("vinetrack_pruning_yield_settings", 0).all.toMap())
    }

    private fun populatedSession(): SessionStore {
        val session = SessionStore(fixture)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        DomainCacheRepository(fixture).savePins(owner, "vineyard", listOf(Pin("original-pin", "vineyard", createdBy = owner)))
        assertTrue(RecoverySnapshotStore.captureBeforeMutation(fixture, "vineyard").isPreserved)
        session.clear()
        return session
    }
    private fun writeRuntimeFiles() {
        mapOf("DATA_ServerControlledParametersManager.data.v1.${fixture.packageName}" to 44468,
            "SavedClientParameters.data.cs" to 55534, "_m_t" to 234).forEach { (name, length) ->
            File(fixture.filesDir, name).writeBytes(ByteArray(length) { (it % 251).toByte() })
        }
    }
    private fun writeSevenEntryLayout() {
        writeRuntimeFiles()
        val update = fixture.packageManager.getPackageInfo(fixture.packageName, 0).lastUpdateTime
        DataOutputStream(File(fixture.filesDir, "profileInstalled").outputStream()).use {
            it.writeInt(1); it.writeInt(0); it.writeLong(update); it.writeLong(0)
        }
        DataOutputStream(File(fixture.filesDir, ProfileInstallerSkipContract.FILE_NAME).outputStream()).use { it.writeLong(update) }
        File(fixture.filesDir, "canopy_reference_images").mkdir()
        File(fixture.filesDir, "vineyard_logos").mkdir()
        assertEquals(7, fixture.filesDir.listFiles()!!.size)
    }
    private fun retainedSnapshot() = listOf("vinetrack_domain_cache", "vinetrack_recovery_snapshots_v2")
        .associateWith { fixture.getSharedPreferences(it, 0).all.toMap() }
    private fun filesSnapshot() = fixture.filesDir.walkTopDown().filter { it.isFile }
        .associate { it.relativeTo(fixture.filesDir).path to it.readBytes().toList() }
    private fun client(account: String, member: Boolean = true) = HttpClient(MockEngine { request ->
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
    private class FixtureContext(val base: Context, private val root: File, val prefix: String) : ContextWrapper(base) {
        val names = linkedSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getFilesDir() = File(root, "files").also { check(it.mkdirs() || it.isDirectory) }
        override fun getCacheDir() = File(root, "cache").also { check(it.mkdirs() || it.isDirectory) }
        override fun getApplicationInfo() = ApplicationInfo(base.applicationInfo).apply { dataDir = root.absolutePath }
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            return base.getSharedPreferences(prefix + name, mode)
        }
    }
}
