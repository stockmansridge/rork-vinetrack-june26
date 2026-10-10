package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

/** Executed read-stage evidence, not physical startup/network/rendering or live-server acceptance. */
class WorkTaskReadBatchTest {
    private val headers = listOf(WorkTask("task", "vineyard"))

    @Test(timeout = 10000) fun allFourReadsStartWithoutWaitingForUnrelatedResponses() = runBlocking {
        val count = AtomicInteger(0)
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        suspend fun waitForResponse() { if (count.incrementAndGet() == 4) started.complete(Unit); release.await() }
        val work = async { WorkTaskReadBatch.read({ true },
            { waitForResponse(); headers }, { waitForResponse(); emptyList() },
            { waitForResponse(); emptyList() }, { waitForResponse(); emptyList() }) }
        started.await()
        assertEquals(4, count.get())
        release.complete(Unit)
        assertEquals(headers, work.await().headers)
    }

    @Test(timeout = 10000) fun childFailureStaysUnknownRatherThanAuthoritativeEmpty() = runBlocking {
        val result = WorkTaskReadBatch.read({ true }, { headers }, { emptyList() },
            { throw java.io.IOException("offline") }, { emptyList() })
        assertEquals(headers, result.headers)
        assertNull(result.labour)
        assertEquals(emptyList<WorkTaskMachineLine>(), result.machines)
    }

    @Test(timeout = 10000) fun requiredHeaderFailureNeverProducesResult() = runBlocking {
        try {
            WorkTaskReadBatch.read({ true }, { throw java.io.IOException("offline") },
                { emptyList() }, { emptyList() }, { emptyList() })
            fail("Header failure was accepted")
        } catch (_: java.io.IOException) { }
    }

    @Test(timeout = 10000) fun revokedOrChangedSelectionAfterWaitCannotPublishResult() = runBlocking {
        var current = true
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val work = async {
            try {
                WorkTaskReadBatch.read({ current }, { started.complete(Unit); release.await(); headers },
                    { emptyList() }, { emptyList() }, { emptyList() })
                fail("Stale results published")
            } catch (_: BackendError.Unauthorized) { }
        }
        started.await(); current = false; release.complete(Unit); work.await()
        var reads = 0
        try {
            WorkTaskReadBatch.read({ false }, { reads++; headers }, { reads++; emptyList() },
                { reads++; emptyList() }, { reads++; emptyList() })
            fail("Read admitted")
        } catch (_: BackendError.Unauthorized) { }
        assertEquals(0, reads)
    }

    @Test(timeout = 10000) fun cancellationDoesNotTurnChildIntoEmptyOrContinuePublication() = runBlocking {
        val started = CompletableDeferred<Unit>()
        var published = false
        val work = launch {
            WorkTaskReadBatch.read({ true }, { started.complete(Unit); awaitCancellation() },
                { awaitCancellation() }, { awaitCancellation() }, { awaitCancellation() })
            published = true
        }
        started.await(); work.cancelAndJoin()
        assertFalse(published)
    }

    @Test(timeout = 10000) fun allocationsOverlapCoreReadsAndReturnExactResults() = runBlocking {
        val count = AtomicInteger(0)
        val allStarted = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val allocations = listOf(TripCostAllocation("allocation", "vineyard", "trip", totalCostRaw = "123.45"))
        suspend fun read() { if (count.incrementAndGet() == 5) allStarted.complete(Unit); release.await() }
        val work = async { WorkTaskReadBatch.read({ true }, { read(); headers }, { read(); emptyList() },
            { read(); emptyList() }, { read(); emptyList() }, { read(); allocations }) }
        allStarted.await(); assertEquals(5, count.get()); release.complete(Unit)
        val result = work.await()
        assertEquals(headers, result.headers); assertEquals(allocations, result.allocations)
    }

    @Test(timeout = 10000) fun allocationFailureIsUnknownAndForbiddenProviderDoesNoRead() = runBlocking {
        val failed = WorkTaskReadBatch.read({ true }, { headers }, { emptyList() }, { emptyList() }, { emptyList() },
            { throw java.io.IOException("offline") })
        assertNull(failed.allocations)
        var reads = 0
        val allowed = false
        val forbidden = WorkTaskReadBatch.read({ true }, { headers }, { emptyList() }, { emptyList() }, { emptyList() },
            { if (allowed) { reads++; emptyList() } else emptyList() })
        assertEquals(0, reads); assertEquals(emptyList<TripCostAllocation>(), forbidden.allocations)
    }

    @Test(timeout = 10000) fun requiredFailureCancelsSuspendedAllocation() = runBlocking {
        val started = CompletableDeferred<Unit>()
        var cancelled = false
        try {
            WorkTaskReadBatch.read({ true }, { started.await(); throw java.io.IOException("offline") },
                { emptyList() }, { emptyList() }, { emptyList() },
                { try { started.complete(Unit); awaitCancellation() } finally { cancelled = true } })
            fail("Header failure accepted")
        } catch (_: java.io.IOException) { }
        assertTrue(cancelled)
    }

    @Test(timeout = 10000) fun allocationCancellationAndChangedScopeCannotPublish() = runBlocking {
        var current = true
        try {
            WorkTaskReadBatch.read({ current }, { headers }, { emptyList() }, { emptyList() }, { emptyList() },
                { current = false; emptyList() })
            fail("Changed scope accepted")
        } catch (_: BackendError.Unauthorized) { }
        try {
            WorkTaskReadBatch.read({ true }, { headers }, { emptyList() }, { emptyList() }, { emptyList() },
                { throw CancellationException("cancel") })
            fail("Allocation cancellation accepted")
        } catch (_: CancellationException) { }
    }

    @Test(timeout = 15000) fun pairedSequentialAndParallelReadStageMeasurementsWithFreshReadsEveryRun() = runBlocking {
        val counts = AtomicInteger(0)
        suspend fun response() { counts.incrementAndGet(); delay(80) }
        for (phase in listOf("first-use", "repeat-use")) {
            repeat(3) { run ->
                counts.set(0)
                val beforeStart = System.nanoTime()
                response(); val baselineHeaders = headers
                response(); response(); response()
                val beforeMs = (System.nanoTime() - beforeStart) / 1_000_000.0
                assertEquals(4, counts.get())
                counts.set(0)
                val afterStart = System.nanoTime()
                val result = WorkTaskReadBatch.read({ true }, { response(); headers },
                    { response(); emptyList() }, { response(); emptyList() }, { response(); emptyList() })
                val afterMs = (System.nanoTime() - afterStart) / 1_000_000.0
                assertEquals(baselineHeaders, result.headers)
                assertEquals(4, counts.get())
                println("WORK_TASK_READ_STAGE phase=$phase run=${run + 1} simulated_response_ms=80 sequential_ms=$beforeMs parallel_ms=$afterMs requests_before=4 requests_after=4")
            }
        }
    }
}
