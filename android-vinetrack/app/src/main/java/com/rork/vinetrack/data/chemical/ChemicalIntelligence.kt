package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.spray.SprayTarget
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The structured, verification-aware chemical record.
 *
 * This aggregate replaces the resistance-critical role of the free-text
 * `chemical_group` column. It answers, in machine-readable form:
 *
 * - What exact product is this?          → [registration]
 * - Which actives does it contain?       → [activeIngredients]
 * - At what concentration?               → each active's concentration
 * - Which activity group per active?     → each active's `activityGroup`
 * - What rate basis does the label use?  → [labelRateBases] / [registeredUses]
 * - Is any of this actually verified?    → [verification]
 *
 * Stored ALONGSIDE the legacy scalar columns, never instead of them, so old app
 * builds and the existing API keep working untouched while the structured model
 * becomes the authority. Mirrors the iOS `ChemicalIntelligence` exactly.
 */
@Serializable
data class ChemicalIntelligence(
    @SerialName("active_ingredients")
    val activeIngredients: List<ChemicalActiveIngredient> = emptyList(),
    val registration: ChemicalRegistration? = null,
    val verification: ChemicalVerification = ChemicalVerification(),
    @SerialName("registered_uses")
    val registeredUses: List<ChemicalRegisteredUse> = emptyList(),
    /** Aligned with the existing `product_category` vocabulary. */
    @SerialName("product_category") val productCategory: String = "",
    /** Version of [AuthoritativeActivityGroups] that judged this record. */
    @SerialName("activity_group_table_version") val activityGroupTableVersion: Int = 0,
    @SerialName("schema_version") val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
) {
    /**
     * Every activity group across every active, de-duplicated and ordered.
     *
     * A Tebuconazole + Azoxystrobin product returns FRAC 3 and FRAC 11 as two
     * separate members. This is the collection the Resistance Engine reads.
     */
    val activityGroups: List<ChemicalActivityGroup> get() = activeIngredients.activityGroups()

    /** Bare codes for the queryable `activity_groups text[]`: `["3", "11"]` — never `["3 + 11"]`. */
    val activityGroupCodes: List<String> get() = activityGroups.codes()

    /** Distinct label rate bases across all registered uses. */
    val labelRateBases: List<ChemicalLabelRateBasis> get() = registeredUses.rateBases()

    /**
     * The trust level the evidence actually supports.
     *
     * Always prefer this over `verification.status`: it re-derives the claim
     * from the actives, the registration and any conflicts, so a stale or
     * over-optimistic stored status cannot promote a product.
     */
    val resolvedVerificationStatus: ChemicalVerificationStatus
        get() = verification.resolvedStatus(
            actives = activeIngredients,
            hasRegistration = hasEvidencedRegistration,
        )

    /**
     * Whether this record's registered identity is backed by something other than
     * the operator's own typing.
     *
     * [ChemicalRegistration.isAuthoritativeIdentity] is a check on SHAPE: a
     * register, a number and a country. That shape is exactly what an operator
     * produces by typing an APVMA number into the manual editor, and on its own it
     * would promote a hand-entered product to Partially Verified, leaving the
     * record citing the operator as evidence for the operator's own claim.
     *
     * So the identity only counts once something outside this installation has
     * been consulted: either a cited source, or an active whose identity a
     * register established. A registration typed by hand is still stored, still
     * shown, and is still the strongest thing Match & Verify and Re-verify lead
     * with when they go looking. It simply is not treated as proof until one of
     * them comes back.
     *
     * The per-active [ChemicalActiveIngredient.identitySource] is consulted as well
     * as the cited sources because a manual edit to an active's GROUP legitimately
     * withdraws the record's authoritative citations while leaving the registered
     * identity itself untouched. That product is still identified; only its
     * chemistry became the operator's own claim.
     */
    val hasEvidencedRegistration: Boolean
        get() = registration?.isAuthoritativeIdentity == true &&
            (
                verification.sources.any { !it.kind.isSelfReported } ||
                    activeIngredients.any { it.identitySource?.isSelfReported == false }
                )

    /** Whether the future Resistance Engine may use these groups unqualified. */
    val isResistanceDependable: Boolean get() = resolvedVerificationStatus.isResistanceDependable

    /** Whether anything at all has been structured yet. */
    val isEmpty: Boolean
        get() = activeIngredients.isEmpty() && registration == null && registeredUses.isEmpty()

    /**
     * `"3 + 11"` — derived FROM [activityGroups] purely so older app builds and
     * the existing API keep rendering something familiar.
     *
     * Write it to the legacy column; never read it back for calculation.
     */
    val legacyChemicalGroup: String get() = activityGroups.legacyGroupProjection()

    /** `"Tebuconazole 200 g/L + Azoxystrobin 120 g/L"`. */
    val legacyActiveIngredient: String
        get() = activeIngredients.legacyActiveIngredientProjection()

    companion object {
        /**
         * Schema version of this payload. Stamped into spray snapshots so a
         * historical record says which contract produced it.
         */
        const val CURRENT_SCHEMA_VERSION: Int = 1

        /**
         * Builds a candidate record from a pre-Chemical-Intelligence chemical.
         *
         * Reads the old free-text fields to SEED the audit, and marks the result
         * `NEEDS_MATCH` with a `LEGACY_RECORD` source. Groups parsed out of a
         * typed string are candidates tagged `LEGACY_RECORD`, so they can never
         * satisfy `hasAuthoritativeGroup` and the product can never drift into
         * Verified without a human confirming it.
         *
         * Existing chemicals therefore keep loading and displaying exactly as
         * they did, while becoming visible to the audit as unmatched.
         */
        fun legacySeed(
            activeIngredientText: String,
            chemicalGroupText: String,
            modeOfActionText: String,
            productCategory: String,
            manufacturer: String,
            countryCode: String,
        ): ChemicalIntelligence {
            val scheme = ChemicalActivityGroupScheme.impliedByProductCategory(productCategory)
            // Mode of action ("11 (QoI / Strobilurin)") is usually a better
            // source of a code than the chemical group free-text, so try first.
            var candidates = ChemicalActivityGroup.parseLegacyText(modeOfActionText, scheme)
            if (candidates.isEmpty()) {
                candidates = ChemicalActivityGroup.parseLegacyText(chemicalGroupText, scheme)
            }

            val names = splitActiveNames(activeIngredientText)
            val actives: List<ChemicalActiveIngredient> = if (names.isEmpty()) {
                // No actives recorded at all: still surface the candidate groups
                // so the audit can see the product exists and needs matching.
                candidates.map { group ->
                    ChemicalActiveIngredient(
                        name = "",
                        activityGroup = group,
                        groupSource = ChemicalDataSourceKind.LEGACY_RECORD,
                        identitySource = ChemicalDataSourceKind.LEGACY_RECORD,
                    )
                }
            } else {
                names.mapIndexed { index, name ->
                    // Pair actives with candidate groups positionally ONLY when
                    // the counts line up exactly. A 2-active product with one
                    // parsed group tells us nothing about which active owns it,
                    // so we attach nothing rather than attach it to the wrong one.
                    val group = if (names.size == candidates.size) candidates[index] else null
                    ChemicalActiveIngredient(
                        name = name,
                        activityGroup = group,
                        groupSource = group?.let { ChemicalDataSourceKind.LEGACY_RECORD },
                        identitySource = ChemicalDataSourceKind.LEGACY_RECORD,
                    )
                }
            }

            val registration = if (countryCode.isBlank() && manufacturer.isBlank()) null
            else ChemicalRegistration.of(countryCode = countryCode, registrant = manufacturer)

            return ChemicalIntelligence(
                activeIngredients = actives,
                registration = registration,
                verification = ChemicalVerification.legacy(),
                registeredUses = emptyList(),
                productCategory = productCategory,
                activityGroupTableVersion = 0,
            )
        }

        /**
         * Splits a legacy free-text active ingredient field into candidate names.
         *
         * Concentrations are stripped from the name but deliberately NOT parsed
         * into `concentration`: a legacy string is not evidence of a label value.
         */
        fun splitActiveNames(raw: String): List<String> {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return emptyList()
            return trimmed.split('+', '&', ',', ';')
                .map { stripConcentration(it) }
                .filter { it.isNotEmpty() }
        }

        /** `"Tebuconazole 200 g/L"` → `"Tebuconazole"`. */
        private fun stripConcentration(raw: String): String {
            var value = raw.trim()
            val digit = value.indexOfFirst { it.isDigit() }
            if (digit > 0) {
                val prefix = value.substring(0, digit).trim()
                // Only cut when a real name precedes the number, so an active
                // whose name legitimately contains a digit ("2,4-D") survives.
                if (prefix.length >= 4) value = prefix
            }
            return value.trim().trim(' ', '-', '–', '—', '(', ')')
        }
    }
}

/**
 * The contract the future Resistance Rules Engine consumes.
 *
 * Deliberately a flat, self-contained projection: the engine never touches a
 * `SavedChemical`, never parses `"Group 3 + 11"`, and never reads label text. If
 * it can be answered from this class, the engine can answer it.
 */
@Serializable
data class ChemicalResistanceProfile(
    @SerialName("product_id") val productId: String,
    @SerialName("product_name") val productName: String,
    /** e.g. `"AU:apvma:62764"`. Null when the product has never been matched. */
    @SerialName("registration_identity_key") val registrationIdentityKey: String? = null,
    @SerialName("country_code") val countryCode: String = "",
    @SerialName("active_ingredients") val activeIngredients: List<ChemicalActiveIngredient> = emptyList(),
    @SerialName("activity_groups") val activityGroups: List<ChemicalActivityGroup> = emptyList(),
    @SerialName("verification_status")
    val verificationStatus: ChemicalVerificationStatus = ChemicalVerificationStatus.UNVERIFIED,
    @SerialName("registered_uses") val registeredUses: List<ChemicalRegisteredUse> = emptyList(),
    @SerialName("label_rate_bases") val labelRateBases: List<ChemicalLabelRateBasis> = emptyList(),
    /** `schemaVersion.activityGroupTableVersion`. */
    @SerialName("source_version") val sourceVersion: String = "0.0",
) {
    /** Bare codes: `["3", "11"]`. */
    val activityGroupCodes: List<String> get() = activityGroups.codes()

    /** Whether the engine may rely on these groups without qualification. */
    val isDependable: Boolean get() = verificationStatus.isResistanceDependable

    /** Typed targets the product is registered against on grapevines. */
    val viticulturalTargets: List<SprayTarget> get() = registeredUses.viticulturalTargets()
}
