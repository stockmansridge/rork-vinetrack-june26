package com.rork.vinetrack.data

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the one-time My Current Location contract on the Android Pins map. */
class PinsMapCurrentLocationRegressionTest {
    private fun source(relative: String): String {
        val candidates = listOf(File(relative), File("app/$relative"), File("android-vinetrack/app/$relative"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Source not found: $relative (cwd=${File(".").absolutePath})")
    }

    private fun vineyardMap(): String = source(
        "src/main/java/com/rork/vinetrack/ui/screens/VineyardMapScreen.kt",
    )

    private fun locationButton(): String = source(
        "src/main/java/com/rork/vinetrack/ui/components/MyLocationButton.kt",
    )

    @Test
    fun `Pins map centres one valid fix at renderer maximum zoom`() {
        val map = vineyardMap()
        val button = locationButton()
        val pinsControl = map.substringAfter("if (onLocationMessage != null)")
            .substringBefore("} else {")

        assertTrue(map.contains("private const val PINS_MY_LOCATION_ZOOM = 21f"))
        assertTrue(pinsControl.contains("targetZoom = PINS_MY_LOCATION_ZOOM"))
        assertTrue(button.contains("CameraUpdateFactory.newLatLngZoom(LatLng(fix.latitude, fix.longitude), requestedZoom)"))
        assertFalse(pinsControl.contains("fitToContent("))
    }

    @Test
    fun `unavailable location leaves camera untouched and reports existing state`() {
        val button = locationButton()
        val unavailable = button.substringAfter("if (fix == null)")
            .substringBefore("val currentZoom")

        assertTrue(unavailable.contains("Current location unavailable"))
        assertFalse(unavailable.contains("camera."))
        assertTrue(button.contains("if (isLocating)"))
        assertTrue(button.contains("CircularProgressIndicator("))
    }

    @Test
    fun `late map loading cannot override a location request or completed recenter`() {
        val map = vineyardMap()
        val initialFit = map.substringAfter("LaunchedEffect(framePoints, hasCurrentLocationRequestOccurred")
            .substringBefore("// Frame the vineyard blocks once")
        val loadedFit = map.substringAfter("LaunchedEffect(mapLoaded, framePoints, hasCurrentLocationRequestOccurred")
            .substringBefore("// Re-apply tilt")

        assertTrue(initialFit.contains("hasCurrentLocationRequestOccurred"))
        assertTrue(initialFit.contains("isCurrentLocationRequestActive"))
        assertTrue(initialFit.contains("hasUserRecentred"))
        assertTrue(loadedFit.contains("hasCurrentLocationRequestOccurred"))
        assertTrue(loadedFit.contains("isCurrentLocationRequestActive"))
        assertTrue(loadedFit.contains("hasUserRecentred"))
    }

    @Test
    fun `only Pins embedding opts into My Current Location`() {
        val pins = source("src/main/java/com/rork/vinetrack/ui/screens/PinsScreen.kt")
        val map = vineyardMap()

        assertTrue(pins.contains("onLocationMessage = { message ->"))
        assertTrue(map.contains("Other map screens retain their existing content-refit control."))
    }
}
