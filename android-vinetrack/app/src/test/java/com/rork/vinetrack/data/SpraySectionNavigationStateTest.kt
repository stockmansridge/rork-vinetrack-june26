package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SpraySectionNavigationState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpraySectionNavigationStateTest {

    @Test
    fun `initial required step is seeded once`() {
        val seeded = SpraySectionNavigationState().seed(SprayGuidedStep.TARGET)
        val afterFlowAdvances = seeded.seed(SprayGuidedStep.GROWTH_STAGE)

        assertEquals(SprayGuidedStep.TARGET, afterFlowAdvances.openedStep)
        assertTrue(afterFlowAdvances.hasSeededOpenedStep)
    }

    @Test
    fun `selecting a target does not change opened section`() {
        val state = seededAt(SprayGuidedStep.TARGET)

        assertEquals(SprayGuidedStep.TARGET, state.seed(SprayGuidedStep.GROWTH_STAGE).openedStep)
    }

    @Test
    fun `completing growth stage does not automatically open equipment`() {
        val state = seededAt(SprayGuidedStep.GROWTH_STAGE)

        assertEquals(SprayGuidedStep.GROWTH_STAGE, state.seed(SprayGuidedStep.EQUIPMENT).openedStep)
    }

    @Test
    fun `selecting equipment does not automatically open carrier`() {
        val state = seededAt(SprayGuidedStep.EQUIPMENT)

        assertEquals(SprayGuidedStep.EQUIPMENT, state.seed(SprayGuidedStep.CARRIER).openedStep)
    }

    @Test
    fun `fully prefilled program step does not automatically open review`() {
        val beforePrefill = seededAt(SprayGuidedStep.BLOCKS)

        assertEquals(SprayGuidedStep.BLOCKS, beforePrefill.seed(SprayGuidedStep.REVIEW).openedStep)
    }

    @Test
    fun `closing a section leaves all sections closed`() {
        val closed = seededAt(SprayGuidedStep.TARGET).toggle(
            step = SprayGuidedStep.TARGET,
            isUnlocked = true,
        )

        assertNull(closed.openedStep)
        assertNull(closed.seed(SprayGuidedStep.REVIEW).openedStep)
    }

    @Test
    fun `unlocked section opens only when tapped`() {
        val state = seededAt(SprayGuidedStep.TARGET)
        val flowChanged = state.seed(SprayGuidedStep.GROWTH_STAGE)
        val tapped = flowChanged.toggle(SprayGuidedStep.GROWTH_STAGE, isUnlocked = true)

        assertEquals(SprayGuidedStep.TARGET, flowChanged.openedStep)
        assertEquals(SprayGuidedStep.GROWTH_STAGE, tapped.openedStep)
    }

    @Test
    fun `completed section can be reopened`() {
        val state = seededAt(SprayGuidedStep.PRODUCTS)
        val reopened = state.toggle(SprayGuidedStep.TARGET, isUnlocked = true)

        assertEquals(SprayGuidedStep.TARGET, reopened.openedStep)
    }

    @Test
    fun `locked section cannot be opened`() {
        val state = seededAt(SprayGuidedStep.TARGET)
        val unchanged = state.toggle(SprayGuidedStep.REVIEW, isUnlocked = false)

        assertEquals(state, unchanged)
    }

    @Test
    fun `recomposition does not reset operator selected section`() {
        val selected = seededAt(SprayGuidedStep.TARGET)
            .toggle(SprayGuidedStep.GROWTH_STAGE, isUnlocked = true)
        val recomposed = SpraySectionNavigationState(
            openedStep = selected.openedStep,
            hasSeededOpenedStep = selected.hasSeededOpenedStep,
        ).seed(SprayGuidedStep.REVIEW)

        assertEquals(SprayGuidedStep.GROWTH_STAGE, recomposed.openedStep)
        assertTrue(recomposed.hasSeededOpenedStep)
    }

    @Test
    fun `saved closed state stays closed after configuration recreation`() {
        val closed = seededAt(SprayGuidedStep.TARGET)
            .toggle(SprayGuidedStep.TARGET, isUnlocked = true)
        val restored = SpraySectionNavigationState(
            openedStep = closed.openedStep,
            hasSeededOpenedStep = closed.hasSeededOpenedStep,
        ).seed(SprayGuidedStep.REVIEW)

        assertNull(restored.openedStep)
        assertTrue(restored.hasSeededOpenedStep)
    }

    private fun seededAt(step: SprayGuidedStep): SpraySectionNavigationState =
        SpraySectionNavigationState().seed(step)
}
