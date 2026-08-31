package com.rork.vinetrack.data.chemical

/**
 * What the Review Chemical screen may offer an operator about the DEFAULT RATE.
 *
 * # The dead end this replaces
 *
 * The review screen used to refuse the save with "Rate not found — enter the
 * rate from the label before saving." while showing no rate field, no rate
 * option and no other control. Add to Chemical Store stayed disabled, the
 * message named an action the screen did not offer, and the operator's only
 * remaining move was to abandon the product.
 *
 * An instruction with no control is worse than silence: silence at least
 * doesn't imply the operator is failing to do something.
 *
 * # Two states, and they are decided by the BACKEND
 *
 * ```text
 * canonical options present -> confirm one (this is the normal path)
 * none present              -> fail closed, and offer four real ways out
 * ```
 *
 * The second state is deliberately NOT "let them type a number". A rate typed
 * here would have no `option_key` and no `rate_ids`, so it could never be shown
 * to correspond to a printed direction — it would be a number wearing the
 * costume of a label-checked rate. The product can still be added; it just
 * enters as a manual, plainly Not-checked record, which is the truth.
 */
object ChemicalRateGate {

    /** Copy for the fail-closed state. Pinned so the tests read the real string. */
    const val NO_CANONICAL_RATE_MESSAGE: String =
        "VineTrack could not read a registered grapevine rate from this label, " +
            "so this product cannot yet be added as a label-checked chemical."

    /** The four ways forward offered beside [NO_CANONICAL_RATE_MESSAGE]. */
    const val ACTION_RETRY: String = "Retry label details"
    const val ACTION_OPEN_LABEL: String = "Open official label"
    const val ACTION_ENTER_MANUALLY: String = "Enter manually"
    const val ACTION_CHANGE_PRODUCT: String = "Change product"

    /** What entering manually will actually produce, said plainly up front. */
    const val MANUAL_FALLBACK_NOTICE: String =
        "Entering it manually saves it as your own record. It stays “Not checked” " +
            "because no official label rate was read for it."

    /** Every action the fail-closed panel must offer, in the order shown. */
    val correctiveActions: List<String> = listOf(
        ACTION_RETRY,
        ACTION_OPEN_LABEL,
        ACTION_ENTER_MANUALLY,
        ACTION_CHANGE_PRODUCT,
    )

    /**
     * Identity prefixes that are the SERVER'S to mint, never this device's.
     *
     * An identity minted on a phone cannot be matched by any other client: it
     * would look canonical, persist as canonical, and correspond to nothing the
     * register ever issued.
     */
    val serverOnlyIdentityPrefixes: List<String> =
        listOf("default_option_v1_", "rate_v1_", "direction_v1_")

    /** The decision for one reviewed product. */
    sealed interface Decision {
        /**
         * The label yielded canonical rate options. Show the confirmation
         * control; the operator picks one (and types a dose inside a band).
         */
        data object Confirmable : Decision

        /**
         * No canonical option exists, so no label-checked save is possible.
         * The screen must show [NO_CANONICAL_RATE_MESSAGE] and every action in
         * [correctiveActions] — never an instruction to "enter the rate".
         */
        data object NoCanonicalRate : Decision

        /**
         * The product registers no grapevine use at all, so a default rate is
         * not the thing standing in the way. A different violation already
         * explains it, and inventing a rate prompt here would misdirect.
         */
        data object NotApplicable : Decision
    }

    /**
     * Which state this product is in.
     *
     * @param selection the in-flight default-rate decision, or null before a
     *   structured lookup has produced one
     * @param grapevineUses the vineyard-scoped registered uses
     */
    fun decide(
        selection: ChemicalDefaultRateSelection?,
        grapevineUses: List<ChemicalRegisteredUse>,
    ): Decision {
        if (grapevineUses.statedUses().isEmpty()) return Decision.NotApplicable
        if (selection?.offersAnyChoice == true) return Decision.Confirmable
        return Decision.NoCanonicalRate
    }

    /**
     * Whether the screen may legitimately tell the operator to enter a rate.
     *
     * True only when a control to do so is actually on screen. This is the rule
     * the old copy broke, expressed so a test can hold the screen to it.
     */
    fun mayInstructRateEntry(decision: Decision): Boolean =
        decision == Decision.Confirmable

    /**
     * Whether a string is an identity only the server may issue.
     *
     * Used by the manual fallback to prove it fabricates nothing: a manual
     * record carries no option key, no rate id and no direction id.
     */
    fun isServerOnlyIdentity(value: String?): Boolean {
        val trimmed = value?.trim().orEmpty()
        if (trimmed.isEmpty()) return false
        return serverOnlyIdentityPrefixes.any { trimmed.startsWith(it) }
    }
}
