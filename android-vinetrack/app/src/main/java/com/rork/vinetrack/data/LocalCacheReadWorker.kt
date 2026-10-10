package com.rork.vinetrack.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Read-only hydration work. No asynchronous writes or outbox work are admitted. */
object LocalCacheReadWorker {
    suspend fun <T> read(operation: () -> T): T = withContext(Dispatchers.IO) { operation() }
}
