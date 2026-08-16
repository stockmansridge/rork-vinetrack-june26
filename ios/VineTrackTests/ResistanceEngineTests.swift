import Foundation
import Testing

@testable import VineTrack

/// Behaviour of the Resistance Rules Engine against the CropLife Australia 2026 grape
/// strategies.
///
/// Mirrors Android `ResistanceEngineTest.kt`.
@Suite("Resistance engine evaluation")
struct ResistanceEngineTests {

    private let calendar = ResistanceSeasonCalendar()
    private var season: ResistanceSeason { calendar.seasonStarting(2026) }
    private var previousSeason: ResistanceSeason { calendar.previous(season) }

    private let blockA = "block-a"
    private let blockB = "block-b"

    private let powderyTargets: [ResistanceDisease] = [.powderyMildew]
    private let downyTargets: [ResistanceDisease] = [.downyMildew]

    private func day(_ offset: Int) -> Int64 {
        season.startEpochMs + Int64(offset) * 86_400_000
    }

    private func previousSeasonDay(_ offset: Int) -> Int64 {
        previousSeason.startEpochMs + Int64(offset) * 86_400_000
    }

    private func p(
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

    /// A product line with no usable chemistry at all — a pre-snapshot record.
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
        targetsRecorded: Bool = true,
        mixtureConfirmed: Bool? = nil
    ) -> ResistanceApplicationEvent {
        ResistanceApplicationEvent(
            applicationId: id,
            kind: kind,
            appliedAtEpochMs: epochMs,
            seasonId: calendar.season(epochMs: epochMs).id,
            vineyardId: "vineyard-1",
            blockId: block ?? blockA,
            targets: targets ?? powderyTargets,
            targetsRecorded: targetsRecorded,
            products: products,
            mixturePartnerAtLabelRate: mixtureConfirmed
        )
    }

    private func evaluate(
        _ events: [ResistanceApplicationEvent],
        candidate: ResistanceApplicationEvent? = nil,
        disease: ResistanceDisease = .powderyMildew,
        block: String? = nil,
        jurisdiction: ResistanceJurisdiction = .australia,
        includePlanned: Bool = false
    ) -> ResistanceEvaluation {
        ResistanceEngine.evaluate(
            ResistanceEvaluationRequest(
                jurisdiction: jurisdiction,
                crop: .grape,
                disease: disease,
                blockId: block ?? blockA,
                season: season,
                seasonCalendar: calendar,
                events: events,
                candidate: candidate,
                includePlanned: includePlanned
            )
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

    // MARK: - Jurisdiction isolation

    @Test("New Zealand vineyard returns unsupported ruleset and runs no Australian rules")
    func newZealandIsolated() {
        let events = [
            ev("s1", day(1), [p("3")]),
            ev("s2", day(8), [p("3")]),
            ev("s3", day(15), [p("3")]),
        ]
        let result = evaluate(events, jurisdiction: .newZealand)
        #expect(result.status == .unsupportedRuleset)
        // Three consecutive Group 3 sprays would breach the AU strategy. No AU rule may
        // run for a New Zealand vineyard.
        #expect(result.ruleResults.isEmpty)
        #expect(result.rulesetId == nil)
        #expect(result.isCleanResult == false)
        #expect(result.summary.contains("not yet configured for this jurisdiction"))
    }

    @Test("Unknown jurisdiction returns unsupported ruleset")
    func unknownJurisdictionIsolated() {
        let result = evaluate([ev("s1", day(1), [p("3")])], jurisdiction: .unknown)
        #expect(result.status == .unsupportedRuleset)
        #expect(result.ruleResults.isEmpty)
    }

    @Test("Unsupported jurisdiction applies to downy as well as powdery")
    func unsupportedAppliesToDowny() {
        let result = evaluate(
            [ev("s1", day(1), [p("40")], targets: downyTargets)],
            disease: .downyMildew,
            jurisdiction: .newZealand
        )
        #expect(result.status == .unsupportedRuleset)
    }

    // MARK: - Ruleset attribution

    @Test("Evaluation records which ruleset and version judged the sequence")
    func rulesetAttribution() {
        let result = evaluate([ev("s1", day(1), [p("3")])])
        #expect(result.rulesetId == "AU_GRAPE_POWDERY_2026_07_22")
        #expect(result.rulesetVersion == "2026.07.22")
        #expect(result.rulesetValidFrom == "2026-07-22")
        #expect(result.seasonId == season.id)
        for entry in result.ruleResults {
            #expect(entry.rulesetId == "AU_GRAPE_POWDERY_2026_07_22")
            #expect(entry.rulesetVersion == "2026.07.22")
        }
    }

    @Test("Downy evaluation records the downy ruleset")
    func downyAttribution() {
        let result = evaluate(
            [ev("s1", day(1), [p("40")], targets: downyTargets)],
            disease: .downyMildew
        )
        #expect(result.rulesetId == "AU_GRAPE_DOWNY_2026_07_22")
    }

    // MARK: - Powdery consecutive rules

    @Test("Two consecutive group 3 powdery sprays reach the consecutive maximum")
    func twoConsecutiveGroup3() throws {
        let events = [ev("s1", day(1), [p("3")]), ev("s2", day(8), [p("3")])]
        let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        #expect(result.status == .limitReached)
        #expect(result.threshold == 2.0)
        #expect(result.observedValue == 2.0)
        #expect(result.severity == .warning)
        #expect(result.contributingApplicationIds == ["s1", "s2"])
    }

    @Test("A third consecutive group 3 candidate would exceed the consecutive maximum")
    func thirdConsecutiveGroup3Candidate() throws {
        let events = [ev("s1", day(1), [p("3")]), ev("s2", day(8), [p("3")])]
        let evaluation = evaluate(events, candidate: ev("candidate", day(15), [p("3")]))
        let result = try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        #expect(result.status == .wouldExceedLimit)
        #expect(result.observedValue == 3.0)
        #expect(result.severity == .critical)
        #expect(evaluation.status == .strategyExceeded)
        #expect(evaluation.candidateApplicationId == "candidate")
        #expect(result.explanation.contains("consecutive Group 3 application number 3"))
    }

    @Test("Three group 3 sprays in existing history exceed the consecutive maximum")
    func threeGroup3History() throws {
        let events = [
            ev("s1", day(1), [p("3")]), ev("s2", day(8), [p("3")]), ev("s3", day(15), [p("3")]),
        ]
        let evaluation = evaluate(events)
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status == .limitExceeded)
        #expect(evaluation.status == .strategyExceeded)
    }

    @Test("An intervening different group resets the consecutive run")
    func interveningGroupResetsRun() throws {
        let events = [
            ev("s1", day(1), [p("3")]),
            ev("s2", day(8), [p("3")]),
            ev("s3", day(15), [p("13")]),
            ev("s4", day(22), [p("3")]),
        ]
        let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        // Longest run is still 2, not 3.
        #expect(result.observedValue == 2.0)
        #expect(result.status == .limitReached)
    }

    @Test("Every group carrying the two-consecutive restriction is enforced")
    func allTwoConsecutiveGroups() throws {
        for (code, fragment) in [
            ("3", "FRAC3"), ("5", "FRAC5"), ("13", "FRAC13"), ("19", "FRAC19"),
            ("21", "FRAC21"), ("50", "FRAC50"), ("U6", "FRACU6"),
        ] {
            let events = (1...3).map { ev("s\($0)", day($0 * 7), [p(code)]) }
            let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_\(fragment)_MAX_CONSECUTIVE")
            #expect(result.status == .limitExceeded, "group \(code) should exceed at three consecutive")
        }
    }

    @Test("Legacy U8 spelling is enforced as group 50")
    func legacyU8Enforced() throws {
        let events = [
            ev("s1", day(1), [p("U8")]),
            ev("s2", day(8), [p("50")]),
            ev("s3", day(15), [p("Group 50 (U8)")]),
        ]
        let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC50_MAX_CONSECUTIVE")
        // All three spellings must meet, or the run would never be detected.
        #expect(result.status == .limitExceeded)
        #expect(result.observedValue == 3.0)
    }

    // MARK: - Cross-season consecutive handling

    @Test("Powdery consecutive runs continue from the end of one season into the next")
    func crossSeasonConsecutive() throws {
        // Two Group 3 sprays late in the previous season, then one early this season.
        // CropLife counts that as three consecutive.
        let events = [
            ev("prev1", previousSeasonDay(300), [p("3")]),
            ev("prev2", previousSeasonDay(310), [p("3")]),
        ]
        let evaluation = evaluate(events, candidate: ev("candidate", day(5), [p("3")]))
        let result = try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        #expect(result.status == .wouldExceedLimit)
        #expect(result.observedValue == 3.0)
        #expect(
            result.explanation.contains("continues from the previous season"),
            "explanation must say the run crosses the season boundary"
        )
    }

    @Test("Seasonal counts do not include the previous season")
    func seasonalCountsExcludePreviousSeason() throws {
        let events = [
            ev("prev1", previousSeasonDay(300), [p("21")]),
            ev("prev2", previousSeasonDay(310), [p("21")]),
            ev("prev3", previousSeasonDay(320), [p("21")]),
            ev("s1", day(5), [p("21")]),
        ]
        let evaluation = evaluate(events)
        // Three Group 21 sprays last season must not consume this season's allowance.
        #expect(evaluation.totalDiseaseSpraysInSeason == 1)
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP").observedValue == 1.0)
        #expect(evaluation.consideredApplicationIds == ["s1"])
    }

    @Test("A non-cross-season rule ignores the previous season entirely")
    func nonCrossSeasonRuleIgnoresPrevious() throws {
        let events = [
            ev("prev1", previousSeasonDay(300), [p("5", "3")]),
            ev("s1", day(5), [p("5", "3")]),
        ]
        // Group 5+3 is one application per season, and last season's use does not carry
        // over.
        let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON")
        #expect(result.status == .limitReached)
        #expect(result.observedValue == 1.0)
    }

    // MARK: - Group 5+3 and shared table column

    @Test("A second group 5 plus 3 candidate would exceed the one-application maximum")
    func secondFivePlusThreeExceeds() throws {
        let events = [ev("s1", day(1), [p("5", "3")]), ev("s2", day(8), [p("13")])]
        let evaluation = evaluate(events, candidate: ev("candidate", day(15), [p("5", "3")]))
        #expect(
            try rule(evaluation, "AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON").status == .wouldExceedLimit
        )
        #expect(evaluation.status == .strategyExceeded)
    }

    @Test("A tank mix of separate group 5 and group 3 products is not a group 5 plus 3 product")
    func tankMixIsNotCoformulation() throws {
        // The published Group 5+3 restriction addresses the co-formulation. A tank mix of
        // two solo products is a mixture, not that product, and must not silently consume
        // the co-formulation's single-application allowance.
        let evaluation = evaluate([ev("s1", day(1), [p("5"), p("3")])])
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON").status == .notTriggered)
        // It still counts against both component groups.
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_FROM_TOTAL_TABLE").observedValue == 1.0)
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC5_MAX_FROM_TOTAL_TABLE").observedValue == 1.0)
    }

    @Test("Group 5 plus 3 counts toward the shared table column with group 7 plus 12")
    func sharedTableColumn() throws {
        let events = [
            ev("s1", day(1), [p("5", "3")]),
            ev("s2", day(8), [p("13")]),
            ev("s3", day(15), [p("7", "12")]),
        ]
        let shared = try rule(
            evaluate(events),
            "AU_GRAPE_POWDERY_FRAC5_PLUS_3_AND_7_PLUS_12_MAX_FROM_TOTAL_TABLE"
        )
        // The published table gives 5+3 and 7+12 ONE shared column with a maximum of 1,
        // so two applications between them exceeds it.
        #expect(shared.status == .limitExceeded)
        #expect(shared.observedValue == 2.0)
        #expect(shared.threshold == 1.0)
    }

    @Test("Group 7 plus 12 also counts within the group 7 table column")
    func sevenPlusTwelveCountsAsSeven() throws {
        let evaluation = evaluate([ev("s1", day(1), [p("7", "12")])])
        // Contains Group 7, so it counts in "7 (inc. 7+3)" as well as the shared column.
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC7_MAX_FROM_TOTAL_TABLE").observedValue == 1.0)
        #expect(
            try rule(evaluation, "AU_GRAPE_POWDERY_FRAC5_PLUS_3_AND_7_PLUS_12_MAX_FROM_TOTAL_TABLE")
                .observedValue == 1.0
        )
    }

    // MARK: - Combination products

    @Test("Group 11 plus 3 contributes to both group 11 and group 3 rules")
    func elevenPlusThreeContributesToBoth() throws {
        let events = [ev("s1", day(1), [p("11", "3")]), ev("s2", day(8), [p("11", "3")])]
        let evaluation = evaluate(events)
        // Guideline 4 restricts Group 3 "including mixture formulations".
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status == .limitReached)
        // And the table's "11 (inc. 11+3)" column counts it as Group 11.
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE").observedValue == 2.0)
    }

    @Test("A combination product is not reduced to one arbitrary primary group")
    func combinationKeepsBothGroups() {
        let event = ev("s1", day(1), [p("11", "3")])
        #expect(event.componentGroups == Set(["3", "11"]))
        #expect(event.coformulationSignatures.map(\.key) == ["3+11"])
    }

    // MARK: - Group 21 crop maximum and percentage

    @Test("Group 21 percentage restriction binds before the crop maximum in a short season")
    func group21PercentageBinds() throws {
        // Three powdery sprays, two Group 21. The crop maximum of 3 is not reached, but
        // 2 of 3 is above 33%, and CropLife says whichever is lower governs.
        let events = [
            ev("s1", day(1), [p("21")]),
            ev("s2", day(8), [p("13")]),
            ev("s3", day(15), [p("21")]),
        ]
        let evaluation = evaluate(events)
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP").status == .approachingLimit)
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION").status == .limitExceeded)
        #expect(evaluation.status == .strategyExceeded)
    }

    @Test("Two group 21 sprays in six is exactly one third and does not exceed")
    func group21ExactlyOneThird() throws {
        let events = (1...6).map { ev("s\($0)", day($0 * 7), [$0 <= 2 ? p("21") : p("13")]) }
        let fraction = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")
        // 2 of 6 compares as 2 x 3 <= 6 x 1. A rounded display percentage would read
        // 33.33% and wrongly exceed a 33% cap.
        #expect(fraction.observedValue == 2.0)
        #expect(fraction.threshold == 2.0)
        #expect(fraction.status == .limitReached)
    }

    @Test("Percentage denominator counts disease applications not products or tank lines")
    func percentageDenominatorIsApplications() throws {
        // One spray, three products. The denominator is 1 application, not 3 lines.
        let evaluation = evaluate([ev("s1", day(1), [p("21"), p("13"), p("19")])])
        #expect(evaluation.totalDiseaseSpraysInSeason == 1)
        let fraction = try rule(evaluation, "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")
        #expect(fraction.observedValue == 1.0)
        // 1 of 1 is 100%, above the 33% maximum.
        #expect(fraction.status == .limitExceeded)
    }

    @Test("Percentage denominator excludes other diseases and other blocks")
    func percentageDenominatorScoped() {
        let events = [
            ev("s1", day(1), [p("21")]),
            ev("s2", day(8), [p("40")], targets: downyTargets),
            ev("s3", day(15), [p("13")], block: blockB),
            ev("s4", day(22), [p("13")]),
            ev("s5", day(29), [p("13")]),
        ]
        let evaluation = evaluate(events)
        // Only s1, s4, s5 are powdery sprays on block A.
        #expect(evaluation.totalDiseaseSpraysInSeason == 3)
        #expect(evaluation.consideredApplicationIds == ["s1", "s4", "s5"])
    }

    // MARK: - Total-spray-count table

    @Test("Table ceiling moves with the season total spray count")
    func tableCeilingMoves() throws {
        // At 2 total sprays the table permits only 1 Group 11.
        let twoSprays = [ev("s1", day(1), [p("11")]), ev("s2", day(8), [p("11")])]
        let short = try rule(evaluate(twoSprays), "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        #expect(short.threshold == 1.0)
        #expect(short.status == .limitExceeded)

        // At 3 total sprays the table permits 2 Group 11, so the same two sprays no
        // longer exceed anything. The ceiling MOVED.
        let threeSprays = twoSprays + [ev("s3", day(15), [p("13")])]
        let longer = try rule(evaluate(threeSprays), "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        #expect(longer.threshold == 2.0)
        #expect(longer.status.isBreach == false)
    }

    @Test("A provisional table ceiling reports no maximum reached mid-season")
    func provisionalCeilingNotReached() throws {
        // The published table permits one application of every group when only one spray
        // targets the disease. Reporting "maximum reached" after a single spray would be
        // misleading, because the ceiling rises as the season grows.
        let table = try rule(
            evaluate([ev("s1", day(1), [p("13")])]),
            "AU_GRAPE_POWDERY_FRAC13_MAX_FROM_TOTAL_TABLE"
        )
        #expect(table.threshold == 1.0)
        #expect(table.observedValue == 1.0)
        #expect(table.status == .withinLimit)
        #expect(table.explanation.contains("ceiling rises"))
    }

    @Test("A table ceiling at or above the open-ended row is final and can be reached")
    func openEndedCeilingIsFinal() throws {
        // At nine or more powdery sprays the table stops moving, so "reached" is real
        // information rather than an artefact of a short season.
        let events = (1...9).map { ev("s\($0)", day($0 * 7), [$0 <= 2 ? p("11") : p("13")]) }
        let table = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        #expect(table.threshold == 2.0)
        #expect(table.status == .limitReached)
    }

    @Test("Table threshold for a candidate uses the total the engine can actually see")
    func candidateTableThreshold() throws {
        // Three applied powdery sprays plus a candidate is a known total of 4, so the
        // Group 3 ceiling is the table's value at 4. The engine never invents future
        // sprays to unlock a higher ceiling.
        let events = [
            ev("s1", day(1), [p("3")]),
            ev("s2", day(8), [p("13")]),
            ev("s3", day(15), [p("3")]),
        ]
        let evaluation = evaluate(events, candidate: ev("candidate", day(22), [p("3")]))
        let table = try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_FROM_TOTAL_TABLE")
        #expect(evaluation.totalDiseaseSpraysInSeason == 4)
        #expect(table.threshold == 2.0)
        #expect(table.observedValue == 3.0)
        #expect(table.status == .wouldExceedLimit)
    }

    // MARK: - Mixture when consecutive

    @Test("Consecutive solo group 7 sprays fail the mixture requirement")
    func consecutiveSoloGroup7Fails() throws {
        let events = [ev("s1", day(1), [p("7")]), ev("s2", day(8), [p("7")])]
        let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE")
        #expect(result.status == .requirementNotMet)
        #expect(result.mixtureRequirement == .notSatisfied)
        #expect(result.severity == .critical)
    }

    @Test("A single group 7 spray carries no mixture requirement")
    func singleGroup7NoRequirement() throws {
        let result = try rule(
            evaluate([ev("s1", day(1), [p("7")])]),
            "AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE"
        )
        // The published requirement applies only to consecutive use.
        #expect(result.status == .notTriggered)
        #expect(result.mixtureRequirement == nil)
    }

    @Test("Consecutive group 7 with an unconfirmed partner returns unknown not satisfied")
    func unconfirmedPartnerIsUnknown() throws {
        // Six powdery sprays so the table permits the two Group 7 applications and the
        // only outstanding question is the mixture itself.
        let events = [
            ev("s1", day(1), [p("7"), p("13")]),
            ev("s2", day(8), [p("7"), p("13")]),
            ev("s3", day(15), [p("19")]),
            ev("s4", day(22), [p("50")]),
            ev("s5", day(29), [p("19")]),
            ev("s6", day(36), [p("50")]),
        ]
        let evaluation = evaluate(events)
        let result = try rule(evaluation, "AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE")
        // A second FRAC code does not prove the partner was applied at an effective rate,
        // so the requirement is unproven, never satisfied.
        #expect(result.status == .requirementUnproven)
        #expect(result.mixtureRequirement == .unknown)
        #expect(result.severity == .indeterminate)
        // And an unproven requirement can never present as a clean pass.
        #expect(evaluation.status == .unableToFullyAssess)
        #expect(evaluation.isCleanResult == false)
    }

    @Test("Consecutive group 7 with a confirmed label-rate partner satisfies the mixture rule")
    func confirmedPartnerSatisfies() throws {
        let events = [
            ev("s1", day(1), [p("7"), p("13")], mixtureConfirmed: true),
            ev("s2", day(8), [p("7"), p("13")], mixtureConfirmed: true),
        ]
        let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE")
        #expect(result.status == .withinLimit)
        #expect(result.mixtureRequirement == .satisfied)
    }

    @Test("Consecutive group 11 sprays fail the mixture requirement")
    func consecutiveGroup11Fails() throws {
        let events = [ev("s1", day(1), [p("11")]), ev("s2", day(8), [p("11")])]
        #expect(
            try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC11_MIXTURE_WHEN_CONSECUTIVE").status
                == .requirementNotMet
        )
    }

    // MARK: - Application-event grouping

    @Test("One spray with two groups is one event contributing to each group once")
    func oneSprayTwoGroups() throws {
        let evaluation = evaluate([ev("s1", day(1), [p("3"), p("11")])])
        #expect(evaluation.totalDiseaseSpraysInSeason == 1)
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_FROM_TOTAL_TABLE").observedValue == 1.0)
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE").observedValue == 1.0)
    }

    @Test("Two products of the same group in one tank count as one application")
    func sameGroupTwiceInOneTank() throws {
        let evaluation = evaluate([
            ev("s1", day(1), [p("11", lineId: "a"), p("11", lineId: "b")]),
        ])
        // Resistance counting happens at application-event level, not per line.
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE").observedValue == 1.0)
        #expect(evaluation.totalDiseaseSpraysInSeason == 1)
    }

    @Test("Two products of the same group in one tank are not a consecutive pair")
    func sameGroupTwiceIsNotConsecutive() throws {
        let result = try rule(
            evaluate([ev("s1", day(1), [p("3", lineId: "a"), p("3", lineId: "b")])]),
            "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE"
        )
        #expect(result.observedValue == 1.0)
        #expect(result.status != .limitReached)
    }

    @Test("Same-day sprays remain distinct application events")
    func sameDaySpraysAreDistinct() throws {
        // A morning job and an afternoon job are two applications. Date is not event
        // identity.
        let events = [
            ev("morning", day(1), [p("3")]),
            ev("afternoon", day(1), [p("3")]),
            ev("next", day(2), [p("3")]),
        ]
        let evaluation = evaluate(events)
        #expect(evaluation.totalDiseaseSpraysInSeason == 3)
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status == .limitExceeded)
    }

    // MARK: - Deterministic ordering

    @Test("Results are identical regardless of input array ordering")
    func deterministicOrdering() {
        let events = [
            ev("s1", day(1), [p("3")]),
            ev("s2", day(8), [p("13")]),
            ev("s3", day(15), [p("3")]),
            ev("s4", day(22), [p("21")]),
        ]
        let forward = evaluate(events)
        let reversed = evaluate(events.reversed())
        let shuffled = evaluate([events[2], events[0], events[3], events[1]])

        for other in [reversed, shuffled] {
            #expect(forward.status == other.status)
            #expect(forward.consideredApplicationIds == other.consideredApplicationIds)
            #expect(forward.totalDiseaseSpraysInSeason == other.totalDiseaseSpraysInSeason)
            #expect(forward.ruleResults.map(\.ruleId) == other.ruleResults.map(\.ruleId))
            #expect(forward.ruleResults.map(\.status) == other.ruleResults.map(\.status))
            #expect(forward.ruleResults.map(\.observedValue) == other.ruleResults.map(\.observedValue))
        }
    }

    @Test("Same-date events order deterministically by application id")
    func sameDateTieBreak() {
        let a = ev("aaa", day(1), [p("3")])
        let b = ev("bbb", day(1), [p("13")])
        let forward = evaluate([a, b])
        let backward = evaluate([b, a])
        #expect(forward.consideredApplicationIds == ["aaa", "bbb"])
        #expect(forward.consideredApplicationIds == backward.consideredApplicationIds)
    }

    // MARK: - Per-disease separation

    @Test("A group 11 downy spray does not increase the powdery group 11 count")
    func diseaseSeparation() throws {
        let events = [
            ev("powderySpray", day(1), [p("11")]),
            ev("downySpray", day(8), [p("11")], targets: downyTargets),
        ]
        let powderyResult = evaluate(events)
        let downyResult = evaluate(events, disease: .downyMildew)
        #expect(powderyResult.consideredApplicationIds == ["powderySpray"])
        #expect(downyResult.consideredApplicationIds == ["downySpray"])
        #expect(
            try rule(powderyResult, "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE").observedValue == 1.0
        )
        #expect(try rule(downyResult, "AU_GRAPE_DOWNY_FRAC11_MAX_SEASON").observedValue == 1.0)
    }

    @Test("A spray targeting both diseases contributes to both histories independently")
    func targetingBothDiseases() {
        let both: [ResistanceDisease] = [.powderyMildew, .downyMildew]
        let events = [ev("s1", day(1), [p("11")], targets: both)]
        #expect(evaluate(events).totalDiseaseSpraysInSeason == 1)
        #expect(evaluate(events, disease: .downyMildew).totalDiseaseSpraysInSeason == 1)
    }

    @Test("A spray targeting neither disease enters no resistance history")
    func targetingNeitherDisease() {
        let evaluation = evaluate([ev("weeds", day(1), [p("11")], targets: [])])
        // Recorded as targeting nothing is a FACT, so it is not an unknown.
        #expect(evaluation.status == .notApplicable)
        #expect(evaluation.unattributedApplicationIds.isEmpty)
    }

    @Test("Disease target is never inferred from the chemical group")
    func targetNeverInferredFromChemistry() {
        // A Group 40 product is a downy fungicide, but the operator recorded this spray as
        // targeting powdery mildew only. The engine honours the record.
        let events = [ev("s1", day(1), [p("40")], targets: powderyTargets)]
        #expect(evaluate(events, disease: .downyMildew).status == .notApplicable)
    }

    // MARK: - Per-block separation

    @Test("The same candidate produces different results on different blocks")
    func blockSeparation() throws {
        let events = [
            ev("a1", day(1), [p("11")], targets: downyTargets, block: blockA),
            ev("a2", day(8), [p("21")], targets: downyTargets, block: blockA),
            ev("a3", day(15), [p("11")], targets: downyTargets, block: blockA),
            ev("a4", day(22), [p("21")], targets: downyTargets, block: blockA),
            ev("b1", day(1), [p("11")], targets: downyTargets, block: blockB),
            ev("b2", day(8), [p("21")], targets: downyTargets, block: blockB),
        ]
        let candidateA = ev("cand", day(29), [p("11")], targets: downyTargets, block: blockA)
        let candidateB = ev("cand", day(29), [p("11")], targets: downyTargets, block: blockB)

        let resultA = evaluate(events, candidate: candidateA, disease: .downyMildew, block: blockA)
        let resultB = evaluate(events, candidate: candidateB, disease: .downyMildew, block: blockB)

        // Block A already has two Group 11 sprays; block B has one.
        #expect(try rule(resultA, "AU_GRAPE_DOWNY_FRAC11_MAX_SEASON").status == .wouldExceedLimit)
        #expect(try rule(resultB, "AU_GRAPE_DOWNY_FRAC11_MAX_SEASON").status == .wouldReachLimit)
        #expect(resultA.status == .strategyExceeded)
        #expect(resultB.status == .limitReached)
    }

    @Test("One spray across three blocks contributes one event to each block history")
    func multiBlockSpray() {
        let blocks = ["b1", "b2", "b3"]
        let events = blocks.map { ev("shared", day(1), [p("11")], block: $0) }
        for block in blocks {
            let evaluation = evaluate(events, block: block)
            #expect(evaluation.totalDiseaseSpraysInSeason == 1)
            #expect(evaluation.consideredApplicationIds == ["shared"])
        }
    }

    @Test("The vineyard is never evaluated as one homogeneous history")
    func vineyardNotHomogeneous() throws {
        let events = [
            ev("a1", day(1), [p("3")], block: blockA),
            ev("a2", day(8), [p("3")], block: blockA),
            ev("b1", day(15), [p("3")], block: blockB),
        ]
        // Three Group 3 sprays across the vineyard, but no block had three.
        #expect(
            try rule(evaluate(events, block: blockA), "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status
                == .limitReached
        )
        let blockBRule = try rule(
            evaluate(events, block: blockB), "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE"
        )
        #expect(blockBRule.observedValue == 1.0)
        #expect(blockBRule.status.isBreach == false)
        #expect(blockBRule.status.isAtLimit == false)
    }

    // MARK: - Downy rules

    @Test("Solo group 4 fails the always-mix requirement")
    func soloGroup4Fails() throws {
        let evaluation = evaluate(
            [ev("s1", day(1), [p("4")], targets: downyTargets)],
            disease: .downyMildew
        )
        let result = try rule(evaluation, "AU_GRAPE_DOWNY_FRAC4_MIXTURE_REQUIRED")
        #expect(result.status == .requirementNotMet)
        #expect(result.mixtureRequirement == .notSatisfied)
        #expect(evaluation.status == .strategyExceeded)
    }

    @Test("Three consecutive group 4 sprays exceed the consecutive maximum")
    func threeConsecutiveGroup4() throws {
        let events = (1...3).map {
            ev("s\($0)", day($0 * 7), [p("4"), p("21")], targets: downyTargets, mixtureConfirmed: true)
        }
        #expect(
            try rule(evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC4_MAX_CONSECUTIVE")
                .status == .limitExceeded
        )
    }

    @Test("Consecutive group 11 downy sprays breach the non-consecutive rule")
    func downyGroup11Consecutive() throws {
        let events = [
            ev("s1", day(1), [p("11")], targets: downyTargets),
            ev("s2", day(8), [p("11")], targets: downyTargets),
        ]
        let result = try rule(
            evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE"
        )
        #expect(result.status == .limitExceeded)
        #expect(result.threshold == 1.0)
        #expect(result.thresholdDescription.contains("must not be applied consecutively"))
    }

    @Test("Group 11 plus 3 counts as group 11 for the downy non-consecutive rule")
    func downyElevenPlusThreeConsecutive() throws {
        let events = [
            ev("s1", day(1), [p("11")], targets: downyTargets),
            ev("s2", day(8), [p("11", "3")], targets: downyTargets),
        ]
        // "including mixture formulations".
        #expect(
            try rule(evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE")
                .status == .limitExceeded
        )
    }

    @Test("A third group 11 downy spray exceeds the two-per-season maximum")
    func downyGroup11SeasonMax() throws {
        let events = [
            ev("s1", day(1), [p("11")], targets: downyTargets),
            ev("s2", day(8), [p("21")], targets: downyTargets),
            ev("s3", day(15), [p("11", "3")], targets: downyTargets),
            ev("s4", day(22), [p("21")], targets: downyTargets),
            ev("s5", day(29), [p("11")], targets: downyTargets),
        ]
        let result = try rule(
            evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC11_MAX_SEASON"
        )
        #expect(result.status == .limitExceeded)
        #expect(result.observedValue == 3.0)
    }

    @Test("Group 21 downy allows two consecutive and breaches at three")
    func downyGroup21Consecutive() throws {
        let events = (1...3).map { ev("s\($0)", day($0 * 7), [p("21")], targets: downyTargets) }
        #expect(
            try rule(evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC21_MAX_CONSECUTIVE")
                .status == .limitExceeded
        )
    }

    @Test("Group 40 exceeds fifty percent of downy sprays")
    func downyGroup40Fraction() throws {
        let events = [
            ev("s1", day(1), [p("40")], targets: downyTargets),
            ev("s2", day(8), [p("40")], targets: downyTargets),
            ev("s3", day(15), [p("11")], targets: downyTargets),
        ]
        let result = try rule(
            evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION"
        )
        // 2 of 3 sprays is above 50%.
        #expect(result.status == .limitExceeded)
        #expect(result.observedValue == 2.0)
        #expect(result.threshold == 1.0)
    }

    @Test("Group 40 exceeds its two solo application maximum")
    func downyGroup40Solo() throws {
        let events = [
            ev("s1", day(1), [p("40")], targets: downyTargets),
            ev("s2", day(8), [p("21")], targets: downyTargets),
            ev("s3", day(15), [p("40")], targets: downyTargets),
            ev("s4", day(22), [p("21")], targets: downyTargets),
            ev("s5", day(29), [p("40")], targets: downyTargets),
            ev("s6", day(36), [p("11")], targets: downyTargets),
        ]
        let evaluation = evaluate(events, disease: .downyMildew)
        let solo = try rule(evaluation, "AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON")
        #expect(solo.status == .limitExceeded)
        #expect(solo.observedValue == 3.0)
        #expect(solo.threshold == 2.0)
        // 3 of 6 is exactly 50%, so the percentage rule is reached, not exceeded.
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION").status == .limitReached)
    }

    @Test("A mixed group 40 spray is not a solo application")
    func mixedGroup40NotSolo() throws {
        let events = [
            ev("s1", day(1), [p("40"), p("11")], targets: downyTargets),
            ev("s2", day(8), [p("21")], targets: downyTargets),
            ev("s3", day(15), [p("40"), p("11")], targets: downyTargets),
            ev("s4", day(22), [p("21")], targets: downyTargets),
        ]
        let solo = try rule(
            evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON"
        )
        #expect(solo.observedValue == 0.0)
        #expect(solo.status == .notTriggered)
    }

    @Test("Group 40 as the currently final downy spray is reported as guidance")
    func downyGroup40LastSpray() throws {
        let events = [
            ev("s1", day(1), [p("11")], targets: downyTargets),
            ev("s2", day(8), [p("40")], targets: downyTargets),
        ]
        let result = try rule(
            evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY"
        )
        // Whether a spray is the LAST of a season is unknowable mid-season, so this is
        // advice, not a breach.
        #expect(result.status == .guidance)
        #expect(result.severity == .informational)
    }

    @Test("Group 45 plus 40 is capped at two per season as its own combination")
    func downyGroup4540Season() throws {
        let events = [
            ev("s1", day(1), [p("45", "40")], targets: downyTargets),
            ev("s2", day(8), [p("11")], targets: downyTargets),
            ev("s3", day(15), [p("45", "40")], targets: downyTargets),
            ev("s4", day(22), [p("11")], targets: downyTargets),
        ]
        let evaluation = evaluate(events, disease: .downyMildew)
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_SEASON").status == .limitReached)
        // And its Group 40 component still counts toward Group 40 rules.
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION").observedValue == 2.0)
    }

    @Test("Group 40 plus 49 has a thirty-three percent cap distinct from group 40's fifty percent")
    func downyGroup4049Fraction() throws {
        let events = [
            ev("s1", day(1), [p("40", "49")], targets: downyTargets, mixtureConfirmed: true),
            ev("s2", day(8), [p("11")], targets: downyTargets),
            ev("s3", day(15), [p("21")], targets: downyTargets),
            ev("s4", day(22), [p("40", "49")], targets: downyTargets, mixtureConfirmed: true),
        ]
        let evaluation = evaluate(events, disease: .downyMildew)
        let combination = try rule(evaluation, "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION")
        // 2 of 4 is 50%, above the combination's 33% ceiling.
        #expect(combination.status == .limitExceeded)
        #expect(combination.threshold == 1.0)
        // The Group 40 component ceiling is 50%, which 2 of 4 exactly reaches.
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION").status == .limitReached)
    }

    @Test("Group 40 plus 49 requires two intervening different-group applications")
    func downyGroup4049Intervening() throws {
        let events = [
            ev("s1", day(1), [p("40", "49")], targets: downyTargets, mixtureConfirmed: true),
            ev("s2", day(8), [p("11")], targets: downyTargets),
            ev("s3", day(15), [p("40", "49")], targets: downyTargets, mixtureConfirmed: true),
        ]
        let result = try rule(
            evaluate(events, disease: .downyMildew), "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING"
        )
        #expect(result.status == .limitExceeded)
        #expect(result.observedValue == 1.0)
        #expect(result.threshold == 2.0)
    }

    @Test("A combination product is recognised by signature and by component groups")
    func combinationBySignatureAndComponents() throws {
        let evaluation = evaluate(
            [ev("s1", day(1), [p("40", "49")], targets: downyTargets, mixtureConfirmed: true)],
            disease: .downyMildew
        )
        // Its own combination identity.
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_SEASON").observedValue == 1.0)
        // And both component groups.
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION").observedValue == 1.0)
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON").observedValue == 1.0)
    }

    @Test("Two adjacent group 49 sprays breach one-in-three even though two of six is thirty-three percent")
    func oneInThreeIsNotAPercentage() throws {
        let events = [
            ev("s1", day(1), [p("49"), p("21")], targets: downyTargets, mixtureConfirmed: true),
            ev("s2", day(8), [p("49"), p("21")], targets: downyTargets, mixtureConfirmed: true),
            ev("s3", day(15), [p("11")], targets: downyTargets),
            ev("s4", day(22), [p("21")], targets: downyTargets),
            ev("s5", day(29), [p("11")], targets: downyTargets),
            ev("s6", day(36), [p("21")], targets: downyTargets),
        ]
        let evaluation = evaluate(events, disease: .downyMildew)
        // Spacing rule: two Group 49 inside one window of three.
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE").status == .limitExceeded)
        // Seasonal count of 2 is exactly the maximum, NOT exceeded. This is why
        // one-in-three and a 33% cap cannot be treated as the same rule.
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON").status == .limitReached)
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC49_NO_CONSECUTIVE").status == .limitExceeded)
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING").status == .limitExceeded)
    }

    @Test("Two properly spaced group 49 sprays satisfy one-in-three and reach the season maximum")
    func spacedGroup49Satisfies() throws {
        let events = [
            ev("s1", day(1), [p("49"), p("21")], targets: downyTargets, mixtureConfirmed: true),
            ev("s2", day(8), [p("11")], targets: downyTargets),
            ev("s3", day(15), [p("21")], targets: downyTargets),
            ev("s4", day(22), [p("49"), p("11")], targets: downyTargets, mixtureConfirmed: true),
            ev("s5", day(29), [p("21")], targets: downyTargets),
            ev("s6", day(36), [p("11")], targets: downyTargets),
        ]
        let evaluation = evaluate(events, disease: .downyMildew)
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE").status == .withinLimit)
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING").status == .withinLimit)
        #expect(try rule(evaluation, "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON").status == .limitReached)
    }

    @Test("Solo group 49 fails its mixture requirement")
    func soloGroup49Fails() throws {
        let result = try rule(
            evaluate([ev("s1", day(1), [p("49")], targets: downyTargets)], disease: .downyMildew),
            "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED"
        )
        #expect(result.status == .requirementNotMet)
        #expect(result.mixtureRequirement == .notSatisfied)
    }

    @Test("Group 49 reuse after only one intervening spray breaches the intervening rule")
    func group49ReuseTooSoon() throws {
        let events = [
            ev("s1", day(1), [p("49"), p("21")], targets: downyTargets, mixtureConfirmed: true),
            ev("s2", day(8), [p("11")], targets: downyTargets),
        ]
        let candidate = ev(
            "cand", day(15), [p("49"), p("21")], targets: downyTargets, mixtureConfirmed: true
        )
        let result = try rule(
            evaluate(events, candidate: candidate, disease: .downyMildew),
            "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING"
        )
        #expect(result.status == .wouldExceedLimit)
        #expect(result.observedValue == 1.0)
        #expect(result.explanation.contains("different group"))
    }

    // MARK: - Chemical Intelligence availability

    @Test("Verified chemistry with no breach returns a clean result")
    func verifiedCleanResult() {
        let events = [ev("s1", day(1), [p("13")]), ev("s2", day(8), [p("19")])]
        let result = evaluate(events)
        #expect(result.status == .compliant)
        #expect(result.evidenceQuality == .high)
        #expect(result.isCleanResult)
        #expect(result.summary.contains("No Powdery Mildew resistance strategy limit is reached"))
    }

    @Test("Partially verified chemistry qualifies the result and blocks a clean pass")
    func partiallyVerifiedQualified() {
        let events = [
            ev("s1", day(1), [p("13", availability: .availablePartiallyVerified)]),
            ev("s2", day(8), [p("19")]),
        ]
        let result = evaluate(events)
        #expect(result.status == .compliant)
        #expect(result.evidenceQuality == .qualified)
        #expect(result.isCleanResult == false)
    }

    @Test("Unverified chemistry with no breach is qualified never reported as all good")
    func unverifiedQualifiedWording() {
        let events = [
            ev("s1", day(1), [p("13", availability: .availableUnverified)]),
            ev("s2", day(8), [p("19")]),
        ]
        let result = evaluate(events)
        #expect(result.status == .compliant)
        #expect(result.evidenceQuality == .qualified)
        #expect(result.isCleanResult == false)
        #expect(
            result.summary
                == "No strategy limit detected using the recorded groups; one or more chemical records are unverified."
        )
    }

    @Test("An unverified sequence that appears to exceed a maximum still warns")
    func unverifiedBreachStillWarns() throws {
        let events = [
            ev("s1", day(1), [p("11", availability: .availableUnverified)]),
            ev("s2", day(8), [p("11", availability: .availableUnverified)]),
        ]
        let evaluation = evaluate(events)
        let table = try rule(evaluation, "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        #expect(table.status == .limitExceeded)
        #expect(evaluation.status == .strategyExceeded)
        #expect(table.evidenceQuality == .qualified)
        // The warning must be qualified by the quality of its evidence.
        #expect(table.explanation.contains("not been independently verified"))
    }

    @Test("Conflicting chemistry cannot be treated as reliable")
    func conflictNotReliable() {
        let events = [
            ev("s1", day(1), [p("13", availability: .conflict)]),
            ev("s2", day(8), [p("19")]),
        ]
        let result = evaluate(events)
        #expect(result.status == .unableToFullyAssess)
        #expect(result.evidenceQuality == .indeterminate)
        #expect(result.isCleanResult == false)
        #expect(result.unassessableApplicationIds.contains("s1"))
    }

    @Test("Unavailable chemistry can never produce a clean pass")
    func unavailableNeverClean() {
        let events = [ev("s1", day(1), [noChemistry()]), ev("s2", day(8), [p("19")])]
        let result = evaluate(events)
        #expect(result.status == .unableToFullyAssess)
        #expect(result.isCleanResult == false)
        #expect(result.status != .compliant)
        #expect(result.unassessableApplicationIds.contains("s1"))
    }

    @Test("A historical spray with no chemical snapshot stays in the chronology")
    func nilSnapshotStaysInChronology() throws {
        // The pre-Chemical-Intelligence record. It must not vanish, and it must not be
        // read as a no-group application.
        let events = [
            ev("legacy", day(1), [noChemistry()]),
            ev("s2", day(8), [p("3")]),
            ev("s3", day(15), [p("3")]),
        ]
        let evaluation = evaluate(events)
        #expect(evaluation.totalDiseaseSpraysInSeason == 3)
        #expect(evaluation.consideredApplicationIds.contains("legacy"))

        let consecutive = try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        // The legacy spray might have been Group 3, which would make this three in a row.
        // The engine refuses to say.
        #expect(consecutive.status == .unableToAssess)
        #expect(consecutive.evidenceQuality == .indeterminate)
        #expect(consecutive.contributingApplicationIds.contains("legacy"))
        #expect(consecutive.explanation.contains("cannot be assessed"))
    }

    @Test("Missing chemistry suppresses a clean result but not a proven breach")
    func missingChemistryKeepsBreach() throws {
        let events = [
            ev("legacy", day(1), [noChemistry()]),
            ev("s2", day(8), [p("3")]),
            ev("s3", day(15), [p("3")]),
            ev("s4", day(22), [p("3")]),
        ]
        let evaluation = evaluate(events)
        // Three known Group 3 sprays in a row is a breach regardless of the unknown one.
        #expect(try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status == .limitExceeded)
        #expect(evaluation.status == .strategyExceeded)
        #expect(evaluation.summary.contains("may be worse"))
    }

    @Test("An application whose chemistry is unavailable is never a no-group application")
    func unavailableIsNotNoGroups() {
        let event = ev("legacy", day(1), [noChemistry()])
        #expect(event.availability == .unavailable)
        #expect(event.canAssessChemistry == false)
        #expect(event.componentGroups.isEmpty)
        // Empty groups plus unavailable is the honest encoding: nothing is known, as
        // opposed to "known to contain nothing".
        #expect(event.availability.permitsCleanResult == false)
    }

    @Test("The weakest product line governs a tank's availability")
    func weakestLineGoverns() {
        let event = ev("s1", day(1), [p("3"), p("11", availability: .conflict)])
        #expect(event.availability == .conflict)
    }

    // MARK: - Unrecorded targets

    @Test("Applications with no recorded target suppress a clean result")
    func unrecordedTargetsSuppressClean() {
        let events = [
            ev("s1", day(1), [p("13")]),
            ev("legacy", day(8), [p("3")], targets: [], targetsRecorded: false),
        ]
        let result = evaluate(events)
        // The unattributed spray cannot be counted against powdery mildew, and it must
        // not be silently dropped either.
        #expect(result.status == .unableToFullyAssess)
        #expect(result.unattributedApplicationIds == ["legacy"])
        #expect(result.isCleanResult == false)
        #expect(result.summary.contains("no recorded target disease"))
    }

    @Test("Recorded-as-no-target differs from never-recorded")
    func recordedNoneVsNeverRecorded() {
        let recordedNone = evaluate([
            ev("s1", day(1), [p("13")]),
            ev("none", day(8), [p("3")], targets: [], targetsRecorded: true),
        ])
        let neverRecorded = evaluate([
            ev("s1", day(1), [p("13")]),
            ev("unknown", day(8), [p("3")], targets: [], targetsRecorded: false),
        ])
        #expect(recordedNone.unattributedApplicationIds.isEmpty)
        #expect(recordedNone.status == .compliant)
        #expect(neverRecorded.unattributedApplicationIds == ["unknown"])
        #expect(neverRecorded.status == .unableToFullyAssess)
    }

    // MARK: - Candidate evaluation

    @Test("History can be evaluated with no candidate at all")
    func historyOnlyEvaluation() {
        let result = evaluate([ev("s1", day(1), [p("13")])])
        #expect(result.candidateApplicationId == nil)
        #expect(result.hasCandidate == false)
        #expect(result.status == .compliant)
    }

    @Test("A candidate needs no saved spray record")
    func unsavedCandidate() throws {
        // A Guided Spray plan that has never been persisted.
        let candidate = ResistanceApplicationEvent(
            applicationId: "temp-candidate-1",
            kind: .candidate,
            appliedAtEpochMs: day(10),
            seasonId: season.id,
            vineyardId: "vineyard-1",
            blockId: blockA,
            targets: powderyTargets,
            targetsRecorded: true,
            products: [p("3")]
        )
        let events = [ev("s1", day(1), [p("3")]), ev("s2", day(8), [p("3")])]
        let evaluation = evaluate(events, candidate: candidate)
        #expect(evaluation.candidateApplicationId == "temp-candidate-1")
        #expect(
            try rule(evaluation, "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status == .wouldExceedLimit
        )
    }

    @Test("Reaching a limit and exceeding it are distinct candidate outcomes")
    func reachVersusExceed() throws {
        let oneSpray = [ev("s1", day(1), [p("3")])]
        let reach = try rule(
            evaluate(oneSpray, candidate: ev("cand", day(8), [p("3")])),
            "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE"
        )
        #expect(reach.status == .wouldReachLimit)
        #expect(reach.severity == .warning)
        #expect(reach.explanation.contains("would reach the strategy maximum"))

        let twoSprays = oneSpray + [ev("s2", day(8), [p("3")])]
        let exceed = try rule(
            evaluate(twoSprays, candidate: ev("cand", day(15), [p("3")])),
            "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE"
        )
        #expect(exceed.status == .wouldExceedLimit)
        #expect(exceed.severity == .critical)
    }

    @Test("A candidate for a different disease does not affect this disease")
    func candidateDifferentDisease() {
        let events = [ev("s1", day(1), [p("3")])]
        let result = evaluate(events, candidate: ev("cand", day(8), [p("3")], targets: downyTargets))
        #expect(result.candidateApplicationId == nil)
        #expect(result.totalDiseaseSpraysInSeason == 1)
    }

    @Test("A candidate for a different block does not affect this block")
    func candidateDifferentBlock() {
        let events = [ev("s1", day(1), [p("3")], block: blockA)]
        let result = evaluate(
            events, candidate: ev("cand", day(8), [p("3")], block: blockB), block: blockA
        )
        // The candidate is scoped to block B, so block A's total is unchanged.
        #expect(result.totalDiseaseSpraysInSeason == 1)
    }

    // MARK: - Planned events

    @Test("Planned events are excluded from counting but reported")
    func plannedExcludedButReported() {
        let events = [
            ev("s1", day(1), [p("3")]),
            ev("planned", day(8), [p("3")], kind: .planned),
        ]
        let result = evaluate(events)
        #expect(result.totalDiseaseSpraysInSeason == 1)
        #expect(result.excludedPlannedApplicationIds == ["planned"])
    }

    @Test("Planned events can be opted into without an engine change")
    func plannedOptIn() {
        let events = [
            ev("s1", day(1), [p("3")]),
            ev("planned", day(8), [p("3")], kind: .planned),
        ]
        let result = evaluate(events, includePlanned: true)
        #expect(result.totalDiseaseSpraysInSeason == 2)
        #expect(result.excludedPlannedApplicationIds.isEmpty)
    }

    // MARK: - Explainability

    @Test("Every finding traces to a specific published rule")
    func findingsAreTraceable() {
        let events = [
            ev("s1", day(1), [p("3")]), ev("s2", day(8), [p("3")]), ev("s3", day(15), [p("3")]),
        ]
        let result = evaluate(events)
        #expect(!result.findings.isEmpty)
        for finding in result.findings {
            #expect(!finding.ruleId.isEmpty, "rule id missing")
            #expect(!finding.rulesetId.isEmpty, "ruleset id missing")
            #expect(!finding.sourceReference.isEmpty, "source reference missing")
            #expect(finding.sourceText.count > 20, "published text missing")
            #expect(finding.explanation.count > 20, "explanation missing")
            #expect(!finding.groups.isEmpty, "groups missing")
            #expect(!finding.thresholdDescription.isEmpty, "threshold description missing")
        }
    }

    @Test("A breach names the contributing applications and their dates")
    func breachNamesContributors() throws {
        let events = [
            ev("s1", day(1), [p("3")]), ev("s2", day(8), [p("3")]), ev("s3", day(15), [p("3")]),
        ]
        let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        #expect(result.contributingApplicationIds == ["s1", "s2", "s3"])
        #expect(result.contributingDatesEpochMs == [day(1), day(8), day(15)])
    }

    @Test("Engine wording never claims illegality")
    func wordingNeverClaimsIllegality() {
        let events = [
            ev("s1", day(1), [p("3")]), ev("s2", day(8), [p("3")]), ev("s3", day(15), [p("3")]),
        ]
        let result = evaluate(events)
        let text = (result.summary + result.ruleResults.map {
            $0.explanation + $0.thresholdDescription + $0.observedDescription
        }.joined(separator: " ")).lowercased()
        for forbidden in ["illegal", "unlawful", "unsafe", "prohibited by law", "non-compliant with law"] {
            #expect(!text.contains(forbidden), "engine must not say '\(forbidden)'")
        }
        #expect(result.summary.hasPrefix("Resistance strategy warning"))
    }

    @Test("Severity is separate from rule status and carries no presentation detail")
    func severitySeparateFromStatus() throws {
        let events = [ev("s1", day(1), [p("3")]), ev("s2", day(8), [p("3")])]
        let result = try rule(evaluate(events), "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        #expect(result.status == .limitReached)
        #expect(result.severity == .warning)
        // Severity is an enum of meanings, not colours.
        for severity in ResistanceSeverity.allCases {
            #expect(!severity.rawValue.contains("#"))
        }
    }

    // MARK: - Season handling

    @Test("Season identity spans the new year rather than resetting at 31 December")
    func seasonSpansNewYear() {
        #expect(calendar.season(epochMs: day(5)).id == calendar.season(epochMs: day(230)).id)
        #expect(calendar.season(epochMs: day(5)).id == "2026/27")
    }

    @Test("A spray before the season start belongs to the previous season")
    func sprayBeforeSeasonStart() {
        #expect(calendar.season(epochMs: season.startEpochMs - 86_400_000).id == "2025/26")
        #expect(calendar.season(epochMs: season.startEpochMs).id == "2026/27")
    }

    @Test("A custom vineyard season start is honoured")
    func customSeasonStart() {
        let aprilCalendar = ResistanceSeasonCalendar(startMonth: 4, startDay: 1)
        let beforeStart = aprilCalendar.seasonStarting(2026).startEpochMs - 86_400_000
        #expect(aprilCalendar.season(epochMs: beforeStart).id == "2025/26")
        #expect(aprilCalendar.seasonStarting(2026).id == "2026/27")
    }

    @Test("No applications targeting the disease returns not applicable")
    func noApplicationsNotApplicable() {
        let result = evaluate([])
        #expect(result.status == .notApplicable)
        #expect(result.ruleResults.isEmpty)
        #expect(result.isCleanResult == false)
    }
}
