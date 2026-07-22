import Foundation
import Observation

/// Financial sync service for `trip_cost_allocations`. Owners/managers only —
/// non-financial roles get an empty result set from RLS and the service no-ops
/// fetching / pushing if `canViewCosting` is false.
@Observable
@MainActor
final class TripCostAllocationSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private weak var accessControl: BackendAccessControl?
    private let repository: any TripCostAllocationSyncRepositoryProtocol
    private let metadata: ManagementSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any TripCostAllocationSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseTripCostAllocationSyncRepository()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_trip_cost_allocation_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService, accessControl: BackendAccessControl) {
        self.store = store
        self.auth = auth
        self.accessControl = accessControl
        guard !isConfigured else { return }
        isConfigured = true
        store.onTripCostAllocationChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onTripCostAllocationDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

    /// Hard request from the recalculation flow to soft-delete every active
    /// allocation row for `tripId` on Supabase before pushing fresh rows.
    /// Owner/manager only; no-ops for non-financial roles.
    func softDeleteAllocations(forTripId tripId: UUID) async {
        guard accessControl?.canViewCosting == true else { return }
        guard SupabaseClientProvider.shared.isConfigured else { return }
        do {
            try await repository.softDeleteForTrip(tripId: tripId)
        } catch {
            #if DEBUG
            print("[TripCostAllocationSync] bulk soft-delete failed for trip \(tripId): \(error)")
            #endif
        }
    }

    func syncForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        // Owner/manager only — RLS would also block this but we short-circuit
        // to avoid leaking pending state for roles that can't view costing.
        guard accessControl?.canViewCosting == true else {
            syncStatus = .idle
            return
        }
        await sync(vineyardId: vineyardId)
    }

    func sync(vineyardId: UUID) async {
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        guard accessControl?.canViewCosting == true else {
            syncStatus = .idle
            return
        }
        syncStatus = .syncing
        errorMessage = nil
        do {
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.tripCostAllocations.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendTripCostAllocationUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendTripCostAllocation.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertMany(payloads)
                metadata.clearDirty(pushed)
            }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                let message = String(describing: error).lowercased()
                if message.contains("not found") || message.contains("pgrst116") || message.contains("0 rows") {
                    metadata.clearDeleted([id])
                }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteTripCostAllocationDelete(item.id)
                metadata.clearDirty([item.id])
                metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteTripCostAllocationUpsert(item.toTripCostAllocation())
            metadata.clearDirty([item.id])
        }
    }
}
