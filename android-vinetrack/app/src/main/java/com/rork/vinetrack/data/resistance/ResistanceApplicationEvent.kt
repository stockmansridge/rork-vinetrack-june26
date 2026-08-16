package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability

/**
 * Whether an event actually happened, is planned, or is being hypothesised.
 *
 * The engine must be able to answer "what if I spray this next?" for a plan that
 * has never been saved, so completion can never be a precondition for
 * evaluation. Equally, a merely planned spray must not silently inflate a
 * seasonal count as though it had been applied.
 */
enum class ResistanceEventKind(val raw: String) {
    /** A genuine, completed application. Counts as history. */
    ACTUAL("actual"),

    /**
     * A future spray the operator has scheduled. Recognised by the model now so
     * the Planner does not require an engine change, but excluded from v1
     * counting unless explicitly requested.
     */
    PLANNED("planned"),

    /** The spray being assessed right now. Never persisted. */
    CANDIDATE("candidate"),
    ;

    val isHistory: Boolean get() = this == ACTUAL
}

/**
 * One product line within an application, reduced to what resistance analysis
 * needs.
 *
 * Groups arrive here from the FROZEN [com.rork.vinetrack.data.chemical.ChemicalLineSnapshot]
 * on the spray record — never from today's Chemical Store record. Re-reading the
 * live product would let a classification corrected in 2029 rewrite what the 2026
 * rotation is said to have been, and every rotation decision derived from it.
 */
data class ResistanceProductLine(
    val lineId: String,
    val productName: String?,
    val savedChemicalId: String?,
    /** Groups carried by THIS product. Two codes here means a co-formulation. */
    val groups: ResistanceGroupSignature,
    val availability: ChemicalIntelligenceAvailability,
) {
    val hasGroups: Boolean get() = groups.codes.isNotEmpty()
}

/**
 * The canonical unit of resistance history: ONE spray application, for ONE block.
 *
 * Deliberately not a database model. The engine consumes these and nothing else,
 * which is what lets the identical rule logic serve saved history, an unsaved
 * Guided Spray plan, and a test fixture.
 *
 * Mirrors iOS `ResistanceApplicationEvent.swift`.
 */
data class ResistanceApplicationEvent(
    /** Spray record ID, or a temporary ID for an unsaved candidate. */
    val applicationId: String,
    val kind: ResistanceEventKind,
    val appliedAtEpochMs: Long,
    val seasonId: String,
    val vineyardId: String,
    /**
     * The block this event applies to.
     *
     * One spray covering three blocks becomes three events — resistance history
     * belongs to the vines that received the chemistry, and block 1 having had
     * two Group 11 sprays says nothing about block 3.
     */
    val blockId: String,
    /**
     * The diseases the operator declared this spray was FOR, from the persisted
     * `spray_records.targets`.
     *
     * Never inferred from the chemistry: a Group 11 product applied purely for
     * downy mildew must not silently consume the block's powdery mildew Group 11
     * allowance.
     */
    val targets: List<ResistanceDisease>,
    /**
     * Whether targets were recorded at all.
     *
     * False for pre-sql/193 history. Critically different from an empty target
     * list: "recorded as targeting nothing" is a fact, whereas "never asked" is
     * an unknown that must suppress a clean result rather than quietly removing
     * the application from every disease history.
     */
    val targetsRecorded: Boolean,
    val products: List<ResistanceProductLine>,
    /**
     * Whether a partner from an alternative mode of action was present AT A
     * REGISTERED/EFFECTIVE RATE, when that is genuinely known.
     *
     * Null — the default — means unknown, which is the honest answer from group
     * data alone. Group codes cannot establish that a tank partner was loaded at
     * a rate that actually controls the disease, and a mixture requirement is
     * about efficacy, not about the presence of a second code.
     */
    val mixturePartnerAtLabelRate: Boolean? = null,
) {
    /** Every group present, however it arrived (solo, co-formulated, tank-mixed). */
    val componentGroups: Set<String>
        get() = products.flatMap { it.groups.codes }.toSet()

    /** Signatures of products carrying more than one group — true co-formulations. */
    val coformulationSignatures: List<ResistanceGroupSignature>
        get() = products.map { it.groups }.filter { it.isCoformulation }

    /**
     * How far this event's chemistry can be trusted: the WEAKEST of its product
     * lines, plus [ChemicalIntelligenceAvailability.UNAVAILABLE] when no product
     * carried usable groups at all.
     *
     * Weakest-wins because one unverifiable product in the tank is enough to make
     * the application's group set uncertain.
     */
    val availability: ChemicalIntelligenceAvailability
        get() {
            if (products.isEmpty() || products.none { it.hasGroups }) {
                return ChemicalIntelligenceAvailability.UNAVAILABLE
            }
            val order = listOf(
                ChemicalIntelligenceAvailability.UNAVAILABLE,
                ChemicalIntelligenceAvailability.CONFLICT,
                ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED,
                ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED,
                ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
            )
            return products.minByOrNull { order.indexOf(it.availability) }?.availability
                ?: ChemicalIntelligenceAvailability.UNAVAILABLE
        }

    /** Whether this event's chemistry can be reasoned about at all. */
    val canAssessChemistry: Boolean get() = availability.canAssess

    fun targets(disease: ResistanceDisease): Boolean = targets.contains(disease)

    /**
     * Groups present that are NOT among [groups] — candidate mixture partners
     * from a different cross-resistance group.
     */
    fun groupsOtherThan(groups: Collection<String>): Set<String> =
        componentGroups.filterNot { groups.contains(it) }.toSet()

    companion object {
        /**
         * Chronological ordering: by instant, then by application ID.
         *
         * The ID tie-breaker is what makes results reproducible. Two sprays on
         * the same date are still two distinct applications (a morning and an
         * afternoon job are not one spray), and database row order is not a
         * chronology — it changes with sync.
         */
        val chronological: Comparator<ResistanceApplicationEvent> =
            compareBy({ it.appliedAtEpochMs }, { it.applicationId })
    }
}
