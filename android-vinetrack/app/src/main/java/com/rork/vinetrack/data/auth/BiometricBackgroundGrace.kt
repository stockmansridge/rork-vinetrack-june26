package com.rork.vinetrack.data.auth

/** Cold-restored sessions use their existing lock route; this governs only a live app resume. */
object BiometricBackgroundGrace {
    const val TIMEOUT_MS: Long = 3_600_000L

    fun shouldLock(elapsedMs: Long, isEnabled: Boolean): Boolean =
        isEnabled && (elapsedMs < 0L || elapsedMs >= TIMEOUT_MS)
}
