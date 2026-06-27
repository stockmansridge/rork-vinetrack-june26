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

    // MARK: - Saved chemicals

    func addSavedChemical(_ chemical: SavedChemical) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = chemical
        item.vineyardId = vineyardId
        savedChemicals.append(item)
        sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
        onSavedChemicalChanged?(item.id)
    }

    func updateSavedChemical(_ chemical: SavedChemical) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let idx = savedChemicals.firstIndex(where: { $0.id == chemical.id }) else { return }
        savedChemicals[idx] = chemical
        sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
        onSavedChemicalChanged?(chemical.id)
    }

    func deleteSavedChemical(_ chemical: SavedChemical) {
        guard let vineyardId = selectedVineyardId else { return }
        savedChemicals.removeAll { $0.id == chemical.id }
        sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
        onSavedChemicalDeleted?(chemical.id)
    }

    /// Removes the chemical from local state without queuing another remote
    /// delete (used after the backend RPC has already archived/hard-deleted it).
    func removeSavedChemicalLocallyOnly(_ id: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        guard savedChemicals.contains(where: { $0.id == id }) else { return }
        savedChemicals.removeAll { $0.id == id }
        sprayRepo.saveChemicalsSlice(savedChemicals, for: vineyardId)
    }

    /// Best-effort local check for whether a saved chemical has been used in
    /// any spray record on this device. The Supabase RPC remains the final
    /// authority — this is only used to decide whether to surface the
    /// "Delete Permanently" option in the UI.
    func isSavedChemicalInUseLocally(_ id: UUID) -> Bool {
        for record in sprayRecords {
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
            if let idx = savedChemicals.firstIndex(where: { $0.id == chemical.id }) {
                savedChemicals[idx] = chemical
            } else {
                savedChemicals.append(chemical)
            }
            sprayRepo.saveChemicalsSlice(savedChemicals, for: chemical.vineyardId)
        } else {
            var all = sprayRepo.loadAllChemicals()
            if let idx = all.firstIndex(where: { $0.id == chemical.id }) {
                all[idx] = chemical
            } else {
                all.append(chemical)
            }
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
