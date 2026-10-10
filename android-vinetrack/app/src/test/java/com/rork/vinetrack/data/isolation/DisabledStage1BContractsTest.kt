package com.rork.vinetrack.data.isolation

import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

internal fun contractDisk(checkpoint: (String) -> Unit = {}): IsolationDisk = IsolationDisk({ directory ->
    FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
}, checkpoint)

internal fun contractDenied(action: () -> Unit) {
    try { action(); fail("Unsafe operation accepted") } catch (_: Exception) { }
}

/** Focused controlled contracts only. No Activity/auth transport/GPS/production repositories or Android instrumentation. */
class DisabledStage1BContractsTest {
    @get:Rule val temporary = TemporaryFolder()
    private val enrollment = FieldCallerFamily.entries.toSet()
    private fun store(root: File, disk: IsolationDisk = contractDisk()) = AccountEvidenceStore(File(root, "new-accounts"), disk)
    private fun journal(root: File, accounts: AccountEvidenceStore, disk: IsolationDisk = contractDisk()) = DisabledGenerationJournal(root, disk, accounts)
    private fun proof(root: File, name: String, bytes: String = "original corrupt XML and exact JPEG reference"): ClosedSetProof {
        val data = File(root, name).also { check(it.mkdirs() || it.isDirectory) }
        File(data, "evidence.bin").also { if (!it.exists()) it.writeText(bytes) }
        val manifest = File(root, "proofs/$name.json")
        return ClosedSetProof(name, "proofs/$name.json", ClosedEvidenceSet(contractDisk()).seal(data, manifest))
    }
    private fun access(root: File, accounts: AccountEvidenceStore, ledger: DisabledGenerationJournal,
                       cap: FieldAccountCapability, family: FieldCallerFamily = FieldCallerFamily.QUEUE) =
        DisabledFamilyAccess(root, contractDisk(), accounts, ledger, cap, "shared", family)

    @Test fun copyOnlyGenerationResumesAndNeverPublishesRouteOrRechecksMutableOriginalsAfterCompletion() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val ledger = journal(root, accounts)
        val original = proof(root, "original")
        val raw = proof(root, "raw")
        assertTrue(ledger.beginGeneration("G1", original, enrollment))
        assertTrue(journal(root, accounts).beginGeneration("G1", original, enrollment))
        ledger.rawVerified("G1", raw)
        ledger.finishCopyOnly("G1")
        ledger.finishCopyOnly("G1")
        File(root, "original/evidence.bin").appendText("later field work")
        assertEquals("LEGACY_LOCKED", journal(root, accounts).status().route)
        assertNull(ledger.status().phase)
        assertEquals("original corrupt XML and exact JPEG reference", File(root, "raw/evidence.bin").readText())
        contractDenied { ledger.commitSyntheticRoute("G1") }
    }

    @Test fun interruptedIntentRefusesChangedSourcesAndCopyMismatchWithoutDeletingEither() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val ledger = journal(root, accounts)
        val original = proof(root, "original")
        val raw = proof(root, "raw", "different")
        assertTrue(ledger.beginGeneration("G1", original, enrollment))
        contractDenied { ledger.rawVerified("G1", raw) }
        File(root, "original/evidence.bin").appendText("new work")
        contractDenied { journal(root, accounts).status() }
        assertTrue(File(root, "original/evidence.bin").readText().endsWith("new work"))
        assertEquals("different", File(root, "raw/evidence.bin").readText())
    }

    @Test fun asyncAdmissionDefersMigrationUntilDurableCompletionAndClosesNewAdmissionDuringCapture() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        val ledger = journal(root, accounts)
        val façade = access(root, accounts, ledger, a)
        val pending = façade.begin("operation")
        val original = proof(root, "original")
        assertFalse(ledger.beginGeneration("G1", original, enrollment))
        assertEquals(1, ledger.status().pendingAdmissions)
        contractDenied { façade.read() }
        façade.publish(pending, "retained exact work".toByteArray())
        assertTrue(ledger.beginGeneration("G1", original, enrollment))
        contractDenied { façade.begin("late-operation") }
        assertEquals(1L, ledger.status().highWater)
        ledger.rawVerified("G1", proof(root, "raw"))
        ledger.finishCopyOnly("G1")
        assertEquals(2L, façade.begin("next-operation").ordinal)
    }

    @Test fun olderSessionsAndForeignDelayedCallbacksCannotPublishAcknowledgeOrRecoverWork() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val ledger = journal(root, accounts)
        val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        val old = access(root, accounts, ledger, a)
        val ticket = old.begin("A-operation")
        accounts.revoke()
        contractDenied { old.publish(ticket, "late A".toByteArray()) }
        val b = accounts.authenticateVerifiedAccount("B", setOf("shared"))
        val other = access(root, accounts, ledger, b)
        contractDenied { other.publish(ticket, "foreign".toByteArray()) }
        contractDenied { other.resume(ticket.id) }
        contractDenied { old.acknowledge(ticket.id) }
        assertTrue(other.read().isEmpty())
        val newA = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        val resumed = access(root, accounts, ledger, newA)
        val newTicket = resumed.resume(ticket.id)
        assertNotEquals(ticket.incarnation, newTicket.incarnation)
        contractDenied { resumed.publish(ticket, "obsolete".toByteArray()) }
        resumed.publish(newTicket, "exact A".toByteArray())
        assertEquals("exact A", resumed.read().single().bytes.toString(Charsets.UTF_8))
        assertEquals(0, ledger.status().pendingAdmissions)
    }

    @Test fun incompleteAndCorruptRestoreOfWholeRevisionCannotBecomeEmptyQueue() {
        for (loss in listOf("revision", "journal", "manifest", "corrupt")) {
            val root = temporary.newFolder(loss)
            val accounts = store(root)
            val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
            val ledger = journal(root, accounts)
            val façade = access(root, accounts, ledger, a)
            façade.publish(façade.begin("operation"), "exact-original".toByteArray())
            val anchor = File(temporary.root, "$loss-restore-manifest.json")
            val digest = ClosedEvidenceSet(contractDisk()).seal(root, anchor)
            val namespace = File(root, "new-accounts/${IsolationDisk.digest("A".toByteArray())}")
            when (loss) {
                "revision" -> namespace.listFiles()!!.filter { it.name.startsWith("operation.") }.forEach { check(it.delete()) }
                "journal" -> check(File(root, "generation-journal").deleteRecursively())
                "manifest" -> check(anchor.delete())
                "corrupt" -> File(namespace, "operation.bin").writeText("changed")
            }
            if (loss != "manifest") contractDenied { façade.read() }
            val restored = store(root)
            contractDenied { DisabledRestoreBoundary(root, anchor, digest, contractDisk(), restored)
                .openFreshlyVerifiedOriginalAccount("A", setOf("shared")) }
            contractDenied { façade.read() }
            assertTrue(File(root, "controlled-outcomes/operation/binding.json").exists())
        }
    }

    @Test fun restoreAcrossNewRootRequiresClosedAnchorAndFreshSessionAndRetainsForeignNamespaces() {
        val root = temporary.newFolder("before")
        val accounts = store(root)
        val ledger = journal(root, accounts)
        val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        val façade = access(root, accounts, ledger, a)
        façade.publish(façade.begin("operation"), "exact-JPEG-reference".toByteArray())
        val anchor = File(temporary.root, "restore.json")
        val digest = ClosedEvidenceSet(contractDisk()).seal(root, anchor)
        val destination = File(temporary.root, "new-device-root")
        assertTrue(root.copyRecursively(destination))
        val restored = store(destination)
        val boundary = DisabledRestoreBoundary(destination, anchor, digest, contractDisk(), restored)
        val b = boundary.openFreshlyVerifiedOriginalAccount("B", setOf("shared"))
        assertTrue(access(destination, restored, journal(destination, restored), b).read().isEmpty())
        val newA = boundary.openFreshlyVerifiedOriginalAccount("A", setOf("shared"))
        assertEquals("exact-JPEG-reference", access(destination, restored, journal(destination, restored), newA).read().single().bytes.toString(Charsets.UTF_8))
        contractDenied { restored.read(a, "shared", "controlled-QUEUE") }
        assertEquals(digest, IsolationDisk.digest(anchor))
    }

    @Test fun activeAndUnknownClaimsDeferWhileOriginalActorWorkContinuesAndForeignActorCannotClear() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val ledger = journal(root, accounts)
        val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        ledger.claim(a, "shared", "active-Trip")
        ledger.holdUnattributedClaim("unreadable-tank")
        val façade = access(root, accounts, ledger, a, FieldCallerFamily.TRIP_TANK)
        val ticket = façade.begin("GPS-point")
        assertFalse(ledger.beginGeneration("G1", proof(root, "original"), enrollment))
        façade.publish(ticket, "1.234567890123 exact synthetic point".toByteArray())
        assertEquals(1, façade.read().size)
        val b = accounts.authenticateVerifiedAccount("B", setOf("shared"))
        contractDenied { ledger.resolveClaim(b, "shared", "active-Trip", proof(root, "ended")) }
        assertEquals(2, journal(root, accounts).status().unresolvedClaims)
        assertFalse(ledger.beginGeneration("G1", proof(root, "original"), enrollment))
        val back = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        contractDenied { ledger.resolveClaim(back, "shared", "unreadable-tank", proof(root, "ended")) }
        ledger.resolveClaim(back, "shared", "active-Trip", proof(root, "ended"))
        assertFalse(ledger.beginGeneration("G1", proof(root, "original"), enrollment))
        assertEquals(1, ledger.status().unresolvedClaims)
        assertEquals(1, access(root, accounts, ledger, back, FieldCallerFamily.TRIP_TANK).read().size)
    }

    @Test fun syntheticRoutingCommitsOnceAndLateOldTicketsCannotBindNewRoute() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        val ledger = journal(root, accounts)
        val façade = access(root, accounts, ledger, a)
        val old = façade.begin("old-operation")
        façade.publish(old, "old-exact".toByteArray())
        assertTrue(ledger.beginGeneration("G1", proof(root, "original"), enrollment))
        ledger.rawVerified("G1", proof(root, "raw"))
        ledger.stageSynthetic("G1", proof(root, "synthetic-stage", "NEW controlled data; not legacy import"))
        assertEquals("LEGACY_LOCKED", ledger.status().route)
        ledger.commitSyntheticRoute("G1")
        ledger.commitSyntheticRoute("G1")
        assertEquals("G1", journal(root, accounts).status().route)
        contractDenied { façade.publish(old, "obsolete".toByteArray()) }
        assertEquals("G1", façade.begin("next-operation").route)
        assertEquals(1, accounts.read(a, "shared", "controlled-QUEUE").size)
    }

    @Test fun missingOrCorruptStagedRevisionHoldsCommittedRoutingWithoutGlobalRollback() {
        for (corrupt in listOf(false, true)) {
            val root = temporary.newFolder()
            val accounts = store(root)
            val ledger = journal(root, accounts)
            ledger.beginGeneration("G1", proof(root, "original"), enrollment)
            ledger.rawVerified("G1", proof(root, "raw"))
            ledger.stageSynthetic("G1", proof(root, "stage", "new-owned"))
            ledger.commitSyntheticRoute("G1")
            val staged = File(root, "stage/evidence.bin")
            if (corrupt) staged.writeText("corrupt") else check(staged.delete())
            contractDenied { journal(root, accounts).status() }
            assertTrue(File(root, "raw/evidence.bin").exists())
            assertTrue(File(root, "original/evidence.bin").exists())
            assertEquals(4, File(root, "generation-journal").listFiles()!!.count { it.extension == "event" })
        }
    }

    @Test fun crossProcessLockContentionAndReentrantCaptureDeferWithoutBlockingWriters() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val ledger = journal(root, accounts)
        val source = proof(root, "original")
        val holding = CountDownLatch(1)
        val release = CountDownLatch(1)
        val thread = Thread {
            contractDisk().locked(File(root, "generation-journal")) {
                holding.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            }
        }
        thread.start()
        try {
            assertTrue(holding.await(5, TimeUnit.SECONDS))
            assertFalse(ledger.beginGeneration("G1", source, enrollment))
        } finally { release.countDown(); thread.join(5000) }
        assertFalse(thread.isAlive)
        contractDisk().locked(File(root, "generation-journal")) { assertFalse(ledger.beginGeneration("G1", source, enrollment)) }
        assertTrue(ledger.beginGeneration("G1", source, enrollment))
    }

    @Test fun sameThreadSessionReentryCannotExposeNextAccountDuringEmission() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        val façade = access(root, accounts, journal(root, accounts), a)
        façade.publish(façade.begin("operation"), "retained".toByteArray())
        façade.deliver { rows ->
            contractDenied { accounts.authenticateVerifiedAccount("B", setOf("shared")) }
            contractDenied { accounts.revoke() }
            assertEquals("A", rows.single().account)
        }
        accounts.revoke()
        contractDenied { façade.deliver { fail("Signed out emission") } }
    }

    @Test fun interruptedCallbackResumesExactRevisionWithoutDuplicateOwnershipOrAutomaticReplay() {
        val checkpoints = listOf("before-rename:operation.intent", "after-rename:operation.bin", "after-rename:operation.record",
            "before-rename:binding.json", "after-rename:binding.json", "after-rename:operation.json", "before-rename:00000000000000000002.event",
            "after-rename:00000000000000000002.event")
        checkpoints.forEach { point ->
            val root = temporary.newFolder()
            val disk = contractDisk { if (it == point) error("interrupted") }
            val accounts = store(root, disk)
            val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
            val ledger = journal(root, accounts, disk)
            val façade = DisabledFamilyAccess(root, disk, accounts, ledger, a, "shared", FieldCallerFamily.QUEUE)
            val ticket = façade.begin("operation")
            contractDenied { façade.publish(ticket, "unchanged precision 1.234567890123".toByteArray()) }
            val restart = store(root)
            val newA = restart.authenticateVerifiedAccount("A", setOf("shared"))
            val resumed = access(root, restart, journal(root, restart), newA)
            val status = journal(root, restart).status()
            if (status.pendingAdmissions != 0) resumed.publish(resumed.resume("operation"), "unchanged precision 1.234567890123".toByteArray())
            assertEquals(1, resumed.read().size)
            assertEquals("unchanged precision 1.234567890123", resumed.read().single().bytes.toString(Charsets.UTF_8))
            assertEquals(0, journal(root, restart).status().pendingAdmissions)
        }
    }

    @Test fun publicationFailuresKeepPendingWorkAndConflictingResumeCannotOverwriteOriginal() {
        val root = temporary.newFolder()
        val disk = contractDisk { if (it == "before-rename:binding.json") error("failed durability") }
        val accounts = store(root, disk)
        val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
        val ledger = journal(root, accounts, disk)
        val façade = DisabledFamilyAccess(root, disk, accounts, ledger, a, "shared", FieldCallerFamily.QUEUE)
        contractDenied { façade.publish(façade.begin("operation"), "original".toByteArray()) }
        val restart = store(root)
        val newA = restart.authenticateVerifiedAccount("A", setOf("shared"))
        val resumed = access(root, restart, journal(root, restart), newA)
        contractDenied { resumed.read() }
        val ticket = resumed.resume("operation")
        contractDenied { resumed.publish(ticket, "different".toByteArray()) }
        assertEquals(1, journal(root, restart).status().pendingAdmissions)
        resumed.publish(ticket, "original".toByteArray())
        assertEquals("original", resumed.read().single().bytes.toString(Charsets.UTF_8))
    }

    @Test fun generationCrashBoundariesResumeOnlyOneChainAndCommitNoImplicitReplay() {
        val steps = listOf("INTENT", "RAW_VERIFIED", "SCOPED_STAGED", "ROUTE_COMMITTED")
        for (step in steps) for (checkpoint in listOf("before-rename", "after-rename")) {
            val root = temporary.newFolder()
            val accounts = store(root)
            val source = proof(root, "original")
            val raw = proof(root, "raw")
            val staged = proof(root, "stage", "new synthetic work")
            val index = steps.indexOf(step) + 1
            val disk = contractDisk { if (it == "$checkpoint:${"%020d".format(index)}.event") error("interruption") }
            val ledger = journal(root, accounts, disk)
            contractDenied {
                ledger.beginGeneration("G1", source, enrollment)
                ledger.rawVerified("G1", raw)
                ledger.stageSynthetic("G1", staged)
                ledger.commitSyntheticRoute("G1")
            }
            val resumed = journal(root, accounts)
            if (resumed.status().route != "G1") {
                resumed.beginGeneration("G1", source, enrollment)
                resumed.rawVerified("G1", raw)
                resumed.stageSynthetic("G1", staged)
                resumed.commitSyntheticRoute("G1")
            }
            assertEquals("G1", resumed.status().route)
            assertEquals(4, File(root, "generation-journal").listFiles()!!.count { it.extension == "event" })
            assertEquals("original corrupt XML and exact JPEG reference", File(root, "original/evidence.bin").readText())
            assertEquals(0, resumed.status().pendingAdmissions)
        }
    }

    @Test fun actualHostTerminationAcrossGenerationCommitsResumesOneChainWithoutReplay() {
        for (index in 1..4) for (boundary in listOf("before-rename", "after-rename")) {
            val root = temporary.newFolder()
            val source = proof(root, "original")
            val raw = proof(root, "raw")
            val stage = proof(root, "stage", "new synthetic work")
            terminateChild(root, "generation", "$boundary:${"%020d".format(index)}.event")
            val accounts = store(root)
            val resumed = journal(root, accounts)
            if (resumed.status().route != "G1") {
                resumed.beginGeneration("G1", source, enrollment)
                resumed.rawVerified("G1", raw)
                resumed.stageSynthetic("G1", stage)
                resumed.commitSyntheticRoute("G1")
            }
            assertEquals("G1", resumed.status().route)
            assertEquals(4, File(root, "generation-journal").listFiles()!!.count { it.extension == "event" })
            assertEquals(0, resumed.status().pendingAdmissions)
            assertEquals("original corrupt XML and exact JPEG reference", File(root, "original/evidence.bin").readText())
        }
    }

    @Test fun actualHostTerminationOfCallbackKeepsAdmissionAndRequiresExplicitOriginalActorResume() {
        for (point in listOf("before-rename:operation.record", "after-rename:operation.record",
            "before-rename:00000000000000000002.event", "after-rename:00000000000000000002.event")) {
            val root = temporary.newFolder()
            terminateChild(root, "callback", point)
            val accounts = store(root)
            val ledger = journal(root, accounts)
            val b = accounts.authenticateVerifiedAccount("B", setOf("shared"))
            contractDenied { access(root, accounts, ledger, b).resume("operation") }
            assertTrue(access(root, accounts, ledger, b).read().isEmpty())
            val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
            val resumed = access(root, accounts, ledger, a)
            if (ledger.status().pendingAdmissions != 0) {
                contractDenied { resumed.read() }
                resumed.publish(resumed.resume("operation"), "exact child-JVM evidence".toByteArray())
            }
            assertEquals(1, resumed.read().size)
            assertEquals("exact child-JVM evidence", resumed.read().single().bytes.toString(Charsets.UTF_8))
        }
    }

    @Test fun legacyFenceRefusesReentrantMutationAndDefersRunningOperation() {
        val fence = FieldHandoverFence(setOf("writer")).also { it.register("writer") }
        assertEquals("copied", fence.idleBaseline({ false }) {
            contractDenied { fence.legacyOperation("writer") { fail("Reentrant write") } }
            "copied"
        })
        fence.legacyOperation("writer") {
            // A read-to-write upgrade must defer rather than deadlock or interrupt this writer.
            assertNull(fence.idleBaseline({ false }) { fail("Running writer capture") })
        }
    }

    private fun terminateChild(root: File, mode: String, point: String) {
        val output = File(root, "child.log")
        val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").absolutePath, "-cp",
            contractClasspath(), DisabledStage1BProcess::class.java.name, root.absolutePath, mode, point)
            .redirectErrorStream(true).redirectOutput(output).start()
        try {
            assertTrue("Child timeout at $point", child.waitFor(25, TimeUnit.SECONDS))
            assertEquals(output.readText(), 73, child.exitValue())
        } finally { if (child.isAlive) child.destroyForcibly() }
    }

    @Test fun damagedChainMissingEventAndIncompleteEnrollmentFailClosed() {
        val root = temporary.newFolder()
        val accounts = store(root)
        val ledger = journal(root, accounts)
        contractDenied { ledger.beginGeneration("G1", proof(root, "original"), enrollment - FieldCallerFamily.EXPORT_CAPTURE) }
        ledger.beginGeneration("G1", proof(root, "original"), enrollment)
        ledger.rawVerified("G1", proof(root, "raw"))
        File(root, "generation-journal/00000000000000000001.event").writeText("corrupt-original")
        contractDenied { ledger.status() }
        assertTrue(File(root, "original/evidence.bin").exists())
        assertTrue(File(root, "raw/evidence.bin").exists())
    }
}

private fun contractClasspath(): String = buildSet {
    addAll((System.getProperty("java.class.path") ?: "").split(File.pathSeparator))
    var loader: ClassLoader? = DisabledStage1BContractsTest::class.java.classLoader
    while (loader != null) {
        (loader as? java.net.URLClassLoader)?.getURLs()?.filter { it.protocol == "file" }?.forEach { add(File(it.toURI()).absolutePath) }
        loader = loader.parent
    }
}.joinToString(File.pathSeparator)

/** Actual abrupt host exit; explicitly not an Android app-process kill. */
object DisabledStage1BProcess {
    @JvmStatic fun main(args: Array<String>) {
        val root = File(args[0])
        val disk = contractDisk { if (it == args[2]) Runtime.getRuntime().halt(73) }
        val accounts = AccountEvidenceStore(File(root, "new-accounts"), disk)
        val ledger = DisabledGenerationJournal(root, disk, accounts)
        if (args[1] == "generation") {
            fun proof(name: String) = ClosedSetProof(name, "proofs/$name.json", IsolationDisk.digest(File(root, "proofs/$name.json")))
            ledger.beginGeneration("G1", proof("original"), FieldCallerFamily.entries.toSet())
            ledger.rawVerified("G1", proof("raw"))
            ledger.stageSynthetic("G1", proof("stage"))
            ledger.commitSyntheticRoute("G1")
        } else {
            val a = accounts.authenticateVerifiedAccount("A", setOf("shared"))
            val access = DisabledFamilyAccess(root, disk, accounts, ledger, a, "shared", FieldCallerFamily.QUEUE)
            access.publish(access.begin("operation"), "exact child-JVM evidence".toByteArray())
        }
        error("Expected termination checkpoint not reached")
    }
}
