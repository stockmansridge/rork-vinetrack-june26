package com.rork.vinetrack.data.spray

/**
 * One explicit growth-stage decision for the guided Spray Calculator.
 *
 * Resolution and value are independent: [NotSet] is complete while carrying no
 * E-L stage, whereas [Unresolved] is incomplete and also carries no stage.
 */
sealed interface SprayGrowthStageDecision {
    val isResolved: Boolean
    val stageCode: String?

    data object Unresolved : SprayGrowthStageDecision {
        override val isResolved: Boolean = false
        override val stageCode: String? = null
    }

    data object NotSet : SprayGrowthStageDecision {
        override val isResolved: Boolean = true
        override val stageCode: String? = null
    }

    data class Stage(override val stageCode: String) : SprayGrowthStageDecision {
        override val isResolved: Boolean = true
    }
}
