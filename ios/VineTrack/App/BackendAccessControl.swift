import Foundation
import Observation
import Supabase

/// Role-based access control backed by the new Supabase backend membership system.
/// Loads the current user's `BackendRole` for the selected vineyard and exposes
/// a set of granular permission flags. Defaults to a safely locked-down state
/// when the role is unknown or still loading.
@Observable
@MainActor
final class BackendAccessControl {
    var currentRole: BackendRole?
    private(set) var currentWorkerTypeId: UUID?
    var isLoading: Bool = false
    var errorMessage: String?

    private(set) var loadedVineyardId: UUID?
    private(set) var loadedUserId: UUID?

    private let teamRepository: any TeamRepositoryProtocol
    private let roleCache: VerifiedVineyardRoleCache
    private let membershipRead: (@MainActor (UUID) async throws -> [BackendVineyardMember])?
    private var refreshId: UUID = UUID()
    private weak var scopedAuth: NewBackendAuthService?
    private var loadedSignOutSequence: Int = 0

    private var effectiveRole: BackendRole? {
        guard let auth = scopedAuth else { return loadedUserId == nil ? currentRole : nil }
        guard auth.isSignedIn, auth.userId == loadedUserId,
              auth.completedSignOutSequence == loadedSignOutSequence else { return nil }
        return currentRole
    }

    init(teamRepository: (any TeamRepositoryProtocol)? = nil,
         roleCache: VerifiedVineyardRoleCache? = nil,
         membershipRead: (@MainActor (UUID) async throws -> [BackendVineyardMember])? = nil) {
        self.teamRepository = teamRepository ?? SupabaseTeamRepository()
        self.roleCache = roleCache ?? VerifiedVineyardRoleCache()
        self.membershipRead = membershipRead
    }

    // MARK: - Permission flags

    var canViewFinancials: Bool { effectiveRole?.canViewFinancials ?? false }
    /// Costing visibility (labour/fuel/chemical/total). Owners + managers only.
    /// Alias of `canViewFinancials` so all costing UI funnels through one helper.
    var canViewCosting: Bool { effectiveRole?.canViewCosting ?? false }
    /// Field pricing (piece rate per vine on an unpriced job). Supervisors and
    /// above. Reviewing or changing an existing price stays on `canViewCosting`.
    var canEnterPricing: Bool { effectiveRole?.canEnterPricing ?? false }
    /// Owner/manager — the client-side mirror of the `spray_jobs` UPDATE policy.
    var canManageSprayProgram: Bool { effectiveRole?.canManageSprayProgram ?? false }
    var canManageManualSprays: Bool { effectiveRole?.canManageManualSprays ?? false }
    var canChangeSettings: Bool { effectiveRole?.canChangeSettings ?? false }
    var canDeleteOperationalRecords: Bool { effectiveRole?.canDeleteOperationalRecords ?? false }
    var canInviteMembers: Bool { effectiveRole?.canInviteMembers ?? false }
    var canExportFinancialReports: Bool { effectiveRole?.canExportFinancialReports ?? false }
    var canManageBilling: Bool { effectiveRole?.canManageBilling ?? false }
    var canEditRecords: Bool { effectiveRole?.canEditRecords ?? false }
    var canCreateOperationalRecords: Bool { effectiveRole?.canCreateOperationalRecords ?? false }

    /// General export permission — anyone with a known role may export
    /// non-financial data. Financial exports are gated separately by
    /// `canExportFinancialReports`.
    var canExport: Bool { effectiveRole != nil }

    /// Convenience for legacy bridge.
    var legacyAccessControl: LegacyAccessControl {
        LegacyAccessControl(
            canDelete: canDeleteOperationalRecords,
            canExport: canExport,
            canExportFinancialPDF: canExportFinancialReports,
            canViewFinancials: canViewFinancials,
            canViewCosting: canViewCosting,
            canEnterPricing: canEnterPricing,
            canFinalizeRecords: canDeleteOperationalRecords,
            canReopenRecords: canDeleteOperationalRecords,
            canManageSetup: canChangeSettings,
            canManageSprayProgram: canManageSprayProgram,
            canManageManualSprays: canManageManualSprays,
            canEditRecords: canEditRecords
        )
    }

    /// Only Inventory flags are scoped here; unrelated legacy permissions stay unchanged.
    func legacyAccessControl(for vineyardId: UUID?, userId: UUID?) -> LegacyAccessControl {
        var access = legacyAccessControl
        guard let vineyardId, let userId, !isLoading,
              loadedVineyardId == vineyardId, loadedUserId == userId,
              let role = effectiveRole else { return access }
        access.inventoryVineyardId = vineyardId
        access.canViewInventory = role.canViewInventory
        access.canRecordInventoryPurchase = role.canRecordInventoryPurchase
        access.canManageInventory = role.canManageInventory
        access.canViewInventoryCosts = role.canViewInventoryCosts
        return access
    }

    // MARK: - Loading

    func refresh(for vineyardId: UUID?, auth: NewBackendAuthService) async {
        guard let vineyardId, auth.isSignedIn, let userId = auth.userId,
              let sessionId = auth.legacySprayScope(vineyard: vineyardId)?.session else {
            clear()
            return
        }
        let requestId = UUID()
        scopedAuth = auth
        loadedSignOutSequence = auth.completedSignOutSequence
        refreshId = requestId
        let cached = roleCache.load(userId: userId, vineyardId: vineyardId, sessionId: sessionId)
        // Switch synchronously to this scope, never show vineyard A's role while B loads.
        currentRole = cached?.role
        currentWorkerTypeId = cached?.workerTypeId
        loadedVineyardId = vineyardId
        loadedUserId = userId
        isLoading = true
        errorMessage = nil
        func isCurrent() -> Bool {
            refreshId == requestId && auth.isSignedIn && auth.userId == userId &&
                auth.legacySprayScope(vineyard: vineyardId)?.session == sessionId
        }
        defer { if refreshId == requestId { isLoading = false } }

        do {
            let members: [BackendVineyardMember]
            if let membershipRead { members = try await membershipRead(vineyardId) }
            else { members = try await teamRepository.listMembers(vineyardId: vineyardId) }
            guard !Task.isCancelled, isCurrent() else { return }
            let membership = members.first { $0.userId == userId && $0.vineyardId == vineyardId }
            // A successful empty result is definitive revocation, not a cache miss.
            currentRole = membership?.role
            currentWorkerTypeId = membership?.operatorCategoryId
            try roleCache.save(.init(userId: userId, vineyardId: vineyardId, sessionId: sessionId,
                                     role: currentRole, workerTypeId: currentWorkerTypeId))
        } catch {
            guard !Task.isCancelled, isCurrent() else { return }
            errorMessage = "Vineyard access could not be refreshed. Previously verified offline access is retained."
            let denied = (error as? PostgrestError)?.code == "42501" ||
                (error as NSError).code == 403
            if denied {
                currentRole = nil
                currentWorkerTypeId = nil
                // Persist denial so a later offline restart cannot resurrect the old role.
                do {
                    try roleCache.save(.init(userId: userId, vineyardId: vineyardId, sessionId: sessionId,
                                             role: nil, workerTypeId: nil))
                } catch {
                    errorMessage = "Access was denied; its local state could not be saved. Reconnect before continuing."
                }
            }
            // Transport, timeout, DNS, 5xx and decoding errors are not proof of revocation.
        }
    }

    func clear() {
        refreshId = UUID()
        isLoading = false
        currentRole = nil
        currentWorkerTypeId = nil
        loadedVineyardId = nil
        loadedUserId = nil
        errorMessage = nil
    }
}
