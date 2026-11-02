import Foundation
import Observation
import Supabase

/// VineTrack platform-level system admin status + shared feature flags.
///
/// Source of truth lives in Supabase:
///   - `public.system_admins`        — registry of platform admins
///   - `public.system_feature_flags` — shared flags (read/written via RPC)
///
/// Vineyard owner/manager roles do NOT grant access here. Only users listed
/// as active rows in `system_admins` can edit flags. Anyone authenticated can
/// read flags so diagnostic surfaces can be toggled remotely without an app
/// release.
@Observable
@MainActor
final class SystemAdminService {
    private(set) var isSystemAdmin: Bool = false
    private(set) var flags: [String: SystemFeatureFlag] = [:]
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?
    /// The signed-in Supabase account whose current admin result was verified.
    private(set) var verifiedAccountId: UUID?
    /// Invalidates pending async auth results on refresh and sign-out.
    private var authorizationGeneration: UInt64 = 0

    private let repository: SupabaseSystemAdminRepository

    init(repository: SupabaseSystemAdminRepository = SupabaseSystemAdminRepository()) {
        self.repository = repository
    }

    #if DEBUG
    /// Disposable workflow fixture only; never present in Release or used by auth.
    static func yieldValidationService(isAdmin: Bool) -> SystemAdminService {
        let service = SystemAdminService()
        service.isSystemAdmin = isAdmin
        return service
    }
    #endif

    // MARK: - Public API

    /// Convenience accessor — defaults to OFF if not loaded yet or unknown.
    func isEnabled(_ key: String) -> Bool {
        flags[key]?.isEnabled ?? false
    }

    /// Add New Chemical is V2 even before flags load. An explicit OFF is the
    /// single emergency rollback for every creation route; existing selection
    /// and re-verification are never redirected.
    var usesChemicalSearchV2ForCreation: Bool {
        flags[SystemFeatureFlagKey.chemicalSearchV2]?.isEnabled ?? true
    }

    var sortedFlags: [SystemFeatureFlag] {
        flags.values.sorted { lhs, rhs in
            let lc = lhs.category ?? "zzz"
            let rc = rhs.category ?? "zzz"
            if lc != rc { return lc < rc }
            return lhs.displayLabel.lowercased() < rhs.displayLabel.lowercased()
        }
    }

    /// Refresh admin status + flags. Safe to call on launch and on settings
    /// open — failures are stored in `lastError` but never throw to the UI.
    func refresh() async {
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        let startingAccount = SupabaseClientProvider.shared.client.auth.currentUser?.id
        PerformanceCapture.shared.suspendAuthorization()
        isSystemAdmin = false
        verifiedAccountId = nil
        isLoading = true
        lastLoadedAt = nil
        lastError = nil
        defer {
            if generation == authorizationGeneration { isLoading = false }
        }
        guard let startingAccount else {
            PerformanceCapture.shared.authorize(false)
            return
        }
        do {
            async let adminTask = repository.isSystemAdmin()
            async let flagsTask = repository.fetchFlags()
            let (admin, flagList) = try await (adminTask, flagsTask)
            // Never apply the results of account A after account B logs in,
            // or after a newer admin check invalidates this generation.
            guard generation == authorizationGeneration,
                  startingAccount == SupabaseClientProvider.shared.client.auth.currentUser?.id else {
                return
            }
            isSystemAdmin = admin
            verifiedAccountId = admin ? startingAccount : nil
            PerformanceCapture.shared.authorize(admin)
            var map: [String: SystemFeatureFlag] = [:]
            for flag in flagList { map[flag.key] = flag }
            flags = map
            lastLoadedAt = Date()
        } catch {
            guard generation == authorizationGeneration,
                  startingAccount == SupabaseClientProvider.shared.client.auth.currentUser?.id else {
                return
            }
            lastError = error.localizedDescription
            isSystemAdmin = false
            verifiedAccountId = nil
            PerformanceCapture.shared.authorize(false)
        }
    }

    /// Toggle a flag remotely (system admins only). Updates local cache
    /// optimistically and reloads from Supabase on completion.
    @discardableResult
    func setFlag(key: String, isEnabled: Bool) async -> Bool {
        guard isSystemAdmin, verifiedAccountId != nil,
              verifiedAccountId == SupabaseClientProvider.shared.client.auth.currentUser?.id else {
            lastError = "System admin required."
            return false
        }
        let previous = flags[key]
        if let previous {
            flags[key] = SystemFeatureFlag(
                key: previous.key,
                valueType: previous.valueType,
                category: previous.category,
                label: previous.label,
                description: previous.description,
                isEnabled: isEnabled,
                updatedAt: Date()
            )
        }
        do {
            try await repository.setFlag(key: key, isEnabled: isEnabled)
            await refresh()
            return true
        } catch {
            // Roll back optimistic update on failure.
            if let previous { flags[key] = previous }
            lastError = error.localizedDescription
            return false
        }
    }

    func clearOnSignOut() {
        authorizationGeneration &+= 1
        verifiedAccountId = nil
        SyncDiagnosticHistory.clear()
        PerformanceCapture.shared.revoke()
        isSystemAdmin = false
        flags = [:]
        lastError = nil
        lastLoadedAt = nil
    }
}
