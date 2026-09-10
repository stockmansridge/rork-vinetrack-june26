package com.rork.vinetrack.data

/**
 * Issues a new identity whenever Follow Me is enabled and rejects coordinates
 * delivered for an earlier or disabled session.
 */
data class FollowCameraSnapshot<T>(
    val target: T,
    val zoom: Float,
    val bearing: Float,
    val tilt: Float,
)

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

    fun <T> acceptedCoordinate(sessionId: Long, coordinate: T?): T? =
        coordinate?.takeIf { accepts(sessionId) }

    fun <T> cameraUpdate(
        sessionId: Long,
        coordinate: T,
        currentCamera: FollowCameraSnapshot<T>,
    ): FollowCameraSnapshot<T>? {
        if (!accepts(sessionId)) return null
        return currentCamera.copy(target = coordinate)
    }
}
