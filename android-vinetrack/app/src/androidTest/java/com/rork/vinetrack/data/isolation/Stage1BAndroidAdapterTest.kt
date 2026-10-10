package com.rork.vinetrack.data.isolation

import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.AtomicFile
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.BuildConfig
import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.PendingWriteRepository
import com.rork.vinetrack.data.PendingWriteStore
import com.rork.vinetrack.data.PendingPhotoRepository
import com.rork.vinetrack.data.PendingPhotoStore
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.insights.SharedPreferencesKeyValueStore
import com.rork.vinetrack.data.insights.VineyardInsightsStore
import com.rork.vinetrack.data.insights.VineyardInsightsController
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Isolated test-created names and directories; never opens existing user preferences, Trips or JPEGs. */
@RunWith(AndroidJUnit4::class)
class Stage1BAndroidAdapterTest {
    private lateinit var context: FixtureContext
    private lateinit var root: File
    private val json = Json { encodeDefaults = true }

    @Before fun prepare() {
        // Instrumentation executes with the target UID; the test APK's own data directory is not writable.
        // All accesses below are confined to random stage1b_ preference names and a random stage1b- directory.
        val testContext = InstrumentationRegistry.getInstrumentation().targetContext
        check(testContext.packageName == "com.rork.vinetrack")
        check(testContext.filesDir.mkdirs() || testContext.filesDir.isDirectory) { "Cannot create test fixture parent" }
        root = File(testContext.filesDir.canonicalFile, "stage1b-${UUID.randomUUID()}").also { check(it.mkdirs()) { "Cannot create isolated test root" } }
        context = FixtureContext(testContext, root, "stage1b_${UUID.randomUUID()}_")
        assertFalse(BuildConfig.FIELD_STORAGE_ISOLATION_ACTIVATED)
    }
    @After fun cleanupOnlyTestOwnedStorage() {
        if (!::context.isInitialized) return
        check(context.prefix.startsWith("stage1b_") && root.name.startsWith("stage1b-"))
        context.names.forEach { context.base.deleteSharedPreferences(context.prefix + it) }
        check(root.canonicalPath.startsWith(context.base.filesDir.canonicalPath + File.separator))
        root.deleteRecursively()
    }
    private fun sources(): List<RawEvidenceSource> = context.names.sorted().flatMap { name ->
        val file = File(File(context.base.applicationInfo.dataDir).canonicalFile, "shared_prefs/${context.prefix}$name.xml")
        listOf(file, File(file.path + ".bak")).filter { it.isFile }.map { RawEvidenceSource("sharedpref/${it.name.removePrefix(context.prefix)}", it) }
    } + context.filesDir.walkTopDown().filter { it.isFile }.map {
        RawEvidenceSource("files/${it.relativeTo(context.filesDir).invariantSeparatorsPath}", it)
    }.toList()
    private fun vault(disk: IsolationDisk = AndroidIsolationSafety.disk()) = RawEvidenceVault(File(root, "vault"), disk, { sources() })
    private fun jpeg(): ByteArray {
        val image = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
        try {
            image.eraseColor(0xff397351.toInt())
            return ByteArrayOutputStream().also { check(image.compress(Bitmap.CompressFormat.JPEG, 90, it)) }.toByteArray()
        } finally { image.recycle() }
    }
    private fun denied(action: () -> Unit) {
        try { action(); fail("Unsafe operation accepted") } catch (_: IllegalStateException) { }
    }

    @Test fun realSharedPreferencesConstructorRecoveryRunsOnlyAfterRawVaultCommit() {
        val prefs = context.getSharedPreferences("vinetrack_pending_writes", Context.MODE_PRIVATE)
        val original = PendingWrite(id = "stable", entityType = PendingEntityType.WORK_TASK, opType = PendingOpType.CREATE, clientId = "task",
            payloadJson = "{\"vineyardId\":\"shared\"}", status = PendingWriteStatus.IN_PROGRESS, createdAt = 1, updatedAt = 1)
        check(prefs.edit().putString("pending_writes_json", json.encodeToString(ListSerializer(PendingWrite.serializer()), listOf(original))).commit())
        val rawBefore = sources().single().file.readBytes()
        val manifest = vault().preserve()
        val repository = PendingWriteRepository(PendingWriteStore(context))
        assertEquals(PendingWriteStatus.FAILED, repository.list().single().status)
        assertArrayEquals(rawBefore, File(root, "vault/${manifest.entries.single().blob}").readBytes())
        assertFalse(rawBefore.contentEquals(sources().single().file.readBytes()))
        assertEquals(manifest, vault().verifyArchive())
        // This proves the actual legacy Android adapter repair order, NOT permission to expose legacy rows.
    }

    @Test fun actualAndroidPhotoAdapterCopiesValidJpegAndVaultRetainsAbsolutePathAndBytes() {
        val repository = PendingPhotoRepository(context.filesDir, PendingPhotoStore(context))
        val bytes = jpeg()
        val row = repository.enqueue("pin", "shared", bytes)
        val originalPath = row.localPath
        val before = sources().associate { it.identity to it.file.readBytes() }
        val manifest = vault().preserve()
        manifest.entries.forEach { assertArrayEquals(before.getValue(it.source), File(root, "vault/${it.blob}").readBytes()) }
        val restarted = PendingPhotoRepository(context.filesDir, PendingPhotoStore(context))
        assertEquals(originalPath, restarted.list().single().localPath)
        assertArrayEquals(bytes, File(originalPath).readBytes())
    }

    @Test fun unreadableActualTripPreferencesStayRawAndNeverBecomeAvailableClaimInHarness() {
        val prefs = context.getSharedPreferences("vinetrack_active_trip", Context.MODE_PRIVATE)
        check(prefs.edit().putString("active_trip_snapshot_json", "{unreadable-owner-evidence").commit())
        assertNull(ActiveTripStore(context).load())
        val before = sources().single().file.readBytes()
        val trial = FieldIsolationTrial(vault(), File(root, "accounts"), AndroidIsolationSafety.disk())
        assertEquals(FieldBootstrapState.PreservedNotActivated, trial.bootstrap())
        val b = trial.acceptVerifiedSession("B", setOf("shared"))
        denied { trial.append(b, "shared", "active-trip", "B", "overwrite".toByteArray()) }
        assertArrayEquals(before, sources().single().file.readBytes())
    }

    @Test fun realScoutAndroidConstructorRepairOccursAfterPreservingUnrepairedXml() {
        val prefs = context.getSharedPreferences("vineyard_insights_preview", Context.MODE_PRIVATE)
        val store = VineyardInsightsStore(SharedPreferencesKeyValueStore(prefs))
        val seeded = VineyardInsightsController(store)
        seeded.startVisit("shared", "A", null, 7, 1)
        check(prefs.edit().remove("pending_operations").commit())
        assertTrue(store.loadQueue().isEmpty())
        val before = sources().single().file.readBytes()
        val manifest = vault().preserve()
        VineyardInsightsController(VineyardInsightsStore(SharedPreferencesKeyValueStore(prefs)))
        assertEquals(1, store.loadQueue().size)
        assertArrayEquals(before, File(root, "vault/${manifest.entries.single().blob}").readBytes())
        assertFalse(before.contentEquals(sources().single().file.readBytes()))
    }

    @Test fun actualAtomicFileBackupRestorationCannotDestroyRetainedOriginalBackup() {
        val file = File(context.filesDir, "pin_capture_evidence_recovery_v2.json")
        file.writeText("incomplete-new-primary")
        val backup = File(file.path + ".bak").also { it.writeText("original-backup") }
        val manifest = vault().preserve()
        assertEquals("original-backup", AtomicFile(file).openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        assertFalse(backup.exists())
        val entry = manifest.entries.single { it.source.endsWith(".bak") }
        assertEquals("original-backup", File(root, "vault/${entry.blob}").readText())
    }

    @Test fun androidBinaryInterruptedMetadataPublicationResumesWithAccountIsolation() {
        val photo = File(context.filesDir, "original.jpg").also { it.writeBytes(jpeg()) }
        val disk = IsolationDisk({ directory ->
            val fd = android.system.Os.open(directory.path, android.system.OsConstants.O_RDONLY, 0)
            try { android.system.Os.fsync(fd) } finally { android.system.Os.close(fd) }
        }) { if (it == "before-rename:stable.record") error("simulated interruption") }
        val broken = AccountEvidenceStore(File(root, "accounts"), disk)
        val a = broken.authenticateVerifiedAccount("A", setOf("shared"))
        denied { broken.appendBinary(a, "shared", "photo", "capture", "stable", photo, photo.absolutePath) }
        val restart = AccountEvidenceStore(File(root, "accounts"), AndroidIsolationSafety.disk())
        val newA = restart.authenticateVerifiedAccount("A", setOf("shared"))
        assertEquals("stable", restart.appendBinary(newA, "shared", "photo", "capture", "stable", photo, photo.absolutePath))
        val output = ByteArrayOutputStream()
        assertTrue(restart.copyBinary(newA, "shared", "photo", "stable", output, photo.absolutePath))
        assertArrayEquals(photo.readBytes(), output.toByteArray())
        val b = restart.authenticateVerifiedAccount("B", setOf("shared"))
        assertFalse(restart.copyBinary(b, "shared", "photo", "stable", ByteArrayOutputStream()))
        denied { restart.acknowledge(newA, "shared", "photo", "stable") }
        assertTrue(photo.exists())
    }

    @Test fun androidVolumeAndLowSpaceMeasurementUsesStreamingAndExactIntegrity() {
        val directory = File(context.filesDir, "pending_pin_photos").also { check(it.mkdirs()) }
        val block = ByteArray(64 * 1024) { (it % 251).toByte() }
        // 128 MiB / 64 retained 2 MiB captures. Synthetic bytes, not camera JPEG decode/render timing.
        repeat(64) { index -> FileOutputStream(File(directory, "$index.jpg")).use { out -> repeat(32) { out.write(block) }; out.fd.sync() } }
        val originalBytes = sources().sumOf { it.file.length() }
        val disk = AndroidIsolationSafety.disk()
        val deniedVault = RawEvidenceVault(File(root, "low-space"), disk, { sources() }, { 1L })
        denied { deniedVault.preserve() }
        assertFalse(File(root, "low-space/prepared.json").exists())
        val start = SystemClock.elapsedRealtimeNanos()
        val manifest = vault().preserve()
        val initialMs = (SystemClock.elapsedRealtimeNanos() - start) / 1_000_000.0
        val second = SystemClock.elapsedRealtimeNanos()
        assertEquals(manifest, vault().verifyArchive())
        val verifyMs = (SystemClock.elapsedRealtimeNanos() - second) / 1_000_000.0
        val vaultBytes = File(root, "vault").walkTopDown().filter { it.isFile }.sumOf { it.length() }
        manifest.entries.forEach { entry -> assertEquals(entry.sha256, IsolationDisk.digest(sources().single { it.identity == entry.source }.file)) }
        val report = "STAGE1B_ANDROID_VOLUME sourceBytes=$originalBytes vaultBytes=$vaultBytes entries=${manifest.entries.size} initialMs=$initialMs verifyMs=$verifyMs sdk=${android.os.Build.VERSION.SDK_INT} model=${android.os.Build.MODEL} bufferBytes=65536"
        Log.i("Stage1B", report)
        println(report)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply { putString("stream", report + "\n") })
        assertEquals(128L * 1024 * 1024, originalBytes)
        assertTrue(vaultBytes - originalBytes < 128 * 1024)
    }

    private class FixtureContext(val base: Context, val root: File, val prefix: String) : ContextWrapper(base) {
        val names = mutableSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = File(root, "legacy-files").also { check(it.mkdirs() || it.isDirectory) }
        override fun getCacheDir(): File = File(root, "legacy-cache").also { check(it.mkdirs() || it.isDirectory) }
        override fun getSharedPreferences(name: String, mode: Int): android.content.SharedPreferences {
            check(name in ReviewedBusinessInventory.businessPreferences)
            names += name
            return base.getSharedPreferences(prefix + name, mode)
        }
    }
}
