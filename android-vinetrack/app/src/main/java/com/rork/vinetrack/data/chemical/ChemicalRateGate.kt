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
 * # Two states, and they are decided by the LABEL
 *
 * ```text
 * usable registered grapevine rate or range -> state it, and save
 * none at all                               -> fail closed, four real ways out
 * ```
 *
 * The first state used to be "confirm one", which asked the operator to answer
 * a band with a single figure while adding a product to a store. There is no
 * block, growth stage or carrier volume at that moment, so the question had no
 * honest answer, only whichever endpoint the screen made easiest to tap. A
 * range is a COMPLETE record of what the label registers, so it is enough to
 * save, and the exact applied dose is chosen later when planning the spray.
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
         * The label registers a usable grapevine rate or range. It is STATED,
         * read-only, and the product saves on it.
         *
         * No dose is asked for and none is invented: no endpoint, no midpoint,
         * and no `default_rates` row unless the operator deliberately records
         * an optional default of their own.
         */
        data object RegisteredRateStated : Decision

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
        val stated = grapevineUses.statedUses()
        if (stated.isEmpty()) return Decision.NotApplicable
        // The LABEL decides this, not the presence of minted default-rate
        // options. A registration can carry a perfectly usable band while the
        // server minted no `default_rate_options` for it, and refusing that
        // product would fail closed on a record that is actually complete.
        if (stated.flatMap { it.rates }.any { ChemicalSaveContract.isUsable(it) }) {
            return Decision.RegisteredRateStated
        }
        // Canonical options exist only where the server read a usable rate, so
        // they are equally good evidence that one is on the label.
        if (selection?.offersAnyChoice == true) return Decision.RegisteredRateStated
        return Decision.NoCanonicalRate
    }

    /**
     * Whether this product may be saved as a label-checked chemical.
     *
     * Only the genuinely rate-less label is refused. A range is not a missing
     * rate: it is the rate, as the register printed it.
     */
    fun permitsSave(decision: Decision): Boolean = when (decision) {
        Decision.RegisteredRateStated -> true
        Decision.NotApplicable -> true
        Decision.NoCanonicalRate -> false
    }

    /**
     * Whether the screen may legitimately tell the operator to enter a rate.
     *
     * False on every branch, and the `when` is exhaustive so it stays that way
     * deliberately rather than by neglect. Setup states what the label
     * registers and offers no dose field, so no copy here may instruct one:
     * this is the rule the old dead-end message broke.
     */
    fun mayInstructRateEntry(decision: Decision): Boolean = when (decision) {
        Decision.RegisteredRateStated -> false
        Decision.NoCanonicalRate -> false
        Decision.NotApplicable -> false
    }

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
