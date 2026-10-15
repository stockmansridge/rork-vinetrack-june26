package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.auth.SessionPhase

/**
 * Shared presentation access for Insights entry, customisation and restored navigation.
 * Scout and Vintage Notes require an authenticated selected-vineyard membership.
 * Vintage Report additionally requires platform System Admin authority.
 * Server RLS/RPC permissions remain independent of these client checks.
 */
sealed interface VineyardInsightsAccess {
    data object Allowed : VineyardInsightsAccess
    data class Unavailable(val reason: Reason) : VineyardInsightsAccess

    enum class Reason {
        NotAuthenticated,
        SessionRestoring,
        NotSystemAdmin,
        NotVineyardMember,
    }

    val isAllowed: Boolean get() = this is Allowed

    companion object {
        /** Set [requiresSystemAdmin] only for the Vintage Report workspace. */
        fun resolve(
            sessionPhase: SessionPhase,
            isSystemAdmin: Boolean,
            selectedVineyardId: String?,
            isMemberOfSelectedVineyard: Boolean,
            requiresSystemAdmin: Boolean = false,
        ): VineyardInsightsAccess = when {
            sessionPhase == SessionPhase.Restoring -> Unavailable(Reason.SessionRestoring)
            !sessionPhase.isAuthenticated -> Unavailable(Reason.NotAuthenticated)
            requiresSystemAdmin && !isSystemAdmin -> Unavailable(Reason.NotSystemAdmin)
            selectedVineyardId.isNullOrBlank() -> Unavailable(Reason.NotVineyardMember)
            !isMemberOfSelectedVineyard -> Unavailable(Reason.NotVineyardMember)
            else -> Allowed
        }
    }
}
