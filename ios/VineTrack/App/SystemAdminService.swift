import Foundation
import Observation

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

    private let repository: SupabaseSystemAdminRepository

    init(repository: SupabaseSystemAdminRepository = SupabaseSystemAdminRepository()) {
        self.repository = repository
    }

    // MARK: - Public API

    /// Convenience accessor — defaults to OFF if not loaded yet or unknown.
    func isEnabled(_ key: String) -> Bool {
        flags[key]?.isEnabled ?? false
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
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            async let adminTask = repository.isSystemAdmin()
            async let flagsTask = repository.fetchFlags()
            let (admin, flagList) = try await (adminTask, flagsTask)
            isSystemAdmin = admin
            var map: [String: SystemFeatureFlag] = [:]
            for flag in flagList { map[flag.key] = flag }
            flags = map
            lastLoadedAt = Date()
        } catch {
            lastError = error.localizedDescription
            isSystemAdmin = false
        }
    }

    /// Toggle a flag remotely (system admins only). Updates local cache
    /// optimistically and reloads from Supabase on completion.
    @discardableResult
    func setFlag(key: String, isEnabled: Bool) async -> Bool {
        guard isSystemAdmin else {
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
        isSystemAdmin = false
        flags = [:]
        lastError = nil
        lastLoadedAt = nil
    }
}
