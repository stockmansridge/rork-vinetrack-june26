package com.rork.vinetrack.data.resistance

/**
 * The versioned, data-driven representation of a published resistance-management
 * strategy.
 *
 * Everything in this file is deliberately free of any published number. The
 * numbers live in [ResistanceRulesets], which encodes a specific dated strategy
 * from a specific issuing body. That separation is the whole point: CropLife
 * Australia reissues its strategies every year, and a 2027 revision must be
 * introducible as new DATA rather than as a rewrite of the evaluation
 * architecture.
 *
 * Mirrors iOS `ResistanceRuleset.swift`.
 */

// ---------------------------------------------------------------------------
// Jurisdiction / crop / disease
// ---------------------------------------------------------------------------

/**
 * The regulatory/agronomic jurisdiction whose resistance strategy applies.
 *
 * Resolved from the VINEYARD's stored country, never from the phone locale — an
 * Australian operator can legitimately manage a New Zealand vineyard, and the
 * Australian maximum-use rules must not follow the phone across the Tasman.
 */
enum class ResistanceJurisdiction(val raw: String, val label: String) {
    AUSTRALIA("AU", "Australia"),
    NEW_ZEALAND("NZ", "New Zealand"),

    /** Country absent or not recognised. Never receives a strategy by default. */
    UNKNOWN("unknown", "Unknown"),
    ;

    companion object {
        /** Maps a stored vineyard country value onto a jurisdiction. */
        fun fromCountryCode(code: String?): ResistanceJurisdiction {
            val trimmed = code?.trim()?.uppercase().orEmpty()
            if (trimmed.isEmpty()) return UNKNOWN
            return when (trimmed) {
                "AU", "AUS", "AUSTRALIA" -> AUSTRALIA
                "NZ", "NZL", "NEW ZEALAND", "AOTEAROA" -> NEW_ZEALAND
                else -> UNKNOWN
            }
        }
    }
}

/** The crop a strategy is written for. */
enum class ResistanceCrop(val raw: String, val label: String) {
    GRAPE("grape", "Grape"),
}

/**
 * A disease that carries its own resistance strategy and therefore its own
 * independent application history.
 *
 * [sprayTargetRaw] ties the disease to the persisted `spray_records.targets`
 * vocabulary (sql/193) so disease attribution comes from what the operator
 * declared the spray was FOR — never from the chemistry in the tank.
 */
enum class ResistanceDisease(
    val raw: String,
    val label: String,
    val sprayTargetRaw: String,
) {
    POWDERY_MILDEW("powdery_mildew", "Powdery Mildew", "powdery_mildew"),
    DOWNY_MILDEW("downy_mildew", "Downy Mildew", "downy_mildew"),
    ;

    companion object {
        fun fromSprayTargetRaw(raw: String?): ResistanceDisease? {
            val trimmed = raw?.trim()?.lowercase() ?: return null
            return entries.firstOrNull { it.sprayTargetRaw == trimmed }
        }
    }
}

// ---------------------------------------------------------------------------
// Group codes and signatures
// ---------------------------------------------------------------------------

/**
 * Canonicalisation for FRAC activity group codes.
 *
 * Free-text group codes reach this engine from Chemical Intelligence, where they
 * are deliberately not constrained to a hard-coded list. Here they must be
 * comparable, so `"Group 11"`, `"frac 11"` and `"11"` have to collapse onto one
 * key without inventing groups that were never recorded.
 */
object ResistanceGroupCode {
    /**
     * FRAC renumbered several legacy "U" codes. CropLife still prints the legacy
     * code alongside the number (`"Group 50 (U8)"`), and product labels use
     * either, so both must resolve to one key or a rotation looks compliant
     * purely because two spellings never met.
     */
    private val aliases: Map<String, String> = mapOf("U8" to "50")

    /** Returns the canonical code, or null when nothing usable was recorded. */
    fun normalize(raw: String?): String? {
        var text = raw?.trim()?.uppercase() ?: return null
        if (text.isEmpty()) return null
        listOf("FRAC", "GROUP", "HRAC", "IRAC").forEach { prefix ->
            if (text.startsWith(prefix)) text = text.removePrefix(prefix).trim()
        }
        text = text.trim().trimStart(':').trim()
        // "50 (U8)" -> "50"
        val parenthesised = Regex("^([0-9A-Z]+)\\s*\\(").find(text)
        if (parenthesised != null) text = parenthesised.groupValues[1]
        if (text.isEmpty()) return null
        return aliases[text] ?: text
    }

    /**
     * Numeric groups ascending, then alphanumeric codes (`U6`) after them, so a
     * signature's key is stable regardless of the order products were recorded.
     */
    val comparator: Comparator<String> = Comparator { lhs, rhs ->
        val left = lhs.toIntOrNull()
        val right = rhs.toIntOrNull()
        when {
            left != null && right != null -> left.compareTo(right)
            left != null -> -1
            right != null -> 1
            else -> lhs.compareTo(rhs)
        }
    }
}

/**
 * The set of activity groups carried by ONE product.
 *
 * A co-formulated product with two actives has a signature of two codes. That
 * matters because CropLife gives certain co-formulations their own rule — Group
 * `5+3` is restricted differently from Group 5 and Group 3 — so the engine needs
 * to know not just WHICH groups were applied but which of them arrived in the
 * same product.
 */
data class ResistanceGroupSignature(val codes: List<String>) {
    /** Canonical key, e.g. `"3+11"`. Always ascending, never display order. */
    val key: String get() = codes.joinToString("+")

    val isCoformulation: Boolean get() = codes.size > 1

    fun contains(code: String): Boolean = codes.contains(code)

    companion object {
        val empty = ResistanceGroupSignature(emptyList())

        fun of(raw: Collection<String>): ResistanceGroupSignature =
            ResistanceGroupSignature(
                raw.mapNotNull { ResistanceGroupCode.normalize(it) }
                    .distinct()
                    .sortedWith(ResistanceGroupCode.comparator),
            )

        fun of(vararg raw: String): ResistanceGroupSignature = of(raw.toList())
    }
}

// ---------------------------------------------------------------------------
// Selectors
// ---------------------------------------------------------------------------

/**
 * What an application must contain for a rule to count it.
 *
 * Published strategies address groups in several distinct shapes, and flattening
 * them loses meaning:
 *
 * - `"Group 11 (inc. 11 + 3)"` — any application containing group 11, however it
 *   arrived. [ContainsGroup].
 * - `"Group 5+3"` — specifically the co-formulated product. [Coformulation].
 * - `"Group 5+3, 7+12"` — one shared table column covering two co-formulations.
 *   [AnyCoformulation].
 * - `"Group 3, 5, 13, 19, 21, 50 (U8) and U6"` — one sentence, many groups, each
 *   of which needs its own stable rule ID, so this expands to separate rules
 *   rather than one [AnyGroup] rule.
 */
sealed interface ResistanceGroupSelector {
    /** Group codes this selector is about, for result reporting. */
    val describedGroups: List<String>

    /** Stable text used in the ruleset fingerprint. */
    val fingerprint: String

    fun matches(event: ResistanceApplicationEvent): Boolean

    /**
     * Any application containing [code] as a component group, whether applied
     * solo, co-formulated or tank-mixed.
     */
    data class ContainsGroup(val code: String) : ResistanceGroupSelector {
        override val describedGroups: List<String> get() = listOf(code)
        override val fingerprint: String get() = "contains:$code"
        override fun matches(event: ResistanceApplicationEvent): Boolean =
            event.componentGroups.contains(code)
    }

    /** Specifically a single product co-formulated with exactly [signature]. */
    data class Coformulation(val signature: ResistanceGroupSignature) : ResistanceGroupSelector {
        override val describedGroups: List<String> get() = signature.codes
        override val fingerprint: String get() = "coformulation:${signature.key}"
        override fun matches(event: ResistanceApplicationEvent): Boolean =
            event.coformulationSignatures.any { it.key == signature.key }
    }

    /** Any of several co-formulations — a shared maximum-use table column. */
    data class AnyCoformulation(
        val signatures: List<ResistanceGroupSignature>,
    ) : ResistanceGroupSelector {
        override val describedGroups: List<String>
            get() = signatures.flatMap { it.codes }.distinct().sortedWith(ResistanceGroupCode.comparator)
        override val fingerprint: String
            get() = "anyCoformulation:" + signatures.map { it.key }.sorted().joinToString(",")
        override fun matches(event: ResistanceApplicationEvent): Boolean =
            event.coformulationSignatures.any { candidate ->
                signatures.any { it.key == candidate.key }
            }
    }

    /** Any application containing at least one of [codes]. */
    data class AnyGroup(val codes: List<String>) : ResistanceGroupSelector {
        override val describedGroups: List<String> get() = codes
        override val fingerprint: String get() = "anyGroup:" + codes.sorted().joinToString(",")
        override fun matches(event: ResistanceApplicationEvent): Boolean =
            codes.any { event.componentGroups.contains(it) }
    }
}

// ---------------------------------------------------------------------------
// Rule kinds
// ---------------------------------------------------------------------------

/**
 * The kinds of restriction a published strategy can express.
 *
 * Deliberately a closed set of DATA-shaped cases rather than code branches, so a
 * new strategy revision changes numbers and rule lists, not the engine.
 */
sealed interface ResistanceRuleKind {
    val fingerprint: String

    /** "Do not apply more than N consecutive sprays of ...". */
    data class MaxConsecutiveApplications(val limit: Int) : ResistanceRuleKind {
        override val fingerprint: String get() = "maxConsecutive:$limit"
    }

    /**
     * "Do not apply Group 11 consecutively." Semantically
     * [MaxConsecutiveApplications] with a limit of 1, kept distinct because the
     * published sentence is a prohibition rather than a ceiling and the operator
     * wording differs.
     */
    data object NoConsecutiveApplications : ResistanceRuleKind {
        override val fingerprint: String get() = "noConsecutive"
    }

    /** "Apply a maximum of N sprays per season of ...". */
    data class MaxApplicationsPerSeason(val limit: Int) : ResistanceRuleKind {
        override val fingerprint: String get() = "maxPerSeason:$limit"
    }

    /**
     * "Do not apply more than N ... per crop." Distinct from per-season because
     * CropLife uses "per crop" for the Powdery Group 21 ceiling; for an annual
     * grape crop cycle it resolves to the same window, and naming it separately
     * keeps the published wording traceable.
     */
    data class MaxApplicationsPerCrop(val limit: Int) : ResistanceRuleKind {
        override val fingerprint: String get() = "maxPerCrop:$limit"
    }

    /**
     * "... a maximum of 33% of total applications."
     *
     * Held as an exact rational, never a rounded percentage, so 2-of-6 compares
     * as 2×3 ≤ 6×1 rather than as 33.33% ≤ 33%.
     */
    data class MaxFractionOfDiseaseSprays(
        val numerator: Int,
        val denominator: Int,
    ) : ResistanceRuleKind {
        override val fingerprint: String get() = "maxFraction:$numerator/$denominator"
    }

    /**
     * "Only apply ... a maximum of one in every three sprays."
     *
     * NOT the same as a 33% cap: this is a spacing rule. 2 of 6 sprays satisfies
     * 33% but violates one-in-three if both fall inside the same window of
     * three.
     */
    data class MaxOneInEveryNSprays(val window: Int) : ResistanceRuleKind {
        override val fingerprint: String get() = "oneInEvery:$window"
    }

    /**
     * "... must be followed by at least N applications of a different group(s)
     * before being reapplied."
     */
    data class MinInterveningDifferentGroupApplications(val count: Int) : ResistanceRuleKind {
        override val fingerprint: String get() = "minIntervening:$count"
    }

    /**
     * "Always apply ... in mixtures" / "only in mixtures with effective
     * fungicides applied at an effective rate from a different cross resistance
     * group."
     */
    data object MixtureRequired : ResistanceRuleKind {
        override val fingerprint: String get() = "mixtureRequired"
    }

    /**
     * A mixture is required only when the application is consecutive with
     * another application of the same selector — CropLife's medium-to-high-risk
     * handling for Powdery Groups 7 and 11.
     */
    data object MixtureRequiredWhenConsecutive : ResistanceRuleKind {
        override val fingerprint: String get() = "mixtureRequiredWhenConsecutive"
    }

    /**
     * "Max. number of solo sprays: 2" — a ceiling that applies only to
     * applications carrying no alternative mode of action, distinct from the
     * higher ceiling permitted when the group is mixed.
     */
    data class MaxSoloApplicationsPerSeason(val limit: Int) : ResistanceRuleKind {
        override val fingerprint: String get() = "maxSoloPerSeason:$limit"
    }

    /** "Do not apply a spray containing Group 40 as the last spray of the season." */
    data object NotLastSprayOfSeason : ResistanceRuleKind {
        override val fingerprint: String get() = "notLastSprayOfSeason"
    }

    /**
     * The maximum varies with how many sprays target the disease in total —
     * CropLife's Powdery table. [columnKey] indexes [ResistanceMaxUseTable].
     */
    data class MaxFromTotalSprayCountTable(val columnKey: String) : ResistanceRuleKind {
        override val fingerprint: String get() = "maxFromTable:$columnKey"
    }

    /** Non-numeric published guidance, e.g. "apply all these preventatively". */
    data object PreventativeApplicationGuidance : ResistanceRuleKind {
        override val fingerprint: String get() = "preventativeGuidance"
    }
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

/**
 * One published restriction, addressable by a stable ID.
 *
 * [id] must survive rewording. It ends up stored in plans and warnings, so a
 * later editorial change to [sourceText] must not orphan them.
 */
data class ResistanceRule(
    val id: String,
    val selector: ResistanceGroupSelector,
    val kind: ResistanceRuleKind,
    /** Which published clause this came from, e.g. `"Guideline 4"`. */
    val sourceReference: String,
    /** The published sentence, verbatim, so a warning can always be justified. */
    val sourceText: String,
    /**
     * Whether the sequence for this rule continues across the season boundary.
     *
     * CropLife's Powdery strategy states that consecutive applications include
     * from the end of one season to the start of the next, so a run of two at the
     * end of last season plus one now is a run of three.
     */
    val crossSeason: Boolean = false,
) {
    val fingerprint: String
        get() = "$id|${selector.fingerprint}|${kind.fingerprint}|crossSeason=$crossSeason|$sourceReference"
}

// ---------------------------------------------------------------------------
// Maximum-use table
// ---------------------------------------------------------------------------

/** One column of a maximum-use table — a group or group set with its own ceiling. */
data class ResistanceMaxUseColumn(
    val key: String,
    val displayName: String,
    val selector: ResistanceGroupSelector,
)

/**
 * One row: the ceiling for every column at a given total spray count.
 *
 * [isOrMore] marks the open-ended final row (CropLife's `9+`).
 */
data class ResistanceMaxUseRow(
    val totalSprays: Int,
    val isOrMore: Boolean,
    val maxByColumn: Map<String, Int>,
)

/**
 * A published table relating the total number of disease-targeting sprays to the
 * maximum permitted applications of each group.
 *
 * Never flattened to a single maximum per group: at 3 total Powdery sprays Group
 * 3 allows 2, and at 9 it allows 3. A flattened "3" would licence a rotation the
 * strategy forbids in a short season.
 */
data class ResistanceMaxUseTable(
    val id: String,
    val rowKeyLabel: String,
    val columns: List<ResistanceMaxUseColumn>,
    val rows: List<ResistanceMaxUseRow>,
    val sourceReference: String,
    val notes: List<String> = emptyList(),
) {
    fun column(key: String): ResistanceMaxUseColumn? = columns.firstOrNull { it.key == key }

    /**
     * The ceiling for [columnKey] when [totalSprays] target the disease, or null
     * when the table cannot speak to that total.
     *
     * Below the first row the table is silent; a total of 0 has no ceiling to
     * breach. At or above the open-ended row, that row governs.
     */
    fun maxFor(columnKey: String, totalSprays: Int): Int? {
        if (totalSprays <= 0) return null
        val exact = rows.firstOrNull { !it.isOrMore && it.totalSprays == totalSprays }
        if (exact != null) return exact.maxByColumn[columnKey]
        val openEnded = rows.firstOrNull { it.isOrMore }
        if (openEnded != null && totalSprays >= openEnded.totalSprays) {
            return openEnded.maxByColumn[columnKey]
        }
        // Totals below the smallest published row: fall back to that row.
        val smallest = rows.minByOrNull { it.totalSprays }
        if (smallest != null && totalSprays < smallest.totalSprays) {
            return smallest.maxByColumn[columnKey]
        }
        return null
    }

    val fingerprint: String
        get() = buildString {
            append(id).append('|').append(rowKeyLabel).append('|')
            columns.sortedBy { it.key }.forEach {
                append(it.key).append('=').append(it.selector.fingerprint).append(';')
            }
            append('|')
            rows.sortedBy { it.totalSprays }.forEach { row ->
                append(row.totalSprays).append(if (row.isOrMore) "+" else "").append(':')
                row.maxByColumn.keys.sorted().forEach { key ->
                    append(key).append('=').append(row.maxByColumn[key]).append(',')
                }
                append(';')
            }
        }
}

// ---------------------------------------------------------------------------
// Group listing
// ---------------------------------------------------------------------------

/** A group the strategy covers, with the chemistry name the source prints. */
data class ResistanceGroupListing(
    val displayName: String,
    val signature: ResistanceGroupSignature,
    val modeOfActionName: String,
)

// ---------------------------------------------------------------------------
// Ruleset
// ---------------------------------------------------------------------------

/**
 * A complete, dated, attributable strategy for one jurisdiction/crop/disease.
 *
 * The evaluation result records the ruleset that produced it. A warning that
 * cannot name its strategy and its date is not auditable, and resistance advice
 * that cannot be audited cannot be defended to a grower.
 */
data class ResistanceRuleset(
    val id: String,
    val jurisdiction: ResistanceJurisdiction,
    val crop: ResistanceCrop,
    val disease: ResistanceDisease,
    val strategyName: String,
    val sourceOrganisation: String,
    /** Canonical public location of the strategy. */
    val sourceReference: String,
    /** ISO date the published advice is valid as at, e.g. `"2026-07-22"`. */
    val validFrom: String,
    val validFromEpochMs: Long,
    val rulesetVersion: String,
    val rules: List<ResistanceRule>,
    val groups: List<ResistanceGroupListing>,
    val maxUseTable: ResistanceMaxUseTable? = null,
    /** ID of the ruleset that replaced this one; null while current. */
    val supersededBy: String? = null,
    /** ID of the ruleset this one replaced. */
    val supersedes: String? = null,
    /**
     * Ambiguities and judgement calls in the published source, recorded so they
     * are visible to whoever maintains the next revision.
     */
    val sourceNotes: List<String> = emptyList(),
) {
    val isSuperseded: Boolean get() = supersededBy != null

    fun rule(id: String): ResistanceRule? = rules.firstOrNull { it.id == id }

    /**
     * Order-independent digest of every rule, threshold and table cell.
     *
     * Exists so the iOS and Android encodings of the same strategy can be
     * asserted identical. Two platforms that each "look right" in isolation is
     * precisely how the Android Powdery table and the iOS Powdery table drift
     * apart, and a rotation that is compliant on one phone and exceeded on the
     * other destroys trust in both.
     *
     * FNV-1a rather than a platform digest API, so the arithmetic is guaranteed
     * identical on both platforms with no dependency.
     */
    fun fingerprint(): String {
        val canonical = buildString {
            append(id).append('\n')
            append(jurisdiction.raw).append('\n')
            append(crop.raw).append('\n')
            append(disease.raw).append('\n')
            append(strategyName).append('\n')
            append(sourceOrganisation).append('\n')
            append(validFrom).append('\n')
            append(rulesetVersion).append('\n')
            append(supersededBy ?: "-").append('\n')
            append(supersedes ?: "-").append('\n')
            groups.map { "${it.displayName}=${it.signature.key}" }.sorted()
                .forEach { append(it).append('\n') }
            rules.map { it.fingerprint }.sorted().forEach { append(it).append('\n') }
            append(maxUseTable?.fingerprint ?: "-").append('\n')
        }
        return fnv1a64Hex(canonical)
    }

    companion object {
        /** 64-bit FNV-1a over UTF-16 code units, lower-case hex. */
        fun fnv1a64Hex(text: String): String {
            var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
            val prime = 0x100000001b3L
            for (char in text) {
                hash = hash xor char.code.toLong()
                hash *= prime
            }
            return java.lang.Long.toHexString(hash).padStart(16, '0')
        }
    }
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/**
 * Holds every known ruleset — current and historical — and answers which one
 * governs a given evaluation.
 *
 * Superseded rulesets are retained rather than deleted so a 2026 spray can still
 * be explained by the strategy that was actually in force when it was applied.
 */
class ResistanceRulesetRegistry(val rulesets: List<ResistanceRuleset>) {

    /** The current (non-superseded) ruleset for this jurisdiction/crop/disease. */
    fun current(
        jurisdiction: ResistanceJurisdiction,
        crop: ResistanceCrop,
        disease: ResistanceDisease,
    ): ResistanceRuleset? = rulesets
        .filter { it.jurisdiction == jurisdiction && it.crop == crop && it.disease == disease && !it.isSuperseded }
        .maxByOrNull { it.validFromEpochMs }

    /**
     * The ruleset that was in force at [atEpochMs] — for reconstructing why a
     * historical spray was assessed the way it was.
     *
     * Not used by v1 planning, which always asks for [current]; the contract
     * exists now so future reporting does not require an engine change.
     */
    fun inForce(
        jurisdiction: ResistanceJurisdiction,
        crop: ResistanceCrop,
        disease: ResistanceDisease,
        atEpochMs: Long,
    ): ResistanceRuleset? = rulesets
        .filter {
            it.jurisdiction == jurisdiction && it.crop == crop && it.disease == disease &&
                it.validFromEpochMs <= atEpochMs
        }
        .maxByOrNull { it.validFromEpochMs }

    fun byId(id: String): ResistanceRuleset? = rulesets.firstOrNull { it.id == id }
}
