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
    /**
     * Which Chemical Store record was frozen. Kept so history is
     * self-describing: a reader of the snapshot alone can say what it came
     * from. Never used to re-read today's record for chemistry.
     */
    @SerialName("saved_chemical_id") val savedChemicalId: String? = null,
    /**
     * The product name AS DISPLAYED at application time. Frozen separately from
     * the store record because a product can be renamed later.
     */
    @SerialName("product_name") val productName: String? = null,
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

    // ---- Applied rate provenance ----
    //
    // What was ACTUALLY poured, and where that number came from. Frozen for the
    // same reason as the chemistry above: a spray must stay readable after the
    // Chemical Store record moves on.
    //
    // This matters most for a confirmed BAND. If the store holds `2-3 L/100 L`
    // and the operator sprayed 2.5, the record has to say 2.5 — the range alone
    // cannot reconstruct it, and re-reading the store later would give a band
    // rather than the dose. Equally the store must keep saying `2-3`: the 2.5
    // belonged to one tank, not to the product.

    /** The dose actually applied on this line, in [appliedRateUnit]. */
    @SerialName("applied_rate") val appliedRate: Double? = null,
    /** The unit that dose was expressed in — never the pack unit. */
    @SerialName("applied_rate_unit") val appliedRateUnit: String? = null,
    /**
     * The basis the dose was quoted against (`per_hectare` / `per_100_litres`),
     * stored verbatim so no reader has to infer it, and never converted.
     */
    @SerialName("applied_rate_basis") val appliedRateBasis: String? = null,
    /**
     * Whether the rate this dose came from was a registered label direction
     * (`canonical`) or one the operator typed and confirmed (`manual`).
     *
     * Keeps the official/user-confirmed distinction alive in history: a record
     * must never later present a typed rate as label evidence.
     */
    @SerialName("rate_entry_method") val rateEntryMethod: String? = null,
    /** The confirmed band this dose was chosen inside, when there was one. */
    @SerialName("rate_range_min") val rateRangeMin: Double? = null,
    @SerialName("rate_range_max") val rateRangeMax: Double? = null,
) {
    /** Whether this snapshot carries anything the Resistance Engine could use. */
    val hasResistanceData: Boolean
        get() = activityGroupCodes.isNotEmpty() || activeIngredients.any { it.name.isNotEmpty() }

    /** True when the dose on this line came from a rate the operator typed. */
    val isUserEnteredRate: Boolean
        get() = rateEntryMethod?.trim() == StoredChemicalDefaultRate.ENTRY_MANUAL

    /**
     * Records what was actually applied, and where the rate came from.
     *
     * Returns a COPY: the saved chemical's own confirmed rate is never touched,
     * which is what keeps a stored `2-3 L/100 L` band intact after a spray goes
     * out at 2.5.
     */
    fun recordingApplied(
        rate: Double,
        unit: String,
        basis: ChemicalDefaultRateBasis,
        entryMethod: String,
        confirmedRange: ChemicalDefaultRateValidity.Amount.Range? = null,
    ): ChemicalLineSnapshot = copy(
        appliedRate = rate,
        appliedRateUnit = unit,
        appliedRateBasis = basis.raw,
        rateEntryMethod = entryMethod,
        rateRangeMin = confirmedRange?.min,
        rateRangeMax = confirmedRange?.max,
    )

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
            savedChemicalId: String? = null,
            productName: String? = null,
            capturedAt: String? = null,
        ): ChemicalLineSnapshot? {
            if (intelligence == null || intelligence.isEmpty) {
                // Nothing structured. Preserve only the displayed legacy string
                // if there was one, so the historical record still reproduces.
                val trimmed = legacyChemicalGroup.trim()
                if (trimmed.isEmpty()) return null
                return ChemicalLineSnapshot(
                    savedChemicalId = savedChemicalId,
                    productName = productName,
                    verificationStatus = ChemicalVerificationStatus.UNVERIFIED,
                    schemaVersion = 0,
                    activityGroupTableVersion = 0,
                    legacyChemicalGroup = trimmed,
                    capturedAt = capturedAt,
                )
            }
            return ChemicalLineSnapshot(
                savedChemicalId = savedChemicalId,
                productName = productName,
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
