package com.rork.vinetrack.data.resistance

/**
 * What to evaluate. Explicit and deterministic: the same request produces the
 * same result on iOS and Android, and on any device in any time zone.
 */
data class ResistanceEvaluationRequest(
    /** From the VINEYARD's stored country — never the phone locale. */
    val jurisdiction: ResistanceJurisdiction,
    val crop: ResistanceCrop,
    val disease: ResistanceDisease,
    val blockId: String,
    val season: ResistanceSeason,
    val seasonCalendar: ResistanceSeasonCalendar,
    /**
     * Every candidate event, any block, any disease, any season. The engine does
     * the filtering, so callers cannot accidentally pre-filter away the previous
     * season's tail that a cross-season rule needs.
     */
    val events: List<ResistanceApplicationEvent>,
    /**
     * A proposed next spray. Need not be saved and need not have a real ID — the
     * Guided Spray plan being assessed has neither.
     */
    val candidate: ResistanceApplicationEvent? = null,
    /**
     * Whether scheduled-but-unapplied events count as history. False in v1: a
     * plan is not an application.
     */
    val includePlanned: Boolean = false,
    val registry: ResistanceRulesetRegistry = ResistanceRulesets.registry,
)

/**
 * The Resistance Rules Engine.
 *
 * Pure domain logic: no SwiftUI, no Compose, no repository, no clock. Everything
 * it knows arrives in the request, which is what lets one implementation serve
 * saved history, an unsaved plan, and a test fixture — and what will let the
 * Resistance Planner and the Spray Calculator share one engine instead of
 * growing two that disagree.
 *
 * Mirrors iOS `ResistanceEngine.swift`.
 */
object ResistanceEngine {

    fun evaluate(request: ResistanceEvaluationRequest): ResistanceEvaluation {
        val ruleset = request.registry.current(request.jurisdiction, request.crop, request.disease)
            ?: return unsupported(request)

        // --- Scope to the block -------------------------------------------
        val blockEvents = request.events.filter { it.blockId == request.blockId }

        val excludedPlanned = if (request.includePlanned) {
            emptyList()
        } else {
            blockEvents.filter { it.kind == ResistanceEventKind.PLANNED }
        }
        val includedKinds = buildSet {
            add(ResistanceEventKind.ACTUAL)
            add(ResistanceEventKind.CANDIDATE)
            if (request.includePlanned) add(ResistanceEventKind.PLANNED)
        }
        val history = blockEvents.filter { includedKinds.contains(it.kind) }

        // Applications with no recorded target cannot be attributed to a
        // disease. They are NOT dropped: an unattributable spray inside the
        // season is a hole in the history, and a hole must suppress a clean
        // result rather than quietly shrink the denominator.
        val unattributedInSeason = history
            .filter { request.season.contains(it.appliedAtEpochMs) && !it.targetsRecorded }
            .sortedWith(ResistanceApplicationEvent.chronological)

        // A candidate is only relevant to the block AND disease being evaluated.
        // Without the block check, assessing a spray planned for block B would
        // silently consume block A's allowance.
        val candidate = request.candidate
            ?.takeIf { it.targets(request.disease) && it.blockId == request.blockId }

        val diseaseHistory = history
            .filter { it.targetsRecorded && it.targets(request.disease) }
            .sortedWith(ResistanceApplicationEvent.chronological)

        val currentSeasonHistory = diseaseHistory.filter { request.season.contains(it.appliedAtEpochMs) }
        val previousSeason = request.seasonCalendar.previous(request.season)
        val previousSeasonHistory = diseaseHistory.filter { previousSeason.contains(it.appliedAtEpochMs) }

        val currentSeasonSequence = (currentSeasonHistory + listOfNotNull(candidate))
            .sortedWith(ResistanceApplicationEvent.chronological)
        val crossSeasonSequence = (previousSeasonHistory + currentSeasonSequence)
            .sortedWith(ResistanceApplicationEvent.chronological)

        // Denominator for every percentage rule: applications targeting THIS
        // disease, for THIS block, in THIS season. Never all vineyard sprays,
        // never tank lines, never other diseases. A mixture is one application,
        // so mixtures never inflate it.
        val totalDiseaseSprays = currentSeasonSequence.size

        if (totalDiseaseSprays == 0 && unattributedInSeason.isEmpty()) {
            return notApplicable(request, ruleset, excludedPlanned)
        }

        val context = EvaluationContext(
            request = request,
            ruleset = ruleset,
            currentSeasonSequence = currentSeasonSequence,
            crossSeasonSequence = crossSeasonSequence,
            candidate = candidate,
            totalDiseaseSprays = totalDiseaseSprays,
            unattributedInSeason = unattributedInSeason,
        )

        val ruleResults = ruleset.rules.map { evaluateRule(it, context) }

        val unassessable = currentSeasonSequence
            .filter { !it.canAssessChemistry }
            .map { it.applicationId }
        val overall = overallStatus(ruleResults, unassessable, unattributedInSeason)
        val evidence = overallEvidence(currentSeasonSequence, unattributedInSeason)

        return ResistanceEvaluation(
            status = overall,
            jurisdiction = request.jurisdiction,
            crop = request.crop,
            disease = request.disease,
            blockId = request.blockId,
            seasonId = request.season.id,
            rulesetId = ruleset.id,
            rulesetVersion = ruleset.rulesetVersion,
            rulesetValidFrom = ruleset.validFrom,
            ruleResults = ruleResults,
            totalDiseaseSpraysInSeason = totalDiseaseSprays,
            consideredApplicationIds = currentSeasonSequence.map { it.applicationId },
            unassessableApplicationIds = unassessable,
            unattributedApplicationIds = unattributedInSeason.map { it.applicationId },
            excludedPlannedApplicationIds = excludedPlanned.map { it.applicationId },
            evidenceQuality = evidence,
            summary = summarise(overall, evidence, ruleResults, request.disease, unattributedInSeason.size),
            candidateApplicationId = candidate?.applicationId,
        )
    }

    // -----------------------------------------------------------------------
    // Context
    // -----------------------------------------------------------------------

    private data class EvaluationContext(
        val request: ResistanceEvaluationRequest,
        val ruleset: ResistanceRuleset,
        val currentSeasonSequence: List<ResistanceApplicationEvent>,
        val crossSeasonSequence: List<ResistanceApplicationEvent>,
        val candidate: ResistanceApplicationEvent?,
        val totalDiseaseSprays: Int,
        val unattributedInSeason: List<ResistanceApplicationEvent>,
    ) {
        fun sequence(rule: ResistanceRule): List<ResistanceApplicationEvent> =
            if (rule.crossSeason) crossSeasonSequence else currentSeasonSequence
    }

    // -----------------------------------------------------------------------
    // Per-rule dispatch
    // -----------------------------------------------------------------------

    private fun evaluateRule(rule: ResistanceRule, context: EvaluationContext): ResistanceRuleResult {
        val partial = when (val kind = rule.kind) {
            is ResistanceRuleKind.MaxConsecutiveApplications ->
                evaluateConsecutive(rule, context, kind.limit)
            ResistanceRuleKind.NoConsecutiveApplications ->
                evaluateConsecutive(rule, context, 1)
            is ResistanceRuleKind.MaxApplicationsPerSeason ->
                evaluateCount(rule, context, kind.limit, "season")
            is ResistanceRuleKind.MaxApplicationsPerCrop ->
                evaluateCount(rule, context, kind.limit, "crop")
            is ResistanceRuleKind.MaxFractionOfDiseaseSprays ->
                evaluateFraction(rule, context, kind.numerator, kind.denominator)
            is ResistanceRuleKind.MaxOneInEveryNSprays ->
                evaluateOneInEveryN(rule, context, kind.window)
            is ResistanceRuleKind.MinInterveningDifferentGroupApplications ->
                evaluateMinIntervening(rule, context, kind.count)
            ResistanceRuleKind.MixtureRequired ->
                evaluateMixture(rule, context, onlyWhenConsecutive = false)
            ResistanceRuleKind.MixtureRequiredWhenConsecutive ->
                evaluateMixture(rule, context, onlyWhenConsecutive = true)
            is ResistanceRuleKind.MaxSoloApplicationsPerSeason ->
                evaluateSoloCount(rule, context, kind.limit)
            ResistanceRuleKind.NotLastSprayOfSeason ->
                evaluateNotLastSpray(rule, context)
            is ResistanceRuleKind.MaxFromTotalSprayCountTable ->
                evaluateTable(rule, context, kind.columnKey)
            ResistanceRuleKind.PreventativeApplicationGuidance ->
                evaluateGuidance(rule, context)
        }
        return finalise(rule, context, partial)
    }

    /**
     * An intermediate result, before availability gating and packaging.
     */
    private data class Partial(
        val status: ResistanceRuleStatus,
        val threshold: Double?,
        val thresholdDescription: String,
        val observedValue: Double?,
        val observedDescription: String,
        val explanation: String,
        val contributing: List<ResistanceApplicationEvent>,
        val mixtureRequirement: ResistanceMixtureRequirement? = null,
        /** Rules that are pure guidance are never gated by availability. */
        val isGuidance: Boolean = false,
    )

    // -----------------------------------------------------------------------
    // Consecutive runs
    // -----------------------------------------------------------------------

    private fun evaluateConsecutive(
        rule: ResistanceRule,
        context: EvaluationContext,
        limit: Int,
    ): Partial {
        val sequence = context.sequence(rule)
        val groups = rule.selector.describedGroups.joinToString(" + ")
        val historyOnly = sequence.filter { it.applicationId != context.candidate?.applicationId }

        val historyRuns = maximalRuns(historyOnly, rule.selector)
        val historyLongest = historyRuns.maxOfOrNull { it.size } ?: 0
        val candidateMatches = context.candidate?.let { rule.selector.matches(it) } == true
        val candidateRun = if (candidateMatches) trailingRun(sequence, rule.selector) else emptyList()

        val crossSeasonNote = if (rule.crossSeason && spansSeasonBoundary(candidateRun.ifEmpty {
                historyRuns.maxByOrNull { it.size } ?: emptyList()
            }, context)
        ) {
            " This run continues from the previous season, which the strategy counts as consecutive."
        } else {
            ""
        }

        val thresholdText = if (limit == 1) {
            "Group $groups must not be applied consecutively"
        } else {
            "a maximum of $limit consecutive Group $groups applications"
        }

        return when {
            historyLongest > limit -> Partial(
                status = ResistanceRuleStatus.LIMIT_EXCEEDED,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = historyLongest.toDouble(),
                observedDescription = "$historyLongest consecutive applications recorded",
                explanation = "Group $groups has already been applied $historyLongest times in a row " +
                    "for ${context.request.disease.label}. The strategy allows $limit.$crossSeasonNote",
                contributing = historyRuns.first { it.size == historyLongest },
            )

            candidateMatches && candidateRun.size > limit -> Partial(
                status = ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = candidateRun.size.toDouble(),
                observedDescription = "${candidateRun.size} consecutive applications including this one",
                explanation = "This would be consecutive Group $groups application number " +
                    "${candidateRun.size}. The strategy allows $limit.$crossSeasonNote",
                contributing = candidateRun,
            )

            candidateMatches && candidateRun.size == limit -> Partial(
                status = ResistanceRuleStatus.WOULD_REACH_LIMIT,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = candidateRun.size.toDouble(),
                observedDescription = "${candidateRun.size} consecutive applications including this one",
                explanation = "This would reach the strategy maximum of $limit consecutive Group " +
                    "$groups applications. A different group should follow.$crossSeasonNote",
                contributing = candidateRun,
            )

            historyLongest == limit -> Partial(
                status = ResistanceRuleStatus.LIMIT_REACHED,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = historyLongest.toDouble(),
                observedDescription = "$historyLongest consecutive applications recorded",
                explanation = "Group $groups has reached the strategy maximum of $limit consecutive " +
                    "applications. A different group should be used next.$crossSeasonNote",
                contributing = historyRuns.first { it.size == historyLongest },
            )

            historyLongest == 0 && !candidateMatches -> notTriggered(rule, limit.toDouble(), thresholdText)

            limit >= 2 && maxOf(historyLongest, candidateRun.size) == limit - 1 -> Partial(
                status = ResistanceRuleStatus.APPROACHING_LIMIT,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = maxOf(historyLongest, candidateRun.size).toDouble(),
                observedDescription = "${maxOf(historyLongest, candidateRun.size)} consecutive applications",
                explanation = "One more consecutive Group $groups application would reach the " +
                    "strategy maximum of $limit.",
                contributing = candidateRun.ifEmpty { historyRuns.maxByOrNull { it.size } ?: emptyList() },
            )

            else -> Partial(
                status = ResistanceRuleStatus.WITHIN_LIMIT,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = maxOf(historyLongest, candidateRun.size).toDouble(),
                observedDescription = "${maxOf(historyLongest, candidateRun.size)} consecutive applications",
                explanation = "Within the strategy limit for consecutive Group $groups applications.",
                contributing = emptyList(),
            )
        }
    }

    /** Maximal runs of adjacent matching events. */
    private fun maximalRuns(
        sequence: List<ResistanceApplicationEvent>,
        selector: ResistanceGroupSelector,
    ): List<List<ResistanceApplicationEvent>> {
        val runs = mutableListOf<List<ResistanceApplicationEvent>>()
        var current = mutableListOf<ResistanceApplicationEvent>()
        sequence.forEach { event ->
            if (selector.matches(event)) {
                current.add(event)
            } else if (current.isNotEmpty()) {
                runs.add(current.toList())
                current = mutableListOf()
            }
        }
        if (current.isNotEmpty()) runs.add(current.toList())
        return runs
    }

    /** The run of matching events ending at the end of the sequence. */
    private fun trailingRun(
        sequence: List<ResistanceApplicationEvent>,
        selector: ResistanceGroupSelector,
    ): List<ResistanceApplicationEvent> {
        val trailing = mutableListOf<ResistanceApplicationEvent>()
        for (event in sequence.reversed()) {
            if (!selector.matches(event)) break
            trailing.add(0, event)
        }
        return trailing
    }

    private fun spansSeasonBoundary(
        run: List<ResistanceApplicationEvent>,
        context: EvaluationContext,
    ): Boolean {
        if (run.size < 2) return false
        return run.any { !context.request.season.contains(it.appliedAtEpochMs) } &&
            run.any { context.request.season.contains(it.appliedAtEpochMs) }
    }

    // -----------------------------------------------------------------------
    // Simple counts
    // -----------------------------------------------------------------------

    private fun evaluateCount(
        rule: ResistanceRule,
        context: EvaluationContext,
        limit: Int,
        window: String,
    ): Partial {
        val matching = context.currentSeasonSequence.filter { rule.selector.matches(it) }
        val groups = rule.selector.describedGroups.joinToString(" + ")
        val thresholdText = "a maximum of $limit Group $groups applications per $window"
        return countOutcome(
            rule = rule,
            context = context,
            matching = matching,
            limit = limit,
            thresholdText = thresholdText,
            groups = groups,
            observedNoun = "applications",
        )
    }

    private fun evaluateSoloCount(
        rule: ResistanceRule,
        context: EvaluationContext,
        limit: Int,
    ): Partial {
        val ruleGroups = rule.selector.describedGroups
        val matching = context.currentSeasonSequence.filter {
            rule.selector.matches(it) && it.groupsOtherThan(ruleGroups).isEmpty()
        }
        val groups = ruleGroups.joinToString(" + ")
        return countOutcome(
            rule = rule,
            context = context,
            matching = matching,
            limit = limit,
            thresholdText = "a maximum of $limit solo (unmixed) Group $groups applications per season",
            groups = groups,
            observedNoun = "solo applications",
        )
    }

    private fun countOutcome(
        rule: ResistanceRule,
        context: EvaluationContext,
        matching: List<ResistanceApplicationEvent>,
        limit: Int,
        thresholdText: String,
        groups: String,
        observedNoun: String,
        /**
         * True when the ceiling itself can still rise this season — the Powdery
         * table's maxima are a function of the total spray count.
         *
         * With a provisional ceiling, "reached" and "approaching" are not
         * meaningful: at one total spray the table permits one application of
         * every group, so a single spray would otherwise report "CropLife
         * strategy maximum reached" in a season that has barely started. Only a
         * genuine EXCEEDANCE is reported, because that cannot be undone by
         * spraying more.
         */
        provisionalCeiling: Boolean = false,
    ): Partial {
        val candidateId = context.candidate?.applicationId
        val historyMatching = matching.filter { it.applicationId != candidateId }
        val candidateMatches = candidateId != null && matching.any { it.applicationId == candidateId }
        val total = matching.size
        val disease = context.request.disease.label

        return when {
            historyMatching.size > limit -> Partial(
                status = ResistanceRuleStatus.LIMIT_EXCEEDED,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = historyMatching.size.toDouble(),
                observedDescription = "${historyMatching.size} $observedNoun recorded",
                explanation = "Group $groups has been applied ${historyMatching.size} times for " +
                    "$disease. The strategy allows $limit.",
                contributing = historyMatching,
            )

            candidateMatches && total > limit -> Partial(
                status = ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = total.toDouble(),
                observedDescription = "$total $observedNoun including this one",
                explanation = "This would be Group $groups application number $total for $disease. " +
                    "The strategy allows $limit.",
                contributing = matching,
            )

            candidateMatches && total == limit -> Partial(
                status = ResistanceRuleStatus.WOULD_REACH_LIMIT,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = total.toDouble(),
                observedDescription = "$total $observedNoun including this one",
                explanation = "This would reach the strategy maximum of $limit Group $groups " +
                    "applications for $disease.",
                contributing = matching,
            )

            !candidateMatches && historyMatching.size == limit -> Partial(
                status = ResistanceRuleStatus.LIMIT_REACHED,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = historyMatching.size.toDouble(),
                observedDescription = "${historyMatching.size} $observedNoun recorded",
                explanation = "Group $groups has reached the strategy maximum of $limit " +
                    "applications for $disease.",
                contributing = historyMatching,
            )

            total == 0 -> notTriggered(rule, limit.toDouble(), thresholdText)

            total == limit - 1 -> Partial(
                status = ResistanceRuleStatus.APPROACHING_LIMIT,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = total.toDouble(),
                observedDescription = "$total $observedNoun",
                explanation = "One more Group $groups application would reach the strategy " +
                    "maximum of $limit for $disease.",
                contributing = matching,
            )

            else -> Partial(
                status = ResistanceRuleStatus.WITHIN_LIMIT,
                threshold = limit.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = total.toDouble(),
                observedDescription = "$total $observedNoun",
                explanation = "Within the strategy maximum of $limit Group $groups applications.",
                contributing = matching,
            )
        }.let { outcome ->
            if (!provisionalCeiling) return@let outcome
            when (outcome.status) {
                ResistanceRuleStatus.LIMIT_REACHED,
                ResistanceRuleStatus.WOULD_REACH_LIMIT,
                ResistanceRuleStatus.APPROACHING_LIMIT,
                -> outcome.copy(
                    status = ResistanceRuleStatus.WITHIN_LIMIT,
                    explanation = "Group $groups is within the current strategy ceiling of $limit. " +
                        "That ceiling rises if more sprays target " +
                        "${context.request.disease.label} this season.",
                )
                else -> outcome
            }
        }
    }

    // -----------------------------------------------------------------------
    // Fractions
    // -----------------------------------------------------------------------

    /**
     * Percentage restrictions, compared as exact rationals.
     *
     * ROUNDING, stated explicitly: the permitted count is the largest integer `c`
     * with `c × denominator ≤ total × numerator`, i.e. `floor(total × num / den)`.
     * Comparison never goes through a rounded display percentage, so 2 of 6 is
     * evaluated as `2 × 3 ≤ 6 × 1` — satisfied exactly — rather than as
     * "33.33% > 33%".
     */
    private fun evaluateFraction(
        rule: ResistanceRule,
        context: EvaluationContext,
        numerator: Int,
        denominator: Int,
    ): Partial {
        val matching = context.currentSeasonSequence.filter { rule.selector.matches(it) }
        val candidateId = context.candidate?.applicationId
        val historyMatching = matching.filter { it.applicationId != candidateId }
        val candidateMatches = candidateId != null && matching.any { it.applicationId == candidateId }

        val total = context.totalDiseaseSprays
        val groups = rule.selector.describedGroups.joinToString(" + ")
        val percent = (numerator * 100.0) / denominator
        val percentText = if (percent % 1.0 == 0.0) "${percent.toInt()}%" else String.format("%.1f%%", percent)
        val permitted = (total.toLong() * numerator / denominator).toInt()
        val thresholdText = "$percentText of the $total ${context.request.disease.label} " +
            "spray${if (total == 1) "" else "s"} this season ($permitted application${if (permitted == 1) "" else "s"})"

        // History-only denominator, for judging whether history alone breaches.
        val historyTotal = if (candidateId == null) total else total - 1
        val historyPermitted = (historyTotal.toLong() * numerator / denominator).toInt()

        return when {
            historyMatching.size.toLong() * denominator > historyTotal.toLong() * numerator -> Partial(
                status = ResistanceRuleStatus.LIMIT_EXCEEDED,
                threshold = historyPermitted.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = historyMatching.size.toDouble(),
                observedDescription = "${historyMatching.size} of $historyTotal sprays",
                explanation = "Group $groups accounts for ${historyMatching.size} of $historyTotal " +
                    "${context.request.disease.label} sprays, above the strategy maximum of $percentText.",
                contributing = historyMatching,
            )

            candidateMatches && matching.size.toLong() * denominator > total.toLong() * numerator -> Partial(
                status = ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
                threshold = permitted.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = matching.size.toDouble(),
                observedDescription = "${matching.size} of $total sprays including this one",
                explanation = "This would make Group $groups ${matching.size} of $total " +
                    "${context.request.disease.label} sprays, above the strategy maximum of $percentText.",
                contributing = matching,
            )

            candidateMatches && matching.size.toLong() * denominator == total.toLong() * numerator -> Partial(
                status = ResistanceRuleStatus.WOULD_REACH_LIMIT,
                threshold = permitted.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = matching.size.toDouble(),
                observedDescription = "${matching.size} of $total sprays including this one",
                explanation = "This would put Group $groups exactly on the strategy maximum of " +
                    "$percentText of ${context.request.disease.label} sprays.",
                contributing = matching,
            )

            !candidateMatches && historyMatching.isNotEmpty() &&
                historyMatching.size.toLong() * denominator == historyTotal.toLong() * numerator -> Partial(
                status = ResistanceRuleStatus.LIMIT_REACHED,
                threshold = historyPermitted.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = historyMatching.size.toDouble(),
                observedDescription = "${historyMatching.size} of $historyTotal sprays",
                explanation = "Group $groups is on the strategy maximum of $percentText of " +
                    "${context.request.disease.label} sprays.",
                contributing = historyMatching,
            )

            matching.isEmpty() -> notTriggered(rule, permitted.toDouble(), thresholdText)

            else -> Partial(
                status = ResistanceRuleStatus.WITHIN_LIMIT,
                threshold = permitted.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = matching.size.toDouble(),
                observedDescription = "${matching.size} of $total sprays",
                explanation = "Group $groups is within the strategy maximum of $percentText of " +
                    "${context.request.disease.label} sprays.",
                contributing = matching,
            )
        }
    }

    // -----------------------------------------------------------------------
    // One-in-every-N spacing
    // -----------------------------------------------------------------------

    /**
     * "One in every three sprays" as SPACING, not as a percentage.
     *
     * Deliberately distinct from [evaluateFraction]: two Group 49 sprays out of
     * six satisfies a 33% cap, but if both land inside the same window of three
     * they violate one-in-three. Treating the two as interchangeable would let a
     * back-to-back pair through on an arithmetic technicality.
     */
    private fun evaluateOneInEveryN(
        rule: ResistanceRule,
        context: EvaluationContext,
        window: Int,
    ): Partial {
        val sequence = context.currentSeasonSequence
        val groups = rule.selector.describedGroups.joinToString(" + ")
        val thresholdText = "no more than one Group $groups application in every $window " +
            "${context.request.disease.label} sprays"
        val candidateId = context.candidate?.applicationId

        var worstWindow: List<ResistanceApplicationEvent> = emptyList()
        var worstCount = 0
        var worstIncludesCandidate = false
        if (sequence.size >= 1) {
            val upper = maxOf(0, sequence.size - window)
            for (start in 0..upper) {
                val slice = sequence.subList(start, minOf(start + window, sequence.size))
                val matches = slice.filter { rule.selector.matches(it) }
                if (matches.size > worstCount) {
                    worstCount = matches.size
                    worstWindow = matches
                    worstIncludesCandidate = candidateId != null && matches.any { it.applicationId == candidateId }
                }
            }
        }

        return when {
            worstCount <= 1 && worstCount > 0 -> Partial(
                status = ResistanceRuleStatus.WITHIN_LIMIT,
                threshold = 1.0,
                thresholdDescription = thresholdText,
                observedValue = worstCount.toDouble(),
                observedDescription = "at most $worstCount in any $window consecutive sprays",
                explanation = "Group $groups spacing satisfies one in every $window sprays.",
                contributing = worstWindow,
            )

            worstCount == 0 -> notTriggered(rule, 1.0, thresholdText)

            worstIncludesCandidate -> Partial(
                status = ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
                threshold = 1.0,
                thresholdDescription = thresholdText,
                observedValue = worstCount.toDouble(),
                observedDescription = "$worstCount within $window consecutive sprays including this one",
                explanation = "This would place $worstCount Group $groups applications inside " +
                    "$window consecutive ${context.request.disease.label} sprays. The strategy " +
                    "allows one in every $window.",
                contributing = worstWindow,
            )

            else -> Partial(
                status = ResistanceRuleStatus.LIMIT_EXCEEDED,
                threshold = 1.0,
                thresholdDescription = thresholdText,
                observedValue = worstCount.toDouble(),
                observedDescription = "$worstCount within $window consecutive sprays",
                explanation = "$worstCount Group $groups applications fall inside $window " +
                    "consecutive ${context.request.disease.label} sprays. The strategy allows one " +
                    "in every $window.",
                contributing = worstWindow,
            )
        }
    }

    // -----------------------------------------------------------------------
    // Intervening different-group applications
    // -----------------------------------------------------------------------

    private fun evaluateMinIntervening(
        rule: ResistanceRule,
        context: EvaluationContext,
        required: Int,
    ): Partial {
        val sequence = context.currentSeasonSequence
        val groups = rule.selector.describedGroups.joinToString(" + ")
        val thresholdText = "at least $required applications of a different group between Group " +
            "$groups applications"
        val candidateId = context.candidate?.applicationId

        val matchingIndices = sequence.indices.filter { rule.selector.matches(sequence[it]) }
        if (matchingIndices.isEmpty()) return notTriggered(rule, required.toDouble(), thresholdText)

        var worstGap: Int? = null
        var worstPair: List<ResistanceApplicationEvent> = emptyList()
        var worstIncludesCandidate = false
        for (position in 1 until matchingIndices.size) {
            val previous = matchingIndices[position - 1]
            val current = matchingIndices[position]
            val intervening = current - previous - 1
            if (worstGap == null || intervening < worstGap) {
                worstGap = intervening
                worstPair = listOf(sequence[previous], sequence[current])
                worstIncludesCandidate = candidateId != null &&
                    worstPair.any { it.applicationId == candidateId }
            }
        }

        if (worstGap == null) {
            return Partial(
                status = ResistanceRuleStatus.WITHIN_LIMIT,
                threshold = required.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = null,
                observedDescription = "one application, no reuse to assess",
                explanation = "Group $groups has been applied once, so no intervening-group " +
                    "requirement applies yet.",
                contributing = matchingIndices.map { sequence[it] },
            )
        }

        val gap = worstGap
        return when {
            gap >= required -> Partial(
                status = ResistanceRuleStatus.WITHIN_LIMIT,
                threshold = required.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = gap.toDouble(),
                observedDescription = "$gap intervening applications at the closest reuse",
                explanation = "Group $groups reuse is separated by at least $required different-group " +
                    "applications.",
                contributing = worstPair,
            )

            worstIncludesCandidate -> Partial(
                status = ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
                threshold = required.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = gap.toDouble(),
                observedDescription = "$gap intervening applications",
                explanation = "Group $groups was used $gap ${if (gap == 1) "spray" else "sprays"} ago " +
                    "and the strategy requires at least $required applications of a different group " +
                    "before it is reapplied.",
                contributing = worstPair,
            )

            else -> Partial(
                status = ResistanceRuleStatus.LIMIT_EXCEEDED,
                threshold = required.toDouble(),
                thresholdDescription = thresholdText,
                observedValue = gap.toDouble(),
                observedDescription = "$gap intervening applications",
                explanation = "Two Group $groups applications are separated by only $gap " +
                    "different-group ${if (gap == 1) "application" else "applications"}. The strategy " +
                    "requires at least $required.",
                contributing = worstPair,
            )
        }
    }

    // -----------------------------------------------------------------------
    // Mixture requirements
    // -----------------------------------------------------------------------

    /**
     * Mixture requirements, answered honestly.
     *
     * CropLife defines a mixture as a co-formulation or a tank mix AT LABEL RATE
     * of an alternative mode of action. The rate condition is the part that
     * matters and the part group codes cannot establish: a second FRAC code in
     * the tank does not prove that partner was loaded at a rate that actually
     * controls the disease. So:
     *
     * - no alternative mode of action present at all -> NOT_SATISFIED (definitive)
     * - a partner present, adequacy unknown            -> UNKNOWN (never a pass)
     * - a partner explicitly confirmed at label rate   -> SATISFIED
     *
     * The engine will therefore usually return UNKNOWN rather than SATISFIED. That
     * is the correct answer, not a gap: claiming a resistance-strategy mixture
     * requirement was met when nothing established the partner rate would be the
     * single most dangerous false pass this engine could produce.
     */
    private fun evaluateMixture(
        rule: ResistanceRule,
        context: EvaluationContext,
        onlyWhenConsecutive: Boolean,
    ): Partial {
        val sequence = context.sequence(rule)
        val ruleGroups = rule.selector.describedGroups
        val groups = ruleGroups.joinToString(" + ")

        val scope = if (onlyWhenConsecutive) {
            maximalRuns(sequence, rule.selector).filter { it.size >= 2 }.flatten()
        } else {
            sequence.filter { rule.selector.matches(it) }
        }

        val thresholdText = if (onlyWhenConsecutive) {
            "consecutive Group $groups applications require a mixture or co-formulation with an " +
                "alternative mode of action"
        } else {
            "Group $groups must be applied in a mixture with an effective alternative mode of action"
        }

        if (scope.isEmpty()) return notTriggered(rule, null, thresholdText)

        val unmixed = scope.filter { it.groupsOtherThan(ruleGroups).isEmpty() }
        val unproven = scope.filter {
            it.groupsOtherThan(ruleGroups).isNotEmpty() && it.mixturePartnerAtLabelRate != true
        }
        val candidateId = context.candidate?.applicationId

        return when {
            unmixed.isNotEmpty() -> Partial(
                status = ResistanceRuleStatus.REQUIREMENT_NOT_MET,
                threshold = null,
                thresholdDescription = thresholdText,
                observedValue = unmixed.size.toDouble(),
                observedDescription = "${unmixed.size} application${if (unmixed.size == 1) "" else "s"} " +
                    "with no alternative mode of action",
                explanation = if (unmixed.any { it.applicationId == candidateId }) {
                    "This Group $groups application carries no alternative mode of action, and the " +
                        "strategy requires one."
                } else {
                    "${unmixed.size} Group $groups application${if (unmixed.size == 1) "" else "s"} " +
                        "carried no alternative mode of action, which the strategy requires."
                },
                contributing = unmixed,
                mixtureRequirement = ResistanceMixtureRequirement.NOT_SATISFIED,
            )

            unproven.isNotEmpty() -> Partial(
                status = ResistanceRuleStatus.REQUIREMENT_UNPROVEN,
                threshold = null,
                thresholdDescription = thresholdText,
                observedValue = unproven.size.toDouble(),
                observedDescription = "${unproven.size} application${if (unproven.size == 1) "" else "s"} " +
                    "with an unconfirmed mixture partner",
                explanation = "A different mode of action was present alongside Group $groups, but " +
                    "VineTrack cannot confirm it was applied at an effective rate, so the mixture " +
                    "requirement cannot be confirmed from the recorded data.",
                contributing = unproven,
                mixtureRequirement = ResistanceMixtureRequirement.UNKNOWN,
            )

            else -> Partial(
                status = ResistanceRuleStatus.WITHIN_LIMIT,
                threshold = null,
                thresholdDescription = thresholdText,
                observedValue = scope.size.toDouble(),
                observedDescription = "${scope.size} application${if (scope.size == 1) "" else "s"} mixed",
                explanation = "Group $groups was applied with a confirmed alternative mode of action.",
                contributing = scope,
                mixtureRequirement = ResistanceMixtureRequirement.SATISFIED,
            )
        }
    }

    // -----------------------------------------------------------------------
    // Last spray of season
    // -----------------------------------------------------------------------

    /**
     * "Do not apply Group 40 as the last spray of the season."
     *
     * Reported as guidance rather than as a breach, because whether a spray is the
     * LAST of a season is unknowable until the season ends. Calling it a breach
     * would flag every mid-season Group 40 spray simply for being the most recent
     * one, which would train operators to ignore the warning.
     */
    private fun evaluateNotLastSpray(rule: ResistanceRule, context: EvaluationContext): Partial {
        val groups = rule.selector.describedGroups.joinToString(" + ")
        val thresholdText = "Group $groups should not be the last spray of the season"
        val last = context.currentSeasonSequence.lastOrNull()
            ?: return notTriggered(rule, null, thresholdText)

        if (!rule.selector.matches(last)) {
            return Partial(
                status = ResistanceRuleStatus.WITHIN_LIMIT,
                threshold = null,
                thresholdDescription = thresholdText,
                observedValue = null,
                observedDescription = "the most recent spray does not contain Group $groups",
                explanation = "The most recent ${context.request.disease.label} spray does not " +
                    "contain Group $groups.",
                contributing = emptyList(),
            )
        }

        val isCandidate = last.applicationId == context.candidate?.applicationId
        return Partial(
            status = ResistanceRuleStatus.GUIDANCE,
            threshold = null,
            thresholdDescription = thresholdText,
            observedValue = null,
            observedDescription = "currently the final ${context.request.disease.label} spray of the season",
            explanation = if (isCandidate) {
                "The strategy advises against Group $groups as the last spray of the season. If no " +
                    "further ${context.request.disease.label} spray follows this one, that advice " +
                    "would not be met."
            } else {
                "Group $groups is currently the final ${context.request.disease.label} spray of the " +
                    "season. The strategy advises the season should not end on Group $groups."
            },
            contributing = listOf(last),
            isGuidance = true,
        )
    }

    // -----------------------------------------------------------------------
    // Total-spray-count table
    // -----------------------------------------------------------------------

    /**
     * The Powdery table, whose ceiling MOVES with the season's total spray count.
     *
     * UNKNOWN FUTURE TOTALS, stated explicitly: for candidate evaluation the
     * engine uses the total it can actually see — applied history plus the
     * candidate — and reports the ceiling at that total. It never invents future
     * sprays to unlock a higher ceiling. A season that later grows longer may
     * legitimately permit more, and re-evaluating then will say so; the Planner
     * will be able to surface that projection, but the engine will not
     * pre-emptively assume a spray nobody has planned.
     */
    private fun evaluateTable(
        rule: ResistanceRule,
        context: EvaluationContext,
        columnKey: String,
    ): Partial {
        val table = context.ruleset.maxUseTable
        val column = table?.column(columnKey)
        val groups = rule.selector.describedGroups.joinToString(" + ")
        if (table == null || column == null) {
            return Partial(
                status = ResistanceRuleStatus.UNABLE_TO_ASSESS,
                threshold = null,
                thresholdDescription = "maximum-use table unavailable",
                observedValue = null,
                observedDescription = "not assessed",
                explanation = "The strategy's maximum-use table is not available for Group $groups.",
                contributing = emptyList(),
            )
        }

        val total = context.totalDiseaseSprays
        val limit = table.maxFor(columnKey, total)
            ?: return notTriggered(rule, null, "no published maximum at $total sprays")

        val matching = context.currentSeasonSequence.filter { rule.selector.matches(it) }
        val thresholdText = "a maximum of $limit Group ${column.displayName} " +
            "application${if (limit == 1) "" else "s"} when $total ${context.request.disease.label} " +
            "spray${if (total == 1) "" else "s"} are applied"

        // The ceiling stops moving once the total reaches the table's open-ended
        // final row (CropLife's 9+), after which reached/approaching are real.
        val openEnded = table.rows.firstOrNull { it.isOrMore }
        val provisional = openEnded != null && total < openEnded.totalSprays

        return countOutcome(
            rule = rule,
            context = context,
            matching = matching,
            limit = limit,
            thresholdText = thresholdText,
            groups = column.displayName,
            observedNoun = "applications",
            provisionalCeiling = provisional,
        )
    }

    // -----------------------------------------------------------------------
    // Guidance
    // -----------------------------------------------------------------------

    private fun evaluateGuidance(rule: ResistanceRule, context: EvaluationContext): Partial = Partial(
        status = ResistanceRuleStatus.GUIDANCE,
        threshold = null,
        thresholdDescription = "published guidance, no numeric limit",
        observedValue = null,
        observedDescription = "informational",
        explanation = rule.sourceText,
        contributing = emptyList(),
        isGuidance = true,
    )

    private fun notTriggered(
        rule: ResistanceRule,
        threshold: Double?,
        thresholdText: String,
    ): Partial = Partial(
        status = ResistanceRuleStatus.NOT_TRIGGERED,
        threshold = threshold,
        thresholdDescription = thresholdText,
        observedValue = 0.0,
        observedDescription = "no matching applications",
        explanation = "Group ${rule.selector.describedGroups.joinToString(" + ")} does not appear " +
            "in this history.",
        contributing = emptyList(),
    )

    // -----------------------------------------------------------------------
    // Availability gating and packaging
    // -----------------------------------------------------------------------

    /**
     * Applies Chemical Intelligence availability to a computed result.
     *
     * A breach computed from known chemistry SURVIVES gating — an unverified
     * Group 11 sequence that appears to exceed the published maximum is still
     * worth telling the operator about, qualified by its evidence.
     *
     * A non-breach does NOT survive gating when any application in scope has
     * conflicting or missing chemistry, because that application might have
     * contained the very group being counted. This is where
     * `chemicalSnapshot == nil` is prevented from meaning "no resistance issue".
     */
    private fun finalise(
        rule: ResistanceRule,
        context: EvaluationContext,
        partial: Partial,
    ): ResistanceRuleResult {
        val scope = context.sequence(rule)
        val opaque = scope.filter { !it.canAssessChemistry }
        val unattributed = context.unattributedInSeason

        var status = partial.status
        var explanation = partial.explanation
        var contributing = partial.contributing

        val blocked = opaque.isNotEmpty() || unattributed.isNotEmpty()
        if (blocked && !partial.isGuidance && !partial.status.isBreach &&
            partial.status != ResistanceRuleStatus.REQUIREMENT_UNPROVEN
        ) {
            status = ResistanceRuleStatus.UNABLE_TO_ASSESS
            val reasons = mutableListOf<String>()
            if (opaque.isNotEmpty()) {
                reasons += "${opaque.size} application${if (opaque.size == 1) "" else "s"} " +
                    "with missing or disputed chemistry"
            }
            if (unattributed.isNotEmpty()) {
                reasons += "${unattributed.size} application${if (unattributed.size == 1) "" else "s"} " +
                    "with no recorded target disease"
            }
            explanation = "This rule cannot be assessed: ${reasons.joinToString(" and ")} could " +
                "change the result. The recorded groups alone show " +
                "${partial.observedDescription}."
            contributing = (partial.contributing + opaque + unattributed).distinctBy { it.applicationId }
        }

        val evidence = ruleEvidence(scope, opaque, unattributed, partial)

        var qualified = explanation
        if (evidence == ResistanceEvidenceQuality.QUALIFIED && status.isBreach) {
            qualified = "$explanation This is based on recorded groups that have not been " +
                "independently verified."
        }

        return ResistanceRuleResult(
            ruleId = rule.id,
            rulesetId = context.ruleset.id,
            rulesetVersion = context.ruleset.rulesetVersion,
            disease = context.request.disease,
            blockId = context.request.blockId,
            status = status,
            severity = severityFor(status),
            groups = rule.selector.describedGroups,
            threshold = partial.threshold,
            thresholdDescription = partial.thresholdDescription,
            observedValue = partial.observedValue,
            observedDescription = partial.observedDescription,
            explanation = qualified,
            contributingApplicationIds = contributing.map { it.applicationId },
            contributingDatesEpochMs = contributing.map { it.appliedAtEpochMs },
            evidenceQuality = evidence,
            mixtureRequirement = partial.mixtureRequirement,
            sourceReference = rule.sourceReference,
            sourceText = rule.sourceText,
        )
    }

    private fun ruleEvidence(
        scope: List<ResistanceApplicationEvent>,
        opaque: List<ResistanceApplicationEvent>,
        unattributed: List<ResistanceApplicationEvent>,
        partial: Partial,
    ): ResistanceEvidenceQuality {
        if (partial.isGuidance) return ResistanceEvidenceQuality.HIGH
        if (opaque.isNotEmpty() || unattributed.isNotEmpty()) {
            return ResistanceEvidenceQuality.INDETERMINATE
        }
        val relevant = if (partial.contributing.isNotEmpty()) partial.contributing else scope
        if (relevant.isEmpty()) return ResistanceEvidenceQuality.HIGH
        return if (relevant.all { it.availability.isDependable }) {
            ResistanceEvidenceQuality.HIGH
        } else {
            ResistanceEvidenceQuality.QUALIFIED
        }
    }

    private fun severityFor(status: ResistanceRuleStatus): ResistanceSeverity = when (status) {
        ResistanceRuleStatus.LIMIT_EXCEEDED,
        ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
        ResistanceRuleStatus.REQUIREMENT_NOT_MET,
        -> ResistanceSeverity.CRITICAL

        ResistanceRuleStatus.LIMIT_REACHED,
        ResistanceRuleStatus.WOULD_REACH_LIMIT,
        -> ResistanceSeverity.WARNING

        ResistanceRuleStatus.UNABLE_TO_ASSESS,
        ResistanceRuleStatus.REQUIREMENT_UNPROVEN,
        -> ResistanceSeverity.INDETERMINATE

        ResistanceRuleStatus.APPROACHING_LIMIT -> ResistanceSeverity.ADVISORY
        ResistanceRuleStatus.GUIDANCE -> ResistanceSeverity.INFORMATIONAL
        ResistanceRuleStatus.WITHIN_LIMIT, ResistanceRuleStatus.NOT_TRIGGERED -> ResistanceSeverity.INFORMATIONAL
    }

    // -----------------------------------------------------------------------
    // Aggregation
    // -----------------------------------------------------------------------

    private fun overallStatus(
        results: List<ResistanceRuleResult>,
        unassessable: List<String>,
        unattributed: List<ResistanceApplicationEvent>,
    ): ResistanceEvaluationStatus = when {
        results.any { it.status.isBreach } -> ResistanceEvaluationStatus.STRATEGY_EXCEEDED
        unassessable.isNotEmpty() || unattributed.isNotEmpty() ->
            ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS
        results.any { it.status == ResistanceRuleStatus.UNABLE_TO_ASSESS } ->
            ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS
        results.any { it.status == ResistanceRuleStatus.REQUIREMENT_UNPROVEN } ->
            ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS
        results.any { it.status.isAtLimit } -> ResistanceEvaluationStatus.LIMIT_REACHED
        // Escalate the overall status only once at least two applications have
        // accumulated. A single Group 3 spray is one step from a limit of two, but
        // calling a season "approaching a limit" after its first spray would make
        // the status meaningless and train operators to ignore it. The rule-level
        // APPROACHING_LIMIT detail is still reported for the Planner.
        results.any {
            it.status == ResistanceRuleStatus.APPROACHING_LIMIT && (it.observedValue ?: 0.0) >= 2.0
        } -> ResistanceEvaluationStatus.APPROACHING_LIMIT
        else -> ResistanceEvaluationStatus.COMPLIANT
    }

    private fun overallEvidence(
        sequence: List<ResistanceApplicationEvent>,
        unattributed: List<ResistanceApplicationEvent>,
    ): ResistanceEvidenceQuality = when {
        unattributed.isNotEmpty() || sequence.any { !it.canAssessChemistry } ->
            ResistanceEvidenceQuality.INDETERMINATE
        sequence.all { it.availability.isDependable } -> ResistanceEvidenceQuality.HIGH
        else -> ResistanceEvidenceQuality.QUALIFIED
    }

    /**
     * The operator-facing sentence.
     *
     * A clean arithmetic result over unverified chemistry is never reported as
     * "all good" — it is reported as what it actually is: no limit detected USING
     * THE RECORDED GROUPS, with the quality of those groups stated.
     */
    private fun summarise(
        status: ResistanceEvaluationStatus,
        evidence: ResistanceEvidenceQuality,
        results: List<ResistanceRuleResult>,
        disease: ResistanceDisease,
        unattributedCount: Int,
    ): String {
        val label = disease.label
        return when (status) {
            ResistanceEvaluationStatus.STRATEGY_EXCEEDED -> {
                val breach = results.first { it.status.isBreach }
                val prefix = "Resistance strategy warning: ${breach.explanation}"
                if (evidence == ResistanceEvidenceQuality.INDETERMINATE) {
                    "$prefix Other applications could not be assessed, so the full picture may be worse."
                } else {
                    prefix
                }
            }

            ResistanceEvaluationStatus.LIMIT_REACHED -> {
                val reached = results.first { it.status.isAtLimit }
                "CropLife strategy maximum reached: ${reached.explanation}"
            }

            ResistanceEvaluationStatus.APPROACHING_LIMIT -> {
                val near = results.first { it.status == ResistanceRuleStatus.APPROACHING_LIMIT }
                "Approaching a CropLife strategy limit: ${near.explanation}"
            }

            ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS -> {
                val reasons = mutableListOf<String>()
                if (unattributedCount > 0) {
                    reasons += "$unattributedCount application${if (unattributedCount == 1) "" else "s"} " +
                        "have no recorded target disease"
                }
                if (results.any { it.status == ResistanceRuleStatus.UNABLE_TO_ASSESS }) {
                    reasons += "chemistry is missing or disputed on one or more applications"
                }
                if (results.any { it.status == ResistanceRuleStatus.REQUIREMENT_UNPROVEN }) {
                    reasons += "a required mixture cannot be confirmed from the recorded data"
                }
                "Unable to fully assess the $label resistance strategy for this block: " +
                    "${reasons.joinToString("; ")}. No clean result can be given."
            }

            ResistanceEvaluationStatus.COMPLIANT -> when (evidence) {
                ResistanceEvidenceQuality.HIGH ->
                    "No $label resistance strategy limit is reached for this block."
                ResistanceEvidenceQuality.QUALIFIED ->
                    "No strategy limit detected using the recorded groups; one or more chemical " +
                        "records are unverified."
                ResistanceEvidenceQuality.INDETERMINATE ->
                    "No strategy limit detected using the recorded groups, but some applications " +
                        "could not be assessed."
            }

            ResistanceEvaluationStatus.NOT_APPLICABLE ->
                "No applications targeting $label are recorded for this block this season."

            ResistanceEvaluationStatus.UNSUPPORTED_RULESET ->
                "A VineTrack resistance strategy is not yet configured for this jurisdiction."
        }
    }

    // -----------------------------------------------------------------------
    // Early exits
    // -----------------------------------------------------------------------

    /**
     * No strategy for this jurisdiction.
     *
     * Australian maximum-use rules are NOT applied as a fallback. A New Zealand
     * vineyard assessed against CropLife Australia limits would be given
     * confident, specific, wrong advice, which is worse than no advice.
     */
    private fun unsupported(request: ResistanceEvaluationRequest) = ResistanceEvaluation(
        status = ResistanceEvaluationStatus.UNSUPPORTED_RULESET,
        jurisdiction = request.jurisdiction,
        crop = request.crop,
        disease = request.disease,
        blockId = request.blockId,
        seasonId = request.season.id,
        rulesetId = null,
        rulesetVersion = null,
        rulesetValidFrom = null,
        ruleResults = emptyList(),
        totalDiseaseSpraysInSeason = 0,
        consideredApplicationIds = emptyList(),
        unassessableApplicationIds = emptyList(),
        unattributedApplicationIds = emptyList(),
        excludedPlannedApplicationIds = emptyList(),
        evidenceQuality = ResistanceEvidenceQuality.INDETERMINATE,
        summary = "A VineTrack resistance strategy is not yet configured for this jurisdiction.",
        candidateApplicationId = request.candidate?.applicationId,
    )

    private fun notApplicable(
        request: ResistanceEvaluationRequest,
        ruleset: ResistanceRuleset,
        excludedPlanned: List<ResistanceApplicationEvent>,
    ) = ResistanceEvaluation(
        status = ResistanceEvaluationStatus.NOT_APPLICABLE,
        jurisdiction = request.jurisdiction,
        crop = request.crop,
        disease = request.disease,
        blockId = request.blockId,
        seasonId = request.season.id,
        rulesetId = ruleset.id,
        rulesetVersion = ruleset.rulesetVersion,
        rulesetValidFrom = ruleset.validFrom,
        ruleResults = emptyList(),
        totalDiseaseSpraysInSeason = 0,
        consideredApplicationIds = emptyList(),
        unassessableApplicationIds = emptyList(),
        unattributedApplicationIds = emptyList(),
        excludedPlannedApplicationIds = excludedPlanned.map { it.applicationId },
        evidenceQuality = ResistanceEvidenceQuality.HIGH,
        summary = "No applications targeting ${request.disease.label} are recorded for this block " +
            "this season.",
        candidateApplicationId = request.candidate?.applicationId,
    )
}
