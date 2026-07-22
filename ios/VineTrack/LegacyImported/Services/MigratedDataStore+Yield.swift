import Foundation

extension MigratedDataStore {

    // MARK: - Ordered Paddocks

    /// Paddocks for the currently selected vineyard, ordered by `settings.paddockOrder`
    /// when defined, falling back to alphabetical order by name.
    var orderedPaddocks: [Paddock] {
        let order = settings.paddockOrder
        guard !order.isEmpty else {
            return paddocks.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let indexMap: [UUID: Int] = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return paddocks.sorted { lhs, rhs in
            switch (indexMap[lhs.id], indexMap[rhs.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    // MARK: - Settings

    func updateSettings(_ newSettings: AppSettings) {
        saveSettings(newSettings)
    }

    // MARK: - YieldEstimationSession

    func saveYieldSession(_ session: YieldEstimationSession) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = session
        item.vineyardId = vineyardId
        if let index = yieldSessions.firstIndex(where: { $0.id == item.id }) {
            yieldSessions[index] = item
        } else {
            yieldSessions.append(item)
        }
        yieldRepo.saveSessionsSlice(yieldSessions, for: vineyardId)
        onYieldSessionChanged?(item.id)
    }

    func deleteYieldSession(_ session: YieldEstimationSession) {
        guard let vineyardId = selectedVineyardId else { return }
        yieldSessions.removeAll { $0.id == session.id }
        yieldRepo.saveSessionsSlice(yieldSessions, for: vineyardId)
        onYieldSessionDeleted?(session.id)
    }

    // MARK: - DamageRecord

    func damageRecords(for paddockId: UUID) -> [DamageRecord] {
        damageRecords.filter { $0.paddockId == paddockId }
    }

    /// Cumulative viability factor (0...1) for a paddock based on its damage records.
    /// Each damage record reduces remaining viability by `damagePercent`%.
    func damageFactor(for paddockId: UUID) -> Double {
        let records = damageRecords(for: paddockId)
        guard !records.isEmpty else { return 1.0 }
        var factor = 1.0
        for record in records {
            let pct = max(0, min(100, record.damagePercent)) / 100.0
            factor *= (1.0 - pct)
        }
        return max(0, min(1, factor))
    }

    func addDamageRecord(_ record: DamageRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = record
        item.vineyardId = vineyardId
        damageRecords.append(item)
        yieldRepo.saveDamageSlice(damageRecords, for: vineyardId)
        onDamageRecordChanged?(item.id)
    }

    func updateDamageRecord(_ record: DamageRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = damageRecords.firstIndex(where: { $0.id == record.id }) else { return }
        damageRecords[index] = record
        yieldRepo.saveDamageSlice(damageRecords, for: vineyardId)
        onDamageRecordChanged?(record.id)
    }

    func deleteDamageRecord(_ record: DamageRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        damageRecords.removeAll { $0.id == record.id }
        yieldRepo.saveDamageSlice(damageRecords, for: vineyardId)
        onDamageRecordDeleted?(record.id)
    }

    // MARK: - HistoricalYieldRecord

    func addHistoricalYieldRecord(_ record: HistoricalYieldRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = record
        item.vineyardId = vineyardId
        historicalYieldRecords.append(item)
        yieldRepo.saveHistoricalSlice(historicalYieldRecords, for: vineyardId)
        onHistoricalYieldRecordChanged?(item.id)
    }

    func updateHistoricalYieldRecord(_ record: HistoricalYieldRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = historicalYieldRecords.firstIndex(where: { $0.id == record.id }) else { return }
        historicalYieldRecords[index] = record
        yieldRepo.saveHistoricalSlice(historicalYieldRecords, for: vineyardId)
        onHistoricalYieldRecordChanged?(record.id)
    }

    func deleteHistoricalYieldRecord(_ record: HistoricalYieldRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        historicalYieldRecords.removeAll { $0.id == record.id }
        yieldRepo.saveHistoricalSlice(historicalYieldRecords, for: vineyardId)
        onHistoricalYieldRecordDeleted?(record.id)
    }

    // MARK: - YieldDeterminationResult (local only)

    func saveYieldDeterminationResult(_ result: YieldDeterminationResult) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = result
        item.vineyardId = vineyardId
        if let idx = yieldDeterminationResults.firstIndex(where: { $0.id == item.id }) {
            yieldDeterminationResults[idx] = item
        } else {
            yieldDeterminationResults.append(item)
        }
        yieldRepo.saveDeterminationSlice(yieldDeterminationResults, for: vineyardId)
    }

    func deleteYieldDeterminationResult(_ result: YieldDeterminationResult) {
        guard let vineyardId = selectedVineyardId else { return }
        yieldDeterminationResults.removeAll { $0.id == result.id }
        yieldRepo.saveDeterminationSlice(yieldDeterminationResults, for: vineyardId)
    }

    /// Most recent determination result for the given paddock, if any.
    func latestDetermination(for paddockId: UUID) -> YieldDeterminationResult? {
        yieldDeterminationResults
            .filter { $0.paddockId == paddockId }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    /// Most recent determination result for the current vineyard overall.
    var latestDeterminationOverall: YieldDeterminationResult? {
        yieldDeterminationResults.max(by: { $0.createdAt < $1.createdAt })
    }
}
