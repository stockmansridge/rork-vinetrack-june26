package com.rork.vinetrack.data.chemical

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Where a piece of chemical information came from, ranked by how much weight it
 * may carry.
 *
 * The ordering IS the source hierarchy: an official register outranks a
 * manufacturer label, which outranks an authoritative activity-group
 * classification for identity purposes, and AI/search interpretation sits at the
 * bottom. [AUTHORITATIVE_CLASSIFICATION] is the highest authority for the
 * activity group specifically — that is the one thing FRAC/HRAC/IRAC define.
 */
@Serializable
enum class ChemicalDataSourceKind(val raw: String, val label: String) {
    /** A national regulator's registered-product record: APVMA (AU), ACVM/EPA (NZ). */
    @SerialName("official_register")
    OFFICIAL_REGISTER("official_register", "Official register"),

    /** The registrant's own approved label document. */
    @SerialName("manufacturer_label")
    MANUFACTURER_LABEL("manufacturer_label", "Product label"),

    /** FRAC / HRAC / IRAC classification. Authoritative for activity group and nothing else. */
    @SerialName("authoritative_classification")
    AUTHORITATIVE_CLASSIFICATION("authoritative_classification", "Activity group classification"),

    /** An industry spray guide used to cross-check that a product is used on grapes. */
    @SerialName("viticulture_reference")
    VITICULTURE_REFERENCE("viticulture_reference", "Viticulture reference"),

    /**
     * A language model's reading of search results. Useful for FINDING a
     * candidate; never sufficient on its own to call anything Verified.
     */
    @SerialName("ai_interpretation")
    AI_INTERPRETATION("ai_interpretation", "AI/search interpretation"),

    @SerialName("manual_entry")
    MANUAL_ENTRY("manual_entry", "Manually entered"),

    /** Read out of a pre-Chemical-Intelligence free-text field. */
    @SerialName("legacy_record")
    LEGACY_RECORD("legacy_record", "Existing VineTrack record"),
    ;

    /**
     * Whether this source can, by itself, support a Verified claim.
     *
     * This single property is what stops AI confidence from being laundered into
     * authority.
     */
    val isAuthoritative: Boolean
        get() = when (this) {
            OFFICIAL_REGISTER, MANUFACTURER_LABEL, AUTHORITATIVE_CLASSIFICATION -> true
            VITICULTURE_REFERENCE, AI_INTERPRETATION, MANUAL_ENTRY, LEGACY_RECORD -> false
        }

    /**
     * Whether this source is the record telling us about itself rather than
     * anything outside VineTrack having been consulted.
     *
     * A manually typed value and a value read out of an old free-text column are
     * both statements by the operator's own installation. Neither is proof of
     * anything, which is why a hand-entered registration number cannot make a
     * product's identity authoritative.
     */
    val isSelfReported: Boolean get() = this == MANUAL_ENTRY || this == LEGACY_RECORD

    /** Higher wins when two sources disagree about the same field. */
    val precedence: Int
        get() = when (this) {
            OFFICIAL_REGISTER -> 100
            MANUFACTURER_LABEL -> 90
            AUTHORITATIVE_CLASSIFICATION -> 80
            VITICULTURE_REFERENCE -> 50
            AI_INTERPRETATION -> 20
            MANUAL_ENTRY -> 15
            LEGACY_RECORD -> 10
        }

    companion object {
        /**
         * An unknown source kind from a newer build must never be READ AS
         * authoritative. Falling back to AI interpretation is the safe
         * direction: it can only lower a verification claim, never raise one.
         */
        fun from(raw: String?): ChemicalDataSourceKind? {
            val v = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            return entries.firstOrNull { it.raw == v } ?: AI_INTERPRETATION
        }
    }
}

/** One cited source behind a chemical's information. */
@Serializable
data class ChemicalDataSource(
    val kind: ChemicalDataSourceKind = ChemicalDataSourceKind.AI_INTERPRETATION,
    /** e.g. `"APVMA PUBCRIS"`, `"FRAC Code List 2025"`. */
    val name: String = "",
    /** URL or document identifier, where one exists. */
    val reference: String? = null,
    @SerialName("retrieved_at") val retrievedAt: String? = null,
) {
    val id: String get() = "${kind.raw}|$name|${reference.orEmpty()}"
}

/** Whether any cited source can support a Verified claim. */
fun List<ChemicalDataSource>.containsAuthoritative(): Boolean = any { it.kind.isAuthoritative }

/** The strongest source cited. */
fun List<ChemicalDataSource>.strongest(): ChemicalDataSource? = maxByOrNull { it.kind.precedence }

/**
 * How much VineTrack trusts a chemical's resistance-critical information.
 *
 * Deliberately separate from "did the lookup return anything". An AI answer is a
 * lead, not a verification: a product only becomes [VERIFIED] when an
 * authoritative source stands behind its identity AND behind every active's
 * activity group.
 */
@Serializable
enum class ChemicalVerificationStatus(val raw: String, val label: String) {
    @SerialName("verified")
    VERIFIED("verified", "Verified"),

    @SerialName("partially_verified")
    PARTIALLY_VERIFIED("partially_verified", "Partially verified"),

    @SerialName("unverified")
    UNVERIFIED("unverified", "Unverified"),

    /**
     * A legacy record that has never been put through the match step. It has
     * data, but nobody has yet confirmed WHICH registered product it is.
     */
    @SerialName("needs_match")
    NEEDS_MATCH("needs_match", "Needs match"),

    /** Sources disagree. Never silently resolved — a human decides. */
    @SerialName("conflict")
    CONFLICT("conflict", "Verification conflict"),
    ;

    val detail: String
        get() = when (this) {
            VERIFIED -> "Product identity and activity groups confirmed against authoritative sources."
            PARTIALLY_VERIFIED -> "Product identified, but some resistance information is still unconfirmed."
            UNVERIFIED -> "Entered manually or carried over from an older record. Not confirmed against a label."
            NEEDS_MATCH -> "Not yet matched to a registered product for this country."
            CONFLICT -> "Sources disagree. Resolve before relying on this product's resistance information."
        }

    /**
     * Whether the future Resistance Engine may treat this product's groups as
     * dependable without warning the operator.
     */
    val isResistanceDependable: Boolean get() = this == VERIFIED

    /** Ranking used when merging: a merge may only ever LOWER confidence. */
    val confidenceRank: Int
        get() = when (this) {
            VERIFIED -> 4
            PARTIALLY_VERIFIED -> 3
            NEEDS_MATCH -> 2
            UNVERIFIED -> 1
            CONFLICT -> 0
        }

    companion object {
        /** An unknown status degrades to unverified — the only safe direction. */
        fun from(raw: String?): ChemicalVerificationStatus {
            val v = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return UNVERIFIED
            return entries.firstOrNull { it.raw == v } ?: UNVERIFIED
        }
    }
}

/**
 * A specific disagreement between two sources about one field.
 *
 * Surfaced to the operator verbatim — VineTrack does not pick a winner, and it
 * certainly does not quietly keep the AI's answer.
 */
@Serializable
data class ChemicalVerificationConflict(
    /** Which field disagrees, e.g. `"activity_group"`, `"concentration"`. */
    val field: String = "",
    @SerialName("active_ingredient_name") val activeIngredientName: String? = null,
    /** What the label/AI extraction claimed. */
    @SerialName("extracted_value") val extractedValue: String = "",
    /** What the authoritative classification says. */
    @SerialName("authoritative_value") val authoritativeValue: String = "",
    @SerialName("extracted_source")
    val extractedSource: ChemicalDataSourceKind = ChemicalDataSourceKind.AI_INTERPRETATION,
    @SerialName("authoritative_source")
    val authoritativeSource: ChemicalDataSourceKind = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
) {
    // `this.field` is deliberate: inside a property accessor a bare `field` is
    // the backing-field keyword, not this class's `field` property.
    val id: String
        get() = "${this.field}|${activeIngredientName.orEmpty()}|$extractedValue|$authoritativeValue"

    /** One-line operator-facing summary. */
    val summary: String
        get() {
            val subject = activeIngredientName?.let { "$it: " } ?: ""
            return "$subject${extractedSource.label} says $extractedValue; " +
                "${authoritativeSource.label} says $authoritativeValue."
        }
}

/** The full verification picture for one chemical. */
@Serializable
data class ChemicalVerification(
    /**
     * The stored status. Prefer [resolvedStatus] when deciding what to trust —
     * it re-derives the claim from the evidence rather than believing a status
     * somebody wrote down.
     */
    val status: ChemicalVerificationStatus = ChemicalVerificationStatus.UNVERIFIED,
    val sources: List<ChemicalDataSource> = emptyList(),
    @SerialName("verified_at") val verifiedAt: String? = null,
    /** Unresolved disagreements. Non-empty forces [ChemicalVerificationStatus.CONFLICT]. */
    val conflicts: List<ChemicalVerificationConflict> = emptyList(),
    /**
     * Fields the lookup explicitly could not resolve, named so the UI can show
     * what is missing instead of an unexplained blank.
     */
    @SerialName("unresolved_fields") val unresolvedFields: List<String> = emptyList(),
) {
    /**
     * The status the EVIDENCE supports, which may be lower than [status].
     *
     * This is the gate that makes source-disagreement handling structural rather
     * than advisory: a record can carry `VERIFIED`, but if a conflict is present
     * or an active's group is unconfirmed, this returns `CONFLICT` or
     * `PARTIALLY_VERIFIED` and the product is not treated as dependable.
     * Confidence can only ever be lowered here, never raised.
     */
    fun resolvedStatus(
        actives: List<ChemicalActiveIngredient>,
        hasRegistration: Boolean,
    ): ChemicalVerificationStatus {
        if (conflicts.isNotEmpty()) return ChemicalVerificationStatus.CONFLICT
        if (actives.isEmpty()) {
            return if (status == ChemicalVerificationStatus.NEEDS_MATCH) {
                ChemicalVerificationStatus.NEEDS_MATCH
            } else {
                ChemicalVerificationStatus.UNVERIFIED
            }
        }
        val everyGroupAuthoritative = actives.all { it.hasAuthoritativeGroup }

        if (status == ChemicalVerificationStatus.VERIFIED &&
            everyGroupAuthoritative &&
            hasRegistration &&
            sources.containsAuthoritative() &&
            unresolvedFields.isEmpty()
        ) {
            return ChemicalVerificationStatus.VERIFIED
        }

        // Partially verified means "we know WHICH product this is, but something
        // about it is still unconfirmed". It therefore requires real evidence:
        // an authoritative registered identity, an authoritative cited source, or
        // an active whose group an authoritative classification stands behind.
        //
        // Merely HAVING a group is not enough. A chemical someone typed by hand
        // has a group because they typed one, and that must stay Unverified —
        // otherwise manual entry quietly launders itself into partial trust.
        val hasAuthoritativeEvidence = hasRegistration ||
            sources.containsAuthoritative() ||
            actives.any { it.hasAuthoritativeGroup }

        if (hasAuthoritativeEvidence) {
            return if (status == ChemicalVerificationStatus.NEEDS_MATCH) {
                ChemicalVerificationStatus.NEEDS_MATCH
            } else {
                ChemicalVerificationStatus.PARTIALLY_VERIFIED
            }
        }
        return if (status == ChemicalVerificationStatus.NEEDS_MATCH) {
            ChemicalVerificationStatus.NEEDS_MATCH
        } else {
            ChemicalVerificationStatus.UNVERIFIED
        }
    }

    /** Records a disagreement and drops the status to conflict. */
    fun addingConflict(conflict: ChemicalVerificationConflict): ChemicalVerification =
        if (conflicts.contains(conflict)) this
        else copy(
            conflicts = conflicts + conflict,
            status = ChemicalVerificationStatus.CONFLICT,
        )

    companion object {
        /** Verification state for a chemical the operator typed in themselves. */
        fun manual(): ChemicalVerification = ChemicalVerification(
            status = ChemicalVerificationStatus.UNVERIFIED,
            sources = listOf(
                ChemicalDataSource(
                    kind = ChemicalDataSourceKind.MANUAL_ENTRY,
                    name = "Entered in VineTrack",
                ),
            ),
        )

        /**
         * Verification state for a pre-Chemical-Intelligence record. It is not
         * "unverified because it's wrong" — it simply has never been matched to a
         * registered product, and the audit needs to tell those apart.
         */
        fun legacy(): ChemicalVerification = ChemicalVerification(
            status = ChemicalVerificationStatus.NEEDS_MATCH,
            sources = listOf(
                ChemicalDataSource(
                    kind = ChemicalDataSourceKind.LEGACY_RECORD,
                    name = "Existing VineTrack chemical",
                ),
            ),
        )
    }
}
