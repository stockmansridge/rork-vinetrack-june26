import Foundation

extension MigratedDataStore {

    // MARK: - Persistence keys (mirrors private keys in MigratedDataStore.swift)

    private enum MgmtKeys {
        static let paddocks = "vinetrack_paddocks"
        static let tractors = "vinetrack_tractors"
        static let vineyardMachines = "vinetrack_vineyard_machines"
        static let fuelPurchases = "vinetrack_fuel_purchases"
        static let tractorFuelLogs = "vinetrack_tractor_fuel_logs"
        static let operatorCategories = "vinetrack_operator_categories"
        static let buttonTemplates = "vinetrack_button_templates"
        static let grapeVarieties = "vinetrack_grape_varieties"
    }

    private var persistenceStore: PersistenceStore { .shared }

    // MARK: - Spray Equipment

    func addSprayEquipment(_ item: SprayEquipmentItem) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = item
        entry.vineyardId = vineyardId
        sprayEquipment.append(entry)
        sprayRepo.saveEquipmentSlice(sprayEquipment, for: vineyardId)
        onSprayEquipmentChanged?(entry.id)
    }

    func updateSprayEquipment(_ item: SprayEquipmentItem) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let idx = sprayEquipment.firstIndex(where: { $0.id == item.id }) else { return }
        sprayEquipment[idx] = item
        sprayRepo.saveEquipmentSlice(sprayEquipment, for: vineyardId)
        onSprayEquipmentChanged?(item.id)
    }

    func deleteSprayEquipment(_ item: SprayEquipmentItem) {
        guard let vineyardId = selectedVineyardId else { return }
        sprayEquipment.removeAll { $0.id == item.id }
        sprayRepo.saveEquipmentSlice(sprayEquipment, for: vineyardId)
        onSprayEquipmentDeleted?(item.id)
    }

    func applyRemoteSprayEquipmentUpsert(_ item: SprayEquipmentItem) {
        if selectedVineyardId == item.vineyardId {
            if let idx = sprayEquipment.firstIndex(where: { $0.id == item.id }) {
                sprayEquipment[idx] = item
            } else {
                sprayEquipment.append(item)
            }
            sprayRepo.saveEquipmentSlice(sprayEquipment, for: item.vineyardId)
        } else {
            var all = sprayRepo.loadAllEquipment()
            if let idx = all.firstIndex(where: { $0.id == item.id }) {
                all[idx] = item
            } else {
                all.append(item)
            }
            sprayRepo.replaceEquipment(all.filter { $0.vineyardId == item.vineyardId }, for: item.vineyardId)
        }
    }

    func applyRemoteSprayEquipmentDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            sprayEquipment.removeAll { $0.id == id }
            sprayRepo.saveEquipmentSlice(sprayEquipment, for: vineyardId)
        }
        var all = sprayRepo.loadAllEquipment()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            sprayRepo.replaceEquipment(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Tractors

    private func saveTractorsToDisk() {
        guard let vineyardId = selectedVineyardId else { return }
        var all: [Tractor] = persistenceStore.load(key: MgmtKeys.tractors) ?? []
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: tractors.filter { $0.vineyardId == vineyardId })
        persistenceStore.save(all, key: MgmtKeys.tractors)
    }

    func addTractor(_ tractor: Tractor) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = tractor
        entry.vineyardId = vineyardId
        tractors.append(entry)
        saveTractorsToDisk()
        onTractorChanged?(entry.id)
    }

    func updateTractor(_ tractor: Tractor) {
        guard let idx = tractors.firstIndex(where: { $0.id == tractor.id }) else { return }
        tractors[idx] = tractor
        saveTractorsToDisk()
        onTractorChanged?(tractor.id)
    }

    func deleteTractor(_ tractor: Tractor) {
        tractors.removeAll { $0.id == tractor.id }
        saveTractorsToDisk()
        onTractorDeleted?(tractor.id)
    }

    func applyRemoteTractorUpsert(_ tractor: Tractor) {
        if let idx = tractors.firstIndex(where: { $0.id == tractor.id }) {
            tractors[idx] = tractor
        } else {
            tractors.append(tractor)
        }
        var all: [Tractor] = persistenceStore.load(key: MgmtKeys.tractors) ?? []
        if let idx = all.firstIndex(where: { $0.id == tractor.id }) {
            all[idx] = tractor
        } else {
            all.append(tractor)
        }
        persistenceStore.save(all, key: MgmtKeys.tractors)
    }

    func applyRemoteTractorDelete(_ id: UUID) {
        tractors.removeAll { $0.id == id }
        var all: [Tractor] = persistenceStore.load(key: MgmtKeys.tractors) ?? []
        all.removeAll { $0.id == id }
        persistenceStore.save(all, key: MgmtKeys.tractors)
    }

    // MARK: - Vineyard Machines

    private func saveVineyardMachinesToDisk() {
        guard let vineyardId = selectedVineyardId else { return }
        var all: [VineyardMachine] = persistenceStore.load(key: MgmtKeys.vineyardMachines) ?? []
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: vineyardMachines.filter { $0.vineyardId == vineyardId })
        persistenceStore.save(all, key: MgmtKeys.vineyardMachines)
    }

    /// Active machines for the current vineyard, sorted by display name.
    func machines(ofType type: VineyardMachineType? = nil) -> [VineyardMachine] {
        vineyardMachines
            .filter { $0.vineyardId == selectedVineyardId && (type == nil || $0.machineType == type) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func addVineyardMachine(_ machine: VineyardMachine) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = machine
        entry.vineyardId = vineyardId
        vineyardMachines.append(entry)
        saveVineyardMachinesToDisk()
        onVineyardMachineChanged?(entry.id)
    }

    func updateVineyardMachine(_ machine: VineyardMachine) {
        guard let idx = vineyardMachines.firstIndex(where: { $0.id == machine.id }) else { return }
        vineyardMachines[idx] = machine
        saveVineyardMachinesToDisk()
        onVineyardMachineChanged?(machine.id)
    }

    func deleteVineyardMachine(_ machine: VineyardMachine) {
        vineyardMachines.removeAll { $0.id == machine.id }
        saveVineyardMachinesToDisk()
        onVineyardMachineDeleted?(machine.id)
    }

    func applyRemoteVineyardMachineUpsert(_ machine: VineyardMachine) {
        if let idx = vineyardMachines.firstIndex(where: { $0.id == machine.id }) {
            vineyardMachines[idx] = machine
        } else {
            vineyardMachines.append(machine)
        }
        var all: [VineyardMachine] = persistenceStore.load(key: MgmtKeys.vineyardMachines) ?? []
        if let idx = all.firstIndex(where: { $0.id == machine.id }) {
            all[idx] = machine
        } else {
            all.append(machine)
        }
        persistenceStore.save(all, key: MgmtKeys.vineyardMachines)
    }

    func applyRemoteVineyardMachineDelete(_ id: UUID) {
        vineyardMachines.removeAll { $0.id == id }
        var all: [VineyardMachine] = persistenceStore.load(key: MgmtKeys.vineyardMachines) ?? []
        all.removeAll { $0.id == id }
        persistenceStore.save(all, key: MgmtKeys.vineyardMachines)
    }

    // MARK: - Fuel Purchases

    private func saveFuelPurchasesToDisk() {
        guard let vineyardId = selectedVineyardId else { return }
        var all: [FuelPurchase] = persistenceStore.load(key: MgmtKeys.fuelPurchases) ?? []
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: fuelPurchases.filter { $0.vineyardId == vineyardId })
        persistenceStore.save(all, key: MgmtKeys.fuelPurchases)
    }

    func addFuelPurchase(_ purchase: FuelPurchase) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = purchase
        entry.vineyardId = vineyardId
        fuelPurchases.append(entry)
        saveFuelPurchasesToDisk()
        onFuelPurchaseChanged?(entry.id)
    }

    func updateFuelPurchase(_ purchase: FuelPurchase) {
        guard let idx = fuelPurchases.firstIndex(where: { $0.id == purchase.id }) else { return }
        fuelPurchases[idx] = purchase
        saveFuelPurchasesToDisk()
        onFuelPurchaseChanged?(purchase.id)
    }

    func deleteFuelPurchase(_ purchase: FuelPurchase) {
        fuelPurchases.removeAll { $0.id == purchase.id }
        saveFuelPurchasesToDisk()
        onFuelPurchaseDeleted?(purchase.id)
    }

    func applyRemoteFuelPurchaseUpsert(_ purchase: FuelPurchase) {
        if let idx = fuelPurchases.firstIndex(where: { $0.id == purchase.id }) {
            fuelPurchases[idx] = purchase
        } else {
            fuelPurchases.append(purchase)
        }
        var all: [FuelPurchase] = persistenceStore.load(key: MgmtKeys.fuelPurchases) ?? []
        if let idx = all.firstIndex(where: { $0.id == purchase.id }) {
            all[idx] = purchase
        } else {
            all.append(purchase)
        }
        persistenceStore.save(all, key: MgmtKeys.fuelPurchases)
    }

    func applyRemoteFuelPurchaseDelete(_ id: UUID) {
        fuelPurchases.removeAll { $0.id == id }
        var all: [FuelPurchase] = persistenceStore.load(key: MgmtKeys.fuelPurchases) ?? []
        all.removeAll { $0.id == id }
        persistenceStore.save(all, key: MgmtKeys.fuelPurchases)
    }

    // MARK: - Tractor Fuel Logs

    private func saveTractorFuelLogsToDisk() {
        guard let vineyardId = selectedVineyardId else { return }
        var all: [TractorFuelLog] = persistenceStore.load(key: MgmtKeys.tractorFuelLogs) ?? []
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: tractorFuelLogs.filter { $0.vineyardId == vineyardId })
        persistenceStore.save(all, key: MgmtKeys.tractorFuelLogs)
    }

    /// Fuel logs for the given tractor in the current vineyard, newest first.
    func fuelLogs(forTractor tractorId: UUID?) -> [TractorFuelLog] {
        tractorFuelLogs
            .filter { $0.vineyardId == selectedVineyardId && $0.tractorId == tractorId }
            .sorted { $0.fillDateTime > $1.fillDateTime }
    }

    /// The most recent fuel log for `tractorId` strictly earlier than
    /// `before`, used to derive a litres/hour rate for a new fill.
    func previousFuelLog(forTractor tractorId: UUID?, before date: Date, excluding id: UUID?) -> TractorFuelLog? {
        tractorFuelLogs
            .filter {
                $0.vineyardId == selectedVineyardId &&
                $0.tractorId == tractorId &&
                $0.id != id &&
                $0.fillDateTime < date
            }
            .max { $0.fillDateTime < $1.fillDateTime }
    }

    /// Resolves the vineyard machine a fuel log belongs to, preferring
    /// `machineId` and falling back to the legacy tractor link so that legacy
    /// rows (tractor-only) and new rows for the same machine group together.
    func machine(forFuelLog log: TractorFuelLog) -> VineyardMachine? {
        if let mid = log.machineId {
            return vineyardMachines.first { $0.id == mid && $0.vineyardId == log.vineyardId }
        }
        if let tid = log.tractorId {
            return vineyardMachines.first { $0.legacyTractorId == tid && $0.vineyardId == log.vineyardId }
        }
        return nil
    }

    /// Stable grouping key for a fuel log. Prefers the resolved machine, then a
    /// raw `machineId`, then the legacy `tractorId`, so display and L/hr
    /// calculation group by machine while still supporting legacy records.
    func fuelLogGroupKey(_ log: TractorFuelLog) -> String {
        if let m = machine(forFuelLog: log) { return "m:\(m.id.uuidString)" }
        if let mid = log.machineId { return "m:\(mid.uuidString)" }
        if let tid = log.tractorId { return "t:\(tid.uuidString)" }
        return "unassigned"
    }

    /// The most recent earlier fill belonging to the same machine group as
    /// `log`, used to derive a litres/hour rate for a new fill. Grouping
    /// prefers `machineId` and falls back to `tractorId` for legacy records.
    func previousFuelLog(forMachineGroupOf log: TractorFuelLog, before date: Date, excluding id: UUID?) -> TractorFuelLog? {
        let key = fuelLogGroupKey(log)
        return tractorFuelLogs
            .filter {
                $0.vineyardId == selectedVineyardId &&
                $0.id != id &&
                $0.fillDateTime < date &&
                fuelLogGroupKey($0) == key
            }
            .max { $0.fillDateTime < $1.fillDateTime }
    }

    func addTractorFuelLog(_ log: TractorFuelLog) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = log
        entry.vineyardId = vineyardId
        tractorFuelLogs.append(entry)
        saveTractorFuelLogsToDisk()
        onTractorFuelLogChanged?(entry.id)
    }

    func updateTractorFuelLog(_ log: TractorFuelLog) {
        guard let idx = tractorFuelLogs.firstIndex(where: { $0.id == log.id }) else { return }
        tractorFuelLogs[idx] = log
        saveTractorFuelLogsToDisk()
        onTractorFuelLogChanged?(log.id)
    }

    func deleteTractorFuelLog(_ log: TractorFuelLog) {
        tractorFuelLogs.removeAll { $0.id == log.id }
        saveTractorFuelLogsToDisk()
        onTractorFuelLogDeleted?(log.id)
    }

    func applyRemoteTractorFuelLogUpsert(_ log: TractorFuelLog) {
        if let idx = tractorFuelLogs.firstIndex(where: { $0.id == log.id }) {
            tractorFuelLogs[idx] = log
        } else {
            tractorFuelLogs.append(log)
        }
        var all: [TractorFuelLog] = persistenceStore.load(key: MgmtKeys.tractorFuelLogs) ?? []
        if let idx = all.firstIndex(where: { $0.id == log.id }) {
            all[idx] = log
        } else {
            all.append(log)
        }
        persistenceStore.save(all, key: MgmtKeys.tractorFuelLogs)
    }

    func applyRemoteTractorFuelLogDelete(_ id: UUID) {
        tractorFuelLogs.removeAll { $0.id == id }
        var all: [TractorFuelLog] = persistenceStore.load(key: MgmtKeys.tractorFuelLogs) ?? []
        all.removeAll { $0.id == id }
        persistenceStore.save(all, key: MgmtKeys.tractorFuelLogs)
    }

    // MARK: - Operator Categories

    private func saveOperatorCategoriesToDisk() {
        guard let vineyardId = selectedVineyardId else { return }
        var all: [OperatorCategory] = persistenceStore.load(key: MgmtKeys.operatorCategories) ?? []
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: operatorCategories.filter { $0.vineyardId == vineyardId })
        persistenceStore.save(all, key: MgmtKeys.operatorCategories)
    }

    func addOperatorCategory(_ category: OperatorCategory) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = category
        entry.vineyardId = vineyardId
        operatorCategories.append(entry)
        saveOperatorCategoriesToDisk()
        onOperatorCategoryChanged?(entry.id)
    }

    func updateOperatorCategory(_ category: OperatorCategory) {
        guard let idx = operatorCategories.firstIndex(where: { $0.id == category.id }) else { return }
        operatorCategories[idx] = category
        saveOperatorCategoriesToDisk()
        onOperatorCategoryChanged?(category.id)
    }

    func deleteOperatorCategory(_ category: OperatorCategory) {
        operatorCategories.removeAll { $0.id == category.id }
        saveOperatorCategoriesToDisk()
        onOperatorCategoryDeleted?(category.id)
    }

    func applyRemoteOperatorCategoryUpsert(_ category: OperatorCategory) {
        if let idx = operatorCategories.firstIndex(where: { $0.id == category.id }) {
            operatorCategories[idx] = category
        } else {
            operatorCategories.append(category)
        }
        var all: [OperatorCategory] = persistenceStore.load(key: MgmtKeys.operatorCategories) ?? []
        if let idx = all.firstIndex(where: { $0.id == category.id }) {
            all[idx] = category
        } else {
            all.append(category)
        }
        persistenceStore.save(all, key: MgmtKeys.operatorCategories)
    }

    func applyRemoteOperatorCategoryDelete(_ id: UUID) {
        operatorCategories.removeAll { $0.id == id }
        var all: [OperatorCategory] = persistenceStore.load(key: MgmtKeys.operatorCategories) ?? []
        all.removeAll { $0.id == id }
        persistenceStore.save(all, key: MgmtKeys.operatorCategories)
    }

    /// Replace a locally created operator category with the server's canonical
    /// row for the same (name, cost). Used when a push collides with the
    /// server's `uniq_worker_types_active_name_cost` unique index because
    /// another client created the same worker type under a different id.
    /// Member references are remapped from the local id to the server id.
    /// Deliberately does NOT fire `onOperatorCategoryChanged` — the adopted
    /// row is already the server's truth and must not re-enter the push queue.
    func adoptRemoteOperatorCategory(localId: UUID, remote: OperatorCategory) {
        operatorCategories.removeAll { $0.id == localId }
        if let idx = operatorCategories.firstIndex(where: { $0.id == remote.id }) {
            operatorCategories[idx] = remote
        } else {
            operatorCategories.append(remote)
        }
        var all: [OperatorCategory] = persistenceStore.load(key: MgmtKeys.operatorCategories) ?? []
        all.removeAll { $0.id == localId }
        if let idx = all.firstIndex(where: { $0.id == remote.id }) {
            all[idx] = remote
        } else {
            all.append(remote)
        }
        persistenceStore.save(all, key: MgmtKeys.operatorCategories)

        if let vineyardIndex = vineyards.firstIndex(where: { $0.id == remote.vineyardId }) {
            var updated = vineyards[vineyardIndex]
            var changed = false
            for i in updated.users.indices where updated.users[i].operatorCategoryId == localId {
                updated.users[i].operatorCategoryId = remote.id
                changed = true
            }
            if changed {
                updateVineyard(updated)
            }
        }
    }

    // MARK: - Work Task Types

    func addWorkTaskType(_ type: WorkTaskType) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = type
        entry.vineyardId = vineyardId
        // Case-insensitive de-dupe within the current vineyard.
        let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if workTaskTypes.contains(where: {
            $0.vineyardId == vineyardId &&
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed.lowercased()
        }) { return }
        workTaskTypes.append(entry)
        workTaskTypeRepo.saveSlice(workTaskTypes, for: vineyardId)
        onWorkTaskTypeChanged?(entry.id)
    }

    func updateWorkTaskType(_ type: WorkTaskType) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let idx = workTaskTypes.firstIndex(where: { $0.id == type.id }) else { return }
        workTaskTypes[idx] = type
        workTaskTypeRepo.saveSlice(workTaskTypes, for: vineyardId)
        onWorkTaskTypeChanged?(type.id)
    }

    func deleteWorkTaskType(_ type: WorkTaskType) {
        guard let vineyardId = selectedVineyardId else { return }
        workTaskTypes.removeAll { $0.id == type.id }
        workTaskTypeRepo.saveSlice(workTaskTypes, for: vineyardId)
        onWorkTaskTypeDeleted?(type.id)
    }

    func applyRemoteWorkTaskTypeUpsert(_ type: WorkTaskType) {
        if selectedVineyardId == type.vineyardId {
            if let idx = workTaskTypes.firstIndex(where: { $0.id == type.id }) {
                workTaskTypes[idx] = type
            } else {
                workTaskTypes.append(type)
            }
            workTaskTypeRepo.saveSlice(workTaskTypes, for: type.vineyardId)
        } else {
            var all = workTaskTypeRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == type.id }) {
                all[idx] = type
            } else {
                all.append(type)
            }
            workTaskTypeRepo.saveSlice(all.filter { $0.vineyardId == type.vineyardId }, for: type.vineyardId)
        }
    }

    func applyRemoteWorkTaskTypeDelete(_ id: UUID) {
        if selectedVineyardId != nil {
            workTaskTypes.removeAll { $0.id == id }
        }
        var all = workTaskTypeRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            workTaskTypeRepo.saveSlice(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Equipment Items ("Other" maintenance assets)

    func addEquipmentItem(_ item: EquipmentItem) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = item
        entry.vineyardId = vineyardId
        let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if equipmentItems.contains(where: {
            $0.vineyardId == vineyardId &&
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed.lowercased()
        }) { return }
        equipmentItems.append(entry)
        equipmentItemRepo.saveSlice(equipmentItems, for: vineyardId)
        onEquipmentItemChanged?(entry.id)
    }

    func updateEquipmentItem(_ item: EquipmentItem) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let idx = equipmentItems.firstIndex(where: { $0.id == item.id }) else { return }
        equipmentItems[idx] = item
        equipmentItemRepo.saveSlice(equipmentItems, for: vineyardId)
        onEquipmentItemChanged?(item.id)
    }

    func deleteEquipmentItem(_ item: EquipmentItem) {
        guard let vineyardId = selectedVineyardId else { return }
        equipmentItems.removeAll { $0.id == item.id }
        equipmentItemRepo.saveSlice(equipmentItems, for: vineyardId)
        onEquipmentItemDeleted?(item.id)
    }

    func applyRemoteEquipmentItemUpsert(_ item: EquipmentItem) {
        if selectedVineyardId == item.vineyardId {
            if let idx = equipmentItems.firstIndex(where: { $0.id == item.id }) {
                equipmentItems[idx] = item
            } else {
                equipmentItems.append(item)
            }
            equipmentItemRepo.saveSlice(equipmentItems, for: item.vineyardId)
        } else {
            var all = equipmentItemRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == item.id }) {
                all[idx] = item
            } else {
                all.append(item)
            }
            equipmentItemRepo.saveSlice(all.filter { $0.vineyardId == item.vineyardId }, for: item.vineyardId)
        }
    }

    func applyRemoteEquipmentItemDelete(_ id: UUID) {
        if selectedVineyardId != nil {
            equipmentItems.removeAll { $0.id == id }
        }
        var all = equipmentItemRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            equipmentItemRepo.saveSlice(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    @discardableResult
    func deduplicateOperatorCategories() -> Int {
        guard let vineyardId = selectedVineyardId else { return 0 }
        var seen: [String: OperatorCategory] = [:]
        var keptOrder: [OperatorCategory] = []
        var duplicateIdToKeptId: [UUID: UUID] = [:]

        for cat in operatorCategories {
            let key = cat.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let existing = seen[key] {
                let winner = (cat.costPerHour > existing.costPerHour) ? cat : existing
                let loser = (winner.id == cat.id) ? existing : cat
                if winner.id != existing.id {
                    if let idx = keptOrder.firstIndex(where: { $0.id == existing.id }) {
                        keptOrder[idx] = winner
                    }
                    seen[key] = winner
                }
                duplicateIdToKeptId[loser.id] = winner.id
            } else {
                seen[key] = cat
                keptOrder.append(cat)
            }
        }

        let removedCount = operatorCategories.count - keptOrder.count
        guard removedCount > 0 else { return 0 }

        operatorCategories = keptOrder
        saveOperatorCategoriesToDisk()

        if let vineyardIndex = vineyards.firstIndex(where: { $0.id == vineyardId }) {
            var updated = vineyards[vineyardIndex]
            var changed = false
            for i in updated.users.indices {
                if let cid = updated.users[i].operatorCategoryId, let newId = duplicateIdToKeptId[cid] {
                    updated.users[i].operatorCategoryId = newId
                    changed = true
                }
            }
            if changed {
                updateVineyard(updated)
            }
        }

        for (dupId, _) in duplicateIdToKeptId {
            onOperatorCategoryDeleted?(dupId)
        }

        return removedCount
    }

    // MARK: - Grape Varieties (CRUD)

    private func saveGrapeVarietiesToDisk() {
        guard let vineyardId = selectedVineyardId else { return }
        var all: [GrapeVariety] = persistenceStore.load(key: MgmtKeys.grapeVarieties) ?? []
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: grapeVarieties.filter { $0.vineyardId == vineyardId })
        persistenceStore.save(all, key: MgmtKeys.grapeVarieties)
    }

    /// Public hook used by `GrapeVarietyCanonicalization` to persist
    /// repaired variety rows for the current vineyard.
    func persistGrapeVarieties() {
        saveGrapeVarietiesToDisk()
    }

    func addGrapeVariety(_ variety: GrapeVariety) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = variety
        entry.vineyardId = vineyardId
        // De-duplicate by canonical name within the vineyard. If a variety
        // with the same canonical name already exists, prefer it and do
        // not create a parallel row with a different id (which is what
        // caused the historical "Unknown variety" regression).
        let canonical = BuiltInGrapeVarietyCatalog.canonical(entry.name)
        if !canonical.isEmpty,
           grapeVarieties.contains(where: {
               $0.vineyardId == vineyardId &&
               BuiltInGrapeVarietyCatalog.canonical($0.name) == canonical
           }) {
            return
        }
        // If this matches a built-in catalog entry, stamp the stable
        // key + deterministic id so it survives device migration.
        if let catalog = BuiltInGrapeVarietyCatalog.entry(matching: entry.name) {
            entry = GrapeVariety(
                id: GrapeVariety.deterministicID(vineyardId: vineyardId, key: catalog.key),
                vineyardId: vineyardId,
                name: catalog.name,
                optimalGDD: entry.optimalGDD > 0 ? entry.optimalGDD : catalog.optimalGDD,
                isBuiltIn: true,
                key: catalog.key
            )
        }
        grapeVarieties.append(entry)
        saveGrapeVarietiesToDisk()
    }

    func updateGrapeVariety(_ variety: GrapeVariety) {
        guard let idx = grapeVarieties.firstIndex(where: { $0.id == variety.id }) else { return }
        grapeVarieties[idx] = variety
        saveGrapeVarietiesToDisk()
    }

    func deleteGrapeVariety(_ variety: GrapeVariety) {
        grapeVarieties.removeAll { $0.id == variety.id }
        saveGrapeVarietiesToDisk()
    }

    /// Merge custom + active vineyard grape varieties pulled from Supabase
    /// (`list_vineyard_grape_varieties`) into the local `grapeVarieties`
    /// array for the given vineyard. Built-in selections are mirrored too
    /// so the resolver can use the server-stamped `optimal_gdd_override`.
    /// Archived (`is_active == false`) rows are removed locally.
    /// No-op when `vineyardId` is not the currently selected vineyard.
    func applyRemoteVineyardGrapeVarieties(
        _ rows: [VineyardGrapeVarietyRow],
        vineyardId: UUID
    ) {
        guard selectedVineyardId == vineyardId else { return }

        var changed = false
        let activeRows = rows.filter { $0.isActive }
        let archivedKeys = Set(rows.filter { !$0.isActive }.map { $0.varietyKey })

        for row in activeRows {
            let key = row.varietyKey
            let deterministicId = GrapeVariety.deterministicID(vineyardId: vineyardId, key: key)
            let trimmedName = row.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName: String = {
                if !row.isCustom, let builtin = BuiltInGrapeVarietyCatalog.entries.first(where: { $0.key == key }) {
                    return builtin.name
                }
                return trimmedName.isEmpty ? key : trimmedName
            }()
            let resolvedGDD: Double = {
                if let override = row.optimalGDDOverride { return override }
                if let builtin = BuiltInGrapeVarietyCatalog.entries.first(where: { $0.key == key }) {
                    return builtin.optimalGDD
                }
                return 1400
            }()

            if let idx = grapeVarieties.firstIndex(where: {
                $0.vineyardId == vineyardId && ($0.key == key || $0.id == deterministicId)
            }) {
                var existing = grapeVarieties[idx]
                var localChanged = false
                if existing.id != deterministicId { existing.id = deterministicId; localChanged = true }
                if existing.key != key { existing.key = key; localChanged = true }
                if existing.name != resolvedName { existing.name = resolvedName; localChanged = true }
                if existing.isBuiltIn != !row.isCustom { existing.isBuiltIn = !row.isCustom; localChanged = true }
                if existing.optimalGDD != resolvedGDD { existing.optimalGDD = resolvedGDD; localChanged = true }
                if localChanged {
                    grapeVarieties[idx] = existing
                    changed = true
                }
            } else {
                // Skip name-duplicate of an existing local row to avoid
                // showing the same variety twice when the local row was
                // created before keys were available.
                let canonical = BuiltInGrapeVarietyCatalog.canonical(resolvedName)
                if !canonical.isEmpty,
                   let idx = grapeVarieties.firstIndex(where: {
                       $0.vineyardId == vineyardId &&
                       BuiltInGrapeVarietyCatalog.canonical($0.name) == canonical
                   }) {
                    var existing = grapeVarieties[idx]
                    existing.id = deterministicId
                    existing.key = key
                    existing.name = resolvedName
                    existing.isBuiltIn = !row.isCustom
                    existing.optimalGDD = resolvedGDD
                    grapeVarieties[idx] = existing
                    changed = true
                    continue
                }
                grapeVarieties.append(GrapeVariety(
                    id: deterministicId,
                    vineyardId: vineyardId,
                    name: resolvedName,
                    optimalGDD: resolvedGDD,
                    isBuiltIn: !row.isCustom,
                    key: key
                ))
                changed = true
            }
        }

        // Remove local rows that match an archived custom key for this vineyard.
        if !archivedKeys.isEmpty {
            let before = grapeVarieties.count
            grapeVarieties.removeAll { v in
                guard v.vineyardId == vineyardId,
                      let k = v.key,
                      archivedKeys.contains(k) else { return false }
                return true
            }
            if grapeVarieties.count != before { changed = true }
        }

        if changed {
            saveGrapeVarietiesToDisk()
        }
    }

    // MARK: - Vineyard Location (lat/long/elevation/timezone)

    /// Result of merging server-side vineyard location into local `AppSettings`.
    /// `needsBackfill` is true when the server has nulls but the local copy has
    /// values — the caller should push the local values back to Supabase as a
    /// one-time migration.
    nonisolated struct VineyardLocationMergeResult: Sendable {
        let needsBackfill: Bool
        let latitude: Double?
        let longitude: Double?
        let elevationMetres: Double?
        let timezone: String?
    }

    /// Merge the server-side vineyard location into the local `AppSettings`.
    /// Server values win whenever they are non-nil; nil server fields preserve
    /// the existing local value (no destructive overwrites). When the server is
    /// missing a value the local copy has, the result flags `needsBackfill`.
    @discardableResult
    func applyRemoteVineyardLocation(
        _ remote: BackendVineyardLocation,
        vineyardId: UUID
    ) -> VineyardLocationMergeResult {
        guard selectedVineyardId == vineyardId else {
            return VineyardLocationMergeResult(
                needsBackfill: false,
                latitude: remote.latitude,
                longitude: remote.longitude,
                elevationMetres: remote.elevationMetres,
                timezone: remote.timezone
            )
        }

        var s = settings
        s.vineyardId = vineyardId
        var changed = false

        if let lat = remote.latitude {
            if s.vineyardLatitude != lat { s.vineyardLatitude = lat; changed = true }
        }
        if let lon = remote.longitude {
            if s.vineyardLongitude != lon { s.vineyardLongitude = lon; changed = true }
        }
        if let elev = remote.elevationMetres {
            if s.vineyardElevationMetres != elev { s.vineyardElevationMetres = elev; changed = true }
        }
        if let tz = remote.timezone, !tz.isEmpty {
            if s.timezone != tz { s.timezone = tz; changed = true }
        }

        if changed {
            saveSettings(s)
        }

        let needsBackfill =
            (remote.latitude == nil && s.vineyardLatitude != nil) ||
            (remote.longitude == nil && s.vineyardLongitude != nil) ||
            (remote.elevationMetres == nil && s.vineyardElevationMetres != nil)

        return VineyardLocationMergeResult(
            needsBackfill: needsBackfill,
            latitude: s.vineyardLatitude,
            longitude: s.vineyardLongitude,
            elevationMetres: s.vineyardElevationMetres,
            timezone: s.timezone
        )
    }

    // MARK: - Vineyard Region Settings (country/units/date format/terminology)

    /// Result of merging server-side vineyard region settings into the local
    /// `AppSettings.regionSettings`. `needsBackfill` is true only when the
    /// server has *no* region values AND the local copy diverges from the
    /// Australian defaults — i.e. there is something worth pushing up once.
    /// `settingsToBackfill` is the resolved local region contract to push.
    nonisolated struct VineyardRegionSettingsMergeResult: Sendable {
        let needsBackfill: Bool
        let settingsToBackfill: OrganizationRegionSettings
    }

    /// Merge the server-side region settings into the local
    /// `AppSettings.regionSettings`.
    ///
    /// Conflict handling:
    ///   1. Server value exists (non-nil/non-empty) → server wins.
    ///   2. Server value missing/null → preserve the local fallback (which is
    ///      itself the AU default unless an owner/manager changed it).
    ///   3. Server all-null + local non-default → flag `needsBackfill` so the
    ///      caller can push local up *once* (caller gates this on role).
    ///
    /// Existing AU organisations have all-null servers and AU-default locals,
    /// so nothing changes and `needsBackfill` stays false.
    @discardableResult
    func applyRemoteVineyardRegionSettings(
        _ remote: BackendVineyardRegionSettings,
        vineyardId: UUID
    ) -> VineyardRegionSettingsMergeResult {
        guard selectedVineyardId == vineyardId else {
            return VineyardRegionSettingsMergeResult(
                needsBackfill: false,
                settingsToBackfill: settings.regionSettings
            )
        }

        var s = settings
        s.vineyardId = vineyardId
        var region = s.regionSettings
        var changed = false

        func apply(_ value: String?, to keyPath: WritableKeyPath<OrganizationRegionSettings, String>) {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if region[keyPath: keyPath] != value {
                region[keyPath: keyPath] = value
                changed = true
            }
        }

        apply(remote.countryCode, to: \.countryCode)
        apply(remote.currencyCode, to: \.currencyCode)
        apply(remote.timezone, to: \.timezone)
        apply(remote.areaUnit, to: \.areaUnit)
        apply(remote.volumeUnit, to: \.volumeUnit)
        apply(remote.distanceUnit, to: \.distanceUnit)
        apply(remote.fuelUnit, to: \.fuelUnit)
        apply(remote.sprayRateAreaUnit, to: \.sprayRateAreaUnit)
        apply(remote.dateFormat, to: \.dateFormat)
        apply(remote.terminologyRegion, to: \.terminologyRegion)

        if changed {
            s.regionSettings = region
            saveSettings(s)
        }

        // Backfill only when the server is entirely empty AND our local region
        // contract diverges from AU defaults. Otherwise there is nothing new
        // to push, and existing AU vineyards stay untouched.
        let needsBackfill = remote.isAllNull
            && region != OrganizationRegionSettings.australianDefaults

        return VineyardRegionSettingsMergeResult(
            needsBackfill: needsBackfill,
            settingsToBackfill: region
        )
    }

    /// Apply the shared vineyard season settings (season start month/day from
    /// `public.vineyards`, sql/108) to the local per-vineyard `AppSettings`
    /// cache. The server value is authoritative; the local JSON copy is only
    /// the offline cache of the last successful fetch.
    func applyRemoteVineyardSeasonSettings(month: Int, day: Int, vineyardId: UUID) {
        guard selectedVineyardId == vineyardId else { return }
        var s = settings
        s.vineyardId = vineyardId
        guard s.seasonStartMonth != month || s.seasonStartDay != day else { return }
        s.seasonStartMonth = month
        s.seasonStartDay = day
        saveSettings(s)
    }

    // MARK: - Button Templates

    private func saveButtonTemplatesToDisk() {
        guard let vineyardId = selectedVineyardId else { return }
        var all: [ButtonTemplate] = persistenceStore.load(key: MgmtKeys.buttonTemplates) ?? []
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: buttonTemplates.filter { $0.vineyardId == vineyardId })
        persistenceStore.save(all, key: MgmtKeys.buttonTemplates)
    }

    func buttonTemplates(for mode: PinMode) -> [ButtonTemplate] {
        buttonTemplates.filter { $0.mode == mode }
    }

    func addButtonTemplate(_ template: ButtonTemplate) {
        guard let vineyardId = selectedVineyardId else { return }
        var entry = template
        entry.vineyardId = vineyardId
        buttonTemplates.append(entry)
        saveButtonTemplatesToDisk()
    }

    func updateButtonTemplate(_ template: ButtonTemplate) {
        guard let idx = buttonTemplates.firstIndex(where: { $0.id == template.id }) else { return }
        buttonTemplates[idx] = template
        saveButtonTemplatesToDisk()
    }

    func deleteButtonTemplate(_ template: ButtonTemplate) {
        buttonTemplates.removeAll { $0.id == template.id }
        saveButtonTemplatesToDisk()
    }

    /// Apply a template to the active button set for its mode, replacing existing buttons.
    func applyButtonTemplate(_ template: ButtonTemplate) {
        guard let vineyardId = selectedVineyardId else { return }
        let configs = template.toButtonConfigs(for: vineyardId)
        switch template.mode {
        case .repairs:
            updateRepairButtons(configs)
        case .growth:
            updateGrowthButtons(configs)
        }
    }

    // MARK: - Vineyard update (used by operator-category user assignment)

    func updateVineyard(_ vineyard: Vineyard) {
        vineyards = vineyardRepo.upsert(vineyard)
    }
}
