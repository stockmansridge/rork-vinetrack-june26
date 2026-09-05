package com.rork.vinetrack.data.spray

/**
 * The ordered decisions in the guided Spray Calculator.
 *
 * ```text
 * Application → Blocks → Target → Growth Stage → Equipment → Carrier → Products → Review
 * ```
 *
 * Shared verbatim with the Swift `SprayGuidedStep` so an operator moving between
 * platforms meets the same decisions in the same order.
 */
enum class SprayGuidedStep(val raw: String, val title: String) {
    APPLICATION("application", "Application"),
    BLOCKS("blocks", "Blocks"),
    TARGET("target", "Target"),
    GROWTH_STAGE("growth_stage", "Growth Stage"),
    EQUIPMENT("equipment", "Equipment"),
    CARRIER("carrier", "Carrier Volume"),
    PRODUCTS("products", "Products"),
    REVIEW("review", "Review"),
    ;

    /** Position in the sequence, used for the gating comparisons. */
    val order: Int get() = ordinal
}

/**
 * Why a step cannot be completed yet. Each case names the ONE thing to fix, so
 * the UI never has to invent guidance.
 */
sealed interface SprayGuidedBlocker {
    val title: String
    val message: String

    /** True when the operator has to leave the calculator and fix block setup. */
    val needsBlockEditor: Boolean get() = false

    data object NoBlocksSelected : SprayGuidedBlocker {
        override val title: String get() = "Select blocks"
        override val message: String get() = "Select at least one block to calculate this spray."
    }

    /** Canonical geometry is incomplete for a calculation that needs row metres. */
    data class BlockSetupRequired(
        override val message: String,
        val blockIds: List<String>,
    ) : SprayGuidedBlocker {
        override val title: String get() = "Block setup required"
        override val needsBlockEditor: Boolean get() = true
    }

    data object NoTargetSelected : SprayGuidedBlocker {
        override val title: String get() = "Choose a target"
        override val message: String get() = "Select what this spray is targeting."
    }

    data object SprayHeadTargetRequired : SprayGuidedBlocker {
        override val title: String get() = "Choose a spray head target"
        override val message: String get() = "Choose where the spray head is aimed."
    }

    data object BandWidthRequired : SprayGuidedBlocker {
        override val title: String get() = "Enter treated band width"
        override val message: String
            get() = "Enter the total treated band width per row, in metres."
    }

    /** Band width was entered but the geometry still cannot yield treated area. */
    data object TreatedAreaUnavailable : SprayGuidedBlocker {
        override val title: String get() = "Treated area unavailable"
        override val message: String
            get() = "Row spacing or vineyard row geometry is incomplete for this calculation."
        override val needsBlockEditor: Boolean get() = true
    }

    data object GrowthStageRequired : SprayGuidedBlocker {
        override val title: String get() = "Set growth stage"
        override val message: String get() = "Set the growth stage for the selected blocks."
    }

    data object EquipmentRequired : SprayGuidedBlocker {
        override val title: String get() = "Select spray unit"
        override val message: String get() = "Select the spray unit used for this application."
    }

    data object EquipmentConfirmationRequired : SprayGuidedBlocker {
        override val title: String get() = "Confirm equipment"
        override val message: String get() = "Review the equipment and path, then tap Confirm equipment and path."
    }

    data object CarrierRateRequired : SprayGuidedBlocker {
        override val title: String get() = "Enter carrier volume"
        override val message: String get() = "Enter the carrier volume for this application."
    }

    data object CarrierNotCalculable : SprayGuidedBlocker {
        override val title: String get() = "Carrier volume unavailable"
        override val message: String
            get() = "Row spacing or vineyard row geometry is incomplete for this calculation."
        override val needsBlockEditor: Boolean get() = true
    }

    data object NoProductsAdded : SprayGuidedBlocker {
        override val title: String get() = "Add products"
        override val message: String get() = "Add at least one product to the tank mix."
    }

    /** Product lines whose basis input is unavailable. */
    data class UnresolvedProducts(val names: List<String>) : SprayGuidedBlocker {
        override val title: String get() = "Product rate unavailable"
        override val message: String
            get() = "Cannot calculate ${names.joinToString(", ")}. " +
                "Check the rate basis and block geometry."
    }

    /**
     * A product is rated per TREATED hectare but the band geometry cannot yield a
     * treated area. Named separately from [UnresolvedProducts] because the fix is
     * specific: complete the band width or the block's row geometry.
     */
    data class TreatedAreaBasisUnavailable(val names: List<String>) : SprayGuidedBlocker {
        override val title: String get() = "Treated area required"
        override val message: String
            get() = "Complete the band width and block geometry before using a " +
                "Treated Area product rate for ${names.joinToString(", ")}."
        override val needsBlockEditor: Boolean get() = true
    }

    /**
     * A banded pass has area-rated products whose area scope nobody has
     * confirmed. The operator must say whether the label rate applies to the
     * whole block or only the treated band.
     */
    data class ProductAreaBasisRequired(val names: List<String>) : SprayGuidedBlocker {
        override val title: String get() = "Choose an area basis"
        override val message: String
            get() = "This is a banded application. Choose whether " +
                "${names.joinToString(", ")} applies to the whole block area or " +
                "only the treated band area."
    }
}

/**
 * Everything the operator has entered. Plain data, no derived values — every
 * calculated figure comes back out through [SprayGuidedFlow.plan].
 */
data class SprayGuidedInputs(
    val sprayName: String = "",
    val operationType: SprayOperationType = SprayOperationType.FOLIAR_SPRAY,
    /** Canonical geometry inputs for the selected blocks. */
    val blocks: List<SprayBlockInput> = emptyList(),
    val targets: Set<SprayTarget> = emptySet(),
    /**
     * Targets this vineyard named that the calculator has no typed case for,
     * as stable identifiers (sql/193). They ride from a Program Step's
     * prefill into the saved record's snapshot so the spray still states what
     * it is for — nothing coerces them onto a built-in target, because
     * recording a Phomopsis spray as "Botrytis" would be a false compliance
     * claim. Mirrors iOS `customSprayTargets`.
     */
    val customTargets: List<String> = emptyList(),
    val sprayHeadTarget: SprayHeadTarget? = null,
    /** Total treated band width per row, metres. Banded applications only. */
    val bandWidthTotalMetres: Double? = null,
    val isGrowthStageAssigned: Boolean = false,
    val isEquipmentSelected: Boolean = false,
    /** Explicit operator sign-off; prefilled or merely selected equipment is not confirmation. */
    val isEquipmentConfirmed: Boolean = false,
    val tankCapacityLitres: Double = 0.0,
    val carrierBasis: SprayCarrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
    /** L/ha mode: the rate the operator entered. */
    val litresPerHectare: Double? = null,
    /**
     * L/ha mode: the dilute/runoff reference used for concentration, when the
     * existing canopy water-rate table supplies one.
     */
    val diluteLitresPerHectare: Double? = null,
    /** L/100 m mode: dilute/runoff reference rate. */
    val diluteLitresPer100Metres: Double? = null,
    /** L/100 m mode: the actual applied rate. */
    val appliedLitresPer100Metres: Double? = null,
    val products: List<SprayProductLineInput> = emptyList(),
    val notes: String = "",
)

/**
 * The guided Spray Calculator's derived state.
 *
 * ## Single calculation authority
 *
 * This type is the ONLY bridge between operator input and
 * [SprayApplicationPlanner.plan]. The screen reads [plan] and formats it. The
 * screen never computes row length, treated area, concentration factor, total
 * carrier, derived L/ha or product totals — if a number is displayed, it came out
 * of the plan.
 *
 * A plan is built on EVERY evaluation, even before the carrier step is valid,
 * using a zero-litre placeholder carrier. That is what lets step 3 preview gross
 * and treated hectares the instant a band width is typed without opening a second
 * arithmetic path: treated area does not depend on carrier volume, so the
 * placeholder cannot change it. Per-100 L product lines correctly report
 * `isUnresolved` until a real carrier exists.
 *
 * ## Progressive disclosure
 *
 * [unlockedSteps] / [activeStep] are derived, not stored, so the UI cannot drift
 * from the validation rules. A step unlocks only when every step before it is
 * complete.
 */
data class SprayGuidedFlow(
    val inputs: SprayGuidedInputs,
    val profile: SprayVineyardProfile = SprayVineyardProfile(),
) {

    // region Application mode

    /**
     * Maps the operator-facing operation type onto the engine's mode.
     *
     * Spreader is a whole-block application: it has no band geometry and no canopy
     * target, so it resolves treated area exactly like a foliar pass.
     */
    val mode: SprayApplicationMode
        get() = when (inputs.operationType) {
            SprayOperationType.BANDED_SPRAY -> SprayApplicationMode.BANDED
            SprayOperationType.FOLIAR_SPRAY, SprayOperationType.SPREADER ->
                SprayApplicationMode.WHOLE_BLOCK
        }

    /** True when this application needs a spray head target (foliar only). */
    val requiresSprayHeadTarget: Boolean
        get() = inputs.operationType == SprayOperationType.FOLIAR_SPRAY

    /** True when this application needs a treated band width (banded only). */
    val requiresBandWidth: Boolean
        get() = inputs.operationType == SprayOperationType.BANDED_SPRAY

    /** True when canopy-specific settings apply. Spreader has no canopy. */
    val supportsCanopySettings: Boolean
        get() = inputs.operationType != SprayOperationType.SPREADER

    // endregion

    // region Application intent

    /**
     * The spray head target that actually applies, which is null for anything
     * that is not a foliar pass.
     *
     * This is where "changing Foliar -> Banded clears the spray head target" is
     * enforced. Doing it here rather than only in the screens means a stale value
     * can never reach the snapshot even if a UI forgets to reset its own state -
     * the persisted record cannot claim a banded pass was aimed at the bunch
     * line. The same rule already governs [bandWidth] in the other direction.
     */
    val effectiveSprayHeadTarget: SprayHeadTarget?
        get() = if (requiresSprayHeadTarget) inputs.sprayHeadTarget else null

    /** The operator's targets in stable presentation order, de-duplicated. */
    val orderedTargets: List<SprayTarget>
        get() = SprayTarget.presentationOrder.filter(inputs.targets::contains)

    // endregion

    // region Carrier policy

    /** Which carrier bases this vineyard may enter. */
    val carrierPolicy: SprayCarrierVolumePolicy get() = profile.resolvedPolicy

    /**
     * True when the vineyard profile leaves no choice, so the UI must not offer
     * one. An NZ/SWNZ vineyard is locked to L/100 m.
     */
    val isCarrierBasisLocked: Boolean get() = profile.isCarrierBasisLocked

    /**
     * The basis actually in force: the operator's choice when the profile allows
     * either, otherwise whatever the profile mandates.
     */
    val effectiveCarrierBasis: SprayCarrierBasis
        get() = if (carrierPolicy.allows(inputs.carrierBasis)) {
            inputs.carrierBasis
        } else {
            carrierPolicy.defaultBasis
        }

    // endregion

    // region Geometry

    /**
     * Canonical geometry for the current selection. The single source of truth for
     * row length and row spacing in this screen.
     */
    val geometry: SprayApplicationGeometry
        get() = SprayGeometryResolver.resolve(inputs.blocks)

    /**
     * True when the chosen workflow genuinely needs canonical row metres.
     *
     * A banded application needs them for treated area; an L/100 m carrier needs
     * them for total litres. A whole-block L/ha spray does not, so a block with
     * area but no row spacing must NOT be blocked out of that path.
     */
    val requiresCanonicalRowLength: Boolean
        get() = mode == SprayApplicationMode.BANDED ||
            effectiveCarrierBasis == SprayCarrierBasis.LITRES_PER_100_METRES

    // endregion

    // region Carrier volume

    /**
     * The resolved carrier volume, or null when it is not calculable yet.
     *
     * Built only by [SprayCarrierVolumeCalculator]; the flow never does the
     * arithmetic itself.
     */
    val carrier: SprayCarrierVolume?
        get() = when (effectiveCarrierBasis) {
            SprayCarrierBasis.LITRES_PER_HECTARE -> {
                val rate = positive(inputs.litresPerHectare)
                if (rate == null) {
                    null
                } else {
                    // Concentration keeps its established VineTrack meaning
                    // (dilute ÷ chosen) and floors at 1.0 so concentrating never
                    // reduces a per-100 L product dose.
                    val dilute = positive(inputs.diluteLitresPerHectare)
                    val factor = if (dilute == null) 1.0 else maxOf(1.0, dilute / rate)
                    SprayCarrierVolumeCalculator.perHectare(
                        litresPerHectare = rate,
                        areaHectares = geometry.grossAreaHectares,
                        concentrationFactor = factor,
                        rowLengthMetres = geometry.totalRowLengthMetres,
                        rowSpacingMetres = geometry.uniformRowSpacingMetres,
                    )
                }
            }

            SprayCarrierBasis.LITRES_PER_100_METRES -> {
                val applied = positive(inputs.appliedLitresPer100Metres)
                if (applied == null) {
                    null
                } else {
                    SprayCarrierVolumeCalculator.per100Metres(
                        appliedLitresPer100Metres = applied,
                        diluteLitresPer100Metres = positive(inputs.diluteLitresPer100Metres),
                        geometry = geometry,
                    )
                }
            }
        }

    /**
     * A zero-litre stand-in so a plan can always be produced for preview.
     *
     * Deliberately zero rather than a guess: a per-100 L product measured against
     * it resolves to null (unresolved) instead of a fabricated dose.
     */
    private val placeholderCarrier: SprayCarrierVolume
        get() = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare = 0.0,
            areaHectares = geometry.grossAreaHectares,
            rowLengthMetres = geometry.totalRowLengthMetres,
            rowSpacingMetres = geometry.uniformRowSpacingMetres,
        )

    /** True when the carrier volume is fully resolved and usable. */
    val isCarrierResolved: Boolean get() = (carrier?.totalLitres ?: 0.0) > 0.0

    // endregion

    // region Band width

    /** The band width to feed the engine, only when it is genuinely valid. */
    val bandWidth: SprayBandWidth?
        get() {
            if (!requiresBandWidth) return null
            val total = positive(inputs.bandWidthTotalMetres) ?: return null
            return SprayBandWidth.total(total)
        }

    // endregion

    // region THE plan

    /**
     * THE canonical calculation for the current inputs.
     *
     * Always non-null so the UI has one thing to read at every stage. Before the
     * carrier step is valid it is built on the zero-litre placeholder, which
     * affects only carrier-dependent figures.
     */
    val plan: SprayApplicationPlan
        get() = SprayApplicationPlanner.plan(
            blocks = inputs.blocks,
            mode = mode,
            bandWidth = bandWidth,
            carrier = carrier ?: placeholderCarrier,
            tankCapacityLitres = inputs.tankCapacityLitres,
            productLines = inputs.products,
        )

    /**
     * The plan to PERSIST — only once the flow is genuinely complete, so a
     * half-entered spray can never be frozen into a compliance record.
     */
    val persistablePlan: SprayApplicationPlan? get() = if (isComplete) plan else null

    /**
     * The snapshot to hand to the persistence layer.
     *
     * Built exclusively by projecting the plan, so the 17 sql/191 + sql/192
     * columns are never populated from individual UI state variables.
     */
    val snapshot: SprayApplicationSnapshot?
        get() {
            val plan = persistablePlan ?: return null
            val snapshot = SprayApplicationSnapshot.from(
                plan = plan,
                targets = orderedTargets,
                sprayHeadTarget = effectiveSprayHeadTarget,
                customTargets = inputs.customTargets.takeIf { it.isNotEmpty() },
            )
            return if (snapshot.isEmpty) null else snapshot
        }

    // endregion

    // region Per-step validation

    /** The blocker for a given step, or null when that step is satisfied. */
    fun blocker(step: SprayGuidedStep): SprayGuidedBlocker? = when (step) {
        // An operation type is always selected.
        SprayGuidedStep.APPLICATION -> null

        SprayGuidedStep.BLOCKS -> when {
            inputs.blocks.isEmpty() -> SprayGuidedBlocker.NoBlocksSelected
            requiresCanonicalRowLength && !geometry.isUsable ->
                SprayGuidedBlocker.BlockSetupRequired(
                    message = geometry.unavailableMessage
                        ?: SprayGeometryUnavailable.MISSING_GEOMETRY.message,
                    blockIds = geometry.unresolvedBlocks.map { it.blockId },
                )
            else -> null
        }

        SprayGuidedStep.TARGET -> when {
            inputs.targets.isEmpty() -> SprayGuidedBlocker.NoTargetSelected
            requiresSprayHeadTarget && inputs.sprayHeadTarget == null ->
                SprayGuidedBlocker.SprayHeadTargetRequired
            requiresBandWidth && bandWidth == null -> SprayGuidedBlocker.BandWidthRequired
            // Band width is valid but geometry still cannot produce a treated
            // area — say so instead of showing gross as treated.
            requiresBandWidth && plan.treatedAreaHectares == null ->
                SprayGuidedBlocker.TreatedAreaUnavailable
            else -> null
        }

        SprayGuidedStep.GROWTH_STAGE ->
            if (inputs.isGrowthStageAssigned) null else SprayGuidedBlocker.GrowthStageRequired

        SprayGuidedStep.EQUIPMENT -> when {
            !inputs.isEquipmentSelected -> SprayGuidedBlocker.EquipmentRequired
            !inputs.isEquipmentConfirmed -> SprayGuidedBlocker.EquipmentConfirmationRequired
            else -> null
        }

        SprayGuidedStep.CARRIER -> {
            val entered = when (effectiveCarrierBasis) {
                SprayCarrierBasis.LITRES_PER_HECTARE -> positive(inputs.litresPerHectare)
                SprayCarrierBasis.LITRES_PER_100_METRES ->
                    positive(inputs.appliedLitresPer100Metres)
            }
            when {
                entered == null -> SprayGuidedBlocker.CarrierRateRequired
                !isCarrierResolved -> SprayGuidedBlocker.CarrierNotCalculable
                else -> null
            }
        }

        SprayGuidedStep.PRODUCTS -> when {
            inputs.products.isEmpty() -> SprayGuidedBlocker.NoProductsAdded
            else -> {
                // A product rated per TREATED hectare against geometry that cannot
                // produce one is called out specifically, so the operator is never
                // left guessing which of several possible inputs is missing - and
                // is never quietly dosed against gross area instead.
                val treatedAreaLines = inputs.products.filter {
                    it.basis == SprayProductRateBasis.TREATED_AREA
                }
                // A banded pass multiplies an area rate by either gross or
                // treated hectares - several times apart. Refusing to proceed
                // until the operator says which is deliberate: silently
                // defaulting would freeze an unconfirmed guess into a compliance
                // record. Whole-block passes are never ambiguous, so they are
                // never asked.
                val undecided = if (mode == SprayApplicationMode.BANDED) {
                    inputs.products.filter { it.needsAreaBasisDecision }
                } else {
                    emptyList()
                }
                val unresolved = plan.unresolvedProductLines
                when {
                    undecided.isNotEmpty() ->
                        SprayGuidedBlocker.ProductAreaBasisRequired(undecided.map { it.name })
                    treatedAreaLines.isNotEmpty() && plan.treatedAreaHectares == null ->
                        SprayGuidedBlocker.TreatedAreaBasisUnavailable(
                            treatedAreaLines.map { it.name },
                        )
                    unresolved.isEmpty() -> null
                    else -> SprayGuidedBlocker.UnresolvedProducts(unresolved.map { it.name })
                }
            }
        }

        SprayGuidedStep.REVIEW -> null
    }

    fun isComplete(step: SprayGuidedStep): Boolean = blocker(step) == null

    // endregion

    // region Progressive disclosure

    /**
     * True when every step before [step] is complete, so [step] may be shown.
     *
     * [SprayGuidedStep.APPLICATION] is always unlocked; nothing else is reachable
     * until the decisions it depends on have actually been made.
     */
    fun isUnlocked(step: SprayGuidedStep): Boolean =
        SprayGuidedStep.entries.filter { it.order < step.order }.all { isComplete(it) }

    val unlockedSteps: List<SprayGuidedStep>
        get() = SprayGuidedStep.entries.filter { isUnlocked(it) }

    /**
     * The first step still needing attention. The screen consults this once to
     * seed its initial section; later validation changes never control expansion.
     */
    val activeStep: SprayGuidedStep
        get() = SprayGuidedStep.entries.firstOrNull { !isComplete(it) } ?: SprayGuidedStep.REVIEW

    /** Steps that are complete AND behind the active step, so they may collapse. */
    fun isCollapsible(step: SprayGuidedStep): Boolean =
        step.order < activeStep.order && isComplete(step)

    /** Everything up to (but not including) Review is satisfied. */
    val isComplete: Boolean
        get() = SprayGuidedStep.entries
            .filter { it.order < SprayGuidedStep.REVIEW.order }
            .all { isComplete(it) }

    /** The first blocker across the whole flow, for the primary action's hint. */
    val firstBlocker: SprayGuidedBlocker?
        get() = SprayGuidedStep.entries.firstNotNullOfOrNull { blocker(it) }

    val progressFraction: Double
        get() {
            val gated = SprayGuidedStep.entries
                .filter { it.order < SprayGuidedStep.REVIEW.order }
            if (gated.isEmpty()) return 1.0
            return gated.count { isComplete(it) }.toDouble() / gated.size.toDouble()
        }

    // endregion

    /**
     * Whether the future Resistance Check panel has a reason to appear.
     *
     * Reserved location only — this task ships NO rules engine and NO warnings.
     * The flag exists so the panel's insertion point beneath the relevant
     * chemistry is already decided and both platforms agree on when it applies.
     */
    val isResistanceCheckApplicable: Boolean
        get() = inputs.targets.any { it.isFungicideResistanceRelevant }

    private fun positive(value: Double?): Double? =
        if (value != null && value.isFinite() && value > 0.0) value else null
}
