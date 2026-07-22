import Foundation
import Observation

/// Role-based access control backed by the new Supabase backend membership system.
/// Loads the current user's `BackendRole` for the selected vineyard and exposes
/// a set of granular permission flags. Defaults to a safely locked-down state
/// when the role is unknown or still loading.
@Observable
@MainActor
final class BackendAccessControl {
    var currentRole: BackendRole?
    var isLoading: Bool = false
    var errorMessage: String?

    private(set) var loadedVineyardId: UUID?
    private(set) var loadedUserId: UUID?

    private let teamRepository: any TeamRepositoryProtocol

    init(teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()) {
        self.teamRepository = teamRepository
    }

    // MARK: - Permission flags

    var canViewFinancials: Bool { currentRole?.canViewFinancials ?? false }
    /// Costing visibility (labour/fuel/chemical/total). Owners + managers only.
    /// Alias of `canViewFinancials` so all costing UI funnels through one helper.
    var canViewCosting: Bool { currentRole?.canViewCosting ?? false }
    var canChangeSettings: Bool { currentRole?.canChangeSettings ?? false }
    var canDeleteOperationalRecords: Bool { currentRole?.canDeleteOperationalRecords ?? false }
    var canInviteMembers: Bool { currentRole?.canInviteMembers ?? false }
    var canExportFinancialReports: Bool { currentRole?.canExportFinancialReports ?? false }
    var canManageBilling: Bool { currentRole?.canManageBilling ?? false }
    var canEditRecords: Bool { currentRole?.canEditRecords ?? false }
    var canCreateOperationalRecords: Bool { currentRole?.canCreateOperationalRecords ?? false }

    /// General export permission — anyone with a known role may export
    /// non-financial data. Financial exports are gated separately by
    /// `canExportFinancialReports`.
    var canExport: Bool { currentRole != nil }

    /// Convenience for legacy bridge.
    var legacyAccessControl: LegacyAccessControl {
        LegacyAccessControl(
            canDelete: canDeleteOperationalRecords,
            canExport: canExport,
            canExportFinancialPDF: canExportFinancialReports,
            canViewFinancials: canViewFinancials,
            canViewCosting: canViewCosting,
            canFinalizeRecords: canDeleteOperationalRecords,
            canReopenRecords: canDeleteOperationalRecords,
            canManageSetup: canChangeSettings
        )
    }

    // MARK: - Loading

    func refresh(for vineyardId: UUID?, auth: NewBackendAuthService) async {
        guard let vineyardId, let userId = auth.userId else {
            currentRole = nil
            loadedVineyardId = nil
            loadedUserId = nil
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let members = try await teamRepository.listMembers(vineyardId: vineyardId)
            currentRole = members.first { $0.userId == userId }?.role
            loadedVineyardId = vineyardId
            loadedUserId = userId
        } catch {
            errorMessage = error.localizedDescription
            currentRole = nil
        }
    }

    func clear() {
        currentRole = nil
        loadedVineyardId = nil
        loadedUserId = nil
        errorMessage = nil
    }
}
