package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability

/**
 * The status of one planned position, derived entirely from engine output.
 *
 * There is deliberately no numeric score. "Reaches strategy limit" and "would exceed
 * strategy" are different decisions for an operator standing at a shed door, and a
 * shared number like "risk 73" would collapse them into something nobody can act on or
 * argue with.
 */
enum class ResistancePlanPositionStatus(val raw: String, val label: String) {
    /** Permitted, with headroom left, from dependable evidence. */
    GOOD_FIT("good_fit", "Good fit"),

    /** Permitted, but lands exactly on a published maximum. */
    REACHES_STRATEGY_LIMIT("reaches_strategy_limit", "Reaches strategy limit"),

    /** Goes past a published maximum. */
    WOULD_EXCEED_STRATEGY("would_exceed_strategy", "Would exceed strategy"),

    /**
     * Permitted arithmetically, but something needs an operator's eye: an unconfirmable
     * mixture, an unverified product, published guidance.
     */
    NEEDS_REVIEW("needs_review", "Needs review"),

    /**
     * The engine cannot reach a conclusion, because the history it would have to count
     * is incomplete or disputed.
     */
    UNABLE_TO_FULLY_ASSESS("unable_to_fully_assess", "Unable to fully assess"),
    ;

    /**
     * Worst-first ranking for multi-block aggregation.
     *
     * [UNABLE_TO_FULLY_ASSESS] outranks [REACHES_STRATEGY_LIMIT] on purpose. "Reaches
     * the limit" reads as a definite, understood position; "unable to assess" means the
     * true answer might be worse than anything shown. Presenting the softer of the two
     * would hide the uncertainty behind a number that looks settled.
     */
    val rank: Int
        get() = when (this) {
            WOULD_EXCEED_STRATEGY -> 5
            UNABLE_TO_FULLY_ASSESS -> 4
            REACHES_STRATEGY_LIMIT -> 3
            NEEDS_REVIEW -> 2
            GOOD_FIT -> 1
        }

    companion object {
        fun worst(statuses: List<ResistancePlanPositionStatus>): ResistancePlanPositionStatus =
            statuses.maxByOrNull { it.rank } ?: NEEDS_REVIEW
    }
}

/** A specific, nameable gap in a block's recorded history. */
enum class ResistanceHistoryConcern(val raw: String, val label: String) {
    UNVERIFIED_CHEMISTRY("unverified_chemistry", "Contains unverified chemistry"),
    UNAVAILABLE_CHEMISTRY("unavailable_chemistry", "Contains unavailable chemistry"),
    CONFLICTING_CHEMISTRY("conflicting_chemistry", "Contains conflicting chemistry"),
    UNRESOLVED_BLOCK_ATTRIBUTION(
        "unresolved_block_attribution",
        "Historical block attribution incomplete",
    ),
    UNKNOWN_TARGETS("unknown_targets", "Contains sprays with unknown disease targets"),
}

/** Whether a block's season history can carry a confident assessment, and if not, why. */
data class ResistanceBlockHistoryCheck(
    val blockId: String,
    /** Completed applications for this block, this season, targeting the planned disease. */
    val relevantApplicationCount: Int,
    val concerns: List<ResistanceHistoryConcern>,
    val unverifiedCount: Int,
    val unavailableCount: Int,
    val conflictingCount: Int,
    val unknownTargetCount: Int,
    /**
     * Vineyard-wide applications that could concern this disease but cannot be placed on
     * any block.
     *
     * The SAME count appears on every selected block, and that is not a bug. An
     * unattributed spray happened somewhere in this vineyard; nothing establishes which
     * block, so it is a live possibility for all of them. Attaching it to one block
     * would invent the very attribution the record is missing.
     */
    val unresolvedVineyardApplicationCount: Int,
) {
    val isCompleteEnoughToAssess: Boolean get() = concerns.isEmpty()

    val hasSeasonHistory: Boolean get() = relevantApplicationCount > 0

    fun headline(disease: ResistanceDisease): String = when {
        concerns.isNotEmpty() -> concerns[0].label
        relevantApplicationCount == 0 -> "No recorded ${disease.label} sprays this season"
        else -> "Current-season history available"
    }
}

/** One completed application on a block's season timeline. */
data class ResistancePlanTimelineEntry(
    val applicationId: String,
    val appliedAtEpochMs: Long,
    /** FRAC identity — the primary resistance concept. Product names are secondary. */
    val groupsLabel: String,
    val productNames: List<String>,
    val availability: ChemicalIntelligenceAvailability,
    val targetsRecorded: Boolean,
)

/** A block's completed season history for the planned disease. */
data class ResistancePlanBlockTimeline(
    val blockId: String,
    val entries: List<ResistancePlanTimelineEntry>,
)

/**
 * Resistance-oriented season totals for one block.
 *
 * Counted from resistance application EVENTS — one application is one event per block,
 * so a three-product tank counts once. Counting tank lines would inflate every total and
 * make the percentage rules meaningless.
 */
data class ResistanceBlockSeasonTotals(
    val blockId: String,
    val diseaseSprayCount: Int,
    /** Group code -> number of applications containing it, this block, this season. */
    val applicationsByGroup: Map<String, Int>,
) {
    val orderedGroups: List<String>
        get() = applicationsByGroup.keys.sortedWith(ResistanceGroupCode.comparator)
}

/** One block's answer for one planned position. */
data class ResistancePlanBlockOutcome(
    val blockId: String,
    val status: ResistancePlanPositionStatus,
    /**
     * The full explainable engine result, carried through untouched so the UI can show
     * observed count, threshold, contributing dates and published source.
     */
    val evaluation: ResistanceEvaluation,
)

/** The evaluation of one planned position across every selected block. */
data class ResistancePlanPositionEvaluation(
    val positionId: String,
    /** Zero-based index in the plan. */
    val index: Int,
    /** Display ordinal continuing the season's completed sprays, e.g. `4`. */
    val displayOrdinal: Int,
    /** Worst state across all selected blocks. */
    val status: ResistancePlanPositionStatus,
    val blocks: List<ResistancePlanBlockOutcome>,
    /** Set when the position has no chemistry chosen yet. */
    val awaitingChemistry: Boolean,
) {
    /**
     * True when the blocks do not all agree — the case that must stay expandable rather
     * than being averaged away.
     */
    val blocksDisagree: Boolean get() = blocks.map { it.status }.distinct().size > 1

    val findings: List<ResistanceRuleResult> get() = blocks.flatMap { it.evaluation.findings }
}

/** A strategy-compatible group option for a position. */
data class ResistancePlanGroupOption(
    val listing: ResistanceGroupListing,
    val status: ResistancePlanPositionStatus,
    /**
     * True when this group shares nothing with the most recent application in the
     * effective sequence — the rotation the strategy actually asks for.
     */
    val differsFromRecentSequence: Boolean,
    val statusByBlock: Map<String, ResistancePlanPositionStatus>,
)

/**
 * A Chemical Store product offered for a chosen group.
 *
 * Supplied by the caller from the vineyard's own Chemical Store. The Planner never
 * invents a product, and never presents one as registered for the disease unless the
 * structured Chemical Intelligence says so.
 */
data class ResistancePlanChemicalCandidate(
    val savedChemicalId: String,
    val productName: String,
    val groups: ResistanceGroupSignature,
    val availability: ChemicalIntelligenceAvailability,
    /**
     * From structured registered-use evidence. Null = not known. NEVER derived from
     * group membership.
     */
    val registeredForDisease: Boolean? = null,
    /** Vineyard/product country, for jurisdiction filtering. Null = unknown. */
    val countryCode: String? = null,
)

/** A Chemical Store product matched to a planned group. */
data class ResistancePlanProductOption(
    val candidate: ResistancePlanChemicalCandidate,
    /**
     * True when the product's groups are exactly the planned signature. False means the
     * product also carries other groups, which the engine will evaluate as a different
     * (co-formulated) chemistry.
     */
    val isExactSignatureMatch: Boolean,
) {
    /**
     * Caveat that must remain visible while this product is planned, or null when the
     * product's chemistry is dependable.
     */
    val caveat: String?
        get() = when (candidate.availability) {
            ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED -> null
            ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED ->
                "Recorded as ${candidate.groups.displayLabel} — chemical information partially verified"
            ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED ->
                "Recorded as ${candidate.groups.displayLabel} — chemical information unverified"
            ChemicalIntelligenceAvailability.CONFLICT ->
                "Sources disagree about this product's chemistry, so its ${candidate.groups.displayLabel} identity cannot be relied on"
            ChemicalIntelligenceAvailability.UNAVAILABLE ->
                "No usable chemistry is recorded for this product"
        }

    /**
     * Registered-use wording. Absence of evidence is stated as such — never as a
     * registration claim, and never inferred from the FRAC group.
     */
    val registeredUseNote: String
        get() = when (candidate.registeredForDisease) {
            true -> "Registered use recorded for this disease"
            false -> "No registered use recorded for this disease"
            null -> "Registered use for this disease not known"
        }
}

/** The full Planner output for one plan. */
data class ResistancePlanEvaluation(
    /** False when no VineTrack strategy exists for the vineyard's jurisdiction. */
    val isSupported: Boolean,
    val unsupportedMessage: String?,
    val strategyName: String?,
    val sourceOrganisation: String?,
    val rulesetId: String?,
    val rulesetVersion: String?,
    val rulesetValidFrom: String?,
    val historyChecks: List<ResistanceBlockHistoryCheck>,
    val timelines: List<ResistancePlanBlockTimeline>,
    val positions: List<ResistancePlanPositionEvaluation>,
    val seasonTotals: List<ResistanceBlockSeasonTotals>,
    /**
     * Vineyard-wide applications that could concern this disease but cannot be placed on
     * a block.
     */
    val unresolvedApplicationCount: Int,
    /** True when any selected block's history cannot carry a confident assessment. */
    val hasHistoryConcerns: Boolean,
) {
    fun historyCheck(blockId: String): ResistanceBlockHistoryCheck? =
        historyChecks.firstOrNull { it.blockId == blockId }

    fun timeline(blockId: String): ResistancePlanBlockTimeline? =
        timelines.firstOrNull { it.blockId == blockId }

    fun totals(blockId: String): ResistanceBlockSeasonTotals? =
        seasonTotals.firstOrNull { it.blockId == blockId }

    val worstPositionStatus: ResistancePlanPositionStatus?
        get() = if (positions.isEmpty()) {
            null
        } else {
            ResistancePlanPositionStatus.worst(positions.map { it.status })
        }
}

/**
 * The Resistance Planner.
 *
 * Pure domain logic with NO resistance rules of its own. Every verdict it returns comes
 * from [ResistanceEngine.evaluate]; the Planner's whole job is to decide WHAT to ask
 * (which block, which sequence prefix, which candidate) and to arrange the answers. If a
 * count appears in the UI, the engine produced it — the Planner never counts sprays
 * itself, because a second implementation of "how many Group 11 sprays is that" would
 * eventually disagree with the first.
 *
 * Mirrors `ResistancePlanner.swift` on iOS.
 */
object ResistancePlanner {

    const val UNSUPPORTED_JURISDICTION_MESSAGE =
        "Resistance planning is not yet configured for this vineyard's jurisdiction."

    /**
     * Shown whenever the engine reports [ResistanceMixtureRequirement.UNKNOWN].
     *
     * Held here rather than typed into each platform's view so iOS and Android cannot
     * drift into wording one softer than the other. The UI must never decide for itself
     * that two FRAC groups in a tank satisfy a mixture requirement.
     */
    const val MIXTURE_UNCONFIRMED_LABEL = "Mixture requirement cannot be fully confirmed"

    /** One day, for spacing synthetic planned timestamps. */
    private const val DAY_MS: Long = 86_400_000

    data class Request(
        val plan: ResistancePlan,
        val season: ResistanceSeason,
        val seasonCalendar: ResistanceSeasonCalendar,
        /**
         * Every completed resistance event available, for any block, disease or season.
         * The engine does the filtering — pre-filtering here would strip the
         * previous-season tail that cross-season rules need.
         */
        val events: List<ResistanceApplicationEvent>,
        /** Real applications whose treated blocks were never recorded. */
        val unresolvedApplications: List<ResistanceEventSource.UnresolvedBlockApplication> = emptyList(),
        val registry: ResistanceRulesetRegistry = ResistanceRulesets.registry,
    )

    // -----------------------------------------------------------------------
    // Entry point
    // -----------------------------------------------------------------------

    fun evaluate(request: Request): ResistancePlanEvaluation {
        val plan = request.plan
        val ruleset = request.registry.current(plan.jurisdiction, plan.crop, plan.disease)
            ?: return ResistancePlanEvaluation(
                isSupported = false,
                unsupportedMessage = UNSUPPORTED_JURISDICTION_MESSAGE,
                strategyName = null,
                sourceOrganisation = null,
                rulesetId = null,
                rulesetVersion = null,
                rulesetValidFrom = null,
                historyChecks = emptyList(),
                timelines = emptyList(),
                positions = emptyList(),
                seasonTotals = emptyList(),
                unresolvedApplicationCount = 0,
                hasHistoryConcerns = false,
            )

        val unresolved = request.unresolvedApplications.filter {
            it.mayConcern(plan.disease) && it.seasonId == request.season.id
        }

        val checks = plan.blockIds.map { historyCheck(it, request, unresolved.size) }
        val timelines = plan.blockIds.map { timeline(it, request) }
        val totals = plan.blockIds.map { seasonTotals(it, request) }
        val positions = plan.positions.indices.map { evaluatePosition(it, request, totals) }

        return ResistancePlanEvaluation(
            isSupported = true,
            unsupportedMessage = null,
            strategyName = ruleset.strategyName,
            sourceOrganisation = ruleset.sourceOrganisation,
            rulesetId = ruleset.id,
            rulesetVersion = ruleset.rulesetVersion,
            rulesetValidFrom = ruleset.validFrom,
            historyChecks = checks,
            timelines = timelines,
            positions = positions,
            seasonTotals = totals,
            unresolvedApplicationCount = unresolved.size,
            hasHistoryConcerns = checks.any { !it.isCompleteEnoughToAssess },
        )
    }

    // -----------------------------------------------------------------------
    // Position evaluation
    // -----------------------------------------------------------------------

    /**
     * Evaluates position [index] for every selected block.
     *
     * The sequence handed to the engine is HISTORY + EVERY PRECEDING PLANNED POSITION,
     * with the position itself as the candidate. Positions after it are excluded
     * entirely — a spray planned for December cannot influence whether October's choice
     * is allowed.
     *
     * Preceding positions are passed as PLANNED with `includePlanned = true` rather than
     * being disguised as ACTUAL. The engine already distinguishes the two, and
     * laundering a plan into history would be a lie that leaks: the same events are used
     * elsewhere to report what was actually applied.
     */
    fun evaluatePosition(
        index: Int,
        request: Request,
        completedCounts: List<ResistanceBlockSeasonTotals>? = null,
    ): ResistancePlanPositionEvaluation {
        val plan = request.plan
        val position = plan.positions[index]
        val totals = completedCounts ?: plan.blockIds.map { seasonTotals(it, request) }
        // The ordinal continues the longest block history, so "Spray 4" means the fourth
        // spray for the block that has had the most — never a count no block experienced.
        val completed = totals.maxOfOrNull { it.diseaseSprayCount } ?: 0

        if (position.isEmpty) {
            return ResistancePlanPositionEvaluation(
                positionId = position.id,
                index = index,
                displayOrdinal = completed + index + 1,
                status = ResistancePlanPositionStatus.NEEDS_REVIEW,
                blocks = emptyList(),
                awaitingChemistry = true,
            )
        }

        val timestamps = plannedTimestamps(request)
        val outcomes = plan.blockIds.map { blockId ->
            val precedingPlanned = (0 until index).map { earlier ->
                event(
                    position = plan.positions[earlier],
                    blockId = blockId,
                    kind = ResistanceEventKind.PLANNED,
                    epochMs = timestamps[earlier],
                    request = request,
                )
            }
            val candidate = event(
                position = position,
                blockId = blockId,
                kind = ResistanceEventKind.CANDIDATE,
                epochMs = timestamps[index],
                request = request,
            )
            val evaluation = ResistanceEngine.evaluate(
                ResistanceEvaluationRequest(
                    jurisdiction = plan.jurisdiction,
                    crop = plan.crop,
                    disease = plan.disease,
                    blockId = blockId,
                    season = request.season,
                    seasonCalendar = request.seasonCalendar,
                    events = request.events + precedingPlanned,
                    candidate = candidate,
                    // Preceding planned positions must count; the plan is the whole
                    // point of the exercise.
                    includePlanned = true,
                    registry = request.registry,
                ),
            )
            ResistancePlanBlockOutcome(
                blockId = blockId,
                status = status(evaluation, position),
                evaluation = evaluation,
            )
        }

        return ResistancePlanPositionEvaluation(
            positionId = position.id,
            index = index,
            displayOrdinal = completed + index + 1,
            status = ResistancePlanPositionStatus.worst(outcomes.map { it.status }),
            blocks = outcomes,
            awaitingChemistry = false,
        )
    }

    /**
     * Maps an engine verdict onto a planner status.
     *
     * Nothing is re-derived here — the engine has already decided. This only chooses the
     * operator-facing name, and refuses to call a result a good fit when a requirement
     * could not be confirmed.
     */
    fun status(
        evaluation: ResistanceEvaluation,
        position: ResistancePlannedPosition?,
    ): ResistancePlanPositionStatus = when (evaluation.status) {
        ResistanceEvaluationStatus.UNSUPPORTED_RULESET,
        ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS,
        -> ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS

        ResistanceEvaluationStatus.STRATEGY_EXCEEDED ->
            ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY

        ResistanceEvaluationStatus.LIMIT_REACHED ->
            ResistancePlanPositionStatus.REACHES_STRATEGY_LIMIT

        ResistanceEvaluationStatus.COMPLIANT,
        ResistanceEvaluationStatus.APPROACHING_LIMIT,
        ResistanceEvaluationStatus.NOT_APPLICABLE,
        -> when {
            // A mixture requirement that cannot be confirmed is not a pass.
            evaluation.ruleResults.any { it.status == ResistanceRuleStatus.REQUIREMENT_UNPROVEN } ->
                ResistancePlanPositionStatus.NEEDS_REVIEW
            // An unverified or conflicting product keeps its caveat visible in the
            // status, so a plan built on shaky chemistry never renders as clean.
            position != null && position.productsRequiringCaveat.isNotEmpty() ->
                ResistancePlanPositionStatus.NEEDS_REVIEW

            evaluation.evidenceQuality != ResistanceEvidenceQuality.HIGH ->
                ResistancePlanPositionStatus.NEEDS_REVIEW

            // Guidance deliberately does NOT downgrade the status. The powdery ruleset
            // carries a blanket preventative-use guideline that is present in every
            // evaluation, so treating guidance as "needs review" would mark every
            // powdery position for review and make GOOD_FIT unreachable — destroying the
            // signal the status exists to carry. Guidance still appears in `findings`,
            // which is where published advice with no threshold belongs.
            else -> ResistancePlanPositionStatus.GOOD_FIT
        }
    }

    // -----------------------------------------------------------------------
    // Group options
    // -----------------------------------------------------------------------

    /**
     * Strategy-compatible group options for a position, worst options omitted.
     *
     * Each option is a real engine evaluation of that group placed at that position, for
     * every selected block — not a heuristic and not a lookup table. Groups whose worst
     * block outcome would exceed the strategy are excluded from the offer.
     */
    fun groupOptions(index: Int, request: Request): List<ResistancePlanGroupOption> {
        val plan = request.plan
        val ruleset = request.registry.current(plan.jurisdiction, plan.crop, plan.disease)
            ?: return emptyList()
        if (index < 0 || index > plan.positions.size) return emptyList()

        val recentGroups = recentGroupsBefore(index, request)

        val options = ruleset.groups.mapNotNull { listing ->
            val trialPosition = ResistancePlannedPosition(
                id = if (index < plan.positions.size) plan.positions[index].id else "trial-position",
                products = listOf(
                    ResistancePlannedProduct(
                        id = "trial",
                        groupCodes = listing.signature.codes,
                        source = ResistancePlannedChemistrySource.GROUP,
                    ),
                ),
            )
            val trialPositions = plan.positions.toMutableList()
            if (index < trialPositions.size) {
                trialPositions[index] = trialPosition
            } else {
                trialPositions.add(trialPosition)
            }
            val trialRequest = request.copy(plan = plan.copy(positions = trialPositions))
            val evaluation = evaluatePosition(index, trialRequest)
            if (evaluation.status == ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY) {
                null
            } else {
                ResistancePlanGroupOption(
                    listing = listing,
                    status = evaluation.status,
                    differsFromRecentSequence = listing.signature.codes.none { it in recentGroups },
                    statusByBlock = evaluation.blocks.associate { it.blockId to it.status },
                )
            }
        }

        // Rotation first: a group sharing nothing with the recent sequence is what the
        // strategy actually asks for, so it leads regardless of how tidy the arithmetic
        // looks for a repeat.
        return options.sortedWith(
            compareByDescending<ResistancePlanGroupOption> { it.differsFromRecentSequence }
                .thenBy { it.status.rank }
                .thenComparing(
                    { it.listing.signature.codes.firstOrNull() ?: "" },
                    ResistanceGroupCode.comparator,
                ),
        )
    }

    /**
     * Groups in the most recent application before [index], across the effective
     * sequence (history plus preceding planned positions).
     *
     * Taken per block and unioned: with two blocks selected the "recent sequence"
     * differs between them, and a group that rotates away from one may repeat on the
     * other. Unioning keeps the recommendation conservative rather than optimistic.
     */
    fun recentGroupsBefore(index: Int, request: Request): Set<String> {
        val plan = request.plan
        if (index in 1..plan.positions.size) {
            return plan.positions[index - 1].componentGroups
        }
        val groups = mutableSetOf<String>()
        for (blockId in plan.blockIds) {
            val history = request.events
                .filter {
                    it.blockId == blockId && it.kind == ResistanceEventKind.ACTUAL &&
                        it.targetsRecorded && it.targets(plan.disease) &&
                        request.season.contains(it.appliedAtEpochMs)
                }
                .sortedWith(ResistanceApplicationEvent.chronological)
            history.lastOrNull()?.let { groups.addAll(it.componentGroups) }
        }
        return groups
    }

    // -----------------------------------------------------------------------
    // Product options
    // -----------------------------------------------------------------------

    /**
     * Chemical Store products offered for a planned group.
     *
     * Filtering is by jurisdiction and structured group only. Registered use and
     * verification state are REPORTED, never used to silently drop a product the
     * operator owns — a grower with one unverified Group 7 product needs to see it and
     * its caveat, not an empty list.
     */
    fun productOptions(
        signature: ResistanceGroupSignature,
        candidates: List<ResistancePlanChemicalCandidate>,
        jurisdiction: ResistanceJurisdiction,
    ): List<ResistancePlanProductOption> {
        val wanted = signature.codes.toSet()
        if (wanted.isEmpty()) return emptyList()
        val expectedCountry = jurisdiction.expectedCountryCode

        return candidates
            .filter { candidate ->
                // Unknown country is not a mismatch: most Chemical Store entries
                // predate country capture, and hiding them would leave the grower unable
                // to plan with products they actually hold.
                val country = candidate.countryCode?.uppercase()?.takeIf { it.isNotBlank() }
                if (country == null || expectedCountry == null) true else country == expectedCountry
            }
            .filter { it.groups.codes.any { code -> code in wanted } }
            .map {
                ResistancePlanProductOption(
                    candidate = it,
                    isExactSignatureMatch = it.groups.codes.toSet() == wanted,
                )
            }
            .sortedWith(
                compareByDescending<ResistancePlanProductOption> { it.isExactSignatureMatch }
                    .thenByDescending { availabilityRank(it.candidate.availability) }
                    .thenBy { it.candidate.productName.lowercase() },
            )
    }

    private fun availabilityRank(availability: ChemicalIntelligenceAvailability): Int =
        when (availability) {
            ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED -> 5
            ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED -> 4
            ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED -> 3
            ChemicalIntelligenceAvailability.CONFLICT -> 2
            ChemicalIntelligenceAvailability.UNAVAILABLE -> 1
        }

    // -----------------------------------------------------------------------
    // History reporting
    // -----------------------------------------------------------------------

    fun historyCheck(
        blockId: String,
        request: Request,
        unresolvedCount: Int,
    ): ResistanceBlockHistoryCheck {
        val plan = request.plan
        val inSeason = request.events.filter {
            it.blockId == blockId && it.kind == ResistanceEventKind.ACTUAL &&
                request.season.contains(it.appliedAtEpochMs)
        }
        val relevant = inSeason.filter { it.targetsRecorded && it.targets(plan.disease) }
        val unknownTargets = inSeason.filter { !it.targetsRecorded }

        val unverified = relevant.filter {
            it.availability == ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED ||
                it.availability == ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED
        }
        val unavailable = relevant.filter {
            it.availability == ChemicalIntelligenceAvailability.UNAVAILABLE
        }
        val conflicting = relevant.filter {
            it.availability == ChemicalIntelligenceAvailability.CONFLICT
        }

        // Ordered worst-first so the headline names the most serious gap.
        val concerns = buildList {
            if (unresolvedCount > 0) add(ResistanceHistoryConcern.UNRESOLVED_BLOCK_ATTRIBUTION)
            if (unknownTargets.isNotEmpty()) add(ResistanceHistoryConcern.UNKNOWN_TARGETS)
            if (conflicting.isNotEmpty()) add(ResistanceHistoryConcern.CONFLICTING_CHEMISTRY)
            if (unavailable.isNotEmpty()) add(ResistanceHistoryConcern.UNAVAILABLE_CHEMISTRY)
            if (unverified.isNotEmpty()) add(ResistanceHistoryConcern.UNVERIFIED_CHEMISTRY)
        }

        return ResistanceBlockHistoryCheck(
            blockId = blockId,
            relevantApplicationCount = relevant.size,
            concerns = concerns,
            unverifiedCount = unverified.size,
            unavailableCount = unavailable.size,
            conflictingCount = conflicting.size,
            unknownTargetCount = unknownTargets.size,
            unresolvedVineyardApplicationCount = unresolvedCount,
        )
    }

    fun timeline(blockId: String, request: Request): ResistancePlanBlockTimeline {
        val plan = request.plan
        val entries = request.events
            .filter {
                it.blockId == blockId && it.kind == ResistanceEventKind.ACTUAL &&
                    request.season.contains(it.appliedAtEpochMs) &&
                    it.targetsRecorded && it.targets(plan.disease)
            }
            .sortedWith(ResistanceApplicationEvent.chronological)
            .map { event ->
                ResistancePlanTimelineEntry(
                    applicationId = event.applicationId,
                    appliedAtEpochMs = event.appliedAtEpochMs,
                    groupsLabel = ResistanceGroupSignature.of(event.componentGroups).displayLabel,
                    productNames = event.products.mapNotNull { it.productName }
                        .filter { it.isNotBlank() },
                    availability = event.availability,
                    targetsRecorded = event.targetsRecorded,
                )
            }
        return ResistancePlanBlockTimeline(blockId = blockId, entries = entries)
    }

    /** Season totals for a block, counted from resistance events (never tank lines). */
    fun seasonTotals(blockId: String, request: Request): ResistanceBlockSeasonTotals {
        val plan = request.plan
        val relevant = request.events.filter {
            it.blockId == blockId && it.kind == ResistanceEventKind.ACTUAL &&
                request.season.contains(it.appliedAtEpochMs) &&
                it.targetsRecorded && it.targets(plan.disease)
        }
        val byGroup = mutableMapOf<String, Int>()
        for (event in relevant) {
            // One application contributes at most one to each group it contains, so a
            // co-formulation of 11+3 counts once for 11 and once for 3 — not twice for
            // either, and not once for "11+3" as though that were a third group.
            for (code in event.componentGroups) {
                byGroup[code] = (byGroup[code] ?: 0) + 1
            }
        }
        return ResistanceBlockSeasonTotals(
            blockId = blockId,
            diseaseSprayCount = relevant.size,
            applicationsByGroup = byGroup,
        )
    }

    // -----------------------------------------------------------------------
    // Synthetic planned chronology
    // -----------------------------------------------------------------------

    /**
     * Timestamps for the plan's positions, derived from plan ORDER.
     *
     * PLAN ORDER IS AUTHORITATIVE, and an optional target date is display metadata only.
     * Two reasons. First, resistance rules are sequence-dependent, so reordering
     * positions has to change the answers (that is the whole value of the tool); if a
     * stale date could override the order, the list an operator is reading would
     * disagree with the arithmetic behind it. Second, requiring dates just to plan a
     * rotation would make the tool unusable in the only situation it is really needed —
     * deciding chemistry months out, before any date is knowable.
     *
     * Slots are placed after the last completed application in the season and spaced so
     * they always remain strictly increasing AND inside the season, so a long plan
     * cannot silently spill into the next season and reset a seasonal maximum.
     */
    fun plannedTimestamps(request: Request): List<Long> {
        val plan = request.plan
        if (plan.positions.isEmpty()) return emptyList()
        val lastHistory = request.events
            .filter {
                it.blockId in plan.blockIds && it.kind == ResistanceEventKind.ACTUAL &&
                    request.season.contains(it.appliedAtEpochMs)
            }
            .maxOfOrNull { it.appliedAtEpochMs }
        val anchor = maxOf(lastHistory ?: request.season.startEpochMs, request.season.startEpochMs)
        val remaining = maxOf(request.season.endEpochMs - anchor, (plan.positions.size + 1).toLong())
        val spacing = maxOf(1L, minOf(DAY_MS, remaining / (plan.positions.size + 1)))
        return plan.positions.indices.map { anchor + spacing * (it + 1) }
    }

    /**
     * Builds a resistance event from a planned position.
     *
     * `targetsRecorded` is true and `targets` is the planned disease: the operator has
     * explicitly said what this slot is for, which is exactly the fact pre-sql/193
     * history lacks.
     *
     * `mixturePartnerAtLabelRate` is deliberately left null. A plan cannot establish that
     * a partner will go in at an effective rate, so mixture rules correctly return
     * "cannot be confirmed" rather than a comfortable pass.
     */
    fun event(
        position: ResistancePlannedPosition,
        blockId: String,
        kind: ResistanceEventKind,
        epochMs: Long,
        request: Request,
    ): ResistanceApplicationEvent = ResistanceApplicationEvent(
        applicationId = plannedApplicationId(request.plan.id, position.id),
        kind = kind,
        appliedAtEpochMs = epochMs,
        seasonId = request.season.id,
        vineyardId = request.plan.vineyardId,
        blockId = blockId,
        targets = listOf(request.plan.disease),
        targetsRecorded = true,
        products = position.products.map { product ->
            ResistanceProductLine(
                lineId = product.id,
                productName = product.productName,
                savedChemicalId = product.savedChemicalId,
                groups = product.groups,
                availability = product.effectiveAvailability,
            )
        },
    )

    /** Namespaced so a planned position can never collide with a real spray record id. */
    fun plannedApplicationId(planId: String, positionId: String): String =
        "plan:$planId:position:$positionId"
}

/** ISO country code this jurisdiction expects, for Chemical Store filtering. */
val ResistanceJurisdiction.expectedCountryCode: String?
    get() = when (this) {
        ResistanceJurisdiction.AUSTRALIA -> "AU"
        ResistanceJurisdiction.NEW_ZEALAND -> "NZ"
        ResistanceJurisdiction.UNKNOWN -> null
    }
