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

    /// Area-weighted damage for a block, scoped to ONE vintage.
    ///
    /// This replaces the old multiplicative `damageFactor(for:)`, which
    /// compounded every record's percentage over the WHOLE block and turned
    /// "20% intensity over 10% of the block" into a 20% block loss instead of
    /// the correct 2%. The contract is
    /// `loss = Σ(mapped area × intensity) ÷ block area`, capped at 100% — see
    /// `docs/season-yield-damage-parity-fixtures.md`.
    ///
    /// Damage is filtered by the server-resolved vintage, so last season's
    /// frost can never reduce this season's crop.
    func blockDamage(for paddockId: UUID, vintage: Int) -> SeasonYieldDamage.BlockDamage {
        let area = paddocks.first { $0.id == paddockId }?.areaHectares ?? 0
        let scoped = damageRecords(for: paddockId).filter {
            $0.resolvedVintage(
                seasonStartMonth: settings.seasonStartMonth,
                seasonStartDay: settings.seasonStartDay
            ) == vintage
        }
        return SeasonYieldDamage.blockDamage(
            paddockId: paddockId,
            blockAreaHectares: area,
            records: scoped.map(\.damageEngineRecord)
        )
    }

    /// Share of a block's crop that SURVIVES recorded damage (0...1), where
    /// 1.0 means undamaged.
    ///
    /// Deliberately not called `damageFactor`: the retired name was read by
    /// some callers as the loss and by others as the remainder, and the two
    /// are complements. ``SeasonYieldDamage/BlockDamage/damageLossFraction``
    /// is the loss.
    func remainingYieldMultiplier(for paddockId: UUID, vintage: Int) -> Double {
        blockDamage(for: paddockId, vintage: vintage).remainingYieldMultiplier
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

    // MARK: - PickingRecord (Detailed picking log)

    func addPickingRecord(_ record: PickingRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = record
        item.vineyardId = vineyardId
        pickingRecords.append(item)
        yieldRepo.savePickingSlice(pickingRecords, for: vineyardId)
        onPickingRecordChanged?(item.id)
    }

    func updatePickingRecord(_ record: PickingRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = pickingRecords.firstIndex(where: { $0.id == record.id }) else { return }
        pickingRecords[index] = record
        yieldRepo.savePickingSlice(pickingRecords, for: vineyardId)
        onPickingRecordChanged?(record.id)
    }

    func deletePickingRecord(_ record: PickingRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        pickingRecords.removeAll { $0.id == record.id }
        yieldRepo.savePickingSlice(pickingRecords, for: vineyardId)
        onPickingRecordDeleted?(record.id)
    }

    /// Canonical actual-yield precedence for a Block + Variety + Vintage:
    /// when detailed picking records exist, their summed weight IS the actual
    /// yield (returns the detailed tonnes); otherwise nil, meaning any Basic
    /// manually entered actual remains authoritative. Never add the two.
    func detailedActualYieldTonnes(paddockId: UUID, varietyName: String?, vintage: Int) -> Double? {
        PickingYieldAggregator.detailedActualTonnes(
            records: pickingRecords,
            paddockId: paddockId,
            varietyName: varietyName,
            vintage: vintage
        )
    }

    // MARK: - PruningYieldSettings (shared per-block calculator config, sql/181)

    /// The saved Pruning Yield Calculator configuration for a block, if any.
    func pruningYieldSettings(for paddockId: UUID) -> PruningYieldSettings? {
        pruningYieldSettings.first { $0.paddockId == paddockId }
    }

    /// Upsert the ONE saved configuration for the settings' block. When the
    /// block already has a record the existing row id is kept (stable identity
    /// for sync), so editing never duplicates a block's configuration.
    ///
    /// The server revision is re-stamped from the cached row alongside the id and never taken
    /// from the incoming value. `server_revision` is server state: the calculator screen builds
    /// a fresh ``PruningYieldSettings`` from its input fields (revision nil), which would
    /// otherwise downgrade a synced block to "unversioned" and have its write read as a create.
    /// Screens author values; only the server authors revisions.
    func savePruningYieldSettings(_ settings: PruningYieldSettings) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = settings
        item.vineyardId = vineyardId
        item.updatedAt = Date()
        if let idx = pruningYieldSettings.firstIndex(where: { $0.paddockId == item.paddockId }) {
            item.id = pruningYieldSettings[idx].id
            item.serverRevision = pruningYieldSettings[idx].serverRevision
            pruningYieldSettings[idx] = item
        } else {
            item.serverRevision = nil
            pruningYieldSettings.append(item)
        }
        yieldRepo.savePruningSettingsSlice(pruningYieldSettings, for: vineyardId)
        onPruningYieldSettingsChanged?(item.id)
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
