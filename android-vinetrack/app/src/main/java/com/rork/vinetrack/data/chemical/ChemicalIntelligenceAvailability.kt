package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayTank
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Whether a recorded spray application's chemistry can be assessed at all, and
 * how far it can be trusted if so.
 *
 * This is the contract the future Resistance Rules Engine consumes. It exists as
 * its own type for one reason: a null `chemicalSnapshot` must never be read as
 * "no resistance issue". A large amount of legitimate VineTrack history predates
 * Chemical Intelligence and has no snapshot, and treating that silence as safety
 * would produce a green rotation report for a season nobody can actually account
 * for. The honest answer is "unable to fully assess this application", and that
 * answer needs a name in the domain.
 *
 * Mirrors iOS `ChemicalIntelligenceAvailability`.
 */
@Serializable
enum class ChemicalIntelligenceAvailability(val raw: String, val label: String) {
    /**
     * Groups are authoritatively classified and the product identity is
     * established. Usable without qualification.
     */
    @SerialName("available_verified")
    AVAILABLE_VERIFIED("available_verified", "Verified chemistry"),

    /**
     * The product is identified, but at least one resistance-relevant field is
     * unconfirmed. Usable, must be shown as partial.
     */
    @SerialName("available_partially_verified")
    AVAILABLE_PARTIALLY_VERIFIED("available_partially_verified", "Partially verified chemistry"),

    /**
     * Chemistry is recorded but rests on operator entry or a legacy record. The
     * engine may reason from it, and must say so.
     */
    @SerialName("available_unverified")
    AVAILABLE_UNVERIFIED("available_unverified", "Unverified chemistry"),

    /**
     * Sources disagreed about a resistance-critical field. Nothing here may be
     * relied on until a human resolves it.
     */
    @SerialName("conflict")
    CONFLICT("conflict", "Conflicting chemistry"),

    /** No usable chemistry was recorded for this application. NOT a pass. */
    @SerialName("unavailable")
    UNAVAILABLE("unavailable", "Chemical intelligence unavailable"),
    ;

    /**
     * Whether resistance analysis can reach ANY conclusion about this
     * application's chemistry.
     *
     * False obliges the caller to report "unable to fully assess" — never a clean
     * result.
     */
    val canAssess: Boolean
        get() = when (this) {
            AVAILABLE_VERIFIED, AVAILABLE_PARTIALLY_VERIFIED, AVAILABLE_UNVERIFIED -> true
            CONFLICT, UNAVAILABLE -> false
        }

    /** Whether the groups may be used without qualifying them to the operator. */
    val isDependable: Boolean get() = this == AVAILABLE_VERIFIED

    /** Whether a conclusion drawn from this application must carry a caveat. */
    val requiresQualification: Boolean get() = this != AVAILABLE_VERIFIED

    /**
     * Explicit, permanent guarantee that no availability state is ever a silent
     * pass.
     *
     * A future Resistance Engine asking "is this application fine?" gets false
     * from anything it cannot assess, forcing it to handle the unknown rather
     * than falling through to a default green.
     */
    val permitsCleanResult: Boolean get() = canAssess

    /** Operator-facing sentence for an application that cannot be assessed. */
    val assessmentCaveat: String?
        get() = when (this) {
            AVAILABLE_VERIFIED -> null
            AVAILABLE_PARTIALLY_VERIFIED ->
                "Some of this product's resistance information was unconfirmed when it was applied."
            AVAILABLE_UNVERIFIED ->
                "This product's activity groups were entered manually or carried over from an older record."
            CONFLICT ->
                "Sources disagreed about this product's resistance information when it was applied."
            UNAVAILABLE ->
                "No chemical intelligence was recorded for this application, so it cannot be fully assessed."
        }

    /**
     * Order for worst-first presentation, so an unassessable application is never
     * buried under assessable ones.
     */
    val severityRank: Int
        get() = when (this) {
            UNAVAILABLE -> 0
            CONFLICT -> 1
            AVAILABLE_UNVERIFIED -> 2
            AVAILABLE_PARTIALLY_VERIFIED -> 3
            AVAILABLE_VERIFIED -> 4
        }

    companion object {
        /**
         * Read availability off a frozen spray-line snapshot.
         *
         * Deliberately takes only the snapshot. There is no overload accepting a
         * `SavedChemical`, because resolving today's Chemical Store during a
         * historical read is precisely the back-fill this stage forbids: an old
         * application would silently inherit chemistry it was never recorded with.
         */
        fun resolve(snapshot: ChemicalLineSnapshot?): ChemicalIntelligenceAvailability {
            if (snapshot == null) return UNAVAILABLE
            // A snapshot can exist and still carry nothing assessable — a
            // legacy-only line that preserved `"Group 3 + 11"` as display text
            // has no structured group and must not be mistaken for one.
            if (!snapshot.hasResistanceData) return UNAVAILABLE
            return from(snapshot.verificationStatus)
        }

        /** Map a frozen verification status onto availability. */
        fun from(status: ChemicalVerificationStatus): ChemicalIntelligenceAvailability =
            when (status) {
                ChemicalVerificationStatus.VERIFIED -> AVAILABLE_VERIFIED
                ChemicalVerificationStatus.PARTIALLY_VERIFIED -> AVAILABLE_PARTIALLY_VERIFIED
                // A legacy record that was never matched has chemistry of a sort,
                // but nobody ever confirmed which product it describes. That is
                // unverified chemistry, not partial verification.
                ChemicalVerificationStatus.UNVERIFIED,
                ChemicalVerificationStatus.NEEDS_MATCH -> AVAILABLE_UNVERIFIED
                ChemicalVerificationStatus.CONFLICT -> CONFLICT
            }

        /**
         * Availability for a whole tank/application: the WEAKEST line governs.
         *
         * A tank mixing a verified product with one whose chemistry is unknown
         * cannot be assessed as verified — the unknown line could be the very
         * group that breaks the rotation. An application with no lines at all is
         * unavailable rather than vacuously fine.
         */
        fun combined(
            availabilities: List<ChemicalIntelligenceAvailability>,
        ): ChemicalIntelligenceAvailability =
            availabilities.minByOrNull { it.severityRank } ?: UNAVAILABLE
    }
}

/** Availability of this frozen line's chemistry. */
val ChemicalLineSnapshot.resistanceAvailability: ChemicalIntelligenceAvailability
    get() = ChemicalIntelligenceAvailability.resolve(this)

/**
 * Availability of this application line's chemistry.
 *
 * Reads the frozen snapshot only. A line recorded before Chemical Intelligence
 * existed reports UNAVAILABLE, which is the truth.
 */
val SprayChemical.resistanceAvailability: ChemicalIntelligenceAvailability
    get() = ChemicalIntelligenceAvailability.resolve(chemicalSnapshot)

/** Weakest availability across this tank's product lines. */
val SprayTank.resistanceAvailability: ChemicalIntelligenceAvailability
    get() = ChemicalIntelligenceAvailability.combined(chemicals.map { it.resistanceAvailability })
