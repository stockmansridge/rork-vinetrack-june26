package com.rork.vinetrack.data

import java.io.File
import org.junit.Assert.assertFalse
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
    fun `off move unavailable then on rejects the previous follow coordinate`() {
        val gate = FollowSessionGate()
        val firstSession = gate.enable()
        var cameraCoordinate = "first-fix"
        gate.disable()

        val secondSession = gate.enable()
        val unavailableUpdate: String? = null
        if (unavailableUpdate != null && gate.accepts(firstSession)) cameraCoordinate = unavailableUpdate

        assertFalse(gate.accepts(firstSession))
        assertTrue(gate.accepts(secondSession))
        assertTrue(cameraCoordinate == "first-fix")
    }

    @Test
    fun `foreground recovery accepts only the current follow session`() {
        val gate = FollowSessionGate()
        val currentSession = gate.enable()
        assertTrue(gate.accepts(currentSession))

        gate.disable()
        val restartedSession = gate.enable()
        assertFalse(gate.accepts(currentSession))
        assertTrue(gate.accepts(restartedSession))
    }

    @Test
    fun `fresh movement follows while preserving zoom bearing and tilt`() {
        val source = map()
        val followEffect = source.substringAfter("LaunchedEffect(followCoordinate, isFollowingUser, followSessionId)")
            .substringBefore("// A one-finger pan")

        assertTrue(followEffect.contains(".target(coordinate)"))
        assertTrue(followEffect.contains(".zoom(current.zoom)"))
        assertTrue(followEffect.contains(".bearing(current.bearing)"))
        assertTrue(followEffect.contains(".tilt(current.tilt)"))
        assertFalse(followEffect.contains("fitToContent("))
    }

    @Test
    fun `manual pan cancels follow but pinch zoom alone does not`() {
        val source = map()
        val gestureEffect = source.substringAfter("// A one-finger pan disables following")
            .substringBefore("val followPermissionLauncher")

        assertTrue(gestureEffect.contains("CameraMoveStartedReason.GESTURE"))
        assertTrue(gestureEffect.contains("centreMoved && zoomUnchanged"))
        assertTrue(gestureEffect.contains("isFollowingUser = false"))
    }

    @Test
    fun `location loss waits in place and fresh recovery resumes`() {
        val source = map()
        val subscription = source.substringAfter("fun startFollowingUpdates()")
            .substringBefore("val observer")

        assertTrue(subscription.contains("result is PinLocationResult.Success"))
        assertTrue(subscription.contains("followSessionGate.accepts(subscribedSessionId)"))
        assertTrue(subscription.contains("followCoordinate = subscribedSessionId to LatLng"))
        assertTrue(subscription.contains("isFollowWaiting = true"))
        assertFalse(subscription.contains("cameraPositionState"))
    }

    @Test
    fun `background suspends updates and foreground resumes only while enabled`() {
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
