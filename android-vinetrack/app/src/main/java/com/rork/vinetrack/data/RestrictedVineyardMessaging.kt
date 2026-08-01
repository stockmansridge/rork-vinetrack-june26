package com.rork.vinetrack.data

/**
 * Who the restricted-vineyard screen is talking to. Derived only from the
 * server access matrix (sql/157 + sql/158) — never from a local role guess.
 */
enum class RestrictedVineyardAudience {
    /** The matrix has not confirmed a denial yet — never show upgrade/purchase. */
    UNRESOLVED,

    /** Owner of this vineyard who can act on its billing. */
    BILLING_OWNER,

    /** Owner-role member whose billing is controlled by another Owner. */
    CO_OWNER,

    /** Manager / Supervisor / Operator — access is provided by the Owner. */
    TEAM_MEMBER,
}

/**
 * Role-aware copy + allowed actions for the restricted-vineyard screen
 * (Phase 2F.2). Pure and platform-agnostic: iOS
 * (`RestrictedVineyardMessaging.swift`) and the portal use identical wording
 * so all three platforms explain the same thing.
 */
data class RestrictedVineyardMessage(
    val audience: RestrictedVineyardAudience,
    val title: String,
    val body: String,
    /**
     * Solo → Team upgrade action. Only ever true for [RestrictedVineyardAudience.BILLING_OWNER]
     * on a server-confirmed `owner_plan_not_vineyard_funding` denial.
     */
    val showsUpgradeToTeam: Boolean,
    /** Generic "Review billing" action for other confirmed denials. */
    val showsReviewBilling: Boolean,
    val footnote: String? = null,
) {
    /** True when the screen offers any billing/purchase entry point. */
    val offersBillingAction: Boolean get() = showsUpgradeToTeam || showsReviewBilling

    companion object {
        /**
         * sql/157 reason code: the vineyard's Owner is entitled, but only for
         * their own account (Solo / legacy / user-scoped grant / assigned licence).
         */
        const val SOLO_FUNDING_REASON_CODE = "owner_plan_not_vineyard_funding"

        const val UPGRADE_ACTION_TITLE = "Upgrade to Team"
        const val REVIEW_BILLING_ACTION_TITLE = "Review billing"

        /**
         * Build the message for the selected vineyard.
         *
         * @param vineyardName display name of the restricted vineyard.
         * @param entry the vineyard's row from `get_my_vineyard_access_matrix()`.
         * @param isMatrixResolved whether a live server matrix has been loaded;
         *   while false the upgrade/billing state is never shown.
         */
        fun make(
            vineyardName: String,
            entry: VineyardAccessEntry?,
            isMatrixResolved: Boolean,
        ): RestrictedVineyardMessage {
            // Never speculate: without a loaded matrix (or with a still-accessible
            // vineyard) the denial is not server-confirmed.
            if (!isMatrixResolved || entry == null || entry.hasVineyardAccess) {
                return RestrictedVineyardMessage(
                    audience = RestrictedVineyardAudience.UNRESOLVED,
                    title = "Checking your VineTrack access…",
                    body = "We're confirming this vineyard's access with the server. This only takes a moment.",
                    showsUpgradeToTeam = false,
                    showsReviewBilling = false,
                )
            }

            val isOwnerRole = entry.membershipRole.orEmpty().equals("owner", ignoreCase = true)
            // sql/158 `is_billing_authority`. A pre-158 backend omits it, so an
            // Owner keeps the previous behaviour rather than losing the action.
            val hasBillingAuthority = isOwnerRole &&
                (entry.isBillingAuthority ?: entry.canManageBilling ?: true)
            val isSoloFunding = entry.vineyardAccessReason == SOLO_FUNDING_REASON_CODE

            val audience = when {
                isOwnerRole && hasBillingAuthority -> RestrictedVineyardAudience.BILLING_OWNER
                isOwnerRole -> RestrictedVineyardAudience.CO_OWNER
                else -> RestrictedVineyardAudience.TEAM_MEMBER
            }

            if (isSoloFunding) {
                return when (audience) {
                    RestrictedVineyardAudience.BILLING_OWNER -> RestrictedVineyardMessage(
                        audience = audience,
                        title = "$vineyardName needs a Team plan",
                        body = "Your current VineTrack plan covers your own account only, so it doesn't fund " +
                            "access for the people working in $vineyardName. Upgrade to a Team plan to restore " +
                            "access for every active member of this vineyard. Your other vineyards are unaffected.",
                        showsUpgradeToTeam = true,
                        showsReviewBilling = false,
                        footnote = "Team and Enterprise plans cover all active members of a vineyard.",
                    )
                    RestrictedVineyardAudience.CO_OWNER -> RestrictedVineyardMessage(
                        audience = audience,
                        title = "$vineyardName needs a Team plan",
                        body = "Billing for $vineyardName is managed by another Owner, and their current plan " +
                            "covers their own account only. Ask the Owner who manages this vineyard's billing to " +
                            "upgrade it to a Team plan. You can keep working in your other vineyards, and any " +
                            "pending invitations remain available.",
                        showsUpgradeToTeam = false,
                        showsReviewBilling = false,
                    )
                    else -> RestrictedVineyardMessage(
                        audience = RestrictedVineyardAudience.TEAM_MEMBER,
                        title = "$vineyardName needs a Team plan",
                        body = "Access for this vineyard is managed by its Vineyard Owner, and their current plan " +
                            "covers their own account only. Ask the Vineyard Owner to upgrade $vineyardName to a " +
                            "Team plan. You can keep working in your other vineyards, and any pending invitations " +
                            "remain available.",
                        showsUpgradeToTeam = false,
                        showsReviewBilling = false,
                    )
                }
            }

            return when (audience) {
                RestrictedVineyardAudience.BILLING_OWNER -> RestrictedVineyardMessage(
                    audience = audience,
                    title = "Access to $vineyardName has expired",
                    body = "This vineyard no longer has an active subscription, trial, or grant. Review billing " +
                        "to restore access for you and your team. Your other vineyards are unaffected.",
                    showsUpgradeToTeam = false,
                    showsReviewBilling = true,
                )
                RestrictedVineyardAudience.CO_OWNER -> RestrictedVineyardMessage(
                    audience = audience,
                    title = "Access to $vineyardName has expired",
                    body = "Billing for $vineyardName is managed by another Owner. Ask them to renew this " +
                        "vineyard's plan. You can keep working in your other vineyards, and any pending " +
                        "invitations remain available.",
                    showsUpgradeToTeam = false,
                    showsReviewBilling = false,
                )
                else -> RestrictedVineyardMessage(
                    audience = RestrictedVineyardAudience.TEAM_MEMBER,
                    title = "Access to $vineyardName has expired",
                    body = "Access for this vineyard is managed by its Vineyard Owner. You can keep working in " +
                        "your other vineyards, and any pending invitations remain available.",
                    showsUpgradeToTeam = false,
                    showsReviewBilling = false,
                )
            }
        }
    }
}
