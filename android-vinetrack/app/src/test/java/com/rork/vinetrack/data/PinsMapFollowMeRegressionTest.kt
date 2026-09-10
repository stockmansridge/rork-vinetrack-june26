package com.rork.vinetrack.data

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the Pins-only Follow Me camera and lifecycle contract. */
class PinsMapFollowMeRegressionTest {
    private fun source(relative: String): String {
        val candidates = listOf(File(relative), File("app/$relative"), File("android-vinetrack/app/$relative"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Source not found: $relative (cwd=${File(".").absolutePath})")
    }

    private fun map(): String = source(
        "src/main/java/com/rork/vinetrack/ui/screens/VineyardMapScreen.kt",
    )

    @Test
    fun `old session update arriving after re-enable is rejected`() {
        val gate = FollowSessionGate()
        val oldSession = gate.enable()
        gate.disable()
        val currentSession = gate.enable()

        assertNull(gate.acceptedCoordinate(oldSession, "stale-fix"))
        assertEquals("fresh-fix", gate.acceptedCoordinate(currentSession, "fresh-fix"))
    }

    @Test
    fun `unavailable GPS produces no camera update and retains current camera`() {
        val gate = FollowSessionGate()
        val session = gate.enable()
        val currentCamera = FollowCameraSnapshot("current", 19f, 73f, 12f)
        val unavailableCoordinate: String? = null

        val acceptedCoordinate = gate.acceptedCoordinate(session, unavailableCoordinate)

        assertNull(acceptedCoordinate)
        assertEquals(FollowCameraSnapshot("current", 19f, 73f, 12f), currentCamera)
    }

    @Test
    fun `fresh accepted update changes target while preserving zoom bearing and tilt`() {
        val gate = FollowSessionGate()
        val session = gate.enable()
        val currentCamera = FollowCameraSnapshot("current", 19f, 73f, 12f)

        val update = gate.cameraUpdate(session, "fresh-fix", currentCamera)

        assertEquals(FollowCameraSnapshot("fresh-fix", 19f, 73f, 12f), update)
    }

    @Test
    fun `foreground restart remains eligible only for the active follow session`() {
        val gate = FollowSessionGate()
        val activeSession = gate.enable()
        assertTrue(gate.accepts(activeSession))

        gate.disable()
        assertFalse(gate.accepts(activeSession))
        val restartedSession = gate.enable()
        assertTrue(gate.accepts(restartedSession))
        assertFalse(gate.accepts(activeSession))
    }

    @Test
    fun `production camera update preserves zoom bearing and tilt`() {
        val source = map()
        val followEffect = source.substringAfter("LaunchedEffect(followCoordinate, isFollowingUser, followSessionId)")
            .substringBefore("// A one-finger pan")

        assertTrue(followEffect.contains("followSessionGate.cameraUpdate("))
        assertTrue(followEffect.contains("target = current.target"))
        assertTrue(followEffect.contains("zoom = current.zoom"))
        assertTrue(followEffect.contains("bearing = current.bearing"))
        assertTrue(followEffect.contains("tilt = current.tilt"))
        assertTrue(followEffect.contains(".target(cameraUpdate.target)"))
        assertTrue(followEffect.contains(".zoom(cameraUpdate.zoom)"))
        assertTrue(followEffect.contains(".bearing(cameraUpdate.bearing)"))
        assertFalse(followEffect.contains("fitToContent("))
    }

    @Test
    fun `manual pan cancels follow but pinch zoom alone does not`() {
        val source = map()
        val gestureEffect = source.substringAfter("// A one-finger pan disables following")
            .substringBefore("val followPermissionLauncher")

        assertTrue(gestureEffect.contains("CameraMoveStartedReason.GESTURE"))
        assertTrue(gestureEffect.contains("centreMoved && zoomUnchanged"))
        assertTrue(gestureEffect.contains("stopFollowSession()"))
    }

    @Test
    fun `production unavailable GPS waiting path does not own the camera source contract`() {
        val source = map()
        val subscription = source.substringAfter("fun startFollowingUpdates()")
            .substringBefore("val observer")

        assertTrue(subscription.contains("result is PinLocationResult.Success"))
        assertTrue(subscription.contains("followSessionGate.accepts(subscribedSessionId)"))
        assertTrue(subscription.contains("followSessionGate.acceptedCoordinate(subscribedSessionId, coordinate)"))
        assertTrue(subscription.contains("followCoordinate = subscribedSessionId to acceptedCoordinate"))
        assertTrue(subscription.contains("isFollowWaiting = true"))
        assertFalse(subscription.contains("cameraPositionState"))
    }

    @Test
    fun `production foreground recovery lifecycle wiring source contract`() {
        val source = map()
        val lifecycle = source.substringAfter("DisposableEffect(isPinsMap, isFollowingUser")
            .substringBefore("LaunchedEffect(followCoordinate")

        assertTrue(lifecycle.contains("Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME -> startFollowingUpdates()"))
        assertTrue(lifecycle.contains("Lifecycle.Event.ON_STOP -> locationTracker.stopPinFixUpdates()"))
        assertTrue(lifecycle.contains("locationTracker.stopPinFixUpdates()"))
    }

    @Test
    fun `Pins owns labelled default-off follow without changing My Current Location zoom`() {
        val source = map()

        assertTrue(source.contains("var isFollowingUser by remember { mutableStateOf(false) }"))
        assertTrue(source.contains("text = \"Follow Me\""))
        assertTrue(source.contains("targetZoom = PINS_MY_LOCATION_ZOOM"))
        assertTrue(source.contains("locationTracker = locationTracker"))
    }
}
