import Foundation

/// THE single access decision for Work Task Material Costs (sql/247).
///
/// Material lines use the existing Work Task access path; the Material Library
/// in Settings retains its separate System Admin restriction.
///
/// ## Why the database is NOT gated on System Admin
///
/// sql/247 deliberately uses the ordinary vineyard/work-task policies:
/// `is_vineyard_member` for reads, `has_vineyard_role` for writes. Baking
/// "System Admin only" into RLS would introduce a platform-authority
/// carve-out in a tenant's costing data.
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

    /// Why access was refused. Diagnostic only.
    nonisolated enum Reason: Equatable, Sendable {
        /// No authenticated session (signed out).
        case notAuthenticated
        /// Session still resolving; nothing is known yet.
        case stillResolving
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
    ///   - isResolving: the session has not settled.
    ///   - selectedVineyardID: the vineyard currently in context.
    ///   - isMemberOfSelectedVineyard: the caller holds a role in it.
    static func resolve(
        isAuthenticated: Bool,
        isResolving: Bool,
        selectedVineyardID: UUID?,
        isMemberOfSelectedVineyard: Bool
    ) -> WorkTaskMaterialCostsAccess {
        if isResolving { return .unavailable(.stillResolving) }
        if !isAuthenticated { return .unavailable(.notAuthenticated) }
        guard selectedVineyardID != nil else { return .unavailable(.notVineyardMember) }
        if !isMemberOfSelectedVineyard { return .unavailable(.notVineyardMember) }
        return .allowed
    }

}
