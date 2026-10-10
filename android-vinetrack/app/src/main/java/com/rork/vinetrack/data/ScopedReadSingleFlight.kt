package com.rork.vinetrack.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeout

/** Shares only overlapping read work. Completed values/errors are never cached. */
internal class ScopedReadSingleFlight<T> {
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val flights = mutableMapOf<Pair<String, String>, Deferred<T>>()

    /** Scope values remain private and must never be logged or exported. */
    suspend fun read(owner: String, credential: String, request: suspend () -> T): T {
        val key = owner to credential
        val flight = synchronized(lock) {
            flights[key]?.takeUnless { it.isCompleted } ?: scope.async(start = CoroutineStart.LAZY) {
                // Bound read lifetime independently of any one cancelled waiter.
                withTimeout(60_000L) { request() }
            }.also { created ->
                flights[key] = created
                created.invokeOnCompletion {
                    synchronized(lock) {
                        if (flights[key] === created) flights.remove(key)
                    }
                }
            }
        }
        flight.start()
        return flight.await()
    }
}
