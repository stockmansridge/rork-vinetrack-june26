package com.rork.vinetrack.data.mapalignment

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Focused state and source contracts for the active-workflow autosave warning. */
class MapAlignmentPersistenceWarningTest {

    private fun wizardSource(): String {
        val candidates = listOf(
            File("src/main/java/com/rork/vinetrack/ui/screens/MapAlignmentWizardScreen.kt"),
            File("android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/MapAlignmentWizardScreen.kt"),
        )
        return requireNotNull(candidates.firstOrNull(File::isFile)) {
            "MapAlignmentWizardScreen.kt not found"
        }.readText()
    }

    @Test
    fun `failed point autosave exposes warning state and successful retry clears it`() {
        val guard = MapAlignmentExitGuard()
        guard.onPersistResult(false)
        assertEquals(MapAlignmentDraftPersistence.SaveFailed, guard.persistence)

        var writes = 0
        assertTrue(guard.retrySave { writes++; true })

        assertEquals(1, writes)
        assertEquals(MapAlignmentDraftPersistence.Saved, guard.persistence)
    }

    @Test
    fun `failed retry keeps warning state and permits another retry`() {
        val guard = MapAlignmentExitGuard()
        guard.onPersistResult(false)
        var writes = 0

        assertFalse(guard.retrySave { writes++; false })
        assertEquals(MapAlignmentDraftPersistence.SaveFailed, guard.persistence)
        assertTrue(guard.retrySave { writes++; true })
        assertEquals(2, writes)
        assertEquals(MapAlignmentDraftPersistence.Saved, guard.persistence)
    }

    @Test
    fun `pending-reference save failure uses the same warning state`() {
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(draft(), hasPendingReference = true)
        guard.onPersistResult(false)

        assertTrue(guard.hasPendingCheckpoint)
        assertEquals(MapAlignmentDraftPersistence.SaveFailed, guard.persistence)

        val source = wizardSource()
        assertTrue(source.contains("This GPS capture may need to be repeated."))
        assertTrue(source.contains("hasPendingCheckpoint = pending != null"))
    }

    @Test
    fun `a later successful meaningful autosave clears an earlier failure`() {
        val guard = MapAlignmentExitGuard()
        guard.onPersistResult(false)
        guard.onUnsavedChange()
        assertEquals(MapAlignmentDraftPersistence.SaveFailed, guard.persistence)

        guard.onPersistResult(true)
        assertEquals(MapAlignmentDraftPersistence.Saved, guard.persistence)
    }

    @Test
    fun `warning state changes neither calibration evidence nor navigation`() {
        val calibration = draft()
        val originalReadiness = calibration.readiness
        val originalPoints = calibration.referencePoints
        val guard = MapAlignmentExitGuard()
        var navigations = 0
        var writes = 0

        guard.onDraftChanged(calibration)
        guard.onPersistResult(false)

        assertEquals(originalReadiness, calibration.readiness)
        assertEquals(originalPoints, calibration.referencePoints)
        assertEquals(0, navigations)
        assertEquals(0, writes)
        assertFalse(guard.isConfirmingExit)
    }

    @Test
    fun `banner is shared by calibration scaffolds and retry rebuilds current full state`() {
        val source = wizardSource()

        assertEquals(1, Regex("internal fun MapAlignmentPersistenceWarning\\(").findAll(source).count())
        assertTrue(source.contains("LocalMapAlignmentPersistenceWarning.current?.let"))
        assertTrue(source.contains("persistence != MapAlignmentDraftPersistence.SaveFailed"))
        assertTrue(source.contains("fun retryCurrentDraft(): Boolean"))
        assertTrue(source.contains("storableDraft(draft, step, pending, solvedAlignmentId)"))
        assertTrue(source.contains("onRetry = { retryCurrentDraft() }"))
        assertTrue(source.contains("Latest progress not saved"))
        assertTrue(source.contains("Your work is still open in the app"))
    }

    private fun draft(): MapAlignmentDraft = MapAlignmentDraft(
        scope = MapAlignmentScope("install-a", "vineyard-a"),
        vineyardName = "Field test vineyard",
    )
}
