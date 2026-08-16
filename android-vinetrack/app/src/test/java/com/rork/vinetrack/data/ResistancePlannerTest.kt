package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import com.rork.vinetrack.data.resistance.ResistanceApplicationEvent
import com.rork.vinetrack.data.resistance.ResistanceBlockSeasonTotals
import com.rork.vinetrack.data.resistance.ResistanceCrop
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceEventKind
import com.rork.vinetrack.data.resistance.ResistanceEventSource
import com.rork.vinetrack.data.resistance.ResistanceEvidenceQuality
import com.rork.vinetrack.data.resistance.ResistanceGroupSignature
import com.rork.vinetrack.data.resistance.ResistanceHistoryConcern
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistanceMixtureRequirement
import com.rork.vinetrack.data.resistance.ResistancePlan
import com.rork.vinetrack.data.resistance.ResistancePlanChemicalCandidate
import com.rork.vinetrack.data.resistance.ResistancePlanPositionStatus
import com.rork.vinetrack.data.resistance.ResistancePlannedChemistrySource
import com.rork.vinetrack.data.resistance.ResistancePlannedPosition
import com.rork.vinetrack.data.resistance.ResistancePlannedProduct
import com.rork.vinetrack.data.resistance.ResistancePlanner
import com.rork.vinetrack.data.resistance.ResistanceProductLine
import com.rork.vinetrack.data.resistance.ResistanceRuleStatus
import com.rork.vinetrack.data.resistance.ResistanceSeasonCalendar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behaviour of the Resistance Planner against the CropLife Australia 2026 grape
 * strategies.
 *
 * The Planner owns no rules. These tests therefore assert that it asks the ENGINE the
 * right question — the right block, the right sequence prefix, the right candidate — and
 * that the engine's own rule ids, thresholds and observed counts survive into planner
 * output unchanged.
 *
 * Mirrored by iOS `ResistancePlannerTests.swift`.
 */
class ResistancePlannerTest {

    private val calendar = ResistanceSeasonCalendar()
    private val season = calendar.seasonStarting(2026)
    private val previousSeason = calendar.previous(season)

    private val blockA = "block-a"
    private val blockC = "block-c"
    private val vineyard = "vineyard-1"

    private val powdery = listOf(ResistanceDisease.POWDERY_MILDEW)
    private val downy = listOf(ResistanceDisease.DOWNY_MILDEW)

    private fun day(offset: Int): Long = season.startEpochMs + offset * 86_400_000L
    private fun previousSeasonDay(offset: Int): Long =
        previousSeason.startEpochMs + offset * 86_400_000L

    private fun p(
        vararg groups: String,
        availability: ChemicalIntelligenceAvailability =
            ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
        lineId: String = "line-${groups.joinToString("-")}",
    ): ResistanceProductLine = ResistanceProductLine(
        lineId = lineId,
        productName = "Product " + groups.joinToString("+"),
        savedChemicalId = "saved-" + groups.joinToString("-"),
        groups = ResistanceGroupSignature.of(groups.toList()),
        availability = availability,
    )

    private fun noChemistry(lineId: String = "line-legacy"): ResistanceProductLine =
        ResistanceProductLine(
            lineId = lineId,
            productName = "Legacy product",
            savedChemicalId = null,
            groups = ResistanceGroupSignature.empty,
            availability = ChemicalIntelligenceAvailability.UNAVAILABLE,
        )

    private fun ev(
        id: String,
        epochMs: Long,
        products: List<ResistanceProductLine>,
        targets: List<ResistanceDisease> = powdery,
        block: String = blockA,
        kind: ResistanceEventKind = ResistanceEventKind.ACTUAL,
        targetsRecorded: Boolean = true,
    ): ResistanceApplicationEvent = ResistanceApplicationEvent(
        applicationId = id,
        kind = kind,
        appliedAtEpochMs = epochMs,
        seasonId = calendar.season(epochMs).id,
        vineyardId = vineyard,
        blockId = block,
        targets = targets,
        targetsRecorded = targetsRecorded,
        products = products,
    )

    /** A position stipulating FRAC group(s) — group-first planning. */
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

    /** A position tank-mixing several stipulated products (NOT a co-formulation). */
    private fun tankMixPosition(id: String, vararg groups: String): ResistancePlannedPosition =
        ResistancePlannedPosition(
            id = id,
            products = groups.mapIndexed { index, code ->
                ResistancePlannedProduct(
                    id = "prod-$id-$index",
                    groupCodes = listOf(code),
                    source = ResistancePlannedChemistrySource.GROUP,
                )
            },
        )

    /** A position built from a Chemical Store product. */
    private fun productPosition(
        id: String,
        vararg groups: String,
        availability: ChemicalIntelligenceAvailability =
            ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
        registeredForDisease: Boolean? = true,
    ): ResistancePlannedPosition = ResistancePlannedPosition(
        id = id,
        products = listOf(
            ResistancePlannedProduct(
                id = "prod-$id",
                groupCodes = groups.toList(),
                source = ResistancePlannedChemistrySource.SAVED_CHEMICAL,
                savedChemicalId = "saved-$id",
                productName = "Product " + groups.joinToString("+"),
                chemicalAvailability = availability,
                registeredForPlannedDisease = registeredForDisease,
            ),
        ),
    )

    private fun plan(
        disease: ResistanceDisease = ResistanceDisease.POWDERY_MILDEW,
        jurisdiction: ResistanceJurisdiction = ResistanceJurisdiction.AUSTRALIA,
        blocks: List<String> = listOf(blockA),
        positions: List<ResistancePlannedPosition> = emptyList(),
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
        createdAtEpochMs = day(0),
        updatedAtEpochMs = day(0),
    )

    private fun request(
        plan: ResistancePlan,
        events: List<ResistanceApplicationEvent> = emptyList(),
        unresolved: List<ResistanceEventSource.UnresolvedBlockApplication> = emptyList(),
    ): ResistancePlanner.Request = ResistancePlanner.Request(
        plan = plan,
        season = season,
        seasonCalendar = calendar,
        events = events,
        unresolvedApplications = unresolved,
    )

    // -----------------------------------------------------------------------
    // Basic planning (item 42)
    // -----------------------------------------------------------------------

    @Test
    fun `every position is evaluated against history plus the preceding planned positions`() {
        // History: one Group 3. Plan: Group 7, then Group 11.
        val history = listOf(ev("h1", day(10), listOf(p("3"))))
        val planned = plan(
            positions = listOf(groupPosition("pos-1", "7"), groupPosition("pos-2", "11")),
        )
        val result = ResistancePlanner.evaluate(request(planned, history))

        assertTrue(result.isSupported)
        assertEquals(2, result.positions.size)

        // Position 1 sees history only: 1 completed + itself = 2 disease sprays.
        val first = result.positions[0].blocks.single().evaluation
        assertEquals(2, first.totalDiseaseSpraysInSeason)
        assertTrue(first.consideredApplicationIds.contains("h1"))

        // Position 2 sees history AND position 1, so the denominator grows to 3. This is
        // the whole point: without the preceding planned position the second slot would
        // be judged against a season that never happened.
        val second = result.positions[1].blocks.single().evaluation
        assertEquals(3, second.totalDiseaseSpraysInSeason)
        assertEquals(
            ResistancePlanner.plannedApplicationId("plan-1", "pos-1"),
            second.consideredApplicationIds.first {
                it.startsWith("plan:")
            },
        )
        // And the candidate for position 2 is position 2 itself, not position 1.
        assertEquals(
            ResistancePlanner.plannedApplicationId("plan-1", "pos-2"),
            second.candidateApplicationId,
        )
    }

    @Test
    fun `a later planned position never influences an earlier one`() {
        val onlyFirst = plan(positions = listOf(groupPosition("pos-1", "3")))
        val withSecond = plan(
            positions = listOf(groupPosition("pos-1", "3"), groupPosition("pos-2", "3")),
        )
        val a = ResistancePlanner.evaluate(request(onlyFirst)).positions[0]
        val b = ResistancePlanner.evaluate(request(withSecond)).positions[0]

        assertEquals(a.status, b.status)
        assertEquals(
            a.blocks.single().evaluation.totalDiseaseSpraysInSeason,
            b.blocks.single().evaluation.totalDiseaseSpraysInSeason,
        )
    }

    @Test
    fun `display ordinal continues the completed season count`() {
        val history = listOf(
            ev("h1", day(5), listOf(p("3"))),
            ev("h2", day(15), listOf(p("7"))),
            ev("h3", day(25), listOf(p("11"))),
        )
        val planned = plan(positions = listOf(groupPosition("pos-1", "13")))
        val result = ResistancePlanner.evaluate(request(planned, history))
        // Three completed sprays, so the first planned slot is "Spray 4".
        assertEquals(4, result.positions[0].displayOrdinal)
    }

    // -----------------------------------------------------------------------
    // Reorder (item 43)
    // -----------------------------------------------------------------------

    @Test
    fun `reordering positions changes the warnings according to the new chronology`() {
        // 3 -> 7 -> 3 keeps the two Group 3 sprays apart.
        val spread = plan(
            positions = listOf(
                groupPosition("pos-1", "3"),
                groupPosition("pos-2", "7"),
                groupPosition("pos-3", "3"),
            ),
        )
        val spreadResult = ResistancePlanner.evaluate(request(spread))

        // 3 -> 3 -> 7 puts them back-to-back, which the consecutive rule must notice.
        val adjacent = spread.movingPositionUp("pos-3", day(1))
        assertEquals(
            listOf("pos-1", "pos-3", "pos-2"),
            adjacent.positions.map { it.id },
        )
        val adjacentResult = ResistancePlanner.evaluate(request(adjacent))

        val consecutiveRule = "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE"
        fun statusOf(
            evaluation: com.rork.vinetrack.data.resistance.ResistancePlanPositionEvaluation,
        ): ResistanceRuleStatus? = evaluation.blocks.single().evaluation
            .ruleResults.firstOrNull { it.ruleId == consecutiveRule }?.status

        // Spread out: the second Group 3 is not part of a run of two.
        val spreadThird = statusOf(spreadResult.positions[2])
        // Adjacent: the second Group 3 now completes a consecutive pair.
        val adjacentSecond = statusOf(adjacentResult.positions[1])

        assertNotEquals(spreadThird, adjacentSecond)
        assertEquals(ResistanceRuleStatus.WOULD_REACH_LIMIT, adjacentSecond)
    }

    @Test
    fun `reordering preserves position identity so a plan can later be compared with actuals`() {
        val original = plan(
            positions = listOf(groupPosition("pos-1", "3"), groupPosition("pos-2", "7")),
        )
        val moved = original.movingPositionDown("pos-1", day(1))
        assertEquals(listOf("pos-2", "pos-1"), moved.positions.map { it.id })
        // The ordinal a position displays changes; its identity does not.
        assertEquals(2, moved.positions.size)
        assertTrue(moved.positions.any { it.id == "pos-1" })
    }

    // -----------------------------------------------------------------------
    // Multi-block (item 44)
    // -----------------------------------------------------------------------

    @Test
    fun `two blocks with different histories return different results and the worst wins`() {
        // Block A: 3 -> 3 (already at the consecutive maximum of two).
        // Block C: 7 only.
        val history = listOf(
            ev("a1", day(5), listOf(p("3")), block = blockA),
            ev("a2", day(15), listOf(p("3")), block = blockA),
            ev("c1", day(5), listOf(p("7")), block = blockC),
        )
        val planned = plan(
            blocks = listOf(blockA, blockC),
            positions = listOf(groupPosition("pos-1", "3")),
        )
        val result = ResistancePlanner.evaluate(request(planned, history))
        val position = result.positions.single()

        val aOutcome = position.blocks.first { it.blockId == blockA }
        val cOutcome = position.blocks.first { it.blockId == blockC }

        // A third consecutive Group 3 on block A exceeds the strategy.
        assertEquals(ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY, aOutcome.status)
        // On block C the same chemistry is a clean rotation away from Group 7.
        assertEquals(ResistancePlanPositionStatus.GOOD_FIT, cOutcome.status)

        assertNotEquals(aOutcome.status, cOutcome.status)
        assertTrue(position.blocksDisagree)
        // The overall position shows the WORST state, never an average.
        assertEquals(ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY, position.status)
    }

    @Test
    fun `block histories are never merged`() {
        val history = listOf(
            ev("a1", day(5), listOf(p("11")), block = blockA),
            ev("c1", day(6), listOf(p("11")), block = blockC),
        )
        val planned = plan(
            disease = ResistanceDisease.DOWNY_MILDEW,
            blocks = listOf(blockA, blockC),
            positions = listOf(groupPosition("pos-1", "40")),
        )
        val downyHistory = history.map { it.copy(targets = downy) }
        val result = ResistancePlanner.evaluate(request(planned, downyHistory))

        // Each block saw ONE Group 11 spray, not two. A merged history would report two
        // and could wrongly consume the season maximum.
        for (totals in result.seasonTotals) {
            assertEquals(1, totals.diseaseSprayCount)
            assertEquals(1, totals.applicationsByGroup["11"])
        }
    }

    @Test
    fun `unable to assess outranks reaching a limit when blocks disagree`() {
        // Uncertainty must not be presented as the softer of two states.
        assertTrue(
            ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS.rank >
                ResistancePlanPositionStatus.REACHES_STRATEGY_LIMIT.rank,
        )
        assertEquals(
            ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY,
            ResistancePlanPositionStatus.worst(
                listOf(
                    ResistancePlanPositionStatus.GOOD_FIT,
                    ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY,
                    ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS,
                ),
            ),
        )
    }

    // -----------------------------------------------------------------------
    // Powdery rules (item 45)
    // -----------------------------------------------------------------------

    @Test
    fun `powdery consecutive maximum surfaces the engine rule id`() {
        val history = listOf(
            ev("h1", day(5), listOf(p("3"))),
            ev("h2", day(15), listOf(p("3"))),
        )
        val planned = plan(positions = listOf(groupPosition("pos-1", "3")))
        val result = ResistancePlanner.evaluate(request(planned, history))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE" }

        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, finding.status)
        assertEquals(2.0, finding.threshold!!, 0.0)
        assertEquals(3.0, finding.observedValue!!, 0.0)
        // Contributing dates are carried through so the operator can check the claim.
        assertEquals(3, finding.contributingDatesEpochMs.size)
        assertTrue(finding.sourceReference.isNotBlank())
    }

    @Test
    fun `powdery group 21 percentage rule is reported with its published threshold`() {
        // Four sprays already, one of them Group 21.
        val history = listOf(
            ev("h1", day(5), listOf(p("21"))),
            ev("h2", day(15), listOf(p("3"))),
            ev("h3", day(25), listOf(p("7"))),
            ev("h4", day(35), listOf(p("13"))),
        )
        val planned = plan(positions = listOf(groupPosition("pos-1", "21")))
        val result = ResistancePlanner.evaluate(request(planned, history))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION" }

        // 2 of 5 sprays would be Group 21, above the published 33%.
        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, finding.status)
        assertEquals(2.0, finding.observedValue!!, 0.0)
    }

    @Test
    fun `powdery max-use table is evaluated through the engine`() {
        val history = (1..8).map { index ->
            ev("h$index", day(index * 5), listOf(p(if (index % 2 == 0) "7" else "3")))
        }
        val planned = plan(positions = listOf(groupPosition("pos-1", "7")))
        val result = ResistancePlanner.evaluate(request(planned, history))
        val tableResults = result.positions.single().blocks.single().evaluation
            .ruleResults.filter { it.ruleId.contains("MAX_FROM_TOTAL_TABLE") }
        assertTrue(tableResults.isNotEmpty())
    }

    @Test
    fun `powdery combination product is evaluated as both components not a fictional group`() {
        // A single co-formulated FRAC 11 + 3 product.
        val planned = plan(positions = listOf(groupPosition("pos-1", "11", "3")))
        val result = ResistancePlanner.evaluate(request(planned))
        val evaluation = result.positions.single().blocks.single().evaluation

        // The label reads as the combination.
        assertEquals("FRAC 3 + 11", planned.positions[0].groupsLabel)

        // But BOTH component rules see it. Flattening 11+3 into one invented group would
        // silently exempt it from the Group 3 and Group 11 restrictions.
        val group3 = evaluation.ruleResults.first {
            it.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE"
        }
        val touchedByGroup11 = evaluation.ruleResults.any {
            it.groups.contains("11") && it.status != ResistanceRuleStatus.NOT_TRIGGERED
        }
        assertNotEquals(ResistanceRuleStatus.NOT_TRIGGERED, group3.status)
        assertTrue(touchedByGroup11)
    }

    @Test
    fun `powdery cross-season tail is counted by the engine`() {
        // Last spray of the previous season plus the first of this one, both Group 3.
        val history = listOf(
            ev("prev", previousSeasonDay(300), listOf(p("3"))),
            ev("h1", day(3), listOf(p("3"))),
        )
        val planned = plan(positions = listOf(groupPosition("pos-1", "3")))
        val result = ResistancePlanner.evaluate(request(planned, history))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE" }

        // The run continues across the season boundary, so this would be a third.
        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, finding.status)
    }

    // -----------------------------------------------------------------------
    // Downy rules (item 46)
    // -----------------------------------------------------------------------

    @Test
    fun `downy group 11 must not be consecutive`() {
        val history = listOf(ev("h1", day(10), listOf(p("11")), targets = downy))
        val planned = plan(
            disease = ResistanceDisease.DOWNY_MILDEW,
            positions = listOf(groupPosition("pos-1", "11")),
        )
        val result = ResistancePlanner.evaluate(request(planned, history))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE" }

        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, finding.status)
        assertEquals(ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY, result.positions[0].status)
    }

    @Test
    fun `downy group 49 one-in-three spacing is enforced through the engine`() {
        val history = listOf(
            ev("h1", day(5), listOf(p("49")), targets = downy),
            ev("h2", day(15), listOf(p("40")), targets = downy),
        )
        val planned = plan(
            disease = ResistanceDisease.DOWNY_MILDEW,
            positions = listOf(groupPosition("pos-1", "49")),
        )
        val result = ResistancePlanner.evaluate(request(planned, history))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE" }

        // Two Group 49 sprays inside three consecutive downy sprays.
        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, finding.status)
    }

    @Test
    fun `downy group 49 intervening-application rule is reported`() {
        val history = listOf(
            ev("h1", day(5), listOf(p("49")), targets = downy),
            ev("h2", day(15), listOf(p("40")), targets = downy),
        )
        val planned = plan(
            disease = ResistanceDisease.DOWNY_MILDEW,
            positions = listOf(groupPosition("pos-1", "49")),
        )
        val result = ResistancePlanner.evaluate(request(planned, history))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING" }
        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, finding.status)
    }

    @Test
    fun `downy group 40 season maximum is reported with observed and threshold`() {
        val history = (1..3).map { ev("h$it", day(it * 10), listOf(p("40")), targets = downy) }
        val planned = plan(
            disease = ResistanceDisease.DOWNY_MILDEW,
            positions = listOf(groupPosition("pos-1", "40")),
        )
        val result = ResistancePlanner.evaluate(request(planned, history))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_DOWNY_FRAC40_MAX_SEASON" }
        assertTrue(finding.threshold != null)
        assertTrue(finding.observedValue != null)
    }

    @Test
    fun `downy mixture requirement stays unconfirmed rather than passing`() {
        // Group 49 requires a mixture with an alternative mode of action. Here it is
        // tank-mixed with Group 11 — a genuine alternative MoA, and deliberately NOT the
        // 40 + 49 co-formulation, which carries its own fraction rule (see the test
        // below).
        val planned = plan(
            disease = ResistanceDisease.DOWNY_MILDEW,
            positions = listOf(tankMixPosition("pos-1", "49", "11")),
        )
        val result = ResistancePlanner.evaluate(request(planned))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED" }

        // A second mode of action is present, but nothing establishes its RATE, so the
        // engine returns UNKNOWN — never a satisfied pass. A plan cannot know what rate a
        // partner will actually go in at.
        assertEquals(ResistanceRuleStatus.REQUIREMENT_UNPROVEN, finding.status)
        assertEquals(ResistanceMixtureRequirement.UNKNOWN, finding.mixtureRequirement)

        // The position is UNABLE_TO_FULLY_ASSESS, not a good fit and not a soft "needs
        // review": the engine escalates an unprovable requirement at the overall level,
        // because a mixture requirement nobody can confirm leaves the real answer
        // genuinely unknown. What must never happen is this reading as compliant.
        assertEquals(
            ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS,
            result.positions[0].status,
        )
        assertNotEquals(ResistancePlanPositionStatus.GOOD_FIT, result.positions[0].status)
        // The finding still carries UNKNOWN, which is what lets the UI say "mixture
        // requirement cannot be fully confirmed" rather than inventing a pass or a fail.
        assertTrue(
            result.positions[0].findings.any {
                it.mixtureRequirement == ResistanceMixtureRequirement.UNKNOWN
            },
        )
    }

    @Test
    fun `the downy 40 plus 49 co-formulation is governed by its own fraction rule`() {
        // A season whose only downy spray is the 40 + 49 co-formulation exceeds the
        // published fraction ceiling for that product: one of one spray is well past a
        // one-in-three allowance. This is the co-formulation being evaluated as itself,
        // not as bare Group 40 or bare Group 49.
        val planned = plan(
            disease = ResistanceDisease.DOWNY_MILDEW,
            positions = listOf(groupPosition("pos-1", "40", "49")),
        )
        val result = ResistancePlanner.evaluate(request(planned))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION" }

        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, finding.status)
        assertEquals(ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY, result.positions[0].status)
    }

    @Test
    fun `downy group 49 alone fails the mixture requirement definitively`() {
        val planned = plan(
            disease = ResistanceDisease.DOWNY_MILDEW,
            positions = listOf(groupPosition("pos-1", "49")),
        )
        val result = ResistancePlanner.evaluate(request(planned))
        val finding = result.positions.single().blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED" }
        assertEquals(ResistanceRuleStatus.REQUIREMENT_NOT_MET, finding.status)
        assertEquals(ResistanceMixtureRequirement.NOT_SATISFIED, finding.mixtureRequirement)
    }

    // -----------------------------------------------------------------------
    // Uncertainty (item 47)
    // -----------------------------------------------------------------------

    @Test
    fun `unresolved block attribution suppresses a clean plan and is reported per block`() {
        val unresolved = listOf(
            ResistanceEventSource.UnresolvedBlockApplication(
                applicationId = "legacy-1",
                vineyardId = vineyard,
                appliedAtEpochMs = day(4),
                seasonId = season.id,
                kind = ResistanceEventKind.ACTUAL,
                targets = emptyList(),
                targetsRecorded = false,
                products = listOf(p("11")),
            ),
            ResistanceEventSource.UnresolvedBlockApplication(
                applicationId = "legacy-2",
                vineyardId = vineyard,
                appliedAtEpochMs = day(8),
                seasonId = season.id,
                kind = ResistanceEventKind.ACTUAL,
                targets = emptyList(),
                targetsRecorded = false,
                products = listOf(p("3")),
            ),
        )
        val planned = plan(
            blocks = listOf(blockA, blockC),
            positions = listOf(groupPosition("pos-1", "7")),
        )
        val result = ResistancePlanner.evaluate(request(planned, emptyList(), unresolved))

        assertEquals(2, result.unresolvedApplicationCount)
        assertTrue(result.hasHistoryConcerns)

        // The same uncertainty is reported for BOTH blocks. An unattributed spray could
        // have been on either, so pinning it to one would invent the missing attribution.
        for (check in result.historyChecks) {
            assertTrue(
                check.concerns.contains(ResistanceHistoryConcern.UNRESOLVED_BLOCK_ATTRIBUTION),
            )
            assertEquals(2, check.unresolvedVineyardApplicationCount)
            assertFalse(check.isCompleteEnoughToAssess)
        }
    }

    @Test
    fun `a spray with unknown targets is reported and never counted as zero`() {
        val history = listOf(
            ev("h1", day(10), listOf(p("3")), targetsRecorded = false, targets = emptyList()),
        )
        val planned = plan(positions = listOf(groupPosition("pos-1", "7")))
        val result = ResistancePlanner.evaluate(request(planned, history))

        val check = result.historyChecks.single()
        assertTrue(check.concerns.contains(ResistanceHistoryConcern.UNKNOWN_TARGETS))
        assertEquals(1, check.unknownTargetCount)
        // The unattributable spray is a hole in the history, so no clean verdict.
        assertEquals(ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS, result.positions[0].status)
    }

    @Test
    fun `unavailable chemistry in history suppresses a clean plan`() {
        val history = listOf(ev("h1", day(10), listOf(noChemistry())))
        val planned = plan(positions = listOf(groupPosition("pos-1", "7")))
        val result = ResistancePlanner.evaluate(request(planned, history))

        val check = result.historyChecks.single()
        assertTrue(check.concerns.contains(ResistanceHistoryConcern.UNAVAILABLE_CHEMISTRY))
        assertEquals(ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS, result.positions[0].status)
    }

    @Test
    fun `unverified chemistry in history is reported and qualifies the verdict`() {
        val history = listOf(
            ev(
                "h1",
                day(10),
                listOf(p("3", availability = ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED)),
            ),
        )
        val planned = plan(positions = listOf(groupPosition("pos-1", "7")))
        val result = ResistancePlanner.evaluate(request(planned, history))

        val check = result.historyChecks.single()
        assertTrue(check.concerns.contains(ResistanceHistoryConcern.UNVERIFIED_CHEMISTRY))
        assertEquals(1, check.unverifiedCount)
        // Sound arithmetic over unverified groups: not a breach, but not a clean pass.
        assertNotEquals(ResistancePlanPositionStatus.GOOD_FIT, result.positions[0].status)
    }

    @Test
    fun `conflicting chemistry in history prevents any conclusion`() {
        val history = listOf(
            ev(
                "h1",
                day(10),
                listOf(p("3", availability = ChemicalIntelligenceAvailability.CONFLICT)),
            ),
        )
        val planned = plan(positions = listOf(groupPosition("pos-1", "7")))
        val result = ResistancePlanner.evaluate(request(planned, history))

        val check = result.historyChecks.single()
        assertTrue(check.concerns.contains(ResistanceHistoryConcern.CONFLICTING_CHEMISTRY))
        assertEquals(ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS, result.positions[0].status)
    }

    @Test
    fun `planning an unverified product keeps the caveat in the status`() {
        val planned = plan(
            positions = listOf(
                productPosition(
                    "pos-1",
                    "7",
                    availability = ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED,
                ),
            ),
        )
        val result = ResistancePlanner.evaluate(request(planned))
        assertEquals(ResistancePlanPositionStatus.NEEDS_REVIEW, result.positions[0].status)
        assertEquals(1, planned.positions[0].productsRequiringCaveat.size)
    }

    @Test
    fun `planning a conflict product is not treated as trusted chemistry`() {
        val planned = plan(
            positions = listOf(
                productPosition(
                    "pos-1",
                    "7",
                    availability = ChemicalIntelligenceAvailability.CONFLICT,
                ),
            ),
        )
        val result = ResistancePlanner.evaluate(request(planned))
        // A product whose FRAC identity is disputed cannot support a rotation verdict.
        assertEquals(ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS, result.positions[0].status)
    }

    @Test
    fun `an empty season with no unresolved history reports no sprays rather than a guarantee`() {
        val planned = plan()
        val result = ResistancePlanner.evaluate(request(planned))
        val check = result.historyChecks.single()
        assertEquals(0, check.relevantApplicationCount)
        assertFalse(check.hasSeasonHistory)
        assertTrue(check.isCompleteEnoughToAssess)
        assertEquals(
            "No recorded Powdery Mildew sprays this season",
            check.headline(ResistanceDisease.POWDERY_MILDEW),
        )
    }

    @Test
    fun `an empty season with unresolved history does not claim completeness`() {
        val unresolved = listOf(
            ResistanceEventSource.UnresolvedBlockApplication(
                applicationId = "legacy-1",
                vineyardId = vineyard,
                appliedAtEpochMs = day(4),
                seasonId = season.id,
                kind = ResistanceEventKind.ACTUAL,
                targets = powdery,
                targetsRecorded = true,
                products = listOf(p("11")),
            ),
        )
        val result = ResistancePlanner.evaluate(request(plan(), emptyList(), unresolved))
        val check = result.historyChecks.single()
        assertEquals(0, check.relevantApplicationCount)
        // No sprays could be placed on this block, but that is not the same as none
        // having happened.
        assertFalse(check.isCompleteEnoughToAssess)
    }

    // -----------------------------------------------------------------------
    // Unsupported jurisdiction (item 48)
    // -----------------------------------------------------------------------

    @Test
    fun `a New Zealand vineyard gets an unsupported state and no Australian results`() {
        val planned = plan(
            jurisdiction = ResistanceJurisdiction.NEW_ZEALAND,
            positions = listOf(groupPosition("pos-1", "3")),
        )
        val result = ResistancePlanner.evaluate(request(planned))

        assertFalse(result.isSupported)
        assertEquals(ResistancePlanner.UNSUPPORTED_JURISDICTION_MESSAGE, result.unsupportedMessage)
        // Critically: no evaluations at all, rather than Australian ones relabelled.
        assertTrue(result.positions.isEmpty())
        assertTrue(result.historyChecks.isEmpty())
        assertNull(result.rulesetId)
        assertNull(result.rulesetVersion)
        assertTrue(ResistancePlanner.groupOptions(0, request(planned)).isEmpty())
    }

    @Test
    fun `an unknown jurisdiction is also unsupported`() {
        val planned = plan(jurisdiction = ResistanceJurisdiction.UNKNOWN)
        val result = ResistancePlanner.evaluate(request(planned))
        assertFalse(result.isSupported)
        assertNull(result.rulesetId)
    }

    // -----------------------------------------------------------------------
    // Group vs product equivalence (item 49)
    // -----------------------------------------------------------------------

    @Test
    fun `a stipulated group and a verified product of the same group evaluate identically`() {
        val history = listOf(ev("h1", day(10), listOf(p("3"))))
        val byGroup = plan(positions = listOf(groupPosition("pos-1", "7")))
        val byProduct = plan(positions = listOf(productPosition("pos-1", "7")))

        val groupResult = ResistancePlanner.evaluate(request(byGroup, history))
        val productResult = ResistancePlanner.evaluate(request(byProduct, history))

        val groupEval = groupResult.positions.single().blocks.single().evaluation
        val productEval = productResult.positions.single().blocks.single().evaluation

        assertEquals(groupResult.positions[0].status, productResult.positions[0].status)
        assertEquals(groupEval.status, productEval.status)
        assertEquals(groupEval.totalDiseaseSpraysInSeason, productEval.totalDiseaseSpraysInSeason)
        // Rule-for-rule identical: the product enriches metadata, it does not change the
        // FRAC arithmetic.
        assertEquals(
            groupEval.ruleResults.map { it.ruleId to it.status },
            productEval.ruleResults.map { it.ruleId to it.status },
        )
    }

    @Test
    fun `a product with extra groups is not evaluated as the browsed group alone`() {
        val byGroup = plan(positions = listOf(groupPosition("pos-1", "7")))
        val byCombination = plan(positions = listOf(productPosition("pos-1", "7", "3")))

        val groupEval = ResistancePlanner.evaluate(request(byGroup))
            .positions.single().blocks.single().evaluation
        val comboEval = ResistancePlanner.evaluate(request(byCombination))
            .positions.single().blocks.single().evaluation

        // Choosing a 7+3 co-formulation from a Group 7 list really is planning 7+3, and
        // the Group 3 rules must see it.
        val groupThree = { e: com.rork.vinetrack.data.resistance.ResistanceEvaluation ->
            e.ruleResults.first { it.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE" }.status
        }
        assertEquals(ResistanceRuleStatus.NOT_TRIGGERED, groupThree(groupEval))
        assertNotEquals(ResistanceRuleStatus.NOT_TRIGGERED, groupThree(comboEval))
    }

    // -----------------------------------------------------------------------
    // History immutability (item 50)
    // -----------------------------------------------------------------------

    @Test
    fun `editing reordering and removing planned positions never alters actual history`() {
        val history = listOf(
            ev("h1", day(5), listOf(p("3"))),
            ev("h2", day(15), listOf(p("7"))),
        )
        val snapshot = history.map { it.copy() }
        var planned = plan(
            positions = listOf(groupPosition("pos-1", "11"), groupPosition("pos-2", "13")),
        )

        ResistancePlanner.evaluate(request(planned, history))
        planned = planned.movingPositionUp("pos-2", day(1))
        ResistancePlanner.evaluate(request(planned, history))
        planned = planned.replacingPosition(groupPosition("pos-1", "21"), day(2))
        ResistancePlanner.evaluate(request(planned, history))
        planned = planned.removingPosition("pos-2", day(3))
        val result = ResistancePlanner.evaluate(request(planned, history))

        // The input events are untouched, field for field.
        assertEquals(snapshot, history)
        // And the completed timeline still reports exactly the two real applications.
        val timeline = result.timeline(blockA)!!
        assertEquals(listOf("h1", "h2"), timeline.entries.map { it.applicationId })
        assertEquals(2, result.totals(blockA)!!.diseaseSprayCount)
    }

    @Test
    fun `planned positions are never mistaken for spray records`() {
        val planned = plan(positions = listOf(groupPosition("pos-1", "7")))
        val result = ResistancePlanner.evaluate(request(planned))
        val candidateId = result.positions.single().blocks.single().evaluation.candidateApplicationId
        // A namespaced id cannot collide with a real spray record uuid.
        assertTrue(candidateId!!.startsWith("plan:"))
        assertTrue(candidateId.contains(":position:"))
    }

    // -----------------------------------------------------------------------
    // Group and product options (items 13, 14, 32, 37)
    // -----------------------------------------------------------------------

    @Test
    fun `group options exclude chemistry that would exceed the strategy`() {
        // Block A is already at two consecutive Group 3.
        val history = listOf(
            ev("h1", day(5), listOf(p("3"))),
            ev("h2", day(15), listOf(p("3"))),
        )
        val planned = plan(positions = listOf(groupPosition("pos-1", "3")))
        val options = ResistancePlanner.groupOptions(0, request(planned, history))

        assertTrue(options.isNotEmpty())
        // A third consecutive Group 3 is not offered.
        assertFalse(options.any { it.listing.signature.codes == listOf("3") })
        // Nothing offered would exceed the strategy.
        assertTrue(
            options.none { it.status == ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY },
        )
        // Rotation leads the list.
        assertTrue(options.first().differsFromRecentSequence)
    }

    @Test
    fun `group options are recomputed for the position they are asked about`() {
        val planned = plan(
            positions = listOf(groupPosition("pos-1", "3"), groupPosition("pos-2", "3")),
        )
        // At position 2 the recent group is the Group 3 planned at position 1.
        val recent = ResistancePlanner.recentGroupsBefore(1, request(planned))
        assertEquals(setOf("3"), recent)
    }

    @Test
    fun `product options come only from the chemical store and keep their caveats`() {
        val candidates = listOf(
            ResistancePlanChemicalCandidate(
                savedChemicalId = "verified-7",
                productName = "Product A",
                groups = ResistanceGroupSignature.of("7"),
                availability = ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
                registeredForDisease = true,
                countryCode = "AU",
            ),
            ResistancePlanChemicalCandidate(
                savedChemicalId = "partial-7",
                productName = "Product B",
                groups = ResistanceGroupSignature.of("7"),
                availability = ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED,
                registeredForDisease = null,
                countryCode = "AU",
            ),
            ResistancePlanChemicalCandidate(
                savedChemicalId = "other-13",
                productName = "Product C",
                groups = ResistanceGroupSignature.of("13"),
                availability = ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
                countryCode = "AU",
            ),
        )
        val options = ResistancePlanner.productOptions(
            ResistanceGroupSignature.of("7"),
            candidates,
            ResistanceJurisdiction.AUSTRALIA,
        )

        // Only Group 7 products, and nothing invented.
        assertEquals(listOf("verified-7", "partial-7"), options.map { it.candidate.savedChemicalId })
        // Verified first, and its caveat is absent.
        assertNull(options[0].caveat)
        assertEquals("Registered use recorded for this disease", options[0].registeredUseNote)
        // The partially verified product keeps a visible caveat.
        assertTrue(options[1].caveat!!.contains("partially verified"))
        // Unknown registered use is stated as unknown, never as a registration claim and
        // never inferred from the group.
        assertEquals("Registered use for this disease not known", options[1].registeredUseNote)
    }

    @Test
    fun `a product from another country is filtered out but unknown country is kept`() {
        val candidates = listOf(
            ResistancePlanChemicalCandidate(
                savedChemicalId = "nz-7",
                productName = "NZ product",
                groups = ResistanceGroupSignature.of("7"),
                availability = ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
                countryCode = "NZ",
            ),
            ResistancePlanChemicalCandidate(
                savedChemicalId = "unknown-7",
                productName = "Legacy product",
                groups = ResistanceGroupSignature.of("7"),
                availability = ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
                countryCode = null,
            ),
        )
        val options = ResistancePlanner.productOptions(
            ResistanceGroupSignature.of("7"),
            candidates,
            ResistanceJurisdiction.AUSTRALIA,
        )
        // A product with no recorded country is still offered: most Chemical Store
        // entries predate country capture, and hiding them would leave the grower unable
        // to plan with products they hold.
        assertEquals(listOf("unknown-7"), options.map { it.candidate.savedChemicalId })
    }

    @Test
    fun `an exact signature match is preferred over a broader co-formulation`() {
        val candidates = listOf(
            ResistancePlanChemicalCandidate(
                savedChemicalId = "combo",
                productName = "Combo",
                groups = ResistanceGroupSignature.of("7", "3"),
                availability = ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
            ),
            ResistancePlanChemicalCandidate(
                savedChemicalId = "solo",
                productName = "Solo",
                groups = ResistanceGroupSignature.of("7"),
                availability = ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
            ),
        )
        val options = ResistancePlanner.productOptions(
            ResistanceGroupSignature.of("7"),
            candidates,
            ResistanceJurisdiction.AUSTRALIA,
        )
        assertEquals("solo", options[0].candidate.savedChemicalId)
        assertTrue(options[0].isExactSignatureMatch)
        assertFalse(options[1].isExactSignatureMatch)
    }

    // -----------------------------------------------------------------------
    // Sequencing mechanics (items 11, 12, 16, 17)
    // -----------------------------------------------------------------------

    @Test
    fun `planned timestamps stay ordered and inside the season`() {
        val planned = plan(
            positions = (1..6).map { groupPosition("pos-$it", "7") },
        )
        val stamps = ResistancePlanner.plannedTimestamps(request(planned))
        assertEquals(6, stamps.size)
        for (index in 1 until stamps.size) {
            assertTrue(stamps[index] > stamps[index - 1])
        }
        // A long plan must not spill into the next season and reset a seasonal maximum.
        assertTrue(stamps.last() < season.endEpochMs)
        assertTrue(stamps.first() >= season.startEpochMs)
    }

    @Test
    fun `planned positions are placed after the last completed application`() {
        val history = listOf(ev("h1", day(100), listOf(p("3"))))
        val planned = plan(positions = listOf(groupPosition("pos-1", "7")))
        val stamps = ResistancePlanner.plannedTimestamps(request(planned, history))
        assertTrue(stamps.single() > day(100))
    }

    @Test
    fun `an optional target date does not override plan order`() {
        // Position 1 carries a LATER target date than position 2. Order must still win,
        // otherwise the list the operator reads would disagree with the arithmetic.
        val planned = plan(
            positions = listOf(
                groupPosition("pos-1", "3").copy(targetDateEpochMs = day(200)),
                groupPosition("pos-2", "3").copy(targetDateEpochMs = day(100)),
            ),
        )
        val stamps = ResistancePlanner.plannedTimestamps(request(planned))
        assertTrue(stamps[0] < stamps[1])

        val result = ResistancePlanner.evaluate(request(planned))
        // The consecutive pair is still detected in plan order.
        val finding = result.positions[1].blocks.single().evaluation
            .ruleResults.first { it.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE" }
        assertEquals(ResistanceRuleStatus.WOULD_REACH_LIMIT, finding.status)
    }

    @Test
    fun `a position with no chemistry awaits input rather than being evaluated`() {
        val planned = plan(positions = listOf(ResistancePlannedPosition(id = "pos-1")))
        val result = ResistancePlanner.evaluate(request(planned))
        val position = result.positions.single()
        assertTrue(position.awaitingChemistry)
        assertTrue(position.blocks.isEmpty())
        assertEquals(ResistancePlanPositionStatus.NEEDS_REVIEW, position.status)
    }

    @Test
    fun `reaching a limit and exceeding it are distinct statuses`() {
        // One prior Group 3 — a second REACHES the consecutive maximum of two.
        val reaching = ResistancePlanner.evaluate(
            request(
                plan(positions = listOf(groupPosition("pos-1", "3"))),
                listOf(ev("h1", day(10), listOf(p("3")))),
            ),
        ).positions[0]
        // Two prior Group 3 — a third EXCEEDS it.
        val exceeding = ResistancePlanner.evaluate(
            request(
                plan(positions = listOf(groupPosition("pos-1", "3"))),
                listOf(
                    ev("h1", day(10), listOf(p("3"))),
                    ev("h2", day(20), listOf(p("3"))),
                ),
            ),
        ).positions[0]

        assertEquals(ResistancePlanPositionStatus.REACHES_STRATEGY_LIMIT, reaching.status)
        assertEquals(ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY, exceeding.status)
        assertNotEquals(reaching.status, exceeding.status)
    }

    // -----------------------------------------------------------------------
    // Season totals and timeline (items 9, 10, 35)
    // -----------------------------------------------------------------------

    @Test
    fun `season totals count applications not tank lines`() {
        // One application carrying three products.
        val history = listOf(ev("h1", day(10), listOf(p("3"), p("7"), p("11"))))
        val planned = plan()
        val result = ResistancePlanner.evaluate(request(planned, history))
        val totals = result.totals(blockA)!!

        // One spray, not three.
        assertEquals(1, totals.diseaseSprayCount)
        // Each group present counts once for that group.
        assertEquals(1, totals.applicationsByGroup["3"])
        assertEquals(1, totals.applicationsByGroup["7"])
        assertEquals(1, totals.applicationsByGroup["11"])
    }

    @Test
    fun `the timeline reports only completed sprays for the planned disease`() {
        val history = listOf(
            ev("h1", day(5), listOf(p("3"))),
            ev("h2", day(15), listOf(p("11")), targets = downy),
            ev("h3", day(25), listOf(p("7")), kind = ResistanceEventKind.PLANNED),
        )
        val planned = plan()
        val result = ResistancePlanner.evaluate(request(planned, history))
        val timeline = result.timeline(blockA)!!

        // The downy spray belongs to another disease's history; the unfinished record is
        // not an application at all.
        assertEquals(listOf("h1"), timeline.entries.map { it.applicationId })
        assertEquals("FRAC 3", timeline.entries[0].groupsLabel)
    }

    @Test
    fun `a spray targeting both diseases appears in both histories`() {
        val both = listOf(
            ev(
                "h1",
                day(10),
                listOf(p("11", "3")),
                targets = listOf(
                    ResistanceDisease.POWDERY_MILDEW,
                    ResistanceDisease.DOWNY_MILDEW,
                ),
            ),
        )
        val powderyResult = ResistancePlanner.evaluate(request(plan(), both))
        val downyResult = ResistancePlanner.evaluate(
            request(plan(disease = ResistanceDisease.DOWNY_MILDEW), both),
        )
        assertEquals(1, powderyResult.totals(blockA)!!.diseaseSprayCount)
        assertEquals(1, downyResult.totals(blockA)!!.diseaseSprayCount)
    }

    // -----------------------------------------------------------------------
    // Ruleset metadata (items 27, 28, 33)
    // -----------------------------------------------------------------------

    @Test
    fun `the evaluation reports the governing strategy and version`() {
        val result = ResistancePlanner.evaluate(request(plan()))
        assertEquals("CropLife Australia", result.sourceOrganisation)
        assertEquals("2026-07-22", result.rulesetValidFrom)
        assertTrue(result.rulesetId!!.startsWith("AU_GRAPE_POWDERY"))
        assertTrue(result.rulesetVersion!!.isNotBlank())
    }

    @Test
    fun `a plan stamps the ruleset version it was evaluated under`() {
        val registry = com.rork.vinetrack.data.resistance.ResistanceRulesets.registry
        val current = registry.current(
            ResistanceJurisdiction.AUSTRALIA,
            ResistanceCrop.GRAPE,
            ResistanceDisease.POWDERY_MILDEW,
        )!!
        val stamped = plan().stampingRuleset(current.id, current.rulesetVersion)

        assertEquals(current.id, stamped.rulesetId)
        assertEquals(current.rulesetVersion, stamped.rulesetVersion)
        // Same version in force — nothing to review.
        assertFalse(stamped.isStrategyOutdated(registry))

        // A plan stamped under an older strategy is flagged for review rather than
        // silently re-interpreted under the new one.
        val stale = stamped.copy(rulesetVersion = "2025.01.01")
        assertTrue(stale.isStrategyOutdated(registry))

        // An unstamped plan makes no claim either way.
        assertFalse(stamped.copy(rulesetVersion = null).isStrategyOutdated(registry))
    }

    // -----------------------------------------------------------------------
    // Cross-platform parity fingerprint (item 51)
    // -----------------------------------------------------------------------

    @Test
    fun `planner parity fixture matches the iOS mirror`() {
        // A clean rotation across two blocks with DIFFERENT histories, planned three
        // positions deep. iOS asserts the identical expectations, value for value.
        val history = listOf(
            ev("a1", day(5), listOf(p("3")), block = blockA),
            ev("a2", day(15), listOf(p("7")), block = blockA),
            ev("c1", day(9), listOf(p("11")), block = blockC),
        )
        val planned = plan(
            blocks = listOf(blockA, blockC),
            positions = listOf(
                groupPosition("pos-1", "13"),
                groupPosition("pos-2", "3"),
                groupPosition("pos-3", "21"),
            ),
        )
        val result = ResistancePlanner.evaluate(request(planned, history))

        // Ordinals continue the LONGEST block history (block A has two completed).
        assertEquals(listOf(3, 4, 5), result.positions.map { it.displayOrdinal })

        // Every position rotates cleanly on both blocks, so no position is downgraded.
        // This is also the regression guard for the blanket preventative-use guideline:
        // it is present in every powdery evaluation and must not make GOOD_FIT
        // unreachable.
        for (position in result.positions) {
            assertEquals(listOf(blockA, blockC), position.blocks.map { it.blockId })
            assertEquals(
                listOf(
                    ResistancePlanPositionStatus.GOOD_FIT,
                    ResistancePlanPositionStatus.GOOD_FIT,
                ),
                position.blocks.map { it.status },
            )
            assertEquals(ResistancePlanPositionStatus.GOOD_FIT, position.status)
            assertFalse(position.blocksDisagree)
        }

        // Season totals per block, never merged.
        assertEquals(2, result.totals(blockA)!!.diseaseSprayCount)
        assertEquals(1, result.totals(blockC)!!.diseaseSprayCount)
        assertEquals(1, result.totals(blockA)!!.applicationsByGroup["3"])
        assertEquals(1, result.totals(blockA)!!.applicationsByGroup["7"])
        assertEquals(1, result.totals(blockC)!!.applicationsByGroup["11"])
        assertNull(result.totals(blockC)!!.applicationsByGroup["3"])

        // The engine's own ruleset identity travels into planner output unchanged.
        assertEquals("2026.07.22", result.rulesetVersion)
        assertEquals(0, result.unresolvedApplicationCount)
        assertFalse(result.hasHistoryConcerns)

        // Evidence is dependable throughout this fixture.
        for (position in result.positions) {
            for (outcome in position.blocks) {
                assertEquals(ResistanceEvidenceQuality.HIGH, outcome.evaluation.evidenceQuality)
            }
        }
    }
}
