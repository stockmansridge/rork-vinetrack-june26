package com.rork.vinetrack.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** One active task, one trailing intent per fixed stage key; never one coroutine per trigger.
 * No automatic retry-on-failure loop. Owners supply a finite set of stage keys.
 * Synchronised admission also supports deterministic host concurrency tests.
 */
internal class BoundedReplayRunner(
    private val scope: CoroutineScope,
    private val onFailure: (String, Exception) -> Unit,
    private val onIdle: () -> Unit = {},
) {
    private data class Stage(val action: suspend () -> Unit, val completion: CompletableDeferred<Boolean>)
    private val pending = linkedMapOf<String, Stage>()
    private var worker: Job? = null

    @Synchronized
    fun request(key: String, action: suspend () -> Unit): Deferred<Boolean> {
        val completion = pending[key]?.completion ?: CompletableDeferred()
        pending[key] = Stage(action, completion)
        if (worker != null) return completion
        val job = scope.launch(start = CoroutineStart.LAZY) {
            drain()
        }
        worker = job
        job.invokeOnCompletion { failure ->
            // A cancelled parent can prevent even the first instruction from
            // running. Awaiting push-then-fetch callers must still be released.
            if (failure != null) synchronized(this) {
                if (worker === job) {
                    pending.values.forEach { it.completion.cancel() }
                    pending.clear()
                    worker = null
                    onIdle()
                }
            }
        }
        job.start()
        return completion
    }

    private suspend fun drain() {
        try {
            // Batch one synchronous lifecycle/Retry All fan-out even on Main.immediate.
            kotlinx.coroutines.yield()
            while (true) {
                val next = synchronized(this) {
                    val entry = pending.entries.firstOrNull()
                    if (entry == null) {
                        worker = null
                        onIdle()
                        null
                    } else (entry.key to entry.value).also { pending.remove(entry.key) }
                } ?: return
                try {
                    next.second.action()
                    next.second.completion.complete(true)
                } catch (cancelled: CancellationException) {
                    next.second.completion.cancel(cancelled)
                    throw cancelled
                } catch (failure: Exception) {
                    next.second.completion.complete(false)
                    try { onFailure(next.first, failure) }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { /* Diagnostics cannot strand independent stages. */ }
                }
            }
        } catch (cancelled: CancellationException) {
            synchronized(this) {
                pending.values.forEach { it.completion.cancel(cancelled) }
                pending.clear() // Runtime requests only, never durable queued work.
                worker = null
                onIdle()
            }
            throw cancelled
        }
    }
}
