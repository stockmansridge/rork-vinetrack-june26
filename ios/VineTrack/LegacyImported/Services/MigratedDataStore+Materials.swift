import Foundation

/// applyRemote helpers for Work Task Material Costs (sql/247).
///
/// Mirrors `MigratedDataStore+Operations` exactly: update in-memory state and
/// the on-disk slice WITHOUT re-firing the corresponding sync hook, so a pull
/// can never re-queue the row it just received.
extension MigratedDataStore {

    // MARK: - Base catalogue (global, pull only)

    /// Replace the cached base catalogue with an authoritative server read.
    ///
    /// The catalogue is not vineyard scoped, so there is a single slice. An
    /// empty read is refused by the repository rather than blanking every
    /// picker — the bundled `MaterialCatalogueSeed` stays in effect.
    func applyRemoteMaterialCatalogue(_ items: [MaterialCatalogueItem]) {
        guard !items.isEmpty else { return }
        materialCatalogueRepo.replace(items)
        materialCatalogue = materialCatalogueRepo.loadEffective()
    }

    // MARK: - Vineyard material library

    func applyRemoteVineyardMaterialUpsert(_ material: VineyardMaterial) {
        if selectedVineyardId == material.vineyardId {
            if let idx = vineyardMaterials.firstIndex(where: { $0.id == material.id }) {
                vineyardMaterials[idx] = material
            } else {
                vineyardMaterials.append(material)
            }
            vineyardMaterialRepo.saveSlice(vineyardMaterials, for: material.vineyardId)
        } else {
            var all = vineyardMaterialRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == material.id }) {
                all[idx] = material
            } else {
                all.append(material)
            }
            vineyardMaterialRepo.replace(all.filter { $0.vineyardId == material.vineyardId }, for: material.vineyardId)
        }
    }

    /// Remove a library row the server reports as soft-deleted.
    ///
    /// Deliberately does NOT touch `workTaskMaterials`: a retired or removed
    /// library material must never delete, hide or alter the historical task
    /// lines that used it. Those lines read entirely from their own snapshot.
    func applyRemoteVineyardMaterialDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            vineyardMaterials.removeAll { $0.id == id }
            vineyardMaterialRepo.saveSlice(vineyardMaterials, for: vineyardId)
        }
        var all = vineyardMaterialRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            vineyardMaterialRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Work Task material lines

    /// Merge one server line by id.
    ///
    /// Because an offline-created line already carries its FINAL id, receiving
    /// it back after replay updates the same row instead of appending a second
    /// material line.
    func applyRemoteWorkTaskMaterialUpsert(_ material: WorkTaskMaterial) {
        if selectedVineyardId == material.vineyardId {
            if let idx = workTaskMaterials.firstIndex(where: { $0.id == material.id }) {
                workTaskMaterials[idx] = material
            } else {
                workTaskMaterials.append(material)
            }
            workTaskMaterialRepo.saveSlice(workTaskMaterials, for: material.vineyardId)
        } else {
            var all = workTaskMaterialRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == material.id }) {
                all[idx] = material
            } else {
                all.append(material)
            }
            workTaskMaterialRepo.replace(all.filter { $0.vineyardId == material.vineyardId }, for: material.vineyardId)
        }
    }

    func applyRemoteWorkTaskMaterialDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            workTaskMaterials.removeAll { $0.id == id }
            workTaskMaterialRepo.saveSlice(workTaskMaterials, for: vineyardId)
        }
        var all = workTaskMaterialRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            workTaskMaterialRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }
}
