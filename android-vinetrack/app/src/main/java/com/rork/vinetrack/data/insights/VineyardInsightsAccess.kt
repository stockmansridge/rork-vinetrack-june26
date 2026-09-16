package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.auth.SessionPhase

/**
 * The single access decision for Vineyard Insights.
 *
 * Tile visibility, Customise Tools, direct navigation and restored navigation
 * all ask THIS, so the rule exists once and the layers cannot disagree.
 *
 * ## Two independent requirements
 *
 * Access needs BOTH:
 *
 *  1. **Platform System Admin** — an active row in `public.system_admins`,
 *     resolved by `is_system_admin()` and surfaced as
 *     `AppUiState.isSystemAdmin`. A vineyard role is not System Admin: owner,
 *     manager, supervisor and operator are memberships of a customer's
 *     vineyard and confer no platform authority whatsoever.
 *  2. **Membership of the selected vineyard** — System Admin is a platform
 *     capability, not a skeleton key. Being able to administer VineTrack does
 *     not make someone a member of a grower's business, and a preview feature
 *     must not become the one place where tenancy stops applying. The server
 *     enforces the same conjunction in SQL 236; this is its client mirror.
 *
 * ## Fail-closed
 *
 * [Unavailable] is the default and every unresolved state lands there. While
 * the session is restoring, while the admin check is in flight, or while no
 * vineyard is selected, access is DENIED rather than optimistically granted.
 * That is what stops the tile flashing into view during launch and then
 * vanishing — a flash is not merely untidy, it discloses that the feature
 * exists to someone who may not have it.
 *
 * ## This is presentation only
 *
 * A cached client boolean is not an authorisation decision. Every read and
 * write is independently enforced by RLS and by the security-definer functions
 * in SQL 236, which re-check `auth.uid()`, `is_system_admin()` and membership
 * of the target vineyard. Hiding a tile protects nobody on its own.
 */
sealed interface VineyardInsightsAccess {

    /** Signed-in System Admin who is also a member of the selected vineyard. */
    data object Allowed : VineyardInsightsAccess

    /** Everyone else, including unauthenticated and still-resolving sessions. */
    data class Unavailable(val reason: Reason) : VineyardInsightsAccess

    /** Why access was refused. Diagnostic only — non-admins are shown nothing. */
    enum class Reason {
        /** No authenticated session (signed out). */
        NotAuthenticated,

        /** Session still hydrating; nothing about the user is known yet. */
        SessionRestoring,

        /** Authenticated, but not an active platform System Admin. */
        NotSystemAdmin,

        /**
         * System Admin, but not a member of the selected vineyard — or no
         * vineyard is selected at all. Platform authority never crosses a
         * tenancy boundary.
         */
        NotVineyardMember,
    }

    val isAllowed: Boolean get() = this is Allowed

    companion object {
        fun resolve(
            sessionPhase: SessionPhase,
            isSystemAdmin: Boolean,
            selectedVineyardId: String?,
            isMemberOfSelectedVineyard: Boolean,
        ): VineyardInsightsAccess = when {
            sessionPhase == SessionPhase.Restoring -> Unavailable(Reason.SessionRestoring)
            !sessionPhase.isAuthenticated -> Unavailable(Reason.NotAuthenticated)
            !isSystemAdmin -> Unavailable(Reason.NotSystemAdmin)
            selectedVineyardId.isNullOrBlank() -> Unavailable(Reason.NotVineyardMember)
            !isMemberOfSelectedVineyard -> Unavailable(Reason.NotVineyardMember)
            else -> Allowed
        }
    }
}
