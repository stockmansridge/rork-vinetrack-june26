import Foundation

/// The CropLife Australia 2026 grape resistance-management strategies, encoded.
///
/// SOURCE OF TRUTH — read before changing anything in this file:
///
/// - Issuer: CropLife Australia (national peak body for the plant science sector).
/// - Powdery: https://croplife.org.au/resources/programs/resistance-management/grape-powdery-mildew-3/
/// - Downy:   https://croplife.org.au/resources/programs/resistance-management/grape-downey-mildew/
/// - Both pages state: "Advice given in this strategy is valid as at 22 July 2026.
///   All previous versions of this strategy are now invalid."
///
/// FRAC supplies the group-classification vocabulary; CropLife Australia supplies
/// the Australian grape application strategy. Where CropLife gives a grape- and
/// disease-specific rule, that rule governs — generic FRAC guidance is not
/// substituted for it.
///
/// These strategies are guides to resistance management. They are NOT label
/// directions and NOT law. CropLife itself directs users to the product label and to
/// the APVMA database for contemporary product information. Nothing derived from
/// this file may be described to an operator as illegal, unsafe or prohibited.
///
/// Mirrors `ResistanceRulesets.kt` on Android. The two encodings are asserted
/// identical by fingerprint in both test suites.
nonisolated enum ResistanceRulesets {

    /// ISO-8601 date both 2026 strategies are valid as at.
    nonisolated static let cropLife2026ValidFrom = "2026-07-22"

    /// `2026-07-22T00:00:00Z`. A constant rather than a parsed date so the value is
    /// identical on both platforms and in every time zone.
    nonisolated static let cropLife2026ValidFromEpochMs: Int64 = 1_784_073_600_000

    nonisolated static let sourceOrganisation = "CropLife Australia"

    nonisolated static let powderyId = "AU_GRAPE_POWDERY_2026_07_22"
    nonisolated static let downyId = "AU_GRAPE_DOWNY_2026_07_22"

    private static let powderyURL =
        "https://croplife.org.au/resources/programs/resistance-management/grape-powdery-mildew-3/"
    private static let downyURL =
        "https://croplife.org.au/resources/programs/resistance-management/grape-downey-mildew/"

    // MARK: - Published sentences, verbatim

    private enum PowderyText {
        static let g1 = "Apply all these fungicides preventatively."
        static let g2 = """
            Consecutive applications include from the end of one season to the start of the next. \
            Medium to high risk fungicides (Group 7 and 11) if used consecutively should be applied \
            in a mixture or co-formulation with a registered, alternative mode of action for which \
            resistance is not known.
            """
        static let g3 = "Do not apply more than one application of Group 5+3."
        static let g4 = """
            Do not apply more than two consecutive sprays of Group 3, 5, 13, 19, 21, 50 (U8) and U6 \
            (including mixture formulations, apart from Group 5+3 which should be a maximum of one \
            application).
            """
        static let g5 = """
            Do not apply more than three Group 21 containing products per crop, or a maximum of 33% \
            of total applications (whichever is lower). Continue alternation of fungicides between \
            successive seasons.
            """
        static let table = """
            Maximum number of applications per group against the total number of powdery mildew \
            targeting sprays. N.B. Consecutive sprays include mixture formulations.
            """
    }

    private enum DownyText {
        static let g1 = """
            Start preventative disease control sprays using non-Group 4 protectant fungicides, \
            typically when shoots are 10-20cm long. Continue spraying at intervals of 7-21 days \
            depending on disease pressure, label directions and rate of vine growth.
            """
        static let g2 = """
            Group 4 fungicides should be applied as soon as possible after an infection period, and \
            before the first sign of oilspots. Limit the use of Group 4 fungicides to periods when \
            conditions favour disease development. Always apply Group 4 fungicides in mixtures.
            """
        static let g3Mixture = """
            Group 49 fungicides should be applied prior to infection and only in mixtures with \
            effective fungicides applied at an effective rate from a different cross resistance \
            group. The mixing partner should give effective control of downy mildew at the rate and \
            interval selected.
            """
        static let g3Season = "A maximum of two Group 49 applications may be made per season."
        static let g3OneInThree = """
            Only apply Group 49 for a maximum of one in every three sprays of the total number of \
            downy mildew sprays.
            """
        static let g3Intervening = """
            A Group 49, or 40+49 application must be followed by at least two applications of a \
            different group(s) before being reapplied.
            """
        static let g3Fraction4049 = """
            Only apply a spray containing Group 40, or 40+49 as a maximum of 33% of the total number \
            of downy mildew sprays.
            """
        static let g4Definition = """
            Fungicide mixtures are defined as co-formulations, or tank mixes at label rate of an \
            alternative mode of action.
            """
        static let g5 = """
            Apply a maximum of two consecutive applications of Group 4, 21, 40, or 45+40 containing \
            fungicides.
            """
        static let g6 = "Do not apply Group 11 (including mixture formulations) consecutively."
        static let g7 = """
            Apply a maximum of two sprays per season of Group 11 (including mixtures) Group 45+40, \
            Group 40 +49 and Group 49.
            """
        static let g8Last = "Do not apply a spray containing Group 40 as the last spray of the season."
        static let g8Fraction = """
            Only apply a spray containing Group 40 a maximum of 50% of the total number of downy \
            mildew sprays.
            """
        static let g9 = """
            Apply a maximum of three Group 21 containing sprays per season, and a maximum of two \
            consecutive sprays.
            """
        static let tableG4Season = """
            Grape - Downy mildew strategy table, Group 4: maximum number of sprays per season 4, \
            applied as mixtures.
            """
        static let tableG40Season = """
            Grape - Downy mildew strategy table, Group 40: maximum number of sprays per season 4 \
            applied as mixtures (50%), maximum number of solo sprays 2.
            """
        static let tableG49Season = """
            Grape - Downy mildew strategy table, Group 49: maximum number of sprays per season 2, \
            applied as mixtures.
            """
    }

    // MARK: - Signatures used by more than one rule

    private static let sig5plus3 = ResistanceGroupSignature.of("5", "3")
    private static let sig7plus12 = ResistanceGroupSignature.of("7", "12")
    private static let sig45plus40 = ResistanceGroupSignature.of("45", "40")
    private static let sig40plus49 = ResistanceGroupSignature.of("40", "49")

    // MARK: - Powdery mildew maximum-use table

    /// Column keys, stable and referenced by rule IDs.
    nonisolated enum PowderyColumns {
        nonisolated static let g3 = "3"
        nonisolated static let g5 = "5"
        /// CropLife prints Group 5+3 and Group 7+12 in ONE shared column.
        nonisolated static let g5_3And7_12 = "5+3,7+12"
        nonisolated static let g7 = "7"
        nonisolated static let g11 = "11"
        nonisolated static let g13 = "13"
        nonisolated static let g19 = "19"
        nonisolated static let g21 = "21"
        nonisolated static let g50 = "50"
        nonisolated static let u6 = "U6"
    }

    private static func powderyRow(
        _ total: Int,
        _ isOrMore: Bool,
        _ g3: Int,
        _ g5: Int,
        _ g53And712: Int,
        _ g7: Int,
        _ g11: Int,
        _ g13: Int,
        _ g19: Int,
        _ g21: Int,
        _ g50: Int,
        _ u6: Int
    ) -> ResistanceMaxUseRow {
        ResistanceMaxUseRow(
            totalSprays: total,
            isOrMore: isOrMore,
            maxByColumn: [
                PowderyColumns.g3: g3,
                PowderyColumns.g5: g5,
                PowderyColumns.g5_3And7_12: g53And712,
                PowderyColumns.g7: g7,
                PowderyColumns.g11: g11,
                PowderyColumns.g13: g13,
                PowderyColumns.g19: g19,
                PowderyColumns.g21: g21,
                PowderyColumns.g50: g50,
                PowderyColumns.u6: u6,
            ]
        )
    }

    /// The published Powdery maximum-use table, reproduced cell for cell.
    ///
    /// Rows are "Total number of powdery mildew targeting sprays"; the final row is
    /// CropLife's open-ended `9+`. Columns follow the published header order:
    /// 3 | 5 | 5+3, 7+12 | 7 (inc. 7+3) | 11 (inc. 11+3) | 13 | 19 | 21 | 50 (U8) | U6.
    nonisolated static let powderyMaxUseTable = ResistanceMaxUseTable(
        id: "AU_GRAPE_POWDERY_2026_MAX_USE_TABLE",
        rowKeyLabel: "Total number of powdery mildew targeting sprays",
        columns: [
            ResistanceMaxUseColumn(key: PowderyColumns.g3, displayName: "3", selector: .containsGroup("3")),
            ResistanceMaxUseColumn(key: PowderyColumns.g5, displayName: "5", selector: .containsGroup("5")),
            ResistanceMaxUseColumn(
                key: PowderyColumns.g5_3And7_12,
                displayName: "5 + 3, 7 + 12",
                selector: .anyCoformulation([sig5plus3, sig7plus12])
            ),
            ResistanceMaxUseColumn(key: PowderyColumns.g7, displayName: "7 (inc. 7 + 3)", selector: .containsGroup("7")),
            ResistanceMaxUseColumn(key: PowderyColumns.g11, displayName: "11 (inc. 11 + 3)", selector: .containsGroup("11")),
            ResistanceMaxUseColumn(key: PowderyColumns.g13, displayName: "13", selector: .containsGroup("13")),
            ResistanceMaxUseColumn(key: PowderyColumns.g19, displayName: "19", selector: .containsGroup("19")),
            ResistanceMaxUseColumn(key: PowderyColumns.g21, displayName: "21", selector: .containsGroup("21")),
            ResistanceMaxUseColumn(key: PowderyColumns.g50, displayName: "50 (U8)", selector: .containsGroup("50")),
            ResistanceMaxUseColumn(key: PowderyColumns.u6, displayName: "U6", selector: .containsGroup("U6")),
        ],
        rows: [
            //         total  9+     3  5  5+3 7  11 13 19 21 50 U6
            powderyRow(1, false, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
            powderyRow(2, false, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1),
            powderyRow(3, false, 2, 2, 1, 1, 2, 2, 2, 1, 1, 1),
            powderyRow(4, false, 2, 2, 1, 1, 2, 2, 2, 1, 2, 2),
            powderyRow(5, false, 2, 2, 1, 1, 2, 2, 2, 1, 2, 2),
            powderyRow(6, false, 3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            powderyRow(7, false, 3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            powderyRow(8, false, 3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            powderyRow(9, true, 3, 3, 1, 2, 2, 3, 3, 3, 2, 2),
        ],
        sourceReference: "Grape - Powdery mildew strategy table",
        notes: ["N.B. Consecutive sprays include mixture formulations."]
    )

    // MARK: - Powdery mildew ruleset

    /// Groups carrying the Guideline 4 two-consecutive restriction.
    private static let powderyTwoConsecutiveGroups: [(code: String, fragment: String)] = [
        ("3", "FRAC3"), ("5", "FRAC5"), ("13", "FRAC13"), ("19", "FRAC19"),
        ("21", "FRAC21"), ("50", "FRAC50"), ("U6", "FRACU6"),
    ]

    nonisolated static let powdery2026: ResistanceRuleset = {
        var rules: [ResistanceRule] = []

        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE",
                selector: .anyGroup(["3", "5", "7", "11", "12", "13", "19", "21", "50", "U6"]),
                kind: .preventativeApplicationGuidance,
                sourceReference: "Guideline 1",
                sourceText: PowderyText.g1
            )
        )

        // Guideline 4 — two consecutive, explicitly crossing the season boundary per
        // Guideline 2. Each group gets its own stable rule ID.
        for entry in powderyTwoConsecutiveGroups {
            rules.append(
                ResistanceRule(
                    id: "AU_GRAPE_POWDERY_\(entry.fragment)_MAX_CONSECUTIVE",
                    selector: .containsGroup(entry.code),
                    kind: .maxConsecutiveApplications(2),
                    sourceReference: "Guideline 4",
                    sourceText: PowderyText.g4,
                    crossSeason: true
                )
            )
        }

        // Guideline 3 — Group 5+3 co-formulation, one application only.
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON",
                selector: .coformulation(sig5plus3),
                kind: .maxApplicationsPerSeason(1),
                sourceReference: "Guideline 3",
                sourceText: PowderyText.g3
            )
        )

        // Guideline 2 — medium-to-high-risk groups mixed when used consecutively.
        for entry in [(code: "7", fragment: "FRAC7"), (code: "11", fragment: "FRAC11")] {
            rules.append(
                ResistanceRule(
                    id: "AU_GRAPE_POWDERY_\(entry.fragment)_MIXTURE_WHEN_CONSECUTIVE",
                    selector: .containsGroup(entry.code),
                    kind: .mixtureRequiredWhenConsecutive,
                    sourceReference: "Guideline 2",
                    sourceText: PowderyText.g2,
                    crossSeason: true
                )
            )
        }

        // Guideline 5 — Group 21 crop ceiling AND fraction ceiling, lower governs.
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP",
                selector: .containsGroup("21"),
                kind: .maxApplicationsPerCrop(3),
                sourceReference: "Guideline 5",
                sourceText: PowderyText.g5
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION",
                selector: .containsGroup("21"),
                kind: .maxFractionOfDiseaseSprays(numerator: 1, denominator: 3),
                sourceReference: "Guideline 5",
                sourceText: PowderyText.g5
            )
        )

        // The maximum-use table — one rule per published column.
        for column in powderyMaxUseTable.columns {
            rules.append(
                ResistanceRule(
                    id: "AU_GRAPE_POWDERY_\(columnIdFragment(column.key))_MAX_FROM_TOTAL_TABLE",
                    selector: column.selector,
                    kind: .maxFromTotalSprayCountTable(columnKey: column.key),
                    sourceReference: "Grape - Powdery mildew strategy table",
                    sourceText: PowderyText.table
                )
            )
        }

        return ResistanceRuleset(
            id: powderyId,
            jurisdiction: .australia,
            crop: .grape,
            disease: .powderyMildew,
            strategyName: "Grape - Powdery mildew",
            sourceOrganisation: sourceOrganisation,
            sourceReference: powderyURL,
            validFrom: cropLife2026ValidFrom,
            validFromEpochMs: cropLife2026ValidFromEpochMs,
            rulesetVersion: "2026.07.22",
            rules: rules,
            groups: [
                ResistanceGroupListing(displayName: "Group 3", signature: .of("3"), modeOfActionName: "Demethylation inhibitors (DMI)"),
                ResistanceGroupListing(displayName: "Group 5", signature: .of("5"), modeOfActionName: "Amines (morpholines)"),
                ResistanceGroupListing(displayName: "Group 5 + 3", signature: sig5plus3, modeOfActionName: "Amines + DMI"),
                ResistanceGroupListing(displayName: "Group 7", signature: .of("7"), modeOfActionName: "Succinate dehydrogenase inhibitors (SDHI)"),
                ResistanceGroupListing(displayName: "Group 7 + 3", signature: .of("7", "3"), modeOfActionName: "SDHI + DMI"),
                ResistanceGroupListing(displayName: "Group 7 + 12", signature: sig7plus12, modeOfActionName: "SDHI + phenylpyrroles (PP)"),
                ResistanceGroupListing(displayName: "Group 11", signature: .of("11"), modeOfActionName: "Quinone outside inhibitors (QoI)"),
                ResistanceGroupListing(displayName: "Group 11 + 3", signature: .of("11", "3"), modeOfActionName: "QoI + DMI"),
                ResistanceGroupListing(displayName: "Group 13", signature: .of("13"), modeOfActionName: "Aza-naphthalenes"),
                ResistanceGroupListing(displayName: "Group 19", signature: .of("19"), modeOfActionName: "Chitin synthase inhibitor"),
                ResistanceGroupListing(displayName: "Group 21", signature: .of("21"), modeOfActionName: "Quinone inside inhibitors (QiI)"),
                ResistanceGroupListing(displayName: "Group 50 (U8)", signature: .of("50"), modeOfActionName: "Actin disruptors (aryl-phenyl-ketones)"),
                ResistanceGroupListing(displayName: "Group U6", signature: .of("U6"), modeOfActionName: "Phenyl-acetamide"),
            ],
            maxUseTable: powderyMaxUseTable,
            sourceNotes: [
                """
                Guideline 2 states consecutive applications include from the end of one season to the \
                start of the next, so consecutive-run rules here are evaluated across the season \
                boundary rather than reset at it.
                """,
                """
                Group 7 + 12 appears BOTH in the shared '5+3, 7+12' table column (maximum 1) and \
                within the '7 (inc. 7+3)' column, because it contains Group 7. Both ceilings are \
                evaluated and the stricter one governs.
                """,
                """
                Group 11 + 3 contributes to Group 11 rules AND to Group 3 rules, because Guideline 4 \
                restricts Group 3 'including mixture formulations'.
                """,
                """
                FRAC renumbered Group U8 as Group 50; CropLife prints 'Group 50 (U8)'. Both spellings \
                normalise to '50'.
                """,
            ]
        )
    }()

    // MARK: - Downy mildew ruleset

    nonisolated static let downy2026: ResistanceRuleset = {
        var rules: [ResistanceRule] = []

        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_PROGRAM_PREVENTATIVE_START",
                selector: .anyGroup(["4", "11", "21", "40", "45", "49"]),
                kind: .preventativeApplicationGuidance,
                sourceReference: "Guideline 1",
                sourceText: DownyText.g1
            )
        )

        // --- Group 4 ---
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC4_MIXTURE_REQUIRED",
                selector: .containsGroup("4"),
                kind: .mixtureRequired,
                sourceReference: "Guideline 2",
                sourceText: DownyText.g2
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC4_MAX_CONSECUTIVE",
                selector: .containsGroup("4"),
                kind: .maxConsecutiveApplications(2),
                sourceReference: "Guideline 5",
                sourceText: DownyText.g5
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC4_MAX_SEASON",
                selector: .containsGroup("4"),
                kind: .maxApplicationsPerSeason(4),
                sourceReference: "Grape - Downy mildew strategy table",
                sourceText: DownyText.tableG4Season
            )
        )

        // --- Group 11 (including 11+3) ---
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE",
                selector: .containsGroup("11"),
                kind: .noConsecutiveApplications,
                sourceReference: "Guideline 6",
                sourceText: DownyText.g6
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC11_MAX_SEASON",
                selector: .containsGroup("11"),
                kind: .maxApplicationsPerSeason(2),
                sourceReference: "Guideline 7",
                sourceText: DownyText.g7
            )
        )

        // --- Group 21 ---
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC21_MAX_CONSECUTIVE",
                selector: .containsGroup("21"),
                kind: .maxConsecutiveApplications(2),
                sourceReference: "Guideline 9",
                sourceText: DownyText.g9
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC21_MAX_SEASON",
                selector: .containsGroup("21"),
                kind: .maxApplicationsPerSeason(3),
                sourceReference: "Guideline 9",
                sourceText: DownyText.g9
            )
        )

        // --- Group 40 ---
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_MAX_CONSECUTIVE",
                selector: .containsGroup("40"),
                kind: .maxConsecutiveApplications(2),
                sourceReference: "Guideline 5",
                sourceText: DownyText.g5
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY",
                selector: .containsGroup("40"),
                kind: .notLastSprayOfSeason,
                sourceReference: "Guideline 8",
                sourceText: DownyText.g8Last
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION",
                selector: .containsGroup("40"),
                kind: .maxFractionOfDiseaseSprays(numerator: 1, denominator: 2),
                sourceReference: "Guideline 8",
                sourceText: DownyText.g8Fraction
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_MAX_SEASON",
                selector: .containsGroup("40"),
                kind: .maxApplicationsPerSeason(4),
                sourceReference: "Grape - Downy mildew strategy table",
                sourceText: DownyText.tableG40Season
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON",
                selector: .containsGroup("40"),
                kind: .maxSoloApplicationsPerSeason(2),
                sourceReference: "Grape - Downy mildew strategy table",
                sourceText: DownyText.tableG40Season
            )
        )

        // --- Group 45+40 ---
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_CONSECUTIVE",
                selector: .coformulation(sig45plus40),
                kind: .maxConsecutiveApplications(2),
                sourceReference: "Guideline 5",
                sourceText: DownyText.g5
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_SEASON",
                selector: .coformulation(sig45plus40),
                kind: .maxApplicationsPerSeason(2),
                sourceReference: "Guideline 7",
                sourceText: DownyText.g7
            )
        )

        // --- Group 40+49 ---
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_SEASON",
                selector: .coformulation(sig40plus49),
                kind: .maxApplicationsPerSeason(2),
                sourceReference: "Guideline 7",
                sourceText: DownyText.g7
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION",
                selector: .coformulation(sig40plus49),
                kind: .maxFractionOfDiseaseSprays(numerator: 1, denominator: 3),
                sourceReference: "Guideline 3",
                sourceText: DownyText.g3Fraction4049
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING",
                selector: .coformulation(sig40plus49),
                kind: .minInterveningDifferentGroupApplications(2),
                sourceReference: "Guideline 3",
                sourceText: DownyText.g3Intervening
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC40_PLUS_49_NO_CONSECUTIVE",
                selector: .coformulation(sig40plus49),
                kind: .noConsecutiveApplications,
                sourceReference: "Grape - Downy mildew strategy table",
                sourceText: """
                    Grape - Downy mildew strategy table, Group 40 + 49: maximum number of consecutive \
                    applications None.
                    """
            )
        )

        // --- Group 49 ---
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED",
                selector: .containsGroup("49"),
                kind: .mixtureRequired,
                sourceReference: "Guideline 3",
                sourceText: DownyText.g3Mixture
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON",
                selector: .containsGroup("49"),
                kind: .maxApplicationsPerSeason(2),
                sourceReference: "Guideline 3",
                sourceText: DownyText.g3Season
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE",
                selector: .containsGroup("49"),
                kind: .maxOneInEveryNSprays(3),
                sourceReference: "Guideline 3",
                sourceText: DownyText.g3OneInThree
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING",
                selector: .containsGroup("49"),
                kind: .minInterveningDifferentGroupApplications(2),
                sourceReference: "Guideline 3",
                sourceText: DownyText.g3Intervening
            )
        )
        rules.append(
            ResistanceRule(
                id: "AU_GRAPE_DOWNY_FRAC49_NO_CONSECUTIVE",
                selector: .containsGroup("49"),
                kind: .noConsecutiveApplications,
                sourceReference: "Grape - Downy mildew strategy table",
                sourceText: """
                    Grape - Downy mildew strategy table, Group 49: maximum number of consecutive \
                    applications None.
                    """
            )
        )

        return ResistanceRuleset(
            id: downyId,
            jurisdiction: .australia,
            crop: .grape,
            disease: .downyMildew,
            strategyName: "Grape - Downy mildew",
            sourceOrganisation: sourceOrganisation,
            sourceReference: downyURL,
            validFrom: cropLife2026ValidFrom,
            validFromEpochMs: cropLife2026ValidFromEpochMs,
            rulesetVersion: "2026.07.22",
            rules: rules,
            groups: [
                ResistanceGroupListing(displayName: "Group 4", signature: .of("4"), modeOfActionName: "Phenylamides (PA)"),
                ResistanceGroupListing(displayName: "Group 11", signature: .of("11"), modeOfActionName: "Quinone outside inhibitors (QoI)"),
                ResistanceGroupListing(displayName: "Group 11 + 3", signature: .of("11", "3"), modeOfActionName: "QoI + Demethylation inhibitors (DMI)"),
                ResistanceGroupListing(displayName: "Group 21", signature: .of("21"), modeOfActionName: "Quinone inside inhibitors (QiI)"),
                ResistanceGroupListing(displayName: "Group 40", signature: .of("40"), modeOfActionName: "Carboxylic acid amides (CAA)"),
                ResistanceGroupListing(displayName: "Group 40 + 49", signature: sig40plus49, modeOfActionName: "CAA + Oxysterol binding protein homologue inhibitors (OSBPI)"),
                ResistanceGroupListing(displayName: "Group 45 + 40", signature: sig45plus40, modeOfActionName: "Quinone outside inhibitor, stigmatellin binding type (QoSI) + CAA"),
                ResistanceGroupListing(displayName: "Group 49", signature: .of("49"), modeOfActionName: "Oxysterol binding protein homologue inhibitors (OSBPI)"),
            ],
            maxUseTable: nil,
            sourceNotes: [
                """
                SOURCE AMBIGUITY, Group 40 percentage ceiling: Guideline 3 reads 'Only apply a spray \
                containing Group 40, or 40+49 as a maximum of 33%', while Guideline 8 reads 'Only \
                apply a spray containing Group 40 a maximum of 50%'. The published strategy table \
                resolves this by footnote: the Group 40 column carries '(50%)' referring to point 8, \
                and the Group 40+49 column carries '(33%)' referring to point 3. Encoded accordingly: \
                Group 40 at 1/2, Group 40+49 at 1/3. Re-check on the next revision.
                """,
                """
                SOURCE AMBIGUITY, Group 45+40 solo sprays: the table's 'Max. number of solo sprays' \
                cell for Group 45+40 reads 'None', but no guideline states a mixture requirement for \
                it. No solo-prohibition rule has been encoded, because inventing one would generate \
                warnings the published guidelines do not support. Group 4 and Group 49 DO carry \
                explicit mixture requirements (Guidelines 2 and 3) and are encoded.
                """,
                """
                Guideline 8's 'last spray of the season' cannot be decided until a season is \
                complete, so it is reported as guidance on the currently-final spray rather than as a \
                breach.
                """,
                """
                The 'Areas of higher agronomic risk' table row advises mixing Groups 4, 11, 40 and \
                49. Treated as advisory context, not an absolute mixture requirement, because it is \
                conditional on a risk assessment VineTrack does not hold.
                """,
                """
                Group 11 + 3 contributes to Group 11 rules via its component groups AND is recognised \
                as its own co-formulation signature.
                """,
                DownyText.g4Definition,
            ]
        )
    }()

    // MARK: - Registry

    /// Every strategy VineTrack knows.
    ///
    /// When the 2027 strategies arrive, ADD them here and set `supersededBy` on the
    /// 2026 entries. Never delete a ruleset: a 2026 spray must remain explainable by
    /// the strategy that was actually in force when it was applied.
    nonisolated static let registry = ResistanceRulesetRegistry([powdery2026, downy2026])

    private static func columnIdFragment(_ columnKey: String) -> String {
        switch columnKey {
        case PowderyColumns.g5_3And7_12: return "FRAC5_PLUS_3_AND_7_PLUS_12"
        case PowderyColumns.u6: return "FRACU6"
        default: return "FRAC\(columnKey)"
        }
    }
}
