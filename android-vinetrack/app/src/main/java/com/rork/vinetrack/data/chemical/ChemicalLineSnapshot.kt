package com.rork.vinetrack.data.chemical

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The resistance-relevant facts about a product AS THEY STOOD when a spray was
 * recorded.
 *
 * Historical resistance analysis must not depend on the current Chemical Store
 * record. If a saved chemical's classification is corrected in three years — or
 * the product is archived, or its actives are restructured — the spray from
 * today must still be able to say what VineTrack believed at the time it was
 * applied. Otherwise a corrected record silently rewrites years of spray
 * history, and every rotation calculated from it.
 *
 * Persisted additively inside the existing `tanks` JSONB on each chemical line,
 * so no relational churn and no migration are required for it. Mirrors the iOS
 * `ChemicalLineSnapshot` keys exactly.
 */
@Serializable
data class ChemicalLineSnapshot(
    @SerialName("active_ingredients")
    val activeIngredients: List<ChemicalActiveIngredient> = emptyList(),
    /**
     * Bare group codes, e.g. `["3", "11"]`, duplicated out of
     * [activeIngredients] so a reader never has to reconstruct them.
     */
    @SerialName("activity_groups") val activityGroupCodes: List<String> = emptyList(),
    /**
     * The trust level the product carried at application time. A spray recorded
     * against an unverified product stays visibly unverified in history even if
     * the product is verified later.
     */
    @SerialName("verification_status")
    val verificationStatus: ChemicalVerificationStatus = ChemicalVerificationStatus.UNVERIFIED,
    /** The registered identity used, e.g. `"AU:apvma:62764"`. */
    @SerialName("registration_identity_key") val registrationIdentityKey: String? = null,
    @SerialName("country_code") val countryCode: String? = null,
    /** `ChemicalIntelligence.schemaVersion` at the time. */
    @SerialName("schema_version") val schemaVersion: Int = 0,
    /** Which revision of the classification table made this call. */
    @SerialName("activity_group_table_version") val activityGroupTableVersion: Int = 0,
    /**
     * The legacy `chemical_group` string as it was DISPLAYED at the time. Kept
     * for faithful reproduction of an old record, never for calculation.
     */
    @SerialName("legacy_chemical_group") val legacyChemicalGroup: String? = null,
    @SerialName("captured_at") val capturedAt: String? = null,
) {
    /** Whether this snapshot carries anything the Resistance Engine could use. */
    val hasResistanceData: Boolean
        get() = activityGroupCodes.isNotEmpty() || activeIngredients.any { it.name.isNotEmpty() }

    companion object {
        /**
         * Freeze a saved chemical's current intelligence onto a spray line.
         *
         * Returns null when there is genuinely nothing structured to record, so
         * a legacy line stays honestly empty rather than carrying a snapshot
         * that implies knowledge VineTrack never had.
         */
        fun capture(
            intelligence: ChemicalIntelligence?,
            legacyChemicalGroup: String,
            capturedAt: String? = null,
        ): ChemicalLineSnapshot? {
            if (intelligence == null || intelligence.isEmpty) {
                // Nothing structured. Preserve only the displayed legacy string
                // if there was one, so the historical record still reproduces.
                val trimmed = legacyChemicalGroup.trim()
                if (trimmed.isEmpty()) return null
                return ChemicalLineSnapshot(
                    verificationStatus = ChemicalVerificationStatus.UNVERIFIED,
                    schemaVersion = 0,
                    activityGroupTableVersion = 0,
                    legacyChemicalGroup = trimmed,
                    capturedAt = capturedAt,
                )
            }
            return ChemicalLineSnapshot(
                activeIngredients = intelligence.activeIngredients,
                activityGroupCodes = intelligence.activityGroupCodes,
                // The RESOLVED status, not the stored one: a spray must never
                // claim its product was verified when the evidence said otherwise.
                verificationStatus = intelligence.resolvedVerificationStatus,
                registrationIdentityKey = intelligence.registration?.identityKey,
                countryCode = intelligence.registration?.countryCode,
                schemaVersion = intelligence.schemaVersion,
                activityGroupTableVersion = intelligence.activityGroupTableVersion,
                legacyChemicalGroup = legacyChemicalGroup.ifEmpty {
                    intelligence.legacyChemicalGroup
                },
                capturedAt = capturedAt,
            )
        }
    }
}
