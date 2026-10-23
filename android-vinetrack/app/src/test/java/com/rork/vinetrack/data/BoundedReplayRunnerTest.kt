package com.rork.vinetrack.data

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class BoundedReplayRunnerTest {
    @Test(timeout = 10000) fun reconnectForegroundStormHasOneActiveAndOneTrailingPass() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val idle = CompletableDeferred<Unit>()
        var calls = 0
        var active = 0
        var peak = 0
        val runner = BoundedReplayRunner(this, { _, e -> throw e }, { idle.complete(Unit) })
        val pass: suspend () -> Unit = {
            calls++; active++; peak = maxOf(peak, active)
            if (calls == 1) { started.complete(Unit); release.await() }
            active--
        }
        runner.request("all", pass)
        started.await()
        repeat(10000) { runner.request("all", pass) }
        assertFalse(idle.isCompleted)
        release.complete(Unit)
        idle.await()
        assertEquals(2, calls)
        assertEquals(1, peak)
    }

    @Test(timeout = 10000) fun failedStageRetainsNextStageAndRetryIndicatorUntilActualCompletion() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val idle = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        val runner = BoundedReplayRunner(this, { key, _ -> events += "held:$key" }, { idle.complete(Unit) })
        runner.request("bad") { throw java.io.IOException("synthetic storage") }
        runner.request("good") { events += "started"; release.await(); events += "finished" }
        yield()
        assertFalse(idle.isCompleted)
        release.complete(Unit)
        idle.await()
        assertEquals(listOf("held:bad", "started", "finished"), events)
    }

    @Test(timeout = 10000) fun coalescedAwaitersCannotPullBeforePushFinishesAndFailureDoesNotStrandThem() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val runner = BoundedReplayRunner(this, { _, _ -> })
        val active = runner.request("push") { started.complete(Unit); release.await() }
        started.await()
        val trailing = runner.request("push") { }
        val coalesced = runner.request("push") { }
        assertSame(trailing, coalesced)
        assertFalse(active.isCompleted)
        assertFalse(trailing.isCompleted)
        release.complete(Unit)
        assertTrue(active.await())
        assertTrue(trailing.await())
        val failed = runner.request("bad") { throw java.io.IOException("synthetic storage") }
        assertFalse(failed.await())
        assertTrue(runner.request("independent") { }.await())
    }

    @Test(timeout = 10000) fun cancelledScopeBeforeFirstInstructionReleasesAwaiters() = runBlocking {
        val owner = CoroutineScope(coroutineContext + Job())
        owner.cancel()
        val runner = BoundedReplayRunner(owner, { _, _ -> })
        val completion = runner.request("push") { fail("Cancelled owner ran a stage") }
        try { completion.await(); fail("Cancelled completion reported success") }
        catch (_: CancellationException) { }
        assertTrue(completion.isCancelled)
    }

    @Test(timeout = 10000) fun nestedDependencyFollowupIsAwaitedBeforeIdle() = runBlocking {
        val idle = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        val runner = BoundedReplayRunner(this, { _, e -> throw e }, { idle.complete(Unit) })
        runner.request("create") {
            events += "create"
            runner.request("evidence") { events += "evidence" }
        }
        runner.request("delete") { events += "delete" }
        idle.await()
        assertEquals(listOf("create", "delete", "evidence"), events)
    }
}
