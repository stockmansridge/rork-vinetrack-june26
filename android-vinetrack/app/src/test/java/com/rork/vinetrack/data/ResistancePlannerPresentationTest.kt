package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import com.rork.vinetrack.data.resistance.ResistanceApplicationEvent
import com.rork.vinetrack.data.resistance.ResistanceCrop
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceEventKind
import com.rork.vinetrack.data.resistance.ResistanceEventSource
import com.rork.vinetrack.data.resistance.ResistanceGroupSignature
import com.rork.vinetrack.data.resistance.ResistanceHistoryConcern
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistanceMixtureRequirement
import com.rork.vinetrack.data.resistance.ResistancePlan
import com.rork.vinetrack.data.resistance.ResistancePlanPositionStatus
import com.rork.vinetrack.data.resistance.ResistancePlanStore
import com.rork.vinetrack.data.resistance.ResistancePlannedChemistrySource
import com.rork.vinetrack.data.resistance.ResistancePlannedPosition
import com.rork.vinetrack.data.resistance.ResistancePlannedProduct
import com.rork.vinetrack.data.resistance.ResistancePlanner
import com.rork.vinetrack.data.resistance.ResistancePlannerPresentation
import com.rork.vinetrack.data.resistance.ResistancePlannerUiState
import com.rork.vinetrack.data.resistance.ResistanceProductLine
import com.rork.vinetrack.data.resistance.ResistanceRuleStatus
import com.rork.vinetrack.data.resistance.ResistanceRulesets
import com.rork.vinetrack.data.resistance.ResistanceSeasonCalendar
import com.rork.vinetrack.data.resistance.plannerMark
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Planner's SCREEN-FACING state.
 *
 * Everything the Android Planner shows is decided in [ResistancePlannerPresentation], so
 * these tests cover the decisions a composable would otherwise make untestably: which
 * status label appears, whether the per-block breakdown is shown, how each kind of history
 * uncertainty is worded, and whether a plan can still be serialised for a future synced
 * repository.
 *
 * Deliberately NOT screenshot tests. A screenshot proves pixels, not that a block-specific
 * breach reached the screen.
 */
class ResistancePlannerPresentationTest {

    private val calendar = ResistanceSeasonCalendar()
    private val season = calendar.seasonStarting(2026)

    private val blockA = "block-a"
    private val blockC = "block-c"
    private val vineyard = "vineyard-1"

    private val blockNames = listOf(blockA to "Shiraz North", blockC to "Cabernet South")

    /** Deterministic date formatting, so no test depends on a device locale. */
    private val formatDate: (Long) -> String = { epochMs ->
        "day-" + ((epochMs - season.startEpochMs) / 86_400_000L)
    }

    private fun day(offset: Int): Long = season.startEpochMs + offset * 86_400_000L

    private fun p(
        vararg groups: String,
        availability: ChemicalIntelligenceAvailability =
            ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
    ): ResistanceProductLine = ResistanceProductLine(
        lineId = "line-" + groups.joinToString("-"),
        productName = "Product " + groups.joinToString("+"),
        savedChemicalId = "saved-" + groups.joinToString("-"),
        groups = ResistanceGroupSignature.of(groups.toList()),
        availability = availability,
    )

    private fun ev(
        id: String,
        epochMs: Long,
        products: List<ResistanceProductLine>,
        targets: List<ResistanceDisease> = listOf(ResistanceDisease.POWDERY_MILDEW),
        block: String = blockA,
        targetsRecorded: Boolean = true,
    ): ResistanceApplicationEvent = ResistanceApplicationEvent(
        applicationId = id,
        kind = ResistanceEventKind.ACTUAL,
        appliedAtEpochMs = epochMs,
        seasonId = calendar.season(epochMs).id,
        vineyardId = vineyard,
        blockId = block,
        targets = targets,
        targetsRecorded = targetsRecorded,
        products = products,
    )

    private fun groupPosition(id: String, vararg groups: String): ResistancePlannedPosition =
        ResistancePlannedPosition(
            id = id,
            products = listOf(
                ResistancePlannedProduct(
                    id = "prod-$id",
                    groupCodes = groups.toList(),
                    source = ResistancePlannedChemistrySource.GROUP,
                ),
            ),
        )

    private fun productPosition(
        id: String,
        vararg groups: String,
        availability: ChemicalIntelligenceAvailability,
    ): ResistancePlannedPosition = ResistancePlannedPosition(
        id = id,
        products = listOf(
            ResistancePlannedProduct(
                id = "prod-$id",
                groupCodes = groups.toList(),
                source = ResistancePlannedChemistrySource.SAVED_CHEMICAL,
                savedChemicalId = "saved-$id",
                productName = "Shed Product",
                chemicalAvailability = availability,
            ),
        ),
    )

    private fun plan(
        disease: ResistanceDisease = ResistanceDisease.POWDERY_MILDEW,
        jurisdiction: ResistanceJurisdiction = ResistanceJurisdiction.AUSTRALIA,
        blocks: List<String> = listOf(blockA),
        positions: List<ResistancePlannedPosition> = emptyList(),
        rulesetVersion: String? = null,
    ): ResistancePlan = ResistancePlan(
        id = "plan-1",
        vineyardId = vineyard,
        seasonId = season.id,
        seasonStartYear = season.startYear,
        disease = disease,
        jurisdiction = jurisdiction,
        crop = ResistanceCrop.GRAPE,
        blockIds = blocks,
        positions = positions,
        rulesetVersion = rulesetVersion,
        createdAtEpochMs = day(0),
        updatedAtEpochMs = day(0),
    )

    private fun ui(
        plan: ResistancePlan,
        events: List<ResistanceApplicationEvent> = emptyList(),
        unresolved: List<ResistanceEventSource.UnresolvedBlockApplication> = emptyList(),
        blocks: List<Pair<String, String>> = blockNames,
    ): ResistancePlannerUiState {
        val request = ResistancePlanner.Request(
            plan = plan,
            season = season,
            seasonCalendar = calendar,
            events = events,
            unresolvedApplications = unresolved,
        )
        return ResistancePlannerPresentation.state(
            plan = plan,
            evaluation = ResistancePlanner.evaluate(request),
            blockNames = blocks,
            currentSeasonStartYear = season.startYear,
            formatDate = formatDate,
        )
    }

    // -----------------------------------------------------------------------
    // Season selection
    // -----------------------------------------------------------------------

    @Test
    fun `season choices are newest first and reach one season ahead`() {
        val choices = ResistancePlannerPresentation.seasonChoices(2026, 2026)

        // Planning the season AHEAD is the main use of the tool, so it must be offered.
        assertEquals(2027, choices.first().startYear)
        assertEquals(2022, choices.last().startYear)
        assertEquals(6, choices.size)
        assertEquals(
            listOf("2027/28", "2026/27", "2025/26", "2024/25", "2023/24", "2022/23"),
            choices.map { it.id },
        )
    }

    @Test
    fun `season is identified as a span rather than a bare calendar year`() {
        // A bare "2026" cannot say which side of the new year a January spray belongs to,
        // and getting that wrong resets a seasonal maximum mid-canopy.
        val state = ui(plan())
        assertEquals("2026/27", state.seasonId)
        assertTrue(state.seasonChoices.single { it.isSelected }.id == "2026/27")
    }

    // -----------------------------------------------------------------------
    // Disease selection & unsupported jurisdiction
    // -----------------------------------------------------------------------

    @Test
    fun `only powdery and downy mildew are offered`() {
        val state = ui(plan())
        assertEquals(
            listOf(ResistanceDisease.POWDERY_MILDEW, ResistanceDisease.DOWNY_MILDEW),
            state.diseaseChoices,
        )
    }

    @Test
    fun `unsupported jurisdiction states the limitation and shows no plan sections`() {
        val state = ui(
            plan(
                jurisdiction = ResistanceJurisdiction.NEW_ZEALAND,
                positions = listOf(groupPosition("pos-1", "3")),
            ),
        )

        assertFalse(state.isSupported)
        assertEquals(ResistancePlanner.UNSUPPORTED_JURISDICTION_MESSAGE, state.unsupportedMessage)
        assertEquals(ResistancePlannerPresentation.UNSUPPORTED_DETAIL, state.unsupportedDetail)
        // No positions, timelines or totals: rendering a sequence nothing will assess
        // would invite the grower to trust arithmetic that never ran.
        assertTrue(state.positions.isEmpty())
        assertTrue(state.timelines.isEmpty())
        assertTrue(state.totals.isEmpty())
        assertTrue(state.historyRows.isEmpty())
        assertNull(state.strategy)
    }

    @Test
    fun `unsupported jurisdiction still lets the grower change season and disease`() {
        // The country may be wrong, or the grower may be checking another season. Locking
        // the pickers would leave them stuck on a dead screen.
        val state = ui(plan(jurisdiction = ResistanceJurisdiction.UNKNOWN))
        assertTrue(state.seasonChoices.isNotEmpty())
        assertEquals(2, state.diseaseChoices.size)
    }

    // -----------------------------------------------------------------------
    // Block selection
    // -----------------------------------------------------------------------

    @Test
    fun `no selected blocks prompts for a block instead of showing an empty plan`() {
        val state = ui(plan(blocks = emptyList()))

        assertFalse(state.hasSelectedBlocks)
        assertEquals(ResistancePlannerPresentation.CHOOSE_BLOCKS_PROMPT, state.chooseBlocksPrompt)
        assertTrue(state.historyRows.isEmpty())
        assertTrue(state.positions.isEmpty())
        assertNull(state.unresolvedSummary)
    }

    @Test
    fun `block chips report which blocks the plan covers`() {
        val state = ui(plan(blocks = listOf(blockC)))

        assertEquals(listOf("Shiraz North", "Cabernet South"), state.blocks.map { it.name })
        assertEquals(listOf(false, true), state.blocks.map { it.isSelected })
        assertNull(state.blocksEmptyLabel)
    }

    @Test
    fun `a vineyard with no blocks says so`() {
        val state = ui(plan(blocks = emptyList()), blocks = emptyList())
        assertEquals(ResistancePlannerPresentation.NO_BLOCKS_LABEL, state.blocksEmptyLabel)
    }

    @Test
    fun `a removed block still renders under a stable stand-in name`() {
        // Matches the spray-export display rule: history that references a deleted block
        // must remain readable rather than collapsing to a bare id.
        val state = ui(plan(blocks = listOf("block-gone")), blocks = blockNames)
        assertEquals(
            ResistancePlannerPresentation.UNKNOWN_BLOCK_NAME,
            state.historyRows.single().blockName,
        )
    }

    // -----------------------------------------------------------------------
    // History completeness
    // -----------------------------------------------------------------------

    @Test
    fun `each kind of history uncertainty gets its own line`() {
        val events = listOf(
            ev("a1", day(5), listOf(p("3"))),
            ev("a2", day(6), listOf(p("7", availability = ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED))),
            ev("a3", day(7), listOf(p("11", availability = ChemicalIntelligenceAvailability.CONFLICT))),
            ev("a4", day(8), listOf(p("13")), targetsRecorded = false),
        )
        val state = ui(plan(), events)
        val row = state.historyRows.single()

        // One line per named gap. A single "history may be incomplete" would tell the
        // grower nothing about which of four different things to go and fix.
        assertTrue(row.detailLines.any { it.contains("3 relevant applications this season") })
        assertTrue(row.detailLines.any { it.contains("1 spray with no recorded disease target") })
        assertTrue(row.detailLines.any { it.contains("1 application with conflicting chemistry") })
        assertTrue(row.detailLines.any { it.contains("1 application with unverified chemistry") })
        assertFalse(row.isCompleteEnoughToAssess)
    }

    @Test
    fun `the history headline names the worst concern`() {
        val events = listOf(ev("a1", day(5), listOf(p("3")), targetsRecorded = false))
        val state = ui(plan(), events)

        assertEquals(
            ResistanceHistoryConcern.UNKNOWN_TARGETS.label,
            state.historyRows.single().headline,
        )
    }

    @Test
    fun `clean history reports as complete with no unresolved summary`() {
        val state = ui(plan(), listOf(ev("a1", day(5), listOf(p("3")))))
        val row = state.historyRows.single()

        assertTrue(row.isCompleteEnoughToAssess)
        assertTrue(row.concerns.isEmpty())
        assertEquals("Current-season history available", row.headline)
        assertNull(state.unresolvedSummary)
    }

    @Test
    fun `unattributed sprays surface as a vineyard-level summary with detail on request`() {
        val unresolved = listOf(
            ResistanceEventSource.UnresolvedBlockApplication(
                applicationId = "legacy-1",
                vineyardId = vineyard,
                appliedAtEpochMs = day(4),
                seasonId = season.id,
                kind = ResistanceEventKind.ACTUAL,
                targets = listOf(ResistanceDisease.POWDERY_MILDEW),
                targetsRecorded = true,
                products = listOf(p("3")),
            ),
        )
        val state = ui(plan(blocks = listOf(blockA, blockC)), emptyList(), unresolved)
        val summary = assertNotNull(state.unresolvedSummary).let { state.unresolvedSummary!! }

        assertEquals(1, summary.count)
        assertEquals("Resistance history incomplete", summary.headline)
        assertTrue(summary.body.contains("cannot be assigned to individual blocks"))
        // The detail explains that unplaceable is not the same as absent — the exact
        // distinction that stops a grower reading silence as a clean history.
        assertTrue(summary.detail.contains("not assumed to be absent"))

        // The same count appears on BOTH blocks: the spray happened somewhere, and
        // pinning it to one block would invent the missing attribution.
        assertEquals(2, state.historyRows.size)
        assertTrue(
            state.historyRows.all {
                it.concerns.contains(ResistanceHistoryConcern.UNRESOLVED_BLOCK_ATTRIBUTION)
            },
        )
    }

    // -----------------------------------------------------------------------
    // Actual history timeline
    // -----------------------------------------------------------------------

    @Test
    fun `the timeline leads with FRAC identity and keeps the product as detail`() {
        val state = ui(plan(), listOf(ev("a1", day(5), listOf(p("11", "3")))))
        val row = state.timelines.single().rows.single()

        assertEquals("FRAC 3 + 11", row.groupsLabel)
        assertEquals("Product 11+3", row.productLine)
        assertEquals("day-5", row.dateLabel)
        assertEquals(1, row.ordinal)
        assertEquals("Completed", row.completedLabel)
    }

    @Test
    fun `the timeline carries a verification mark for each application`() {
        val state = ui(
            plan(),
            listOf(
                ev("a1", day(5), listOf(p("3"))),
                ev("a2", day(6), listOf(p("7", availability = ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED))),
            ),
        )
        val rows = state.timelines.single().rows

        assertEquals("✓ Verified", rows[0].availabilityMark)
        assertEquals("○ Unverified", rows[1].availabilityMark)
    }

    @Test
    fun `a block with no relevant history says so rather than showing an empty list`() {
        val state = ui(plan(blocks = listOf(blockA, blockC)), listOf(ev("a1", day(5), listOf(p("3")))))

        assertNull(state.timelines.first { it.blockId == blockA }.emptyLabel)
        assertEquals(
            "No recorded Powdery Mildew sprays this season",
            state.timelines.first { it.blockId == blockC }.emptyLabel,
        )
        assertEquals("1 relevant application", state.timelines.first { it.blockId == blockA }.countLabel)
    }

    // -----------------------------------------------------------------------
    // Planned positions
    // -----------------------------------------------------------------------

    @Test
    fun `the position ordinal continues the season's completed sprays`() {
        val history = listOf(
            ev("a1", day(5), listOf(p("3"))),
            ev("a2", day(6), listOf(p("7"))),
        )
        val state = ui(plan(positions = listOf(groupPosition("pos-1", "11"))), history)

        assertEquals("Spray 3", state.positions.single().ordinalLabel)
    }

    @Test
    fun `an empty position asks for chemistry instead of reporting a verdict`() {
        val state = ui(plan(positions = listOf(ResistancePlannedPosition(id = "pos-1"))))
        val position = state.positions.single()

        assertEquals("No chemistry selected", position.chemistryLabel)
        assertEquals(ResistancePlannerPresentation.AWAITING_CHEMISTRY_HINT, position.awaitingChemistryHint)
        assertTrue(position.findings.isEmpty())
    }

    @Test
    fun `no planned positions invites the first one`() {
        val state = ui(plan())
        assertEquals(ResistancePlannerPresentation.NO_POSITIONS_LABEL, state.positionsEmptyLabel)
    }

    @Test
    fun `move flags are disabled at the ends of the sequence`() {
        val state = ui(
            plan(
                positions = listOf(
                    groupPosition("pos-1", "3"),
                    groupPosition("pos-2", "7"),
                    groupPosition("pos-3", "11"),
                ),
            ),
        )

        assertEquals(listOf(false, true, true), state.positions.map { it.canMoveUp })
        assertEquals(listOf(true, true, false), state.positions.map { it.canMoveDown })
    }

    @Test
    fun `reordering changes the ordinals and re-runs the sequence`() {
        val positions = listOf(groupPosition("pos-1", "3"), groupPosition("pos-2", "7"))
        val original = plan(positions = positions)
        val reordered = original.movingPositionDown("pos-1", day(1))

        val before = ui(original)
        val after = ui(reordered)

        // Same ids, different order: the id is identity, the ordinal is display.
        assertEquals(listOf("pos-1", "pos-2"), before.positions.map { it.positionId })
        assertEquals(listOf("pos-2", "pos-1"), after.positions.map { it.positionId })
        assertEquals("Spray 1", after.positions.first().ordinalLabel)
        assertEquals("FRAC 7", after.positions.first().chemistryLabel)
    }

    @Test
    fun `an optional target date and growth stage read as timing metadata`() {
        val position = groupPosition("pos-1", "3").copy(
            targetDateEpochMs = day(30),
            growthStage = "E-L 23",
        )
        val state = ui(plan(positions = listOf(position)))

        assertEquals("Target day-30 • E-L 23", state.positions.single().timingLabel)
    }

    @Test
    fun `a position with no timing metadata shows no timing line`() {
        // Dates are optional by design: a rotation is planned months out, before any date
        // is knowable.
        val state = ui(plan(positions = listOf(groupPosition("pos-1", "3"))))
        assertNull(state.positions.single().timingLabel)
    }

    // -----------------------------------------------------------------------
    // Status mapping & multi-block aggregation
    // -----------------------------------------------------------------------

    @Test
    fun `blanket preventative-use guidance does not stop a position reading as a good fit`() {
        // REGRESSION GUARD. The powdery ruleset carries AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE
        // in EVERY evaluation. When guidance downgraded the status, "Good fit" became
        // unreachable for powdery and the badge carried no signal at all.
        val state = ui(
            plan(positions = listOf(groupPosition("pos-1", "13"))),
            listOf(ev("a1", day(5), listOf(p("3")))),
        )
        val position = state.positions.single()

        assertEquals(ResistancePlanPositionStatus.GOOD_FIT, position.status)
        assertEquals("Good fit", position.statusLabel)
        // The guidance is still SHOWN — it just lives in the findings, where published
        // advice with no threshold belongs.
        assertTrue(position.findings.any { it.ruleId == "AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE" })
    }

    @Test
    fun `the summary badge shows the worst block and hides nothing when blocks agree`() {
        val state = ui(
            plan(blocks = listOf(blockA, blockC), positions = listOf(groupPosition("pos-1", "13"))),
        )
        val position = state.positions.single()

        assertFalse(position.blocksDisagree)
        // No breakdown rows when every block agrees: repeating the same verdict twice
        // would add noise, not information.
        assertTrue(position.blockBreakdown.isEmpty())
    }

    @Test
    fun `a block-specific breach is never hidden behind a better block`() {
        // Block A already holds two consecutive Group 3; block C holds none. A third
        // Group 3 breaches on A only.
        val history = listOf(
            ev("a1", day(5), listOf(p("3")), block = blockA),
            ev("a2", day(6), listOf(p("3")), block = blockA),
            ev("c1", day(5), listOf(p("11")), block = blockC),
        )
        val state = ui(
            plan(blocks = listOf(blockA, blockC), positions = listOf(groupPosition("pos-1", "3"))),
            history,
        )
        val position = state.positions.single()

        assertTrue(position.blocksDisagree)
        assertEquals(2, position.blockBreakdown.size)
        // Named blocks, each with its own verdict, so the grower can see WHICH block is
        // the problem rather than a single averaged badge.
        val byName = position.blockBreakdown.associate { it.blockName to it.status }
        assertEquals(ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY, byName["Shiraz North"])
        assertEquals(ResistancePlanPositionStatus.GOOD_FIT, byName["Cabernet South"])
        // The summary is the worst of the two.
        assertEquals(ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY, position.status)
        assertEquals("Would exceed strategy", position.statusLabel)
    }

    @Test
    fun `every status carries the domain's own wording`() {
        // The UI introduces no status vocabulary of its own.
        assertEquals("Good fit", ResistancePlanPositionStatus.GOOD_FIT.label)
        assertEquals("Reaches strategy limit", ResistancePlanPositionStatus.REACHES_STRATEGY_LIMIT.label)
        assertEquals("Would exceed strategy", ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY.label)
        assertEquals("Needs review", ResistancePlanPositionStatus.NEEDS_REVIEW.label)
        assertEquals("Unable to fully assess", ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS.label)
    }

    // -----------------------------------------------------------------------
    // Product verification presentation
    // -----------------------------------------------------------------------

    @Test
    fun `an unverified product keeps its caveat visible on the position card`() {
        val state = ui(
            plan(
                positions = listOf(
                    productPosition(
                        "pos-1",
                        "13",
                        availability = ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED,
                    ),
                ),
            ),
        )
        val position = state.positions.single()

        assertEquals(1, position.productCaveats.size)
        assertTrue(position.productCaveats.single().contains("Shed Product"))
        assertTrue(position.productCaveats.single().contains("FRAC 13"))
        // Planning is still allowed — the caveat travels with it rather than blocking it.
        assertEquals(ResistancePlanPositionStatus.NEEDS_REVIEW, position.status)
    }

    @Test
    fun `a conflicting product never renders a trusted verdict`() {
        val state = ui(
            plan(
                positions = listOf(
                    productPosition(
                        "pos-1",
                        "13",
                        availability = ChemicalIntelligenceAvailability.CONFLICT,
                    ),
                ),
            ),
        )
        val position = state.positions.single()

        assertTrue(position.productCaveats.isNotEmpty())
        assertTrue(position.status != ResistancePlanPositionStatus.GOOD_FIT)
    }

    @Test
    fun `a stipulated group carries no product caveat`() {
        // There is no product identity to verify: the operator declared the group as the
        // premise of the plan.
        val state = ui(plan(positions = listOf(groupPosition("pos-1", "13"))))
        assertTrue(state.positions.single().productCaveats.isEmpty())
    }

    @Test
    fun `verification marks are identical on both platforms`() {
        // Held in the domain so the two phones cannot drift to different symbols for the
        // same evidence state.
        assertEquals("✓ Verified", ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED.plannerMark)
        assertEquals("◐ Partially Verified", ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED.plannerMark)
        assertEquals("○ Unverified", ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED.plannerMark)
        assertEquals("⚠ Conflict", ChemicalIntelligenceAvailability.CONFLICT.plannerMark)
        assertEquals("— No chemistry", ChemicalIntelligenceAvailability.UNAVAILABLE.plannerMark)
    }

    // -----------------------------------------------------------------------
    // Findings & mixture uncertainty
    // -----------------------------------------------------------------------

    @Test
    fun `an unconfirmable mixture is stated as unconfirmable`() {
        // Downy Group 49 must be mixed with an alternative mode of action. Tank-mixed with
        // Group 11 a partner IS present, but a plan cannot establish the rate it will go in
        // at, so the engine returns UNKNOWN and the screen must say exactly that.
        val position = ResistancePlannedPosition(
            id = "pos-1",
            products = listOf(
                ResistancePlannedProduct(id = "a", groupCodes = listOf("49"), source = ResistancePlannedChemistrySource.GROUP),
                ResistancePlannedProduct(id = "b", groupCodes = listOf("11"), source = ResistancePlannedChemistrySource.GROUP),
            ),
        )
        val state = ui(
            plan(disease = ResistanceDisease.DOWNY_MILDEW, positions = listOf(position)),
        )
        val finding = state.positions.single().findings
            .first { it.ruleId == "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED" }

        assertEquals(
            ResistancePlannerPresentation.MIXTURE_UNCONFIRMED_LABEL,
            finding.mixtureUnconfirmedLabel,
        )
        assertEquals("Mixture requirement cannot be fully confirmed", finding.mixtureUnconfirmedLabel)
    }

    @Test
    fun `a mixture that is definitively absent is not softened into unconfirmable`() {
        // Group 49 planned alone: no alternative mode of action is present at all. That is
        // a DEFINITIVE failure, and reporting it as "cannot be confirmed" would make a
        // known breach sound like missing paperwork.
        val state = ui(
            plan(
                disease = ResistanceDisease.DOWNY_MILDEW,
                positions = listOf(groupPosition("pos-1", "49")),
            ),
        )
        val finding = state.positions.single().findings
            .first { it.ruleId == "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED" }

        assertNull(finding.mixtureUnconfirmedLabel)
        assertTrue(finding.explanation.isNotBlank())
    }

    @Test
    fun `two FRAC groups in a plan do not let the UI declare a mixture satisfied`() {
        // The screen never decides this for itself. A tank-mix of 49 and 11 still leaves
        // the partner's rate unestablished, so the label stays.
        val position = ResistancePlannedPosition(
            id = "pos-1",
            products = listOf(
                ResistancePlannedProduct(id = "a", groupCodes = listOf("49"), source = ResistancePlannedChemistrySource.GROUP),
                ResistancePlannedProduct(id = "b", groupCodes = listOf("11"), source = ResistancePlannedChemistrySource.GROUP),
            ),
        )
        val state = ui(plan(disease = ResistanceDisease.DOWNY_MILDEW, positions = listOf(position)))
        val mixture = state.positions.single().findings
            .firstOrNull { it.ruleId == "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED" }

        assertNotNull(mixture)
        assertEquals(
            ResistancePlannerPresentation.MIXTURE_UNCONFIRMED_LABEL,
            mixture!!.mixtureUnconfirmedLabel,
        )
    }

    @Test
    fun `a finding with no mixture question carries no mixture label`() {
        val state = ui(
            plan(positions = listOf(groupPosition("pos-1", "13"))),
            listOf(ev("a1", day(5), listOf(p("3")))),
        )
        val guidance = state.positions.single().findings
            .first { it.ruleId == "AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE" }

        assertNull(guidance.mixtureUnconfirmedLabel)
    }

    @Test
    fun `a finding shows observed value, threshold and published source`() {
        val history = listOf(
            ev("a1", day(5), listOf(p("3")), block = blockA),
            ev("a2", day(6), listOf(p("3")), block = blockA),
        )
        val state = ui(plan(positions = listOf(groupPosition("pos-1", "3"))), history)
        val finding = state.positions.single().findings
            .first { it.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE" }

        assertTrue(finding.title.startsWith("Shiraz North — "))
        // Observed vs threshold vs source: everything needed to check the claim instead
        // of taking it on faith.
        assertTrue(finding.observedLine.startsWith("Observed: "))
        assertTrue(finding.observedLine.contains("Strategy: "))
        assertTrue(finding.sourceLine.contains("AU_GRAPE_POWDERY"))
        assertTrue(finding.sourceLine.contains("2026.07.22"))
        assertNotNull(finding.contributingLine)
        assertTrue(finding.contributingLine!!.startsWith("Contributing: "))
    }

    // -----------------------------------------------------------------------
    // Season totals
    // -----------------------------------------------------------------------

    @Test
    fun `season totals are reported per block and never merged`() {
        val history = listOf(
            ev("a1", day(5), listOf(p("3")), block = blockA),
            ev("a2", day(6), listOf(p("3")), block = blockA),
            ev("c1", day(5), listOf(p("11")), block = blockC),
        )
        val state = ui(plan(blocks = listOf(blockA, blockC)), history)

        val a = state.totals.first { it.blockId == blockA }
        val c = state.totals.first { it.blockId == blockC }
        assertEquals("Shiraz North", a.blockName)
        assertEquals("Powdery Mildew sprays this season: 2", a.sprayCountLabel)
        assertEquals(listOf("FRAC 3 applications: 2"), a.groupLines)
        assertEquals("Powdery Mildew sprays this season: 1", c.sprayCountLabel)
        assertEquals(listOf("FRAC 11 applications: 1"), c.groupLines)
    }

    @Test
    fun `a tank of several products counts as one application`() {
        // Counting tank lines would inflate every total and make the percentage rules
        // meaningless.
        val state = ui(plan(), listOf(ev("a1", day(5), listOf(p("3"), p("11")))))
        val totals = state.totals.single()

        assertEquals("Powdery Mildew sprays this season: 1", totals.sprayCountLabel)
        assertEquals(listOf("FRAC 3 applications: 1", "FRAC 11 applications: 1"), totals.groupLines)
    }

    // -----------------------------------------------------------------------
    // Ruleset metadata & local-only persistence
    // -----------------------------------------------------------------------

    @Test
    fun `strategy metadata comes from the ruleset that produced the verdicts`() {
        val state = ui(plan())
        val strategy = state.strategy!!

        assertEquals("CropLife Australia", strategy.organisation)
        assertNotNull(strategy.strategyName)
        assertEquals("Valid 2026-07-22", strategy.validFromLabel)
        assertEquals("Ruleset: 2026.07.22", strategy.rulesetVersionLabel)
    }

    @Test
    fun `a plan stamped with an older ruleset is flagged for review, not silently re-read`() {
        val state = ui(plan(rulesetVersion = "2025.01.01"))

        assertEquals(
            ResistancePlannerPresentation.STRATEGY_OUTDATED_WARNING,
            state.strategy!!.outdatedWarning,
        )
    }

    @Test
    fun `a plan stamped with the current ruleset shows no outdated warning`() {
        val current = ResistanceRulesets.registry.current(
            ResistanceJurisdiction.AUSTRALIA,
            ResistanceCrop.GRAPE,
            ResistanceDisease.POWDERY_MILDEW,
        )!!
        val state = ui(plan(rulesetVersion = current.rulesetVersion))

        assertNull(state.strategy!!.outdatedWarning)
    }

    @Test
    fun `the local-only limitation is stated where plans are edited`() {
        val state = ui(plan())

        assertEquals(ResistancePlanStore.LOCAL_ONLY_NOTICE, state.localOnlyNotice)
        assertTrue(state.localOnlyNotice.contains("this device only"))
        // Must not imply sync exists.
        assertTrue(state.localOnlyNotice.contains("do not yet sync"))
    }

    @Test
    fun `a plan survives a serialise-reload round trip unchanged`() {
        // v1 stores locally, but the model must stay shaped for a server repository: no
        // local-only quirks, stable position ids, vineyard scope and stamped ruleset.
        val original = plan(
            blocks = listOf(blockA, blockC),
            positions = listOf(
                groupPosition("pos-1", "3"),
                productPosition("pos-2", "7", availability = ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED),
            ),
            rulesetVersion = "2026.07.22",
        ).copy(notes = "Rotate away from 3 after Christmas")

        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val restored = json.decodeFromString<ResistancePlan>(json.encodeToString(original))

        assertEquals(original, restored)
        assertEquals(listOf("pos-1", "pos-2"), restored.positions.map { it.id })
        assertEquals("2026.07.22", restored.rulesetVersion)
        assertEquals(vineyard, restored.vineyardId)
        assertEquals(
            ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED,
            restored.positions[1].products.single().chemicalAvailability,
        )
    }

    @Test
    fun `reloading a plan reproduces the same screen state`() {
        // The reopen path a grower actually takes: save, reload, and the evaluation must
        // be identical rather than re-derived differently.
        val original = plan(
            blocks = listOf(blockA, blockC),
            positions = listOf(groupPosition("pos-1", "3"), groupPosition("pos-2", "7")),
        )
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val restored = json.decodeFromString<ResistancePlan>(json.encodeToString(original))

        val history = listOf(ev("a1", day(5), listOf(p("11")), block = blockA))
        val before = ui(original, history)
        val after = ui(restored, history)

        assertEquals(
            before.positions.map { it.positionId to it.status },
            after.positions.map { it.positionId to it.status },
        )
        assertEquals(
            before.positions.map { it.ordinalLabel },
            after.positions.map { it.ordinalLabel },
        )
        assertEquals(before.totals, after.totals)
        assertEquals(before.historyRows, after.historyRows)
    }

    // -----------------------------------------------------------------------
    // Historical records stay untouched
    // -----------------------------------------------------------------------

    @Test
    fun `editing a plan never alters the recorded history it is assessed against`() {
        val history = listOf(ev("a1", day(5), listOf(p("3"))))
        val snapshot = history.map { it.copy() }

        val original = plan(positions = listOf(groupPosition("pos-1", "7")))
        ui(original, history)
        ui(original.addingPosition(groupPosition("pos-2", "11"), nowMs = day(2)), history)
        ui(original.removingPosition("pos-1", nowMs = day(3)), history)

        // Same events, same values: the plan reads history and never writes it.
        assertEquals(snapshot, history)
        assertEquals(ResistanceRuleStatus.NOT_TRIGGERED, ResistanceRuleStatus.NOT_TRIGGERED)
        assertEquals(ResistanceMixtureRequirement.UNKNOWN, ResistanceMixtureRequirement.UNKNOWN)
    }
}
