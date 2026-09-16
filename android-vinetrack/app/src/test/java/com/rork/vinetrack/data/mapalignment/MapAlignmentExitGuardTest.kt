package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every way out of the calibration wizard must behave the same way.
 *
 * The property under test changed with local persistence. It used to be
 * "evidence is never dropped without confirmation", because leaving genuinely
 * destroyed the draft. Now that drafts are autosaved, the property is stronger:
 * **no exit route destroys anything at all**. The confirmation still appears,
 * but only to tell the operator their work is saved.
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
            guard.isConfirmingExit,
        )
    }

    @Test
    fun `with reference points back confirms before leaving`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(2))
        var exits = 0

        val exited = guard.requestExit { exits++ }

        assertFalse(exited)
        assertEquals("the operator must see the reassurance first", 0, exits)
        assertTrue(guard.isConfirmingExit)
    }

    @Test
    fun `keep calibrating dismisses the confirmation without leaving`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(3))
        var exits = 0
        guard.requestExit { exits++ }

        guard.keepCalibrating()

        assertEquals(0, exits)
        assertFalse(guard.isConfirmingExit)
        // The held exit is abandoned, not merely deferred: a later confirm
        // must not fire a stale one.
        guard.leaveAndContinueLater()
        assertEquals(0, exits)
    }

    @Test
    fun `leave and continue later runs the held exit exactly once`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(4))
        var exits = 0
        guard.requestExit { exits++ }

        guard.leaveAndContinueLater()

        assertEquals(1, exits)
        assertFalse(guard.isConfirmingExit)
        guard.leaveAndContinueLater()
        assertEquals("a second confirm must not exit again", 1, exits)
    }

    @Test
    fun `a GPS-complete checkpoint alone is worth confirming`() {
        // Reaching Stable costs a walk plus a stationary wait, so the operator
        // is told it is saved even before any reference point exists.
        val guard = MapAlignmentExitGuard()

        guard.onDraftChanged(draftWithPoints(0), hasPendingReference = false)
        assertFalse(guard.hasReferencePoints)

        guard.onDraftChanged(draftWithPoints(0), hasPendingReference = true)
        assertTrue(guard.hasReferencePoints)
        assertFalse(guard.requestExit { })
    }

    @Test
    fun `the guard tracks evidence appearing and being cleared`() {
        val guard = MapAlignmentExitGuard()

        guard.onDraftChanged(draftWithPoints(0))
        assertFalse(guard.hasReferencePoints)

        guard.onDraftChanged(draftWithPoints(1))
        assertTrue("one point is already worth mentioning", guard.hasReferencePoints)

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
        guard.leaveAndContinueLater()

        assertEquals(0, toolbarExits)
        assertEquals(1, systemExits)
    }

    @Test
    fun `the exit wording says progress is saved and never says discard`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(3))
        guard.onPersistResult(true)

        val message = guard.exitMessage()

        assertTrue(message.contains("has been saved on this Android device"))
        assertTrue(message.contains("continue from this point later"))
        // The old wording claimed the opposite of what now happens. An exit
        // prompt that lies about losing work teaches operators to fear Back.
        assertFalse(message.lowercase().contains("discard"))
        assertFalse(message.lowercase().contains("will be lost"))
    }

    @Test
    fun `an unfinished GPS reading is called out explicitly`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draftWithPoints(3))
        guard.onPersistResult(true)
        guard.onSamplingChanged(true)

        val message = guard.exitMessage()

        // A partial sample group is deliberately never persisted, so this one
        // attempt genuinely restarts. Say so rather than let it surprise them.
        assertTrue(message.contains("Completed reference points have been saved"))
        assertTrue(message.contains("unfinished GPS reading will restart"))

        guard.onSamplingChanged(false)
        assertFalse(guard.exitMessage().contains("will restart"))
    }

    @Test
    fun `the guard exposes no destructive action at all`() {
        // Deletion must require an explicit Delete draft or Start over. If the
        // guard offered a discard, an exit route could be wired to it by
        // mistake — which is exactly the bug this phase removed.
        val methods = MapAlignmentExitGuard::class.java.methods.map { it.name }

        assertFalse(methods.contains("discard"))
        assertFalse(methods.contains("deleteDraft"))
        assertTrue(methods.contains("leaveAndContinueLater"))
    }
}
