package com.rork.vinetrack.data

/** One warning decision. Create-anyway can commit once; cancel commits nothing. */
class PinDuplicateCreateAttempt(private val create: () -> Unit) {
    private var isResolved: Boolean = false

    @Synchronized
    fun createAnyway(): Boolean {
        if (isResolved) return false
        isResolved = true
        create()
        return true
    }

    @Synchronized
    fun cancel(): Boolean {
        if (isResolved) return false
        isResolved = true
        return true
    }
}
