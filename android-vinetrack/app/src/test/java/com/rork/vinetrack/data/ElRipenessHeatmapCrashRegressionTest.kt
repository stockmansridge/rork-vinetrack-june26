package com.rork.vinetrack.data

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the Android-only layout and lifecycle conditions behind the Heatmap crash. */
class ElRipenessHeatmapCrashRegressionTest {
    private fun source(relative: String): String {
        val candidates = listOf(
            File(relative),
            File("app/$relative"),
            File("android-vinetrack/app/$relative"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Source not found: $relative (cwd=${File(".").absolutePath})")
    }

    @Test
    fun `Google Map has a finite viewport with scrolling content below it`() {
        val screen = source(
            "src/main/java/com/rork/vinetrack/ui/screens/ElRipenessHeatmapScreen.kt"
        )
        val readyBranch = screen.substringAfter("is ElRipenessLoadState.Ready -> {")
            .substringBefore("sheetObservation?.let")
        val mapCall = readyBranch.indexOf("HeatMap(")
        val scrollingSibling = readyBranch.indexOf(".verticalScroll(rememberScrollState())")

        assertTrue("The map viewport must have a finite height", readyBranch.contains(".height(320.dp)"))
        assertTrue("Scrolling detail must remain below the map", mapCall >= 0 && scrollingSibling > mapCall)
        assertFalse(
            "The map call itself must not be wrapped by verticalScroll",
            readyBranch.substring(0, mapCall).contains("verticalScroll("),
        )
    }

    @Test
    fun `native map content waits for a loaded and measured map`() {
        val screen = source(
            "src/main/java/com/rork/vinetrack/ui/screens/ElRipenessHeatmapScreen.kt"
        )
        val map = screen.substringAfter("private fun HeatMap(")
            .substringBefore("private enum class PinStyle")

        assertTrue(map.contains("onSizeChanged { mapViewportSize = it }"))
        assertTrue(map.contains("onMapLoaded = { mapLoaded = true }"))
        assertTrue(map.contains("mapLoaded && mapViewportSize.width > 0 && mapViewportSize.height > 0"))
        assertTrue(map.contains("if (mapReady) {"))
        assertTrue(map.contains("LaunchedEffect(mapReady, allPoints)"))
        assertTrue(map.contains("if (mapReady && allPoints.isNotEmpty())"))
        assertTrue(map.substringAfter("if (mapReady) {").contains("GroundOverlay("))
        assertTrue(map.substringAfter("if (mapReady) {").contains("Polygon("))
        assertTrue(map.substringAfter("if (mapReady) {").contains("ObservationPin("))
        assertTrue(map.substringAfter("if (mapReady) {").contains("BlockLabel("))
    }

    @Test
    fun `ground overlays retain stable native objects across recomposition`() {
        val screen = source(
            "src/main/java/com/rork/vinetrack/ui/screens/ElRipenessHeatmapScreen.kt"
        )
        val map = screen.substringAfter("private fun HeatMap(")
            .substringBefore("private enum class PinStyle")

        assertTrue(map.contains("remember(stableBitmap) { BitmapDescriptorFactory.fromBitmap(stableBitmap) }"))
        assertTrue(map.contains("overlay.bounds.south,"))
        assertTrue(map.contains("overlay.bounds.west,"))
        assertTrue(map.contains("overlay.bounds.north,"))
        assertTrue(map.contains("overlay.bounds.east,"))
        assertTrue(map.contains("groundOverlayPositionOrNull(overlay.bounds)"))
    }

    @Test
    fun `shared model has one loader and survives Summary Heatmap switches`() {
        val heatmapScreen = source(
            "src/main/java/com/rork/vinetrack/ui/screens/ElRipenessHeatmapScreen.kt"
        )
        val growthScreen = source(
            "src/main/java/com/rork/vinetrack/ui/screens/GrowthScreen.kt"
        )

        assertTrue(heatmapScreen.contains("if (ownsModel && vineyardId != null)"))
        assertTrue(heatmapScreen.contains("if (ownsModel) model.teardown()"))
        assertTrue(growthScreen.contains("onDispose { heatmapModel.teardown() }"))
    }

    @Test
    fun `new loads and screen teardown cancel stale Heatmap work`() {
        val model = source(
            "src/main/java/com/rork/vinetrack/ui/screens/ElRipenessHeatmapViewModel.kt"
        )

        assertTrue(model.contains("private var loadJob: Job? = null"))
        assertTrue(model.contains("loadJob?.cancel()"))
        assertTrue(model.contains("loadJob = viewModelScope.launch"))
        assertTrue(model.substringAfter("fun teardown()").substringBefore("override fun onCleared")
            .contains("loadJob?.cancel()"))
    }
}
