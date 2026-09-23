package com.rork.vinetrack.data.material

import com.rork.vinetrack.data.auth.SessionPhase

/**
 * THE single access decision for Work Task Material Costs (sql/247).
 *
 * Work Task materials follow the existing vineyard Work Task access path.
 *
 * Material Library entry points retain their separate System Admin restriction.
 *
 * ## Why the database is NOT gated on System Admin
 *
 * sql/247 deliberately uses the ordinary vineyard/work-task policies:
 * `is_vineyard_member` for reads, `has_vineyard_role` for writes. Baking
 * "System Admin only" into RLS would introduce a platform-authority
 * carve-out inside a tenant's costing data.
 *
 * ## This is presentation only
 *
 * A cached client boolean is not authorisation. Every read and write is
 * independently enforced by RLS; hiding an entry point protects nobody on its
 * own. Mirrors the iOS `WorkTaskMaterialCostsAccess.swift` exactly.
 */
sealed interface WorkTaskMaterialCostsAccess {

    /** Material Costs may be shown and exercised. */
    data object Allowed : WorkTaskMaterialCostsAccess

    /** Everyone else, including unauthenticated and still-resolving sessions. */
    data class Unavailable(val reason: Reason) : WorkTaskMaterialCostsAccess

    /**
     * Why access was refused. Diagnostic only.
     */
    enum class Reason {
        /** No authenticated session (signed out). */
        NotAuthenticated,

        /** Session still hydrating; nothing about the user is known yet. */
        SessionRestoring,


        /**
         * No vineyard is selected, or the caller is not a member of it.
         * Material Costs is vineyard data; platform authority never crosses a
         * tenancy boundary. This reason SURVIVES removal of the gate.
         */
        NotVineyardMember,
    }

    val isAllowed: Boolean get() = this is Allowed

    companion object {
        /**
         * Resolve the single decision.
         *
         * Fail-closed: every unresolved state lands in [Unavailable], so a
         * Material Costs entry point can never flash into view during launch
         * for someone who does not have it.
         */
        fun resolve(
            sessionPhase: SessionPhase,
            selectedVineyardId: String?,
            isMemberOfSelectedVineyard: Boolean,
        ): WorkTaskMaterialCostsAccess = when {
            sessionPhase == SessionPhase.Restoring -> Unavailable(Reason.SessionRestoring)
            !sessionPhase.isAuthenticated -> Unavailable(Reason.NotAuthenticated)
            selectedVineyardId.isNullOrBlank() -> Unavailable(Reason.NotVineyardMember)
            !isMemberOfSelectedVineyard -> Unavailable(Reason.NotVineyardMember)
            else -> Allowed
        }

    }
}
