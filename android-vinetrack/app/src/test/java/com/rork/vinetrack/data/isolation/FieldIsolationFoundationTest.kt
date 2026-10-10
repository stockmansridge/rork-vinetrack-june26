package com.rork.vinetrack.data.isolation

import com.rork.vinetrack.BuildConfig
import com.rork.vinetrack.data.RetentionReviewTest
import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Foundation contracts only; these fixtures do not instantiate the production ViewModel or Android backup transport. */
class FieldIsolationFoundationTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun source(root: File, name: String, bytes: ByteArray): File = File(root, name).also {
        it.parentFile?.mkdirs()
        FileOutputStream(it).use { output -> output.write(bytes); output.fd.sync() }
    }
    private fun originalSources(root: File): List<RawEvidenceSource> =
        ReviewedBusinessInventory.sources(File(root, "original/shared_prefs"), File(root, "original/files"))
    private fun fixture(root: File, checkpoint: (String) -> Unit = {}, space: Long = Long.MAX_VALUE): FieldIsolationTrial {
        val disk = fixtureDisk(checkpoint)
        return FieldIsolationTrial(RawEvidenceVault(File(root, "vault"), disk,
            { originalSources(root) }, { space }, checkpoint), File(root, "accounts"), disk)
    }
    private fun ready(root: File): FieldIsolationTrial = fixture(root).also {
        assertEquals(FieldBootstrapState.PreservedNotActivated, it.bootstrap())
    }
    private fun denied(action: () -> Unit) {
        try { action(); fail("Unsafe access was accepted") } catch (_: IllegalStateException) { }
    }

    @Test fun activationCannotBeEnabledByRuntimeLogin() {
        assertFalse(BuildConfig.FIELD_STORAGE_ISOLATION_ACTIVATED)
        val trial = ready(temporary.root)
        trial.acceptVerifiedSession("A", setOf("shared"))
        assertFalse(BuildConfig.FIELD_STORAGE_ISOLATION_ACTIVATED)
    }

    @Test fun authenticationRejectedBeforeBootstrapCreatesNoAccountData() {
        val trial = fixture(temporary.root)
        denied { trial.acceptVerifiedSession("A", setOf("shared")) }
        trial.rejectOrSignOut()
        assertFalse(File(temporary.root, "accounts").exists())
    }

    @Test fun exactUnreadableXmlBackupAndJpegBytesSurviveRepeatedBootstrap() {
        val root = temporary.root
        val broken = byteArrayOf(0, -1, 60, 33, 10)
        source(root, "original/shared_prefs/vinetrack_pending_writes.xml", broken)
        source(root, "original/shared_prefs/vinetrack_pending_writes.xml.bak", "{partially truncated".toByteArray())
        val photo = source(root, "original/files/pending_pin_photos/original.jpg", RetentionReviewTest.jpeg())
        val original = originalSources(root).associate { it.identity to it.file.readBytes() }
        val first = RawEvidenceVault(File(root, "vault"), fixtureDisk(), { originalSources(root) }).preserve()
        repeat(3) {
            val next = RawEvidenceVault(File(root, "vault"), fixtureDisk(), { originalSources(root) }).preserve()
            assertEquals(first, next)
            next.entries.forEach { assertArrayEquals(original.getValue(it.source), File(root, "vault/${it.blob}").readBytes()) }
        }
        originalSources(root).forEach { assertArrayEquals(original.getValue(it.identity), it.file.readBytes()) }
        assertArrayEquals(RetentionReviewTest.jpeg(), photo.readBytes())
        assertEquals(first.entries.size, File(root, "vault").listFiles()!!.count { it.extension == "raw" })
    }

    @Test fun authTokensAreNotInventoriedOrCopied() {
        val root = temporary.root
        source(root, "original/shared_prefs/vinetrack_session.xml", "NEVER-COPY-TOKEN".toByteArray())
        source(root, "original/shared_prefs/vinetrack_pending_writes.xml", "original-work".toByteArray())
        val manifest = RawEvidenceVault(File(root, "vault"), fixtureDisk(), { originalSources(root) }).preserve()
        assertEquals(listOf("sharedpref/vinetrack_pending_writes.xml"), manifest.entries.map { it.source })
        assertFalse(File(root, "vault").listFiles()!!.filter { it.isFile }.any { it.readText().contains("NEVER-COPY-TOKEN") })
    }

    @Test fun unknownStoreBlocksPreservationInsteadOfCopyingPotentialSecrets() {
        val root = temporary.root
        source(root, "original/shared_prefs/unknown_credentials.xml", "SECRET".toByteArray())
        val trial = fixture(root)
        assertTrue(trial.bootstrap() is FieldBootstrapState.RecoveryRequired)
        denied { trial.acceptVerifiedSession("B", setOf("shared")) }
        assertFalse(File(root, "vault/prepared.json").exists())
        assertEquals("SECRET", File(root, "original/shared_prefs/unknown_credentials.xml").readText())
    }

    @Test fun insufficientSpaceRetainsEveryOriginalAndCreatesNoPreparedCommit() {
        val root = temporary.root
        val photo = source(root, "original/files/pending_pin_photos/a.jpg", RetentionReviewTest.jpeg())
        assertTrue(fixture(root, space = 1).bootstrap() is FieldBootstrapState.RecoveryRequired)
        assertArrayEquals(RetentionReviewTest.jpeg(), photo.readBytes())
        assertFalse(File(root, "vault/prepared.json").exists())
        assertEquals(FieldBootstrapState.PreservedNotActivated, fixture(root).bootstrap())
    }

    @Test fun failedMetadataCommitLeavesOriginalAndResumesSameInventory() {
        val root = temporary.root
        val original = source(root, "original/shared_prefs/vinetrack_pending_photos.xml", "reference=/old/path.jpg".toByteArray())
        val trial = fixture(root, { if (it == "before-rename:verified.json") error("Injected metadata failure") })
        assertTrue(trial.bootstrap() is FieldBootstrapState.RecoveryRequired)
        denied { trial.acceptVerifiedSession("A", setOf("shared")) }
        assertFalse(File(root, "vault/verified.json").exists())
        assertEquals("reference=/old/path.jpg", original.readText())
        ready(root)
        assertEquals(1, File(root, "vault").listFiles()!!.count { it.extension == "raw" })
    }

    @Test fun sourceChangeDuringCopyBlocksVerificationAndRetainsBothVersions() {
        val root = temporary.root
        val original = source(root, "original/shared_prefs/vinetrack_pending_writes.xml", "first".toByteArray())
        val trial = fixture(root, { if (it == "after-copy:0.raw") original.writeText("second") })
        assertTrue(trial.bootstrap() is FieldBootstrapState.RecoveryRequired)
        assertEquals("first", File(root, "vault/0.raw").readText())
        assertEquals("second", original.readText())
        assertFalse(File(root, "vault/verified.json").exists())
        assertTrue(fixture(root).bootstrap() is FieldBootstrapState.RecoveryRequired)
    }

    @Test fun corruptedVaultNeverOverwritesOriginalOrEnablesAccountAccess() {
        val root = temporary.root
        val original = source(root, "original/shared_prefs/vinetrack_pending_writes.xml", "exact".toByteArray())
        ready(root)
        File(root, "vault/0.raw").writeText("broken")
        val next = fixture(root)
        assertTrue(next.bootstrap() is FieldBootstrapState.RecoveryRequired)
        denied { next.acceptVerifiedSession("A", setOf("shared")) }
        assertEquals("exact", original.readText())
        assertEquals("broken", File(root, "vault/0.raw").readText())
    }

    @Test fun accountBWithSharedVineyardCannotReadAOrAcknowledgeItsRevision() {
        val trial = ready(temporary.root)
        val a = trial.acceptVerifiedSession("A", setOf("shared"))
        val revision = trial.append(a, "shared", "pending-write", "stable-id", "GPS:1.234567890123".toByteArray())
        val b = trial.acceptVerifiedSession("B", setOf("shared"))
        assertTrue(trial.read(b, "shared", "pending-write").isEmpty())
        assertFalse(trial.acknowledge(b, "shared", "pending-write", revision))
        denied { trial.read(a, "shared", "pending-write") }
        denied { trial.acknowledge(a, "shared", "pending-write", revision) }
    }

    @Test fun sameAccountReauthenticationAndRestartRetainExactBytesButInvalidateOldCallbacks() {
        val root = temporary.root
        val trial = ready(root)
        val a = trial.acceptVerifiedSession("A", setOf("shared"))
        trial.append(a, "shared", "tank-actual", "tank", "23.456789012345".toByteArray())
        trial.rejectOrSignOut()
        denied { trial.append(a, "shared", "tank-actual", "tank", "obsolete".toByteArray()) }
        val nextA = trial.acceptVerifiedSession("A", setOf("shared"))
        denied { trial.read(a, "shared", "tank-actual") }
        assertEquals("23.456789012345", trial.read(nextA, "shared", "tank-actual").single().bytes.toString(Charsets.UTF_8))
        val recreated = ready(root)
        val restoredA = recreated.acceptVerifiedSession("A", setOf("shared"))
        assertEquals("23.456789012345", recreated.read(restoredA, "shared", "tank-actual").single().bytes.toString(Charsets.UTF_8))
    }

    @Test fun vineyardAccessIsRequiredIndependentlyOfAccount() {
        val trial = ready(temporary.root)
        val a = trial.acceptVerifiedSession("A", setOf("one", "two"))
        trial.append(a, "two", "trip", "id", "trip".toByteArray())
        val restricted = trial.acceptVerifiedSession("A", setOf("one"))
        denied { trial.read(restricted, "two", "trip") }
        assertTrue(trial.read(restricted, "one", "trip").isEmpty())
    }

    @Test fun authorlessLegacyEditsPhotosAndJournalsStayLockedAfterAnyLogin() {
        val root = temporary.root
        source(root, "original/shared_prefs/vinetrack_pending_writes.xml", "{pinId:42,isCompleted:true}".toByteArray())
        source(root, "original/shared_prefs/vinetrack_paired_growth_capture.xml", "{vineyard:shared}".toByteArray())
        val photo = source(root, "original/files/pending_pin_photos/unknown.jpg", RetentionReviewTest.jpeg())
        val trial = ready(root)
        for (account in listOf("A", "B", "A")) {
            val capability = trial.acceptVerifiedSession(account, setOf("shared"))
            assertTrue(trial.read(capability, "shared", "pending-write").isEmpty())
            assertTrue(trial.read(capability, "shared", "paired-growth").isEmpty())
            assertNull(trial.photoBytes(capability, "shared", "photo", "unknown", photo.absolutePath))
        }
        assertArrayEquals(RetentionReviewTest.jpeg(), photo.readBytes())
    }

    @Test fun unreadableLegacyActiveClaimIsPreservedAndBlocksNewClaim() {
        val root = temporary.root
        val original = source(root, "original/shared_prefs/vinetrack_active_trip.xml", byteArrayOf(-1, 0, 123))
        val trial = ready(root)
        val b = trial.acceptVerifiedSession("B", setOf("shared"))
        denied { trial.append(b, "shared", "active-trip", "B-trip", "new".toByteArray()) }
        assertArrayEquals(byteArrayOf(-1, 0, 123), original.readBytes())
        assertArrayEquals(original.readBytes(), File(root, "vault/0.raw").readBytes())
    }

    @Test fun pairedGrowthAndChemicalLabelNamespacesNeverShareRecordsOrPhotoCopies() {
        val root = temporary.root
        val original = source(root, "original/files/pending_chemical_label_photos/legacy.jpg", RetentionReviewTest.jpeg())
        val trial = ready(root)
        val a = trial.acceptVerifiedSession("A", setOf("shared"))
        val paired = trial.append(a, "shared", "paired-growth", "capture", "A-journal".toByteArray())
        val photo = trial.append(a, "shared", "chemical-label", "label", original.readBytes(), original.absolutePath)
        val b = trial.acceptVerifiedSession("B", setOf("shared"))
        assertTrue(trial.read(b, "shared", "paired-growth").isEmpty())
        assertFalse(trial.acknowledge(b, "shared", "paired-growth", paired))
        assertNull(trial.photoBytes(b, "shared", "chemical-label", photo, original.absolutePath))
        assertFalse(trial.acknowledge(b, "shared", "chemical-label", photo))
        trial.append(b, "shared", "paired-growth", "capture", "B-journal".toByteArray())
        val originalA = trial.acceptVerifiedSession("A", setOf("shared"))
        assertEquals("A-journal", trial.read(originalA, "shared", "paired-growth").single().bytes.toString(Charsets.UTF_8))
        assertTrue(trial.acknowledge(originalA, "shared", "chemical-label", photo))
        assertArrayEquals(RetentionReviewTest.jpeg(), original.readBytes())
        assertArrayEquals(RetentionReviewTest.jpeg(), trial.photoBytes(originalA, "shared", "chemical-label", photo, original.absolutePath))
    }

    @Test fun oldAcknowledgementCannotConsumeNewRevisionAndRetainsAllPayloads() {
        val trial = ready(temporary.root)
        val a = trial.acceptVerifiedSession("A", setOf("shared"))
        val old = trial.append(a, "shared", "gps", "trip", "old-route".toByteArray())
        val newer = trial.append(a, "shared", "gps", "trip", "new-route".toByteArray())
        assertTrue(trial.acknowledge(a, "shared", "gps", old))
        assertEquals(setOf(old, newer), trial.read(a, "shared", "gps").map { it.revision }.toSet())
    }

    @Test fun wholeFixtureRestoreRequiresNewAuthenticationAndPreservesOwnerIsolation() {
        val first = temporary.newFolder("first")
        val trial = ready(first)
        val a = trial.acceptVerifiedSession("A", setOf("shared"))
        trial.append(a, "shared", "photo", "photo", RetentionReviewTest.jpeg(), "/old-device/path.jpg")
        val restored = temporary.newFolder("restored")
        first.copyRecursively(restored, overwrite = true)
        val next = ready(restored)
        denied { next.read(a, "shared", "photo") }
        val b = next.acceptVerifiedSession("B", setOf("shared"))
        assertTrue(next.read(b, "shared", "photo").isEmpty())
        val newA = next.acceptVerifiedSession("A", setOf("shared"))
        val row = next.read(newA, "shared", "photo").single()
        assertEquals("/old-device/path.jpg", row.originalPhotoPath)
        assertArrayEquals(RetentionReviewTest.jpeg(), row.bytes)
    }

    @Test fun incompleteVaultRestoreFailsClosedWithoutTouchingSource() {
        val root = temporary.root
        val original = source(root, "original/shared_prefs/vinetrack_pending_writes.xml", "offline".toByteArray())
        ready(root)
        assertTrue(File(root, "vault/prepared.json").delete())
        val next = fixture(root)
        assertTrue(next.bootstrap() is FieldBootstrapState.RecoveryRequired)
        assertEquals("offline", original.readText())
        denied { next.acceptVerifiedSession("B", setOf("shared")) }
    }

    @Test fun existingGpsTripTankAndOfflineXmlRemainByteForByteUnchanged() {
        val root = temporary.root
        val names = listOf("vinetrack_pending_writes", "vinetrack_active_trip", "vinetrack_spray_tank_actuals", "vinetrack_start_tank_journal", "vinetrack_irrigation", "vineyard_insights_preview", "vinetrack_work_task_materials")
        val originals = names.map { name -> source(root, "original/shared_prefs/$name.xml", "<map><string name=\"raw\">ID-$name;1.234567890123;IN_PROGRESS;attempts=3</string></map>".toByteArray()) }
        val before = originals.map { it.readBytes() }
        ready(root)
        originals.zip(before).forEach { (file, bytes) -> assertArrayEquals(bytes, file.readBytes()) }
    }

    @Test fun recreatedFacadeRevokesOldAccountCallbacksAcrossRepositoryInstances() {
        val root = temporary.root
        val first = ready(root)
        val a = first.acceptVerifiedSession("A", setOf("shared"))
        first.append(a, "shared", "gps", "trip", "A-route".toByteArray())
        val second = ready(root)
        val b = second.acceptVerifiedSession("B", setOf("shared"))
        denied { first.append(a, "shared", "gps", "trip", "obsolete".toByteArray()) }
        denied { first.read(a, "shared", "gps") }
        assertTrue(second.read(b, "shared", "gps").isEmpty())
    }

    @Test fun partialAccountRecordRestoreIsNotTreatedAsAnEmptyQueue() {
        val root = temporary.root
        val trial = ready(root)
        val a = trial.acceptVerifiedSession("A", setOf("shared"))
        val revision = trial.append(a, "shared", "gps", "trip", "exact-route".toByteArray())
        val record = File(root, "accounts/${IsolationDisk.digest("A".toByteArray())}/$revision.record")
        record.writeText("{truncated")
        val recreated = ready(root)
        val newA = recreated.acceptVerifiedSession("A", setOf("shared"))
        try { recreated.read(newA, "shared", "gps"); fail("Corrupt restored data must block reading") }
        catch (_: kotlinx.serialization.SerializationException) { }
        assertEquals("{truncated", record.readText())
    }

    @Test fun hostCopySizingReportsByteOverheadWithoutClaimingAndroidStartupPerformance() {
        val root = temporary.root
        repeat(8) { index ->
            source(root, "original/files/pending_pin_photos/$index.jpg", ByteArray(1024 * 1024) { (it % 251).toByte() })
        }
        repeat(16) { index -> source(root, "original/files/scout_photos/$index.json", "raw-$index".toByteArray()) }
        val originals = originalSources(root).sumOf { it.file.length() }
        val start = System.nanoTime()
        ready(root)
        val initialMs = (System.nanoTime() - start) / 1_000_000.0
        val second = System.nanoTime()
        ready(root)
        val verifyMs = (System.nanoTime() - second) / 1_000_000.0
        val vaultBytes = File(root, "vault").listFiles()!!.sumOf { it.length() }
        println("ISOLATION_HOST_SIZING sourceBytes=$originals vaultBytes=$vaultBytes entries=24 initialMs=$initialMs repeatVerifyMs=$verifyMs copyBufferBytes=65536")
        assertTrue(vaultBytes >= originals)
        assertEquals(24, File(root, "vault").listFiles()!!.count { it.extension == "raw" })
    }

    @Test fun abruptProcessExitAtEveryPublicationBoundaryResumesWithoutDuplicateCopies() {
        val checkpoints = listOf("before-prepare", "after-prepare", "before-file-sync:0.raw", "before-rename:0.raw", "after-rename:0.raw", "after-copy:0.raw", "before-verify-commit", "before-rename:verified.json", "after-rename:verified.json", "after-verify-commit")
        for ((index, point) in checkpoints.withIndex()) {
            val root = temporary.newFolder("termination-$index")
            val original = source(root, "original/files/pending_pin_photos/original.jpg", RetentionReviewTest.jpeg())
            val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").absolutePath,
                "-cp", fixtureClasspath(), FieldIsolationProcess::class.java.name, root.absolutePath, point)
                .redirectErrorStream(true).redirectOutput(File(root, "child.log")).start()
            try {
                assertTrue("Child timed out at $point", child.waitFor(25, TimeUnit.SECONDS))
                assertEquals("Child missed $point: ${File(root, "child.log").readText()}", 73, child.exitValue())
            } finally { if (child.isAlive) child.destroyForcibly() }
            ready(root)
            ready(root)
            assertArrayEquals(RetentionReviewTest.jpeg(), original.readBytes())
            assertArrayEquals(original.readBytes(), File(root, "vault/0.raw").readBytes())
            assertEquals(1, File(root, "vault").listFiles()!!.count { it.extension == "raw" })
        }
    }
}

internal fun fixtureDisk(checkpoint: (String) -> Unit = {}): IsolationDisk = IsolationDisk({ directory ->
    FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
}, checkpoint)

internal fun fixtureClasspath(): String = buildSet {
    addAll((System.getProperty("java.class.path") ?: "").split(File.pathSeparator))
    var loader: ClassLoader? = FieldIsolationFoundationTest::class.java.classLoader
    while (loader != null) {
        (loader as? java.net.URLClassLoader)?.getURLs()?.filter { it.protocol == "file" }?.forEach { add(File(it.toURI()).absolutePath) }
        loader = loader.parent
    }
}.joinToString(File.pathSeparator)

/** Host termination helper exits without finally blocks; not an Android OS kill. */
object FieldIsolationProcess {
    @JvmStatic fun main(args: Array<String>) {
        val root = File(args[0])
        val stop: (String) -> Unit = { if (it == args[1]) Runtime.getRuntime().halt(73) }
        RawEvidenceVault(File(root, "vault"), fixtureDisk(stop), {
            ReviewedBusinessInventory.sources(File(root, "original/shared_prefs"), File(root, "original/files"))
        }, checkpoint = stop).preserve()
        error("Termination checkpoint missed")
    }
}
