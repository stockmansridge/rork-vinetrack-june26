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
    fun `Google Map is measured inside the bounded viewport rather than a vertical scroller`() {
        val screen = source(
            "src/main/java/com/rork/vinetrack/ui/screens/ElRipenessHeatmapScreen.kt"
        )
        val readyBranch = screen.substringAfter("is ElRipenessLoadState.Ready -> {")
            .substringBefore("sheetObservation?.let")

        assertFalse(
            "Android GoogleMap must not be hosted by an unbounded verticalScroll",
            readyBranch.contains("verticalScroll("),
        )
        assertTrue(
            "The map must consume a finite share of the parent viewport",
            readyBranch.contains("Modifier.weight(1f).fillMaxWidth()"),
        )
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
