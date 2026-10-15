import Foundation

/// Shared presentation access for Insights entry, customisation and restored navigation.
/// Scout and Vintage Notes require an authenticated selected-vineyard membership.
/// Vintage Report additionally requires resolved platform System Admin authority.
/// Server RLS/RPC permissions remain independent of these client checks.
nonisolated enum VineyardInsightsAccess: Equatable, Sendable {
    case allowed
    case unavailable(Reason)

    nonisolated enum Reason: Equatable, Sendable {
        case notAuthenticated
        case stillResolving
        case notSystemAdmin
        case notVineyardMember
    }

    var isAllowed: Bool { self == .allowed }

    /// Pass `requiresSystemAdmin` only for the Vintage Report workspace.
    /// `isResolving` represents membership/session loading for general Insights,
    /// and must also include admin loading when resolving report access.
    static func resolve(
        isAuthenticated: Bool,
        isResolving: Bool,
        isSystemAdmin: Bool,
        selectedVineyardID: UUID?,
        isMemberOfSelectedVineyard: Bool,
        requiresSystemAdmin: Bool = false
    ) -> VineyardInsightsAccess {
        if isResolving { return .unavailable(.stillResolving) }
        if !isAuthenticated { return .unavailable(.notAuthenticated) }
        if requiresSystemAdmin && !isSystemAdmin { return .unavailable(.notSystemAdmin) }
        guard selectedVineyardID != nil else { return .unavailable(.notVineyardMember) }
        if !isMemberOfSelectedVineyard { return .unavailable(.notVineyardMember) }
        return .allowed
    }
}
