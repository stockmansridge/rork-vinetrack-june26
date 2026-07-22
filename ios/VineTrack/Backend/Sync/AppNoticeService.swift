import Foundation
import Observation

/// Manages app-wide information notices: fetching active notices from
/// Supabase, exposing them to the Home banner, and tracking per-device
/// dismissals via UserDefaults.
@Observable
@MainActor
final class AppNoticeService {

    enum Status: Equatable, Sendable {
        case idle
        case loading
        case success
        case failure(String)
    }

    var status: Status = .idle
    var activeNotices: [BackendAppNotice] = []
    var allNotices: [BackendAppNotice] = []
    var lastRefresh: Date?

    private weak var auth: NewBackendAuthService?
    private let repository: any AppNoticeRepositoryProtocol

    private let dismissedKey = "appNotices.dismissedIds.v1"

    init(repository: (any AppNoticeRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseAppNoticeRepository()
    }

    func configure(auth: NewBackendAuthService) {
        self.auth = auth
    }

    // MARK: - Dismissals (local-only)

    private var dismissedIds: Set<String> {
        get {
            let raw = UserDefaults.standard.array(forKey: dismissedKey) as? [String] ?? []
            return Set(raw)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: dismissedKey)
        }
    }

    func isDismissed(_ id: UUID) -> Bool {
        dismissedIds.contains(id.uuidString)
    }

    func dismiss(_ id: UUID) {
        var ids = dismissedIds
        ids.insert(id.uuidString)
        dismissedIds = ids
        // Drop from in-memory active list so the banner updates instantly.
        activeNotices.removeAll { $0.id == id }
    }

    /// For admin/debug use: clear local dismissals so all active notices
    /// become visible again on this device.
    func clearLocalDismissals() {
        dismissedIds = []
    }

    // MARK: - Visible

    /// Notices the current device should display — active, in-window, and
    /// not previously dismissed on this device — ordered by priority then
    /// recency.
    var visibleNotices: [BackendAppNotice] {
        let dismissed = dismissedIds
        return activeNotices
            .filter { !dismissed.contains($0.id.uuidString) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
            }
    }

    // MARK: - Refresh

    /// Pulls the currently-active notices for the home banner.
    func refresh() async {
        guard let auth, auth.isSignedIn,
              SupabaseClientProvider.shared.isConfigured else { return }
        status = .loading
        do {
            activeNotices = try await repository.fetchActiveNotices()
            lastRefresh = Date()
            status = .success
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    /// Pulls every notice (active + archived) for the admin management list.
    func refreshAll() async {
        guard let auth, auth.isSignedIn,
              SupabaseClientProvider.shared.isConfigured else { return }
        do {
            allNotices = try await repository.fetchAllNotices()
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    // MARK: - Mutations

    func upsert(_ notice: BackendAppNotice) async throws {
        let payload = AppNoticeUpsert(
            id: notice.id,
            title: notice.title,
            message: notice.message,
            noticeType: notice.noticeType,
            priority: notice.priority,
            startsAt: notice.startsAt,
            endsAt: notice.endsAt,
            isActive: notice.isActive,
            createdBy: notice.createdBy ?? auth?.userId,
            updatedBy: auth?.userId,
            deletedAt: notice.deletedAt,
            clientUpdatedAt: Date()
        )
        try await repository.upsertNotice(payload)
        await refreshAll()
        await refresh()
    }

    func softDelete(id: UUID) async throws {
        try await repository.softDeleteNotice(id: id, updatedBy: auth?.userId)
        await refreshAll()
        await refresh()
    }
}
