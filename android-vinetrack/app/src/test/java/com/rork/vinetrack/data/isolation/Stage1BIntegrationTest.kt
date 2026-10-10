package com.rork.vinetrack.data.isolation

import com.rork.vinetrack.data.PendingWriteRepository
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.insights.PairedGrowthCaptureCoordinator
import com.rork.vinetrack.data.insights.PairedGrowthCaptureJournal
import com.rork.vinetrack.data.insights.VineyardInsightsController
import com.rork.vinetrack.data.insights.VineyardInsightsStore
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Executes actual repository/controller constructors through disabled storage seams, not MainActivity or live auth. */
class Stage1BIntegrationTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun denied(action: () -> Unit) {
        try { action(); fail("Unsafe operation accepted") } catch (_: IllegalStateException) { }
    }
    private fun accounts(disk: IsolationDisk = fixtureDisk()) = AccountEvidenceStore(File(temporary.root, "accounts"), disk)
    private fun source() = File(temporary.root, "legacy.xml").also { it.writeText("original unreadable field evidence") }
    private fun vault(source: File, disk: IsolationDisk = fixtureDisk()) = RawEvidenceVault(File(temporary.root, "vault"), disk,
        { listOf(RawEvidenceSource("sharedpref/vinetrack_pending_writes.xml", source)) })
    private fun journal(id: String) = PairedGrowthCaptureJournal(operationId = id, pinId = "$id-pin", growthRecordId = "$id-growth",
        vineyardId = "shared", stageCode = "EL19", observedAtIso = "2026-10-10T01:00:00Z", originatingFeature = "growth",
        createdAtMillis = 1, updatedAtMillis = 1)

    @Test fun constructorsAndWorkerFactoryCannotRunBeforeVerifiedBaseline() {
        val original = source()
        val store = accounts()
        val fence = FieldHandoverFence(setOf("all-stores")).also { it.register("all-stores") }
        val boundary = FieldStartupBoundary(fence, vault(original), { false }, store)
        denied { boundary.openVerifiedAccount("A", setOf("shared")) }
        assertEquals(FieldStartupResult.PreservedLocked, boundary.bootstrap())
        val a = boundary.openVerifiedAccount("A", setOf("shared"))
        val values = DisabledOwnedValues(store, a, "shared", "writes")
        val adapter = DisabledPendingWriteAdapter(values, "shared")
        // Seed NEW, explicitly scoped work; never import the raw original.
        val repo = boundary.construct(a, "shared") { PendingWriteRepository(adapter) }
        val queued = repo.enqueue(PendingEntityType.WORK_TASK, PendingOpType.CREATE, "{\"vineyardId\":\"shared\"}")
        repo.updateStatus(queued.id, PendingWriteStatus.IN_PROGRESS)
        val effects = mutableListOf<String>()
        boundary.construct(a, "shared") {
            assertTrue(File(temporary.root, "vault/verified.json").isFile)
            effects += "constructor"
            PendingWriteRepository(adapter).also { assertEquals(PendingWriteStatus.FAILED, it.list().single().status) }
        }
        boundary.construct(a, "shared") { effects += "observer" }
        boundary.construct(a, "shared") { effects += "background-worker" }
        boundary.construct(a, "shared") { effects += "exporter" }
        assertEquals(listOf("constructor", "observer", "background-worker", "exporter"), effects)
        boundary.rejectSession()
        denied { boundary.construct(a, "shared") { effects += "stale-worker" } }
        assertEquals("original unreadable field evidence", original.readText())
    }

    @Test fun failedPreservationInvokesNoFactoryAndLeavesOriginal() {
        val original = source()
        val store = accounts()
        val fence = FieldHandoverFence(setOf("all")).also { it.register("all") }
        val disk = fixtureDisk { if (it == "before-rename:verified.json") error("failed commit") }
        val boundary = FieldStartupBoundary(fence, vault(original, disk), { false }, store)
        assertEquals(FieldStartupResult.RecoveryRequired, boundary.bootstrap())
        denied { boundary.openVerifiedAccount("A", setOf("shared")) }
        assertFalse(File(temporary.root, "accounts").exists())
        assertEquals("original unreadable field evidence", original.readText())
    }

    @Test fun activeTripAndIncompleteFenceDeferWithoutConstructingOrPausingFieldWork() {
        val original = source()
        val fence = FieldHandoverFence(setOf("gps", "photos"))
        fence.register("gps")
        denied { fence.idleBaseline({ false }) { fail("missing writer coverage") } }
        fence.register("photos")
        assertNull(fence.idleBaseline({ true }) { fail("active Trip cannot be paused") })
        fence.legacyOperation("gps") { original.appendText(";GPS-1.234567890123") }
        assertFalse(File(temporary.root, "vault").exists())
        assertTrue(original.readText().endsWith("GPS-1.234567890123"))
    }

    @Test fun arrivingWriterCompletesBeforeIdleBaselineAndHistoricalArchiveDoesNotFreezeFutureLaunches() {
        val original = source()
        val fence = FieldHandoverFence(setOf("writer")).also { it.register("writer") }
        val started = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val writer = Thread {
            fence.legacyOperation("writer") {
                started.countDown()
                check(finish.await(5, TimeUnit.SECONDS))
                original.appendText(";arriving-work")
            }
        }
        writer.start()
        assertTrue(started.await(5, TimeUnit.SECONDS))
        assertNull(fence.idleBaseline({ false }) { fail("running writer must not be interrupted") })
        finish.countDown()
        writer.join(5000)
        assertFalse(writer.isAlive)
        val raw = vault(original)
        val baseline = checkNotNull(fence.idleBaseline({ false }) { raw.preserve() })
        assertEquals(original.readText(), File(temporary.root, "vault/${baseline.entries.single().blob}").readText())
        fence.legacyOperation("writer") { original.appendText(";later-field-work") }
        assertEquals(baseline, raw.verifyArchive())
        assertTrue(original.readText().endsWith("later-field-work"))
        denied { raw.preserve() } // A changed source cannot silently replace the retained historical generation.
    }

    @Test fun productionWriteRepositoryAdapterRejectsSharedVineyardOtherAccountAndStaleCallbacks() {
        val store = accounts()
        val a = store.authenticateVerifiedAccount("A", setOf("shared"))
        val adapter = DisabledPendingWriteAdapter(DisabledOwnedValues(store, a, "shared", "writes"), "shared")
        val repo = PendingWriteRepository(adapter)
        repo.enqueue(PendingEntityType.PIN, PendingOpType.UPDATE, "{\"vineyard_id\":\"shared\",\"latitude\":1.234567890123}")
        val b = store.authenticateVerifiedAccount("B", setOf("shared"))
        val bRepo = PendingWriteRepository(DisabledPendingWriteAdapter(DisabledOwnedValues(store, b, "shared", "writes"), "shared"))
        assertTrue(bRepo.list().isEmpty())
        denied { adapter.load() }
        denied { adapter.clear() }
        denied { repo.enqueue(PendingEntityType.PIN, PendingOpType.UPDATE, "{\"vineyard_id\":\"shared\"}") }
        val newA = store.authenticateVerifiedAccount("A", setOf("shared"))
        val restored = PendingWriteRepository(DisabledPendingWriteAdapter(DisabledOwnedValues(store, newA, "shared", "writes"), "shared"))
        assertEquals(1, restored.list().size)
        assertTrue(restored.list().single().payloadJson.contains("1.234567890123"))
    }

    @Test fun actualScoutConstructorRepairOnlyWritesOwnedNamespaceAfterBootstrap() {
        val original = source()
        val store = accounts()
        val fence = FieldHandoverFence(setOf("scout")).also { it.register("scout") }
        val boundary = FieldStartupBoundary(fence, vault(original), { false }, store)
        assertEquals(FieldStartupResult.PreservedLocked, boundary.bootstrap())
        val a = boundary.openVerifiedAccount("A", setOf("shared"))
        val values = DisabledOwnedValues(store, a, "shared", "scout")
        val scout = boundary.construct(a, "shared") { VineyardInsightsController(VineyardInsightsStore(values)) }
        scout.startVisit("shared", "A", null, 7, 1)
        values.remove("pending_operations")
        assertTrue(VineyardInsightsStore(values).loadQueue().isEmpty())
        val b = boundary.openVerifiedAccount("B", setOf("shared"))
        val other = boundary.construct(b, "shared") {
            VineyardInsightsController(VineyardInsightsStore(DisabledOwnedValues(store, b, "shared", "scout")))
        }
        assertTrue(other.visits.value.isEmpty())
        denied { values.write("visits", "obsolete") }
        val newA = boundary.openVerifiedAccount("A", setOf("shared"))
        val restored = boundary.construct(newA, "shared") {
            VineyardInsightsController(VineyardInsightsStore(DisabledOwnedValues(store, newA, "shared", "scout")))
        }
        assertEquals(1, restored.visits.value.size)
        assertEquals(1, VineyardInsightsStore(DisabledOwnedValues(store, newA, "shared", "scout")).loadQueue().size)
        assertEquals("original unreadable field evidence", original.readText())
    }

    @Test fun realPairedCoordinatorCannotReuseOtherAccountsJournal() {
        val store = accounts()
        val a = store.authenticateVerifiedAccount("A", setOf("shared"))
        val values = DisabledOwnedValues(store, a, "shared", "paired")
        val first = PairedGrowthCaptureCoordinator(DisabledPairedJournalAdapter(values, "shared"))
        assertEquals("A", first.beginOrReuse(journal("A"))?.operationId)
        val b = store.authenticateVerifiedAccount("B", setOf("shared"))
        val second = PairedGrowthCaptureCoordinator(DisabledPairedJournalAdapter(DisabledOwnedValues(store, b, "shared", "paired"), "shared"))
        assertEquals("B", second.beginOrReuse(journal("B"))?.operationId)
        denied { values.remove("journals") }
        val again = store.authenticateVerifiedAccount("A", setOf("shared"))
        assertEquals("A", DisabledPairedJournalAdapter(DisabledOwnedValues(store, again, "shared", "paired"), "shared").load().single().operationId)
    }

    @Test fun binaryPublicationResumesExactIntentAtEveryBoundaryAndNeverOverwrites() {
        val source = File(temporary.root, "photo.jpg").also { it.writeBytes(ByteArray(2 * 1024 * 1024) { (it % 251).toByte() }) }
        val original = IsolationDisk.digest(source)
        val boundaries = listOf("before-rename:stable.intent", "after-rename:stable.intent", "before-file-sync:stable.bin",
            "before-rename:stable.bin", "after-rename:stable.bin", "before-rename:stable.record", "after-rename:stable.record")
        boundaries.forEachIndexed { index, point ->
            val root = File(temporary.root, "binary-$index")
            val broken = AccountEvidenceStore(root, fixtureDisk { if (it == point) error("interrupted") })
            val a = broken.authenticateVerifiedAccount("A", setOf("shared"))
            denied { broken.appendBinary(a, "shared", "photo", "photo", "stable", source, "/original/path") }
            val restarted = AccountEvidenceStore(root, fixtureDisk())
            val newA = restarted.authenticateVerifiedAccount("A", setOf("shared"))
            assertEquals("stable", restarted.appendBinary(newA, "shared", "photo", "photo", "stable", source, "/original/path"))
            assertEquals("stable", restarted.appendBinary(newA, "shared", "photo", "photo", "stable", source, "/original/path"))
            val row = restarted.metadata(newA, "shared", "photo").single()
            assertEquals(original, row.sha256)
            assertTrue(File(root, "${IsolationDisk.digest("A".toByteArray())}/stable.record").length() < 1024)
            val output = ByteArrayOutputStream()
            assertTrue(restarted.copyBinary(newA, "shared", "photo", "stable", output, "/original/path"))
            assertEquals(original, IsolationDisk.digest(output.toByteArray()))
            val b = restarted.authenticateVerifiedAccount("B", setOf("shared"))
            assertFalse(restarted.copyBinary(b, "shared", "photo", "stable", ByteArrayOutputStream()))
        }
        assertEquals(original, IsolationDisk.digest(source))
    }

    @Test fun lowSpaceAndChangedBinaryIntentNeverExposePartialOrReplaceOriginal() {
        val photo = File(temporary.root, "photo.jpg").also { it.writeText("original") }
        val root = File(temporary.root, "binary")
        val noSpace = AccountEvidenceStore(root, fixtureDisk(), { 1L })
        val a = noSpace.authenticateVerifiedAccount("A", setOf("shared"))
        denied { noSpace.appendBinary(a, "shared", "photo", "photo", "stable", photo) }
        val broken = AccountEvidenceStore(root, fixtureDisk { if (it == "before-rename:stable.record") error("interrupted") })
        val nextA = broken.authenticateVerifiedAccount("A", setOf("shared"))
        denied { broken.appendBinary(nextA, "shared", "photo", "photo", "stable", photo) }
        val restart = AccountEvidenceStore(root, fixtureDisk())
        val restoredA = restart.authenticateVerifiedAccount("A", setOf("shared"))
        denied { restart.metadata(restoredA, "shared", "photo") }
        photo.writeText("different")
        denied { restart.appendBinary(restoredA, "shared", "photo", "photo", "stable", photo) }
        assertEquals("original", File(root, "${IsolationDisk.digest("A".toByteArray())}/stable.bin").readText())
    }

    @Test fun abruptHostExitDuringBinaryPublicationResumesTheSameRevisionExactlyOnce() {
        val checkpoints = listOf("before-rename:stable.intent", "after-rename:stable.intent", "before-file-sync:stable.bin",
            "before-rename:stable.bin", "after-rename:stable.bin", "before-rename:stable.record", "after-rename:stable.record")
        checkpoints.forEachIndexed { index, point ->
            val root = temporary.newFolder("kill-$index")
            val photo = File(root, "original.jpg").also { it.writeBytes(ByteArray(1024 * 1024) { (it % 251).toByte() }) }
            val hash = IsolationDisk.digest(photo)
            val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").absolutePath,
                "-cp", fixtureClasspath(), Stage1BBinaryProcess::class.java.name, root.path, point)
                .redirectErrorStream(true).redirectOutput(File(root, "child.log")).start()
            try {
                assertTrue("Child timed out", child.waitFor(25, TimeUnit.SECONDS))
                assertEquals(File(root, "child.log").readText(), 73, child.exitValue())
            } finally { if (child.isAlive) child.destroyForcibly() }
            val store = AccountEvidenceStore(File(root, "accounts"), fixtureDisk())
            val a = store.authenticateVerifiedAccount("A", setOf("shared"))
            repeat(2) { assertEquals("stable", store.appendBinary(a, "shared", "photo", "capture", "stable", photo)) }
            assertEquals(1, store.metadata(a, "shared", "photo").size)
            assertEquals(hash, IsolationDisk.digest(photo))
            val output = ByteArrayOutputStream()
            assertTrue(store.copyBinary(a, "shared", "photo", "stable", output))
            assertEquals(hash, IsolationDisk.digest(output.toByteArray()))
        }
    }

    @Test fun restoredBinaryWithoutMetadataOrPayloadRemainsLockedNotAnEmptyQueue() {
        for (missing in listOf("intent", "record", "bin")) {
            val root = temporary.newFolder("restore-$missing")
            val store = AccountEvidenceStore(root, fixtureDisk())
            val a = store.authenticateVerifiedAccount("A", setOf("shared"))
            val revision = store.append(a, "shared", "photo", "capture", "exact-jpeg-evidence".toByteArray())
            val ns = File(root, IsolationDisk.digest("A".toByteArray()))
            check(File(ns, "$revision.$missing").delete()) // Simulated incomplete transfer of test-owned data.
            val restored = AccountEvidenceStore(root, fixtureDisk())
            val newA = restored.authenticateVerifiedAccount("A", setOf("shared"))
            denied { restored.read(newA, "shared", "photo") }
            denied { restored.acknowledge(newA, "shared", "photo", revision) }
            assertTrue(ns.listFiles()!!.isNotEmpty())
        }
    }

    @Test fun everyCurrentSourceLiteralPreferenceHasAReviewedClassification() {
        val sourceRoot = listOf(File("src/main/java"), File("app/src/main/java"), File("android-vinetrack/app/src/main/java"))
            .firstOrNull { it.isDirectory } ?: error("Main sources unavailable; inventory coverage not verified")
        val preferenceCall = Regex("getSharedPreferences\\s*\\(\\s*\\\"([^\\\"]+)\\\"")
        val names = sourceRoot.walkTopDown().filter { it.extension == "kt" }.flatMap { file ->
            preferenceCall.findAll(file.readText()).map { it.groupValues[1] }
        }.toSet()
        val unknown = names - FieldStoreClassification.preferences.keys
        assertTrue("Unreviewed source preference names: $unknown", unknown.isEmpty())
        assertTrue(names.size >= 40)
        assertEquals(ReviewedBusinessInventory.businessPreferences,
            FieldStoreClassification.preferences.filterValues {
                it == FieldStoreClass.BUSINESS_CRITICAL || it == FieldStoreClass.RECOVERABLE_CACHE
            }.keys - setOf("vinetrack_entitlement", "admin_performance_capture", "release_reminders", "chemical_catalogue_discovery"))
        println("STAGE1B_LITERAL_PREFERENCE_COVERAGE names=${names.size}; constant/dynamic names and transitive callers require separate review")
    }

    @Test fun realisticVolumeHostCopyAndBinaryStorageReportWithoutClaimingDeviceStartup() {
        val photos = temporary.newFolder("volume")
        val block = ByteArray(64 * 1024) { (it % 251).toByte() }
        repeat(64) { index -> java.io.FileOutputStream(File(photos, "$index.jpg")).use { output ->
            repeat(32) { output.write(block) }; output.fd.sync()
        } }
        val sources = photos.listFiles()!!.map { RawEvidenceSource("photos/${it.name}", it) }
        val raw = RawEvidenceVault(File(temporary.root, "volume-vault"), fixtureDisk(), { sources })
        val start = System.nanoTime()
        val manifest = raw.preserve()
        val initialMs = (System.nanoTime() - start) / 1_000_000.0
        val repeatStart = System.nanoTime()
        assertEquals(manifest, raw.verifyArchive())
        val verifyMs = (System.nanoTime() - repeatStart) / 1_000_000.0
        val store = accounts()
        val a = store.authenticateVerifiedAccount("A", setOf("shared"))
        val binaryStart = System.nanoTime()
        sources.forEachIndexed { index, source -> store.appendBinary(a, "shared", "photo", "photo-$index", "revision-$index", source.file) }
        val binaryMs = (System.nanoTime() - binaryStart) / 1_000_000.0
        val records = store.metadata(a, "shared", "photo")
        assertEquals(64, records.size)
        assertEquals(128L * 1024 * 1024, records.sumOf { it.length })
        val vaultBytes = File(temporary.root, "volume-vault").walkTopDown().filter { it.isFile }.sumOf { it.length() }
        val accountBytes = File(temporary.root, "accounts").walkTopDown().filter { it.isFile }.sumOf { it.length() }
        println("STAGE1B_HOST_VOLUME sources=64 sourceBytes=${sources.sumOf { it.file.length() }} vaultBytes=$vaultBytes accountBytes=$accountBytes initialMs=$initialMs verifyMs=$verifyMs binaryMs=$binaryMs bufferBytes=65536")
        assertTrue(vaultBytes - 128L * 1024 * 1024 < 128 * 1024)
        assertTrue(accountBytes - 128L * 1024 * 1024 < 128 * 1024)
    }

    @Test fun inventoryExcludesExplicitVaultAndAccountsButRefusesSelfCopyOrUnknownSources() {
        val files = temporary.newFolder("files")
        val protected = File(files, "field-isolation").also { it.mkdirs(); File(it, "secret-account.bin").writeText("private") }
        val cache = temporary.newFolder("cache")
        File(cache, "camera-captures").mkdirs()
        File(cache, "camera-captures/unhanded.jpg").writeText("unhanded capture")
        val sources = ReviewedBusinessInventory.sources(File(temporary.root, "prefs"), files, cache, setOf(protected))
        assertEquals(listOf("cache/camera-captures/unhanded.jpg"), sources.map { it.identity })
        denied { ReviewedBusinessInventory.sources(File(temporary.root, "prefs"), files) }
        denied { RawEvidenceVault(protected, fixtureDisk(), { listOf(RawEvidenceSource("recursive", File(protected, "secret-account.bin"))) }).preserve() }
    }
}

/** Abrupt JVM exit is persisted-store evidence, not an Android app-process kill. */
object Stage1BBinaryProcess {
    @JvmStatic fun main(args: Array<String>) {
        val root = File(args[0])
        val store = AccountEvidenceStore(File(root, "accounts"), fixtureDisk { if (it == args[1]) Runtime.getRuntime().halt(73) })
        val a = store.authenticateVerifiedAccount("A", setOf("shared"))
        store.appendBinary(a, "shared", "photo", "capture", "stable", File(root, "original.jpg"))
        error("Termination checkpoint missed")
    }
}
