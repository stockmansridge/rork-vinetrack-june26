import Foundation
import Testing

@testable import VineTrack

/// Canonical fingerprints of the CropLife Australia 2026 rulesets.
///
/// Duplicated verbatim in Android `ResistanceRulesetTest.kt`. Regenerate BOTH only
/// when a genuine strategy revision is encoded, never to make a red test go green.
nonisolated enum ResistanceParityFixture {
    nonisolated static let powdery2026Fingerprint = "14148a7c4d4682a1"
    nonisolated static let downy2026Fingerprint = "3bcc71d77397e116"
}

/// Fidelity of the encoded CropLife Australia 2026 strategies to their published
/// source, plus the cross-platform parity assertions.
///
/// Mirrors Android `ResistanceRulesetTest.kt`. Every expectation in this file exists
/// verbatim there; the two suites are the drift detector.
@Suite("Resistance ruleset fidelity and parity")
struct ResistanceRulesetTests {

    // MARK: - Versioned source metadata

    @Test("Powdery ruleset carries the published CropLife source metadata")
    func powderyMetadata() {
        let ruleset = ResistanceRulesets.powdery2026
        #expect(ruleset.id == "AU_GRAPE_POWDERY_2026_07_22")
        #expect(ruleset.jurisdiction == .australia)
        #expect(ruleset.crop == .grape)
        #expect(ruleset.disease == .powderyMildew)
        #expect(ruleset.strategyName == "Grape - Powdery mildew")
        #expect(ruleset.sourceOrganisation == "CropLife Australia")
        #expect(ruleset.validFrom == "2026-07-22")
        #expect(ruleset.rulesetVersion == "2026.07.22")
        #expect(ruleset.sourceReference.contains("croplife.org.au"))
    }

    @Test("Downy ruleset carries the published CropLife source metadata")
    func downyMetadata() {
        let ruleset = ResistanceRulesets.downy2026
        #expect(ruleset.id == "AU_GRAPE_DOWNY_2026_07_22")
        #expect(ruleset.jurisdiction == .australia)
        #expect(ruleset.disease == .downyMildew)
        #expect(ruleset.strategyName == "Grape - Downy mildew")
        #expect(ruleset.validFrom == "2026-07-22")
        #expect(ruleset.rulesetVersion == "2026.07.22")
    }

    @Test("Both 2026 rulesets are valid as at 22 July 2026")
    func validFromDate() {
        #expect(ResistanceRulesets.cropLife2026ValidFrom == "2026-07-22")
        #expect(ResistanceRulesets.powdery2026.validFrom == ResistanceRulesets.cropLife2026ValidFrom)
        #expect(ResistanceRulesets.downy2026.validFrom == ResistanceRulesets.cropLife2026ValidFrom)
    }

    @Test("Neither 2026 ruleset is marked superseded")
    func notSuperseded() {
        #expect(ResistanceRulesets.powdery2026.isSuperseded == false)
        #expect(ResistanceRulesets.downy2026.isSuperseded == false)
    }

    // MARK: - Jurisdiction selection

    @Test("Registry selects the Australian grape rulesets")
    func australianSelection() {
        let registry = ResistanceRulesets.registry
        #expect(
            registry.current(jurisdiction: .australia, crop: .grape, disease: .powderyMildew)?.id
                == "AU_GRAPE_POWDERY_2026_07_22"
        )
        #expect(
            registry.current(jurisdiction: .australia, crop: .grape, disease: .downyMildew)?.id
                == "AU_GRAPE_DOWNY_2026_07_22"
        )
    }

    @Test("Registry has no ruleset for New Zealand")
    func noNewZealandRuleset() {
        let registry = ResistanceRulesets.registry
        #expect(registry.current(jurisdiction: .newZealand, crop: .grape, disease: .powderyMildew) == nil)
        #expect(registry.current(jurisdiction: .newZealand, crop: .grape, disease: .downyMildew) == nil)
    }

    @Test("Registry has no ruleset for an unknown jurisdiction")
    func noUnknownRuleset() {
        #expect(
            ResistanceRulesets.registry
                .current(jurisdiction: .unknown, crop: .grape, disease: .powderyMildew) == nil
        )
    }

    @Test("Vineyard country maps onto jurisdiction and never defaults to Australia")
    func countryMapping() {
        #expect(ResistanceJurisdiction.fromCountryCode("AU") == .australia)
        #expect(ResistanceJurisdiction.fromCountryCode("australia") == .australia)
        #expect(ResistanceJurisdiction.fromCountryCode("NZ") == .newZealand)
        #expect(ResistanceJurisdiction.fromCountryCode("New Zealand") == .newZealand)
        #expect(ResistanceJurisdiction.fromCountryCode(nil) == .unknown)
        #expect(ResistanceJurisdiction.fromCountryCode("") == .unknown)
        #expect(ResistanceJurisdiction.fromCountryCode("US") == .unknown)
        #expect(ResistanceJurisdiction.fromCountryCode("FR") == .unknown)
    }

    // MARK: - Superseding architecture

    @Test("A future ruleset supersedes without deleting the 2026 definition")
    func supersedingRetainsHistory() throws {
        var future = ResistanceRulesets.powdery2026
        future.id = "AU_GRAPE_POWDERY_2027_07_20"
        future.validFrom = "2027-07-20"
        future.validFromEpochMs = ResistanceRulesets.cropLife2026ValidFromEpochMs + 365 * 86_400_000
        future.rulesetVersion = "2027.07.20"
        future.supersedes = ResistanceRulesets.powderyId

        var retired = ResistanceRulesets.powdery2026
        retired.supersededBy = future.id

        let registry = ResistanceRulesetRegistry([retired, future, ResistanceRulesets.downy2026])
        #expect(
            registry.current(jurisdiction: .australia, crop: .grape, disease: .powderyMildew)?.id
                == future.id
        )
        let retained = try #require(registry.byId(ResistanceRulesets.powderyId))
        #expect(retained.isSuperseded)
    }

    @Test("Historical reconstruction selects the ruleset in force at the time")
    func historicalReconstruction() {
        var future = ResistanceRulesets.powdery2026
        future.id = "AU_GRAPE_POWDERY_2027_07_20"
        future.validFrom = "2027-07-20"
        future.validFromEpochMs = ResistanceRulesets.cropLife2026ValidFromEpochMs + 365 * 86_400_000
        future.supersedes = ResistanceRulesets.powderyId

        var retired = ResistanceRulesets.powdery2026
        retired.supersededBy = future.id

        let registry = ResistanceRulesetRegistry([retired, future])
        let during2026 = ResistanceRulesets.cropLife2026ValidFromEpochMs + 30 * 86_400_000
        #expect(
            registry.inForce(
                jurisdiction: .australia, crop: .grape, disease: .powderyMildew, atEpochMs: during2026
            )?.id == ResistanceRulesets.powderyId
        )
    }

    // MARK: - Rule ID stability

    @Test("Every rule id is unique within its ruleset")
    func uniqueRuleIds() {
        for ruleset in [ResistanceRulesets.powdery2026, ResistanceRulesets.downy2026] {
            let ids = ruleset.rules.map(\.id)
            #expect(ids.count == Set(ids).count, "duplicate rule id in \(ruleset.id)")
        }
    }

    @Test("Every rule id is globally unique and systematically named")
    func systematicRuleIds() {
        let all = ResistanceRulesets.registry.rulesets.flatMap { $0.rules }.map(\.id)
        #expect(all.count == Set(all).count)
        for id in all {
            #expect(id.hasPrefix("AU_GRAPE_"), "\(id) must be namespaced by jurisdiction and crop")
            #expect(id == id.uppercased(), "\(id) must be upper snake case")
        }
    }

    @Test("Every rule cites a published clause and its verbatim text")
    func rulesCiteSource() {
        for rule in ResistanceRulesets.registry.rulesets.flatMap({ $0.rules }) {
            #expect(!rule.sourceReference.isEmpty, "\(rule.id) has no source reference")
            #expect(rule.sourceText.count > 20, "\(rule.id) has no source text")
        }
    }

    // MARK: - Powdery rule inventory

    @Test("Powdery rule inventory matches the published strategy exactly")
    func powderyInventory() {
        let expected = [
            "AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE",
            "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC11_MIXTURE_WHEN_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC13_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC13_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC19_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC19_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC21_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION",
            "AU_GRAPE_POWDERY_FRAC21_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP",
            "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC3_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC50_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC50_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC5_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC5_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC5_PLUS_3_AND_7_PLUS_12_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON",
            "AU_GRAPE_POWDERY_FRAC7_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRACU6_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRACU6_MAX_FROM_TOTAL_TABLE",
        ]
        #expect(ResistanceRulesets.powdery2026.rules.map(\.id).sorted() == expected)
    }

    @Test("Powdery groups 3 5 13 19 21 50 and U6 each carry a two-consecutive rule")
    func powderyConsecutiveRules() throws {
        for fragment in ["FRAC3", "FRAC5", "FRAC13", "FRAC19", "FRAC21", "FRAC50", "FRACU6"] {
            let rule = try #require(
                ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_\(fragment)_MAX_CONSECUTIVE"),
                "missing consecutive rule for \(fragment)"
            )
            #expect(rule.kind == .maxConsecutiveApplications(2))
            #expect(rule.sourceReference == "Guideline 4")
            // Guideline 2: consecutive applications include from the end of one season
            // to the start of the next.
            #expect(rule.crossSeason, "\(fragment) consecutive rule must cross the season boundary")
        }
    }

    @Test("Powdery group 5 plus 3 is limited to one application")
    func powderyFivePlusThree() throws {
        let rule = try #require(
            ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON")
        )
        #expect(rule.kind == .maxApplicationsPerSeason(1))
        #expect(rule.sourceReference == "Guideline 3")
        #expect(rule.selector == .coformulation(.of("3", "5")))
    }

    @Test("Powdery groups 7 and 11 require mixtures only when used consecutively")
    func powderyMixtureWhenConsecutive() throws {
        for (fragment, code) in [("FRAC7", "7"), ("FRAC11", "11")] {
            let rule = try #require(
                ResistanceRulesets.powdery2026
                    .rule("AU_GRAPE_POWDERY_\(fragment)_MIXTURE_WHEN_CONSECUTIVE")
            )
            #expect(rule.kind == .mixtureRequiredWhenConsecutive)
            #expect(rule.selector == .containsGroup(code))
            #expect(rule.sourceReference == "Guideline 2")
        }
    }

    @Test("Powdery group 21 carries both a crop maximum and a percentage restriction")
    func powderyGroup21() throws {
        let crop = try #require(ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP"))
        #expect(crop.kind == .maxApplicationsPerCrop(3))
        let fraction = try #require(
            ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")
        )
        #expect(fraction.kind == .maxFractionOfDiseaseSprays(numerator: 1, denominator: 3))
        #expect(crop.sourceReference == "Guideline 5")
        #expect(fraction.sourceReference == "Guideline 5")
    }

    @Test("Powdery preventative-use guidance is encoded")
    func powderyPreventative() throws {
        let rule = try #require(
            ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE")
        )
        #expect(rule.kind == .preventativeApplicationGuidance)
        #expect(rule.sourceText == "Apply all these fungicides preventatively.")
    }

    @Test("Powdery lists all thirteen published groups and combinations")
    func powderyGroupListing() {
        #expect(
            ResistanceRulesets.powdery2026.groups.map(\.displayName).sorted() == [
                "Group 11", "Group 11 + 3", "Group 13", "Group 19", "Group 21", "Group 3",
                "Group 5", "Group 5 + 3", "Group 50 (U8)", "Group 7", "Group 7 + 12",
                "Group 7 + 3", "Group U6",
            ]
        )
    }

    // MARK: - Powdery maximum-use table, cell for cell

    @Test("Powdery maximum-use table reproduces every published cell")
    func powderyTableCells() {
        let table = ResistanceRulesets.powderyMaxUseTable
        // Published column order:
        // 3 | 5 | 5+3, 7+12 | 7 (inc. 7+3) | 11 (inc. 11+3) | 13 | 19 | 21 | 50 (U8) | U6
        let columns = ["3", "5", "5+3,7+12", "7", "11", "13", "19", "21", "50", "U6"]
        #expect(table.columns.map(\.key) == columns)

        let expected: [Int: [Int]] = [
            1: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
            2: [2, 1, 1, 1, 1, 2, 2, 1, 1, 1],
            3: [2, 2, 1, 1, 2, 2, 2, 1, 1, 1],
            4: [2, 2, 1, 1, 2, 2, 2, 1, 2, 2],
            5: [2, 2, 1, 1, 2, 2, 2, 1, 2, 2],
            6: [3, 3, 1, 2, 2, 3, 3, 2, 2, 2],
            7: [3, 3, 1, 2, 2, 3, 3, 2, 2, 2],
            8: [3, 3, 1, 2, 2, 3, 3, 2, 2, 2],
            9: [3, 3, 1, 2, 2, 3, 3, 3, 2, 2],
        ]
        #expect(table.rows.count == 9)
        for (total, maxima) in expected {
            for (index, key) in columns.enumerated() {
                #expect(
                    table.maxFor(key, totalSprays: total) == maxima[index],
                    "total=\(total) column=\(key)"
                )
            }
        }
    }

    @Test("Powdery table final row is open-ended and governs above nine sprays")
    func powderyTableOpenEnded() throws {
        let table = ResistanceRulesets.powderyMaxUseTable
        let last = try #require(table.rows.last)
        #expect(last.isOrMore)
        #expect(last.totalSprays == 9)
        // 9+ means 9 or more: 12 and 20 sprays use the same published ceilings.
        for total in [9, 10, 12, 20, 40] {
            #expect(table.maxFor("3", totalSprays: total) == 3)
            #expect(table.maxFor("11", totalSprays: total) == 2)
            #expect(table.maxFor("21", totalSprays: total) == 3)
            #expect(table.maxFor("5+3,7+12", totalSprays: total) == 1)
        }
    }

    @Test("Powdery table is silent when no sprays target the disease")
    func powderyTableZero() {
        #expect(ResistanceRulesets.powderyMaxUseTable.maxFor("3", totalSprays: 0) == nil)
        #expect(ResistanceRulesets.powderyMaxUseTable.maxFor("3", totalSprays: -1) == nil)
    }

    @Test("Powdery table group 5 plus 3 column never exceeds one application")
    func powderyTableFivePlusThreeColumn() {
        // Reinforces Guideline 3 from the table side.
        for total in 1...15 {
            #expect(ResistanceRulesets.powderyMaxUseTable.maxFor("5+3,7+12", totalSprays: total) == 1)
        }
    }

    @Test("Powdery table has a rule for every published column")
    func powderyTableRuleCoverage() {
        let columnKeys = Set(ResistanceRulesets.powderyMaxUseTable.columns.map(\.key))
        var ruleColumnKeys: Set<String> = []
        for rule in ResistanceRulesets.powdery2026.rules {
            if case .maxFromTotalSprayCountTable(let key) = rule.kind { ruleColumnKeys.insert(key) }
        }
        #expect(columnKeys == ruleColumnKeys)
    }

    // MARK: - Downy rule inventory

    @Test("Downy rule inventory matches the published strategy exactly")
    func downyInventory() {
        let expected = [
            "AU_GRAPE_DOWNY_FRAC11_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC21_MAX_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC21_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC40_MAX_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION",
            "AU_GRAPE_DOWNY_FRAC40_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON",
            "AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY",
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION",
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING",
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_NO_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE",
            "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING",
            "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED",
            "AU_GRAPE_DOWNY_FRAC49_NO_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC4_MAX_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC4_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC4_MIXTURE_REQUIRED",
            "AU_GRAPE_DOWNY_PROGRAM_PREVENTATIVE_START",
        ]
        #expect(ResistanceRulesets.downy2026.rules.map(\.id).sorted() == expected)
    }

    @Test("Downy group 4 must always be mixed and is capped at two consecutive and four per season")
    func downyGroup4() throws {
        let ruleset = ResistanceRulesets.downy2026
        #expect(try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC4_MIXTURE_REQUIRED")).kind == .mixtureRequired)
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC4_MAX_CONSECUTIVE")).kind
                == .maxConsecutiveApplications(2)
        )
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC4_MAX_SEASON")).kind
                == .maxApplicationsPerSeason(4)
        )
    }

    @Test("Downy group 11 must not be consecutive and is capped at two per season")
    func downyGroup11() throws {
        let ruleset = ResistanceRulesets.downy2026
        let consecutive = try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE"))
        #expect(consecutive.kind == .noConsecutiveApplications)
        #expect(consecutive.sourceReference == "Guideline 6")
        // "including mixture formulations" -> a component-group selector, so 11+3 counts.
        #expect(consecutive.selector == .containsGroup("11"))
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC11_MAX_SEASON")).kind
                == .maxApplicationsPerSeason(2)
        )
    }

    @Test("Downy group 21 is capped at three per season and two consecutive")
    func downyGroup21() throws {
        let ruleset = ResistanceRulesets.downy2026
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC21_MAX_SEASON")).kind
                == .maxApplicationsPerSeason(3)
        )
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC21_MAX_CONSECUTIVE")).kind
                == .maxConsecutiveApplications(2)
        )
    }

    @Test("Downy group 40 carries consecutive, fifty percent, solo, season and last-spray rules")
    func downyGroup40() throws {
        let ruleset = ResistanceRulesets.downy2026
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_MAX_CONSECUTIVE")).kind
                == .maxConsecutiveApplications(2)
        )
        // Table footnote * refers to point 8: Group 40 at 50%.
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION")).kind
                == .maxFractionOfDiseaseSprays(numerator: 1, denominator: 2)
        )
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON")).kind
                == .maxSoloApplicationsPerSeason(2)
        )
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_MAX_SEASON")).kind
                == .maxApplicationsPerSeason(4)
        )
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY")).kind == .notLastSprayOfSeason
        )
    }

    @Test("Downy group 40 plus 49 is a distinct combination with a thirty-three percent cap")
    func downyGroup4049() throws {
        let ruleset = ResistanceRulesets.downy2026
        let signature = ResistanceGroupSignature.of("40", "49")
        let fraction = try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION"))
        // Table footnote ** refers to point 3: Group 40+49 at 33%, NOT 50%.
        #expect(fraction.kind == .maxFractionOfDiseaseSprays(numerator: 1, denominator: 3))
        #expect(fraction.selector == .coformulation(signature))
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_SEASON")).kind
                == .maxApplicationsPerSeason(2)
        )
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING")).kind
                == .minInterveningDifferentGroupApplications(2)
        )
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_NO_CONSECUTIVE")).kind
                == .noConsecutiveApplications
        )
    }

    @Test("Downy group 45 plus 40 is a distinct combination capped at two per season")
    func downyGroup4540() throws {
        let ruleset = ResistanceRulesets.downy2026
        let season = try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_SEASON"))
        #expect(season.kind == .maxApplicationsPerSeason(2))
        #expect(season.selector == .coformulation(.of("45", "40")))
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_CONSECUTIVE")).kind
                == .maxConsecutiveApplications(2)
        )
    }

    @Test("Downy group 49 carries mixture, season, one-in-three and intervening rules")
    func downyGroup49() throws {
        let ruleset = ResistanceRulesets.downy2026
        #expect(try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED")).kind == .mixtureRequired)
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC49_MAX_SEASON")).kind
                == .maxApplicationsPerSeason(2)
        )
        // One-in-three is a SPACING rule, deliberately not a 33% fraction.
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE")).kind
                == .maxOneInEveryNSprays(3)
        )
        #expect(
            try #require(ruleset.rule("AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING")).kind
                == .minInterveningDifferentGroupApplications(2)
        )
    }

    @Test("Downy lists all eight published groups and combinations")
    func downyGroupListing() {
        #expect(
            ResistanceRulesets.downy2026.groups.map(\.displayName).sorted() == [
                "Group 11", "Group 11 + 3", "Group 21", "Group 4", "Group 40",
                "Group 40 + 49", "Group 45 + 40", "Group 49",
            ]
        )
    }

    @Test("Downy has no total-spray-count table because the published strategy has none")
    func downyNoTable() {
        #expect(ResistanceRulesets.downy2026.maxUseTable == nil)
        #expect(ResistanceRulesets.powdery2026.maxUseTable != nil)
    }

    @Test("Source ambiguities are recorded rather than silently resolved")
    func sourceAmbiguities() {
        let notes = ResistanceRulesets.downy2026.sourceNotes.joined(separator: " ")
        #expect(notes.contains("SOURCE AMBIGUITY"))
        // The 33% vs 50% Group 40 conflict between Guideline 3 and Guideline 8.
        #expect(notes.contains("33%") && notes.contains("50%"))
        // The Group 45+40 "solo: None" cell with no supporting guideline.
        #expect(notes.contains("45+40"))
    }

    // MARK: - Group code canonicalisation

    @Test("Group codes normalise across the spellings that reach the engine")
    func groupCodeNormalisation() {
        #expect(ResistanceGroupCode.normalize("11") == "11")
        #expect(ResistanceGroupCode.normalize(" 11 ") == "11")
        #expect(ResistanceGroupCode.normalize("Group 11") == "11")
        #expect(ResistanceGroupCode.normalize("FRAC 11") == "11")
        #expect(ResistanceGroupCode.normalize("frac11") == "11")
        #expect(ResistanceGroupCode.normalize("u6") == "U6")
        #expect(ResistanceGroupCode.normalize(nil) == nil)
        #expect(ResistanceGroupCode.normalize("") == nil)
        #expect(ResistanceGroupCode.normalize("   ") == nil)
    }

    @Test("Legacy code U8 normalises to Group 50 so both spellings meet")
    func legacyU8Alias() {
        // CropLife prints "Group 50 (U8)". A product label may print either. If they did
        // not collapse onto one key, a rotation could look compliant purely because the
        // two spellings never met.
        #expect(ResistanceGroupCode.normalize("U8") == "50")
        #expect(ResistanceGroupCode.normalize("Group U8") == "50")
        #expect(ResistanceGroupCode.normalize("50 (U8)") == "50")
        #expect(ResistanceGroupCode.normalize("50") == "50")
    }

    @Test("Signatures are canonically ordered so recording order never matters")
    func signatureOrdering() {
        #expect(ResistanceGroupSignature.of("11", "3").key == "3+11")
        #expect(ResistanceGroupSignature.of("3", "11").key == "3+11")
        #expect(ResistanceGroupSignature.of("49", "40").key == "40+49")
        #expect(ResistanceGroupSignature.of("45", "40").key == "40+45")
        // Numeric groups first, alphanumeric after.
        #expect(ResistanceGroupSignature.of("U6", "3").key == "3+U6")
    }

    @Test("Signatures de-duplicate repeated codes")
    func signatureDeduplication() {
        let signature = ResistanceGroupSignature.of("11", "11", "Group 11")
        #expect(signature.codes == ["11"])
        #expect(signature.isCoformulation == false)
    }

    // MARK: - Cross-platform parity

    @Test("Ruleset fingerprints are stable and deterministic")
    func fingerprintStability() {
        let powdery = ResistanceRulesets.powdery2026
        #expect(powdery.fingerprint() == powdery.fingerprint())
        #expect(powdery.fingerprint().count == 16)
        #expect(powdery.fingerprint().allSatisfy { $0.isNumber || ("a"..."f").contains($0) })
    }

    @Test("Fingerprints differ between the two strategies")
    func fingerprintsDiffer() {
        #expect(ResistanceRulesets.powdery2026.fingerprint() != ResistanceRulesets.downy2026.fingerprint())
    }

    @Test("Fingerprint changes when any threshold changes")
    func fingerprintDetectsThresholdChange() {
        let original = ResistanceRulesets.downy2026
        var tampered = original
        tampered.rules = original.rules.map { rule in
            guard rule.id == "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON" else { return rule }
            var changed = rule
            changed.kind = .maxApplicationsPerSeason(3)
            return changed
        }
        #expect(original.fingerprint() != tampered.fingerprint())
    }

    @Test("Fingerprint changes when a table cell changes")
    func fingerprintDetectsTableChange() throws {
        let original = ResistanceRulesets.powdery2026
        var table = try #require(original.maxUseTable)
        table.rows = table.rows.map { row in
            guard row.totalSprays == 3 else { return row }
            var changed = row
            changed.maxByColumn["3"] = 3
            return changed
        }
        var tampered = original
        tampered.maxUseTable = table
        #expect(original.fingerprint() != tampered.fingerprint())
    }

    @Test("Fingerprint ignores rule declaration order")
    func fingerprintOrderIndependent() {
        let original = ResistanceRulesets.downy2026
        var shuffled = original
        shuffled.rules = original.rules.reversed()
        #expect(original.fingerprint() == shuffled.fingerprint())
    }

    @Test("FNV-1a digest matches the shared reference vectors used by Android")
    func fnvReferenceVectors() {
        // Fixed vectors so a divergence in the hash arithmetic itself is caught, rather
        // than being mistaken for a ruleset difference.
        #expect(ResistanceRuleset.fnv1a64Hex("") == "cbf29ce484222325")
        #expect(ResistanceRuleset.fnv1a64Hex("a") == "af63dc4c8601ec8c")
        #expect(ResistanceRuleset.fnv1a64Hex("foobar") == "85944171f73967e8")
    }

    @Test("Canonical parity fingerprints are recorded for both platforms")
    func canonicalParityFingerprints() {
        // These constants are asserted identically in Android
        // `ResistanceRulesetTest.kt`. If either platform's encoding of the 2026
        // strategies drifts, that platform's test fails here rather than a grower
        // discovering it as contradictory advice on two phones.
        #expect(ResistanceRulesets.powdery2026.fingerprint() == ResistanceParityFixture.powdery2026Fingerprint)
        #expect(ResistanceRulesets.downy2026.fingerprint() == ResistanceParityFixture.downy2026Fingerprint)
    }
}
