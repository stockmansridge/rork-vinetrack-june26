import Foundation

/// THE single access decision for Work Task Material Costs (sql/247).
///
/// ## TEMPORARY DEVELOPMENT GATE — REMOVE WHEN THE FEATURE IS ACCEPTED
///
/// While Material Costs is being built, the feature is exposed to platform
/// System Admins ONLY. Every other role continues to see the existing Work
/// Task experience with no Material Costs controls, no placeholders, no
/// Material Costs validation and no Material Costs completion requirements.
///
/// This file is the ONLY place in the iOS app that consults System Admin
/// status for Material Costs. Nothing in the domain models, persistence,
/// repositories or sync services knows this gate exists — so removing it is a
/// two-line change here plus deleting the callers' `guard`, with:
///
///  * NO database migration
///  * NO RLS policy change
///  * NO schema change
///  * NO change to `WorkTaskMaterial`, `VineyardMaterial`,
///    `MaterialCatalogueItem`, their repositories, or their sync services
///  * NO change to already-stored data
///
/// ### How to remove the gate later
///
/// Replace the `isSystemAdmin` requirement in ``resolve(...)`` with the normal
/// Work Task permission the caller already holds (vineyard membership plus the
/// role that may edit the parent task). The ``Reason/notSystemAdmin`` case then
/// becomes unreachable and can be deleted. Call sites keep asking this same
/// type, so they do not change at all.
///
/// ## Why the database is NOT gated on System Admin
///
/// sql/247 deliberately uses the ordinary vineyard/work-task policies:
/// `is_vineyard_member` for reads, `has_vineyard_role` for writes. Baking
/// "System Admin only" into RLS would make the eventual production permission
/// model a migration instead of a client change, and would leave a
/// platform-authority carve-out in a tenant's costing data. The temporary
/// restriction is a PRESENTATION decision and lives only here.
///
/// ## This is presentation only
///
/// A cached client boolean is not authorisation. Every read and write is
/// independently enforced by RLS; hiding an entry point protects nobody on its
/// own. Mirrors the Android `WorkTaskMaterialCostsAccess.kt`.
nonisolated enum WorkTaskMaterialCostsAccess: Equatable, Sendable {

    /// Material Costs may be shown and exercised.
    case allowed

    /// Everyone else, including unauthenticated and still-resolving sessions.
    case unavailable(Reason)

    /// Why access was refused. Diagnostic only — a non-admin is shown nothing
    /// at all, not an explanation.
    nonisolated enum Reason: Equatable, Sendable {
        /// No authenticated session (signed out).
        case notAuthenticated
        /// Session or System Admin status still resolving; nothing is known yet.
        case stillResolving
        /// TEMPORARY. Authenticated, but not an active platform System Admin.
        /// Disappears when the development gate is removed.
        case notSystemAdmin
        /// No vineyard is selected, or the caller is not a member of it.
        /// Material Costs is vineyard data; platform authority never crosses a
        /// tenancy boundary. This reason SURVIVES removal of the gate.
        case notVineyardMember
    }

    var isAllowed: Bool { self == .allowed }

    /// Resolve the single decision.
    ///
    /// Fail-closed: every unresolved state lands in `unavailable`, so a
    /// Material Costs entry point can never flash into view during launch for
    /// someone who does not have it.
    ///
    /// - Parameters:
    ///   - isAuthenticated: a signed-in session exists.
    ///   - isResolving: the session or the System Admin check has not settled.
    ///   - isSystemAdmin: `SystemAdminService.isSystemAdmin`. TEMPORARY input.
    ///   - selectedVineyardID: the vineyard currently in context.
    ///   - isMemberOfSelectedVineyard: the caller holds a role in it.
    static func resolve(
        isAuthenticated: Bool,
        isResolving: Bool,
        isSystemAdmin: Bool,
        selectedVineyardID: UUID?,
        isMemberOfSelectedVineyard: Bool
    ) -> WorkTaskMaterialCostsAccess {
        if isResolving { return .unavailable(.stillResolving) }
        if !isAuthenticated { return .unavailable(.notAuthenticated) }
        // ---- TEMPORARY DEVELOPMENT GATE (delete this line to ship) ----
        if !isSystemAdmin { return .unavailable(.notSystemAdmin) }
        // ---------------------------------------------------------------
        guard selectedVineyardID != nil else { return .unavailable(.notVineyardMember) }
        if !isMemberOfSelectedVineyard { return .unavailable(.notVineyardMember) }
        return .allowed
    }

    /// True while the temporary System Admin restriction is still in force.
    /// Referenced by the gate's own tests so the day it is removed, the tests
    /// that assert "non-admins see nothing" fail loudly and get updated rather
    /// than silently passing against a feature that is now public.
    static let isTemporarySystemAdminGateActive = true
}
