import Foundation

extension MigratedDataStore {

    // MARK: - Saved Inputs CRUD

    func addSavedInput(_ input: SavedInput) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = input
        item.vineyardId = vineyardId
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Case-insensitive de-dupe within the current vineyard.
        if savedInputs.contains(where: {
            $0.vineyardId == vineyardId &&
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed.lowercased()
        }) { return }
        savedInputs.append(item)
        savedInputRepo.saveSlice(savedInputs, for: vineyardId)
        onSavedInputChanged?(item.id)
    }

    func updateSavedInput(_ input: SavedInput) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let idx = savedInputs.firstIndex(where: { $0.id == input.id }) else { return }
        savedInputs[idx] = input
        savedInputRepo.saveSlice(savedInputs, for: vineyardId)
        onSavedInputChanged?(input.id)
    }

    func deleteSavedInput(_ input: SavedInput) {
        guard let vineyardId = selectedVineyardId else { return }
        savedInputs.removeAll { $0.id == input.id }
        savedInputRepo.saveSlice(savedInputs, for: vineyardId)
        onSavedInputDeleted?(input.id)
    }

    func applyRemoteSavedInputUpsert(_ input: SavedInput) {
        if selectedVineyardId == input.vineyardId {
            if let idx = savedInputs.firstIndex(where: { $0.id == input.id }) {
                savedInputs[idx] = input
            } else {
                savedInputs.append(input)
            }
            savedInputRepo.saveSlice(savedInputs, for: input.vineyardId)
        } else {
            var all = savedInputRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == input.id }) {
                all[idx] = input
            } else {
                all.append(input)
            }
            savedInputRepo.replace(all.filter { $0.vineyardId == input.vineyardId }, for: input.vineyardId)
        }
    }

    func applyRemoteSavedInputDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            savedInputs.removeAll { $0.id == id }
            savedInputRepo.saveSlice(savedInputs, for: vineyardId)
        }
        var all = savedInputRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            savedInputRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }
}
