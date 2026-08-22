import Foundation
import Observation

/// Sync + offline cache for portal-managed spray templates
/// (`public.spray_jobs` with `is_template = true`).
///
/// Kept deliberately separate from `MigratedDataStore.sprayRecords` /
/// `SprayRecordSyncService` so portal templates:
///   * are never pushed back into `spray_records`,
///   * never appear as operational/completed spray records or trip history.
///
/// A Program Step is a SHARED vineyard resource: the portal and mobile edit the
/// same `spray_jobs` row. `updateProgramStep` writes that row IN PLACE and then
/// patches this cache, so the change is visible immediately without a local
/// duplicate ever existing. There is no offline mutation queue here — a write
/// either reaches `spray_jobs` or it fails loudly.
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

    /// Update one existing portal Program Step and reflect it locally.
    ///
    /// Ordering matters: the server write happens FIRST and the cache is patched
    /// only from what the server confirms. Optimistically patching, then writing,
    /// would leave a rejected save looking successful — the one outcome this
    /// path must never produce.
    ///
    /// The row keeps its id, its vineyard and `is_template = true`; the payload
    /// simply does not contain them.
    @discardableResult
    func updateProgramStep(
        id: UUID,
        payload: BackendSprayJobTemplateUpdate
    ) async throws -> BackendSprayJobTemplate {
        guard let vineyardId = store?.selectedVineyardId else {
            throw SprayProgramStepWriteError.noVineyardSelected
        }
        let saved = try await repository.updateTemplate(
            id: id,
            vineyardId: vineyardId,
            payload: payload
        )
        applyLocalUpdate(saved, vineyardId: vineyardId)
        return saved
    }

    /// Replace one cached row in place and re-persist the offline cache.
    ///
    /// A replacement, never an append: an id already in the list is the SAME
    /// Program Step, and adding a second entry for it is precisely the duplicate
    /// this design exists to prevent.
    func applyLocalUpdate(_ row: BackendSprayJobTemplate, vineyardId: UUID) {
        let rows = Self.patched(templates, with: row)
        guard rows.count == templates.count else { return }
        apply(rows, vineyardId: vineyardId)
        persistence.save(rows, key: Self.cacheKey(vineyardId))
    }

    /// Replace the row with the same id, in place.
    ///
    /// Pure so the rule can be proven without a store, a network or a cache. It
    /// is a REPLACEMENT and never an append: an id already in the list is the
    /// same Program Step, and adding a second entry for it would put a duplicate
    /// in front of the operator — the exact outcome editing the shared row is
    /// meant to avoid. An unknown id changes nothing.
    nonisolated static func patched(
        _ rows: [BackendSprayJobTemplate],
        with row: BackendSprayJobTemplate
    ) -> [BackendSprayJobTemplate] {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return rows }
        var updated = rows
        updated[index] = row
        return updated
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
