package com.rork.vinetrack.data.material

import com.rork.vinetrack.data.auth.SessionPhase

/**
 * THE single access decision for Work Task Material Costs (sql/247).
 *
 * ## TEMPORARY DEVELOPMENT GATE — REMOVE WHEN THE FEATURE IS ACCEPTED
 *
 * While Material Costs is being built, the feature is exposed to platform
 * System Admins ONLY. Every other role continues to see the existing Work Task
 * experience with no Material Costs controls, no placeholders, no Material
 * Costs validation and no Material Costs completion requirements.
 *
 * This file is the ONLY place in the Android app that consults System Admin
 * status for Material Costs. Nothing in the models, store, repository or
 * offline replay knows this gate exists — so removing it is a one-line change
 * here plus deleting the callers' check, with:
 *
 *  * NO database migration
 *  * NO RLS policy change
 *  * NO schema change
 *  * NO change to [WorkTaskMaterial], [VineyardMaterial],
 *    [MaterialCatalogueItem], [WorkTaskMaterialRepository],
 *    [WorkTaskMaterialStore], [WorkTaskMaterialSync] or [VineyardMaterialSync]
 *  * NO change to already-stored data
 *
 * ### How to remove the gate later
 *
 * Delete the `!isSystemAdmin` branch in [resolve]; the feature then resolves on
 * the normal Work Task permission the caller already holds (vineyard membership
 * plus the role that may edit the parent task). [Reason.NotSystemAdmin] becomes
 * unreachable and can be deleted. Call sites keep asking this same type, so
 * they do not change at all.
 *
 * ## Why the database is NOT gated on System Admin
 *
 * sql/247 deliberately uses the ordinary vineyard/work-task policies:
 * `is_vineyard_member` for reads, `has_vineyard_role` for writes. Baking
 * "System Admin only" into RLS would make the eventual production permission
 * model a migration instead of a client change, and would leave a
 * platform-authority carve-out inside a tenant's costing data. The temporary
 * restriction is a PRESENTATION decision and lives only here.
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
     * Why access was refused. Diagnostic only — a non-admin is shown nothing at
     * all, not an explanation.
     */
    enum class Reason {
        /** No authenticated session (signed out). */
        NotAuthenticated,

        /** Session still hydrating; nothing about the user is known yet. */
        SessionRestoring,

        /**
         * TEMPORARY. Authenticated, but not an active platform System Admin.
         * Disappears when the development gate is removed.
         */
        NotSystemAdmin,

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
            isSystemAdmin: Boolean,
            selectedVineyardId: String?,
            isMemberOfSelectedVineyard: Boolean,
        ): WorkTaskMaterialCostsAccess = when {
            sessionPhase == SessionPhase.Restoring -> Unavailable(Reason.SessionRestoring)
            !sessionPhase.isAuthenticated -> Unavailable(Reason.NotAuthenticated)
            // ---- TEMPORARY DEVELOPMENT GATE (delete this line to ship) ----
            !isSystemAdmin -> Unavailable(Reason.NotSystemAdmin)
            // ---------------------------------------------------------------
            selectedVineyardId.isNullOrBlank() -> Unavailable(Reason.NotVineyardMember)
            !isMemberOfSelectedVineyard -> Unavailable(Reason.NotVineyardMember)
            else -> Allowed
        }

        /**
         * True while the temporary System Admin restriction is still in force.
         * Referenced by the gate's own tests so the day it is removed, the
         * tests asserting "non-admins see nothing" fail loudly and get updated
         * rather than silently passing against a now-public feature.
         */
        const val IS_TEMPORARY_SYSTEM_ADMIN_GATE_ACTIVE = true
    }
}
