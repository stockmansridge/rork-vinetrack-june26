import Foundation
import Observation

/// In-memory cache + lightweight sync service for vineyard-scoped custom Trip
/// Functions. Backed by `public.vineyard_trip_functions` via
/// `SupabaseVineyardTripFunctionRepository`.
///
/// Built-in trip functions live in the `TripFunction` enum and are NOT
/// managed by this service.
@Observable
@MainActor
final class VineyardTripFunctionService {

    /// All trip functions for the currently loaded vineyard, including
    /// archived rows. UI is expected to filter on `isActive` /
    /// `deletedAt == nil` for selection menus.
    var functions: [VineyardTripFunction] = []

    /// Most recent error string from a fetch / mutate call. Cleared on each
    /// new operation that succeeds.
    var errorMessage: String?

    var isLoading: Bool = false

    private let repository: SupabaseVineyardTripFunctionRepository
    private(set) var loadedVineyardId: UUID?

    init(repository: SupabaseVineyardTripFunctionRepository = SupabaseVineyardTripFunctionRepository()) {
        self.repository = repository
    }

    /// Active, non-deleted trip functions for the currently loaded vineyard,
    /// sorted alphabetically by label (case-insensitive).
    var activeSortedByLabel: [VineyardTripFunction] {
        functions
            .filter { $0.isActive && $0.deletedAt == nil }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Look up the display label for a custom slug stored on a trip
    /// (e.g. `trip_function = "custom:rolling"`). Returns nil when the slug
    /// is unknown for the loaded vineyard (e.g. archived in another client
    /// without a refresh).
    func label(forCustomSlug slug: String) -> String? {
        functions.first(where: { $0.slug == slug })?.label
    }

    func reset() {
        functions = []
        loadedVineyardId = nil
        errorMessage = nil
    }

    /// Refresh the cache from Supabase. Safe to call repeatedly; if Supabase
    /// is unconfigured or the user has no role yet, this no-ops with an
    /// error message instead of throwing.
    func refresh(vineyardId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try await repository.fetchAll(vineyardId: vineyardId)
            functions = items
            loadedVineyardId = vineyardId
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Insert or update a custom trip function. The caller is expected to
    /// gate this on `BackendAccessControl.canChangeSettings`; RLS enforces
    /// the same rule on the server.
    @discardableResult
    func upsert(_ item: VineyardTripFunction) async -> Bool {
        do {
            try await repository.upsert(item)
            errorMessage = nil
            // Update local cache.
            if let idx = functions.firstIndex(where: { $0.id == item.id }) {
                functions[idx] = item
            } else {
                functions.append(item)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Soft-delete (archive) a custom trip function via the
    /// `archive_vineyard_trip_function` RPC.
    @discardableResult
    func archive(id: UUID) async -> Bool {
        do {
            try await repository.archive(id: id)
            if let idx = functions.firstIndex(where: { $0.id == id }) {
                var updated = functions[idx]
                updated.isActive = false
                updated.deletedAt = Date()
                functions[idx] = updated
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Restore a previously-archived custom trip function via the
    /// `restore_vineyard_trip_function` RPC.
    @discardableResult
    func restore(id: UUID) async -> Bool {
        do {
            try await repository.restore(id: id)
            if let idx = functions.firstIndex(where: { $0.id == id }) {
                var updated = functions[idx]
                updated.isActive = true
                updated.deletedAt = nil
                functions[idx] = updated
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
