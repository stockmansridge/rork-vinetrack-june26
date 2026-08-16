package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability

/**
 * The Resistance Planner's screen-facing state, built as PURE DATA.
 *
 * Compose renders this and does nothing else. Every count, label and ordering decision
 * is made here so it can be asserted in a plain JVM unit test — a composable that decides
 * "show the per-block breakdown" or "call this Good fit" is a decision nobody can test
 * without an emulator, and an untested presentation layer is exactly where a block's
 * breach would quietly disappear behind a better block.
 *
 * Nothing in this file evaluates a resistance rule. It reads [ResistancePlanEvaluation],
 * which came from [ResistanceEngine] via [ResistancePlanner].
 *
 * Mirrors the information hierarchy of `ResistancePlannerView.swift`.
 */

/** One selectable block chip. */
data class ResistancePlannerBlockChoice(
    val id: String,
    val name: String,
    val isSelected: Boolean,
)

/** One selectable season, identified as a span (`2026/27`) and never a bare year. */
data class ResistancePlannerSeasonChoice(
    val startYear: Int,
    val id: String,
    val isSelected: Boolean,
)

/** One block's history-completeness row. */
data class ResistancePlannerHistoryRow(
    val blockId: String,
    val blockName: String,
    val headline: String,
    /**
     * Each kind of uncertainty on its OWN line. Deliberately not collapsed into a
     * single "history may be incomplete": an unattributed spray, a missing disease
     * target and unverified chemistry need three different fixes, and one generic
     * warning tells the grower none of them.
     */
    val detailLines: List<String>,
    val isCompleteEnoughToAssess: Boolean,
    val concerns: List<ResistanceHistoryConcern>,
)

/** The vineyard-level unattributed-history summary. */
data class ResistancePlannerUnresolvedSummary(
    val count: Int,
    val headline: String,
    val body: String,
    /** Shown only on request, so years of legacy history never bury the plan. */
    val detail: String,
)

/** One completed application on the timeline. */
data class ResistancePlannerTimelineRow(
    val applicationId: String,
    val ordinal: Int,
    val dateLabel: String,
    /** FRAC identity leads; the brand is supporting detail. */
    val groupsLabel: String,
    val productLine: String?,
    val availability: ChemicalIntelligenceAvailability,
    val availabilityMark: String,
    val completedLabel: String = "Completed",
)

/** One block's completed season history. */
data class ResistancePlannerTimeline(
    val blockId: String,
    val blockName: String,
    val countLabel: String,
    /** Non-null only when the block has no relevant history. */
    val emptyLabel: String?,
    val rows: List<ResistancePlannerTimelineRow>,
)

/** One explainable engine finding, formatted. */
data class ResistancePlannerFinding(
    val ruleId: String,
    val blockName: String,
    val title: String,
    val explanation: String,
    /** Observed vs threshold, so the operator can check the claim rather than trust it. */
    val observedLine: String,
    val contributingLine: String?,
    /**
     * Non-null when the engine reported [ResistanceMixtureRequirement.UNKNOWN]. The UI
     * NEVER decides this for itself — two FRAC groups in a tank does not establish that
     * a partner goes in at an effective rate.
     */
    val mixtureUnconfirmedLabel: String?,
    val sourceLine: String,
)

/** One block's status inside a planned position. */
data class ResistancePlannerBlockStatus(
    val blockId: String,
    val blockName: String,
    val status: ResistancePlanPositionStatus,
    val statusLabel: String,
)

/** One planned position card. */
data class ResistancePlannerPosition(
    val positionId: String,
    val index: Int,
    /** Display ordinal continuing the season's completed sprays, e.g. `"Spray 4"`. */
    val ordinalLabel: String,
    val chemistryLabel: String,
    val timingLabel: String?,
    val status: ResistancePlanPositionStatus,
    val statusLabel: String,
    val awaitingChemistryHint: String?,
    /** Caveats from unverified or conflicting chosen products. */
    val productCaveats: List<String>,
    /**
     * Per-block rows, populated ONLY when the blocks disagree.
     *
     * When they disagree the summary badge alone would hide a real breach behind a
     * better block, so the breakdown is not optional in that case.
     */
    val blockBreakdown: List<ResistancePlannerBlockStatus>,
    val blocksDisagree: Boolean,
    val findings: List<ResistancePlannerFinding>,
    val canMoveUp: Boolean,
    val canMoveDown: Boolean,
)

/** One block's season totals. */
data class ResistancePlannerTotals(
    val blockId: String,
    val blockName: String,
    val sprayCountLabel: String,
    val groupLines: List<String>,
)

/** The published strategy behind every verdict on the screen. */
data class ResistancePlannerStrategy(
    val organisation: String?,
    val strategyName: String?,
    val validFromLabel: String?,
    val rulesetVersionLabel: String?,
    /** Non-null when a newer strategy is in force than the one this plan recorded. */
    val outdatedWarning: String?,
)

/** Everything the Planner screen renders. */
data class ResistancePlannerUiState(
    val seasonId: String,
    val seasonChoices: List<ResistancePlannerSeasonChoice>,
    val disease: ResistanceDisease,
    val diseaseChoices: List<ResistanceDisease>,
    val diseaseNote: String,
    /** False when no VineTrack strategy exists for the vineyard's jurisdiction. */
    val isSupported: Boolean,
    val unsupportedMessage: String?,
    val unsupportedDetail: String?,
    val blocks: List<ResistancePlannerBlockChoice>,
    val blocksEmptyLabel: String?,
    val hasSelectedBlocks: Boolean,
    val chooseBlocksPrompt: String?,
    val historyRows: List<ResistancePlannerHistoryRow>,
    val unresolvedSummary: ResistancePlannerUnresolvedSummary?,
    val timelines: List<ResistancePlannerTimeline>,
    val positions: List<ResistancePlannerPosition>,
    val positionsEmptyLabel: String?,
    val totals: List<ResistancePlannerTotals>,
    val strategy: ResistancePlannerStrategy?,
    val localOnlyNotice: String,
)

object ResistancePlannerPresentation {

    const val MIXTURE_UNCONFIRMED_LABEL = "Mixture requirement cannot be fully confirmed"

    const val CHOOSE_BLOCKS_PROMPT =
        "Select at least one block to see its recorded history and plan a sequence."

    const val NO_POSITIONS_LABEL =
        "No planned positions yet. Add one to start building the sequence."

    const val AWAITING_CHEMISTRY_HINT = "Choose a FRAC group to evaluate this position."

    const val NO_BLOCKS_LABEL = "This vineyard has no blocks yet."

    const val BLOCKS_NEVER_MERGED_NOTE =
        "Each block is assessed against its own history. Selecting several never merges them."

    const val DISEASE_NOTE =
        "One disease is planned at a time. A spray recorded against both diseases still counts in both histories."

    /**
     * Said out loud rather than implied, so nobody reads the Australian strategy as a
     * sensible default for another country's label conditions.
     */
    const val UNSUPPORTED_DETAIL =
        "VineTrack applies a published strategy only where one has been configured for the vineyard's country. No resistance limits are being evaluated."

    const val STRATEGY_OUTDATED_WARNING =
        "A newer resistance strategy is available — review this plan."

    const val UNKNOWN_BLOCK_NAME = "Unknown block"

    /** How many past seasons a grower may plan against, plus the season ahead. */
    private const val PAST_SEASONS_SELECTABLE = 4

    /**
     * Selectable seasons, newest first: the four completed seasons, the current one and
     * the season ahead.
     *
     * The season ahead matters — the whole point of the tool is deciding a rotation
     * before the season starts.
     */
    fun seasonChoices(
        currentStartYear: Int,
        selectedStartYear: Int,
    ): List<ResistancePlannerSeasonChoice> =
        ((currentStartYear - PAST_SEASONS_SELECTABLE)..(currentStartYear + 1))
            .reversed()
            .map { year ->
                ResistancePlannerSeasonChoice(
                    startYear = year,
                    id = ResistanceSeasonCalendar.seasonId(year),
                    isSelected = year == selectedStartYear,
                )
            }

    /**
     * Builds the whole screen state.
     *
     * @param blockNames every block in the vineyard, in display order, as id to name.
     * @param formatDate injected so this stays a pure function with no platform locale.
     */
    fun state(
        plan: ResistancePlan,
        evaluation: ResistancePlanEvaluation,
        blockNames: List<Pair<String, String>>,
        currentSeasonStartYear: Int,
        registry: ResistanceRulesetRegistry = ResistanceRulesets.registry,
        formatDate: (Long) -> String,
    ): ResistancePlannerUiState {
        val resolve: (String) -> String = { id -> blockName(id, blockNames) }
        val hasBlocks = plan.blockIds.isNotEmpty()

        if (!evaluation.isSupported) {
            // An unsupported jurisdiction shows the season and disease pickers and
            // nothing else. Rendering an empty plan below the notice would invite the
            // grower to build a sequence no strategy is going to assess.
            return ResistancePlannerUiState(
                seasonId = plan.seasonId,
                seasonChoices = seasonChoices(currentSeasonStartYear, plan.seasonStartYear),
                disease = plan.disease,
                diseaseChoices = ResistanceDisease.entries.toList(),
                diseaseNote = DISEASE_NOTE,
                isSupported = false,
                unsupportedMessage = evaluation.unsupportedMessage
                    ?: ResistancePlanner.UNSUPPORTED_JURISDICTION_MESSAGE,
                unsupportedDetail = UNSUPPORTED_DETAIL,
                blocks = emptyList(),
                blocksEmptyLabel = null,
                hasSelectedBlocks = false,
                chooseBlocksPrompt = null,
                historyRows = emptyList(),
                unresolvedSummary = null,
                timelines = emptyList(),
                positions = emptyList(),
                positionsEmptyLabel = null,
                totals = emptyList(),
                strategy = null,
                localOnlyNotice = ResistancePlanStore.LOCAL_ONLY_NOTICE,
            )
        }

        return ResistancePlannerUiState(
            seasonId = plan.seasonId,
            seasonChoices = seasonChoices(currentSeasonStartYear, plan.seasonStartYear),
            disease = plan.disease,
            diseaseChoices = ResistanceDisease.entries.toList(),
            diseaseNote = DISEASE_NOTE,
            isSupported = true,
            unsupportedMessage = null,
            unsupportedDetail = null,
            blocks = blockNames.map { (id, name) ->
                ResistancePlannerBlockChoice(
                    id = id,
                    name = name,
                    isSelected = plan.blockIds.contains(id),
                )
            },
            blocksEmptyLabel = if (blockNames.isEmpty()) NO_BLOCKS_LABEL else null,
            hasSelectedBlocks = hasBlocks,
            chooseBlocksPrompt = if (hasBlocks) null else CHOOSE_BLOCKS_PROMPT,
            historyRows = if (hasBlocks) {
                evaluation.historyChecks.map { historyRow(it, plan.disease, resolve) }
            } else {
                emptyList()
            },
            unresolvedSummary = unresolvedSummary(evaluation.unresolvedApplicationCount)
                .takeIf { hasBlocks },
            timelines = if (hasBlocks) {
                evaluation.timelines.map { timeline(it, plan.disease, resolve, formatDate) }
            } else {
                emptyList()
            },
            positions = if (hasBlocks) {
                evaluation.positions.map {
                    position(it, plan, evaluation.positions.size, resolve, formatDate)
                }
            } else {
                emptyList()
            },
            positionsEmptyLabel = if (hasBlocks && evaluation.positions.isEmpty()) {
                NO_POSITIONS_LABEL
            } else {
                null
            },
            totals = if (hasBlocks) {
                evaluation.seasonTotals.map { totals(it, plan.disease, resolve) }
            } else {
                emptyList()
            },
            strategy = if (hasBlocks) strategy(evaluation, plan, registry) else null,
            localOnlyNotice = ResistancePlanStore.LOCAL_ONLY_NOTICE,
        )
    }

    // -----------------------------------------------------------------------
    // Sections
    // -----------------------------------------------------------------------

    fun historyRow(
        check: ResistanceBlockHistoryCheck,
        disease: ResistanceDisease,
        blockName: (String) -> String,
    ): ResistancePlannerHistoryRow = ResistancePlannerHistoryRow(
        blockId = check.blockId,
        blockName = blockName(check.blockId),
        headline = check.headline(disease),
        detailLines = historyDetailLines(check),
        isCompleteEnoughToAssess = check.isCompleteEnoughToAssess,
        concerns = check.concerns,
    )

    /** One line per named kind of uncertainty, in worst-first order. */
    fun historyDetailLines(check: ResistanceBlockHistoryCheck): List<String> = buildList {
        if (check.relevantApplicationCount > 0) {
            add("${check.relevantApplicationCount} relevant ${plural("application", check.relevantApplicationCount)} this season")
        }
        if (check.unresolvedVineyardApplicationCount > 0) {
            add("${check.unresolvedVineyardApplicationCount} older spray ${plural("record", check.unresolvedVineyardApplicationCount)} cannot be assigned to a block")
        }
        if (check.unknownTargetCount > 0) {
            add("${check.unknownTargetCount} ${plural("spray", check.unknownTargetCount)} with no recorded disease target")
        }
        if (check.conflictingCount > 0) {
            add("${check.conflictingCount} ${plural("application", check.conflictingCount)} with conflicting chemistry")
        }
        if (check.unavailableCount > 0) {
            add("${check.unavailableCount} ${plural("application", check.unavailableCount)} with no usable chemistry")
        }
        if (check.unverifiedCount > 0) {
            add("${check.unverifiedCount} ${plural("application", check.unverifiedCount)} with unverified chemistry")
        }
    }

    fun unresolvedSummary(count: Int): ResistancePlannerUnresolvedSummary? {
        if (count <= 0) return null
        return ResistancePlannerUnresolvedSummary(
            count = count,
            headline = "Resistance history incomplete",
            body = "$count older ${plural("spray", count)} in this vineyard cannot be assigned to individual blocks, so VineTrack cannot confirm that every strategy limit is still available for these blocks.",
            detail = "These applications happened somewhere in this vineyard. Because the treated blocks were never recorded, they are not assigned to any block — and not assumed to be absent from one either.",
        )
    }

    fun timeline(
        timeline: ResistancePlanBlockTimeline,
        disease: ResistanceDisease,
        blockName: (String) -> String,
        formatDate: (Long) -> String,
    ): ResistancePlannerTimeline = ResistancePlannerTimeline(
        blockId = timeline.blockId,
        blockName = blockName(timeline.blockId),
        countLabel = "${timeline.entries.size} relevant ${plural("application", timeline.entries.size)}",
        emptyLabel = if (timeline.entries.isEmpty()) {
            "No recorded ${disease.label} sprays this season"
        } else {
            null
        },
        rows = timeline.entries.mapIndexed { index, entry ->
            ResistancePlannerTimelineRow(
                applicationId = entry.applicationId,
                ordinal = index + 1,
                dateLabel = formatDate(entry.appliedAtEpochMs),
                groupsLabel = entry.groupsLabel,
                productLine = entry.productNames.takeIf { it.isNotEmpty() }?.joinToString(", "),
                availability = entry.availability,
                availabilityMark = entry.availability.plannerMark,
            )
        },
    )

    fun position(
        evaluation: ResistancePlanPositionEvaluation,
        plan: ResistancePlan,
        positionCount: Int,
        blockName: (String) -> String,
        formatDate: (Long) -> String,
    ): ResistancePlannerPosition {
        val position = plan.position(evaluation.positionId)
        return ResistancePlannerPosition(
            positionId = evaluation.positionId,
            index = evaluation.index,
            ordinalLabel = "Spray ${evaluation.displayOrdinal}",
            chemistryLabel = position?.groupsLabel ?: "No chemistry selected",
            timingLabel = position?.let { timingLabel(it, formatDate) },
            status = evaluation.status,
            statusLabel = evaluation.status.label,
            awaitingChemistryHint = AWAITING_CHEMISTRY_HINT.takeIf { evaluation.awaitingChemistry },
            productCaveats = position?.productsRequiringCaveat?.map { product ->
                "${product.displayLabel}: recorded as ${product.groups.displayLabel} — ${product.effectiveAvailability.label.lowercase()}"
            } ?: emptyList(),
            blockBreakdown = if (evaluation.blocksDisagree) {
                evaluation.blocks.map {
                    ResistancePlannerBlockStatus(
                        blockId = it.blockId,
                        blockName = blockName(it.blockId),
                        status = it.status,
                        statusLabel = it.status.label,
                    )
                }
            } else {
                emptyList()
            },
            blocksDisagree = evaluation.blocksDisagree,
            findings = evaluation.blocks.flatMap { outcome ->
                outcome.evaluation.findings.map { finding(it, blockName(outcome.blockId), formatDate) }
            },
            canMoveUp = evaluation.index > 0,
            canMoveDown = evaluation.index < positionCount - 1,
        )
    }

    fun timingLabel(
        position: ResistancePlannedPosition,
        formatDate: (Long) -> String,
    ): String? {
        val parts = buildList {
            position.targetDateEpochMs?.let { add("Target ${formatDate(it)}") }
            position.growthStage?.takeIf { it.isNotBlank() }?.let { add(it) }
        }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" • ")
    }

    fun finding(
        result: ResistanceRuleResult,
        blockName: String,
        formatDate: (Long) -> String,
    ): ResistancePlannerFinding = ResistancePlannerFinding(
        ruleId = result.ruleId,
        blockName = blockName,
        title = "$blockName — ${result.thresholdDescription.capitalizeFirst()}",
        explanation = result.explanation,
        observedLine = "Observed: ${result.observedDescription}. Strategy: ${result.thresholdDescription}.",
        contributingLine = result.contributingDatesEpochMs
            .takeIf { it.isNotEmpty() }
            ?.let { "Contributing: " + it.joinToString(", ") { date -> formatDate(date) } },
        mixtureUnconfirmedLabel = MIXTURE_UNCONFIRMED_LABEL
            .takeIf { result.mixtureRequirement == ResistanceMixtureRequirement.UNKNOWN },
        sourceLine = "${result.sourceReference} • ${result.rulesetId} ${result.rulesetVersion}",
    )

    fun totals(
        totals: ResistanceBlockSeasonTotals,
        disease: ResistanceDisease,
        blockName: (String) -> String,
    ): ResistancePlannerTotals = ResistancePlannerTotals(
        blockId = totals.blockId,
        blockName = blockName(totals.blockId),
        sprayCountLabel = "${disease.label} sprays this season: ${totals.diseaseSprayCount}",
        groupLines = totals.orderedGroups.map { group ->
            "FRAC $group applications: ${totals.applicationsByGroup[group] ?: 0}"
        },
    )

    fun strategy(
        evaluation: ResistancePlanEvaluation,
        plan: ResistancePlan,
        registry: ResistanceRulesetRegistry,
    ): ResistancePlannerStrategy = ResistancePlannerStrategy(
        organisation = evaluation.sourceOrganisation,
        strategyName = evaluation.strategyName,
        validFromLabel = evaluation.rulesetValidFrom?.let { "Valid $it" },
        rulesetVersionLabel = evaluation.rulesetVersion?.let { "Ruleset: $it" },
        outdatedWarning = STRATEGY_OUTDATED_WARNING.takeIf { plan.isStrategyOutdated(registry) },
    )

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /**
     * Current live name, falling back to a stable stand-in for a block that has since
     * been removed. Matches the spray-export display rule.
     */
    fun blockName(blockId: String, blockNames: List<Pair<String, String>>): String =
        blockNames.firstOrNull { it.first.equals(blockId, ignoreCase = true) }?.second
            ?: UNKNOWN_BLOCK_NAME

    private fun plural(word: String, count: Int): String = if (count == 1) word else "${word}s"

    private fun String.capitalizeFirst(): String =
        if (isEmpty()) this else substring(0, 1).uppercase() + substring(1)
}

/**
 * Verification mark for a product's chemistry.
 *
 * Lives in the domain rather than in each platform's view so the two phones cannot drift
 * to different symbols for the same evidence state — a grower comparing an iPhone and an
 * Android in the same shed must not see one product marked differently on each.
 */
val ChemicalIntelligenceAvailability.plannerMark: String
    get() = when (this) {
        ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED -> "✓ Verified"
        ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED -> "◐ Partially Verified"
        ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED -> "○ Unverified"
        ChemicalIntelligenceAvailability.CONFLICT -> "⚠ Conflict"
        ChemicalIntelligenceAvailability.UNAVAILABLE -> "— No chemistry"
    }
