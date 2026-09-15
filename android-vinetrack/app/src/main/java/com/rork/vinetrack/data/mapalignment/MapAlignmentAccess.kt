package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.auth.SessionPhase

/**
 * The single access decision for Android Map Alignment.
 *
 * Every layer — entry visibility, navigation and execution — asks THIS, so a
 * role comparison is never re-implemented inside a Compose screen and the three
 * layers can never disagree.
 *
 * ## Authority
 *
 * The only thing that grants access is platform **System Admin**: an active row
 * in `public.system_admins`, resolved by the existing `is_system_admin()` RPC
 * via `SystemAdminRepository` and surfaced as `AppUiState.isSystemAdmin`. That
 * is the same authority already gating the Admin dashboard, and it is
 * server-enforced.
 *
 * A vineyard role is explicitly NOT System Admin. Owner, manager, supervisor
 * and operator are vineyard memberships; they confer no platform authority and
 * are deliberately not consulted here at all. There is no email allow-list, no
 * user-id check, no build-type bypass, no local preference and no hidden
 * gesture — the feature is unavailable unless System Admin is positively
 * established for an authenticated session.
 *
 * ## Fail-closed
 *
 * [Unavailable] is the default. While the session is still restoring, or while
 * the admin check has not yet returned, access is DENIED rather than optimistically
 * granted. `isSystemAdmin` defaults to `false` and is only ever set true by a
 * successful RPC, so an unresolved state naturally lands here.
 */
sealed interface MapAlignmentAccess {

    /** Signed-in active system admin — the preview may be shown and opened. */
    data object Allowed : MapAlignmentAccess

    /** Everyone else, including unauthenticated and still-resolving sessions. */
    data class Unavailable(val reason: Reason) : MapAlignmentAccess

    /** Why access was refused. Diagnostic only — non-admins are shown nothing. */
    enum class Reason {
        /** No authenticated session (signed out). */
        NotAuthenticated,

        /** Session still hydrating; nothing about the user is known yet. */
        SessionRestoring,

        /** Authenticated, but not an active platform System Admin. */
        NotSystemAdmin,
    }

    val isAllowed: Boolean get() = this is Allowed

    companion object {
        /**
         * Resolve whether the current user may use Android Map Alignment.
         *
         * @param sessionPhase the authentication lifecycle state.
         * @param isSystemAdmin the authoritative platform System Admin flag from
         *   `AppUiState.isSystemAdmin` (backed by `is_system_admin()`).
         *
         * Note there is deliberately no `role` parameter: a vineyard role can
         * neither grant nor deny this, so accepting one would invite exactly the
         * confusion this gate exists to prevent.
         */
        fun resolve(
            sessionPhase: SessionPhase,
            isSystemAdmin: Boolean,
        ): MapAlignmentAccess = when {
            sessionPhase == SessionPhase.Restoring -> Unavailable(Reason.SessionRestoring)
            !sessionPhase.isAuthenticated -> Unavailable(Reason.NotAuthenticated)
            isSystemAdmin -> Allowed
            else -> Unavailable(Reason.NotSystemAdmin)
        }

        /**
         * Execution guard for alignment create/edit/reset operations.
         *
         * Hiding the entry is never the boundary: any mutation added in a later
         * pass must call this first and refuse when it returns false, exactly as
         * the Admin RPCs are server-enforced independently of the Settings entry.
         */
        fun canMutateAlignment(access: MapAlignmentAccess): Boolean = access.isAllowed
    }
}
