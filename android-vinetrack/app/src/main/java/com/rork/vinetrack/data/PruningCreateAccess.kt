package com.rork.vinetrack.data

/**
 * Resolved state of the "can this account create pruning records?" question,
 * shared by every create affordance on the Pruning Tracker (top app bar `+`,
 * the labelled button and the empty state) so they can never disagree.
 *
 * The create action is NEVER silently removed. An unknown or still-loading role
 * renders a DISABLED control with a visible explanation, because a missing
 * permission answer is a configuration problem the user must be able to see —
 * not a reason to hand an authorised user a blank interface.
 *
 * Mirrors the iOS `PruningCreateAccess` and `BackendRole.canCreateOperationalRecords`.
 */
sealed interface PruningCreateAccess {
    /** Membership/role has not resolved yet — show a disabled progress state. */
    data object Loading : PruningCreateAccess

    /** Role resolved and permitted. */
    data object Allowed : PruningCreateAccess

    /** Role resolved and not permitted. */
    data object Denied : PruningCreateAccess

    /** Role could not be resolved — deny the write, but explain why. */
    data class Unresolved(val reason: String) : PruningCreateAccess

    val isAllowed: Boolean get() = this is Allowed

    /** Non-null whenever the action is unusable; shown verbatim to the user. */
    val explanation: String?
        get() = when (this) {
            Allowed -> null
            Loading -> "Checking your vineyard permissions…"
            Denied ->
                "Your role on this vineyard can view pruning progress but not record it. " +
                    "Ask an owner or manager for record-creation access."
            is Unresolved -> "Pruning permissions couldn't be confirmed, so recording is locked. $reason"
        }

    companion object {
        /**
         * Roles permitted to create operational records. Identical to the iOS
         * contract: every known vineyard role may record work; only an UNKNOWN
         * role is refused.
         */
        private val CREATE_ROLES = setOf("owner", "manager", "supervisor", "operator")

        /**
         * @param role the current member's role, lower-cased, or null when unknown.
         * @param membersLoaded whether the membership list has been fetched at all.
         *   A null role with no membership loaded means "still loading", not "denied".
         */
        fun resolve(role: String?, membersLoaded: Boolean): PruningCreateAccess {
            val normalised = role?.trim()?.lowercase()
            if (normalised.isNullOrEmpty()) {
                return if (!membersLoaded) {
                    Loading
                } else {
                    Unresolved(
                        "Your membership role for this vineyard hasn't loaded yet. " +
                            "Pull to refresh, or reopen the vineyard.",
                    )
                }
            }
            return if (normalised in CREATE_ROLES) Allowed else Denied
        }
    }
}
