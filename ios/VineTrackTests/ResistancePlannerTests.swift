import Foundation
import Testing

@testable import VineTrack

/// Behaviour of the Resistance Planner against the CropLife Australia 2026 grape
/// strategies.
///
/// The Planner owns no rules. These tests therefore assert that it asks the ENGINE the
/// right question — the right block, the right sequence prefix, the right candidate — and
/// that the engine's own rule ids, thresholds and observed counts survive into planner
/// output unchanged.
///
/// Mirrors Android `ResistancePlannerTest.kt` case for case, including the fixtures and
/// the expected values, so a divergence between the two platforms fails on one of them
/// rather than being discovered by a grower comparing two phones in a shed.
@Suite("Resistance planner")
struct ResistancePlannerTests {

    private let calendar = ResistanceSeasonCalendar()
    private var season: ResistanceSeason { calendar.seasonStarting(2026) }
    private var previousSeason: ResistanceSeason { calendar.previous(season) }

    private let blockA = "block-a"
    private let blockC = "block-c"
    private let vineyard = "vineyard-1"

    private let powdery: [ResistanceDisease] = [.powderyMildew]
    private let downy: [ResistanceDisease] = [.downyMildew]

    private func day(_ offset: Int) -> Int64 {
        season.startEpochMs + Int64(offset) * 86_400_000
    }

    private func previousSeasonDay(_ offset: Int) -> Int64 {
        previousSeason.startEpochMs + Int64(offset) * 86_400_000
    }

    private func p(
        _ groups: String...,
        availability: ChemicalIntelligenceAvailability = .availableVerified
    ) -> ResistanceProductLine {
        ResistanceProductLine(
            lineId: "line-" + groups.joined(separator: "-"),
            productName: "Product " + groups.joined(separator: "+"),
            savedChemicalId: "saved-" + groups.joined(separator: "-"),
            groups: .of(groups),
            availability: availability
        )
    }

    private func noChemistry(lineId: String = "line-legacy") -> ResistanceProductLine {
        ResistanceProductLine(
            lineId: lineId,
            productName: "Legacy product",
            savedChemicalId: nil,
            groups: .empty,
            availability: .unavailable
        )
    }

    private func ev(
        _ id: String,
        _ epochMs: Int64,
        _ products: [ResistanceProductLine],
        targets: [ResistanceDisease]? = nil,
        block: String? = nil,
        kind: ResistanceEventKind = .actual,
        targetsRecorded: Bool = true
    ) -> ResistanceApplicationEvent {
        ResistanceApplicationEvent(
            applicationId: id,
            kind: kind,
            appliedAtEpochMs: epochMs,
            seasonId: calendar.season(epochMs: epochMs).id,
            vineyardId: vineyard,
            blockId: block ?? blockA,
            targets: targets ?? powdery,
            targetsRecorded: targetsRecorded,
            products: products
        )
    }

    /// A position stipulating FRAC group(s) — group-first planning.
    private func groupPosition(_ id: String, _ groups: String...) -> ResistancePlannedPosition {
        ResistancePlannedPosition(
            id: id,
            products: [
                ResistancePlannedProduct(
                    id: "prod-\(id)",
                    groups: .of(groups),
                    source: .group
                )
            ]
        )
    }

    /// A position tank-mixing several stipulated products (NOT a co-formulation).
    private func tankMixPosition(_ id: String, _ groups: String...) -> ResistancePlannedPosition {
        ResistancePlannedPosition(
            id: id,
            products: groups.enumerated().map { index, code in
                ResistancePlannedProduct(
                    id: "prod-\(id)-\(index)",
                    groups: .of([code]),
                    source: .group
                )
            }
        )
    }

    /// A position built from a Chemical Store product.
    private func productPosition(
        _ id: String,
        _ groups: String...,
        availability: ChemicalIntelligenceAvailability = .availableVerified,
        registeredForDisease: Bool? = true
    ) -> ResistancePlannedPosition {
        ResistancePlannedPosition(
            id: id,
            products: [
                ResistancePlannedProduct(
                    id: "prod-\(id)",
                    groups: .of(groups),
                    source: .savedChemical,
                    savedChemicalId: "saved-\(id)",
                    productName: "Product " + groups.joined(separator: "+"),
                    chemicalAvailability: availability,
                    registeredForPlannedDisease: registeredForDisease
                )
            ]
        )
    }

    private func plan(
        disease: ResistanceDisease = .powderyMildew,
        jurisdiction: ResistanceJurisdiction = .australia,
        blocks: [String]? = nil,
        positions: [ResistancePlannedPosition] = []
    ) -> ResistancePlan {
        ResistancePlan(
            id: "plan-1",
            vineyardId: vineyard,
            seasonId: season.id,
            seasonStartYear: season.startYear,
            disease: disease,
            jurisdiction: jurisdiction,
            crop: .grape,
            blockIds: blocks ?? [blockA],
            positions: positions,
            createdAtEpochMs: day(0),
            updatedAtEpochMs: day(0)
        )
    }

    private func request(
        _ plan: ResistancePlan,
        _ events: [ResistanceApplicationEvent] = [],
        unresolved: [ResistanceEventSource.UnresolvedBlockApplication] = []
    ) -> ResistancePlanner.Request {
        ResistancePlanner.Request(
            plan: plan,
            season: season,
            seasonCalendar: calendar,
            events: events,
            unresolvedApplications: unresolved
        )
    }

    private func rule(
        _ evaluation: ResistanceEvaluation,
        _ id: String
    ) throws -> ResistanceRuleResult {
        try #require(
            evaluation.ruleResults.first { $0.ruleId == id },
            "rule \(id) not evaluated"
        )
    }

    private func singleEvaluation(
        _ result: ResistancePlanEvaluation,
        _ index: Int = 0
    ) throws -> ResistanceEvaluation {
        let position = try #require(result.positions.indices.contains(index) ? result.positions[index] : nil)
        let outcome = try #require(position.blocks.first)
        return outcome.evaluation
    }

    // MARK: - Basic planning (item 42)

    @Test("Every position is evaluated against history plus the preceding planned positions")
    func sequentialEvaluation() throws {
        let history = [ev("h1", day(10), [p("3")])]
        let planned = plan(positions: [groupPosition("pos-1", "7"), groupPosition("pos-2", "11")])
        let result = ResistancePlanner.evaluate(request(planned, history))

        #expect(result.isSupported)
        #expect(result.positions.count == 2)

        // Position 1 sees history only: 1 completed + itself = 2 disease sprays.
        let first = try singleEvaluation(result, 0)
        #expect(first.totalDiseaseSpraysInSeason == 2)
        #expect(first.consideredApplicationIds.contains("h1"))

        // Position 2 sees history AND position 1, so the denominator grows to 3. This is
        // the whole point: without the preceding planned position the second slot would be
        // judged against a season that never happened.
        let second = try singleEvaluation(result, 1)
        #expect(second.totalDiseaseSpraysInSeason == 3)
        #expect(
            second.consideredApplicationIds.first { $0.hasPrefix("plan:") }
                == ResistancePlanner.plannedApplicationId(planId: "plan-1", positionId: "pos-1")
        )
        // And the candidate for position 2 is position 2 itself, not position 1.
        #expect(
            second.candidateApplicationId
                == ResistancePlanner.plannedApplicationId(planId: "plan-1", positionId: "pos-2")
        )
    }

    @Test("A later planned position never influences an earlier one")
    func laterPositionDoesNotLeakBackwards() throws {
        let onlyFirst = plan(positions: [groupPosition("pos-1", "3")])
        let withSecond = plan(positions: [groupPosition("pos-1", "3"), groupPosition("pos-2", "3")])
        let a = ResistancePlanner.evaluate(request(onlyFirst)).positions[0]
        let b = ResistancePlanner.evaluate(request(withSecond)).positions[0]

        #expect(a.status == b.status)
        let aEval = try #require(a.blocks.first).evaluation
        let bEval = try #require(b.blocks.first).evaluation
        #expect(aEval.totalDiseaseSpraysInSeason == bEval.totalDiseaseSpraysInSeason)
    }

    @Test("Display ordinal continues the completed season count")
    func displayOrdinalContinuesHistory() {
        let history = [
            ev("h1", day(5), [p("3")]),
            ev("h2", day(15), [p("7")]),
            ev("h3", day(25), [p("11")]),
        ]
        let planned = plan(positions: [groupPosition("pos-1", "13")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        // Three completed sprays, so the first planned slot is "Spray 4".
        #expect(result.positions[0].displayOrdinal == 4)
    }

    // MARK: - Reorder (item 43)

    @Test("Reordering positions changes the warnings according to the new chronology")
    func reorderChangesWarnings() throws {
        // 3 -> 7 -> 3 keeps the two Group 3 sprays apart.
        let spread = plan(
            positions: [
                groupPosition("pos-1", "3"),
                groupPosition("pos-2", "7"),
                groupPosition("pos-3", "3"),
            ]
        )
        let spreadResult = ResistancePlanner.evaluate(request(spread))

        // 3 -> 3 -> 7 puts them back-to-back, which the consecutive rule must notice.
        let adjacent = spread.movingPositionUp(id: "pos-3", atEpochMs: day(1))
        #expect(adjacent.positions.map(\.id) == ["pos-1", "pos-3", "pos-2"])
        let adjacentResult = ResistancePlanner.evaluate(request(adjacent))

        let ruleId = "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE"
        let spreadThird = try rule(try singleEvaluation(spreadResult, 2), ruleId).status
        let adjacentSecond = try rule(try singleEvaluation(adjacentResult, 1), ruleId).status

        #expect(spreadThird != adjacentSecond)
        #expect(adjacentSecond == .wouldReachLimit)
    }

    @Test("Reordering preserves position identity so a plan can later be compared with actuals")
    func reorderPreservesIdentity() {
        let original = plan(positions: [groupPosition("pos-1", "3"), groupPosition("pos-2", "7")])
        let moved = original.movingPositionDown(id: "pos-1", atEpochMs: day(1))
        #expect(moved.positions.map(\.id) == ["pos-2", "pos-1"])
        // The ordinal a position displays changes; its identity does not.
        #expect(moved.positions.count == 2)
        #expect(moved.positions.contains { $0.id == "pos-1" })
    }

    // MARK: - Multi-block (item 44)

    @Test("Two blocks with different histories return different results and the worst wins")
    func multiBlockWorstWins() throws {
        // Block A: 3 -> 3 (already at the consecutive maximum of two).
        // Block C: 7 only.
        let history = [
            ev("a1", day(5), [p("3")], block: blockA),
            ev("a2", day(15), [p("3")], block: blockA),
            ev("c1", day(5), [p("7")], block: blockC),
        ]
        let planned = plan(blocks: [blockA, blockC], positions: [groupPosition("pos-1", "3")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let position = try #require(result.positions.first)

        let aOutcome = try #require(position.blocks.first { $0.blockId == blockA })
        let cOutcome = try #require(position.blocks.first { $0.blockId == blockC })

        // A third consecutive Group 3 on block A exceeds the strategy.
        #expect(aOutcome.status == .wouldExceedStrategy)
        // On block C the same chemistry is a clean rotation away from Group 7.
        #expect(cOutcome.status == .goodFit)

        #expect(aOutcome.status != cOutcome.status)
        #expect(position.blocksDisagree)
        // The overall position shows the WORST state, never an average.
        #expect(position.status == .wouldExceedStrategy)
    }

    @Test("Block histories are never merged")
    func blockHistoriesNeverMerged() {
        let history = [
            ev("a1", day(5), [p("11")], targets: downy, block: blockA),
            ev("c1", day(6), [p("11")], targets: downy, block: blockC),
        ]
        let planned = plan(
            disease: .downyMildew,
            blocks: [blockA, blockC],
            positions: [groupPosition("pos-1", "40")]
        )
        let result = ResistancePlanner.evaluate(request(planned, history))

        // Each block saw ONE Group 11 spray, not two. A merged history would report two
        // and could wrongly consume the season maximum.
        for totals in result.seasonTotals {
            #expect(totals.diseaseSprayCount == 1)
            #expect(totals.applicationsByGroup["11"] == 1)
        }
    }

    @Test("Unable to assess outranks reaching a limit when blocks disagree")
    func unableOutranksLimitReached() {
        // Uncertainty must not be presented as the softer of two states.
        #expect(
            ResistancePlanPositionStatus.unableToFullyAssess.rank
                > ResistancePlanPositionStatus.reachesStrategyLimit.rank
        )
        #expect(
            ResistancePlanPositionStatus.worst([.goodFit, .wouldExceedStrategy, .unableToFullyAssess])
                == .wouldExceedStrategy
        )
    }

    // MARK: - Powdery rules (item 45)

    @Test("Powdery consecutive maximum surfaces the engine rule id")
    func powderyConsecutive() throws {
        let history = [ev("h1", day(5), [p("3")]), ev("h2", day(15), [p("3")])]
        let planned = plan(positions: [groupPosition("pos-1", "3")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")

        #expect(finding.status == .wouldExceedLimit)
        #expect(finding.threshold == 2.0)
        #expect(finding.observedValue == 3.0)
        // Contributing dates are carried through so the operator can check the claim.
        #expect(finding.contributingDatesEpochMs.count == 3)
        #expect(!finding.sourceReference.isEmpty)
    }

    @Test("Powdery group 21 percentage rule is reported with its published threshold")
    func powderyGroup21Fraction() throws {
        // Four sprays already, one of them Group 21.
        let history = [
            ev("h1", day(5), [p("21")]),
            ev("h2", day(15), [p("3")]),
            ev("h3", day(25), [p("7")]),
            ev("h4", day(35), [p("13")]),
        ]
        let planned = plan(positions: [groupPosition("pos-1", "21")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")

        // 2 of 5 sprays would be Group 21, above the published 33%.
        #expect(finding.status == .wouldExceedLimit)
        #expect(finding.observedValue == 2.0)
    }

    @Test("Powdery max-use table is evaluated through the engine")
    func powderyMaxUseTable() throws {
        let history = (1...8).map { index in
            ev("h\(index)", day(index * 5), [p(index % 2 == 0 ? "7" : "3")])
        }
        let planned = plan(positions: [groupPosition("pos-1", "7")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let tableResults = try singleEvaluation(result).ruleResults.filter {
            $0.ruleId.contains("MAX_FROM_TOTAL_TABLE")
        }
        #expect(!tableResults.isEmpty)
    }

    @Test("Powdery combination product is evaluated as both components not a fictional group")
    func powderyCombination() throws {
        // A single co-formulated FRAC 11 + 3 product.
        let planned = plan(positions: [groupPosition("pos-1", "11", "3")])
        let result = ResistancePlanner.evaluate(request(planned))
        let evaluation = try singleEvaluation(result)

        // The label reads as the combination.
        #expect(planned.positions[0].groupsLabel == "FRAC 3 + 11")

        // But BOTH component rules see it. Flattening 11+3 into one invented group would
        // silently exempt it from the Group 3 and Group 11 restrictions.
        let group3 = try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        let touchedByGroup11 = evaluation.ruleResults.contains {
            $0.groups.contains("11") && $0.status != .notTriggered
        }
        #expect(group3.status != .notTriggered)
        #expect(touchedByGroup11)
    }

    @Test("Powdery cross-season tail is counted by the engine")
    func powderyCrossSeason() throws {
        // Last spray of the previous season plus the first of this one, both Group 3.
        let history = [
            ev("prev", previousSeasonDay(300), [p("3")]),
            ev("h1", day(3), [p("3")]),
        ]
        let planned = plan(positions: [groupPosition("pos-1", "3")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")

        // The run continues across the season boundary, so this would be a third.
        #expect(finding.status == .wouldExceedLimit)
    }

    // MARK: - Downy rules (item 46)

    @Test("Downy group 11 must not be consecutive")
    func downyGroup11Consecutive() throws {
        let history = [ev("h1", day(10), [p("11")], targets: downy)]
        let planned = plan(disease: .downyMildew, positions: [groupPosition("pos-1", "11")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE")

        #expect(finding.status == .wouldExceedLimit)
        #expect(result.positions[0].status == .wouldExceedStrategy)
    }

    @Test("Downy group 49 one-in-three spacing is enforced through the engine")
    func downyGroup49Spacing() throws {
        let history = [
            ev("h1", day(5), [p("49")], targets: downy),
            ev("h2", day(15), [p("40")], targets: downy),
        ]
        let planned = plan(disease: .downyMildew, positions: [groupPosition("pos-1", "49")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE")

        // Two Group 49 sprays inside three consecutive downy sprays.
        #expect(finding.status == .wouldExceedLimit)
    }

    @Test("Downy group 49 intervening-application rule is reported")
    func downyGroup49Intervening() throws {
        let history = [
            ev("h1", day(5), [p("49")], targets: downy),
            ev("h2", day(15), [p("40")], targets: downy),
        ]
        let planned = plan(disease: .downyMildew, positions: [groupPosition("pos-1", "49")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING")
        #expect(finding.status == .wouldExceedLimit)
    }

    @Test("Downy group 40 season maximum is reported with observed and threshold")
    func downyGroup40Season() throws {
        let history = (1...3).map { ev("h\($0)", day($0 * 10), [p("40")], targets: downy) }
        let planned = plan(disease: .downyMildew, positions: [groupPosition("pos-1", "40")])
        let result = ResistancePlanner.evaluate(request(planned, history))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_DOWNY_FRAC40_MAX_SEASON")
        #expect(finding.threshold != nil)
        #expect(finding.observedValue != nil)
    }

    @Test("Downy mixture requirement stays unconfirmed rather than passing")
    func downyMixtureUnconfirmed() throws {
        // Group 49 requires a mixture with an alternative mode of action. Here it is
        // tank-mixed with Group 11 — a genuine alternative MoA, and deliberately NOT the
        // 40 + 49 co-formulation, which carries its own fraction rule.
        let planned = plan(disease: .downyMildew, positions: [tankMixPosition("pos-1", "49", "11")])
        let result = ResistancePlanner.evaluate(request(planned))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED")

        // A second mode of action is present, but nothing establishes its RATE, so the
        // engine returns unknown — never a satisfied pass. A plan cannot know what rate a
        // partner will actually go in at.
        #expect(finding.status == .requirementUnproven)
        #expect(finding.mixtureRequirement == .unknown)

        // The position is unableToFullyAssess, not a good fit and not a soft "needs
        // review": the engine escalates an unprovable requirement at the overall level,
        // because a mixture requirement nobody can confirm leaves the real answer
        // genuinely unknown. What must never happen is this reading as compliant.
        #expect(result.positions[0].status == .unableToFullyAssess)
        #expect(result.positions[0].status != .goodFit)
        #expect(result.positions[0].findings.contains { $0.mixtureRequirement == .unknown })
    }

    @Test("The downy 40 plus 49 co-formulation is governed by its own fraction rule")
    func downyCoformulationFraction() throws {
        // A season whose only downy spray is the 40 + 49 co-formulation exceeds the
        // published fraction ceiling for that product. This is the co-formulation being
        // evaluated as itself, not as bare Group 40 or bare Group 49.
        let planned = plan(disease: .downyMildew, positions: [groupPosition("pos-1", "40", "49")])
        let result = ResistancePlanner.evaluate(request(planned))
        let finding = try rule(
            try singleEvaluation(result),
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION"
        )

        #expect(finding.status == .wouldExceedLimit)
        #expect(result.positions[0].status == .wouldExceedStrategy)
    }

    @Test("Downy group 49 alone fails the mixture requirement definitively")
    func downyGroup49Solo() throws {
        let planned = plan(disease: .downyMildew, positions: [groupPosition("pos-1", "49")])
        let result = ResistancePlanner.evaluate(request(planned))
        let finding = try rule(try singleEvaluation(result), "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED")
        #expect(finding.status == .requirementNotMet)
        #expect(finding.mixtureRequirement == .notSatisfied)
    }

    // MARK: - Uncertainty (item 47)

    @Test("Unresolved block attribution suppresses a clean plan and is reported per block")
    func unresolvedAttributionReportedPerBlock() {
        let unresolved = [
            ResistanceEventSource.UnresolvedBlockApplication(
                applicationId: "legacy-1",
                vineyardId: vineyard,
                appliedAtEpochMs: day(4),
                seasonId: season.id,
                kind: .actual,
                targets: [],
                targetsRecorded: false,
                products: [p("11")]
            ),
            ResistanceEventSource.UnresolvedBlockApplication(
                applicationId: "legacy-2",
                vineyardId: vineyard,
                appliedAtEpochMs: day(8),
                seasonId: season.id,
                kind: .actual,
                targets: [],
                targetsRecorded: false,
                products: [p("3")]
            ),
        ]
        let planned = plan(blocks: [blockA, blockC], positions: [groupPosition("pos-1", "7")])
        let result = ResistancePlanner.evaluate(request(planned, [], unresolved: unresolved))

        #expect(result.unresolvedApplicationCount == 2)
        #expect(result.hasHistoryConcerns)

        // The same uncertainty is reported for BOTH blocks. An unattributed spray could
        // have been on either, so pinning it to one would invent the missing attribution.
        for check in result.historyChecks {
            #expect(check.concerns.contains(.unresolvedBlockAttribution))
            #expect(check.unresolvedVineyardApplicationCount == 2)
            #expect(!check.isCompleteEnoughToAssess)
        }
    }

    @Test("A spray with unknown targets is reported and never counted as zero")
    func unknownTargetsReported() throws {
        let history = [ev("h1", day(10), [p("3")], targets: [], targetsRecorded: false)]
        let planned = plan(positions: [groupPosition("pos-1", "7")])
        let result = ResistancePlanner.evaluate(request(planned, history))

        let check = try #require(result.historyChecks.first)
        #expect(check.concerns.contains(.unknownTargets))
        #expect(check.unknownTargetCount == 1)
        // The unattributable spray is a hole in the history, so no clean verdict.
        #expect(result.positions[0].status == .unableToFullyAssess)
    }

    @Test("Unavailable chemistry in history suppresses a clean plan")
    func unavailableChemistryReported() throws {
        let history = [ev("h1", day(10), [noChemistry()])]
        let planned = plan(positions: [groupPosition("pos-1", "7")])
        let result = ResistancePlanner.evaluate(request(planned, history))

        let check = try #require(result.historyChecks.first)
        #expect(check.concerns.contains(.unavailableChemistry))
        #expect(result.positions[0].status == .unableToFullyAssess)
    }

    @Test("Unverified chemistry in history is reported and qualifies the verdict")
    func unverifiedChemistryReported() throws {
        let history = [ev("h1", day(10), [p("3", availability: .availableUnverified)])]
        let planned = plan(positions: [groupPosition("pos-1", "7")])
        let result = ResistancePlanner.evaluate(request(planned, history))

        let check = try #require(result.historyChecks.first)
        #expect(check.concerns.contains(.unverifiedChemistry))
        #expect(check.unverifiedCount == 1)
        // Sound arithmetic over unverified groups: not a breach, but not a clean pass.
        #expect(result.positions[0].status != .goodFit)
    }

    @Test("Conflicting chemistry in history prevents any conclusion")
    func conflictingChemistryReported() throws {
        let history = [ev("h1", day(10), [p("3", availability: .conflict)])]
        let planned = plan(positions: [groupPosition("pos-1", "7")])
        let result = ResistancePlanner.evaluate(request(planned, history))

        let check = try #require(result.historyChecks.first)
        #expect(check.concerns.contains(.conflictingChemistry))
        #expect(result.positions[0].status == .unableToFullyAssess)
    }

    @Test("Planning an unverified product keeps the caveat in the status")
    func unverifiedProductKeepsCaveat() {
        let planned = plan(
            positions: [productPosition("pos-1", "7", availability: .availableUnverified)]
        )
        let result = ResistancePlanner.evaluate(request(planned))
        #expect(result.positions[0].status == .needsReview)
        #expect(planned.positions[0].productsRequiringCaveat.count == 1)
    }

    @Test("Planning a conflict product is not treated as trusted chemistry")
    func conflictProductNotTrusted() {
        let planned = plan(positions: [productPosition("pos-1", "7", availability: .conflict)])
        let result = ResistancePlanner.evaluate(request(planned))
        // A product whose FRAC identity is disputed cannot support a rotation verdict.
        #expect(result.positions[0].status == .unableToFullyAssess)
    }

    @Test("An empty season with no unresolved history reports no sprays rather than a guarantee")
    func emptySeasonReportsNoSprays() throws {
        let result = ResistancePlanner.evaluate(request(plan()))
        let check = try #require(result.historyChecks.first)
        #expect(check.relevantApplicationCount == 0)
        #expect(!check.hasSeasonHistory)
        #expect(check.isCompleteEnoughToAssess)
        #expect(check.headline(disease: .powderyMildew) == "No recorded Powdery Mildew sprays this season")
    }

    @Test("An empty season with unresolved history does not claim completeness")
    func emptySeasonWithUnresolvedIsNotComplete() throws {
        let unresolved = [
            ResistanceEventSource.UnresolvedBlockApplication(
                applicationId: "legacy-1",
                vineyardId: vineyard,
                appliedAtEpochMs: day(4),
                seasonId: season.id,
                kind: .actual,
                targets: powdery,
                targetsRecorded: true,
                products: [p("11")]
            )
        ]
        let result = ResistancePlanner.evaluate(request(plan(), [], unresolved: unresolved))
        let check = try #require(result.historyChecks.first)
        #expect(check.relevantApplicationCount == 0)
        // No sprays could be placed on this block, but that is not the same as none having
        // happened.
        #expect(!check.isCompleteEnoughToAssess)
    }

    // MARK: - Unsupported jurisdiction (item 48)

    @Test("A New Zealand vineyard gets an unsupported state and no Australian results")
    func newZealandUnsupported() {
        let planned = plan(jurisdiction: .newZealand, positions: [groupPosition("pos-1", "3")])
        let result = ResistancePlanner.evaluate(request(planned))

        #expect(!result.isSupported)
        #expect(result.unsupportedMessage == ResistancePlanner.unsupportedJurisdictionMessage)
        // Critically: no evaluations at all, rather than Australian ones relabelled.
        #expect(result.positions.isEmpty)
        #expect(result.historyChecks.isEmpty)
        #expect(result.rulesetId == nil)
        #expect(result.rulesetVersion == nil)
        #expect(ResistancePlanner.groupOptions(at: 0, request: request(planned)).isEmpty)
    }

    @Test("An unknown jurisdiction is also unsupported")
    func unknownJurisdictionUnsupported() {
        let result = ResistancePlanner.evaluate(request(plan(jurisdiction: .unknown)))
        #expect(!result.isSupported)
        #expect(result.rulesetId == nil)
    }

    // MARK: - Group vs product equivalence (item 49)

    @Test("A stipulated group and a verified product of the same group evaluate identically")
    func groupAndProductEquivalent() throws {
        let history = [ev("h1", day(10), [p("3")])]
        let byGroup = plan(positions: [groupPosition("pos-1", "7")])
        let byProduct = plan(positions: [productPosition("pos-1", "7")])

        let groupResult = ResistancePlanner.evaluate(request(byGroup, history))
        let productResult = ResistancePlanner.evaluate(request(byProduct, history))

        let groupEval = try singleEvaluation(groupResult)
        let productEval = try singleEvaluation(productResult)

        #expect(groupResult.positions[0].status == productResult.positions[0].status)
        #expect(groupEval.status == productEval.status)
        #expect(groupEval.totalDiseaseSpraysInSeason == productEval.totalDiseaseSpraysInSeason)
        // Rule-for-rule identical: the product enriches metadata, it does not change the
        // FRAC arithmetic.
        #expect(
            groupEval.ruleResults.map { "\($0.ruleId)|\($0.status.rawValue)" }
                == productEval.ruleResults.map { "\($0.ruleId)|\($0.status.rawValue)" }
        )
    }

    @Test("A product with extra groups is not evaluated as the browsed group alone")
    func coformulationNotFlattened() throws {
        let byGroup = plan(positions: [groupPosition("pos-1", "7")])
        let byCombination = plan(positions: [productPosition("pos-1", "7", "3")])

        let groupEval = try singleEvaluation(ResistancePlanner.evaluate(request(byGroup)))
        let comboEval = try singleEvaluation(ResistancePlanner.evaluate(request(byCombination)))

        // Choosing a 7+3 co-formulation from a Group 7 list really is planning 7+3, and
        // the Group 3 rules must see it.
        let ruleId = "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE"
        #expect(try rule(groupEval, ruleId).status == .notTriggered)
        #expect(try rule(comboEval, ruleId).status != .notTriggered)
    }

    // MARK: - History immutability (item 50)

    @Test("Editing reordering and removing planned positions never alters actual history")
    func historyIsImmutable() throws {
        let history = [ev("h1", day(5), [p("3")]), ev("h2", day(15), [p("7")])]
        let snapshot = history
        var planned = plan(positions: [groupPosition("pos-1", "11"), groupPosition("pos-2", "13")])

        _ = ResistancePlanner.evaluate(request(planned, history))
        planned = planned.movingPositionUp(id: "pos-2", atEpochMs: day(1))
        _ = ResistancePlanner.evaluate(request(planned, history))
        planned = planned.replacingPosition(groupPosition("pos-1", "21"), atEpochMs: day(2))
        _ = ResistancePlanner.evaluate(request(planned, history))
        planned = planned.removingPosition(id: "pos-2", atEpochMs: day(3))
        let result = ResistancePlanner.evaluate(request(planned, history))

        // The input events are untouched, field for field.
        #expect(snapshot == history)
        // And the completed timeline still reports exactly the two real applications.
        let timeline = try #require(result.timeline(blockId: blockA))
        #expect(timeline.entries.map(\.applicationId) == ["h1", "h2"])
        #expect(result.totals(blockId: blockA)?.diseaseSprayCount == 2)
    }

    @Test("Planned positions are never mistaken for spray records")
    func plannedIdsAreNamespaced() throws {
        let planned = plan(positions: [groupPosition("pos-1", "7")])
        let result = ResistancePlanner.evaluate(request(planned))
        let candidateId = try #require(try singleEvaluation(result).candidateApplicationId)
        // A namespaced id cannot collide with a real spray record uuid.
        #expect(candidateId.hasPrefix("plan:"))
        #expect(candidateId.contains(":position:"))
    }

    // MARK: - Group and product options (items 13, 14, 32, 37)

    @Test("Group options exclude chemistry that would exceed the strategy")
    func groupOptionsExcludeBreaches() throws {
        // Block A is already at two consecutive Group 3.
        let history = [ev("h1", day(5), [p("3")]), ev("h2", day(15), [p("3")])]
        let planned = plan(positions: [groupPosition("pos-1", "3")])
        let options = ResistancePlanner.groupOptions(at: 0, request: request(planned, history))

        #expect(!options.isEmpty)
        // A third consecutive Group 3 is not offered.
        #expect(!options.contains { $0.listing.signature.codes == ["3"] })
        // Nothing offered would exceed the strategy.
        #expect(!options.contains { $0.status == .wouldExceedStrategy })
        // Rotation leads the list.
        #expect(try #require(options.first).differsFromRecentSequence)
    }

    @Test("Group options are recomputed for the position they are asked about")
    func recentGroupsBeforePosition() {
        let planned = plan(positions: [groupPosition("pos-1", "3"), groupPosition("pos-2", "3")])
        // At position 2 the recent group is the Group 3 planned at position 1.
        #expect(ResistancePlanner.recentGroupsBefore(index: 1, request: request(planned)) == ["3"])
    }

    @Test("Product options come only from the chemical store and keep their caveats")
    func productOptionsKeepCaveats() throws {
        let candidates = [
            ResistancePlanChemicalCandidate(
                savedChemicalId: "verified-7",
                productName: "Product A",
                groups: .of(["7"]),
                availability: .availableVerified,
                registeredForDisease: true,
                countryCode: "AU"
            ),
            ResistancePlanChemicalCandidate(
                savedChemicalId: "partial-7",
                productName: "Product B",
                groups: .of(["7"]),
                availability: .availablePartiallyVerified,
                registeredForDisease: nil,
                countryCode: "AU"
            ),
            ResistancePlanChemicalCandidate(
                savedChemicalId: "other-13",
                productName: "Product C",
                groups: .of(["13"]),
                availability: .availableVerified,
                countryCode: "AU"
            ),
        ]
        let options = ResistancePlanner.productOptions(
            for: .of(["7"]),
            candidates: candidates,
            jurisdiction: .australia
        )

        // Only Group 7 products, and nothing invented.
        #expect(options.map(\.candidate.savedChemicalId) == ["verified-7", "partial-7"])
        // Verified first, and its caveat is absent.
        #expect(options[0].caveat == nil)
        #expect(options[0].registeredUseNote == "Registered use recorded for this disease")
        // The partially verified product keeps a visible caveat.
        #expect(try #require(options[1].caveat).contains("partially verified"))
        // Unknown registered use is stated as unknown, never as a registration claim and
        // never inferred from the group.
        #expect(options[1].registeredUseNote == "Registered use for this disease not known")
    }

    @Test("A product from another country is filtered out but unknown country is kept")
    func productCountryFiltering() {
        let candidates = [
            ResistancePlanChemicalCandidate(
                savedChemicalId: "nz-7",
                productName: "NZ product",
                groups: .of(["7"]),
                availability: .availableVerified,
                countryCode: "NZ"
            ),
            ResistancePlanChemicalCandidate(
                savedChemicalId: "unknown-7",
                productName: "Legacy product",
                groups: .of(["7"]),
                availability: .availableVerified,
                countryCode: nil
            ),
        ]
        let options = ResistancePlanner.productOptions(
            for: .of(["7"]),
            candidates: candidates,
            jurisdiction: .australia
        )
        // A product with no recorded country is still offered: most Chemical Store entries
        // predate country capture, and hiding them would leave the grower unable to plan
        // with products they hold.
        #expect(options.map(\.candidate.savedChemicalId) == ["unknown-7"])
    }

    @Test("An exact signature match is preferred over a broader co-formulation")
    func exactSignaturePreferred() {
        let candidates = [
            ResistancePlanChemicalCandidate(
                savedChemicalId: "combo",
                productName: "Combo",
                groups: .of(["7", "3"]),
                availability: .availableVerified
            ),
            ResistancePlanChemicalCandidate(
                savedChemicalId: "solo",
                productName: "Solo",
                groups: .of(["7"]),
                availability: .availableVerified
            ),
        ]
        let options = ResistancePlanner.productOptions(
            for: .of(["7"]),
            candidates: candidates,
            jurisdiction: .australia
        )
        #expect(options[0].candidate.savedChemicalId == "solo")
        #expect(options[0].isExactSignatureMatch)
        #expect(!options[1].isExactSignatureMatch)
    }

    // MARK: - Sequencing mechanics (items 11, 12, 16, 17)

    @Test("Planned timestamps stay ordered and inside the season")
    func plannedTimestampsOrdered() {
        let planned = plan(positions: (1...6).map { groupPosition("pos-\($0)", "7") })
        let stamps = ResistancePlanner.plannedTimestamps(request: request(planned))
        #expect(stamps.count == 6)
        for index in 1..<stamps.count {
            #expect(stamps[index] > stamps[index - 1])
        }
        // A long plan must not spill into the next season and reset a seasonal maximum.
        #expect(stamps.last! < season.endEpochMs)
        #expect(stamps.first! >= season.startEpochMs)
    }

    @Test("Planned positions are placed after the last completed application")
    func plannedAfterHistory() {
        let history = [ev("h1", day(100), [p("3")])]
        let planned = plan(positions: [groupPosition("pos-1", "7")])
        let stamps = ResistancePlanner.plannedTimestamps(request: request(planned, history))
        #expect(stamps[0] > day(100))
    }

    @Test("An optional target date does not override plan order")
    func targetDateDoesNotOverrideOrder() {
        // Position 1 carries a LATER target date than position 2. Order must still win,
        // otherwise the list the operator reads would disagree with the arithmetic.
        var first = groupPosition("pos-1", "3")
        first.targetDateEpochMs = day(200)
        var second = groupPosition("pos-2", "3")
        second.targetDateEpochMs = day(100)
        let planned = plan(positions: [first, second])
        let stamps = ResistancePlanner.plannedTimestamps(request: request(planned))
        #expect(stamps[1] > stamps[0])
    }

    @Test("A position with no chemistry is awaiting input rather than reporting a verdict")
    func emptyPositionAwaitsChemistry() {
        let planned = plan(positions: [ResistancePlannedPosition(id: "pos-1")])
        let result = ResistancePlanner.evaluate(request(planned))
        #expect(result.positions[0].awaitingChemistry)
        #expect(result.positions[0].blocks.isEmpty)
        #expect(result.positions[0].status == .needsReview)
    }

    @Test("A stipulated group is dependable while an unverified product is not")
    func stipulatedGroupIsDependable() {
        // There is no product identity to verify: the operator declared the group as the
        // premise of the plan. Downgrading it would make every group-first plan report
        // "unable to fully assess" and locate the doubt in the wrong place.
        let byGroup = groupPosition("pos-1", "7")
        #expect(byGroup.effectiveAvailability == .availableVerified)
        #expect(byGroup.productsRequiringCaveat.isEmpty)

        let byProduct = productPosition("pos-2", "7", availability: .availableUnverified)
        #expect(byProduct.effectiveAvailability == .availableUnverified)
        #expect(byProduct.productsRequiringCaveat.count == 1)
    }

    @Test("Season totals count applications, not tank lines")
    func totalsCountApplications() throws {
        let history = [ev("h1", day(5), [p("3"), p("11")])]
        let result = ResistancePlanner.evaluate(request(plan(), history))
        let totals = try #require(result.totals(blockId: blockA))
        // A three-product tank is ONE application; counting lines would inflate every
        // total and make the percentage rules meaningless.
        #expect(totals.diseaseSprayCount == 1)
        #expect(totals.applicationsByGroup["3"] == 1)
        #expect(totals.applicationsByGroup["11"] == 1)
        #expect(totals.orderedGroups == ["3", "11"])
    }

    @Test("The timeline reports completed applications group-first")
    func timelineIsGroupFirst() throws {
        let history = [ev("h1", day(5), [p("11", "3")])]
        let result = ResistancePlanner.evaluate(request(plan(), history))
        let entry = try #require(result.timeline(blockId: blockA)?.entries.first)
        #expect(entry.groupsLabel == "FRAC 3 + 11")
        #expect(entry.productNames == ["Product 11+3"])
        #expect(entry.availability == .availableVerified)
        #expect(entry.targetsRecorded)
    }

    // MARK: - Guidance, statuses and metadata (items 15, 16, 18)

    @Test("Blanket preventative-use guidance does not stop a position reading as a good fit")
    func guidanceDoesNotDowngrade() throws {
        // REGRESSION GUARD. The powdery ruleset carries
        // AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE in EVERY evaluation. When guidance
        // downgraded the status, "good fit" became unreachable for powdery and the badge
        // carried no signal at all.
        let history = [ev("a1", day(5), [p("3")])]
        let planned = plan(positions: [groupPosition("pos-1", "13")])
        let result = ResistancePlanner.evaluate(request(planned, history))

        #expect(result.positions[0].status == .goodFit)
        #expect(ResistancePlanPositionStatus.goodFit.label == "Good fit")
        // The guidance is still SHOWN — it just lives in the findings, where published
        // advice with no threshold belongs.
        #expect(
            result.positions[0].findings.contains {
                $0.ruleId == "AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE"
            }
        )
    }

    @Test("Status wording comes from the domain, identically on both platforms")
    func statusWording() {
        #expect(ResistancePlanPositionStatus.goodFit.label == "Good fit")
        #expect(ResistancePlanPositionStatus.reachesStrategyLimit.label == "Reaches strategy limit")
        #expect(ResistancePlanPositionStatus.wouldExceedStrategy.label == "Would exceed strategy")
        #expect(ResistancePlanPositionStatus.needsReview.label == "Needs review")
        #expect(ResistancePlanPositionStatus.unableToFullyAssess.label == "Unable to fully assess")
    }

    @Test("The mixture-uncertainty sentence is single-sourced and never softened")
    func mixtureLabelIsSingleSourced() {
        // The same string is asserted in the Android presentation tests, so neither
        // platform can quietly soften it into "mixture satisfied".
        #expect(
            ResistancePlanner.mixtureUnconfirmedLabel
                == "Mixture requirement cannot be fully confirmed"
        )
    }

    @Test("Verification marks are identical on both platforms")
    func verificationMarks() {
        // Held in the domain so the two phones cannot drift to different symbols for the
        // same evidence state.
        #expect(ChemicalIntelligenceAvailability.availableVerified.plannerMark == "✓ Verified")
        #expect(
            ChemicalIntelligenceAvailability.availablePartiallyVerified.plannerMark
                == "◐ Partially Verified"
        )
        #expect(ChemicalIntelligenceAvailability.availableUnverified.plannerMark == "○ Unverified")
        #expect(ChemicalIntelligenceAvailability.conflict.plannerMark == "⚠ Conflict")
        #expect(ChemicalIntelligenceAvailability.unavailable.plannerMark == "— No chemistry")
    }

    @Test("The evaluation names the strategy that produced it")
    func rulesetMetadata() {
        let result = ResistancePlanner.evaluate(request(plan()))
        #expect(result.sourceOrganisation == "CropLife Australia")
        #expect(result.strategyName != nil)
        #expect(result.rulesetValidFrom == "2026-07-22")
        #expect(result.rulesetVersion == "2026.07.22")
    }

    @Test("A plan stamped with an older ruleset is flagged rather than silently re-read")
    func outdatedRulesetFlagged() {
        var stale = plan()
        stale.rulesetVersion = "2025.01.01"
        #expect(stale.isStrategyOutdated(against: ResistanceRulesets.registry))

        let current = ResistanceRulesets.registry.current(
            jurisdiction: .australia,
            crop: .grape,
            disease: .powderyMildew
        )
        var stamped = plan()
        stamped.rulesetVersion = current?.rulesetVersion
        #expect(!stamped.isStrategyOutdated(against: ResistanceRulesets.registry))
    }

    @Test("A season is identified as a span, never a bare calendar year")
    func seasonIdentity() {
        // "2026" cannot say which side of the new year a January spray belongs to, and
        // getting that wrong resets a seasonal maximum mid-canopy.
        #expect(season.id == "2026/27")
        #expect(ResistanceSeasonCalendar.seasonId(startYear: 2026) == "2026/27")
    }

    // MARK: - Local persistence (item 23)

    @Test("A plan saves, reloads and keeps its positions and stamps")
    func planPersistsLocally() throws {
        let suite = "resistance-plan-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var original = plan(
            blocks: [blockA, blockC],
            positions: [
                groupPosition("pos-1", "3"),
                productPosition("pos-2", "7", availability: .availableUnverified),
            ]
        )
        original = original.stampingRuleset(id: "AU_GRAPE_POWDERY_2026_07_22", version: "2026.07.22")
        original = original.settingNotes("Rotate away from 3 after Christmas", atEpochMs: day(1))

        let store = ResistancePlanStore(defaults: defaults)
        store.load(vineyardId: vineyard)
        store.save(original)

        // A fresh store, as though the app had been restarted.
        let reloaded = ResistancePlanStore(defaults: defaults)
        reloaded.load(vineyardId: vineyard)
        let restored = try #require(
            reloaded.plans(seasonId: season.id, disease: .powderyMildew).first
        )

        #expect(restored == original)
        #expect(restored.positions.map(\.id) == ["pos-1", "pos-2"])
        #expect(restored.rulesetVersion == "2026.07.22")
        #expect(restored.blockIds == [blockA, blockC])
        #expect(restored.positions[1].products[0].chemicalAvailability == .availableUnverified)
        #expect(restored.notes == "Rotate away from 3 after Christmas")
    }

    @Test("A reloaded plan reproduces exactly the same evaluation")
    func reloadedPlanEvaluatesIdentically() throws {
        // v1 stores locally, but the model must stay shaped for a server repository: no
        // local-only quirks, so an encode/decode round trip cannot change a verdict.
        let original = plan(
            blocks: [blockA, blockC],
            positions: [groupPosition("pos-1", "3"), groupPosition("pos-2", "7")]
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ResistancePlan.self, from: data)

        let history = [ev("a1", day(5), [p("11")], block: blockA)]
        let before = ResistancePlanner.evaluate(request(original, history))
        let after = ResistancePlanner.evaluate(request(restored, history))

        #expect(before.positions.map(\.positionId) == after.positions.map(\.positionId))
        #expect(before.positions.map(\.status) == after.positions.map(\.status))
        #expect(before.positions.map(\.displayOrdinal) == after.positions.map(\.displayOrdinal))
        #expect(before.seasonTotals == after.seasonTotals)
        #expect(before.historyChecks == after.historyChecks)
    }

    @Test("The local-only limitation is stated and never implies sync")
    func localOnlyNotice() {
        #expect(ResistancePlanStore.localOnlyNotice.contains("this device only"))
        #expect(ResistancePlanStore.localOnlyNotice.contains("do not yet sync"))
    }

    @Test("A decode failure leaves the stored blob alone instead of wiping plans")
    func decodeFailureIsNonDestructive() throws {
        let suite = "resistance-plan-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = "resistance_plans_v1_\(vineyard)"
        let corrupt = Data("not a plan".utf8)
        defaults.set(corrupt, forKey: key)

        let store = ResistancePlanStore(defaults: defaults)
        store.load(vineyardId: vineyard)

        #expect(store.plans.isEmpty)
        // The blob survives, so a later version with a migration can still read it.
        #expect(defaults.data(forKey: key) == corrupt)
    }

    // MARK: - Block selection (items 5, 22)

    @Test("Selecting blocks de-duplicates and keeps each block's own assessment")
    func blockSelection() {
        let planned = plan(blocks: []).settingBlockIds([blockA, blockC, blockA], atEpochMs: day(1))
        #expect(planned.blockIds == [blockA, blockC])

        let result = ResistancePlanner.evaluate(
            request(
                planned,
                [
                    ev("a1", day(5), [p("3")], block: blockA),
                    ev("c1", day(5), [p("7")], block: blockC),
                ]
            )
        )
        // One history check, timeline and totals row per block — never a merged view.
        #expect(result.historyChecks.map(\.blockId) == [blockA, blockC])
        #expect(result.timelines.map(\.blockId) == [blockA, blockC])
        #expect(result.seasonTotals.map(\.blockId) == [blockA, blockC])
    }

    @Test("A plan with no blocks selected evaluates nothing rather than guessing one")
    func noBlocksSelected() {
        let planned = plan(blocks: [], positions: [groupPosition("pos-1", "3")])
        let result = ResistancePlanner.evaluate(request(planned))
        #expect(result.historyChecks.isEmpty)
        #expect(result.seasonTotals.isEmpty)
        // The position exists but has no block outcomes to report.
        #expect(result.positions[0].blocks.isEmpty)
    }
}
