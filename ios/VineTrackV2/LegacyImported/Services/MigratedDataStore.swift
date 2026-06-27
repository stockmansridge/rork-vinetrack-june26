import Foundation
import Observation

/// Backend-neutral local data store. Uses the imported legacy repositories and
/// PersistenceStore for storage. Has no knowledge of AuthService, CloudSyncService,
/// SupabaseManager, AnalyticsService, AuditService, or AccessControl.
///
/// This is the Phase 4 replacement for the old DataStore — it loads/saves local
/// state and exposes simple CRUD methods. Backend wiring will be added in later phases.
@Observable
@MainActor
final class MigratedDataStore {

    // MARK: - State

    var vineyards: [Vineyard] = []
    var selectedVineyardId: UUID?

    var pins: [VinePin] = []
    var paddocks: [Paddock] = []
    var trips: [Trip] = []

    var repairButtons: [ButtonConfig] = []
    var growthButtons: [ButtonConfig] = []
    var settings: AppSettings = AppSettings()
    var savedCustomPatterns: [SavedCustomPattern] = []

    var sprayRecords: [SprayRecord] = []
    var savedChemicals: [SavedChemical] = []
    var savedSprayPresets: [SavedSprayPreset] = []
    var savedEquipmentOptions: [SavedEquipmentOption] = []
    var sprayEquipment: [SprayEquipmentItem] = []
    var savedInputs: [SavedInput] = []

    var tractors: [Tractor] = []
    var vineyardMachines: [VineyardMachine] = []
    var fuelPurchases: [FuelPurchase] = []
    var tractorFuelLogs: [TractorFuelLog] = []
    var operatorCategories: [OperatorCategory] = []
    var workTaskTypes: [WorkTaskType] = []
    var equipmentItems: [EquipmentItem] = []
    var buttonTemplates: [ButtonTemplate] = []

    var yieldSessions: [YieldEstimationSession] = []
    var damageRecords: [DamageRecord] = []
    var historicalYieldRecords: [HistoricalYieldRecord] = []
    var yieldDeterminationResults: [YieldDeterminationResult] = []

    var maintenanceLogs: [MaintenanceLog] = []
    var workTasks: [WorkTask] = []
    var workTaskLabourLines: [WorkTaskLabourLine] = []
    var workTaskMachineLines: [WorkTaskMachineLine] = []
    var workTaskPaddocks: [WorkTaskPaddock] = []

    var grapeVarieties: [GrapeVariety] = []

    /// Phase 5 — saved trip cost allocation rows (owner/manager only). UI must
    /// gate visibility via `canViewCosting`; sync only fetches when the
    /// current role can view financials.
    var tripCostAllocations: [TripCostAllocation] = []

    var selectedTab: Int = 0

    // MARK: - Sync hooks (Phase 10B)

    /// Called when a pin is added/updated locally. Sync services observe this
    /// to mark the pin as dirty for upload.
    var onPinChanged: ((UUID) -> Void)?
    /// Called when a pin is deleted locally.
    var onPinDeleted: ((UUID) -> Void)?

    /// Called when a growth-stage pin is added locally so the dedicated
    /// `growth_stage_records` table can be kept in sync. Wired by
    /// `GrowthStageRecordSyncService.configure(store:auth:)`.
    var onGrowthStagePinAdded: ((VinePin) -> Void)?
    /// Called when a growth-stage pin is soft-deleted locally so the
    /// mirrored growth-stage record can also be soft-deleted.
    var onGrowthStagePinDeleted: ((UUID) -> Void)?

    /// Provides the currently-authenticated user UUID, used to self-heal
    /// `createdByUserId` on pins that were saved before auth was wired up
    /// (or on creation paths that forgot to plumb auth in).
    var currentUserIdProvider: (() -> UUID?)?
    /// Provides the currently-authenticated user display name. Used as a
    /// last-resort fallback for `createdBy` text when missing.
    var currentUserNameProvider: (() -> String?)?

    /// Provides the id of the currently active trip, if any. Used by
    /// `addPin` to associate pins dropped during a trip with the trip
    /// (so the Trip Report shows them and so Lovable can link pins to
    /// trips on Supabase). Wired in `NewMainTabView.onAppear` from
    /// `TripTrackingService.activeTrip`.
    var currentActiveTripIdProvider: (() -> UUID?)?

    /// Called when a paddock is added/updated locally. Sync services observe
    /// this to mark the paddock as dirty for upload.
    var onPaddockChanged: ((UUID) -> Void)?
    /// Called when a paddock is deleted locally.
    var onPaddockDeleted: ((UUID) -> Void)?

    /// Called when a trip is started/updated/ended locally. Sync services observe
    /// this to mark the trip as dirty for upload.
    var onTripChanged: ((UUID) -> Void)?
    /// Called when a trip is deleted locally.
    var onTripDeleted: ((UUID) -> Void)?

    /// Called when a spray record is added/updated locally. Sync services observe
    /// this to mark the record as dirty for upload.
    var onSprayRecordChanged: ((UUID) -> Void)?
    /// Called when a spray record is deleted locally.
    var onSprayRecordDeleted: ((UUID) -> Void)?

    /// Called when repair buttons change locally. The Date passed is the
    /// `clientUpdatedAt` to use for sync — `Date.distantPast` indicates a
    /// freshly-generated default that should not override remote config.
    var onRepairButtonsChanged: ((Date) -> Void)?
    /// Called when growth buttons change locally.
    var onGrowthButtonsChanged: ((Date) -> Void)?

    // Phase 15C: management data sync hooks.
    var onSavedChemicalChanged: ((UUID) -> Void)?
    var onSavedChemicalDeleted: ((UUID) -> Void)?
    var onSavedInputChanged: ((UUID) -> Void)?
    var onSavedInputDeleted: ((UUID) -> Void)?
    var onSavedSprayPresetChanged: ((UUID) -> Void)?
    var onSavedSprayPresetDeleted: ((UUID) -> Void)?
    var onSprayEquipmentChanged: ((UUID) -> Void)?
    var onSprayEquipmentDeleted: ((UUID) -> Void)?
    var onTractorChanged: ((UUID) -> Void)?
    var onTractorDeleted: ((UUID) -> Void)?
    var onVineyardMachineChanged: ((UUID) -> Void)?
    var onVineyardMachineDeleted: ((UUID) -> Void)?
    var onFuelPurchaseChanged: ((UUID) -> Void)?
    var onFuelPurchaseDeleted: ((UUID) -> Void)?
    var onTractorFuelLogChanged: ((UUID) -> Void)?
    var onTractorFuelLogDeleted: ((UUID) -> Void)?
    var onOperatorCategoryChanged: ((UUID) -> Void)?
    var onOperatorCategoryDeleted: ((UUID) -> Void)?
    var onWorkTaskTypeChanged: ((UUID) -> Void)?
    var onWorkTaskTypeDeleted: ((UUID) -> Void)?
    var onEquipmentItemChanged: ((UUID) -> Void)?
    var onEquipmentItemDeleted: ((UUID) -> Void)?
    var onTripCostAllocationChanged: ((UUID) -> Void)?
    var onTripCostAllocationDeleted: ((UUID) -> Void)?

    // Phase 15G: operations sync hooks (work tasks, maintenance, yield, damage, historical).
    var onWorkTaskChanged: ((UUID) -> Void)?
    var onWorkTaskDeleted: ((UUID) -> Void)?
    var onWorkTaskLabourLineChanged: ((UUID) -> Void)?
    var onWorkTaskLabourLineDeleted: ((UUID) -> Void)?
    var onWorkTaskMachineLineChanged: ((UUID) -> Void)?
    var onWorkTaskMachineLineDeleted: ((UUID) -> Void)?
    var onWorkTaskPaddockChanged: ((UUID) -> Void)?
    var onWorkTaskPaddockDeleted: ((UUID) -> Void)?
    var onMaintenanceLogChanged: ((UUID) -> Void)?
    var onMaintenanceLogDeleted: ((UUID) -> Void)?
    var onYieldSessionChanged: ((UUID) -> Void)?
    var onYieldSessionDeleted: ((UUID) -> Void)?
    var onDamageRecordChanged: ((UUID) -> Void)?
    var onDamageRecordDeleted: ((UUID) -> Void)?
    var onHistoricalYieldRecordChanged: ((UUID) -> Void)?
    var onHistoricalYieldRecordDeleted: ((UUID) -> Void)?

    // Phase 15F: shared photo / image sync hooks.
    /// Fired when an owner/manager saves a custom E-L stage image locally.
    /// Args: (vineyardId, stageCode).
    var onCustomELStageImageChanged: ((UUID, String) -> Void)?
    /// Fired when a custom E-L stage image is removed locally.
    var onCustomELStageImageDeleted: ((UUID, String) -> Void)?

    // MARK: - Repositories

    let vineyardRepo: VineyardRepository
    let pinRepo: PinRepository
    let tripRepo: TripRepository
    let workTaskRepo: WorkTaskRepository
    let workTaskLabourLineRepo: WorkTaskLabourLineRepository
    let workTaskMachineLineRepo: WorkTaskMachineLineRepository
    let workTaskPaddockRepo: WorkTaskPaddockRepository
    let workTaskTypeRepo: WorkTaskTypeRepository
    let equipmentItemRepo: EquipmentItemRepository
    let maintenanceLogRepo: MaintenanceLogRepository
    let sprayRepo: SprayRepository
    let savedInputRepo: SavedInputRepository
    let tripCostAllocationRepo: TripCostAllocationRepository
    let settingsRepo: SettingsRepository
    let yieldRepo: YieldRepository

    private let persistence: PersistenceStore

    // MARK: - Storage keys for collections without a dedicated repository

    private enum Keys {
        static let paddocks = "vinetrack_paddocks"
        // Legacy global keys (pre-Phase 10F). Kept here so deleteAllLocalData
        // continues to wipe them. New code uses per-vineyard keys via
        // `MigratedDataStore.repairButtonsKey(for:)` / `growthButtonsKey(for:)`.
        static let repairButtons = "vinetrack_repair_buttons"
        static let growthButtons = "vinetrack_growth_buttons"
        static let savedCustomPatterns = "vinetrack_saved_custom_patterns"
        static let tractors = "vinetrack_tractors"
        static let vineyardMachines = "vinetrack_vineyard_machines"
        static let fuelPurchases = "vinetrack_fuel_purchases"
        static let tractorFuelLogs = "vinetrack_tractor_fuel_logs"
        static let operatorCategories = "vinetrack_operator_categories"
        static let buttonTemplates = "vinetrack_button_templates"
        static let grapeVarieties = "vinetrack_grape_varieties"
        static let selectedVineyardId = "vinetrack_selected_vineyard_id"
    }

    // MARK: - Init

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.vineyardRepo = VineyardRepository(persistence: persistence)
        self.pinRepo = PinRepository(persistence: persistence)
        self.tripRepo = TripRepository(persistence: persistence)
        self.workTaskRepo = WorkTaskRepository(persistence: persistence)
        self.workTaskLabourLineRepo = WorkTaskLabourLineRepository(persistence: persistence)
        self.workTaskMachineLineRepo = WorkTaskMachineLineRepository(persistence: persistence)
        self.workTaskPaddockRepo = WorkTaskPaddockRepository(persistence: persistence)
        self.workTaskTypeRepo = WorkTaskTypeRepository(persistence: persistence)
        self.equipmentItemRepo = EquipmentItemRepository(persistence: persistence)
        self.maintenanceLogRepo = MaintenanceLogRepository(persistence: persistence)
        self.sprayRepo = SprayRepository(persistence: persistence)
        self.savedInputRepo = SavedInputRepository(persistence: persistence)
        self.tripCostAllocationRepo = TripCostAllocationRepository(persistence: persistence)
        self.settingsRepo = SettingsRepository(persistence: persistence)
        self.yieldRepo = YieldRepository(persistence: persistence)
        load()
    }

    // MARK: - Lifecycle

    func load() {
        vineyards = vineyardRepo.loadAll()
        hydrateVineyardLogosFromCache()

        if let stored: SelectedVineyardWrapper = persistence.load(key: Keys.selectedVineyardId) {
            selectedVineyardId = stored.id
        }
        if selectedVineyardId == nil, let first = vineyards.first {
            selectedVineyardId = first.id
        }

        savedCustomPatterns = persistence.load(key: Keys.savedCustomPatterns) ?? []
        tractors = persistence.load(key: Keys.tractors) ?? []
        vineyardMachines = persistence.load(key: Keys.vineyardMachines) ?? []
        fuelPurchases = persistence.load(key: Keys.fuelPurchases) ?? []
        tractorFuelLogs = persistence.load(key: Keys.tractorFuelLogs) ?? []
        operatorCategories = persistence.load(key: Keys.operatorCategories) ?? []
        buttonTemplates = persistence.load(key: Keys.buttonTemplates) ?? []
        grapeVarieties = persistence.load(key: Keys.grapeVarieties) ?? []

        deduplicateManagementCollections()

        reloadCurrentVineyardData()
    }

    /// Removes duplicate rows accumulated by a previous bug in the per-vineyard
    /// save functions. Idempotent and cheap once the data is clean.
    private func deduplicateManagementCollections() {
        let originalGrape = grapeVarieties.count
        let originalOps = operatorCategories.count
        let originalTemplates = buttonTemplates.count
        let originalTractors = tractors.count
        let originalMachines = vineyardMachines.count
        let originalFuel = fuelPurchases.count
        let originalFuelLogs = tractorFuelLogs.count

        grapeVarieties = Self.dedupById(grapeVarieties) { $0.id }
        operatorCategories = Self.dedupById(operatorCategories) { $0.id }
        operatorCategories = Self.dedupOperatorCategoriesByVineyardAndName(operatorCategories)
        buttonTemplates = Self.dedupById(buttonTemplates) { $0.id }
        buttonTemplates = Self.dedupTemplatesByNameModeVineyard(buttonTemplates)
        buttonTemplates = Self.collapseDefaultTemplates(buttonTemplates)
        tractors = Self.dedupById(tractors) { $0.id }
        vineyardMachines = Self.dedupById(vineyardMachines) { $0.id }
        fuelPurchases = Self.dedupById(fuelPurchases) { $0.id }
        tractorFuelLogs = Self.dedupById(tractorFuelLogs) { $0.id }

        if grapeVarieties.count != originalGrape {
            persistence.save(grapeVarieties, key: Keys.grapeVarieties)
        }
        if operatorCategories.count != originalOps {
            persistence.save(operatorCategories, key: Keys.operatorCategories)
        }
        if buttonTemplates.count != originalTemplates {
            persistence.save(buttonTemplates, key: Keys.buttonTemplates)
        }
        if tractors.count != originalTractors {
            persistence.save(tractors, key: Keys.tractors)
        }
        if vineyardMachines.count != originalMachines {
            persistence.save(vineyardMachines, key: Keys.vineyardMachines)
        }
        if fuelPurchases.count != originalFuel {
            persistence.save(fuelPurchases, key: Keys.fuelPurchases)
        }
        if tractorFuelLogs.count != originalFuelLogs {
            persistence.save(tractorFuelLogs, key: Keys.tractorFuelLogs)
        }
    }

    private static func dedupById<T>(_ items: [T], id: (T) -> UUID) -> [T] {
        var seen = Set<UUID>()
        var result: [T] = []
        result.reserveCapacity(items.count)
        for item in items {
            if seen.insert(id(item)).inserted {
                result.append(item)
            }
        }
        return result
    }

    /// Collapse legacy seeded duplicates of the canonical "Default Repairs" /
    /// "Default Growth" templates so each vineyard ends up with at most one of
    /// each. Non-default templates (user-created with custom names) are
    /// preserved untouched.
    private static func collapseDefaultTemplates(_ items: [ButtonTemplate]) -> [ButtonTemplate] {
        var seenDefault = Set<String>()
        var result: [ButtonTemplate] = []
        result.reserveCapacity(items.count)
        for item in items {
            let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isDefault: Bool
            switch item.mode {
            case .repairs: isDefault = trimmed.hasPrefix("default repair")
            case .growth: isDefault = trimmed.hasPrefix("default growth")
            }
            if isDefault {
                let key = "\(item.vineyardId.uuidString)|\(item.mode.rawValue)"
                if seenDefault.insert(key).inserted {
                    result.append(item)
                }
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// Collapse operator categories that share the same (vineyardId, lowercased name).
    /// Keeps the entry with the highest costPerHour; ties keep the first occurrence.
    /// Used at load time to clean up duplicates accumulated from earlier sync bugs
    /// or cross-client creates with the same name.
    private static func dedupOperatorCategoriesByVineyardAndName(_ items: [OperatorCategory]) -> [OperatorCategory] {
        var seen: [String: Int] = [:]
        var result: [OperatorCategory] = []
        result.reserveCapacity(items.count)
        for item in items {
            let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let key = "\(item.vineyardId.uuidString)|\(trimmed)"
            if let idx = seen[key] {
                if item.costPerHour > result[idx].costPerHour {
                    result[idx] = item
                }
            } else {
                seen[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    private static func dedupTemplatesByNameModeVineyard(_ items: [ButtonTemplate]) -> [ButtonTemplate] {
        var seen = Set<String>()
        var result: [ButtonTemplate] = []
        result.reserveCapacity(items.count)
        for item in items {
            let key = "\(item.vineyardId.uuidString)|\(item.mode.rawValue)|\(item.name.lowercased())"
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    /// Reload all per-vineyard scoped collections from disk for the currently selected vineyard.
    func reloadCurrentVineyardData() {
        guard let vineyardId = selectedVineyardId else {
            pins = []
            paddocks = []
            trips = []
            sprayRecords = []
            savedChemicals = []
            savedSprayPresets = []
            savedEquipmentOptions = []
            sprayEquipment = []
            savedInputs = []
            tripCostAllocations = []
            yieldSessions = []
            damageRecords = []
            historicalYieldRecords = []
            yieldDeterminationResults = []
            maintenanceLogs = []
            workTasks = []
            workTaskLabourLines = []
            workTaskMachineLines = []
            workTaskPaddocks = []
            workTaskTypes = []
            equipmentItems = []
            settings = AppSettings()
            return
        }

        pins = pinRepo.load(for: vineyardId)
        trips = tripRepo.load(for: vineyardId)
        workTasks = workTaskRepo.load(for: vineyardId)
        workTaskLabourLines = workTaskLabourLineRepo.load(for: vineyardId)
        workTaskMachineLines = workTaskMachineLineRepo.load(for: vineyardId)
        workTaskPaddocks = workTaskPaddockRepo.load(for: vineyardId)
        workTaskTypes = workTaskTypeRepo.load(for: vineyardId)
        equipmentItems = equipmentItemRepo.load(for: vineyardId)
        maintenanceLogs = maintenanceLogRepo.load(for: vineyardId)

        sprayRecords = sprayRepo.loadRecords(for: vineyardId)
        savedChemicals = sprayRepo.loadChemicals(for: vineyardId)
        savedSprayPresets = sprayRepo.loadPresets(for: vineyardId)
        savedEquipmentOptions = sprayRepo.loadEquipmentOptions(for: vineyardId)
        sprayEquipment = sprayRepo.loadEquipment(for: vineyardId)
        savedInputs = savedInputRepo.load(for: vineyardId)
        tripCostAllocations = tripCostAllocationRepo.load(for: vineyardId)

        yieldSessions = yieldRepo.loadSessions(for: vineyardId)
        damageRecords = yieldRepo.loadDamage(for: vineyardId)
        historicalYieldRecords = yieldRepo.loadHistorical(for: vineyardId)
        yieldDeterminationResults = yieldRepo.loadDetermination(for: vineyardId)

        settings = settingsRepo.load(for: vineyardId)

        let allPaddocks: [Paddock] = persistence.load(key: Keys.paddocks) ?? []
        paddocks = allPaddocks.filter { $0.vineyardId == vineyardId }

        loadButtonsForCurrentVineyard()

        // After paddocks + varieties are loaded for this vineyard, repair
        // any drift between built-in variety ids and existing block
        // allocations (e.g. duplicate seedings from earlier app versions).
        GrapeVarietyCanonicalization.run(store: self)
    }

    /// Clear in-memory state without touching disk.
    func clearInMemoryState() {
        vineyards = []
        selectedVineyardId = nil
        pins = []
        paddocks = []
        trips = []
        repairButtons = []
        growthButtons = []
        settings = AppSettings()
        savedCustomPatterns = []
        sprayRecords = []
        savedChemicals = []
        savedSprayPresets = []
        savedEquipmentOptions = []
        sprayEquipment = []
        savedInputs = []
        tripCostAllocations = []
        tractors = []
        vineyardMachines = []
        fuelPurchases = []
        tractorFuelLogs = []
        operatorCategories = []
        buttonTemplates = []
        yieldSessions = []
        damageRecords = []
        historicalYieldRecords = []
        yieldDeterminationResults = []
        maintenanceLogs = []
        workTasks = []
        workTaskLabourLines = []
        workTaskMachineLines = []
        workTaskPaddocks = []
        workTaskTypes = []
        equipmentItems = []
        grapeVarieties = []
        selectedTab = 0
    }

    /// Wipe all locally persisted data and reset in-memory state.
    func deleteAllLocalData() {
        // Per-vineyard button config keys must be removed for every known vineyard.
        for vineyard in vineyards {
            persistence.remove(key: Self.repairButtonsKey(for: vineyard.id))
            persistence.remove(key: Self.growthButtonsKey(for: vineyard.id))
        }
        let keys: [String] = [
            VineyardRepository.storageKey,
            PinRepository.storageKey,
            TripRepository.storageKey,
            WorkTaskRepository.storageKey,
            WorkTaskLabourLineRepository.storageKey,
            WorkTaskMachineLineRepository.storageKey,
            WorkTaskPaddockRepository.storageKey,
            WorkTaskTypeRepository.storageKey,
            EquipmentItemRepository.storageKey,
            MaintenanceLogRepository.storageKey,
            SprayRepository.recordsKey,
            SprayRepository.savedChemicalsKey,
            SprayRepository.savedPresetsKey,
            SprayRepository.savedEquipmentOptionsKey,
            SprayRepository.equipmentKey,
            SavedInputRepository.storageKey,
            TripCostAllocationRepository.storageKey,
            SettingsRepository.storageKey,
            YieldRepository.sessionsKey,
            YieldRepository.damageKey,
            YieldRepository.historicalKey,
            Keys.paddocks,
            Keys.repairButtons,
            Keys.growthButtons,
            Keys.savedCustomPatterns,
            Keys.tractors,
            Keys.fuelPurchases,
            Keys.tractorFuelLogs,
            Keys.operatorCategories,
            Keys.buttonTemplates,
            Keys.grapeVarieties,
            Keys.selectedVineyardId,
        ]
        for key in keys {
            persistence.remove(key: key)
        }
        clearInMemoryState()
    }

    // MARK: - Vineyard selection

    var selectedVineyard: Vineyard? {
        guard let id = selectedVineyardId else { return nil }
        return vineyards.first { $0.id == id }
    }

    func selectVineyard(_ vineyard: Vineyard) {
        selectedVineyardId = vineyard.id
        persistence.save(SelectedVineyardWrapper(id: vineyard.id), key: Keys.selectedVineyardId)
        reloadCurrentVineyardData()
        // Pull the vineyard's shared Davis WeatherLink integration so all
        // weather call sites (resolver, rainfall history, hourly service,
        // alerts) see the configured station immediately on switch —
        // operators included.
        Task { await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: vineyard.id) }
    }

    /// Resolve which vineyard should be active using:
    /// 1. profile default if user is still a member
    /// 2. existing local selection if still valid
    /// 3. first available vineyard
    /// 4. nil (caller should show picker)
    func applyDefaultVineyardSelection(defaultId: UUID?) {
        let memberIds = Set(vineyards.map { $0.id })

        if let defaultId, memberIds.contains(defaultId) {
            if selectedVineyardId != defaultId {
                selectedVineyardId = defaultId
                persistence.save(SelectedVineyardWrapper(id: defaultId), key: Keys.selectedVineyardId)
                reloadCurrentVineyardData()
            }
            Task { await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: defaultId) }
            return
        }

        if let id = selectedVineyardId, memberIds.contains(id) {
            Task { await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: id) }
            return
        }

        if let first = vineyards.first {
            selectedVineyardId = first.id
            persistence.save(SelectedVineyardWrapper(id: first.id), key: Keys.selectedVineyardId)
            reloadCurrentVineyardData()
            Task { await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: first.id) }
        } else {
            selectedVineyardId = nil
            persistence.remove(key: Keys.selectedVineyardId)
            reloadCurrentVineyardData()
        }
    }

    // MARK: - Image cache hydration

    /// On cold launch, refill any missing `logoData` from the on-disk shared
    /// image cache so the vineyard logo is visible immediately, before any
    /// network sync has run.
    private func hydrateVineyardLogosFromCache() {
        var changed = false
        for index in vineyards.indices {
            let vineyard = vineyards[index]
            guard vineyard.logoData == nil, vineyard.logoPath != nil else { continue }
            if let cached = SharedImageCache.shared.cachedImageData(
                for: .vineyardLogo(vineyardId: vineyard.id)
            ) {
                vineyards[index].logoData = cached
                changed = true
            }
        }
        if changed {
            vineyardRepo.saveAll(vineyards)
        }
    }

    // MARK: - Vineyard upsert

    func upsertLocalVineyard(_ vineyard: Vineyard) {
        vineyards = vineyardRepo.upsert(vineyard)
        if selectedVineyardId == nil {
            selectVineyard(vineyard)
        }
    }

    func upsertLocalVineyards(_ items: [Vineyard]) {
        for item in items {
            vineyards = vineyardRepo.upsert(item)
        }
        if selectedVineyardId == nil, let first = vineyards.first {
            selectVineyard(first)
        }
    }

    /// Map BackendVineyard records into the local `Vineyard` model, preserving local
    /// fields like `users` and any cached `logoData` where possible. If the
    /// backend reports a newer `logoUpdatedAt` than the local cache, the cached
    /// `logoData` is cleared so the next refresh redownloads it.
    func mapBackendVineyardsIntoLocal(_ backendVineyards: [BackendVineyard]) {
        let existing = vineyardRepo.loadAll()
        var merged: [Vineyard] = []
        for backend in backendVineyards {
            if let local = existing.first(where: { $0.id == backend.id }) {
                var updated = local
                updated.name = backend.name
                updated.country = backend.country ?? local.country
                updated.logoPath = backend.logoPath
                let remoteUpdated = backend.logoUpdatedAt
                let localUpdated = local.logoUpdatedAt
                if backend.logoPath == nil {
                    // Remote authoritatively says no logo — clear local cache.
                    updated.logoData = nil
                    updated.logoUpdatedAt = nil
                    SharedImageCache.shared.removeCachedImage(
                        for: .vineyardLogo(vineyardId: backend.id)
                    )
                } else if let remoteUpdated, localUpdated != remoteUpdated {
                    // Remote logo changed. Keep showing the existing cached
                    // image until the new one downloads successfully; just
                    // mark the cache stale and update the timestamp pointer.
                    SharedImageCache.shared.markStale(
                        for: .vineyardLogo(vineyardId: backend.id)
                    )
                    updated.logoUpdatedAt = remoteUpdated
                } else {
                    updated.logoUpdatedAt = remoteUpdated ?? localUpdated
                }
                if updated.logoData == nil, updated.logoPath != nil,
                   let cached = SharedImageCache.shared.cachedImageData(
                       for: .vineyardLogo(vineyardId: backend.id)
                   ) {
                    updated.logoData = cached
                }
                merged.append(updated)
            } else {
                let cached = SharedImageCache.shared.cachedImageData(
                    for: .vineyardLogo(vineyardId: backend.id)
                )
                let mapped = Vineyard(
                    id: backend.id,
                    name: backend.name,
                    users: [],
                    createdAt: backend.createdAt ?? Date(),
                    logoData: cached,
                    country: backend.country ?? "",
                    logoPath: backend.logoPath,
                    logoUpdatedAt: backend.logoUpdatedAt
                )
                merged.append(mapped)
            }
        }
        vineyardRepo.saveAll(merged)
        vineyards = merged

        if selectedVineyardId == nil, let first = merged.first {
            selectedVineyardId = first.id
            persistence.save(SelectedVineyardWrapper(id: first.id), key: Keys.selectedVineyardId)
        } else if let id = selectedVineyardId, !merged.contains(where: { $0.id == id }) {
            selectedVineyardId = merged.first?.id
            if let id = selectedVineyardId {
                persistence.save(SelectedVineyardWrapper(id: id), key: Keys.selectedVineyardId)
            } else {
                persistence.remove(key: Keys.selectedVineyardId)
            }
        }

        reloadCurrentVineyardData()
    }

    // MARK: - Pin CRUD

    func addPin(_ pin: VinePin) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = pin
        item.vineyardId = vineyardId
        // Self-heal: stamp the current authenticated user as the creator if
        // the caller forgot to plumb auth through. Never overwrite an
        // existing non-nil value.
        if item.createdByUserId == nil, let uid = currentUserIdProvider?() {
            item.createdByUserId = uid
            if (item.createdBy ?? "").isEmpty,
               let name = currentUserNameProvider?(), !name.isEmpty {
                item.createdBy = name
            }
            #if DEBUG
            print("[Pins] addPin self-stamped createdByUserId=\(uid) on pin \(item.id)")
            #endif
        }
        #if DEBUG
        print("[Pins] addPin id=\(item.id) createdBy=\(item.createdBy ?? "nil") createdByUserId=\(item.createdByUserId?.uuidString ?? "nil")")
        #endif
        // Self-heal: if a trip is active and the pin wasn't already
        // linked, associate it with the trip so the Trip Report can
        // show "Pins logged" > 0 and Supabase keeps a pin↔trip link.
        if item.tripId == nil, let activeTripId = currentActiveTripIdProvider?() {
            item.tripId = activeTripId
            #if DEBUG
            print("[Pins] addPin self-linked tripId=\(activeTripId) on pin \(item.id)")
            #endif
        }
        pins.append(item)
        pinRepo.saveSlice(pins, for: vineyardId)
        // Mirror growth-stage pins into the dedicated growth_stage_records
        // table for the Lovable Growth Stage Records page. Legacy pin-based
        // growth observations remain authoritative for the iOS workflow.
        if item.mode == .growth, item.growthStageCode != nil {
            #if DEBUG
            print("[Pins] addPin firing onGrowthStagePinAdded? \(onGrowthStagePinAdded != nil) for pin=\(item.id) code=\(item.growthStageCode ?? "nil")")
            #endif
            onGrowthStagePinAdded?(item)
        }
        // Append to the active trip's pinIds so the saved trip record
        // carries the association even if downstream code only reads
        // `trip.pinIds` (e.g. PDF export, Lovable trip report).
        if let tripId = item.tripId,
           let idx = trips.firstIndex(where: { $0.id == tripId }),
           !trips[idx].pinIds.contains(item.id) {
            trips[idx].pinIds.append(item.id)
            tripRepo.saveSlice(trips, for: vineyardId)
            onTripChanged?(tripId)
        }
        onPinChanged?(item.id)
    }

    func updatePin(_ pin: VinePin) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        var item = pin
        // Self-heal: never push a pin with a nil createdByUserId if we have
        // an authenticated user available locally.
        if item.createdByUserId == nil, let uid = currentUserIdProvider?() {
            item.createdByUserId = uid
            if (item.createdBy ?? "").isEmpty,
               let name = currentUserNameProvider?(), !name.isEmpty {
                item.createdBy = name
            }
            #if DEBUG
            print("[Pins] updatePin self-stamped createdByUserId=\(uid) on pin \(item.id)")
            #endif
        }
        pins[index] = item
        pinRepo.saveSlice(pins, for: vineyardId)
        onPinChanged?(item.id)
    }

    func deletePin(_ pinId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        let wasGrowthStagePin = pins.first(where: { $0.id == pinId })?.growthStageCode != nil
        pins.removeAll { $0.id == pinId }
        pinRepo.saveSlice(pins, for: vineyardId)
        onPinDeleted?(pinId)
        if wasGrowthStagePin {
            onGrowthStagePinDeleted?(pinId)
        }
    }

    func togglePinCompletion(_ pinId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = pins.firstIndex(where: { $0.id == pinId }) else { return }
        var pin = pins[index]
        pin.isCompleted.toggle()
        pin.completedAt = pin.isCompleted ? Date() : nil
        pins[index] = pin
        pinRepo.saveSlice(pins, for: vineyardId)
        onPinChanged?(pinId)
    }

    /// Apply a pin upsert that originated from a remote sync pull. Does NOT
    /// trigger `onPinChanged` (avoids re-marking the pin dirty).
    func applyRemotePinUpsert(_ pin: VinePin) {
        guard let vineyardId = selectedVineyardId, pin.vineyardId == vineyardId else {
            // Still persist into the appropriate slice on disk so it surfaces
            // when the user switches vineyards.
            var allPins = pinRepo.loadAll()
            if let idx = allPins.firstIndex(where: { $0.id == pin.id }) {
                allPins[idx] = pin
            } else {
                allPins.append(pin)
            }
            pinRepo.replace(allPins.filter { $0.vineyardId == pin.vineyardId }, for: pin.vineyardId)
            return
        }
        if let idx = pins.firstIndex(where: { $0.id == pin.id }) {
            pins[idx] = pin
        } else {
            pins.append(pin)
        }
        pinRepo.saveSlice(pins, for: vineyardId)
    }

    /// Apply a pin deletion that originated from a remote sync pull.
    func applyRemotePinDelete(_ pinId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        pins.removeAll { $0.id == pinId }
        pinRepo.saveSlice(pins, for: vineyardId)
    }

    // MARK: - Paddock CRUD

    /// Public hook used by `GrapeVarietyCanonicalization` to persist
    /// repaired allocations back to disk and notify sync of the changes.
    func persistPaddocksAfterRepair() {
        savePaddocksToDisk()
        guard let vineyardId = selectedVineyardId else { return }
        for paddock in paddocks where paddock.vineyardId == vineyardId {
            onPaddockChanged?(paddock.id)
        }
    }

    private func savePaddocksToDisk() {
        guard let vineyardId = selectedVineyardId else { return }
        var all: [Paddock] = persistence.load(key: Keys.paddocks) ?? []
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: paddocks)
        persistence.save(all, key: Keys.paddocks)
    }

    func addPaddock(_ paddock: Paddock) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = paddock
        item.vineyardId = vineyardId
        paddocks.append(item)
        savePaddocksToDisk()
        onPaddockChanged?(item.id)
    }

    func updatePaddock(_ paddock: Paddock) {
        guard let index = paddocks.firstIndex(where: { $0.id == paddock.id }) else { return }
        paddocks[index] = paddock
        savePaddocksToDisk()
        onPaddockChanged?(paddock.id)
    }

    func deletePaddock(_ paddockId: UUID) {
        // Clean up local references that depend on this paddock BEFORE removing
        // it so nothing is left pointing at a missing paddock. Each helper marks
        // the affected record dirty so the cleared link propagates. Rows live
        // inside `paddock.rows`, so they are removed with the paddock itself.
        clearPaddockLinkOnPins(paddockId: paddockId, propagate: true)
        clearPaddockLinkOnTrips(paddockId: paddockId, propagate: true)
        removeWorkTaskPaddockLinks(paddockId: paddockId, propagate: true)
        paddocks.removeAll { $0.id == paddockId }
        savePaddocksToDisk()
        onPaddockDeleted?(paddockId)
    }

    /// Clear the `paddockId` link on any pins attached to `paddockId`. Keeps the
    /// pin/observation and preserves its `rowNumber`/`alongRowDistanceM` as
    /// historical context. When `propagate` is true the cleared link is pushed
    /// via the normal dirty path; when false (remote delete) the change is
    /// applied locally only.
    private func clearPaddockLinkOnPins(paddockId: UUID, propagate: Bool) {
        let owned = pins.filter { $0.paddockId == paddockId }
        guard !owned.isEmpty else { return }
        for var pin in owned {
            pin.paddockId = nil
            if propagate {
                updatePin(pin)
            } else {
                applyRemotePinUpsert(pin)
            }
        }
    }

    /// Clear the `paddockId`/`paddockIds` links on any trips that reference the
    /// deleted paddock. The trip itself (path, duration, cost, machine,
    /// operator, Work Task link) is untouched. When `propagate` is true the
    /// change is pushed via the normal dirty path; when false (remote delete)
    /// it is applied locally only.
    private func clearPaddockLinkOnTrips(paddockId: UUID, propagate: Bool) {
        let affected = trips.filter { $0.paddockId == paddockId || $0.paddockIds.contains(paddockId) }
        guard !affected.isEmpty else { return }
        for var trip in affected {
            if trip.paddockId == paddockId { trip.paddockId = nil }
            trip.paddockIds.removeAll { $0 == paddockId }
            if propagate {
                updateTrip(trip)
            } else {
                applyRemoteTripUpsert(trip)
            }
        }
    }

    /// Remove any `WorkTaskPaddock` join records that reference the deleted
    /// paddock so Work Task summaries stop counting it. The Work Task and its
    /// labour/machine lines are untouched. When `propagate` is true the join
    /// removal is synced; when false (remote delete) it is purged locally only.
    private func removeWorkTaskPaddockLinks(paddockId: UUID, propagate: Bool) {
        let links = workTaskPaddocks.filter { $0.paddockId == paddockId }
        guard !links.isEmpty else { return }
        for link in links {
            if propagate {
                deleteWorkTaskPaddock(link.id)
            } else {
                applyRemoteWorkTaskPaddockDelete(link.id)
            }
        }
    }

    /// Apply a paddock upsert that originated from a remote sync pull. Does NOT
    /// trigger `onPaddockChanged` (avoids re-marking the paddock dirty).
    func applyRemotePaddockUpsert(_ paddock: Paddock) {
        if selectedVineyardId == paddock.vineyardId {
            if let idx = paddocks.firstIndex(where: { $0.id == paddock.id }) {
                paddocks[idx] = paddock
            } else {
                paddocks.append(paddock)
            }
            savePaddocksToDisk()
        } else {
            // Persist into the on-disk slice so it surfaces when switching vineyards.
            var all: [Paddock] = persistence.load(key: Keys.paddocks) ?? []
            if let idx = all.firstIndex(where: { $0.id == paddock.id }) {
                all[idx] = paddock
            } else {
                all.append(paddock)
            }
            persistence.save(all, key: Keys.paddocks)
        }
    }

    /// Apply a paddock deletion that originated from a remote sync pull.
    func applyRemotePaddockDelete(_ paddockId: UUID) {
        // Repair local orphaned links even when the delete came from another
        // device. The server cascade/constraint already handled the remote
        // rows, so apply the cleanup locally without re-propagating.
        clearPaddockLinkOnPins(paddockId: paddockId, propagate: false)
        clearPaddockLinkOnTrips(paddockId: paddockId, propagate: false)
        removeWorkTaskPaddockLinks(paddockId: paddockId, propagate: false)
        paddocks.removeAll { $0.id == paddockId }
        if selectedVineyardId != nil {
            savePaddocksToDisk()
        } else {
            var all: [Paddock] = persistence.load(key: Keys.paddocks) ?? []
            all.removeAll { $0.id == paddockId }
            persistence.save(all, key: Keys.paddocks)
        }
    }

    // MARK: - Trip CRUD

    func startTrip(_ trip: Trip) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = trip
        item.vineyardId = vineyardId
        item.isActive = true
        trips.append(item)
        tripRepo.saveSlice(trips, for: vineyardId)
        onTripChanged?(item.id)
    }

    /// Add a trip without marking it active. Used for "Save Job for Later"
    /// flows where a placeholder trip is needed but should not auto-start.
    func addInactiveTrip(_ trip: Trip) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = trip
        item.vineyardId = vineyardId
        item.isActive = false
        trips.append(item)
        tripRepo.saveSlice(trips, for: vineyardId)
        onTripChanged?(item.id)
    }

    func updateTrip(_ trip: Trip) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        trips[index] = trip
        tripRepo.saveSlice(trips, for: vineyardId)
        onTripChanged?(trip.id)
    }

    func endTrip(_ tripId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = trips.firstIndex(where: { $0.id == tripId }) else { return }
        var trip = trips[index]
        trip.isActive = false
        trip.endTime = Date()
        trips[index] = trip
        tripRepo.saveSlice(trips, for: vineyardId)
        onTripChanged?(tripId)
    }

    func deleteTrip(_ tripId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        // Clean up local links that depend on this trip BEFORE removing it so
        // nothing is left pointing at a missing trip.
        // 1. Trip cost allocations — soft-delete locally and propagate so the
        //    server rows are removed too.
        deleteTripCostAllocations(tripId: tripId)
        // 2. Pins that are trip-owned — clear the dangling trip link but keep
        //    the observation. Propagated via updatePin (marks dirty).
        clearTripLinkOnPins(tripId: tripId, propagate: true)
        trips.removeAll { $0.id == tripId }
        tripRepo.saveSlice(trips, for: vineyardId)
        // Fires markTripDeleted on the sync service, which also drops any
        // pending work_task_id clear for this trip (subsumed by the delete).
        onTripDeleted?(tripId)
    }

    /// Clear the `tripId` link on any pins owned by `tripId`. Keeps the pin
    /// (observations are independent of trips). When `propagate` is true the
    /// cleared link is pushed via the normal dirty path; when false (remote
    /// delete) the change is applied locally only.
    private func clearTripLinkOnPins(tripId: UUID, propagate: Bool) {
        let owned = pins.filter { $0.tripId == tripId }
        guard !owned.isEmpty else { return }
        for var pin in owned {
            pin.tripId = nil
            if propagate {
                updatePin(pin)
            } else {
                applyRemotePinUpsert(pin)
            }
        }
    }

    /// Apply a trip upsert that originated from a remote sync pull. Does NOT
    /// trigger `onTripChanged` (avoids re-marking the trip dirty).
    func applyRemoteTripUpsert(_ trip: Trip) {
        if selectedVineyardId == trip.vineyardId {
            if let idx = trips.firstIndex(where: { $0.id == trip.id }) {
                trips[idx] = trip
            } else {
                trips.append(trip)
            }
            if let vineyardId = selectedVineyardId {
                tripRepo.saveSlice(trips, for: vineyardId)
            }
        } else {
            // Persist into the on-disk slice for the trip's vineyard so it
            // surfaces when switching vineyards.
            var all = tripRepo.loadAll()
            if let idx = all.firstIndex(where: { $0.id == trip.id }) {
                all[idx] = trip
            } else {
                all.append(trip)
            }
            tripRepo.replace(all.filter { $0.vineyardId == trip.vineyardId }, for: trip.vineyardId)
        }
    }

    /// Apply a trip deletion that originated from a remote sync pull.
    func applyRemoteTripDelete(_ tripId: UUID) {
        // Repair local orphaned links even when the delete came from another
        // device. The server cascade already removed the remote rows, so purge
        // the local cache without re-propagating.
        purgeTripCostAllocationsLocally(tripId: tripId)
        clearTripLinkOnPins(tripId: tripId, propagate: false)
        if let vineyardId = selectedVineyardId {
            trips.removeAll { $0.id == tripId }
            tripRepo.saveSlice(trips, for: vineyardId)
        }
        var all = tripRepo.loadAll()
        if let removed = all.first(where: { $0.id == tripId }) {
            all.removeAll { $0.id == tripId }
            tripRepo.replace(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - SprayRecord CRUD

    func addSprayRecord(_ record: SprayRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = record
        item.vineyardId = vineyardId
        sprayRecords.append(item)
        sprayRepo.saveRecordsSlice(sprayRecords, for: vineyardId)
        onSprayRecordChanged?(item.id)
    }

    func updateSprayRecord(_ record: SprayRecord) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = sprayRecords.firstIndex(where: { $0.id == record.id }) else { return }
        sprayRecords[index] = record
        sprayRepo.saveRecordsSlice(sprayRecords, for: vineyardId)
        onSprayRecordChanged?(record.id)
    }

    func deleteSprayRecord(_ recordId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        sprayRecords.removeAll { $0.id == recordId }
        sprayRepo.saveRecordsSlice(sprayRecords, for: vineyardId)
        onSprayRecordDeleted?(recordId)
    }

    /// Apply a spray record upsert that originated from a remote sync pull. Does NOT
    /// trigger `onSprayRecordChanged` (avoids re-marking the record dirty).
    func applyRemoteSprayRecordUpsert(_ record: SprayRecord) {
        if selectedVineyardId == record.vineyardId {
            if let idx = sprayRecords.firstIndex(where: { $0.id == record.id }) {
                sprayRecords[idx] = record
            } else {
                sprayRecords.append(record)
            }
            if let vineyardId = selectedVineyardId {
                sprayRepo.saveRecordsSlice(sprayRecords, for: vineyardId)
            }
        } else {
            var all = sprayRepo.loadAllRecords()
            if let idx = all.firstIndex(where: { $0.id == record.id }) {
                all[idx] = record
            } else {
                all.append(record)
            }
            sprayRepo.replaceRecords(all.filter { $0.vineyardId == record.vineyardId }, for: record.vineyardId)
        }
    }

    /// Apply a spray record deletion that originated from a remote sync pull.
    func applyRemoteSprayRecordDelete(_ recordId: UUID) {
        if let vineyardId = selectedVineyardId {
            sprayRecords.removeAll { $0.id == recordId }
            sprayRepo.saveRecordsSlice(sprayRecords, for: vineyardId)
        }
        var all = sprayRepo.loadAllRecords()
        if let removed = all.first(where: { $0.id == recordId }) {
            all.removeAll { $0.id == recordId }
            sprayRepo.replaceRecords(all.filter { $0.vineyardId == removed.vineyardId }, for: removed.vineyardId)
        }
    }

    // MARK: - MaintenanceLog CRUD

    func addMaintenanceLog(_ log: MaintenanceLog) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = log
        item.vineyardId = vineyardId
        maintenanceLogs.append(item)
        maintenanceLogRepo.saveSlice(maintenanceLogs, for: vineyardId)
        onMaintenanceLogChanged?(item.id)
    }

    func updateMaintenanceLog(_ log: MaintenanceLog) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = maintenanceLogs.firstIndex(where: { $0.id == log.id }) else { return }
        maintenanceLogs[index] = log
        maintenanceLogRepo.saveSlice(maintenanceLogs, for: vineyardId)
        onMaintenanceLogChanged?(log.id)
    }

    func deleteMaintenanceLog(_ logId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        maintenanceLogs.removeAll { $0.id == logId }
        maintenanceLogRepo.saveSlice(maintenanceLogs, for: vineyardId)
        onMaintenanceLogDeleted?(logId)
    }

    // MARK: - WorkTask CRUD

    func addWorkTask(_ task: WorkTask) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = task
        item.vineyardId = vineyardId
        workTasks.append(item)
        workTaskRepo.saveSlice(workTasks, for: vineyardId)
        onWorkTaskChanged?(item.id)
    }

    func updateWorkTask(_ task: WorkTask) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTasks.firstIndex(where: { $0.id == task.id }) else { return }
        workTasks[index] = task
        workTaskRepo.saveSlice(workTasks, for: vineyardId)
        onWorkTaskChanged?(task.id)
    }

    func deleteWorkTask(_ taskId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        workTasks.removeAll { $0.id == taskId }
        workTaskRepo.saveSlice(workTasks, for: vineyardId)
        onWorkTaskDeleted?(taskId)
    }

    // MARK: - WorkTaskLabourLine CRUD

    func addWorkTaskLabourLine(_ line: WorkTaskLabourLine) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = line
        item.vineyardId = vineyardId
        workTaskLabourLines.append(item)
        workTaskLabourLineRepo.saveSlice(workTaskLabourLines, for: vineyardId)
        onWorkTaskLabourLineChanged?(item.id)
    }

    func updateWorkTaskLabourLine(_ line: WorkTaskLabourLine) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTaskLabourLines.firstIndex(where: { $0.id == line.id }) else { return }
        workTaskLabourLines[index] = line
        workTaskLabourLineRepo.saveSlice(workTaskLabourLines, for: vineyardId)
        onWorkTaskLabourLineChanged?(line.id)
    }

    func deleteWorkTaskLabourLine(_ lineId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        workTaskLabourLines.removeAll { $0.id == lineId }
        workTaskLabourLineRepo.saveSlice(workTaskLabourLines, for: vineyardId)
        onWorkTaskLabourLineDeleted?(lineId)
    }

    // MARK: - WorkTaskMachineLine CRUD

    func addWorkTaskMachineLine(_ line: WorkTaskMachineLine) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = line
        item.vineyardId = vineyardId
        workTaskMachineLines.append(item)
        workTaskMachineLineRepo.saveSlice(workTaskMachineLines, for: vineyardId)
        onWorkTaskMachineLineChanged?(item.id)
    }

    func updateWorkTaskMachineLine(_ line: WorkTaskMachineLine) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTaskMachineLines.firstIndex(where: { $0.id == line.id }) else { return }
        workTaskMachineLines[index] = line
        workTaskMachineLineRepo.saveSlice(workTaskMachineLines, for: vineyardId)
        onWorkTaskMachineLineChanged?(line.id)
    }

    func deleteWorkTaskMachineLine(_ lineId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        workTaskMachineLines.removeAll { $0.id == lineId }
        workTaskMachineLineRepo.saveSlice(workTaskMachineLines, for: vineyardId)
        onWorkTaskMachineLineDeleted?(lineId)
    }

    // MARK: - WorkTaskPaddock CRUD

    func addWorkTaskPaddock(_ paddock: WorkTaskPaddock) {
        guard let vineyardId = selectedVineyardId else { return }
        var item = paddock
        item.vineyardId = vineyardId
        workTaskPaddocks.append(item)
        workTaskPaddockRepo.saveSlice(workTaskPaddocks, for: vineyardId)
        onWorkTaskPaddockChanged?(item.id)
    }

    func updateWorkTaskPaddock(_ paddock: WorkTaskPaddock) {
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTaskPaddocks.firstIndex(where: { $0.id == paddock.id }) else { return }
        workTaskPaddocks[index] = paddock
        workTaskPaddockRepo.saveSlice(workTaskPaddocks, for: vineyardId)
        onWorkTaskPaddockChanged?(paddock.id)
    }

    func deleteWorkTaskPaddock(_ paddockRowId: UUID) {
        guard let vineyardId = selectedVineyardId else { return }
        workTaskPaddocks.removeAll { $0.id == paddockRowId }
        workTaskPaddockRepo.saveSlice(workTaskPaddocks, for: vineyardId)
        onWorkTaskPaddockDeleted?(paddockRowId)
    }

    // MARK: - Settings

    func saveSettings(_ newSettings: AppSettings) {
        settings = newSettings
        settingsRepo.upsert(newSettings)
    }
}

private nonisolated struct SelectedVineyardWrapper: Codable, Sendable {
    let id: UUID
}
