package com.rork.vinetrack.data.spray

/**
 * Operator-owned expansion state for the guided Spray Calculator.
 *
 * Validation decides whether a section is unlocked, but never changes which
 * section is visible. The flow's active step is consulted only by [seed].
 */
data class SpraySectionNavigationState(
    val openedStep: SprayGuidedStep? = null,
    val hasSeededOpenedStep: Boolean = false,
) {
    /** Opens the initial required section once and ignores every later flow change. */
    fun seed(initialRequiredStep: SprayGuidedStep): SpraySectionNavigationState =
        if (hasSeededOpenedStep) {
            this
        } else {
            copy(openedStep = initialRequiredStep, hasSeededOpenedStep = true)
        }

    /**
     * Applies an operator tap. Locked sections are unchanged; tapping the open
     * section closes it, while any other unlocked section becomes visible.
     */
    fun toggle(
        step: SprayGuidedStep,
        isUnlocked: Boolean,
    ): SpraySectionNavigationState {
        if (!isUnlocked) return this
        return copy(openedStep = if (openedStep == step) null else step)
    }
}
