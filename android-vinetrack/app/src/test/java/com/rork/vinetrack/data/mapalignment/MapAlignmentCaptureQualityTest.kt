package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.PinLocationFixValidator
import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.QualifiedLocationFix
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wizard's stricter gate must only ever NARROW the existing production rule.
 *
 * The critical property is the negative one: nothing here may accept a fix the
 * production pipeline rejected, and no production threshold changes.
 */
class MapAlignmentCaptureQualityTest {

    private fun fix(accuracyMetres: Double) = QualifiedLocationFix(
        latitude = -33.2835,
        longitude = 149.0988,
        accuracyMetres = accuracyMetres,
        fixTimeEpochMs = 1_757_000_000_000,
        fixElapsedRealtimeNanos = 1_000_000_000L,
        bearingDegrees = null,
    )

    @Test
    fun `the wizard threshold is stricter than the production threshold`() {
        // The whole design rests on this: the wizard narrows, never widens.
        assertTrue(
            "wizard accuracy limit must be inside the production limit",
            MapAlignmentCaptureQuality.MAX_ACCURACY_METRES <
                PinLocationFixValidator.MAX_ACCURACY_METRES,
        )
        assertTrue(
            MapAlignmentCaptureQuality.GOOD_ACCURACY_METRES <=
                MapAlignmentCaptureQuality.MAX_ACCURACY_METRES,
        )
    }

    @Test
    fun `a precise fix is accepted`() {
        val precise = fix(2.0)
        val result = MapAlignmentCaptureQuality.evaluate(PinLocationResult.Success(precise))
        assertTrue(result is MapAlignmentCaptureQuality.Result.Accepted)
        assertSame(precise, result.acceptedFix)
    }

    @Test
    fun `a fix at exactly the wizard limit is accepted`() {
        val boundary = fix(MapAlignmentCaptureQuality.MAX_ACCURACY_METRES)
        val result = MapAlignmentCaptureQuality.evaluate(PinLocationResult.Success(boundary))
        assertTrue(result is MapAlignmentCaptureQuality.Result.Accepted)
    }

    @Test
    fun `a production-acceptable but imprecise fix is rejected for calibration`() {
        // 10 m and 15 m are fine for a pin but useless for measuring a
        // several-metre imagery offset — this is the reason the gate exists.
        listOf(6.0, 10.0, 15.0).forEach { accuracy ->
            val production = PinLocationResult.Success(fix(accuracy))
            // Production would accept it.
            assertTrue(production is PinLocationResult.Success)

            val result = MapAlignmentCaptureQuality.evaluate(production)
            assertTrue(
                "±$accuracy m must not calibrate",
                result is MapAlignmentCaptureQuality.Result.TooImpreciseForCalibration,
            )
            assertNull(result.acceptedFix)
            assertTrue(result.operatorMessage().contains("accuracy"))
        }
    }

    @Test
    fun `production rejections are passed through with their existing wording`() {
        val rejections = listOf(
            PinLocationResult.PermissionDenied,
            PinLocationResult.ApproximatePermission,
            PinLocationResult.ServicesDisabled,
            PinLocationResult.Stale,
            PinLocationResult.Inaccurate,
            PinLocationResult.Invalid,
            PinLocationResult.Timeout,
            PinLocationResult.Cancelled,
        )
        rejections.forEach { production ->
            val result = MapAlignmentCaptureQuality.evaluate(production)
            assertTrue(result is MapAlignmentCaptureQuality.Result.Rejected)
            assertNull(result.acceptedFix)
            // The existing, already-correct production message is reused verbatim.
            assertEquals(production.operatorMessage(), result.operatorMessage())
        }
    }

    @Test
    fun `the gate can never accept what production rejected`() {
        val everyRejection = listOf(
            PinLocationResult.PermissionDenied,
            PinLocationResult.ServicesDisabled,
            PinLocationResult.Stale,
            PinLocationResult.Inaccurate,
            PinLocationResult.Invalid,
            PinLocationResult.Timeout,
            PinLocationResult.Cancelled,
            PinLocationResult.ApproximatePermission,
        )
        everyRejection.forEach {
            assertNull(
                "the wizard must never manufacture a fix",
                MapAlignmentCaptureQuality.evaluate(it).acceptedFix,
            )
        }
    }

    @Test
    fun `comfort is presentation only and never rejects`() {
        assertTrue(MapAlignmentCaptureQuality.isComfortable(1.0))
        assertTrue(
            MapAlignmentCaptureQuality.isComfortable(
                MapAlignmentCaptureQuality.GOOD_ACCURACY_METRES,
            ),
        )
        val merelyAcceptable = MapAlignmentCaptureQuality.MAX_ACCURACY_METRES
        assertTrue(!MapAlignmentCaptureQuality.isComfortable(merelyAcceptable))
        // ...but still accepted.
        assertTrue(
            MapAlignmentCaptureQuality.evaluate(PinLocationResult.Success(fix(merelyAcceptable)))
                is MapAlignmentCaptureQuality.Result.Accepted,
        )
    }
}
