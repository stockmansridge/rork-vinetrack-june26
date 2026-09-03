package com.rork.vinetrack.data

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the Android-only Damage editor interaction contract. */
class DamageMapInteractionRegressionTest {
    private fun source(): String {
        val relative = "src/main/java/com/rork/vinetrack/ui/screens/DamageRecordsScreen.kt"
        val candidates = listOf(File(relative), File("app/$relative"), File("android-vinetrack/app/$relative"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Source not found: $relative (cwd=${File(".").absolutePath})")
    }

    private fun editor(source: String): String = source.substringAfter("private fun RecordDamageView(")
        .substringBefore("// MARK: - Helpers")

    @Test
    fun `map is a bounded sibling rather than a child of the scrolling form`() {
        val editor = editor(source())
        val beforeMap = editor.substringBefore("GoogleMap(")

        assertFalse(beforeMap.contains("verticalScroll(rememberScrollState())"))
        assertTrue(beforeMap.contains(".height(340.dp)"))
        assertTrue(editor.substringAfter("GoogleMap(").contains(".weight(1f)\n                    .verticalScroll"))
    }

    @Test
    fun `damage map explicitly enables precise touch navigation and close zoom`() {
        val editor = editor(source())

        assertTrue(editor.contains("mapType = MapType.HYBRID"))
        assertTrue(editor.contains("maxZoomPreference = DAMAGE_MAP_MAX_ZOOM"))
        assertTrue(source().contains("private const val DAMAGE_MAP_MAX_ZOOM = 21f"))
        assertTrue(editor.contains("scrollGesturesEnabled = true"))
        assertTrue(editor.contains("zoomGesturesEnabled = true"))
        assertTrue(editor.contains("rotationGesturesEnabled = true"))
        assertTrue(editor.contains("tiltGesturesEnabled = false"))
    }

    @Test
    fun `camera frames once and point edits never move it`() {
        val editor = editor(source())
        val framing = editor.substringAfter("LaunchedEffect(mapLoaded, paddock.id)")
            .substringBefore("Scaffold(")

        assertTrue(framing.contains("initiallyFramed"))
        assertFalse(editor.contains("LaunchedEffect(mapLoaded, paddock.id, committedPoints"))
        assertFalse(editor.substringAfter("onMapClick").substringBefore("onMapLoaded").contains("cameraPositionState"))
        assertFalse(editor.substringAfter("snapshotFlow").substringBefore("Marker(").contains("cameraPositionState"))
    }

    @Test
    fun `native markers stay stable and polygon commits only after drag end`() {
        val editor = editor(source())

        assertTrue(editor.contains("key(vertex.id)"))
        assertTrue(editor.contains("state = vertex.markerState"))
        assertTrue(editor.contains("snapshotFlow { vertex.markerState.isDragging }"))
        assertTrue(editor.contains("if (wasDragging && !isDragging)"))
        assertTrue(editor.contains("vertex.committedPosition = vertex.markerState.position"))
        assertTrue(editor.contains("points = committedPoints"))
        assertFalse(editor.contains("verts.map { it.position }"))
    }

    @Test
    fun `save uses the same committed coordinates displayed by the polygon`() {
        val editor = editor(source())

        assertTrue(editor.contains("points = committedPoints"))
        assertTrue(editor.contains("buildRecord(editing, paddock, committedPoints"))
    }
}
