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

    @ObservationIgnored var operationalWriteAuthority: VineyardWriteAuthority = .shared
    private func admitSelectedMutation() -> Bool {
        guard let vineyard = selectedVineyardId else { return true }
        return operationalWriteAuthority.admit(vineyardId: vineyard.uuidString)
    }

    #if DEBUG
    @ObservationIgnored var switchPerformanceSample: ((VineyardSwitchPerformanceProbe.Sample) -> Void)?
    @ObservationIgnored var preparedSelectionMeasurement: ((String, Double) -> Void)?
    #endif

    // MARK: - State

    var vineyards: [Vineyard] = []
    var selectedVineyardId: UUID?
    /// Presentation acknowledges the request while operational authority keeps
    /// its complete old slice until the atomic, non-suspending commit.
    private(set) var preparingVineyard: Vineyard?
    @ObservationIgnored private var vineyardPreparationGeneration: UInt64 = 0
    var vineyardSelectionGeneration: UInt64 { vineyardPreparationGeneration }
    @ObservationIgnored private(set) var deferredSelectionRepairs: Task<Void, Never>?
    @ObservationIgnored var canDeleteWorkerType: (UUID) -> Bool = { _ in false }

    var pins: [VinePin] = [] {
        didSet {
            #if DEBUG
            SyntheticHomePerformanceProbe.publication()
            #endif
        }
    }
    var paddocks: [Paddock] = []
    var trips: [Trip] = [] {
        didSet {
            #if DEBUG
            SyntheticHomePerformanceProbe.publication()
            #endif
        }
    }
    /// The UUID claimed by this device, never inferred from server-active rows.
    private struct DeviceTripOwnership: Codable {
        let tripId: UUID
        let userId: UUID?
    }
    private var deviceTripOwnership: DeviceTripOwnership?
    @ObservationIgnored var onOwnedTripCompletedByServer: ((UUID) -> Void)?
    var deviceActiveTripId: UUID? { deviceTripOwnership?.tripId }
    var isDeviceTripOwner: Bool {
        guard let ownership = deviceTripOwnership else { return false }
        return ownership.userId == currentUserIdProvider?()
    }

    var deviceOwnedTrip: Trip? {
        guard isDeviceTripOwner, let id = deviceActiveTripId else { return nil }
        if let trip = trips.first(where: { $0.id == id }) { return trip.isActive ? trip : nil }
        for vineyard in vineyards where vineyard.id != selectedVineyardId {
            if let trip = tripRepo.load(for: vineyard.id).first(where: { $0.id == id && $0.isActive }) {
                return trip
            }
        }
        return nil
    }

    func claimDeviceTrip(_ id: UUID) {
        guard deviceTripOwnership == nil else { return }
        let ownership = DeviceTripOwnership(tripId: id, userId: currentUserIdProvider?())
        deviceTripOwnership = ownership
        persistence.save(ownership, key: Keys.deviceActiveTripId)
    }

    func releaseDeviceTrip(_ id: UUID) {
        guard deviceActiveTripId == id else { return }
        deviceTripOwnership = nil
        persistence.remove(key: Keys.deviceActiveTripId)
    }

    /// Keep GPS on the owned trip when the operator views another vineyard.
    func updateDeviceOwnedTrip(_ trip: Trip) {
        guard operationalWriteAuthority.admit(vineyardId: trip.vineyardId.uuidString) else { return }
        guard isDeviceTripOwner, trip.id == deviceActiveTripId else { return }
        if trip.vineyardId == selectedVineyardId {
            updateTrip(trip)
        } else {
            var slice = tripRepo.load(for: trip.vineyardId)
            guard let index = slice.firstIndex(where: { $0.id == trip.id }) else { return }
            slice[index] = trip
            tripRepo.saveSlice(slice, for: trip.vineyardId)
            onTripChanged?(trip.id)
        }
    }

    var repairButtons: [ButtonConfig] = []
    var growthButtons: [ButtonConfig] = []
    var settings: AppSettings = AppSettings()
    var savedCustomPatterns: [SavedCustomPattern] = []

    var sprayRecords: [SprayRecord] = [] {
        didSet {
            #if DEBUG
            SyntheticHomePerformanceProbe.publication()
            #endif
        }
    }
    var savedChemicals: [SavedChemical] = [] {
        didSet {
            #if DEBUG
            SyntheticHomePerformanceProbe.publication()
            #endif
        }
    }
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

    var yieldSessions: [YieldEstimationSession] = [] {
        didSet {
            #if DEBUG
            SyntheticHomePerformanceProbe.publication()
            #endif
        }
    }
    var damageRecords: [DamageRecord] = []
    var historicalYieldRecords: [HistoricalYieldRecord] = []
    var yieldDeterminationResults: [YieldDeterminationResult] = []
    /// Detailed picking log (sql/180) — many picks per Block + Variety + Vintage.
    var pickingRecords: [PickingRecord] = []
    /// Shared per-block Pruning Yield Calculator configuration (sql/181).
    var pruningYieldSettings: [PruningYieldSettings] = []

    var maintenanceLogs: [MaintenanceLog] = [] {
        didSet {
            #if DEBUG
            SyntheticHomePerformanceProbe.publication()
            #endif
        }
    }
    var workTasks: [WorkTask] = [] {
        didSet {
            #if DEBUG
            SyntheticHomePerformanceProbe.publication()
            #endif
        }
    }
    var workTaskLabourLines: [WorkTaskLabourLine] = []
    /// Labour lines owned by PRUNING ACTIVITIES (sql/190). Labour is
    /// pruning-owned: a linked Work Task never holds a copy, it reads THROUGH to
    /// these rows, so the two modules can never report the same money twice.
    var pruningActivityLabourLines: [PruningActivityLabourLine] = []
    var workTaskMachineLines: [WorkTaskMachineLine] = []
    var workTaskPaddocks: [WorkTaskPaddock] = []
    /// Historical per-row vine-count snapshots behind piece-rate jobs (sql/188).
    /// Frozen commercial history — never recalculated from today's block rows.
    var workTaskPieceRateRows: [WorkTaskPieceRateRow] = []

    // MARK: Work Task Material Costs (sql/247)

    /// The global VineTrack base material catalogue. NOT vineyard scoped —
    /// the same 18 high-level items for everyone. Falls back to the bundled
    /// `MaterialCatalogueSeed` until a server copy has synced, so an offline
    /// fresh install still resolves the same material keys.
    var materialCatalogue: [MaterialCatalogueItem] = []
    /// One vineyard's material library: its own default costs for base items
    /// plus its own custom materials. Prices live here, never on the catalogue.
    var vineyardMaterials: [VineyardMaterial] = []
    /// Materials actually used on Work Tasks. Each row carries a FROZEN
    /// name/unit/quantity/unit-cost snapshot, so later library repricing can
    /// never alter a historical task cost.
    var workTaskMaterials: [WorkTaskMaterial] = []

    var grapeVarieties: [GrapeVariety] = []

    /// Phase 5 — saved trip cost allocation rows (owner/manager only). UI must
    /// gate visibility via `canViewCosting`; sync only fetches when the
    /// current role can view financials.
    var tripCostAllocations: [TripCostAllocation] = []

    var selectedTab: Int = 0

    // MARK: - Sync hooks (Phase 10B)

    /// Called before a newly captured pin is published. The sync service uses
    /// this throwing hook to retain its upload marker first, so a successful
    /// capture can always be retried after restart.
    var onPinCreateWillPersist: ((UUID, Date) throws -> Void)?
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
    var onGrowthStagePinDeleted: ((VinePin) -> Bool)?

    /// Provides the currently-authenticated user UUID, used to self-heal
    /// `createdByUserId` on pins that were saved before auth was wired up
    /// (or on creation paths that forgot to plumb auth in).
    var currentUserIdProvider: (() -> UUID?)?
    @ObservationIgnored var legacySprayScopeProvider: (() -> LegacySpraySaveRecovery.Scope?)?
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
    var onSavedChemicalCreated: ((UUID) -> Void)?
    var onSavedChemicalChanged: ((UUID) -> Void)?
    var savedChemicalHasPendingWrite: ((UUID) -> Bool)?
    var onSavedChemicalDeleted: ((UUID) -> Void)?
    var onSavedChemicalRetired: ((UUID) -> Void)?
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
    /// Fired with the ACTIVITY id, never a line id: `save_pruning_activity_labour_lines`
    /// is a DESIRED-STATE save of the activity's whole set, so the unit of sync
    /// work is the activity. Adding, editing and removing a line all mark the
    /// same activity dirty, which is what makes an offline replay idempotent.
    var onPruningActivityLabourLinesChanged: ((UUID) -> Void)?
    var onWorkTaskMachineLineChanged: ((UUID) -> Void)?
    var onWorkTaskMachineLineDeleted: ((UUID) -> Void)?
    var onWorkTaskPaddockChanged: ((UUID) -> Void)?
    var onWorkTaskPaddockDeleted: ((UUID) -> Void)?
    var onWorkTaskPieceRateRowChanged: ((UUID) -> Void)?
    var onWorkTaskPieceRateRowDeleted: ((UUID) -> Void)?
    /// Work Task Material Costs (sql/247). The base catalogue is pull-only and
    /// therefore has no change hook.
    var onVineyardMaterialChanged: ((UUID) -> Void)?
    var onVineyardMaterialDeleted: ((UUID) -> Void)?
    var onWorkTaskMaterialChanged: ((UUID) -> Void)?
    var onWorkTaskMaterialDeleted: ((UUID) -> Void)?
    var onMaintenanceLogChanged: ((UUID) -> Void)?
    var onMaintenanceLogDeleted: ((UUID) -> Void)?
    var onYieldSessionChanged: ((UUID) -> Void)?
    var onYieldSessionDeleted: ((UUID) -> Void)?
    var onDamageRecordChanged: ((UUID) -> Void)?
    var onDamageRecordDeleted: ((UUID) -> Void)?
    var onHistoricalYieldRecordChanged: ((UUID) -> Void)?
    var onHistoricalYieldRecordDeleted: ((UUID) -> Void)?
    var onPickingRecordChanged: ((UUID) -> Void)?
    var onPickingRecordDeleted: ((UUID) -> Void)?
    var onPruningYieldSettingsChanged: ((UUID) -> Void)?
    var onPruningYieldSettingsDeleted: ((UUID) -> Void)?

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
    let pruningActivityLabourLineRepo: PruningActivityLabourLineRepository
    let workTaskMachineLineRepo: WorkTaskMachineLineRepository
    let workTaskPaddockRepo: WorkTaskPaddockRepository
    let workTaskPieceRateRowRepo: WorkTaskPieceRateRowRepository
    /// Work Task Material Costs (sql/247).
    let materialCatalogueRepo: MaterialCatalogueRepository
    let vineyardMaterialRepo: VineyardMaterialRepository
    let workTaskMaterialRepo: WorkTaskMaterialRepository
    let workTaskTypeRepo: WorkTaskTypeRepository
    let equipmentItemRepo: EquipmentItemRepository
    let maintenanceLogRepo: MaintenanceLogRepository
    let sprayRepo: SprayRepository
    let savedInputRepo: SavedInputRepository
    let tripCostAllocationRepo: TripCostAllocationRepository
    let settingsRepo: SettingsRepository
    let yieldRepo: YieldRepository

    private let persistence: PersistenceStore
    var buttonPersistence: PersistenceStore { persistence }
    private let pinNotesDraftStore: PinNotesDraftStore

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
        static let deviceActiveTripId = "vinetrack_device_active_trip_id"
    }

    // MARK: - Init

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.vineyardRepo = VineyardRepository(persistence: persistence)
        self.pinRepo = PinRepository(persistence: persistence)
        self.pinNotesDraftStore = PinNotesDraftStore(persistence: persistence)
        self.tripRepo = TripRepository(persistence: persistence)
        self.workTaskRepo = WorkTaskRepository(persistence: persistence)
        self.workTaskLabourLineRepo = WorkTaskLabourLineRepository(persistence: persistence)
        self.pruningActivityLabourLineRepo = PruningActivityLabourLineRepository(persistence: persistence)
        self.workTaskMachineLineRepo = WorkTaskMachineLineRepository(persistence: persistence)
        self.workTaskPaddockRepo = WorkTaskPaddockRepository(persistence: persistence)
        self.workTaskPieceRateRowRepo = WorkTaskPieceRateRowRepository(persistence: persistence)
        self.materialCatalogueRepo = MaterialCatalogueRepository(persistence: persistence)
        self.vineyardMaterialRepo = VineyardMaterialRepository(persistence: persistence)
        self.workTaskMaterialRepo = WorkTaskMaterialRepository(persistence: persistence)
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
        let performanceSpan = PerformanceCapture.shared.begin("store global load and repair")
        defer { PerformanceCapture.shared.end(performanceSpan) }
        deviceTripOwnership = persistence.load(key: Keys.deviceActiveTripId)
        vineyards = vineyardRepo.loadAll()
        hydrateVineyardLogosFromCache()

        if let stored: SelectedVineyardWrapper = persistence.load(key: Keys.selectedVineyardId) {
            selectedVineyardId = stored.id
        }
        if selectedVineyardId == nil, let first = vineyards.first {
            selectedVineyardId = first.id
        }

        savedCustomPatterns = persistence.load(key: Keys.savedCustomPatterns) ?? []
        // Loaded UNSCOPED on purpose: `deduplicateManagementCollections()`
        // below rewrites the multi-vineyard blob and must see every vineyard's
        // rows. `reloadCurrentVineyardData()` immediately narrows these four
        // collections to the selected vineyard.
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
            // Manual issues have no launcher button templates.
            case .manualIssue: isDefault = false
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
    func reloadCurrentVineyardData(deferSelectionRepairs: Bool = false) {
        #if DEBUG
        let switchProbe = VineyardSwitchPerformanceProbe(receive: switchPerformanceSample)
        defer { switchProbe.finish() }
        #endif
        let performanceSpan = PerformanceCapture.shared.begin("store selected vineyard hydration")
        defer { PerformanceCapture.shared.end(performanceSpan) }
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
            pruningActivityLabourLines = []
            workTaskMachineLines = []
            workTaskPaddocks = []
            workTaskPieceRateRows = []
            // The base catalogue is global, not vineyard data, so it stays
            // loaded with no vineyard selected. The vineyard-scoped material
            // library and task lines do not.
            materialCatalogue = materialCatalogueRepo.loadEffective()
            vineyardMaterials = []
            workTaskMaterials = []
            workTaskTypes = []
            equipmentItems = []
            // Equipment is vineyard-scoped operational state: with nothing
            // selected there is no correct answer, so expose none rather than
            // leaking the last vineyard's machinery.
            tractors = []
            vineyardMachines = []
            fuelPurchases = []
            tractorFuelLogs = []
            settings = AppSettings()
            return
        }

        #if DEBUG
        switchProbe.next("core-records")
        #endif
        VineyardSelectionDiagnostics.stage("core-records", vineyardId: vineyardId)
        pins = pinRepo.load(for: vineyardId)
        trips = tripRepo.load(for: vineyardId)
        workTasks = workTaskRepo.load(for: vineyardId)
        workTaskLabourLines = workTaskLabourLineRepo.load(for: vineyardId)
        pruningActivityLabourLines = pruningActivityLabourLineRepo.load(for: vineyardId)
        workTaskMachineLines = workTaskMachineLineRepo.load(for: vineyardId)
        workTaskPaddocks = workTaskPaddockRepo.load(for: vineyardId)
        workTaskPieceRateRows = workTaskPieceRateRowRepo.load(for: vineyardId)
        materialCatalogue = materialCatalogueRepo.loadEffective()
        vineyardMaterials = vineyardMaterialRepo.load(for: vineyardId)
        workTaskMaterials = workTaskMaterialRepo.load(for: vineyardId)
        workTaskTypes = workTaskTypeRepo.load(for: vineyardId)
        equipmentItems = equipmentItemRepo.load(for: vineyardId)
        maintenanceLogs = maintenanceLogRepo.load(for: vineyardId)

        #if DEBUG
        switchProbe.next("spray-records")
        #endif
        VineyardSelectionDiagnostics.stage("spray-records", vineyardId: vineyardId)
        sprayRecords = sprayRepo.loadRecords(for: vineyardId)
        // Authentication may be configured after hydration; sync preflight retries this before any write.
        #if DEBUG
        switchProbe.next("legacy-spray-recovery")
        #endif
        if !deferSelectionRepairs { try? reconcileLegacySpraySaves() }
        #if DEBUG
        switchProbe.next("chemical-and-spray-reference")
        #endif
        savedChemicals = sprayRepo.loadChemicals(for: vineyardId)
        savedSprayPresets = sprayRepo.loadPresets(for: vineyardId)
        savedEquipmentOptions = sprayRepo.loadEquipmentOptions(for: vineyardId)
        sprayEquipment = sprayRepo.loadEquipment(for: vineyardId)
        savedInputs = savedInputRepo.load(for: vineyardId)
        tripCostAllocations = tripCostAllocationRepo.load(for: vineyardId)

        #if DEBUG
        switchProbe.next("yield-records")
        #endif
        VineyardSelectionDiagnostics.stage("yield-records", vineyardId: vineyardId)
        yieldSessions = yieldRepo.loadSessions(for: vineyardId)
        damageRecords = yieldRepo.loadDamage(for: vineyardId)
        historicalYieldRecords = yieldRepo.loadHistorical(for: vineyardId)
        yieldDeterminationResults = yieldRepo.loadDetermination(for: vineyardId)
        pickingRecords = yieldRepo.loadPicking(for: vineyardId)
        pruningYieldSettings = yieldRepo.loadPruningSettings(for: vineyardId)

        settings = settingsRepo.load(for: vineyardId)

        #if DEBUG
        switchProbe.next("block-cache")
        #endif
        VineyardSelectionDiagnostics.stage("block-cache", vineyardId: vineyardId)
        let allPaddocks: [Paddock] = loadAllPaddocksFromDisk()
        paddocks = allPaddocks.filter { $0.vineyardId == vineyardId }

        // Equipment: the persisted blobs stay MULTI-vineyard (a device syncs
        // several vineyards and every slice must survive a save of a different
        // one), but in-memory operational state represents ONLY the selected
        // vineyard. Reading from disk here — instead of filtering whatever is
        // already in memory — is what makes a vineyard switch symmetric:
        // switching away drops the old slice, switching back restores it, with
        // no logout, reinstall or manual cache wipe.
        #if DEBUG
        switchProbe.next("equipment-cache")
        #endif
        VineyardSelectionDiagnostics.stage("equipment-cache", vineyardId: vineyardId)
        let allTractors: [Tractor] = persistence.load(key: Keys.tractors) ?? []
        tractors = allTractors.filter { $0.vineyardId == vineyardId }
        let allMachines: [VineyardMachine] = persistence.load(key: Keys.vineyardMachines) ?? []
        vineyardMachines = allMachines.filter { $0.vineyardId == vineyardId }
        let allFuelPurchases: [FuelPurchase] = persistence.load(key: Keys.fuelPurchases) ?? []
        fuelPurchases = allFuelPurchases.filter { $0.vineyardId == vineyardId }
        let allFuelLogs: [TractorFuelLog] = persistence.load(key: Keys.tractorFuelLogs) ?? []
        tractorFuelLogs = allFuelLogs.filter { $0.vineyardId == vineyardId }

        #if DEBUG
        switchProbe.next("button-cache")
        #endif
        VineyardSelectionDiagnostics.stage("button-cache", vineyardId: vineyardId)
        loadButtonsForCurrentVineyard()

        #if DEBUG
        switchProbe.next("variety-canonicalization")
        #endif
        VineyardSelectionDiagnostics.stage("variety-canonicalization", vineyardId: vineyardId)
        // After paddocks + varieties are loaded for this vineyard, repair
        // any drift between built-in variety ids and existing block
        // allocations (e.g. duplicate seedings from earlier app versions).
        if !deferSelectionRepairs { GrapeVarietyCanonicalization.run(store: self) }
    }

    /// Clear in-memory state without touching disk.
    func clearInMemoryState() {
        vineyardPreparationGeneration &+= 1
        preparingVineyard = nil
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
        pruningActivityLabourLines = []
        workTaskMachineLines = []
        workTaskPaddocks = []
        workTaskPieceRateRows = []
        materialCatalogue = []
        vineyardMaterials = []
        workTaskMaterials = []
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
            PruningActivityLabourLineRepository.storageKey,
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
        // An active device claim survives a local-data reset/account switch;
        // only an exact remote end/delete or the owner's successful end releases it.
        clearInMemoryState()
    }

    /// Read-only worker preparation; the repository rereads exact current bytes
    /// before reusing the result. Does not mutate records or acknowledge sync.
    func prepareRemoteTripCache() async {
        await persistence.prepareDecode([Trip].self, key: TripRepository.storageKey)
    }

    // MARK: - Vineyard selection

    var selectedVineyard: Vineyard? {
        guard let id = selectedVineyardId else { return nil }
        return vineyards.first { $0.id == id }
    }

    /// Interactive path: no observable store/repository is sent to a worker.
    /// Exact current bytes remain authoritative at the final synchronous load.
    func prepareAndSelectVineyard(_ vineyard: Vineyard) async {
        #if DEBUG
        let requestStart = ProcessInfo.processInfo.systemUptime
        #endif
        deferredSelectionRepairs?.cancel()
        vineyardPreparationGeneration &+= 1
        let generation = vineyardPreparationGeneration
        let account = currentUserIdProvider?()
        let binding = operationalWriteAuthority.accountBinding
        let incarnation = operationalWriteAuthority.accountGeneration
        let originalSelection = selectedVineyardId
        preparingVineyard = vineyard
        #if DEBUG
        preparedSelectionMeasurement?("selection-state-acknowledgement", (ProcessInfo.processInfo.systemUptime - requestStart) * 1000)
        let preparationStart = ProcessInfo.processInfo.systemUptime
        #endif
        defer {
            if generation == vineyardPreparationGeneration { preparingVineyard = nil }
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == vineyardPreparationGeneration &&
                currentUserIdProvider?() == account &&
                operationalWriteAuthority.accountBinding == binding &&
                operationalWriteAuthority.accountGeneration == incarnation &&
                selectedVineyardId == originalSelection
        }
        // These already-audited Sendable collections dominate cold hydration.
        // Each preparation owns its decoder. It cannot repair or mutate files.
        await persistence.prepareDecode([VinePin].self, key: PinRepository.storageKey)
        guard isCurrent() else { return }
        await persistence.prepareDecode([Trip].self, key: TripRepository.storageKey)
        guard isCurrent() else { return }
        await persistence.prepareDecode([WorkTask].self, key: WorkTaskRepository.storageKey)
        guard isCurrent() else { return }
        await persistence.prepareDecode([SavedChemical].self, key: SprayRepository.savedChemicalsKey)
        guard isCurrent() else { return }
        await persistence.prepareDecode([Paddock].self, key: "vinetrack_paddocks")
        guard isCurrent() else { return }
        // No await from selection through full hydration/persistence. Writers,
        // GPS and sync never observe empty/partly loaded operational arrays.
        #if DEBUG
        preparedSelectionMeasurement?("snapshot-preparation-including-waits", (ProcessInfo.processInfo.systemUptime - preparationStart) * 1000)
        let commitStart = ProcessInfo.processInfo.systemUptime
        #endif
        selectVineyard(vineyard, deferSelectionRepairs: true)
        #if DEBUG
        preparedSelectionMeasurement?("atomic-selection-commit", (ProcessInfo.processInfo.systemUptime - commitStart) * 1000)
        #endif
        let committedGeneration = vineyardPreparationGeneration
        deferredSelectionRepairs = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.vineyardPreparationGeneration == committedGeneration,
                  self.selectedVineyardId == vineyard.id,
                  self.currentUserIdProvider?() == account,
                  self.operationalWriteAuthority.accountBinding == binding,
                  self.operationalWriteAuthority.accountGeneration == incarnation else { return }
            // Sync/write preflights still reconcile independently. These local
            // repairs execute only against the fully hydrated, current slice.
            #if DEBUG
            let recoveryStart = ProcessInfo.processInfo.systemUptime
            #endif
            try? self.reconcileLegacySpraySaves()
            #if DEBUG
            self.preparedSelectionMeasurement?("deferred-legacy-spray-recovery", (ProcessInfo.processInfo.systemUptime - recoveryStart) * 1000)
            #endif
            guard !Task.isCancelled, self.vineyardPreparationGeneration == committedGeneration,
                  self.selectedVineyardId == vineyard.id,
                  self.currentUserIdProvider?() == account,
                  self.operationalWriteAuthority.accountBinding == binding,
                  self.operationalWriteAuthority.accountGeneration == incarnation else { return }
            #if DEBUG
            let canonicalizationStart = ProcessInfo.processInfo.systemUptime
            #endif
            GrapeVarietyCanonicalization.run(store: self)
            #if DEBUG
            self.preparedSelectionMeasurement?("deferred-variety-canonicalization", (ProcessInfo.processInfo.systemUptime - canonicalizationStart) * 1000)
            #endif
        }
    }

    func selectVineyard(_ vineyard: Vineyard, deferSelectionRepairs: Bool = false) {
        deferredSelectionRepairs?.cancel()
        vineyardPreparationGeneration &+= 1
        preparingVineyard = nil
        VineyardSelectionDiagnostics.started(vineyardId: vineyard.id)
        selectedVineyardId = vineyard.id
        reloadCurrentVineyardData(deferSelectionRepairs: deferSelectionRepairs)
        // Commit the durable selection only after local hydration completes. If
        // hydration stalls, relaunch returns to the previous working vineyard so
        // the bounded diagnostic can be retrieved without re-entering the stall.
        persistence.save(SelectedVineyardWrapper(id: vineyard.id), key: Keys.selectedVineyardId)
        VineyardSelectionDiagnostics.hydrationCompleted(vineyardId: vineyard.id)
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
                vineyardPreparationGeneration &+= 1
                preparingVineyard = nil
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
            vineyardPreparationGeneration &+= 1
            preparingVineyard = nil
            selectedVineyardId = first.id
            persistence.save(SelectedVineyardWrapper(id: first.id), key: Keys.selectedVineyardId)
            reloadCurrentVineyardData()
            Task { await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: first.id) }
        } else {
            vineyardPreparationGeneration &+= 1
            preparingVineyard = nil
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
                // Spray profile is authoritative from the backend, INCLUDING a
                // cleared value: a vineyard that resets its profile must fall
                // back to the country default rather than keep a stale lock.
                updated.sprayComplianceProfile = backend.sprayComplianceProfile
                updated.sprayCarrierVolumeBasis = backend.sprayCarrierVolumeBasis
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
                    logoUpdatedAt: backend.logoUpdatedAt,
                    sprayComplianceProfile: backend.sprayComplianceProfile,
                    sprayCarrierVolumeBasis: backend.sprayCarrierVolumeBasis
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
        try? addPinDurably(pin)
    }

    /// Retains the upload marker and complete local pin before publishing it to
    /// the UI. The stable pin ID makes retries idempotent.
    @discardableResult
    func addPinDurably(_ pin: VinePin) throws -> VinePin {
        if let vineyard = selectedVineyardId { try operationalWriteAuthority.requireWrite(vineyardId: vineyard.uuidString) }
        guard let vineyardId = selectedVineyardId else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "No vineyard is selected."])
        }
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
        try onPinCreateWillPersist?(item.id, item.timestamp)
        var nextPins = pins
        if let existingIndex = nextPins.firstIndex(where: { $0.id == item.id }) {
            nextPins[existingIndex] = item
        } else {
            nextPins.append(item)
        }
        try pinRepo.saveSliceOrThrow(nextPins, for: vineyardId)
        pins = nextPins
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
        return item
    }

    func updatePin(_ pin: VinePin) {
        let vineyardId = pin.vineyardId
        guard selectedVineyardId == vineyardId,
              let index = pins.firstIndex(where: { $0.id == pin.id && $0.vineyardId == vineyardId }) else { return }
        guard operationalWriteAuthority.admit(vineyardId: vineyardId.uuidString) else { return }
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

    func pendingPinNotesDraft(pinId: UUID, vineyardId: UUID) -> PendingPinNotesDraft? {
        pinNotesDraftStore.draft(pinId: pinId, vineyardId: vineyardId)
    }

    /// Retains the draft first, then durably merges only notes onto the original
    /// pin identity. Once the pin cache write succeeds, its value is published
    /// and marked for sync before recoverable draft cleanup is attempted.
    func updatePinNotesDurably(
        pinId: UUID,
        vineyardId: UUID,
        notes: String?
    ) throws -> PinNotesUpdateOutcome {
        try operationalWriteAuthority.requireWrite(vineyardId: vineyardId.uuidString)
        guard try pinRepo.loadAllForDurableUpdate().contains(where: { $0.id == pinId && $0.vineyardId == vineyardId }) else {
            throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED")
        }
        let draftText = notes ?? ""
        try pinNotesDraftStore.retain(pinId: pinId, vineyardId: vineyardId, notes: draftText)
        let updated = try pinRepo.updateNotesDurably(pinId: pinId, vineyardId: vineyardId, notes: notes)
        if selectedVineyardId == vineyardId,
           let index = pins.firstIndex(where: { $0.id == pinId && $0.vineyardId == vineyardId }) {
            pins[index] = updated
        }
        onPinChanged?(pinId)
        do {
            try pinNotesDraftStore.clear(pinId: pinId, vineyardId: vineyardId)
            return .saved
        } catch {
            return .savedCleanupPending
        }
    }

    func deletePin(_ pinId: UUID) {
        guard let pin = pins.first(where: { $0.id == pinId }) else { return }
        let vineyardId = pin.vineyardId
        guard selectedVineyardId == vineyardId else { return }
        guard operationalWriteAuthority.admit(vineyardId: vineyardId.uuidString) else { return }
        if pin.growthStageCode != nil, onGrowthStagePinDeleted?(pin) == false {
            return
        }
        pins.removeAll { $0.id == pinId }
        pinRepo.saveSlice(pins, for: vineyardId)
        onPinDeleted?(pinId)
    }

    func togglePinCompletion(_ pinId: UUID) {
        guard let index = pins.firstIndex(where: { $0.id == pinId }) else { return }
        let vineyardId = pins[index].vineyardId
        guard selectedVineyardId == vineyardId else { return }
        guard operationalWriteAuthority.admit(vineyardId: vineyardId.uuidString) else { return }
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

    /// Applies one remote-sync slice with one checked cache read, one durable
    /// write, and at most one selected-vineyard publication.
    func applyRemotePinBatch(
        vineyardId: UUID,
        cacheSnapshot: [VinePin],
        upserts: [VinePin],
        deleting ids: Set<UUID>
    ) throws {
        let isSelected = selectedVineyardId == vineyardId
        let latestSlice = try pinRepo.applyRemoteBatchDurably(
            vineyardId: vineyardId,
            selectedSlice: isSelected ? pins : nil,
            cacheSnapshot: cacheSnapshot,
            upserts: upserts,
            deleting: ids
        )
        if selectedVineyardId == vineyardId {
            pins = latestSlice
        }
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
        var all: [Paddock] = loadAllPaddocksFromDisk()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: paddocks)
        persistence.save(all, key: Keys.paddocks)
    }

    /// Explicit outcome of reading the shared multi-vineyard block cache.
    /// Callers whose safety depends on distinguishing "cache is empty" from
    /// "cache could not be read" (the block sync's push path) MUST use the
    /// outcome variants — a corrupt cache read as an ordinary empty array
    /// would let every pending entry be misclassified as an orphan.
    enum PaddockCacheReadOutcome {
        /// The cache was read successfully (a missing file — fresh install —
        /// is a genuinely empty cache).
        case loaded([Paddock])
        /// The persisted cache exists but failed to decode. It has been
        /// quarantined and a server recovery flagged for the next block sync.
        case corrupted
    }

    /// Load the shared multi-vineyard paddock cache from disk, distinguishing
    /// a missing file (fresh install — genuinely empty) from a corrupt one.
    /// On decode failure the corrupt payload is quarantined for diagnostics
    /// (so a subsequent save cannot overwrite the evidence with an empty or
    /// partial array), the failure is logged with its key and underlying
    /// error, and a full server recovery is flagged for the next block sync.
    private func loadAllPaddocksFromDiskOutcome() -> PaddockCacheReadOutcome {
        let outcome: PersistenceStore.LoadOutcome<[Paddock]> = persistence.loadOutcome(key: Keys.paddocks)
        switch outcome {
        case .decoded(let all):
            return .loaded(all)
        case .missing:
            return .loaded([])
        case .failed(let error):
            PaddockCacheRecovery.noteDecodeFailure(key: Keys.paddocks, error: error)
            persistence.quarantine(key: Keys.paddocks)
            return .corrupted
        }
    }

    private func loadAllPaddocksFromDisk() -> [Paddock] {
        switch loadAllPaddocksFromDiskOutcome() {
        case .loaded(let all):
            return all
        case .corrupted:
            return []
        }
    }

    /// Locally cached block ids for a vineyard — from memory when it is the
    /// selected vineyard, otherwise from the persisted multi-vineyard cache.
    /// Used by the block sync consistency check.
    func cachedPaddockIds(for vineyardId: UUID) -> Set<UUID> {
        if selectedVineyardId == vineyardId {
            return Set(paddocks.filter { $0.vineyardId == vineyardId }.map { $0.id })
        }
        return Set(loadAllPaddocksFromDisk().filter { $0.vineyardId == vineyardId }.map { $0.id })
    }

    /// The COMPLETE multi-vineyard block view: the persisted shared cache
    /// merged with the (possibly newer) in-memory slice for the selected
    /// vineyard. The block sync uses this to look up pending records so a
    /// pending edit for a NON-selected vineyard is never misclassified as an
    /// orphan (and discarded) while a different vineyard syncs.
    func allCachedPaddocks() -> [Paddock] {
        switch allCachedPaddocksOutcome() {
        case .loaded(let merged):
            return merged
        case .corrupted:
            // Legacy behaviour for callers that can tolerate it: the disk
            // view is unavailable, only the in-memory slice remains. Safety-
            // critical callers use `allCachedPaddocksOutcome()` instead.
            return paddocks
        }
    }

    /// Outcome-reporting variant of `allCachedPaddocks()`. The block sync's
    /// push path uses this so a decode failure FIRST discovered by this very
    /// read is surfaced explicitly — never silently returned as an empty
    /// cache against which pending records would be reclaimed as orphans.
    func allCachedPaddocksOutcome() -> PaddockCacheReadOutcome {
        switch loadAllPaddocksFromDiskOutcome() {
        case .corrupted:
            return .corrupted
        case .loaded(let all):
            guard let selected = selectedVineyardId else { return .loaded(all) }
            var merged = all.filter { $0.vineyardId != selected }
            merged.append(contentsOf: paddocks)
            return .loaded(merged)
        }
    }

    /// Block ids for a vineyard read FRESH from the persisted cache — never
    /// from memory. Used as the block sync's durable success gate: a block
    /// only counts as synced once it can be read back from disk.
    func persistedPaddockIds(for vineyardId: UUID) -> Set<UUID> {
        Set(loadAllPaddocksFromDisk().filter { $0.vineyardId == vineyardId }.map { $0.id })
    }

    /// Apply remote paddock upserts and deletes DURABLY with one shared-cache
    /// read and one atomic write. Local relationship cleanup for deleted ids is
    /// retained, while server-originated changes never re-enter the dirty queue.
    func applyRemotePaddockChangesBatch(upserts incoming: [Paddock], deleteIds: Set<UUID>) throws {
        guard !incoming.isEmpty || !deleteIds.isEmpty else { return }
        var all: [Paddock] = loadAllPaddocksFromDisk()
        if let selected = selectedVineyardId {
            // The in-memory slice for the selected vineyard is authoritative
            // over its persisted copy (same rule as `savePaddocksToDisk`).
            all.removeAll { $0.vineyardId == selected }
            all.append(contentsOf: paddocks)
        }
        all.removeAll { deleteIds.contains($0.id) }
        var stagedPaddocks = paddocks
        stagedPaddocks.removeAll { deleteIds.contains($0.id) }
        var allIndex = Dictionary(uniqueKeysWithValues: all.indices.map { (all[$0].id, $0) })
        var memoryIndex = Dictionary(uniqueKeysWithValues: stagedPaddocks.indices.map { (stagedPaddocks[$0].id, $0) })
        for paddock in incoming {
            if let idx = allIndex[paddock.id] {
                all[idx] = paddock
            } else {
                allIndex[paddock.id] = all.count
                all.append(paddock)
            }
            if selectedVineyardId == paddock.vineyardId {
                if let memIdx = memoryIndex[paddock.id] {
                    stagedPaddocks[memIdx] = paddock
                } else {
                    memoryIndex[paddock.id] = stagedPaddocks.count
                    stagedPaddocks.append(paddock)
                }
            }
        }
        try persistence.saveOrThrow(all, key: Keys.paddocks)

        paddocks = stagedPaddocks
        for paddockId in deleteIds {
            clearPaddockLinkOnPins(paddockId: paddockId, propagate: false)
            clearPaddockLinkOnTrips(paddockId: paddockId, propagate: false)
            removeWorkTaskPaddockLinks(paddockId: paddockId, propagate: false)
        }
    }

    func applyRemotePaddockUpsertsBatch(_ incoming: [Paddock]) throws {
        try applyRemotePaddockChangesBatch(upserts: incoming, deleteIds: [])
    }

    func addPaddock(_ paddock: Paddock) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = paddock
        item.vineyardId = vineyardId
        paddocks.append(item)
        savePaddocksToDisk()
        onPaddockChanged?(item.id)
    }

    func updatePaddock(_ paddock: Paddock) {
        guard admitSelectedMutation() else { return }
        guard let index = paddocks.firstIndex(where: { $0.id == paddock.id }) else { return }
        paddocks[index] = paddock
        savePaddocksToDisk()
        onPaddockChanged?(paddock.id)
    }

    func deletePaddock(_ paddockId: UUID) {
        guard admitSelectedMutation() else { return }
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
            var all: [Paddock] = loadAllPaddocksFromDisk()
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
            var all: [Paddock] = loadAllPaddocksFromDisk()
            all.removeAll { $0.id == paddockId }
            persistence.save(all, key: Keys.paddocks)
        }
    }

    // MARK: - Trip CRUD

    /// Prospective planned starts publish only after the complete trip snapshot reaches disk.
    func savePlannedTripOrThrow(_ trip: Trip) throws {
        try operationalWriteAuthority.requireWrite(vineyardId: trip.vineyardId.uuidString)
        guard selectedVineyardId == trip.vineyardId else { throw TripOccurrenceCoverage.Failure.scopeConflict }
        var next = trips
        if let index = next.firstIndex(where: { $0.id == trip.id }) { next[index] = trip }
        else { next.append(trip) }
        try tripRepo.saveSliceOrThrow(next, for: trip.vineyardId)
        trips = next
        onTripChanged?(trip.id)
    }

    func startTrip(_ trip: Trip) {
        guard admitSelectedMutation() else { return }
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
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = trip
        item.vineyardId = vineyardId
        item.isActive = false
        trips.append(item)
        tripRepo.saveSlice(trips, for: vineyardId)
        onTripChanged?(item.id)
    }

    func updateTrip(_ trip: Trip) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }),
              trips[index].vineyardId == trip.vineyardId,
              selectedVineyardId == trip.vineyardId else { return }
        let vineyardId = trips[index].vineyardId
        guard operationalWriteAuthority.admit(vineyardId: vineyardId.uuidString) else { return }
        trips[index] = trip
        tripRepo.saveSlice(trips, for: vineyardId)
        onTripChanged?(trip.id)
    }

    func updateTripOrThrow(_ trip: Trip) throws {
        try operationalWriteAuthority.requireWrite(vineyardId: trip.vineyardId.uuidString)
        guard let vineyardId = selectedVineyardId, vineyardId == trip.vineyardId,
              let index = trips.firstIndex(where: { $0.id == trip.id && $0.vineyardId == vineyardId })
        else { throw SprayTankActualValidationError.localSaveFailed }
        var next = trips
        next[index] = trip
        try tripRepo.saveSliceOrThrow(next, for: vineyardId)
        trips = next
        onTripChanged?(trip.id)
    }

    func endTrip(_ tripId: UUID) {
        guard let index = trips.firstIndex(where: { $0.id == tripId }),
              selectedVineyardId == trips[index].vineyardId else { return }
        let vineyardId = trips[index].vineyardId
        guard operationalWriteAuthority.admit(vineyardId: vineyardId.uuidString) else { return }
        var trip = trips[index]
        trip.isActive = false
        trip.endTime = Date()
        trips[index] = trip
        tripRepo.saveSlice(trips, for: vineyardId)
        onTripChanged?(tripId)
    }

    /// End a trip, surfacing a disk-write failure instead of swallowing it.
    ///
    /// The non-throwing `endTrip` above cannot tell its caller that the final
    /// state never reached disk, which would let the UI clear the active trip
    /// and lose the whole recorded route. This variant mutates the in-memory
    /// array only AFTER the write succeeds, so a failure leaves the trip
    /// exactly as it was: still active, still holding its full route.
    ///
    /// `endTime` is the moment the operator confirmed, matching `endTrip`.
    func endTripOrThrow(_ tripId: UUID) throws {
        guard let index = trips.firstIndex(where: { $0.id == tripId }),
              selectedVineyardId == trips[index].vineyardId
        else { throw TripEndPersistenceError.tripUnavailable }
        let vineyardId = trips[index].vineyardId
        try operationalWriteAuthority.requireWrite(vineyardId: vineyardId.uuidString)
        var next = trips
        var trip = next[index]
        trip.isActive = false
        trip.endTime = Date()
        next[index] = trip
        try tripRepo.saveSliceOrThrow(next, for: vineyardId)
        trips = next
        onTripChanged?(tripId)
    }

    func deleteTrip(_ tripId: UUID) {
        guard let target = trips.first(where: { $0.id == tripId }), selectedVineyardId == target.vineyardId else { return }
        let vineyardId = target.vineyardId
        guard operationalWriteAuthority.admit(vineyardId: vineyardId.uuidString) else { return }
        guard tripId != deviceActiveTripId || isDeviceTripOwner else { return }
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
        releaseDeviceTrip(tripId)
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
        // An inactive saved placeholder is not a terminal server acknowledgement.
        // Preserve the owned activation and its route/tank evidence until reconciled.
        if deviceActiveTripId == trip.id, !trip.isActive, trip.endTime == nil,
           trips.contains(where: { $0.id == trip.id && $0.vineyardId == trip.vineyardId && $0.isActive && $0.endTime == nil }) {
            return
        }
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
        if !trip.isActive && trip.endTime != nil {
            let wasOwned = deviceActiveTripId == trip.id
            releaseDeviceTrip(trip.id)
            if wasOwned { onOwnedTripCompletedByServer?(trip.id) }
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
        releaseDeviceTrip(tripId)
    }

    // MARK: - SprayRecord CRUD

    /// Saves the validated recipe before publishing its inactive placeholder. Retry keeps both IDs.
    func saveSprayForLater(record: SprayRecord, trip: Trip) throws {
        try prepareLegacySpraySave(record: record, trip: trip)
        try reconcileLegacySpraySaves()
    }

    /// Must precede even local occurrence-parent preparation for this paired legacy save.
    func prepareLegacySpraySave(record: SprayRecord, trip: Trip) throws {
        try operationalWriteAuthority.requireWrite(vineyardId: record.vineyardId.uuidString)
        guard selectedVineyardId == record.vineyardId else {
            throw SprayTankActualValidationError.localSaveFailed
        }
        guard let scope = legacySprayScopeProvider?(), scope.vineyard == record.vineyardId else {
            throw SprayTankActualValidationError.localSaveFailed
        }
        let journal = LegacySpraySaveRecovery(persistence: persistence)
        try journal.prepare(scope: scope, record: record, trip: trip)
    }

    /// Called at startup hydration and again before either dependent sync writer.
    func reconcileLegacySpraySaves(isolatingHeldFailures: Bool = false) throws {
        let journal = LegacySpraySaveRecovery(persistence: persistence)
        guard !((try journal.attempts()).isEmpty) else { return }
        guard let scope = legacySprayScopeProvider?(), selectedVineyardId == scope.vineyard else {
            // Foreign retained evidence remains held but cannot veto unrelated work.
            if isolatingHeldFailures { return }
            throw SprayTankActualValidationError.localSaveFailed
        }
        let repaired: [LegacySpraySaveRecovery.Attempt]
        do {
        repaired = try journal.reconcile(scope: scope, record: { item in
            var next = self.sprayRecords
            if let index = next.firstIndex(where: { $0.id == item.id }) {
                guard try LegacySpraySaveRecovery.sameProjection(next[index], item) else { throw SprayTankActualValidationError.localSaveFailed }
            } else {
                next.append(item)
            }
            try self.sprayRepo.saveRecordsSliceOrThrow(next, for: item.vineyardId)
            self.sprayRecords = next
        }, trip: { item in
            var next = self.trips
            if let index = next.firstIndex(where: { $0.id == item.id }) {
                guard try LegacySpraySaveRecovery.sameProjection(next[index], item) else { throw SprayTankActualValidationError.localSaveFailed }
            } else {
                next.append(item)
            }
            try self.tripRepo.saveSliceOrThrow(next, for: item.vineyardId)
            self.trips = next
        })
        } catch {
            // No failed attempt is acknowledged or discarded. Only its identities
            // remain held; sync preflights can still process unrelated records.
            if isolatingHeldFailures { return }
            throw error
        }
        // Publication is AFTER both stores and the WAL completion marker are durable.
        for item in repaired {
            self.onTripChanged?(item.trip.id)
            self.onSprayRecordChanged?(item.record.id)
        }
    }

    /// A prior queued occurrence start can retain its original spray recipe in
    /// the exact local paired-save WAL even when the separately stored spray
    /// list has not hydrated it. Recover ONLY an existing, unfinished matching
    /// trip's missing recipe. Never mint a new trip, modify coverage or replace
    /// a conflicting record; the occurrence journal still owns activation.
    @discardableResult
    func restoreQueuedOccurrenceSprayRecordIfRetained(tripId: UUID) throws -> Bool {
        guard let scope = legacySprayScopeProvider?(),
              selectedVineyardId == scope.vineyard,
              let existingTrip = trips.first(where: { $0.id == tripId }),
              existingTrip.vineyardId == scope.vineyard,
              existingTrip.coverageBasis == .occurrence,
              !existingTrip.isActive, existingTrip.endTime == nil,
              existingTrip.pathPoints.isEmpty, existingTrip.tankSessions.isEmpty,
              existingTrip.completedPaths.isEmpty, existingTrip.skippedPaths.isEmpty else {
            return false
        }

        let matches = try LegacySpraySaveRecovery(persistence: persistence)
            .attempts().filter { attempt in
                attempt.scope == scope && attempt.localComplete &&
                attempt.trip.id == tripId && attempt.trip.coverageBasis == .occurrence &&
                attempt.record.tripId == tripId &&
                attempt.trip.occurrenceCoverage == existingTrip.occurrenceCoverage &&
                attempt.record.vineyardId == scope.vineyard
            }
        guard matches.count == 1, let attempt = matches.first else { return false }
        if let current = sprayRecords.first(where: {
            $0.id == attempt.record.id || $0.tripId == tripId
        }) {
            // Never overwrite a changed record; an existing different recipe
            // must be investigated and reconciled, not silently replaced.
            return current.id == attempt.record.id && current.tripId == tripId
        }
        var next = sprayRecords
        next.append(attempt.record)
        try sprayRepo.saveRecordsSliceOrThrow(next, for: scope.vineyard)
        sprayRecords = next
        onSprayRecordChanged?(attempt.record.id)
        return true
    }

    var legacySprayReceiptNotice: String? {
        guard let items = try? LegacySpraySaveRecovery(persistence: persistence).attempts() else { return "Legacy receipt evidence could not be decoded; synchronization remains held." }
        let journal = LegacySpraySaveRecovery(persistence: persistence)
        return items.first { $0.scope.vineyard == selectedVineyardId && $0.receiptBlocker != nil && ((try? journal.requiresLegacyReceipt($0)) ?? true) }?.receiptBlocker
    }

    func acceptedLegacySprayPairs(vineyard: UUID) throws -> [LegacySpraySaveRecovery.Attempt] {
        try LegacySpraySaveRecovery(persistence: persistence).attempts().filter { $0.trip.coverageBasis == .legacy && !$0.isHeld && $0.scope.vineyard == vineyard }
    }

    func unchangedAcceptedLegacySprays() throws -> [LegacySpraySaveRecovery.Attempt] {
        try LegacySpraySaveRecovery(persistence: persistence).attempts().filter { item in
            item.trip.coverageBasis == .legacy && !item.isHeld && item.scope.vineyard == selectedVineyardId &&
                trips.first(where: { $0.id == item.trip.id }).map { (try? LegacySpraySaveRecovery.sameProjection($0, item.trip)) == true } == true &&
                sprayRecords.first(where: { $0.id == item.record.id }).map { (try? LegacySpraySaveRecovery.sameProjection($0, item.record)) == true } == true
        }
    }

    @ObservationIgnored private var legacyReceiptReplayRunning: Bool = false

    /// Called before ordinary writers; errors retain the pair but never veto unrelated synchronization.
    func recoverLegacySprayReceipts() async {
        guard !legacyReceiptReplayRunning, let scope = legacySprayScopeProvider?(), selectedVineyardId == scope.vineyard else { return }
        legacyReceiptReplayRunning = true
        defer { legacyReceiptReplayRunning = false }
        do {
            try reconcileLegacySpraySaves(isolatingHeldFailures: true)
            let current = { self.legacySprayScopeProvider?() == scope && self.selectedVineyardId == scope.vineyard }
            try await LegacySpraySaveRecovery(persistence: persistence).replay(scope: scope, isCurrent: current) { rpc, body in
                try await LegacySprayPairReceipt.request(rpc: rpc, body: body, scope: scope, isCurrent: current)
            }
        } catch { /* Exact evidence stays durable and held. Unrelated writers continue. */ }
    }

    func legacySprayHeldCount(vineyard: UUID) throws -> Int {
        let journal = LegacySpraySaveRecovery(persistence: persistence)
        return try journal.attempts().filter { item in
            guard item.scope.vineyard == vineyard else { return false }
            return try journal.requiresLegacyReceipt(item)
        }.count
    }

    func requireLegacySpraySweepCompletion(vineyard: UUID) throws {
        let journal = LegacySpraySaveRecovery(persistence: persistence)
        if try journal.attempts().contains(where: { item in
            guard item.scope.vineyard == vineyard else { return false }
            return try journal.requiresLegacyReceipt(item)
        }) {
            throw SprayPlanningAdmissionError(message: "Legacy creation evidence remains held on this device pending verified paired-create recovery.")
        }
    }

    func isLegacySpraySyncHeld(record: UUID? = nil, trip: UUID? = nil) throws -> Bool {
        try LegacySpraySaveRecovery(persistence: persistence).contains(record: record, trip: trip)
    }

    /// The ordinary REST upsert is not an immutable create receipt. Never replay a retained pair through LWW.
    func requireLegacySpraySyncAdmission(record: UUID? = nil, trip: UUID? = nil) throws {
        try reconcileLegacySpraySaves(isolatingHeldFailures: true)
        if try LegacySpraySaveRecovery(persistence: persistence).contains(record: record, trip: trip) {
            throw SprayPlanningAdmissionError(message: "Legacy Save for Later is retained locally. Exact paired-create receipt verification is required before synchronization.")
        }
    }

    @discardableResult
    func addSprayRecord(_ record: SprayRecord) -> Bool {
        guard admitSelectedMutation() else { return false }
        guard record.operationalPlanningBlocker == nil else { return false }
        guard let vineyardId = selectedVineyardId else { return false }
        var item = record
        item.vineyardId = vineyardId
        var next = sprayRecords
        next.append(item)
        do {
            try sprayRepo.saveRecordsSliceOrThrow(next, for: vineyardId)
        } catch { return false }
        sprayRecords = next
        onSprayRecordChanged?(item.id)
        return true
    }

    @discardableResult
    func updateSprayRecord(_ record: SprayRecord) -> Bool {
        guard operationalWriteAuthority.admit(vineyardId: record.vineyardId.uuidString) else { return false }
        guard record.operationalPlanningBlocker == nil else { return false }
        guard let vineyardId = selectedVineyardId, record.vineyardId == vineyardId else { return false }
        guard let index = sprayRecords.firstIndex(where: { $0.id == record.id && $0.vineyardId == vineyardId }) else { return false }
        var next = sprayRecords
        next[index] = record
        do {
            try sprayRepo.saveRecordsSliceOrThrow(next, for: vineyardId)
        } catch { return false }
        sprayRecords = next
        onSprayRecordChanged?(record.id)
        return true
    }

    func deleteSprayRecord(_ recordId: UUID) {
        guard let record = sprayRecords.first(where: { $0.id == recordId }), selectedVineyardId == record.vineyardId else { return }
        let vineyardId = record.vineyardId
        guard operationalWriteAuthority.admit(vineyardId: vineyardId.uuidString) else { return }
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

    /// Captured once when a maintenance editor opens, not when Save is tapped.
    /// The admission retains the account incarnation but rechecks current entitlement.
    struct MaintenanceEditScope {
        let vineyardId: UUID
        fileprivate let admission: VineyardMutationAdmission
    }

    func captureMaintenanceEditScope(vineyardId: UUID) -> MaintenanceEditScope? {
        guard let userProvider = currentUserIdProvider,
              let admission = try? VineyardMutationAdmission(currentUserId: userProvider, authority: operationalWriteAuthority) else { return nil }
        return MaintenanceEditScope(vineyardId: vineyardId, admission: admission)
    }

    private func admitMaintenanceMutation(vineyardId: UUID, scope: MaintenanceEditScope?) -> Bool {
        guard let captured = scope ?? captureMaintenanceEditScope(vineyardId: vineyardId),
              captured.vineyardId == vineyardId else { return false }
        do {
            try captured.admission.requireWrite(vineyardId: vineyardId)
            return true
        } catch { return false }
    }

    /// Persisted ownership wins over stale editor/selected-slice data. Ambiguity is a hold.
    private func maintenanceOriginal(_ id: UUID) -> MaintenanceLog? {
        let disk = maintenanceLogRepo.loadAll().filter { $0.id == id }
        if !disk.isEmpty { return disk.count == 1 ? disk.first : nil }
        let loaded = maintenanceLogs.filter { $0.id == id }
        return loaded.count == 1 ? loaded.first : nil
    }

    @discardableResult
    func addMaintenanceLog(_ log: MaintenanceLog, scope: MaintenanceEditScope? = nil) -> Bool {
        guard !maintenanceLogRepo.loadAll().contains(where: { $0.id == log.id }),
              !maintenanceLogs.contains(where: { $0.id == log.id }),
              admitMaintenanceMutation(vineyardId: log.vineyardId, scope: scope) else { return false }
        var slice = maintenanceLogRepo.load(for: log.vineyardId)
        slice.append(log)
        guard let accountId = currentUserIdProvider?() else { return false }
        do { try maintenanceLogRepo.saveLocal(log, accountId: accountId) }
        catch { return false }
        if selectedVineyardId == log.vineyardId { maintenanceLogs = slice }
        onMaintenanceLogChanged?(log.id)
        return true
    }

    @discardableResult
    func updateMaintenanceLog(_ log: MaintenanceLog, scope: MaintenanceEditScope? = nil) -> Bool {
        guard let original = maintenanceOriginal(log.id), original.vineyardId == log.vineyardId,
              admitMaintenanceMutation(vineyardId: original.vineyardId, scope: scope) else { return false }
        var slice = maintenanceLogRepo.load(for: original.vineyardId)
        var item = log
        item.createdBy = original.createdBy
        if let index = slice.firstIndex(where: { $0.id == log.id }) { slice[index] = item }
        else { slice.append(item) }
        guard let accountId = currentUserIdProvider?() else { return false }
        do { try maintenanceLogRepo.saveLocal(item, accountId: accountId) }
        catch { return false }
        if selectedVineyardId == original.vineyardId { maintenanceLogs = slice }
        onMaintenanceLogChanged?(log.id)
        return true
    }

    @discardableResult
    func deleteMaintenanceLog(_ logId: UUID, scope: MaintenanceEditScope? = nil) -> Bool {
        guard let original = maintenanceOriginal(logId),
              admitMaintenanceMutation(vineyardId: original.vineyardId, scope: scope) else { return false }
        let slice = maintenanceLogRepo.load(for: original.vineyardId).filter { $0.id != logId }
        guard let accountId = currentUserIdProvider?() else { return false }
        do { try maintenanceLogRepo.saveLocal(original, accountId: accountId, deleted: true) }
        catch { return false }
        if selectedVineyardId == original.vineyardId { maintenanceLogs = slice }
        onMaintenanceLogDeleted?(logId)
        return true
    }

    // MARK: - WorkTask CRUD

    func addWorkTask(_ task: WorkTask) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = task
        item.vineyardId = vineyardId
        workTasks.append(item)
        workTaskRepo.saveSlice(workTasks, for: vineyardId)
        onWorkTaskChanged?(item.id)
    }

    func updateWorkTask(_ task: WorkTask) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTasks.firstIndex(where: { $0.id == task.id }) else { return }
        workTasks[index] = task
        workTaskRepo.saveSlice(workTasks, for: vineyardId)
        onWorkTaskChanged?(task.id)
    }

    func deleteWorkTask(_ taskId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        workTasks.removeAll { $0.id == taskId }
        workTaskRepo.saveSlice(workTasks, for: vineyardId)
        onWorkTaskDeleted?(taskId)
    }

    // MARK: - WorkTaskLabourLine CRUD

    func addWorkTaskLabourLine(_ line: WorkTaskLabourLine) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = line
        item.vineyardId = vineyardId
        workTaskLabourLines.append(item)
        workTaskLabourLineRepo.saveSlice(workTaskLabourLines, for: vineyardId)
        onWorkTaskLabourLineChanged?(item.id)
    }

    func updateWorkTaskLabourLine(_ line: WorkTaskLabourLine) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTaskLabourLines.firstIndex(where: { $0.id == line.id }) else { return }
        workTaskLabourLines[index] = line
        workTaskLabourLineRepo.saveSlice(workTaskLabourLines, for: vineyardId)
        onWorkTaskLabourLineChanged?(line.id)
    }

    func deleteWorkTaskLabourLine(_ lineId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        workTaskLabourLines.removeAll { $0.id == lineId }
        workTaskLabourLineRepo.saveSlice(workTaskLabourLines, for: vineyardId)
        onWorkTaskLabourLineDeleted?(lineId)
    }

    // MARK: - PruningActivityLabourLine CRUD (sql/190)

    /// Every mutation below marks the parent ACTIVITY dirty rather than the line,
    /// because the server contract is a DESIRED-STATE save of the activity's
    /// whole set. A removal is therefore expressed as "this line is no longer in
    /// the set", which is what lets a replay be idempotent instead of
    /// resurrecting a line another device deleted.

    /// The live labour lines of ONE activity, in stable display order.
    func labourLines(forPruningActivity activityId: UUID) -> [PruningActivityLabourLine] {
        PruningActivityLabourCosting.lines(pruningActivityLabourLines, for: activityId)
    }

    func addPruningActivityLabourLine(_ line: PruningActivityLabourLine) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = line
        item.vineyardId = vineyardId
        pruningActivityLabourLines.append(item)
        pruningActivityLabourLineRepo.saveSlice(pruningActivityLabourLines, for: vineyardId)
        onPruningActivityLabourLinesChanged?(item.pruningActivityId)
    }

    func updatePruningActivityLabourLine(_ line: PruningActivityLabourLine) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = pruningActivityLabourLines.firstIndex(where: { $0.id == line.id }) else { return }
        pruningActivityLabourLines[index] = line
        pruningActivityLabourLineRepo.saveSlice(pruningActivityLabourLines, for: vineyardId)
        onPruningActivityLabourLinesChanged?(line.pruningActivityId)
    }

    func deletePruningActivityLabourLine(_ lineId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let removed = pruningActivityLabourLines.first(where: { $0.id == lineId }) else { return }
        pruningActivityLabourLines.removeAll { $0.id == lineId }
        pruningActivityLabourLineRepo.saveSlice(pruningActivityLabourLines, for: vineyardId)
        onPruningActivityLabourLinesChanged?(removed.pruningActivityId)
    }

    /// Replaces ONE activity's whole set — the local twin of the RPC contract.
    /// `line_index` is renumbered from the given order so the stored display
    /// order is the order the operator actually sees.
    func replacePruningActivityLabourLines(
        _ lines: [PruningActivityLabourLine],
        forPruningActivity activityId: UUID
    ) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        pruningActivityLabourLines.removeAll { $0.pruningActivityId == activityId }
        for (index, line) in lines.enumerated() {
            var item = line
            item.vineyardId = vineyardId
            item.pruningActivityId = activityId
            item.lineIndex = index
            pruningActivityLabourLines.append(item)
        }
        pruningActivityLabourLineRepo.saveSlice(pruningActivityLabourLines, for: vineyardId)
        onPruningActivityLabourLinesChanged?(activityId)
    }

    /// Adopts the CANONICAL server set for one activity after a successful
    /// `save_pruning_activity_labour_lines` or pull. Deliberately silent: the
    /// server has just acknowledged this state, so re-marking it dirty would
    /// push the same rows back forever.
    func applyRemotePruningActivityLabourLines(
        _ lines: [PruningActivityLabourLine],
        forPruningActivity activityId: UUID,
        vineyardId: UUID
    ) {
        if selectedVineyardId == vineyardId {
            pruningActivityLabourLines.removeAll { $0.pruningActivityId == activityId }
            pruningActivityLabourLines.append(contentsOf: lines)
            pruningActivityLabourLineRepo.saveSlice(pruningActivityLabourLines, for: vineyardId)
        } else {
            var all = pruningActivityLabourLineRepo.loadAll()
            all.removeAll { $0.pruningActivityId == activityId }
            all.append(contentsOf: lines)
            pruningActivityLabourLineRepo.replace(
                all.filter { $0.vineyardId == vineyardId },
                for: vineyardId
            )
        }
    }

    // MARK: - WorkTaskMachineLine CRUD

    func addWorkTaskMachineLine(_ line: WorkTaskMachineLine) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = line
        item.vineyardId = vineyardId
        workTaskMachineLines.append(item)
        workTaskMachineLineRepo.saveSlice(workTaskMachineLines, for: vineyardId)
        onWorkTaskMachineLineChanged?(item.id)
    }

    func updateWorkTaskMachineLine(_ line: WorkTaskMachineLine) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTaskMachineLines.firstIndex(where: { $0.id == line.id }) else { return }
        workTaskMachineLines[index] = line
        workTaskMachineLineRepo.saveSlice(workTaskMachineLines, for: vineyardId)
        onWorkTaskMachineLineChanged?(line.id)
    }

    func deleteWorkTaskMachineLine(_ lineId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        workTaskMachineLines.removeAll { $0.id == lineId }
        workTaskMachineLineRepo.saveSlice(workTaskMachineLines, for: vineyardId)
        onWorkTaskMachineLineDeleted?(lineId)
    }

    // MARK: - WorkTaskPaddock CRUD

    func addWorkTaskPaddock(_ paddock: WorkTaskPaddock) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = paddock
        item.vineyardId = vineyardId
        workTaskPaddocks.append(item)
        workTaskPaddockRepo.saveSlice(workTaskPaddocks, for: vineyardId)
        onWorkTaskPaddockChanged?(item.id)
    }

    func updateWorkTaskPaddock(_ paddock: WorkTaskPaddock) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTaskPaddocks.firstIndex(where: { $0.id == paddock.id }) else { return }
        workTaskPaddocks[index] = paddock
        workTaskPaddockRepo.saveSlice(workTaskPaddocks, for: vineyardId)
        onWorkTaskPaddockChanged?(paddock.id)
    }

    func deleteWorkTaskPaddock(_ paddockRowId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        workTaskPaddocks.removeAll { $0.id == paddockRowId }
        workTaskPaddockRepo.saveSlice(workTaskPaddocks, for: vineyardId)
        onWorkTaskPaddockDeleted?(paddockRowId)
    }

    // MARK: - WorkTaskPieceRateRow CRUD (sql/188)

    /// Every historical row snapshot of one piece-rate job, in row order.
    func pieceRateRows(forWorkTask workTaskId: UUID) -> [WorkTaskPieceRateRow] {
        workTaskPieceRateRows
            .filter { $0.workTaskId == workTaskId }
            .sorted { ($0.rowNumber ?? 0) < ($1.rowNumber ?? 0) }
    }

    func addWorkTaskPieceRateRow(_ row: WorkTaskPieceRateRow) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = row
        item.vineyardId = vineyardId
        workTaskPieceRateRows.append(item)
        workTaskPieceRateRowRepo.saveSlice(workTaskPieceRateRows, for: vineyardId)
        onWorkTaskPieceRateRowChanged?(item.id)
    }

    func updateWorkTaskPieceRateRow(_ row: WorkTaskPieceRateRow) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTaskPieceRateRows.firstIndex(where: { $0.id == row.id }) else { return }
        workTaskPieceRateRows[index] = row
        workTaskPieceRateRowRepo.saveSlice(workTaskPieceRateRows, for: vineyardId)
        onWorkTaskPieceRateRowChanged?(row.id)
    }

    func deleteWorkTaskPieceRateRow(_ rowId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        workTaskPieceRateRows.removeAll { $0.id == rowId }
        workTaskPieceRateRowRepo.saveSlice(workTaskPieceRateRows, for: vineyardId)
        onWorkTaskPieceRateRowDeleted?(rowId)
    }

    /// Replaces a job's ENTIRE row snapshot in one operation.
    ///
    /// Called only when the job's piece-rate basis is being created or
    /// deliberately re-agreed. Snapshots for rows that are no longer part of
    /// the job are soft-deleted; the rest are upserted by their stable id, so a
    /// retry can never duplicate the history.
    func replaceWorkTaskPieceRateRows(_ rows: [WorkTaskPieceRateRow], forWorkTask workTaskId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        let existing = workTaskPieceRateRows.filter { $0.workTaskId == workTaskId }
        let keptIds = Set(rows.map(\.id))
        for removed in existing where !keptIds.contains(removed.id) {
            deleteWorkTaskPieceRateRow(removed.id)
        }
        for row in rows {
            var item = row
            item.vineyardId = vineyardId
            item.workTaskId = workTaskId
            if workTaskPieceRateRows.contains(where: { $0.id == item.id }) {
                updateWorkTaskPieceRateRow(item)
            } else {
                addWorkTaskPieceRateRow(item)
            }
        }
    }

    // MARK: - Material Costs CRUD (sql/247)

    /// The vineyard's effective material library: base catalogue merged with
    /// its own overrides and custom items AT READ TIME, so no vineyard is
    /// pre-populated with eighteen empty rows.
    func materialLibrary() -> [MaterialLibraryEntry] {
        guard let vineyardId = selectedVineyardId else { return [] }
        return MaterialLibrary.merged(
            catalogue: materialCatalogue,
            vineyardMaterials: vineyardMaterials,
            vineyardId: vineyardId
        )
    }

    // MARK: Vineyard material library

    func addVineyardMaterial(_ material: VineyardMaterial) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = material
        item.vineyardId = vineyardId
        vineyardMaterials.append(item)
        vineyardMaterialRepo.saveSlice(vineyardMaterials, for: vineyardId)
        onVineyardMaterialChanged?(item.id)
    }

    func updateVineyardMaterial(_ material: VineyardMaterial) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = vineyardMaterials.firstIndex(where: { $0.id == material.id }) else { return }
        vineyardMaterials[index] = material
        vineyardMaterialRepo.saveSlice(vineyardMaterials, for: vineyardId)
        onVineyardMaterialChanged?(material.id)
    }

    /// Deactivate a library material WITHOUT touching history.
    ///
    /// Historical `workTaskMaterials` rows are deliberately left alone: they
    /// read from their own snapshot, so a retired material never erases or
    /// alters the tasks that used it.
    func deactivateVineyardMaterial(_ materialId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = vineyardMaterials.firstIndex(where: { $0.id == materialId }) else { return }
        vineyardMaterials[index].isActive = false
        vineyardMaterialRepo.saveSlice(vineyardMaterials, for: vineyardId)
        onVineyardMaterialChanged?(materialId)
    }

    func deleteVineyardMaterial(_ materialId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        vineyardMaterials.removeAll { $0.id == materialId }
        vineyardMaterialRepo.saveSlice(vineyardMaterials, for: vineyardId)
        onVineyardMaterialDeleted?(materialId)
    }

    // MARK: Work Task material lines

    /// The material lines of ONE task, in stable display order.
    func materials(forWorkTask workTaskId: UUID) -> [WorkTaskMaterial] {
        WorkTaskMaterialCosting.lines(workTaskMaterials, for: workTaskId)
    }

    /// Total material cost of one task. A task with NO material rows returns
    /// zero without needing a row to say so.
    func materialTotal(forWorkTask workTaskId: UUID) -> Decimal {
        WorkTaskMaterialCosting.total(workTaskMaterials, for: workTaskId)
    }

    /// Persist a new material line.
    ///
    /// The id is already final (minted by the caller before any network call),
    /// so the offline create, its replay and the eventual server row are all
    /// the same row — a replay can never produce a second material line.
    func addWorkTaskMaterial(_ material: WorkTaskMaterial) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        var item = material
        item.vineyardId = vineyardId
        workTaskMaterials.append(item)
        workTaskMaterialRepo.saveSlice(workTaskMaterials, for: vineyardId)
        onWorkTaskMaterialChanged?(item.id)
    }

    func updateWorkTaskMaterial(_ material: WorkTaskMaterial) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        guard let index = workTaskMaterials.firstIndex(where: { $0.id == material.id }) else { return }
        workTaskMaterials[index] = material
        workTaskMaterialRepo.saveSlice(workTaskMaterials, for: vineyardId)
        onWorkTaskMaterialChanged?(material.id)
    }

    func deleteWorkTaskMaterial(_ materialId: UUID) {
        guard admitSelectedMutation() else { return }
        guard let vineyardId = selectedVineyardId else { return }
        workTaskMaterials.removeAll { $0.id == materialId }
        workTaskMaterialRepo.saveSlice(workTaskMaterials, for: vineyardId)
        onWorkTaskMaterialDeleted?(materialId)
    }

    // MARK: - Settings

    func saveSettings(_ newSettings: AppSettings) {
        guard admitSelectedMutation() else { return }
        settings = newSettings
        settingsRepo.upsert(newSettings)
    }
}

private nonisolated struct SelectedVineyardWrapper: Codable, Sendable {
    let id: UUID
}
