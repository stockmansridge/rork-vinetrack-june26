package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.spray.SprayApplicationSnapshot
import com.rork.vinetrack.data.spray.SprayPassConfiguration
import com.rork.vinetrack.data.spray.SprayPlanningIntent
import com.rork.vinetrack.data.spray.SprayPlanningOperationalGate
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** Real child-JVM termination, not Android app process-death acceptance. No transport. */
class SprayPlanningProcessRestartTest {
    @Test(timeout = 60000) fun abruptProcessTerminationRetainsBlockedOriginalPayloadAndRetryCount() = runBlocking {
        val root = kotlin.io.path.createTempDirectory("spray-process-acceptance-").toFile()
        try {
            val classpath = buildSet {
                addAll(System.getProperty("java.class.path").split(File.pathSeparator))
                var loader: ClassLoader? = javaClass.classLoader
                while (loader != null) {
                    (loader as? java.net.URLClassLoader)?.getURLs()?.filter { it.protocol == "file" }
                        ?.forEach { add(File(it.toURI()).absolutePath) }
                    loader = loader.parent
                }
            }.joinToString(File.pathSeparator)
            val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").absolutePath,
                "-cp", classpath, "com.rork.vinetrack.data.SprayPlanningAbruptProcess", root.absolutePath)
                .redirectErrorStream(true).redirectOutput(File(root, "child.log")).start()
            if (!child.waitFor(25, TimeUnit.SECONDS)) {
                child.destroyForcibly()
                fail("Child did not terminate within the acceptance bound")
            }
            assertEquals(File(root, "child.log").readText(), 73, child.exitValue())
            val original = SprayPlanningProcessDisk(File(root, "original.json")).load().single()
            val queue = PendingWriteRepository(SprayPlanningProcessDisk(File(root, "pending.json")))
            val before = queue.list().single()
            assertEquals(original.id, before.id)
            assertEquals(original.clientId, before.clientId)
            assertEquals(original.createdAt, before.createdAt)
            assertEquals(original.payloadJson, before.payloadJson)
            assertEquals(PendingWriteStatus.BLOCKED, before.status)
            assertEquals(2, before.attemptCount)
            assertEquals("Planning evidence is incomplete. Recalculate this draft before starting.", before.lastError)
            val payload = Json.decodeFromString(SprayRecordUpdateSync.Payload.serializer(), before.payloadJson)
            assertEquals(true, payload.applicationGeometry?.planningFieldsCleared)
            assertEquals("Preserved factual notes", payload.notes)
            var published = false
            SprayRecordUpdateSync(queue).replayAll { published = true }
            assertFalse(published)
            assertEquals(before, queue.list().single())
            assertEquals(0, queue.retryEligibleCount())
            assertFalse(queue.resetFailedRowForRetry(before.id))
            assertEquals(before, SprayPlanningProcessDisk(File(root, "pending.json")).load().single())
        } finally { root.deleteRecursively() }
    }
}

private class SprayPlanningProcessDisk(private val file: File) : PendingWriteStoring {
    private val json = Json { encodeDefaults = true }
    private val serializer = ListSerializer(PendingWrite.serializer())
    override fun load(): List<PendingWrite> = if (file.exists()) json.decodeFromString(serializer, file.readText()) else emptyList()
    override fun save(writes: List<PendingWrite>): Boolean {
        FileOutputStream(file).use { output ->
            output.write(json.encodeToString(serializer, writes).toByteArray())
            output.fd.sync()
        }
        return true
    }
    override fun clear(): Boolean = save(emptyList())
}

/** Persists production payload/outbox, attempts blocked replay, then halts without cleanup. */
object SprayPlanningAbruptProcess {
    @JvmStatic fun main(args: Array<String>) = runBlocking {
        val root = File(args.single())
        val snapshot = SprayApplicationSnapshot(grossAreaHa = 10.0,
            planningIntent = SprayPlanningIntent(configuration = SprayPassConfiguration.OVER_ROW)).clearingPlanning()
        val payload = SprayRecordUpdateSync.Payload("original-record", "2026-10-13", "2026-10-13",
            notes = "Preserved factual notes", applicationGeometry = snapshot, clientUpdatedAt = "original-version")
        val bytes = Json { encodeDefaults = true }.encodeToString(SprayRecordUpdateSync.Payload.serializer(), payload)
        val queue = PendingWriteRepository(SprayPlanningProcessDisk(File(root, "pending.json")))
        val original = queue.enqueue(PendingEntityType.SPRAY_RECORD, PendingOpType.UPDATE, bytes, "original-record")
        queue.incrementAttempt(original.id)
        queue.incrementAttempt(original.id)
        check(SprayPlanningProcessDisk(File(root, "original.json")).save(queue.list()))
        SprayRecordUpdateSync(queue).replayAll { error("Blocked record published success") }
        check(queue.list().single().status == PendingWriteStatus.BLOCKED)
        Runtime.getRuntime().halt(73)
    }
}
