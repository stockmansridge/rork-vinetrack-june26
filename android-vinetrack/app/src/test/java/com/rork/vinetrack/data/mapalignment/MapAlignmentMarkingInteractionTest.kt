package com.rork.vinetrack.data.mapalignment

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the Map Alignment image-marking interaction contract.
 *
 * The field defect: the crosshair map was nested inside `WizardScaffold`, which
 * applies `verticalScroll` to the whole page, so the scroll container consumed
 * the vertical component of every one-finger pan and the satellite imagery
 * could not be moved. These are source-contract checks over the Compose wiring
 * — they assert the structure that gives the map gesture ownership; they do not
 * claim native pan/pinch was exercised.
 */
class MapAlignmentMarkingInteractionTest {

    private fun source(relative: String): String {
        val path = "src/main/java/com/rork/vinetrack/$relative"
        val candidates = listOf(
            File(path),
            File("app/$path"),
            File("android-vinetrack/app/$path"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Source not found: $path (cwd=${File(".").absolutePath})")
    }

    private fun wizard(): String = source("ui/screens/MapAlignmentWizardScreen.kt")

    private fun previewMap(): String = source("ui/screens/MapAlignmentPreviewMap.kt")

    /** The marking step only, excluding the steps that legitimately scroll. */
    private fun markingStep(): String = wizard()
        .substringAfter("private fun MarkOnImageStep(")
        .substringBefore("// --- 3c.")

    /** The dedicated marking layout. */
    private fun markingScaffold(): String = wizard()
        .substringAfter("private fun MarkingScaffold(")
        .substringBefore("// --- 3c.")

    private fun crosshairMap(): String = previewMap()
        .substringAfter("fun MapAlignmentCrosshairMap(")
        .substringBefore("private fun CrosshairReticle(")

    // ----- 1. Gesture ownership -----

    @Test
    fun `the marking step does not use the vertically scrolling wizard scaffold`() {
        val step = markingStep()

        assertFalse(
            "WizardScaffold applies verticalScroll to the whole page, which steals the map pan",
            step.contains("WizardScaffold("),
        )
        assertTrue(step.contains("MarkingScaffold("))
    }

    @Test
    fun `the map has no vertically scrolling ancestor in the marking layout`() {
        val scaffold = markingScaffold()
        val beforeMap = scaffold.substringBefore("map()")

        assertFalse(
            "a verticalScroll ancestor above the map would consume its drag gestures",
            beforeMap.contains("verticalScroll"),
        )
        // The controls scroll, and they come AFTER the map, as a sibling.
        assertTrue(scaffold.substringAfter("map()").contains("verticalScroll(rememberScrollState())"))
    }

    @Test
    fun `the map claims remaining height as a sibling of the controls`() {
        val scaffold = markingScaffold()

        assertTrue("the map must take the space between header and controls", scaffold.contains(".weight(1f)"))
        assertTrue("the map must not be crushed on a small screen", scaffold.contains(".heightIn(min = 240.dp)"))
    }

    @Test
    fun `the fixed 340dp map box is gone from the marking step`() {
        val step = markingStep()

        assertFalse(
            "a precision task should not be constrained to a fixed short map",
            step.contains(".height(340.dp)"),
        )
    }

    @Test
    fun `no pointer-event hack is used to steal gestures from a parent`() {
        val step = markingStep() + markingScaffold() + crosshairMap()

        // The fix is structural. These would mask the problem instead.
        listOf(
            "pointerInteropFilter",
            "requestDisallowInterceptTouchEvent",
            "consumeAllChanges",
            "awaitPointerEventScope",
            "nestedScroll",
        ).forEach { hack ->
            assertFalse("gesture ownership must be structural, not a $hack hack", step.contains(hack))
        }
    }

    // ----- Explicit MapUiSettings -----

    @Test
    fun `the crosshair map sets every relevant gesture setting explicitly`() {
        val map = crosshairMap()

        assertTrue(map.contains("scrollGesturesEnabled = true"))
        assertTrue(map.contains("zoomGesturesEnabled = true"))
        assertTrue(map.contains("rotationGesturesEnabled = false"))
        assertTrue(map.contains("tiltGesturesEnabled = false"))
        assertTrue(map.contains("myLocationButtonEnabled = false"))
        assertTrue(map.contains("mapToolbarEnabled = false"))
        // Pinch is the primary zoom; Google's buttons would collide with Recentre.
        assertTrue(map.contains("zoomControlsEnabled = false"))
    }

    @Test
    fun `selection remains the camera target with no map-tap selection`() {
        val map = crosshairMap()

        assertTrue("the selected coordinate is the camera target", map.contains("val target = camera.position.target"))
        assertTrue(map.contains("onTargetChanged(AndroidDisplayCoordinate(target.latitude, target.longitude))"))
        // A tap is too coarse at field zoom and the finger hides the target.
        assertFalse(map.contains("onMapClick"))
        assertFalse(map.contains("onMapLongClick"))
    }

    @Test
    fun `the crosshair stays fixed at the map centre and is not draggable`() {
        val map = crosshairMap()

        assertTrue(map.contains("CrosshairReticle(modifier = Modifier.align(Alignment.Center))"))
        assertFalse("the imagery moves, not the reticle", map.contains("draggable"))
        assertFalse(map.contains("detectDragGestures"))
    }

    // ----- 2. The recorded position must not obscure the imagery -----

    @Test
    fun `the recorded GPS position is a hollow ring not an opaque pin`() {
        val map = crosshairMap()

        // A pin's teardrop sits above its coordinate and covered the crosshair.
        assertFalse(
            "an opaque marker under the reticle hides the feature being aimed at",
            map.contains("Marker("),
        )
        assertTrue(map.contains("Circle("))
        assertTrue(map.contains("radius = GPS_RING_RADIUS_METRES"))
        assertTrue("the ring must be see-through", map.contains("fillColor = Color.Transparent"))
    }

    @Test
    fun `the recorded position ring has a real ground radius`() {
        val source = previewMap()

        assertTrue(source.contains("private const val GPS_RING_RADIUS_METRES = 1.5"))
    }

    @Test
    fun `the google my-location dot stays disabled`() {
        val map = crosshairMap()

        // It is not a selection control and would compete with the crosshair.
        assertTrue(map.contains("isMyLocationEnabled = false"))
    }

    @Test
    fun `the recentre control is retained`() {
        val map = crosshairMap()

        assertTrue("panning far away is easy; recentre must remain", map.contains("Recentre"))
        assertTrue(map.contains("CameraPosition.fromLatLngZoom("))
    }

    // ----- Nothing else changed -----

    @Test
    fun `the imagery is still drawn unaligned during capture`() {
        val map = crosshairMap()

        // Pre-correcting would hide the discrepancy being measured.
        assertTrue(map.contains("MapAlignment.none(draft.scope)"))
        assertTrue(map.contains("mapType = MapType.HYBRID"))
    }

    @Test
    fun `canonical and display typing at confirmation is unchanged`() {
        val step = markingStep()

        assertTrue(step.contains("canonicalCoordinate = mode.gps"))
        assertTrue(step.contains("selectedMapCoordinate = target"))
        assertTrue(step.contains("gpsEvidence = mode.evidence"))
        assertTrue(step.contains("capturedAtEpochMillis = mode.capturedAtEpochMillis"))
    }

    @Test
    fun `the near-duplicate guard and optional metadata are retained`() {
        val step = markingStep()

        assertTrue(step.contains("draft.isNearDuplicate(mode.gps, excludingId = mode.editingId)"))
        assertTrue(step.contains("enabled = !duplicate"))
        assertTrue(step.contains("MapAlignmentSolver.NEAR_DUPLICATE_MESSAGE"))
        assertTrue(step.contains("ReferenceTypeChips"))
        assertTrue(step.contains("RowPositionChips"))
        assertTrue(step.contains("withRemarkedImagePoint"))
    }

    @Test
    fun `other steps keep the scrolling wizard scaffold`() {
        val source = wizard()

        // Only the marking step was restructured.
        assertTrue(source.contains("private fun GpsSamplingStep("))
        assertTrue(
            source.substringAfter("private fun GpsSamplingStep(")
                .substringBefore("// --- 3b.")
                .contains("WizardScaffold(modifier = modifier)"),
        )
        assertTrue(
            source.substringAfter("private fun CaptureOverviewStep(")
                .contains("WizardScaffold(modifier = modifier)"),
        )
    }

    @Test
    fun `gps sampling and calibration rules are untouched by this change`() {
        val gps = wizard()
            .substringAfter("private fun GpsSamplingStep(")
            .substringBefore("// --- 3b.")

        // The live-subscription contract from the previous pass must survive.
        assertTrue(gps.contains("session.begin {"))
        assertTrue(gps.contains("LaunchedEffect(isStable) { if (isStable) session.end() }"))
        assertTrue(gps.contains("MapAlignmentGpsRules.SAMPLING_TIMEOUT_MILLIS"))
        assertTrue(gps.contains("liveUpdates.onCallbackReceived("))
        assertFalse("the marking fix must not touch one-shot GPS", gps.contains("fetchCurrentFix"))

        assertEquals(5, MapAlignmentGpsRules.MIN_SAMPLES)
        assertEquals(8.0, MapAlignmentGpsRules.MAX_SAMPLE_ACCURACY_METRES, 1e-9)
        assertEquals(8.0, MapAlignmentGpsRules.MAX_STABILITY_RADIUS_METRES, 1e-9)
        assertEquals(45_000L, MapAlignmentGpsRules.SAMPLING_TIMEOUT_MILLIS)
    }

    @Test
    fun `calibration maths constants are unchanged`() {
        assertEquals(10.0, MapAlignmentSolver.NEAR_DUPLICATE_METRES, 1e-9)
        assertEquals(4, MapAlignmentSolver.MIN_POINTS)
        assertEquals(3.0, MapAlignmentSolver.GOOD_RMS_RESIDUAL_METRES, 1e-9)
        assertEquals(6.0, MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES, 1e-9)
    }
}
