package com.rork.vinetrack.data.spray

/**
 * A vineyard's spray calculation/compliance profile — the Kotlin twin of the
 * Swift `SprayComplianceProfile`.
 *
 * Governs how the grower is allowed to ENTER carrier volume. It says nothing
 * about product label rates — see [SprayProductRateBasis].
 */
enum class SprayComplianceProfile(val raw: String, val label: String) {
    /** Australia — hectare and row-length carrier volumes both acceptable. */
    AUSTRALIA("au", "Australia"),

    /**
     * New Zealand / VineTrack SWNZ — L/100 m is the only user-entered canopy
     * carrier-volume basis. L/ha is still derived and stored internally.
     */
    NEW_ZEALAND_SWNZ("nz_swnz", "New Zealand (SWNZ)"),
    ;

    companion object {
        fun from(raw: String?): SprayComplianceProfile? =
            entries.firstOrNull { it.raw == raw?.trim()?.lowercase() }
    }
}

/** Which carrier-volume bases a vineyard may enter. */
enum class SprayCarrierVolumePolicy(val raw: String) {
    LITRES_PER_HECTARE_ONLY("l_per_ha"),
    LITRES_PER_100_METRES_ONLY("l_per_100m"),
    EITHER("either"),
    ;

    fun allows(basis: SprayCarrierBasis): Boolean = when (this) {
        EITHER -> true
        LITRES_PER_HECTARE_ONLY -> basis == SprayCarrierBasis.LITRES_PER_HECTARE
        LITRES_PER_100_METRES_ONLY -> basis == SprayCarrierBasis.LITRES_PER_100_METRES
    }

    /** The basis to present by default under this policy. */
    val defaultBasis: SprayCarrierBasis
        get() = if (this == LITRES_PER_100_METRES_ONLY) {
            SprayCarrierBasis.LITRES_PER_100_METRES
        } else {
            SprayCarrierBasis.LITRES_PER_HECTARE
        }

    companion object {
        fun from(raw: String?): SprayCarrierVolumePolicy? =
            entries.firstOrNull { it.raw == raw?.trim()?.lowercase() }
    }
}

/**
 * The vineyard-level spray profile as stored (both fields nullable) plus the
 * rules for resolving an unset profile.
 *
 * Resolution NEVER writes anything: an unset vineyard keeps NULL in the database
 * and simply presents a country-appropriate default, so no existing vineyard
 * silently acquires a compliance profile it did not choose.
 */
data class SprayVineyardProfile(
    /** Stored `vineyards.spray_compliance_profile`, or null when never set. */
    val storedProfile: SprayComplianceProfile? = null,
    /** Stored `vineyards.spray_carrier_volume_basis`, or null when never set. */
    val storedPolicy: SprayCarrierVolumePolicy? = null,
    /** Existing `vineyards.country_code` (ISO-3166 alpha-2). */
    val countryCode: String? = null,
) {
    /** New Zealand vineyards default to the SWNZ profile; everyone else to AU. */
    val resolvedProfile: SprayComplianceProfile
        get() = storedProfile
            ?: if (countryCode?.trim()?.uppercase() == "NZ") {
                SprayComplianceProfile.NEW_ZEALAND_SWNZ
            } else {
                SprayComplianceProfile.AUSTRALIA
            }

    /**
     * An explicitly stored policy always wins. Otherwise the profile decides:
     * SWNZ restricts entry to L/100 m, Australia allows either.
     */
    val resolvedPolicy: SprayCarrierVolumePolicy
        get() = storedPolicy
            ?: if (resolvedProfile == SprayComplianceProfile.NEW_ZEALAND_SWNZ) {
                SprayCarrierVolumePolicy.LITRES_PER_100_METRES_ONLY
            } else {
                SprayCarrierVolumePolicy.EITHER
            }

    val defaultCarrierBasis: SprayCarrierBasis get() = resolvedPolicy.defaultBasis

    fun allows(basis: SprayCarrierBasis): Boolean = resolvedPolicy.allows(basis)

    /** True when the grower has no choice to make and the UI should not offer one. */
    val isCarrierBasisLocked: Boolean get() = resolvedPolicy != SprayCarrierVolumePolicy.EITHER
}
