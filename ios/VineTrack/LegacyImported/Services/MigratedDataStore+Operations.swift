import Foundation

/// Phase 15G: applyRemote helpers for work tasks, maintenance logs, yield
/// estimation sessions, damage records, and historical yield records.
/// Mirrors the pattern used by pin/paddock/spray applyRemote methods —
/// updates local in-memory state and on-disk slices without re-firing
/// the corresponding sync hooks.
extension MigratedDataStore {

    // MARK: - Work Tasks

    func applyRemoteWorkTaskUpsert(_ task: WorkTask) {
        if selectedVineyardId == task.vineyardId {
            if let idx = workTasks.firstIndex(where: { $0.id == task.id }) {
                workTasks[idx] = task
            } else {
                workTasks.append(task)
            }
            workTaskRepo.saveSlice(workTasks, for: task.vineyardId)
        } else {
            var all = workTaskRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == task.id }) {
                all[idx] = task
            } else {
                all.append(task)
            }
            workTaskRepo.replace(all.filter { $0.vineyardId == task.vineyardId }, for: task.vineyardId)
        }
    }

    func applyRemoteWorkTaskDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            workTasks.removeAll { $0.id == id }
            workTaskRepo.saveSlice(workTasks, for: vineyardId)
        }
        var all = workTaskRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            workTaskRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Work Task Labour Lines

    func applyRemoteWorkTaskLabourLineUpsert(_ line: WorkTaskLabourLine) {
        if selectedVineyardId == line.vineyardId {
            if let idx = workTaskLabourLines.firstIndex(where: { $0.id == line.id }) {
                workTaskLabourLines[idx] = line
            } else {
                workTaskLabourLines.append(line)
            }
            workTaskLabourLineRepo.saveSlice(workTaskLabourLines, for: line.vineyardId)
        } else {
            var all = workTaskLabourLineRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == line.id }) {
                all[idx] = line
            } else {
                all.append(line)
            }
            workTaskLabourLineRepo.replace(all.filter { $0.vineyardId == line.vineyardId }, for: line.vineyardId)
        }
    }

    func applyRemoteWorkTaskLabourLineDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            workTaskLabourLines.removeAll { $0.id == id }
            workTaskLabourLineRepo.saveSlice(workTaskLabourLines, for: vineyardId)
        }
        var all = workTaskLabourLineRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            workTaskLabourLineRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Work Task Machine Lines

    func applyRemoteWorkTaskMachineLineUpsert(_ line: WorkTaskMachineLine) {
        if selectedVineyardId == line.vineyardId {
            if let idx = workTaskMachineLines.firstIndex(where: { $0.id == line.id }) {
                workTaskMachineLines[idx] = line
            } else {
                workTaskMachineLines.append(line)
            }
            workTaskMachineLineRepo.saveSlice(workTaskMachineLines, for: line.vineyardId)
        } else {
            var all = workTaskMachineLineRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == line.id }) {
                all[idx] = line
            } else {
                all.append(line)
            }
            workTaskMachineLineRepo.replace(all.filter { $0.vineyardId == line.vineyardId }, for: line.vineyardId)
        }
    }

    func applyRemoteWorkTaskMachineLineDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            workTaskMachineLines.removeAll { $0.id == id }
            workTaskMachineLineRepo.saveSlice(workTaskMachineLines, for: vineyardId)
        }
        var all = workTaskMachineLineRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            workTaskMachineLineRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    /// Resolves the display name for a manual machine line, preferring the
    /// stable equipment link (equipmentSource + equipmentRefId) when present so
    /// the shown name reflects the current asset, and falling back to the
    /// stored equipmentNameSnapshot otherwise. The snapshot is never mutated.
    func resolvedMachineLineEquipmentName(_ line: WorkTaskMachineLine) -> String {
        equipmentResolver.sourceRefName(
            source: line.equipmentSource,
            refId: line.equipmentRefId,
            snapshot: line.equipmentNameSnapshot
        )
    }

    /// Shared display-only equipment resolver built from the store's current
    /// equipment collections. Read-only; never mutates or backfills.
    var equipmentResolver: EquipmentResolver {
        EquipmentResolver(
            vineyardMachines: vineyardMachines,
            tractors: tractors,
            sprayEquipment: sprayEquipment,
            equipmentItems: equipmentItems
        )
    }

    // MARK: - Work Task Paddocks

    func applyRemoteWorkTaskPaddockUpsert(_ paddock: WorkTaskPaddock) {
        if selectedVineyardId == paddock.vineyardId {
            if let idx = workTaskPaddocks.firstIndex(where: { $0.id == paddock.id }) {
                workTaskPaddocks[idx] = paddock
            } else {
                workTaskPaddocks.append(paddock)
            }
            workTaskPaddockRepo.saveSlice(workTaskPaddocks, for: paddock.vineyardId)
        } else {
            var all = workTaskPaddockRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == paddock.id }) {
                all[idx] = paddock
            } else {
                all.append(paddock)
            }
            workTaskPaddockRepo.replace(all.filter { $0.vineyardId == paddock.vineyardId }, for: paddock.vineyardId)
        }
    }

    func applyRemoteWorkTaskPaddockDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            workTaskPaddocks.removeAll { $0.id == id }
            workTaskPaddockRepo.saveSlice(workTaskPaddocks, for: vineyardId)
        }
        var all = workTaskPaddockRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            workTaskPaddockRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Maintenance Logs

    func applyRemoteMaintenanceLogUpsert(_ log: MaintenanceLog) {
        if selectedVineyardId == log.vineyardId {
            if let idx = maintenanceLogs.firstIndex(where: { $0.id == log.id }) {
                maintenanceLogs[idx] = log
            } else {
                maintenanceLogs.append(log)
            }
            maintenanceLogRepo.saveSlice(maintenanceLogs, for: log.vineyardId)
        } else {
            var all = maintenanceLogRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == log.id }) {
                all[idx] = log
            } else {
                all.append(log)
            }
            maintenanceLogRepo.replace(all.filter { $0.vineyardId == log.vineyardId }, for: log.vineyardId)
        }
    }

    /// Resolves the display name for a maintenance log, preferring the stable
    /// equipment link (equipmentSource + equipmentRefId) when present so the
    /// shown name reflects the current asset, and falling back to the stored
    /// item_name snapshot when there is no link or the asset is unavailable.
    func resolvedMaintenanceItemName(_ log: MaintenanceLog) -> String {
        equipmentResolver.sourceRefName(
            source: log.equipmentSource,
            refId: log.equipmentRefId,
            snapshot: log.itemName
        )
    }

    /// Resolves the display name for a spray record's tractor/machine field,
    /// preferring the stable link (machineId → tractorId) when present so the
    /// shown name reflects the current asset, and falling back to the stored
    /// `tractor` text snapshot otherwise. The text snapshot is never mutated.
    func resolvedSprayTractorName(_ record: SprayRecord) -> String {
        equipmentResolver.sprayTractorName(record)
    }

    /// Resolves the display name for a spray record's equipment-type field,
    /// preferring the stable `sprayEquipmentId` link when present and falling
    /// back to the stored `equipmentType` text snapshot otherwise.
    func resolvedSprayEquipmentName(_ record: SprayRecord) -> String {
        equipmentResolver.sprayEquipmentName(record)
    }

    func applyRemoteMaintenanceLogDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            maintenanceLogs.removeAll { $0.id == id }
            maintenanceLogRepo.saveSlice(maintenanceLogs, for: vineyardId)
        }
        var all = maintenanceLogRepo.loadAll()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            maintenanceLogRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Yield Estimation Sessions

    func applyRemoteYieldSessionUpsert(_ session: YieldEstimationSession) {
        if selectedVineyardId == session.vineyardId {
            if let idx = yieldSessions.firstIndex(where: { $0.id == session.id }) {
                yieldSessions[idx] = session
            } else {
                yieldSessions.append(session)
            }
            yieldRepo.saveSessionsSlice(yieldSessions, for: session.vineyardId)
        } else {
            var all = yieldRepo.loadAllSessions()
            if let idx = all.firstIndex(where: { $0.id == session.id }) {
                all[idx] = session
            } else {
                all.append(session)
            }
            yieldRepo.replaceSessions(all.filter { $0.vineyardId == session.vineyardId }, for: session.vineyardId)
        }
    }

    func applyRemoteYieldSessionDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            yieldSessions.removeAll { $0.id == id }
            yieldRepo.saveSessionsSlice(yieldSessions, for: vineyardId)
        }
        var all = yieldRepo.loadAllSessions()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            yieldRepo.replaceSessions(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Damage Records

    func applyRemoteDamageRecordUpsert(_ record: DamageRecord) {
        if selectedVineyardId == record.vineyardId {
            if let idx = damageRecords.firstIndex(where: { $0.id == record.id }) {
                damageRecords[idx] = record
            } else {
                damageRecords.append(record)
            }
            yieldRepo.saveDamageSlice(damageRecords, for: record.vineyardId)
        } else {
            var all = yieldRepo.loadAllDamage()
            if let idx = all.firstIndex(where: { $0.id == record.id }) {
                all[idx] = record
            } else {
                all.append(record)
            }
            yieldRepo.replaceDamage(all.filter { $0.vineyardId == record.vineyardId }, for: record.vineyardId)
        }
    }

    func applyRemoteDamageRecordDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            damageRecords.removeAll { $0.id == id }
            yieldRepo.saveDamageSlice(damageRecords, for: vineyardId)
        }
        var all = yieldRepo.loadAllDamage()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            yieldRepo.replaceDamage(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - Historical Yield Records

    func applyRemoteHistoricalYieldRecordUpsert(_ record: HistoricalYieldRecord) {
        if selectedVineyardId == record.vineyardId {
            if let idx = historicalYieldRecords.firstIndex(where: { $0.id == record.id }) {
                historicalYieldRecords[idx] = record
            } else {
                historicalYieldRecords.append(record)
            }
            yieldRepo.saveHistoricalSlice(historicalYieldRecords, for: record.vineyardId)
        } else {
            var all = yieldRepo.loadAllHistorical()
            if let idx = all.firstIndex(where: { $0.id == record.id }) {
                all[idx] = record
            } else {
                all.append(record)
            }
            yieldRepo.replaceHistorical(all.filter { $0.vineyardId == record.vineyardId }, for: record.vineyardId)
        }
    }

    func applyRemoteHistoricalYieldRecordDelete(_ id: UUID) {
        if let vineyardId = selectedVineyardId {
            historicalYieldRecords.removeAll { $0.id == id }
            yieldRepo.saveHistoricalSlice(historicalYieldRecords, for: vineyardId)
        }
        var all = yieldRepo.loadAllHistorical()
        if let removed = all.first(where: { $0.id == id }) {
            all.removeAll { $0.id == id }
            yieldRepo.replaceHistorical(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }
}
