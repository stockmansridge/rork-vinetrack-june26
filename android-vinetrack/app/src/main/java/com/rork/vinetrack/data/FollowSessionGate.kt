package com.rork.vinetrack.data

/**
 * Issues a new identity whenever Follow Me is enabled and rejects coordinates
 * delivered for an earlier or disabled session.
 */
class FollowSessionGate {
    private var nextSessionId: Long = 0L
    private var activeSessionId: Long? = null

    fun enable(): Long {
        nextSessionId += 1L
        activeSessionId = nextSessionId
        return nextSessionId
    }

    fun disable() {
        activeSessionId = null
    }

    fun accepts(sessionId: Long): Boolean = activeSessionId == sessionId
}
