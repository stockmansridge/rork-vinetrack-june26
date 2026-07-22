import Foundation

extension MigratedDataStore {

    // MARK: - Trip Cost Allocation CRUD (owner/manager only — gate in UI)

    /// Replace all active allocations for `tripId` with `newRows`. Old rows
    /// for the trip are removed from the local store and a delete callback
    /// fires for each so the sync service can soft-delete on Supabase.
    /// New rows fire a change callback for upload.
    func replaceTripCostAllocations(tripId: UUID, with newRows: [TripCostAllocation]) {
        guard let vineyardId = selectedVineyardId else { return }
        let stale = tripCostAllocations.filter { $0.tripId == tripId }
        tripCostAllocations.removeAll { $0.tripId == tripId }
        tripCostAllocations.append(contentsOf: newRows)
        tripCostAllocationRepo.saveSlice(
            tripCostAllocations.filter { $0.vineyardId == vineyardId },
            for: vineyardId
        )
        for row in stale { onTripCostAllocationDeleted?(row.id) }
        for row in newRows { onTripCostAllocationChanged?(row.id) }
    }

    /// Soft-delete every allocation for `tripId` locally (and notify sync to
    /// remove them remotely). Used when a trip is deleted.
    func deleteTripCostAllocations(tripId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        let stale = tripCostAllocations.filter { $0.tripId == tripId }
        guard !stale.isEmpty else { return }
        tripCostAllocations.removeAll { $0.tripId == tripId }
        tripCostAllocationRepo.saveSlice(
            tripCostAllocations.filter { $0.vineyardId == vineyardId },
            for: vineyardId
        )
        for row in stale { onTripCostAllocationDeleted?(row.id) }
    }

    /// Purge every local allocation for `tripId` WITHOUT firing delete
    /// callbacks. Used when a trip deletion originated remotely: the server
    /// cascade already removes the allocations, so we only need the local
    /// cache to stay consistent (no re-propagation of a soft-delete).
    func purgeTripCostAllocationsLocally(tripId: UUID) {
        let stale = tripCostAllocations.filter { $0.tripId == tripId }
        guard !stale.isEmpty else { return }
        tripCostAllocations.removeAll { $0.tripId == tripId }
        var all = tripCostAllocationRepo.loadAll()
        all.removeAll { $0.tripId == tripId }
        let byVineyard = Dictionary(grouping: all, by: { $0.vineyardId })
        for (vid, rows) in byVineyard {
            tripCostAllocationRepo.replace(rows, for: vid)
        }
        if let selected = selectedVineyardId {
            tripCostAllocationRepo.saveSlice(
                tripCostAllocations.filter { $0.vineyardId == selected },
                for: selected
            )
        }
    }

    func applyRemoteTripCostAllocationUpsert(_ row: TripCostAllocation) {
        if selectedVineyardId == row.vineyardId {
            if let idx = tripCostAllocations.firstIndex(where: { $0.id == row.id }) {
                tripCostAllocations[idx] = row
            } else {
                tripCostAllocations.append(row)
            }
            tripCostAllocationRepo.saveSlice(
                tripCostAllocations.filter { $0.vineyardId == row.vineyardId },
                for: row.vineyardId
            )
        } else {
            var all = tripCostAllocationRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == row.id }) {
                all[idx] = row
            } else {
                all.append(row)
            }
            tripCostAllocationRepo.replace(
                all.filter { $0.vineyardId == row.vineyardId },
                for: row.vineyardId
            )
        }
    }

    func applyRemoteTripCostAllocationDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            tripCostAllocations.removeAll { $0.id == id }
            tripCostAllocationRepo.saveSlice(
                tripCostAllocations.filter { $0.vineyardId == vineyardId },
                for: vineyardId
            )
        }
        var all = tripCostAllocationRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            tripCostAllocationRepo.replace(
                all.filter { $0.vineyardId == removed.vineyardId },
                for: removed.vineyardId
            )
        }
    }
}
