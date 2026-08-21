import Foundation
import Testing

@testable import VineTrack

/// P7 — parity between the two iOS resistance surfaces.
///
/// The standalone Resistance Planner and the Live Resistance Check in the Spray
/// Calculator must reach the SAME verdict for the same history and the same
/// proposed chemistry. These tests assert that, and pin the group-scheme handling
/// both of them now depend on.
@Suite("Resistance planner / live check parity")
struct ResistanceParityTests {

    private let calendar = ResistanceSeasonCalendar()
    private var season: ResistanceSeason { calendar.seasonStarting(2026) }
    private var previousSeason: ResistanceSeason { calendar.previous(season) }

    private let blockA = "block-a"
    private let blockB = "block-b"
    private let vineyardId = "vineyard-1"

    private func day(_ offset: Int) -> Int64 {
        season.startEpochMs + Int64(offset) * 86_400_000
    }

    private func previousSeasonDay(_ offset: Int) -> Int64 {
        previousSeason.startEpochMs + Int64(offset) * 86_400_000
    }

    // MARK: - Fixtures

    private func line(
        _ groups: String...,
        availability: ChemicalIntelligenceAvailability = .availableVerified,
        lineId: String? = nil
    ) -> ResistanceProductLine {
        ResistanceProductLine(
            lineId: lineId ?? "line-\(groups.joined(separator: "-"))",
            productName: "Product " + groups.joined(separator: "+"),
            savedChemicalId: "saved-" + groups.joined(separator: "-"),
            groups: .of(groups),
            availability: availability
        )
    }

    private func history(
        _ id: String,
        _ epochMs: Int64,
        _ products: [ResistanceProductLine],
        block: String? = nil,
        targets: [ResistanceDisease] = [.powderyMildew],
        targetsRecorded: Bool = true
    ) -> ResistanceApplicationEvent {
        ResistanceApplicationEvent(
            applicationId: id,
            kind: .actual,
            appliedAtEpochMs: epochMs,
            seasonId: calendar.season(epochMs: epochMs).id,
            vineyardId: vineyardId,
            blockId: block ?? blockA,
            targets: targets,
            targetsRecorded: targetsRecorded,
            products: products
        )
    }

    private func product(
        _ groups: String...,
        id: String = "candidate-product",
        availability: ChemicalIntelligenceAvailability = .availableVerified
    ) -> ResistancePlannedProduct {
        ResistancePlannedProduct(
            id: id,
            groups: .of(groups),
            source: .savedChemical,
            savedChemicalId: "saved-\(id)",
            productName: "Product " + groups.joined(separator: "+"),
            chemicalAvailability: availability
        )
    }

    // MARK: - The two surfaces

    /// The standalone Planner, assembled exactly as `ResistancePlanEditorView` does.
    private func plannerOutcome(
        events: [ResistanceApplicationEvent],
        products: [ResistancePlannedProduct],
        disease: ResistanceDisease = .powderyMildew,
        blocks: [String]? = nil
    ) -> ResistancePlanPositionEvaluation {
        let plan = ResistancePlan(
            id: "plan-1",
            vineyardId: vineyardId,
            seasonId: season.id,
            seasonStartYear: season.startYear,
            disease: disease,
            jurisdiction: .australia,
            blockIds: blocks ?? [blockA],
            positions: [ResistancePlannedPosition(id: "position-1", products: products)],
            createdAtEpochMs: day(0),
            updatedAtEpochMs: day(0)
        )
        let evaluation = ResistancePlanner.evaluate(
            ResistancePlanner.Request(
                plan: plan,
                season: season,
                seasonCalendar: calendar,
                events: events
            )
        )
        return evaluation.positions[0]
    }

    /// The Live Resistance Check, assembled exactly as `SprayCalculatorView` does.
    private func liveCheck(
        events: [ResistanceApplicationEvent],
        products: [ResistancePlannedProduct],
        diseases: [ResistanceDisease] = [.powderyMildew],
        blocks: [String]? = nil,
        unresolved: [ResistanceEventSource.UnresolvedBlockApplication] = []
    ) -> SprayResistanceCheck.Result {
        SprayResistanceCheck.evaluate(
            SprayResistanceCheck.Request(
                vineyardId: vineyardId,
                blockIds: blocks ?? [blockA],
                diseases: diseases,
                products: products,
                jurisdiction: .australia,
                season: season,
                seasonCalendar: calendar,
                events: events,
                unresolvedApplications: unresolved,
                nowMs: day(30)
            )
        )
    }

    /// Asserts the two surfaces agree on everything an operator can see.
    private func assertParity(
        events: [ResistanceApplicationEvent],
        products: [ResistancePlannedProduct],
        disease: ResistanceDisease = .powderyMildew,
        blocks: [String]? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let planner = plannerOutcome(
            events: events, products: products, disease: disease, blocks: blocks
        )
        let live = liveCheck(
            events: events, products: products, diseases: [disease], blocks: blocks
        )
        let outcome = try #require(live.outcomes.first, sourceLocation: sourceLocation)
        let position = try #require(outcome.position, sourceLocation: sourceLocation)

        // Severity / status
        #expect(position.status == planner.status, sourceLocation: sourceLocation)
        #expect(outcome.status == planner.status, sourceLocation: sourceLocation)
        // Which blocks were assessed, and in what order
        #expect(
            position.blocks.map(\.blockId) == planner.blocks.map(\.blockId),
            sourceLocation: sourceLocation
        )
        for (livePer, plannerPer) in zip(position.blocks, planner.blocks) {
            let a = livePer.evaluation
            let b = plannerPer.evaluation
            // Rule results, verbatim: ids, statuses, severities, thresholds,
            // observed values and explanations all come out identical.
            #expect(a.ruleResults == b.ruleResults, sourceLocation: sourceLocation)
            // Previous uses
            #expect(
                a.consideredApplicationIds == b.consideredApplicationIds,
                sourceLocation: sourceLocation
            )
            #expect(
                a.totalDiseaseSpraysInSeason == b.totalDiseaseSpraysInSeason,
                sourceLocation: sourceLocation
            )
            // Overall verdict and recommendation
            #expect(a.status == b.status, sourceLocation: sourceLocation)
            #expect(a.evidenceQuality == b.evidenceQuality, sourceLocation: sourceLocation)
            #expect(a.summary == b.summary, sourceLocation: sourceLocation)
            #expect(livePer.status == plannerPer.status, sourceLocation: sourceLocation)
        }
    }

    private func finding(
        _ outcome: SprayResistanceCheck.DiseaseOutcome,
        _ ruleId: String
    ) throws -> ResistanceRuleResult {
        let all = outcome.blocks.flatMap { $0.evaluation.ruleResults }
        return try #require(all.first { $0.ruleId == ruleId }, "rule \(ruleId) not evaluated")
    }

    // MARK: - Scenario 1: FRAC 3 followed by FRAC 3

    @Test func consecutiveGroup3IsFlaggedIdenticallyOnBothSurfaces() throws {
        let events = [
            history("s1", day(1), [line("3")]),
            history("s2", day(8), [line("3")]),
        ]
        let products = [product("3")]

        try assertParity(events: events, products: products)

        let live = liveCheck(events: events, products: products)
        let outcome = try #require(live.outcomes.first)
        // Two applied plus this one is a run of three; the strategy permits two.
        let consecutive = try finding(outcome, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        #expect(consecutive.status == .wouldExceedLimit)
        #expect(consecutive.threshold == 2)
        #expect(consecutive.observedValue == 3)
        #expect(outcome.status == .wouldExceedStrategy)
        #expect(live.status == .wouldExceedStrategy)
        // The warning reaches the product line that carries Group 3.
        #expect(!live.findings(forProductId: "candidate-product").isEmpty)
    }

    // MARK: - Scenario 2: FRAC 3 -> 11 -> 40 rotation

    @Test func rotatingThroughDistinctGroupsBreachesNothing() throws {
        let events = [
            history("s1", day(1), [line("3")]),
            history("s2", day(8), [line("11")]),
        ]
        let products = [product("40")]

        try assertParity(events: events, products: products)

        let outcome = try #require(liveCheck(events: events, products: products).outcomes.first)
        #expect(outcome.blocks[0].evaluation.breaches.isEmpty)
        #expect(outcome.status == .goodFit)
    }

    // MARK: - Scenario 3: multi-active FRAC 3+7

    @Test func coformulationRetainsEveryGroupItCarries() throws {
        let events = [
            history("s1", day(1), [line("3")]),
            history("s2", day(8), [line("3", "7")]),
        ]
        let products = [product("3", "7")]

        try assertParity(events: events, products: products)

        let live = liveCheck(events: events, products: products)
        let outcome = try #require(live.outcomes.first)
        // The co-formulation counts as Group 3 — a third consecutive one.
        let group3 = try finding(outcome, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        #expect(group3.observedValue == 3)
        #expect(group3.status == .wouldExceedLimit)
        // ...AND independently as Group 7, which has its own mixture rule. A
        // two-active product belongs to both groups; counting it once would let
        // half its chemistry escape the strategy entirely.
        let group7 = try finding(outcome, "AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE")
        #expect(group7.status != .notTriggered)
        #expect(product("3", "7").groups.codes == ["3", "7"])
        #expect(product("3", "7").groups.isCoformulation)
    }

    // MARK: - Scenario 4: repeated group separated by another group

    @Test func aGroupRepeatedAcrossAnInterveningGroupIsNotConsecutive() throws {
        let events = [
            history("s1", day(1), [line("3")]),
            history("s2", day(8), [line("11")]),
        ]
        let products = [product("3")]

        try assertParity(events: events, products: products)

        let outcome = try #require(liveCheck(events: events, products: products).outcomes.first)
        let consecutive = try finding(outcome, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        // The Group 11 spray breaks the run: this is a run of one, not of two.
        #expect(consecutive.observedValue == 1)
        #expect(consecutive.status != .wouldExceedLimit)
        #expect(outcome.status == .goodFit)
    }

    // MARK: - Scenario 5: multi-site M group

    @Test func multiSiteGroupCountsAsASprayWithoutTriggeringAGroupLimit() throws {
        let events = [
            history("s1", day(1), [line("M3")]),
            history("s2", day(8), [line("M3")]),
        ]
        let products = [product("M3")]

        try assertParity(events: events, products: products)

        let live = liveCheck(events: events, products: products)
        let outcome = try #require(live.outcomes.first)
        let evaluation = outcome.blocks[0].evaluation
        // A multi-site protectant carries no single-site resistance ceiling, so no
        // group rule fires...
        #expect(evaluation.breaches.isEmpty)
        // ...but it is still a disease spray, so it counts in the denominator every
        // percentage rule divides by. Dropping it would quietly inflate the share
        // that single-site chemistry is allowed.
        #expect(evaluation.totalDiseaseSpraysInSeason == 3)
        // The group is preserved verbatim rather than normalised away.
        #expect(ResistanceGroupSignature.of(["M3"]).codes == ["M3"])
    }

    // MARK: - Scenario 6: HRAC 9 versus FRAC 9

    @Test func hrac9IsNeverTreatedAsFrac9() throws {
        let frac = ResistanceGroupSignature.of(["FRAC 9"])
        let hrac = ResistanceGroupSignature.of(["HRAC 9"])
        let irac = ResistanceGroupSignature.of(["IRAC 9"])

        // The scheme survives normalisation. Before P7 all three collapsed to "9".
        #expect(frac.codes == ["FRAC:9"])
        #expect(hrac.codes == ["HRAC:9"])
        #expect(irac.codes == ["IRAC:9"])
        #expect(frac != hrac)
        #expect(hrac != irac)

        // Read by a FRAC strategy, only the FRAC code is Group 9. The herbicide and
        // the insecticide are not that chemistry and drop out entirely.
        #expect(frac.projected(into: .frac).codes == ["9"])
        #expect(hrac.projected(into: .frac).codes.isEmpty)
        #expect(irac.projected(into: .frac).codes.isEmpty)
        // ...and symmetrically, a FRAC code is not an HRAC one.
        #expect(frac.projected(into: .hrac).codes.isEmpty)
        #expect(hrac.projected(into: .hrac).codes == ["9"])
    }

    @Test func foreignSchemeChemistryCannotConsumeAFungicideAllowance() throws {
        // Two real Group 3 fungicide sprays, then a spray whose only chemistry is
        // HRAC 3 — a dinitroaniline herbicide, unrelated to the FRAC 3 DMIs.
        let events = [
            history("s1", day(1), [line("3")]),
            history("s2", day(8), [line("HRAC 3")]),
        ]
        let products = [product("3")]

        try assertParity(events: events, products: products)

        let outcome = try #require(liveCheck(events: events, products: products).outcomes.first)
        let consecutive = try finding(outcome, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        // The herbicide carries no FRAC chemistry, so it cannot extend the Group 3
        // run. Before P7 its bare "3" did exactly that, turning one real DMI spray
        // plus a knockdown into a reported run of three.
        #expect(consecutive.status != .wouldExceedLimit)
        #expect(!consecutive.status.isBreach)
        // Nor is it silently ignored: an application VineTrack cannot assess in this
        // strategy's terms suppresses a clean verdict rather than flattering it.
        #expect(outcome.status != .goodFit)
    }

    @Test func aForeignSchemeLineDoesNotInventGroupsForItsApplication() throws {
        let event = history("s1", day(1), [line("HRAC 9")])
        let projected = event.projected(into: .frac)
        #expect(projected.componentGroups.isEmpty)
        // The LINE survives — it really was in the tank, and its verification state
        // still governs how far the application can be trusted.
        #expect(projected.products.count == 1)
    }

    // MARK: - Scenario 7: unresolved group

    @Test func aSprayWithNoResolvableChemistryIsNeverACleanResult() throws {
        let unresolvedLine = ResistanceProductLine(
            lineId: "line-unknown",
            productName: "Unmatched product",
            savedChemicalId: nil,
            groups: .empty,
            availability: .unavailable
        )
        let events = [
            history("s1", day(1), [line("3")]),
            history("s2", day(8), [unresolvedLine]),
        ]
        let products = [product("11")]

        try assertParity(events: events, products: products)

        let live = liveCheck(events: events, products: products)
        let outcome = try #require(live.outcomes.first)
        let evaluation = outcome.blocks[0].evaluation
        // The arithmetic breaches nothing, and that is exactly the trap: the spray
        // nobody can identify could be the one that breaks the rotation.
        #expect(evaluation.breaches.isEmpty)
        #expect(evaluation.unassessableApplicationIds.contains("s2"))
        #expect(!evaluation.isCleanResult)
        #expect(evaluation.status == .unableToFullyAssess)
        #expect(outcome.status == .unableToFullyAssess)
        #expect(live.status == .unableToFullyAssess)
    }

    @Test func aCandidateWithNoGroupsCannotBeCalledAGoodFit() throws {
        let events = [history("s1", day(1), [line("3")])]
        let products = [
            ResistancePlannedProduct(
                id: "candidate-product",
                groups: .empty,
                source: .savedChemical,
                savedChemicalId: "saved-unknown",
                productName: "Unmatched product",
                chemicalAvailability: .unavailable
            )
        ]

        try assertParity(events: events, products: products)

        let outcome = try #require(liveCheck(events: events, products: products).outcomes.first)
        #expect(outcome.status != .goodFit)
    }

    // MARK: - Scenario 8: manually entered / unverified chemical

    @Test func unverifiedChemistryNeverReadsAsAConfidentPass() throws {
        let events = [history("s1", day(1), [line("11")])]
        let products = [product("3", availability: .availableUnverified)]

        try assertParity(events: events, products: products)

        let live = liveCheck(events: events, products: products)
        let outcome = try #require(live.outcomes.first)
        // Nothing is breached, but the chemistry rests on the operator's own typing,
        // so the verdict is qualified rather than clean.
        #expect(outcome.blocks[0].evaluation.breaches.isEmpty)
        #expect(outcome.status == .needsReview)

        // The same rotation with verified chemistry IS a good fit \u2014 proving the
        // downgrade comes from the evidence, not from the arithmetic.
        let verified = liveCheck(events: events, products: [product("3")])
        #expect(try #require(verified.outcomes.first).status == .goodFit)
    }

    @Test func authoritativeStructuredGroupsOutrankTheLegacyCodeArray() throws {
        // A snapshot whose structured active says HRAC 3, while the denormalised
        // legacy array still says a bare "3".
        let snapshot = ChemicalLineSnapshot(
            savedChemicalId: "saved-1",
            productName: "Herbicide",
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Trifluralin",
                    activityGroup: ChemicalActivityGroup(scheme: .hrac, code: "3")
                )
            ],
            activityGroupCodes: ["3"],
            verificationStatus: .verified
        )
        // The classification wins. The bare copy is a convenience column, not
        // evidence, and it must never override the scheme the register recorded.
        #expect(ResistanceEventSource.groups(from: snapshot).codes == ["HRAC:3"])
        #expect(ResistanceEventSource.groups(from: snapshot).projected(into: .frac).codes.isEmpty)

        // With no structured classification at all, the legacy array is the only
        // thing there and stays usable \u2014 bare, and resolved by the reading ruleset.
        let legacyOnly = ChemicalLineSnapshot(
            productName: "Legacy fungicide",
            activityGroupCodes: ["3"],
            verificationStatus: .unverified
        )
        #expect(ResistanceEventSource.groups(from: legacyOnly).codes == ["3"])
        #expect(ResistanceEventSource.groups(from: legacyOnly).projected(into: .frac).codes == ["3"])

        // A missing snapshot is an absence of information, never an absence of risk.
        #expect(ResistanceEventSource.groups(from: nil).codes.isEmpty)
    }

    @Test func aBareCodeAndItsQualifiedFormAreOneGroupNotACoformulation() throws {
        let signature = ResistanceGroupSignature.of(["3", "FRAC 3"])
        #expect(signature.codes == ["FRAC:3"])
        #expect(!signature.isCoformulation)
        // Genuinely different schemes sharing a number stay two distinct groups.
        let mixed = ResistanceGroupSignature.of(["FRAC 3", "IRAC 3"])
        #expect(mixed.codes == ["FRAC:3", "IRAC:3"])
    }

    // MARK: - Scenario 9: previous-season versus current-season history

    @Test func crossSeasonRunsContinueAcrossTheSeasonBoundary() throws {
        // Two Group 3 sprays at the END of last season, none yet this season.
        let events = [
            history("prev1", previousSeasonDay(300), [line("3")]),
            history("prev2", previousSeasonDay(320), [line("3")]),
        ]
        let products = [product("3")]

        try assertParity(events: events, products: products)

        let live = liveCheck(events: events, products: products)
        let outcome = try #require(live.outcomes.first)
        let evaluation = outcome.blocks[0].evaluation
        // The consecutive rule explicitly crosses the boundary, so this is a third
        // consecutive Group 3 even though it is the season's first spray.
        let consecutive = try finding(outcome, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        #expect(consecutive.observedValue == 3)
        #expect(consecutive.status == .wouldExceedLimit)
        // Seasonal COUNTS, however, do not inherit last season: only the candidate
        // falls inside this season.
        #expect(evaluation.totalDiseaseSpraysInSeason == 1)
        #expect(evaluation.consideredApplicationIds == ["plan:spray-calculator-candidate:position:candidate"])
    }

    @Test func lastSeasonsSpraysDoNotFillThisSeasonsQuota() throws {
        let events = (1...4).map {
            history("prev\($0)", previousSeasonDay(100 + $0 * 10), [line("21")])
        }
        let products = [product("21")]

        try assertParity(events: events, products: products)

        let outcome = try #require(liveCheck(events: events, products: products).outcomes.first)
        let perCrop = try finding(outcome, "AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP")
        // Four Group 21 sprays last season, one now. The per-crop ceiling is a
        // seasonal one, so the observed count is this season's single application.
        #expect(perCrop.observedValue == 1)
        #expect(perCrop.status != .wouldExceedLimit)
    }

    // MARK: - Block and disease scoping

    @Test func eachBlockKeepsItsOwnHistoryOnBothSurfaces() throws {
        let events = [
            history("s1", day(1), [line("3")], block: blockA),
            history("s2", day(8), [line("3")], block: blockA),
        ]
        let products = [product("3")]

        try assertParity(events: events, products: products, blocks: [blockA, blockB])

        let live = liveCheck(events: events, products: products, blocks: [blockA, blockB])
        let outcome = try #require(live.outcomes.first)
        #expect(outcome.blocks.count == 2)
        let a = try #require(outcome.blocks.first { $0.blockId == blockA })
        let b = try #require(outcome.blocks.first { $0.blockId == blockB })
        // Block A has had two Group 3 sprays; block B has had none. They must not
        // be merged \u2014 block A's rotation says nothing about block B's vines.
        #expect(a.status == .wouldExceedStrategy)
        #expect(b.status == .goodFit)
        // The worst block governs the headline, so the panel cannot look clean
        // while one selected block is already over.
        #expect(outcome.status == .wouldExceedStrategy)
    }

    @Test func eachDiseaseIsAskedSeparately() throws {
        let events = [
            history("s1", day(1), [line("3")], targets: [.powderyMildew]),
            history("s2", day(8), [line("3")], targets: [.powderyMildew]),
        ]
        let products = [product("3")]
        let live = liveCheck(
            events: events,
            products: products,
            diseases: [.powderyMildew, .downyMildew]
        )
        #expect(live.outcomes.count == 2)
        let powdery = try #require(live.outcomes.first { $0.disease == .powderyMildew })
        let downy = try #require(live.outcomes.first { $0.disease == .downyMildew })
        // A Group 3 spray applied FOR powdery must not consume a downy allowance.
        #expect(powdery.status == .wouldExceedStrategy)
        #expect(downy.status != .wouldExceedStrategy)
        // The headline is the worst across diseases.
        #expect(live.status == .wouldExceedStrategy)

        // ...and each disease matches its own standalone plan.
        try assertParity(events: events, products: products, disease: .powderyMildew)
        try assertParity(events: events, products: products, disease: .downyMildew)
    }

    // MARK: - Applicability

    @Test func theCheckStaysSilentRatherThanReassuring() throws {
        let events = [history("s1", day(1), [line("3")])]
        // No resistance-relevant target.
        #expect(SprayResistanceCheck.diseases(from: [.weeds, .nutritionBiostimulant]).isEmpty)
        // No disease, no block, or no chemistry: nothing to say, and nothing is said.
        #expect(!liveCheck(events: events, products: [product("3")], diseases: []).isApplicable)
        #expect(!liveCheck(events: events, products: [], diseases: [.powderyMildew]).isApplicable)
        #expect(!liveCheck(events: events, products: [product("3")], blocks: []).isApplicable)
        #expect(SprayResistanceCheck.Result.notApplicable.status == nil)
        #expect(SprayResistanceCheck.Result.notApplicable.findings(forProductId: "x").isEmpty)
    }

    @Test func targetsMapOntoTheDiseasesThatHaveAStrategy() throws {
        #expect(
            SprayResistanceCheck.diseases(from: [.powderyMildew, .downyMildew])
                == [.powderyMildew, .downyMildew]
        )
        // Botrytis is resistance-relevant but carries no VineTrack strategy yet, so
        // it produces no disease rather than an invented verdict.
        #expect(SprayResistanceCheck.diseases(from: [.botrytis]).isEmpty)
    }

    @Test func anUnsupportedJurisdictionIsStatedNotPassed() throws {
        let live = SprayResistanceCheck.evaluate(
            SprayResistanceCheck.Request(
                vineyardId: vineyardId,
                blockIds: [blockA],
                diseases: [.powderyMildew],
                products: [product("3")],
                jurisdiction: .unknown,
                season: season,
                seasonCalendar: calendar,
                events: [history("s1", day(1), [line("3")])],
                nowMs: day(30)
            )
        )
        let outcome = try #require(live.outcomes.first)
        #expect(!outcome.isSupported)
        #expect(outcome.status == .unableToFullyAssess)
        #expect(outcome.unsupportedMessage == ResistancePlanner.unsupportedJurisdictionMessage)
    }

    // MARK: - Findings routed to the right product line

    @Test func aFindingAppearsUnderTheProductThatCarriesItsGroup() throws {
        let events = [
            history("s1", day(1), [line("3")]),
            history("s2", day(8), [line("3")]),
        ]
        let products = [
            product("3", id: "line-dmi"),
            product("40", id: "line-cAA"),
        ]
        let live = liveCheck(events: events, products: products)

        let dmiFindings = live.findings(forProductId: "line-dmi")
        let otherFindings = live.findings(forProductId: "line-cAA")
        #expect(dmiFindings.contains { $0.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE" })
        // The Group 3 consecutive warning is not shown under the Group 40 product:
        // it is not that tin's problem.
        #expect(!otherFindings.contains { $0.ruleId == "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE" })
        // An unknown product id yields nothing rather than everything.
        #expect(live.findings(forProductId: "no-such-line").isEmpty)
    }

    // MARK: - Group code canonicalisation

    @Test func groupCodeNormalisationKeepsPublishedSpellingsTogether() throws {
        // Legacy alias and renumbering still resolve to one key...
        #expect(ResistanceGroupSignature.of(["U8"]).codes == ["50"])
        #expect(ResistanceGroupSignature.of(["Group 50 (U8)"]).codes == ["50"])
        #expect(ResistanceGroupSignature.of(["group 11"]).codes == ["11"])
        // ...while a stated scheme is retained rather than stripped.
        #expect(ResistanceGroupSignature.of(["FRAC 50 (U8)"]).codes == ["FRAC:50"])
        #expect(ResistanceGroupSignature.of(["frac:11"]).codes == ["FRAC:11"])
        // Empty and scheme-only inputs produce no group at all.
        #expect(ResistanceGroupSignature.of(["", "  ", "FRAC"]).codes.isEmpty)
        // Ordering is by number, so a signature's key never depends on entry order.
        #expect(ResistanceGroupSignature.of(["11", "3"]).key == "3+11")
        #expect(ResistanceGroupSignature.of(["3", "11"]).key == "3+11")
    }

    @Test func nonFracGroupsAreNamedInFullWhenDisplayed() throws {
        #expect(ResistanceGroupSignature.of(["3", "11"]).displayLabel == "FRAC 3 + 11")
        #expect(ResistanceGroupSignature.of(["FRAC 3"]).displayLabel == "FRAC 3")
        // A herbicide group must not be presented under a FRAC heading.
        #expect(ResistanceGroupSignature.of(["HRAC 9"]).displayLabel == "HRAC 9")
        #expect(ResistanceGroupSignature.empty.displayLabel == "No group recorded")
    }
}
