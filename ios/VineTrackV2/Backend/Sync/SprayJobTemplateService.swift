import Foundation
import Observation

/// Read-only sync + offline cache for portal-managed spray templates
/// (`public.spray_jobs` with `is_template = true`).
///
/// Kept deliberately separate from `MigratedDataStore.sprayRecords` /
/// `SprayRecordSyncService` so portal templates:
///   * are never pushed back into `spray_records`,
///   * never appear as operational/completed spray records or trip history,
///   * cannot be edited or deleted from mobile.
///
/// Templates are surfaced through `templateRecords` (mapped to in-memory
/// `SprayRecord` values) so the existing template pickers and calculator
/// prefill flow work without modification.
@Observable
@MainActor
final class SprayJobTemplateService {

    /// Raw portal template rows for the currently hydrated vineyard.
    private(set) var templates: [BackendSprayJobTemplate] = []
    /// Templates mapped to read-only `SprayRecord` values for the pickers.
    /// Cached so repeated view-body reads return identical values.
    private(set) var templateRecords: [SprayRecord] = []

    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: SupabaseSprayJobTemplateRepository
    private let persistence: PersistenceStore
    private var hydratedVineyardId: UUID?

    init(
        repository: SupabaseSprayJobTemplateRepository = SupabaseSprayJobTemplateRepository(),
        persistence: PersistenceStore = .shared
    ) {
        self.repository = repository
        self.persistence = persistence
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
    }

    /// Hydrate from the offline cache for a vineyard (no network). Called on
    /// vineyard selection and by the template pickers so Lovable templates
    /// stay available after first sync even when the device is offline.
    func loadCached(for vineyardId: UUID?) {
        guard let vineyardId, hydratedVineyardId != vineyardId else { return }
        let cached: [BackendSprayJobTemplate] = persistence.load(key: Self.cacheKey(vineyardId)) ?? []
        apply(cached, vineyardId: vineyardId)
    }

    /// Pull the latest templates for the selected vineyard. Failures keep the
    /// last good (cached) list — templates never blank out on a bad fetch.
    func syncForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        loadCached(for: vineyardId)
        do {
            let remote = try await repository.fetchTemplates(vineyardId: vineyardId)
            apply(remote, vineyardId: vineyardId)
            persistence.save(remote, key: Self.cacheKey(vineyardId))
            lastSyncDate = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            #if DEBUG
            print("[SprayJobTemplateService] fetch failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func apply(_ rows: [BackendSprayJobTemplate], vineyardId: UUID) {
        templates = rows
        templateRecords = rows.map { $0.toSprayRecord() }
        hydratedVineyardId = vineyardId
    }

    private static func cacheKey(_ vineyardId: UUID) -> String {
        "vinetrack_spray_job_templates_\(vineyardId.uuidString)"
    }
}
