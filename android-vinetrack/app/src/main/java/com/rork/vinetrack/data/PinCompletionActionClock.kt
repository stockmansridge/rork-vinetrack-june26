package com.rork.vinetrack.data

/** Identifies the newest local toggle, including online requests not yet represented in the outbox. */
internal class PinCompletionActionClock {
    private val versions = mutableMapOf<String, Long>()

    @Synchronized
    fun begin(pinId: String): Long = ((versions[pinId] ?: 0L) + 1L).also { versions[pinId] = it }

    @Synchronized
    fun isCurrent(pinId: String, version: Long): Boolean = versions[pinId] == version
}
