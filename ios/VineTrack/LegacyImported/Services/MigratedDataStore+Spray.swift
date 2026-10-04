import Foundation

extension MigratedDataStore {

    // MARK: - Convenience accessors used by imported spray views

    var seasonFuelCostPerLitre: Double {
        settings.seasonFuelCostPerLitre
    }

    func operatorCategoryForName(_ name: String) -> OperatorCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return operatorCategories.first { $0.name.lowercased() == trimmed.lowercased() }
    }

    // MARK: - SprayRecord overload

    func deleteSprayRecord(_ record: SprayRecord) {
        deleteSprayRecord(record.id)
    }

    /// Hides a manual application after its coordinated delete has been durably
    /// queued. This deliberately does not enter the generic spray delete outbox.
    func removeManualSprayLocallyOnly(_ record: SprayRecord) {
        guard record.isManualEntry, let vineyardId = selectedVineyardId else { return }
        sprayRecords.removeAll { $0.id == record.id }
        sprayRepo.saveRecordsSlice(sprayRecords, for: vineyardId)
        trips.removeAll { $0.id == record.tripId }
    }

    // MARK: - Saved chemicals

    func addSavedChemical(_ chemical: SavedChemical) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = chemical
        if let intelligence = item.chemicalIntelligence {
            guard let canonical = ChemicalLabelRateNormalizer.normalize(intelligence) else { return }
            item.chemicalIntelligence = canonical
        }
        item.vineyardId = vineyardId
        guard !sprayRepo.loadAllChemicals().contains(where: { $0.id == item.id }) else { return }
        // Durably identify a real CREATE; disk presence and generic edits are insufficient.
        onSavedChemicalCreated?(item.id)
        savedChemicals.append(item)
        sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
    }

    func updateSavedChemical(_ chemical: SavedChemical) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let idx = savedChemicals.firstIndex(where: { $0.id == chemical.id }) else { return }
        var item = chemical
        if let intelligence = item.chemicalIntelligence {
            guard let canonical = ChemicalLabelRateNormalizer.normalize(intelligence) else { return }
            item.chemicalIntelligence = canonical
        }
        if savedChemicals[idx].vineyardPreferredRatePending && !item.vineyardPreferredRatePending {
            item.vineyardPreferredRate = savedChemicals[idx].vineyardPreferredRate
            item.vineyardPreferredRatePending = true
        }
        item.vineyardPreferredRateOnly = false
        item.savedChemicalGeneralPending = true
        savedChemicals[idx] = item
        sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
        onSavedChemicalChanged?(item.id)
    }

    /// Queues an operational preference independently of catalogue/default-rate fields.
    func setVineyardPreferredRate(_ rate: VineyardPreferredRate?, chemicalId: UUID) {
        guard rate == nil || rate?.isValid == true,
              let vineyardId = selectedVineyardId,
              let index = savedChemicals.firstIndex(where: { $0.id == chemicalId && $0.vineyardId == vineyardId && $0.isActive }) else { return }
        var item = savedChemicals[index]
        item.vineyardPreferredRate = rate
        let hasOlderGeneralWrite = (savedChemicalHasPendingWrite?(item.id) ?? false) && !item.vineyardPreferredRateOnly
        item.vineyardPreferredRateOnly = !item.savedChemicalGeneralPending && !hasOlderGeneralWrite
        item.vineyardPreferredRatePending = true
        savedChemicals[index] = item
        sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
        onSavedChemicalChanged?(item.id)
    }

    func deleteSavedChemical(_ chemical: SavedChemical) {
        guard let vineyardId = selectedVineyardId else { return }
        savedChemicals.removeAll { $0.id == chemical.id }
        sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
        onSavedChemicalDeleted?(chemical.id)
    }

    /// Retains an archived row for historical resolution without queuing an upsert.
    func archiveSavedChemicalLocallyOnly(_ id: UUID, vineyardId: UUID? = nil) {
        guard let vineyard = vineyardId ?? selectedVineyardId else { return }
        let rows = selectedVineyardId == vineyard ? savedChemicals : sprayRepo.loadChemicals(for: vineyard)
        guard rows.contains(where: { $0.id == id }) else { return }
        onSavedChemicalRetired?(id)
        let archived = rows.map { $0.id == id ? ChemicalStorePresentation.archived($0) : $0 }
        sprayRepo.saveChemicalsSlice(archived, for: vineyard)
        if selectedVineyardId == vineyard { savedChemicals = archived }
    }

    /// Removes the chemical from local state without queuing another remote
    /// delete (used after the backend RPC has already archived/hard-deleted it).
    func removeSavedChemicalLocallyOnly(_ id: UUID, vineyardId: UUID? = nil) {
        guard let vineyard = vineyardId ?? selectedVineyardId else { return }
        let rows = selectedVineyardId == vineyard ? savedChemicals : sprayRepo.loadChemicals(for: vineyard)
        guard rows.contains(where: { $0.id == id }) else { return }
        if isSavedChemicalInUseLocally(id) {
            archiveSavedChemicalLocallyOnly(id, vineyardId: vineyard)
            return
        }
        onSavedChemicalRetired?(id)
        let retained = rows.filter { $0.id != id }
        sprayRepo.saveChemicalsSlice(retained, for: vineyard)
        if selectedVineyardId == vineyard { savedChemicals = retained }
    }

    /// Best-effort local check for whether a saved chemical has been used in
    /// any spray record on this device. The Supabase RPC remains the final
    /// authority — this is only used to decide whether to surface the
    /// "Delete Permanently" option in the UI.
    func isSavedChemicalInUseLocally(_ id: UUID) -> Bool {
        for record in sprayRepo.loadAllRecords() + sprayRecords {
            for tank in record.tanks {
                if tank.chemicals.contains(where: { $0.savedChemicalId == id }) {
                    return true
                }
            }
        }
        return false
    }

    func applyRemoteSavedChemicalUpsert(_ chemical: SavedChemical) {
        if selectedVineyardId == chemical.vineyardId {
            savedChemicals.removeAll { $0.id == chemical.id }
            savedChemicals.append(chemical)
            sprayRepo.saveChemicalsSlice(savedChemicals, for: chemical.vineyardId)
        } else {
            var all = sprayRepo.loadAllChemicals()
            all.removeAll { $0.id == chemical.id }
            all.append(chemical)
            sprayRepo.replaceChemicals(all.filter { $0.vineyardId == chemical.vineyardId }, for: chemical.vineyardId)
        }
    }

    func applyRemoteSavedChemicalDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            savedChemicals.removeAll { $0.id == id }
            sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
        }
        var all = sprayRepo.loadAllChemicals()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            sprayRepo.replaceChemicals(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Saved spray presets

    func addSavedSprayPreset(_ preset: SavedSprayPreset) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = preset
        item.vineyardId = vineyardId
        savedSprayPresets.append(item)
        sprayRepo.savePresetsSlice(savedSprayPresets, for: vineyardId)
        onSavedSprayPresetChanged?(item.id)
    }

    func updateSavedSprayPreset(_ preset: SavedSprayPreset) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let idx = savedSprayPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        savedSprayPresets[idx] = preset
        sprayRepo.savePresetsSlice(savedSprayPresets, for: vineyardId)
        onSavedSprayPresetChanged?(preset.id)
    }

    func deleteSavedSprayPreset(_ preset: SavedSprayPreset) {
        guard let vineyardId = selectedVineyardId else { return }
        savedSprayPresets.removeAll { $0.id == preset.id }
        sprayRepo.savePresetsSlice(savedSprayPresets, for: vineyardId)
        onSavedSprayPresetDeleted?(preset.id)
    }

    func applyRemoteSavedSprayPresetUpsert(_ preset: SavedSprayPreset) {
        if selectedVineyardId == preset.vineyardId {
            if let idx = savedSprayPresets.firstIndex(where: { $0.id == preset.id }) {
                savedSprayPresets[idx] = preset
            } else {
                savedSprayPresets.append(preset)
            }
            sprayRepo.savePresetsSlice(savedSprayPresets, for: preset.vineyardId)
        } else {
            var all = sprayRepo.loadAllPresets()
            if let idx = all.firstIndex(where: { $0.id == preset.id }) {
                all[idx] = preset
            } else {
                all.append(preset)
            }
            sprayRepo.replacePresets(all.filter { $0.vineyardId == preset.vineyardId }, for: preset.vineyardId)
        }
    }

    func applyRemoteSavedSprayPresetDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            savedSprayPresets.removeAll { $0.id == id }
            sprayRepo.savePresetsSlice(savedSprayPresets, for: vineyardId)
        }
        var all = sprayRepo.loadAllPresets()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            sprayRepo.replacePresets(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Equipment options (autocomplete entries)

    func equipmentOptions(for category: String) -> [SavedEquipmentOption] {
        savedEquipmentOptions
            .filter { $0.category == category }
            .sorted { $0.value.lowercased() < $1.value.lowercased() }
    }

    func addEquipmentOption(_ option: SavedEquipmentOption) {
        guard let vineyardId = selectedVineyardId else { return }
        let trimmed = option.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if savedEquipmentOptions.contains(where: {
            $0.category == option.category && $0.value.lowercased() == trimmed.lowercased()
        }) {
            return
        }
        var item = option
        item.vineyardId = vineyardId
        item.value = trimmed
        savedEquipmentOptions.append(item)
        sprayRepo.saveEquipmentOptionsSlice(savedEquipmentOptions, for: vineyardId)
    }

    func deleteEquipmentOption(_ option: SavedEquipmentOption) {
        guard let vineyardId = selectedVineyardId else { return }
        savedEquipmentOptions.removeAll { $0.id == option.id }
        sprayRepo.saveEquipmentOptionsSlice(savedEquipmentOptions, for: vineyardId)
    }
}
