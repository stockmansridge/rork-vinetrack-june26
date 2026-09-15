package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every way out of the calibration wizard must ask the same question.
 *
 * Reference points cost real walking, so the toolbar Back button, Android
 * system Back and the wizard's own Cancel/Discard actions all route through
 * this one guard. The property being protected: evidence is never dropped
 * without the operator confirming it.
 */
class MapAlignmentExitGuardTest {

    private val scope = MapAlignmentScope("install-a", "v1")
    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    private fun draftWithPoints(count: Int): MapAlignmentDraft {
        var draft = MapAlignmentDraft(scope = scope, vineyardName = "Stockman's Ridge")
        repeat(count) { index ->
            val canonical = CanonicalCoordinate(
                origin.latitude + index * 0.001,
                origin.longitude + index * 0.001,
            )
            draft = draft.withReferencePoint(
                MapAlignmentReferencePoint(
                    id = "p$index",
                    scope = scope,
                    canonicalCoordinate = canonical,
                    selectedMapCoordinate = AndroidDisplayCoordinate(
                        canonical.latitude,
                        canonical.longitude,
                    ),
                    gpsAccuracyMetres = 2.0,
                    gpsEvidence = null,
                    capturedAtEpochMillis = 1_757_000_000_000,
                ),
            )
        }
        return draft
    }

    @Test
    fun `with no reference points back exits immediately`() {
        val guard = MapAlignmentExitGuard()
        var exits = 0

        // Both an absent draft and a scoped-but-empty one are safe to leave.
        guard.onDraftChanged(null)
        assertTrue(guard.requestExit { exits++ })

        guard.onDraftChanged(draftWithPoints(0))
        assertTrue(guard.requestExit { exits++ })

        assertEquals(2, exits)
        assertFalse(
            "leaving with nothing collected must not raise a confirmation",
            guard.isConfirmingDiscard,
        )
    }

    @Test
    fun `with reference points back requests confirmation instead of exiting`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(2))
        var exits = 0

        val exited = guard.requestExit { exits++ }

        assertFalse(exited)
        assertEquals("evidence must not be dropped on the spot", 0, exits)
        assertTrue(guard.isConfirmingDiscard)
    }

    @Test
    fun `keep calibrating dismisses the confirmation without exiting`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(3))
        var exits = 0
        guard.requestExit { exits++ }

        guard.keepCalibrating()

        assertEquals(0, exits)
        assertFalse(guard.isConfirmingDiscard)
        // The held exit is abandoned, not merely deferred: a later confirm
        // must not fire a stale one.
        guard.discard()
        assertEquals(0, exits)
    }

    @Test
    fun `discard runs the held exit exactly once`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(4))
        var exits = 0
        guard.requestExit { exits++ }

        guard.discard()

        assertEquals(1, exits)
        assertFalse(guard.isConfirmingDiscard)
        guard.discard()
        assertEquals("a second confirm must not exit again", 1, exits)
    }

    @Test
    fun `the guard tracks evidence appearing and being cleared`() {
        val guard = MapAlignmentExitGuard()

        guard.onDraftChanged(draftWithPoints(0))
        assertFalse(guard.hasReferencePoints)

        guard.onDraftChanged(draftWithPoints(1))
        assertTrue("one point is already worth protecting", guard.hasReferencePoints)

        // After a discard the draft is emptied, so Back must stop prompting.
        guard.onDraftChanged(draftWithPoints(0))
        assertFalse(guard.hasReferencePoints)
        var exits = 0
        assertTrue(guard.requestExit { exits++ })
        assertEquals(1, exits)
    }

    @Test
    fun `each exit route is confirmed separately`() {
        // Toolbar Back, then system Back: the second must not inherit the
        // first's pending exit or exit silently.
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(2))
        var toolbarExits = 0
        var systemExits = 0

        assertFalse(guard.requestExit { toolbarExits++ })
        guard.keepCalibrating()

        assertFalse(guard.requestExit { systemExits++ })
        guard.discard()

        assertEquals(0, toolbarExits)
        assertEquals(1, systemExits)
    }
}
