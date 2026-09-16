import Foundation

/// The single access decision for Vineyard Insights.
///
/// Tile visibility, Customise Tools, direct navigation and restored navigation
/// all ask THIS, so the rule exists once and the layers cannot disagree.
/// Mirrors the Android `VineyardInsightsAccess.kt`.
///
/// ## Two independent requirements
///
/// Access needs BOTH:
///
///  1. **Platform System Admin** — an active row in `public.system_admins`,
///     resolved by `is_system_admin()` and surfaced as
///     `SystemAdminService.isSystemAdmin`. A vineyard role is not System
///     Admin: owner, manager, supervisor and operator are memberships of a
///     customer's vineyard and confer no platform authority whatsoever.
///  2. **Membership of the selected vineyard** — System Admin is a platform
///     capability, not a skeleton key. Being able to administer VineTrack does
///     not make someone a member of a grower's business, and a preview feature
///     must not become the one place where tenancy stops applying. The server
///     enforces the same conjunction in SQL 236; this is its client mirror.
///
/// ## Fail-closed
///
/// `unavailable` is the default and every unresolved state lands there. While
/// the session is restoring, while the admin check is in flight, or while no
/// vineyard is selected, access is DENIED rather than optimistically granted.
/// That is what stops the tile flashing into view during launch and then
/// vanishing — a flash is not merely untidy, it discloses that the feature
/// exists to someone who may not have it.
///
/// ## This is presentation only
///
/// A cached client boolean is not an authorisation decision. Every read and
/// write is independently enforced by RLS and by the security-definer
/// functions in SQL 236, which re-check `auth.uid()`, `is_system_admin()` and
/// membership of the target vineyard. Hiding a tile protects nobody on its own.
nonisolated enum VineyardInsightsAccess: Equatable, Sendable {

    /// Signed-in System Admin who is also a member of the selected vineyard.
    case allowed

    /// Everyone else, including unauthenticated and still-resolving sessions.
    case unavailable(Reason)

    /// Why access was refused. Diagnostic only — non-admins are shown nothing.
    nonisolated enum Reason: Equatable, Sendable {
        /// No authenticated session (signed out).
        case notAuthenticated
        /// Session or admin status still resolving; nothing is known yet.
        case stillResolving
        /// Authenticated, but not an active platform System Admin.
        case notSystemAdmin
        /// System Admin, but not a member of the selected vineyard — or no
        /// vineyard is selected at all. Platform authority never crosses a
        /// tenancy boundary.
        case notVineyardMember
    }

    var isAllowed: Bool { self == .allowed }

    /// - Parameters:
    ///   - isAuthenticated: a signed-in session exists.
    ///   - isResolving: the session or the System Admin check has not settled.
    ///   - isSystemAdmin: `SystemAdminService.isSystemAdmin`.
    ///   - selectedVineyardID: the vineyard currently in context.
    ///   - isMemberOfSelectedVineyard: the caller holds a role in it.
    static func resolve(
        isAuthenticated: Bool,
        isResolving: Bool,
        isSystemAdmin: Bool,
        selectedVineyardID: UUID?,
        isMemberOfSelectedVineyard: Bool
    ) -> VineyardInsightsAccess {
        if isResolving { return .unavailable(.stillResolving) }
        if !isAuthenticated { return .unavailable(.notAuthenticated) }
        if !isSystemAdmin { return .unavailable(.notSystemAdmin) }
        guard selectedVineyardID != nil else { return .unavailable(.notVineyardMember) }
        if !isMemberOfSelectedVineyard { return .unavailable(.notVineyardMember) }
        return .allowed
    }
}
