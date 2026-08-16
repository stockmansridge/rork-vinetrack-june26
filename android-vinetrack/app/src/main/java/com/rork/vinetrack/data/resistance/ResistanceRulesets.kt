package com.rork.vinetrack.data.resistance

/**
 * The CropLife Australia 2026 grape resistance-management strategies, encoded.
 *
 * SOURCE OF TRUTH — read before changing anything in this file:
 *
 * - Issuer: CropLife Australia (national peak body for the plant science sector).
 * - Powdery: https://croplife.org.au/resources/programs/resistance-management/grape-powdery-mildew-3/
 * - Downy:   https://croplife.org.au/resources/programs/resistance-management/grape-downey-mildew/
 * - Both pages state: "Advice given in this strategy is valid as at 22 July 2026.
 *   All previous versions of this strategy are now invalid."
 *
 * FRAC supplies the group-classification vocabulary; CropLife Australia supplies
 * the Australian grape application strategy. Where CropLife gives a grape- and
 * disease-specific rule, that rule governs — generic FRAC guidance is not
 * substituted for it.
 *
 * These strategies are guides to resistance management. They are NOT label
 * directions and NOT law. CropLife itself directs users to the product label and
 * to the APVMA database for contemporary product information. Nothing derived
 * from this file may be described to an operator as illegal, unsafe or
 * prohibited.
 *
 * Mirrors iOS `ResistanceRulesets.swift`. The two encodings are asserted
 * identical by fingerprint in both test suites.
 */
object ResistanceRulesets {

    /** ISO-8601 date both 2026 strategies are valid as at. */
    const val CROPLIFE_2026_VALID_FROM: String = "2026-07-22"

    /**
     * `2026-07-22T00:00:00Z`. A constant rather than a parsed date so the value
     * is identical on both platforms and in every time zone.
     */
    const val CROPLIFE_2026_VALID_FROM_EPOCH_MS: Long = 1_784_073_600_000L

    const val SOURCE_ORGANISATION: String = "CropLife Australia"

    const val POWDERY_ID: String = "AU_GRAPE_POWDERY_2026_07_22"
    const val DOWNY_ID: String = "AU_GRAPE_DOWNY_2026_07_22"

    private const val POWDERY_URL =
        "https://croplife.org.au/resources/programs/resistance-management/grape-powdery-mildew-3/"
    private const val DOWNY_URL =
        "https://croplife.org.au/resources/programs/resistance-management/grape-downey-mildew/"

    // -----------------------------------------------------------------------
    // Published sentences, verbatim.
    // -----------------------------------------------------------------------

    private object PowderyText {
        const val G1 = "Apply all these fungicides preventatively."
        const val G2 =
            "Consecutive applications include from the end of one season to the start of the " +
                "next. Medium to high risk fungicides (Group 7 and 11) if used consecutively " +
                "should be applied in a mixture or co-formulation with a registered, alternative " +
                "mode of action for which resistance is not known."
        const val G3 = "Do not apply more than one application of Group 5+3."
        const val G4 =
            "Do not apply more than two consecutive sprays of Group 3, 5, 13, 19, 21, 50 (U8) " +
                "and U6 (including mixture formulations, apart from Group 5+3 which should be a " +
                "maximum of one application)."
        const val G5 =
            "Do not apply more than three Group 21 containing products per crop, or a maximum " +
                "of 33% of total applications (whichever is lower). Continue alternation of " +
                "fungicides between successive seasons."
        const val TABLE =
            "Maximum number of applications per group against the total number of powdery " +
                "mildew targeting sprays. N.B. Consecutive sprays include mixture formulations."
    }

    private object DownyText {
        const val G1 =
            "Start preventative disease control sprays using non-Group 4 protectant fungicides, " +
                "typically when shoots are 10-20cm long. Continue spraying at intervals of 7-21 " +
                "days depending on disease pressure, label directions and rate of vine growth."
        const val G2 =
            "Group 4 fungicides should be applied as soon as possible after an infection period, " +
                "and before the first sign of oilspots. Limit the use of Group 4 fungicides to " +
                "periods when conditions favour disease development. Always apply Group 4 " +
                "fungicides in mixtures."
        const val G3_MIXTURE =
            "Group 49 fungicides should be applied prior to infection and only in mixtures with " +
                "effective fungicides applied at an effective rate from a different cross " +
                "resistance group. The mixing partner should give effective control of downy " +
                "mildew at the rate and interval selected."
        const val G3_SEASON = "A maximum of two Group 49 applications may be made per season."
        const val G3_ONE_IN_THREE =
            "Only apply Group 49 for a maximum of one in every three sprays of the total number " +
                "of downy mildew sprays."
        const val G3_INTERVENING =
            "A Group 49, or 40+49 application must be followed by at least two applications of a " +
                "different group(s) before being reapplied."
        const val G3_FRACTION_40_49 =
            "Only apply a spray containing Group 40, or 40+49 as a maximum of 33% of the total " +
                "number of downy mildew sprays."
        const val G4_DEFINITION =
            "Fungicide mixtures are defined as co-formulations, or tank mixes at label rate of an " +
                "alternative mode of action."
        const val G5 =
            "Apply a maximum of two consecutive applications of Group 4, 21, 40, or 45+40 " +
                "containing fungicides."
        const val G6 = "Do not apply Group 11 (including mixture formulations) consecutively."
        const val G7 =
            "Apply a maximum of two sprays per season of Group 11 (including mixtures) Group " +
                "45+40, Group 40 +49 and Group 49."
        const val G8_LAST =
            "Do not apply a spray containing Group 40 as the last spray of the season."
        const val G8_FRACTION =
            "Only apply a spray containing Group 40 a maximum of 50% of the total number of downy " +
                "mildew sprays."
        const val G9 =
            "Apply a maximum of three Group 21 containing sprays per season, and a maximum of two " +
                "consecutive sprays."
        const val TABLE_G4_SEASON =
            "Grape - Downy mildew strategy table, Group 4: maximum number of sprays per season " +
                "4, applied as mixtures."
        const val TABLE_G40_SEASON =
            "Grape - Downy mildew strategy table, Group 40: maximum number of sprays per season " +
                "4 applied as mixtures (50%), maximum number of solo sprays 2."
        const val TABLE_G49_SEASON =
            "Grape - Downy mildew strategy table, Group 49: maximum number of sprays per season " +
                "2, applied as mixtures."
        const val TABLE_HIGHER_RISK =
            "Grape - Downy mildew strategy table, areas of higher agronomic risk: apply Group 4, " +
                "11, 40 and 49 in mixtures."
    }

    // -----------------------------------------------------------------------
    // Signatures used by more than one rule.
    // -----------------------------------------------------------------------

    private val sig5plus3 = ResistanceGroupSignature.of("5", "3")
    private val sig7plus12 = ResistanceGroupSignature.of("7", "12")
    private val sig45plus40 = ResistanceGroupSignature.of("45", "40")
    private val sig40plus49 = ResistanceGroupSignature.of("40", "49")

    // -----------------------------------------------------------------------
    // Powdery mildew maximum-use table
    // -----------------------------------------------------------------------

    /** Column keys, stable and referenced by rule IDs. */
    object PowderyColumns {
        const val G3 = "3"
        const val G5 = "5"

        /** CropLife prints Group 5+3 and Group 7+12 in ONE shared column. */
        const val G5_3_AND_7_12 = "5+3,7+12"
        const val G7 = "7"
        const val G11 = "11"
        const val G13 = "13"
        const val G19 = "19"
        const val G21 = "21"
        const val G50 = "50"
        const val U6 = "U6"
    }

    private fun powderyRow(
        total: Int,
        isOrMore: Boolean,
        g3: Int,
        g5: Int,
        g53And712: Int,
        g7: Int,
        g11: Int,
        g13: Int,
        g19: Int,
        g21: Int,
        g50: Int,
        u6: Int,
    ) = ResistanceMaxUseRow(
        totalSprays = total,
        isOrMore = isOrMore,
        maxByColumn = mapOf(
            PowderyColumns.G3 to g3,
            PowderyColumns.G5 to g5,
            PowderyColumns.G5_3_AND_7_12 to g53And712,
            PowderyColumns.G7 to g7,
            PowderyColumns.G11 to g11,
            PowderyColumns.G13 to g13,
            PowderyColumns.G19 to g19,
            PowderyColumns.G21 to g21,
            PowderyColumns.G50 to g50,
            PowderyColumns.U6 to u6,
        ),
    )

    /**
     * The published Powdery maximum-use table, reproduced cell for cell.
     *
     * Rows are "Total number of powdery mildew targeting sprays"; the final row is
     * CropLife's open-ended `9+`. Columns follow the published header order:
     * 3 | 5 | 5+3, 7+12 | 7 (inc. 7+3) | 11 (inc. 11+3) | 13 | 19 | 21 | 50 (U8) | U6.
     */
    val powderyMaxUseTable: ResistanceMaxUseTable = ResistanceMaxUseTable(
        id = "AU_GRAPE_POWDERY_2026_MAX_USE_TABLE",
        rowKeyLabel = "Total number of powdery mildew targeting sprays",
        sourceReference = "Grape - Powdery mildew strategy table",
        notes = listOf("N.B. Consecutive sprays include mixture formulations."),
        columns = listOf(
            ResistanceMaxUseColumn(PowderyColumns.G3, "3", ResistanceGroupSelector.ContainsGroup("3")),
            ResistanceMaxUseColumn(PowderyColumns.G5, "5", ResistanceGroupSelector.ContainsGroup("5")),
            ResistanceMaxUseColumn(
                PowderyColumns.G5_3_AND_7_12,
                "5 + 3, 7 + 12",
                ResistanceGroupSelector.AnyCoformulation(listOf(sig5plus3, sig7plus12)),
            ),
            ResistanceMaxUseColumn(PowderyColumns.G7, "7 (inc. 7 + 3)", ResistanceGroupSelector.ContainsGroup("7")),
            ResistanceMaxUseColumn(PowderyColumns.G11, "11 (inc. 11 + 3)", ResistanceGroupSelector.ContainsGroup("11")),
            ResistanceMaxUseColumn(PowderyColumns.G13, "13", ResistanceGroupSelector.ContainsGroup("13")),
            ResistanceMaxUseColumn(PowderyColumns.G19, "19", ResistanceGroupSelector.ContainsGroup("19")),
            ResistanceMaxUseColumn(PowderyColumns.G21, "21", ResistanceGroupSelector.ContainsGroup("21")),
            ResistanceMaxUseColumn(PowderyColumns.G50, "50 (U8)", ResistanceGroupSelector.ContainsGroup("50")),
            ResistanceMaxUseColumn(PowderyColumns.U6, "U6", ResistanceGroupSelector.ContainsGroup("U6")),
        ),
        rows = listOf(
            //          total  9+     3  5  5+3 7  11 13 19 21 50 U6
            powderyRow(1, false, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
            powderyRow(2, false, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1),
            powderyRow(3, false, 2, 2, 1, 1, 2, 2, 2, 1, 1, 1),
            powderyRow(4, false, 2, 2, 1, 1, 2, 2, 2, 1, 2, 2),
            powderyRow(5, false, 2, 2, 1, 1, 2, 2, 2, 1, 2, 2),
            powderyRow(6, false, 3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            powderyRow(7, false, 3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            powderyRow(8, false, 3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            powderyRow(9, true, 3, 3, 1, 2, 2, 3, 3, 3, 2, 2),
        ),
    )

    // -----------------------------------------------------------------------
    // Powdery mildew ruleset
    // -----------------------------------------------------------------------

    /** Groups carrying the Guideline 4 two-consecutive restriction. */
    private val powderyTwoConsecutiveGroups: List<Pair<String, String>> = listOf(
        "3" to "FRAC3",
        "5" to "FRAC5",
        "13" to "FRAC13",
        "19" to "FRAC19",
        "21" to "FRAC21",
        "50" to "FRAC50",
        "U6" to "FRACU6",
    )

    val powdery2026: ResistanceRuleset by lazy {
        val rules = mutableListOf<ResistanceRule>()

        rules += ResistanceRule(
            id = "AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE",
            selector = ResistanceGroupSelector.AnyGroup(
                listOf("3", "5", "7", "11", "12", "13", "19", "21", "50", "U6"),
            ),
            kind = ResistanceRuleKind.PreventativeApplicationGuidance,
            sourceReference = "Guideline 1",
            sourceText = PowderyText.G1,
        )

        // Guideline 4 — two consecutive, explicitly crossing the season boundary
        // per Guideline 2. Each group gets its own stable rule ID.
        powderyTwoConsecutiveGroups.forEach { (code, idFragment) ->
            rules += ResistanceRule(
                id = "AU_GRAPE_POWDERY_${idFragment}_MAX_CONSECUTIVE",
                selector = ResistanceGroupSelector.ContainsGroup(code),
                kind = ResistanceRuleKind.MaxConsecutiveApplications(2),
                sourceReference = "Guideline 4",
                sourceText = PowderyText.G4,
                crossSeason = true,
            )
        }

        // Guideline 3 — Group 5+3 co-formulation, one application only.
        rules += ResistanceRule(
            id = "AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON",
            selector = ResistanceGroupSelector.Coformulation(sig5plus3),
            kind = ResistanceRuleKind.MaxApplicationsPerSeason(1),
            sourceReference = "Guideline 3",
            sourceText = PowderyText.G3,
        )

        // Guideline 2 — medium-to-high-risk groups mixed when used consecutively.
        listOf("7" to "FRAC7", "11" to "FRAC11").forEach { (code, idFragment) ->
            rules += ResistanceRule(
                id = "AU_GRAPE_POWDERY_${idFragment}_MIXTURE_WHEN_CONSECUTIVE",
                selector = ResistanceGroupSelector.ContainsGroup(code),
                kind = ResistanceRuleKind.MixtureRequiredWhenConsecutive,
                sourceReference = "Guideline 2",
                sourceText = PowderyText.G2,
                crossSeason = true,
            )
        }

        // Guideline 5 — Group 21 crop ceiling AND fraction ceiling, lower governs.
        rules += ResistanceRule(
            id = "AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP",
            selector = ResistanceGroupSelector.ContainsGroup("21"),
            kind = ResistanceRuleKind.MaxApplicationsPerCrop(3),
            sourceReference = "Guideline 5",
            sourceText = PowderyText.G5,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION",
            selector = ResistanceGroupSelector.ContainsGroup("21"),
            kind = ResistanceRuleKind.MaxFractionOfDiseaseSprays(1, 3),
            sourceReference = "Guideline 5",
            sourceText = PowderyText.G5,
        )

        // The maximum-use table — one rule per published column.
        powderyMaxUseTable.columns.forEach { column ->
            rules += ResistanceRule(
                id = "AU_GRAPE_POWDERY_${columnIdFragment(column.key)}_MAX_FROM_TOTAL_TABLE",
                selector = column.selector,
                kind = ResistanceRuleKind.MaxFromTotalSprayCountTable(column.key),
                sourceReference = "Grape - Powdery mildew strategy table",
                sourceText = PowderyText.TABLE,
            )
        }

        ResistanceRuleset(
            id = POWDERY_ID,
            jurisdiction = ResistanceJurisdiction.AUSTRALIA,
            crop = ResistanceCrop.GRAPE,
            disease = ResistanceDisease.POWDERY_MILDEW,
            strategyName = "Grape - Powdery mildew",
            sourceOrganisation = SOURCE_ORGANISATION,
            sourceReference = POWDERY_URL,
            validFrom = CROPLIFE_2026_VALID_FROM,
            validFromEpochMs = CROPLIFE_2026_VALID_FROM_EPOCH_MS,
            rulesetVersion = "2026.07.22",
            rules = rules,
            maxUseTable = powderyMaxUseTable,
            groups = listOf(
                ResistanceGroupListing("Group 3", ResistanceGroupSignature.of("3"), "Demethylation inhibitors (DMI)"),
                ResistanceGroupListing("Group 5", ResistanceGroupSignature.of("5"), "Amines (morpholines)"),
                ResistanceGroupListing("Group 5 + 3", sig5plus3, "Amines + DMI"),
                ResistanceGroupListing("Group 7", ResistanceGroupSignature.of("7"), "Succinate dehydrogenase inhibitors (SDHI)"),
                ResistanceGroupListing("Group 7 + 3", ResistanceGroupSignature.of("7", "3"), "SDHI + DMI"),
                ResistanceGroupListing("Group 7 + 12", sig7plus12, "SDHI + phenylpyrroles (PP)"),
                ResistanceGroupListing("Group 11", ResistanceGroupSignature.of("11"), "Quinone outside inhibitors (QoI)"),
                ResistanceGroupListing("Group 11 + 3", ResistanceGroupSignature.of("11", "3"), "QoI + DMI"),
                ResistanceGroupListing("Group 13", ResistanceGroupSignature.of("13"), "Aza-naphthalenes"),
                ResistanceGroupListing("Group 19", ResistanceGroupSignature.of("19"), "Chitin synthase inhibitor"),
                ResistanceGroupListing("Group 21", ResistanceGroupSignature.of("21"), "Quinone inside inhibitors (QiI)"),
                ResistanceGroupListing("Group 50 (U8)", ResistanceGroupSignature.of("50"), "Actin disruptors (aryl-phenyl-ketones)"),
                ResistanceGroupListing("Group U6", ResistanceGroupSignature.of("U6"), "Phenyl-acetamide"),
            ),
            sourceNotes = listOf(
                "Guideline 2 states consecutive applications include from the end of one season " +
                    "to the start of the next, so consecutive-run rules here are evaluated across " +
                    "the season boundary rather than reset at it.",
                "Group 7 + 12 appears BOTH in the shared '5+3, 7+12' table column (maximum 1) and " +
                    "within the '7 (inc. 7+3)' column, because it contains Group 7. Both ceilings " +
                    "are evaluated and the stricter one governs.",
                "Group 11 + 3 contributes to Group 11 rules AND to Group 3 rules, because " +
                    "Guideline 4 restricts Group 3 'including mixture formulations'.",
                "FRAC renumbered Group U8 as Group 50; CropLife prints 'Group 50 (U8)'. Both " +
                    "spellings normalise to '50'.",
            ),
        )
    }

    // -----------------------------------------------------------------------
    // Downy mildew ruleset
    // -----------------------------------------------------------------------

    val downy2026: ResistanceRuleset by lazy {
        val rules = mutableListOf<ResistanceRule>()

        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_PROGRAM_PREVENTATIVE_START",
            selector = ResistanceGroupSelector.AnyGroup(listOf("4", "11", "21", "40", "45", "49")),
            kind = ResistanceRuleKind.PreventativeApplicationGuidance,
            sourceReference = "Guideline 1",
            sourceText = DownyText.G1,
        )

        // --- Group 4 -------------------------------------------------------
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC4_MIXTURE_REQUIRED",
            selector = ResistanceGroupSelector.ContainsGroup("4"),
            kind = ResistanceRuleKind.MixtureRequired,
            sourceReference = "Guideline 2",
            sourceText = DownyText.G2,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC4_MAX_CONSECUTIVE",
            selector = ResistanceGroupSelector.ContainsGroup("4"),
            kind = ResistanceRuleKind.MaxConsecutiveApplications(2),
            sourceReference = "Guideline 5",
            sourceText = DownyText.G5,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC4_MAX_SEASON",
            selector = ResistanceGroupSelector.ContainsGroup("4"),
            kind = ResistanceRuleKind.MaxApplicationsPerSeason(4),
            sourceReference = "Grape - Downy mildew strategy table",
            sourceText = DownyText.TABLE_G4_SEASON,
        )

        // --- Group 11 (including 11+3) -------------------------------------
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE",
            selector = ResistanceGroupSelector.ContainsGroup("11"),
            kind = ResistanceRuleKind.NoConsecutiveApplications,
            sourceReference = "Guideline 6",
            sourceText = DownyText.G6,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC11_MAX_SEASON",
            selector = ResistanceGroupSelector.ContainsGroup("11"),
            kind = ResistanceRuleKind.MaxApplicationsPerSeason(2),
            sourceReference = "Guideline 7",
            sourceText = DownyText.G7,
        )

        // --- Group 21 ------------------------------------------------------
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC21_MAX_CONSECUTIVE",
            selector = ResistanceGroupSelector.ContainsGroup("21"),
            kind = ResistanceRuleKind.MaxConsecutiveApplications(2),
            sourceReference = "Guideline 9",
            sourceText = DownyText.G9,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC21_MAX_SEASON",
            selector = ResistanceGroupSelector.ContainsGroup("21"),
            kind = ResistanceRuleKind.MaxApplicationsPerSeason(3),
            sourceReference = "Guideline 9",
            sourceText = DownyText.G9,
        )

        // --- Group 40 ------------------------------------------------------
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_MAX_CONSECUTIVE",
            selector = ResistanceGroupSelector.ContainsGroup("40"),
            kind = ResistanceRuleKind.MaxConsecutiveApplications(2),
            sourceReference = "Guideline 5",
            sourceText = DownyText.G5,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY",
            selector = ResistanceGroupSelector.ContainsGroup("40"),
            kind = ResistanceRuleKind.NotLastSprayOfSeason,
            sourceReference = "Guideline 8",
            sourceText = DownyText.G8_LAST,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION",
            selector = ResistanceGroupSelector.ContainsGroup("40"),
            kind = ResistanceRuleKind.MaxFractionOfDiseaseSprays(1, 2),
            sourceReference = "Guideline 8",
            sourceText = DownyText.G8_FRACTION,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_MAX_SEASON",
            selector = ResistanceGroupSelector.ContainsGroup("40"),
            kind = ResistanceRuleKind.MaxApplicationsPerSeason(4),
            sourceReference = "Grape - Downy mildew strategy table",
            sourceText = DownyText.TABLE_G40_SEASON,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON",
            selector = ResistanceGroupSelector.ContainsGroup("40"),
            kind = ResistanceRuleKind.MaxSoloApplicationsPerSeason(2),
            sourceReference = "Grape - Downy mildew strategy table",
            sourceText = DownyText.TABLE_G40_SEASON,
        )

        // --- Group 45+40 ---------------------------------------------------
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_CONSECUTIVE",
            selector = ResistanceGroupSelector.Coformulation(sig45plus40),
            kind = ResistanceRuleKind.MaxConsecutiveApplications(2),
            sourceReference = "Guideline 5",
            sourceText = DownyText.G5,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_SEASON",
            selector = ResistanceGroupSelector.Coformulation(sig45plus40),
            kind = ResistanceRuleKind.MaxApplicationsPerSeason(2),
            sourceReference = "Guideline 7",
            sourceText = DownyText.G7,
        )

        // --- Group 40+49 ---------------------------------------------------
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_SEASON",
            selector = ResistanceGroupSelector.Coformulation(sig40plus49),
            kind = ResistanceRuleKind.MaxApplicationsPerSeason(2),
            sourceReference = "Guideline 7",
            sourceText = DownyText.G7,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION",
            selector = ResistanceGroupSelector.Coformulation(sig40plus49),
            kind = ResistanceRuleKind.MaxFractionOfDiseaseSprays(1, 3),
            sourceReference = "Guideline 3",
            sourceText = DownyText.G3_FRACTION_40_49,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING",
            selector = ResistanceGroupSelector.Coformulation(sig40plus49),
            kind = ResistanceRuleKind.MinInterveningDifferentGroupApplications(2),
            sourceReference = "Guideline 3",
            sourceText = DownyText.G3_INTERVENING,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC40_PLUS_49_NO_CONSECUTIVE",
            selector = ResistanceGroupSelector.Coformulation(sig40plus49),
            kind = ResistanceRuleKind.NoConsecutiveApplications,
            sourceReference = "Grape - Downy mildew strategy table",
            sourceText = "Grape - Downy mildew strategy table, Group 40 + 49: maximum number of " +
                "consecutive applications None.",
        )

        // --- Group 49 ------------------------------------------------------
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED",
            selector = ResistanceGroupSelector.ContainsGroup("49"),
            kind = ResistanceRuleKind.MixtureRequired,
            sourceReference = "Guideline 3",
            sourceText = DownyText.G3_MIXTURE,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON",
            selector = ResistanceGroupSelector.ContainsGroup("49"),
            kind = ResistanceRuleKind.MaxApplicationsPerSeason(2),
            sourceReference = "Guideline 3",
            sourceText = DownyText.G3_SEASON,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE",
            selector = ResistanceGroupSelector.ContainsGroup("49"),
            kind = ResistanceRuleKind.MaxOneInEveryNSprays(3),
            sourceReference = "Guideline 3",
            sourceText = DownyText.G3_ONE_IN_THREE,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING",
            selector = ResistanceGroupSelector.ContainsGroup("49"),
            kind = ResistanceRuleKind.MinInterveningDifferentGroupApplications(2),
            sourceReference = "Guideline 3",
            sourceText = DownyText.G3_INTERVENING,
        )
        rules += ResistanceRule(
            id = "AU_GRAPE_DOWNY_FRAC49_NO_CONSECUTIVE",
            selector = ResistanceGroupSelector.ContainsGroup("49"),
            kind = ResistanceRuleKind.NoConsecutiveApplications,
            sourceReference = "Grape - Downy mildew strategy table",
            sourceText = "Grape - Downy mildew strategy table, Group 49: maximum number of " +
                "consecutive applications None.",
        )

        ResistanceRuleset(
            id = DOWNY_ID,
            jurisdiction = ResistanceJurisdiction.AUSTRALIA,
            crop = ResistanceCrop.GRAPE,
            disease = ResistanceDisease.DOWNY_MILDEW,
            strategyName = "Grape - Downy mildew",
            sourceOrganisation = SOURCE_ORGANISATION,
            sourceReference = DOWNY_URL,
            validFrom = CROPLIFE_2026_VALID_FROM,
            validFromEpochMs = CROPLIFE_2026_VALID_FROM_EPOCH_MS,
            rulesetVersion = "2026.07.22",
            rules = rules,
            maxUseTable = null,
            groups = listOf(
                ResistanceGroupListing("Group 4", ResistanceGroupSignature.of("4"), "Phenylamides (PA)"),
                ResistanceGroupListing("Group 11", ResistanceGroupSignature.of("11"), "Quinone outside inhibitors (QoI)"),
                ResistanceGroupListing("Group 11 + 3", ResistanceGroupSignature.of("11", "3"), "QoI + Demethylation inhibitors (DMI)"),
                ResistanceGroupListing("Group 21", ResistanceGroupSignature.of("21"), "Quinone inside inhibitors (QiI)"),
                ResistanceGroupListing("Group 40", ResistanceGroupSignature.of("40"), "Carboxylic acid amides (CAA)"),
                ResistanceGroupListing("Group 40 + 49", sig40plus49, "CAA + Oxysterol binding protein homologue inhibitors (OSBPI)"),
                ResistanceGroupListing("Group 45 + 40", sig45plus40, "Quinone outside inhibitor, stigmatellin binding type (QoSI) + CAA"),
                ResistanceGroupListing("Group 49", ResistanceGroupSignature.of("49"), "Oxysterol binding protein homologue inhibitors (OSBPI)"),
            ),
            sourceNotes = listOf(
                "SOURCE AMBIGUITY, Group 40 percentage ceiling: Guideline 3 reads 'Only apply a " +
                    "spray containing Group 40, or 40+49 as a maximum of 33%', while Guideline 8 " +
                    "reads 'Only apply a spray containing Group 40 a maximum of 50%'. The " +
                    "published strategy table resolves this by footnote: the Group 40 column " +
                    "carries '(50%)' referring to point 8, and the Group 40+49 column carries " +
                    "'(33%)' referring to point 3. Encoded accordingly: Group 40 at 1/2, Group " +
                    "40+49 at 1/3. Re-check on the next revision.",
                "SOURCE AMBIGUITY, Group 45+40 solo sprays: the table's 'Max. number of solo " +
                    "sprays' cell for Group 45+40 reads 'None', but no guideline states a mixture " +
                    "requirement for it. No solo-prohibition rule has been encoded, because " +
                    "inventing one would generate warnings the published guidelines do not " +
                    "support. Group 4 and Group 49 DO carry explicit mixture requirements " +
                    "(Guidelines 2 and 3) and are encoded.",
                "Guideline 8's 'last spray of the season' cannot be decided until a season is " +
                    "complete, so it is reported as guidance on the currently-final spray rather " +
                    "than as a breach.",
                "The 'Areas of higher agronomic risk' table row advises mixing Groups 4, 11, 40 " +
                    "and 49. Treated as advisory context, not an absolute mixture requirement, " +
                    "because it is conditional on a risk assessment VineTrack does not hold.",
                "Group 11 + 3 contributes to Group 11 rules via its component groups AND is " +
                    "recognised as its own co-formulation signature.",
            ),
        )
    }

    // -----------------------------------------------------------------------
    // Registry
    // -----------------------------------------------------------------------

    /**
     * Every strategy VineTrack knows.
     *
     * When the 2027 strategies arrive, ADD them here and set `supersededBy` on the
     * 2026 entries. Never delete a ruleset: a 2026 spray must remain explainable
     * by the strategy that was actually in force when it was applied.
     */
    val registry: ResistanceRulesetRegistry by lazy {
        ResistanceRulesetRegistry(listOf(powdery2026, downy2026))
    }

    private fun columnIdFragment(columnKey: String): String = when (columnKey) {
        PowderyColumns.G5_3_AND_7_12 -> "FRAC5_PLUS_3_AND_7_PLUS_12"
        PowderyColumns.U6 -> "FRACU6"
        else -> "FRAC$columnKey"
    }
}
