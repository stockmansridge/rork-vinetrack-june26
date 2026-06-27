package com.rork.vinetrack.ui

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import android.net.Uri
import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.ButtonConfigRepository
import com.rork.vinetrack.data.ButtonConfigUpdateSync
import com.rork.vinetrack.data.ConnectivityObserver
import com.rork.vinetrack.data.DamageRecordCreateSync
import com.rork.vinetrack.data.DamageRecordDeleteSync
import com.rork.vinetrack.data.DamageRecordUpdateSync
import com.rork.vinetrack.data.FuelLogCreateSync
import com.rork.vinetrack.data.FuelLogDeleteSync
import com.rork.vinetrack.data.DamageRecordRepository
import com.rork.vinetrack.data.FuelLogRepository
import com.rork.vinetrack.data.FuelLogUpdateSync
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.MaintenanceLogCreateSync
import com.rork.vinetrack.data.MaintenanceLogDeleteSync
import com.rork.vinetrack.data.MaintenanceLogRepository
import com.rork.vinetrack.data.MaintenancePhotoRepository
import com.rork.vinetrack.data.MaintenanceLogUpdateSync
import com.rork.vinetrack.data.PinPhotoImageUtil
import com.rork.vinetrack.data.PinPhotoRepository
import com.rork.vinetrack.data.VineyardLogoRepository
import com.rork.vinetrack.data.GrowthRecordCreateSync
import com.rork.vinetrack.data.GrowthRecordDeleteSync
import com.rork.vinetrack.data.GrowthRecordUpdateSync
import com.rork.vinetrack.data.GrowthStageImageRepository
import com.rork.vinetrack.data.GrowthStageRecordRepository
import com.rork.vinetrack.data.GrapeVarietyDeleteOutcome
import com.rork.vinetrack.data.PaddockReferenceCounts
import com.rork.vinetrack.data.PaddockRepository
import com.rork.vinetrack.data.PaddockTransferService
import com.rork.vinetrack.data.calculateRowLines
import com.rork.vinetrack.data.DomainCacheRepository
import com.rork.vinetrack.data.PendingPhotoRepository
import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.PendingWriteOverlay
import com.rork.vinetrack.data.PendingWriteRepository
import com.rork.vinetrack.data.AdminRepository
import com.rork.vinetrack.data.AlertPreferencesRepository
import com.rork.vinetrack.data.BillingGrantsRepository
import com.rork.vinetrack.data.HomePrefsStore
import com.rork.vinetrack.data.OnboardingStore
import com.rork.vinetrack.data.PinCompletionSync
import com.rork.vinetrack.data.PinCreateSync
import com.rork.vinetrack.data.PinDeleteSync
import com.rork.vinetrack.data.PinEditSync
import com.rork.vinetrack.data.PinPhotoSync
import com.rork.vinetrack.data.model.PendingPhotoStatus
import com.rork.vinetrack.data.PinRepository
import com.rork.vinetrack.data.ProfileRepository
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.RegionSettings
import com.rork.vinetrack.data.RegionSettingsRepository
import com.rork.vinetrack.data.RegionSettingsStore
import com.rork.vinetrack.data.RowAttachment
import com.rork.vinetrack.data.RowLockTracker
import com.rork.vinetrack.data.TeamRepository
import com.rork.vinetrack.data.OperatorCategoryRepository
import com.rork.vinetrack.data.VineyardTripFunctionRepository
import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.SavedInputRepository
import com.rork.vinetrack.data.SavedSprayPresetRepository
import com.rork.vinetrack.data.SprayEquipmentRepository
import com.rork.vinetrack.data.VineyardMachineRepository
import com.rork.vinetrack.data.EquipmentItemRepository
import com.rork.vinetrack.data.FuelPurchaseRepository
import com.rork.vinetrack.data.SprayProgramCsvImporter
import com.rork.vinetrack.data.SprayRecordCreateSync
import com.rork.vinetrack.data.SprayRecordDeleteSync
import com.rork.vinetrack.data.SprayRecordRepository
import com.rork.vinetrack.data.SprayRecordUpdateSync
import com.rork.vinetrack.data.TripDeleteSync
import com.rork.vinetrack.data.TripEndSync
import com.rork.vinetrack.data.TripStartSync
import com.rork.vinetrack.data.YieldEstimationSessionRepository
import com.rork.vinetrack.data.YieldSampleGenerator
import com.rork.vinetrack.data.YieldSessionDeleteSync
import com.rork.vinetrack.data.YieldSessionSaveSync
import com.rork.vinetrack.data.TripGpsSync
import com.rork.vinetrack.data.TripMetadataSync
import com.rork.vinetrack.data.TripSeedingSync
import com.rork.vinetrack.data.TripRowSync
import com.rork.vinetrack.data.TripTankSync
import com.rork.vinetrack.data.TripAuditRepository
import com.rork.vinetrack.data.TripRepository
import com.rork.vinetrack.data.VineyardRepository
import com.rork.vinetrack.data.SupportRepository
import com.rork.vinetrack.data.SystemAdminRepository
import com.rork.vinetrack.data.SupportRequestCategory
import com.rork.vinetrack.data.SupportSubmissionResult
import com.rork.vinetrack.data.SupportDiagnostics
import com.rork.vinetrack.data.AccountDeletionRepository
import com.rork.vinetrack.data.AccountDeletionPreflight
import com.rork.vinetrack.data.AccountDeletionRequestResult
import com.rork.vinetrack.data.WorkTaskCreateSync
import com.rork.vinetrack.data.WorkTaskUpdateSync
import com.rork.vinetrack.data.WorkTaskDeleteSync
import com.rork.vinetrack.data.WorkTaskLabourSync
import com.rork.vinetrack.data.WorkTaskMachineSync
import com.rork.vinetrack.data.WorkTaskPaddockRepository
import com.rork.vinetrack.data.WorkTaskPaddockSync
import com.rork.vinetrack.data.WorkTaskRepository
import com.rork.vinetrack.data.WorkTaskLineRepository
import com.rork.vinetrack.data.YieldRecordCreateSync
import com.rork.vinetrack.data.YieldRecordDeleteSync
import com.rork.vinetrack.data.YieldRecordUpdateSync
import com.rork.vinetrack.data.YieldRepository
import com.rork.vinetrack.data.auth.AuthRepository
import com.rork.vinetrack.data.auth.BiometricStore
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.GrapeVarietyRow
import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.GrowthStageImage
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.HistoricalBlockResult
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.data.model.LauncherButton
import com.rork.vinetrack.data.model.MaintenanceLog
import com.rork.vinetrack.data.model.applyGrowthInput
import com.rork.vinetrack.data.model.applyMaintenanceInput
import com.rork.vinetrack.data.model.AlertPreferences
import com.rork.vinetrack.data.model.Invitation
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.VineyardTripFunction
import com.rork.vinetrack.data.model.builtInTripFunctions
import com.rork.vinetrack.data.model.slugifyTripFunction
import com.rork.vinetrack.data.model.tripFunctionDisplayName
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.AppNotice
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SavedInput
import com.rork.vinetrack.data.model.SavedSprayPreset
import com.rork.vinetrack.data.model.SprayEquipment
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.TractorFuelLog
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.EquipmentItem
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.WorkTaskMachineLine
import com.rork.vinetrack.data.model.WorkTaskPaddock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

/** Top-level startup route, mirrors the iOS NewBackendRootView state machine. */
enum class AppRoute { Restoring, Login, BiometricLock, VineyardLoading, VineyardLoadFailed, NoVineyards, Main }

/**
 * Derived display state for an unresolved outbox entry (Tier-A Stage F-1).
 * UI-layer only — it never persists and never mutates the stored
 * [PendingWriteStatus]. It refines the overloaded [PendingWriteStatus.FAILED]
 * into clearer user-facing states (in particular dependency-waiting vs genuine
 * retrying) by reading the same-trip dependency context at render time.
 */
/**
 * Replay attempt cap shared by every coordinator (PinCreateSync, TripEndSync,
 * … all use MAX_ATTEMPTS = 8). Used for the read-only "Attempt X of 8" display
 * on the Sync Status screen (Tier-A Stage F-1); it does not drive any retry.
 */
private const val MAX_DISPLAY_ATTEMPTS = 8

enum class PendingSyncDisplayState(val label: String) {
    /** Enqueued, not yet attempted. */
    Pending("Waiting to sync"),
    /** A replay attempt is currently in flight. */
    Syncing("Syncing…"),
    /** A dependent same-trip marker is held until its TRIP_START server row exists. */
    WaitingForTripStart("Waiting for trip start"),
    /** A trip-end marker is held until same-trip GPS/row/tank/metadata changes sync. */
    WaitingForTripChanges("Waiting for trip changes"),
    /** A real transient failure that will be retried automatically. */
    Retrying("Retrying"),
    /** Genuinely blocked — needs the user's attention. */
    NeedsAttention("Needs attention"),
}

/**
 * A single unresolved outbox entry surfaced read-only on the Sync Status screen
 * (Stage 4A-iv; display clarity refined in Tier-A Stage F-1). Derived from
 * [PendingWrite]; carries only display strings so the screen never touches the
 * repository or payloads directly. Building this item never mutates the stored
 * pending row — the dependency-aware labels are derived, not persisted.
 */
/** Coarse per-record sync state for list badges, mirroring iOS `RecordSyncState`. */
enum class TripSyncBadge { SYNCED, QUEUED, SYNCING, ERROR }

data class PendingSyncItem(
    val id: String,
    val title: String,
    /** User-facing status line derived from [PendingSyncDisplayState]. */
    val displayStatusLabel: String,
    /** Plain-language explanation (dependency wait / friendly error). */
    val friendlyDetail: String? = null,
    /** e.g. "Attempt 3 of 8" — only for genuinely retrying/blocked rows. */
    val attemptLabel: String? = null,
    /** Raw error retained for debugging, shown de-emphasised when it adds detail. */
    val rawDetail: String? = null,
    // Tier-A Stage F-3 — read-only details surface fields. These mirror the
    // stored outbox row's non-sensitive metadata for a details sheet + copyable
    // diagnostics. Building or showing them never mutates the pending row, and
    // the opaque payload JSON is deliberately excluded.
    /** Outbox entity discriminator (e.g. "trip_start", "pin"). */
    val entityType: String = "",
    /** Operation kind ("create" / "update" / "delete"). */
    val opType: String = "",
    /** Stable client idempotency key / related record id (trip id or pin id). */
    val clientId: String = "",
    /** Raw stored lifecycle status ("pending" / "failed" / "blocked" / …). */
    val status: String = "",
    /**
     * Whether this row is safe for an explicit per-item retry (Tier-A Stage
     * F-2b). True only for FAILED rows (real transient failures or
     * dependency-deferred markers); BLOCKED / PENDING / IN_PROGRESS / SYNCED
     * are excluded. Display-only — the actual retry still routes through the
     * full ordered replay pipeline.
     */
    val canRetry: Boolean = false,
    /** Replay attempt count so far. */
    val attemptCount: Int = 0,
    /** Epoch millis the row was first enqueued. */
    val createdAt: Long = 0L,
    /** Epoch millis of the last status/error change. */
    val updatedAt: Long = 0L,
    /**
     * Multi-line, copy-ready diagnostic block for support/debugging (Stage
     * F-3). Contains only non-sensitive metadata — no payload JSON, secrets,
     * tokens, or auth/session data.
     */
    val diagnosticText: String = "",
)

/**
 * Read-only summary of the local domain read-cache (Stage 6A). Informational
 * only — surfaced on the Sync Status screen so the user can see that field data
 * has been saved on the device. Counts/timestamps reflect the last successful
 * online read written through to [DomainCacheRepository].
 */
data class DomainCacheStatus(
    val hasVineyards: Boolean = false,
    val vineyardsSyncedAt: Long? = null,
    val paddockCount: Int = 0,
    val pinCount: Int = 0,
    val selectedSyncedAt: Long? = null,
)

data class AuthFormState(
    val isLoading: Boolean = false,
    val error: String? = null,
)

data class AppUiState(
    val route: AppRoute = AppRoute.Restoring,
    /**
     * Whether the first-launch welcome carousel has been completed on this
     * device (mirrors iOS `OnboardingState`). Gates the intro shown once after
     * sign-in, before Main.
     */
    val onboardingCompleted: Boolean = true,
    val vineyards: List<Vineyard> = emptyList(),
    val selectedVineyardId: String? = null,
    /** The user's preferred default vineyard (auto-selected on launch). */
    val defaultVineyardId: String? = null,
    /**
     * Region & units settings for the selected vineyard, controlling how values
     * are displayed across the app (currency, area, volume, fuel, distance,
     * spray rate). Defaults to the Australian preset so AU/NZ output is
     * unchanged. Consume via [regionFormatter].
     */
    val regionSettings: RegionSettings = RegionSettings.defaults,
    val paddocks: List<Paddock> = emptyList(),
    val pins: List<Pin> = emptyList(),
    val trips: List<Trip> = emptyList(),
    val machines: List<VineyardMachine> = emptyList(),
    val workTasks: List<WorkTask> = emptyList(),
    val members: List<VineyardMember> = emptyList(),
    val operatorCategories: List<OperatorCategory> = emptyList(),
    /** Vineyard-scoped custom Trip Functions (active + archived) for the picker and Settings. */
    val vineyardTripFunctions: List<VineyardTripFunction> = emptyList(),
    val sprayRecords: List<SprayRecord> = emptyList(),
    val sprayEquipment: List<SprayEquipment> = emptyList(),
    val savedChemicals: List<SavedChemical> = emptyList(),
    /** Shared Saved Inputs library (seed/fertiliser/etc.) backing seeding-trip costing. */
    val savedInputs: List<SavedInput> = emptyList(),
    val savedSprayPresets: List<SavedSprayPreset> = emptyList(),
    val maintenanceLogs: List<MaintenanceLog> = emptyList(),
    val growthRecords: List<GrowthStageRecord> = emptyList(),
    val fuelLogs: List<TractorFuelLog> = emptyList(),
    /** `fuel_purchases` for the vineyard, driving weighted fuel cost per litre + Equipment Fuel section. */
    val fuelPurchases: List<FuelPurchase> = emptyList(),
    /** General-purpose "Other" equipment items (`equipment_items`) for the Equipment area. */
    val equipmentItems: List<EquipmentItem> = emptyList(),
    /** Error surfaced by Equipment (machines / other items / fuel purchases) writes. */
    val equipmentError: String? = null,
    /** Per-vineyard Repairs launcher buttons from `vineyard_button_configs` (empty = use defaults). */
    val repairButtons: List<LauncherButton> = emptyList(),
    /** Per-vineyard Growth launcher buttons from `vineyard_button_configs` (empty = use defaults). */
    val growthButtons: List<LauncherButton> = emptyList(),
    val grapeVarieties: List<GrapeVarietyRow> = emptyList(),
    val yieldRecords: List<HistoricalYieldRecord> = emptyList(),
    val damageRecords: List<DamageRecord> = emptyList(),
    /** Working yield-estimation sessions for the selected vineyard (Stage Q). */
    val yieldSessions: List<YieldEstimationSession> = emptyList(),
    val yieldSessionBusy: Boolean = false,
    val yieldSessionError: String? = null,
    val isLoadingVineyardData: Boolean = false,
    val paddockError: String? = null,
    /** Transient error surfaced by block create/edit/delete writes. */
    val blockEditError: String? = null,
    val pinError: String? = null,
    val tripError: String? = null,
    /** Active app-wide notices ("system messages") fetched from the backend. */
    val appNotices: List<AppNotice> = emptyList(),
    /** Per-device dismissed notice ids, restored from on-device prefs. */
    val dismissedNoticeIds: Set<String> = emptySet(),
    val pinPhotoBusy: Boolean = false,
    val vineyardLogoBusy: Boolean = false,
    /**
     * Decoded logo bitmap for the currently selected vineyard, cached so the
     * dashboard header/overview and exported PDFs can render it. `null` when the
     * vineyard has no logo or it hasn't loaded yet. Mirrors iOS `logoData`.
     */
    val selectedVineyardLogo: Bitmap? = null,
    /**
     * Custom E-L growth-stage reference images for the selected vineyard, keyed
     * by stage code via [GrowthStageImage.stageCode]. Owners/managers curate
     * these; all members see them. Mirrors iOS `vineyard_growth_stage_images`.
     */
    val growthStageImages: List<GrowthStageImage> = emptyList(),
    /** Stage code currently uploading/removing its reference image, if any. */
    val growthStageImageBusyCode: String? = null,
    val tripBusy: Boolean = false,
    val isTracking: Boolean = false,
    /** Latest device course over ground (deg, 0–360) during the active trip. */
    val latestBearingDegrees: Double? = null,
    /** Latest ground speed (m/s) during the active trip. */
    val latestSpeedMetresPerSecond: Double? = null,
    /** Latest horizontal accuracy (m) during the active trip. */
    val latestAccuracyMetres: Double? = null,
    /** Live driving path (X.5) the operator is locked onto, if confident geometry exists. */
    val currentDrivingPathNumber: Double? = null,
    /** Row-lock confidence in [0.0, 1.0]; saturates after ~10s of continuous lock. */
    val rowLockConfidence: Double = 0.0,
    /** True when the row lock meets the iOS 0.6 "confident" threshold. */
    val rowLockIsConfident: Boolean = false,
    val workTaskError: String? = null,
    val workTaskBusy: Boolean = false,
    /**
     * Active work-task -> paddock join rows for the selected vineyard (sql/051).
     * A single work task can span multiple paddocks; these rows carry the full
     * set while [WorkTask.paddockId]/[WorkTask.paddockName] keep the primary
     * block snapshot for backwards compatibility.
     */
    val workTaskPaddocks: List<WorkTaskPaddock> = emptyList(),
    /** Labour lines for the work task currently open in detail. */
    val taskLabourLines: List<WorkTaskLabourLine> = emptyList(),
    /** Machine lines for the work task currently open in detail. */
    val taskMachineLines: List<WorkTaskMachineLine> = emptyList(),
    /** Work task id the loaded lines belong to (null when nothing is open). */
    val taskLinesTaskId: String? = null,
    val taskLinesLoading: Boolean = false,
    val taskLineBusy: Boolean = false,
    val taskLineError: String? = null,
    val sprayBusy: Boolean = false,
    val sprayError: String? = null,
    val maintenanceBusy: Boolean = false,
    val maintenanceError: String? = null,
    /** True while an invoice photo is uploading/removing for a maintenance log. */
    val maintenancePhotoBusy: Boolean = false,
    val growthBusy: Boolean = false,
    val growthError: String? = null,
    val growthPhotoBusy: Boolean = false,
    val yieldBusy: Boolean = false,
    val yieldError: String? = null,
    val damageBusy: Boolean = false,
    val damageError: String? = null,
    val fuelBusy: Boolean = false,
    val fuelError: String? = null,
    /** Signed-in user id, used to resolve the caller's vineyard role. */
    val currentUserId: String? = null,
    /**
     * True when the signed-in user is an active row in `public.system_admins`.
     * Gates the platform Admin dashboard + System Admin tools entry. Vineyard
     * owner/manager roles do NOT grant this — mirrors iOS `SystemAdminService`.
     */
    val isSystemAdmin: Boolean = false,
    /** Pending team invitations for the selected vineyard (Team & Access). */
    val pendingInvitations: List<Invitation> = emptyList(),
    /** True while a team mutation (invite/role/remove/transfer) is in flight. */
    val teamBusy: Boolean = false,
    val teamError: String? = null,
    /** Saved alert preferences for the selected vineyard (null until loaded). */
    val alertPreferences: AlertPreferences? = null,
    val alertPrefsLoading: Boolean = false,
    val alertPrefsBusy: Boolean = false,
    val alertPrefsError: String? = null,
    /** True while a launcher button-config save is in flight. */
    val buttonConfigBusy: Boolean = false,
    val buttonConfigError: String? = null,
    /**
     * Device connectivity (Stage 4A-i). Defaults to true so startup never
     * blocks on connectivity; updated live by [ConnectivityObserver]. This is
     * informational only — no write path queues or retries based on it yet.
     */
    val isOnline: Boolean = true,
    /**
     * Number of writes waiting to sync, sourced from [PendingWriteRepository].
     * Stays 0 until a future slice enqueues real deferred writes — nothing in
     * the production write paths enqueues yet (Stage 4A-ii is skeleton only).
     */
    val pendingSyncCount: Int = 0,
    /**
     * Read-only summaries of the unresolved outbox entries (Stage 4A-iv). Only
     * queued pin creates land here today; shown on the Sync Status screen.
     */
    val pendingSyncItems: List<PendingSyncItem> = emptyList(),
    /**
     * Number of pin photos retained locally that are waiting to upload (Stage
     * 7B). A photo lands here when a pin is created offline with a photo, or an
     * online pin row was created but its photo upload failed. Stage 7C uploads
     * these once their pin exists server-side; this count drops as they sync.
     */
    val pendingPhotoCount: Int = 0,
    /**
     * Subset of [pendingPhotoCount] that hit the retry cap or a permanent error
     * and are blocked (Stage 7C). Surfaced as a gentle "needs attention" line.
     */
    val pendingPhotoBlockedCount: Int = 0,
    /**
     * True when at least one unresolved outbox row is retry-eligible (a FAILED
     * row — a real transient failure or a dependency-deferred marker) so the
     * Sync Status screen can offer an explicit "Retry all" (Tier-A Stage F-2).
     * BLOCKED rows are excluded, so a genuinely blocked-only queue offers no
     * retry. Display gating only — the screen also requires connectivity.
     */
    val canRetrySync: Boolean = false,
    /**
     * True for the brief window after the user taps "Retry all" while the
     * ordered replay pipeline is being kicked off (Tier-A Stage F-2). Used only
     * to show a transient "Retrying…" hint and avoid double-taps; the pending
     * list itself updates reactively as rows resolve.
     */
    val isRetryingSync: Boolean = false,
    /**
     * Read-cache status for launch-critical data (Stage 6A). Informational only:
     * reflects what the local [DomainCacheRepository] has written through on
     * successful online reads. Nothing in the app hydrates from this cache yet.
     */
    val cacheStatus: DomainCacheStatus = DomainCacheStatus(),
    /**
     * True when launch-critical field data (vineyard list and/or the selected
     * vineyard's blocks/pins) is being served from the local read-cache because
     * a live fetch failed (Stage 6B). Display-only — it never implies full
     * offline mode and never grants permissions; the server stays authoritative
     * once online. Cleared when a fresh online load succeeds.
     */
    val isUsingCachedFieldData: Boolean = false,
    /** Epoch millis the currently-shown cached field data was last saved online. */
    val cachedFieldDataLastSyncedAt: Long? = null,
    /**
     * Client pin UUIDs whose CREATE is still queued/unresolved in the outbox
     * (offline-created pins not yet on the server). Derived from
     * [PendingWriteRepository]; drives per-pin "pending sync" indicators only.
     */
    val pendingPinIds: Set<String> = emptySet(),
    /** Subset of [pendingPinIds] whose create is blocked and needs attention. */
    val blockedPinIds: Set<String> = emptySet(),
    /**
     * Client pin UUIDs with a retained photo still waiting to upload. Derived
     * from [PendingPhotoRepository]; drives per-pin "photo waiting" indicators.
     */
    val pendingPhotoPinIds: Set<String> = emptySet(),
    /** Subset of [pendingPhotoPinIds] whose photo upload is blocked. */
    val blockedPhotoPinIds: Set<String> = emptySet(),
    /**
     * Pin ids whose completion toggle is queued/unresolved in the outbox
     * (Stage 9A — offline Done/Open change not yet replayed). Derived from
     * [PendingWriteRepository]; drives per-pin "pending sync" indicators.
     */
    val pendingCompletionPinIds: Set<String> = emptySet(),
    /** Subset of [pendingCompletionPinIds] whose completion replay is blocked. */
    val blockedCompletionPinIds: Set<String> = emptySet(),
    /**
     * Pin ids whose descriptive edit (title/notes/category/mode) is queued and
     * unresolved in the outbox (Stage 9B-3 — offline edit not yet replayed).
     * Derived from [PendingWriteRepository]; drives per-pin "pending sync".
     */
    val pendingEditPinIds: Set<String> = emptySet(),
    /** Subset of [pendingEditPinIds] whose edit replay is blocked (e.g. a conflict). */
    val blockedEditPinIds: Set<String> = emptySet(),
    /**
     * Trip ids the operator finished offline (or whose online end failed
     * transiently) so the server row is still active but a TRIP_END marker is
     * queued (Tier-A Stage B-2-1). In-memory only. Drives the locally-ended UI
     * (the trip no longer counts as the live active trip) and gates further
     * GPS / row / tank actions, while the durable Stage A snapshot is preserved
     * until the end marker successfully syncs.
     */
    val locallyEndedTripIds: Set<String> = emptySet(),
) {
    val selectedVineyard: Vineyard? get() = vineyards.firstOrNull { it.id == selectedVineyardId }

    /** Central, region-aware formatter for all display values (units/currency). */
    val regionFormatter: RegionFormatter get() = RegionFormatter(regionSettings)

    /**
     * Local sync/upload visibility for a single pin, derived from the pending
     * outbox and photo store. Display-only — never triggers replay or upload.
     */
    fun pinSyncState(pinId: String): PinSyncState = PinSyncState(
        pendingCreate = pinId in pendingPinIds,
        blockedCreate = pinId in blockedPinIds,
        pendingPhoto = pinId in pendingPhotoPinIds,
        blockedPhoto = pinId in blockedPhotoPinIds,
        pendingCompletion = pinId in pendingCompletionPinIds,
        blockedCompletion = pinId in blockedCompletionPinIds,
        pendingEdit = pinId in pendingEditPinIds,
        blockedEdit = pinId in blockedEditPinIds,
    )
    /**
     * Coarse per-trip sync state derived from the pending outbox, mirroring the
     * iOS `RecordSyncState`. Display-only — never triggers replay. A trip with no
     * unresolved trip-scoped markers is treated as synced.
     */
    fun tripSyncState(tripId: String): TripSyncBadge {
        val items = pendingSyncItems.filter { it.clientId == tripId && it.entityType.startsWith("trip") }
        if (items.isEmpty() && tripId !in locallyEndedTripIds) return TripSyncBadge.SYNCED
        if (items.any { it.status == "failed" }) return TripSyncBadge.ERROR
        if (items.any { it.status == "in_progress" }) return TripSyncBadge.SYNCING
        return TripSyncBadge.QUEUED
    }

    /** The caller's role in the selected vineyard, if known. */
    val currentRole: String? get() = members.firstOrNull { it.userId == currentUserId }?.role?.lowercase()
    /** Only owners and managers may edit launcher buttons (matches iOS + RLS). */
    val canEditLauncherButtons: Boolean get() = currentRole == "owner" || currentRole == "manager"
    val openPins: Int get() = pins.count { !it.isCompleted }
    val totalHectares: Double get() = paddocks.sumOf { it.areaHectares }
    val activeTrips: Int get() = trips.count { it.isActive }
    /**
     * The live active trip. A trip the operator ended locally (in
     * [locallyEndedTripIds]) is excluded even though the server row is still
     * active and its Stage A snapshot is retained for the queued end replay, so
     * the UI treats it as finished.
     */
    val activeTrip: Trip? get() = trips.firstOrNull { it.isActive && it.id !in locallyEndedTripIds }

    /**
     * Notices the device should display now — active, in-window, and not
     * previously dismissed on this device — ordered by priority then recency.
     * Mirrors iOS `AppNoticeService.visibleNotices`.
     */
    val visibleNotices: List<AppNotice>
        get() = appNotices
            .filter { it.id !in dismissedNoticeIds && it.isCurrentlyVisible() }
            .sortedWith(
                compareByDescending<AppNotice> { it.priority }
                    .thenByDescending { it.createdAtEpochMs }
            )
}

class AppViewModel(app: Application) : AndroidViewModel(app) {

    private val session = SessionStore(app)
    private val auth = AuthRepository(session)
    private val biometricStore = BiometricStore(app)
    private val onboardingStore = OnboardingStore(app)
    private val repo = VineyardRepository(session)
    private val pinRepo = PinRepository(session)
    private val pinPhotoRepo = PinPhotoRepository(session)
    private val vineyardLogoRepo = VineyardLogoRepository(session)
    private val tripRepo = TripRepository(session)
    private val workTaskRepo = WorkTaskRepository(session)
    private val workTaskLineRepo = WorkTaskLineRepository(session)
    private val sprayRepo = SprayRecordRepository(session)
    private val savedChemicalRepo = SavedChemicalRepository(session)
    private val savedInputRepo = SavedInputRepository(session)
    private val operatorCategoryRepo = OperatorCategoryRepository(session)
    private val tripFunctionRepo = VineyardTripFunctionRepository(session)
    private val sprayEquipmentRepo = SprayEquipmentRepository(session)
    private val machineRepo = VineyardMachineRepository(session)
    private val equipmentItemRepo = EquipmentItemRepository(session)
    private val fuelPurchaseRepo = FuelPurchaseRepository(session)
    private val savedSprayPresetRepo = SavedSprayPresetRepository(session)
    private val maintenanceRepo = MaintenanceLogRepository(session)
    private val maintenancePhotoRepo = MaintenancePhotoRepository(session)
    private val growthRepo = GrowthStageRecordRepository(session)
    private val paddockRepo = PaddockRepository(session)
    private val yieldRepo = YieldRepository(session)
    private val damageRepo = DamageRecordRepository(session)
    private val growthImageRepo = GrowthStageImageRepository(session)
    private val fuelRepo = FuelLogRepository(session)
    private val buttonConfigRepo = ButtonConfigRepository(session)
    private val profileRepo = ProfileRepository(session)
    private val teamRepo = TeamRepository(session)
    private val alertPrefsRepo = AlertPreferencesRepository(session)
    private val supportRepo = SupportRepository(session)
    private val accountDeletionRepo = AccountDeletionRepository(session)
    private val regionSettingsStore = RegionSettingsStore(app)
    private val regionSettingsRepo = RegionSettingsRepository(session)

    /**
     * Platform System Admin data layer (parity with iOS `SupabaseAdminRepository`
     * / `SupabaseSystemAdminRepository`). Exposed so the gated Admin dashboard
     * can issue read-only RPC calls directly. Every call is server-enforced.
     */
    val adminRepository = AdminRepository(session)
    val systemAdminRepository = SystemAdminRepository(session)
    val billingGrantsRepository = BillingGrantsRepository(session)

    /**
     * Owner/manager Trip Audit data layer (parity with iOS `TripAuditService`).
     * Reads trips/paddocks/vineyards across every accessible vineyard and
     * repairs `vineyard_id` integrity. RLS scopes reads; repairs are gated to
     * roles that can update trips.
     */
    val tripAuditRepository = TripAuditRepository(session)
    private val homePrefs = HomePrefsStore(app)

    /** Live device connectivity, independent of auth/session state. */
    private val connectivity = ConnectivityObserver(app)

    /**
     * Local pending-write outbox (Stage 4A-ii skeleton). Exposed via
     * [AppUiState.pendingSyncCount]. No write path enqueues into it yet, so the
     * count stays 0 in production.
     */
    private val pendingWrites = PendingWriteRepository(app)

    /**
     * Local store for pin photos retained when they can't upload immediately
     * (Stage 7B). Separate from the write outbox: it copies the compressed JPEG
     * to app-private storage and records an attachment keyed by the client pin
     * UUID. This slice only persists photos — no upload or retry is wired in.
     */
    private val pendingPhotos = PendingPhotoRepository(app)

    /**
     * Local read-cache for launch-critical vineyard data (Stage 6A). Written
     * through on successful online reads only; not yet used to hydrate app state
     * or drive routing (that lands in Stage 6B).
     */
    private val domainCache = DomainCacheRepository(app)

    /**
     * Offline replay coordinator for pin CREATE only (Stage 4A-iv). The first
     * and only write path wired into the outbox — every other write stays
     * online-only. Replayed on reconnect and after a successful vineyard load.
     */
    private val pinCreateSync = PinCreateSync(pinRepo, pendingWrites)

    /**
     * Replay coordinator for fuel-log CREATE only (Tier-A Stage H-1). Replays an
     * additive fuel-fill insert queued offline (or after a transient failure)
     * using the same client-generated id minted up front, then reconciles the
     * returned server row into state. Fuel-create only — never fuel update or
     * delete (both remain online-only in H-1) and never any other entity.
     */
    private val fuelCreateSync = FuelLogCreateSync(fuelRepo, pendingWrites)

    /**
     * Replay coordinator for queued fuel-log EDITS (Tier-A Stage H-2). Owns the
     * FUEL_LOG / UPDATE op only; create stays with [fuelCreateSync] and delete is
     * still online-only. Edits made while a same-log create is unresolved are
     * folded into that create rather than queued here.
     */
    private val fuelUpdateSync = FuelLogUpdateSync(fuelRepo, pendingWrites)

    /**
     * Replay coordinator for queued fuel-log DELETES (Tier-A Stage H-3). Owns the
     * FUEL_LOG / DELETE op only; create stays with [fuelCreateSync] and edit with
     * [fuelUpdateSync]. Replays the soft-delete RPC for an already-synced log,
     * deferring while a same-log create/update is still unresolved. A local-only
     * offline-created log is cancelled in place (see [deleteFuelLog]) rather than
     * queued here, so it can never be resurrected by a later create replay.
     */
    private val fuelDeleteSync = FuelLogDeleteSync(fuelRepo, pendingWrites)

    /**
     * Replay coordinator for spray-record CREATE only (Android Stage I-1).
     * Replays an additive spray-record insert queued offline (or after a
     * transient failure) using the same client-generated id minted up front,
     * then reconciles the returned server row into state. Spray-create only —
     * never spray update or delete (both remain online-only in I-1) and never any
     * other entity. The trip-coupled spray-create variants (which create a trip
     * first) are NOT queued here.
     */
    private val sprayCreateSync = SprayRecordCreateSync(sprayRepo, pendingWrites)

    /**
     * Replay coordinator for spray-record edits only (Android Stage I-2).
     * SPRAY_RECORD / UPDATE — never create (owned by [sprayCreateSync]) or delete
     * (still online-only). Defers while a same-record create is unresolved.
     */
    private val sprayUpdateSync = SprayRecordUpdateSync(sprayRepo, pendingWrites)

    /**
     * Replay coordinator for spray-record soft-deletes only (Android Stage I-3).
     * SPRAY_RECORD / DELETE — never create (owned by [sprayCreateSync]) or update
     * (owned by [sprayUpdateSync]). Defers while a same-record create/update is
     * unresolved; a local-only offline-created record is cancelled in place (see
     * [deleteSprayRecord]) rather than queued for delete.
     */
    private val sprayDeleteSync = SprayRecordDeleteSync(sprayRepo, pendingWrites)

    /**
     * Replay coordinator for work-task HEADER create only (Android Stage J-1).
     * WORK_TASK / CREATE — never work-task update/finalize/delete (still
     * online-only) and never any labour/machine/paddock line (parked for J-4/J-5)
     * or other entity. Mints the client id up front, replays the additive insert,
     * then reconciles the returned server row into state.
     */
    private val workTaskCreateSync = WorkTaskCreateSync(workTaskRepo, pendingWrites)

    /**
     * Replay coordinator for work-task HEADER edits only (Android Stage J-2).
     * WORK_TASK / UPDATE — covers metadata edits and finalize/reopen flips,
     * coalesced into one marker per task. Never create (owned by
     * [workTaskCreateSync], folded into when unresolved) or delete (still
     * online-only) and never any labour/machine line (parked for J-4/J-5).
     * Defers while a same-task create is unresolved.
     */
    private val workTaskUpdateSync = WorkTaskUpdateSync(workTaskRepo, pendingWrites)

    /**
     * Replay coordinator for work-task HEADER soft-deletes only (Android Stage
     * J-3). WORK_TASK / DELETE — never create (owned by [workTaskCreateSync]) or
     * update (owned by [workTaskUpdateSync]) and never any labour/machine line
     * (parked for J-4/J-5). Defers while a same-task create/update is unresolved;
     * a local-only offline-created task is cancelled in place (see
     * [deleteWorkTask]) rather than queued for delete.
     */
    private val workTaskDeleteSync = WorkTaskDeleteSync(workTaskRepo, pendingWrites)

    /**
     * Replay coordinator for work-task LABOUR lines only (Android Stage J-4).
     * WORK_TASK_LABOUR create/update/delete — the first work-task CHILD queue.
     * Never touches the work-task header (owned by the create/update/delete
     * header coordinators) and never any machine line (parked for J-5). Defers
     * every labour write while the parent task's create is still unresolved; a
     * never-synced line's markers are folded ([WorkTaskLabourSync.foldCreate]) or
     * cancelled in place ([WorkTaskLabourSync.cancelLocalCreate]) rather than
     * replayed against a parent that doesn't exist server-side.
     */
    private val workTaskLabourSync = WorkTaskLabourSync(workTaskLineRepo, pendingWrites)

    /**
     * Replay coordinator for work-task MACHINE lines only (Android Stage J-5).
     * WORK_TASK_MACHINE create/update/delete — the second work-task CHILD queue
     * (after labour, J-4). Never touches the work-task header (owned by the
     * create/update/delete header coordinators) and never any labour line (owned
     * by [workTaskLabourSync]). Defers every machine write while the parent
     * task's create is still unresolved; a never-synced line's markers are folded
     * ([WorkTaskMachineSync.foldCreate]) or cancelled in place
     * ([WorkTaskMachineSync.cancelLocalCreate]) rather than replayed against a
     * parent that doesn't exist server-side.
     */
    private val workTaskMachineSync = WorkTaskMachineSync(workTaskLineRepo, pendingWrites)

    private val workTaskPaddockRepo = WorkTaskPaddockRepository(session)

    /**
     * Replay coordinator for work-task -> paddock join rows only (Android Stage
     * R). WORK_TASK_PADDOCK create/delete — lets a single work task span multiple
     * paddocks (sql/051). Never touches the work-task header (owned by the
     * create/update/delete header coordinators) and never any labour/machine line
     * (owned by [workTaskLabourSync]/[workTaskMachineSync]). Defers every join
     * write while the parent task's create is still unresolved; a never-synced
     * row's create is cancelled in place ([WorkTaskPaddockSync.cancelLocalCreate])
     * rather than replayed against a parent that doesn't exist server-side.
     */
    private val workTaskPaddockSync = WorkTaskPaddockSync(workTaskPaddockRepo, pendingWrites)

    /**
     * Upload coordinator for retained pin photos only (Stage 7C). Replays
     * locally-persisted pin photos once their pin exists server-side, uploading
     * the JPEG and PATCHing `photo_path`. Pin-photo-only — never any other
     * entity or write type. Triggered after pin-create replay, on reconnect, and
     * after a successful vineyard load.
     */
    /**
     * Replay coordinator for maintenance-log CREATE only (Android Stage K-1).
     * MAINTENANCE_LOG / CREATE — the additive insert of a maintenance record
     * logged offline (or whose online insert hit a transient failure). Never
     * edits, archives/finalizes an existing log, deletes, or touches
     * invoice/photo upload (update/delete parked for K-2/K-3). No parent gate —
     * maintenance logs are top-level records. Placed after the work-task group
     * and before pin photos in every replay pipeline.
     */
    private val maintenanceCreateSync = MaintenanceLogCreateSync(maintenanceRepo, pendingWrites)

    /**
     * Replay coordinator for maintenance-log UPDATE only (Android Stage K-2).
     * MAINTENANCE_LOG / UPDATE — the PATCH of an existing maintenance record
     * edited offline (or whose online PATCH hit a transient failure). Never
     * inserts, deletes, or touches invoice/photo upload (delete parked for K-3).
     * Edits to a still-pending create fold into that create instead (see
     * [MaintenanceLogCreateSync.foldEdit]); a safety-net dependency gate defers a
     * stray UPDATE behind an unresolved same-log create. Placed immediately
     * after maintenance creates and before pin photos in every replay pipeline.
     */
    private val maintenanceUpdateSync = MaintenanceLogUpdateSync(maintenanceRepo, pendingWrites)

    /**
     * Replay coordinator for maintenance-log soft-DELETE only (Android Stage
     * K-3). MAINTENANCE_LOG / DELETE — the soft-delete RPC of an existing
     * maintenance record deleted offline (or whose online delete hit a transient
     * failure). Never inserts, edits, or touches invoice/photo upload. A
     * never-synced log is cancelled in place by the caller instead of queued. A
     * dependency gate defers a delete behind an unresolved same-log create/update
     * (no attempt consumed). Placed immediately after maintenance updates and
     * before pin photos in every replay pipeline.
     */
    private val maintenanceDeleteSync = MaintenanceLogDeleteSync(maintenanceRepo, pendingWrites)

    /**
     * Replay coordinator for yield-record CREATE only (Android Stage L-1).
     * YIELD_RECORD / CREATE — the additive insert of a seasonal yield record
     * (actual or estimate) archived offline (or whose online insert hit a
     * transient failure). Never edits an existing record, re-authors
     * actuals/estimates, deletes, or touches estimation sessions (update/delete
     * parked for L-2/L-3). No parent gate — yield records are top-level records.
     * Placed after the maintenance group and before pin photos in every replay
     * pipeline.
     */
    private val yieldCreateSync = YieldRecordCreateSync(yieldRepo, pendingWrites)

    /**
     * Replay coordinator for yield-record UPDATE only (Android Stage L-2).
     * YIELD_RECORD / UPDATE — the PATCH of an already-synced yield record edited
     * offline (re-authored estimate or adjusted actuals + notes) or whose online
     * PATCH hit a transient failure. Never inserts, deletes, or touches
     * estimation sessions (delete parked for L-3). A safety-net dependency gate
     * defers a stray UPDATE behind an unresolved same-record create. Placed
     * immediately after yield creates and before pin photos in every replay
     * pipeline.
     */
    private val yieldUpdateSync = YieldRecordUpdateSync(yieldRepo, pendingWrites)

    /**
     * Replay coordinator for yield-record DELETE only (Android Stage L-3).
     * YIELD_RECORD / DELETE — the soft-delete of an already-synced yield record
     * deleted offline (or whose online delete hit a transient failure). Never
     * inserts, edits, or touches estimation sessions. A dependency gate defers a
     * delete behind an unresolved same-record create/update, and the caller
     * cancels a local-only pending create in place rather than enqueueing.
     * Placed immediately after yield updates and before pin photos in every
     * replay pipeline.
     */
    private val yieldDeleteSync = YieldRecordDeleteSync(yieldRepo, pendingWrites)

    /**
     * Replay coordinator for growth-stage record CREATE only (Android Stage N-1).
     * GROWTH_RECORD / CREATE — the additive insert of an observation logged
     * offline (or whose online insert hit a transient failure). Never edits,
     * deletes, or touches photo uploads/removals (those remain online-only;
     * update/delete parked for N-2/N-3). No parent gate — growth records are
     * top-level records. Placed immediately after the yield group and before pin
     * photos in every replay pipeline.
     */
    private val growthCreateSync = GrowthRecordCreateSync(growthRepo, pendingWrites)

    /**
     * Replay coordinator for growth-stage record UPDATE only (Android Stage N-2).
     * GROWTH_RECORD / UPDATE — the form-owned edit of an already-synced
     * observation (or one whose online PATCH hit a transient failure). Never
     * inserts, deletes, or touches photo uploads/removals (delete parked for N-3;
     * photos stay online-only). Edits to a still-pending create fold into that
     * create instead (see [GrowthRecordCreateSync.foldEdit]); a safety-net
     * dependency gate defers a stray UPDATE behind an unresolved same-record
     * create. Placed immediately after growth creates and before pin photos in
     * every replay pipeline.
     */
    private val growthUpdateSync = GrowthRecordUpdateSync(growthRepo, pendingWrites)

    /**
     * Replay coordinator for growth-stage record soft-DELETE only (Android Stage
     * N-3). GROWTH_RECORD / DELETE — the soft-delete of an already-synced
     * observation (or one whose online delete hit a transient failure). Never
     * inserts, edits, or touches photo uploads/removals. A still-pending create is
     * cancelled locally by the caller rather than queued for delete; a safety-net
     * dependency gate defers a delete behind an unresolved same-record
     * create/update. Role-restricted (operators may create/edit but not delete) —
     * a permission rejection becomes BLOCKED, never an infinite retry. Placed
     * immediately after growth updates and before pin photos in every replay
     * pipeline.
     */
    private val growthDeleteSync = GrowthRecordDeleteSync(growthRepo, pendingWrites)

    /**
     * Replay coordinator for block-damage record CREATE only (Android Stage M-1).
     * DAMAGE_RECORD / CREATE — the additive insert of a damage record logged
     * offline (or whose online insert hit a transient failure). Never edits an
     * existing record, deletes, or touches any other entity. No parent gate —
     * damage records are top-level records. Placed after the growth group and
     * before button config in every replay pipeline.
     */
    private val damageCreateSync = DamageRecordCreateSync(damageRepo, pendingWrites)

    /**
     * Replay coordinator for block-damage record UPDATE only (Android Stage M-2).
     * DAMAGE_RECORD / UPDATE — the PATCH of an existing damage record edited
     * offline (or whose online PATCH hit a transient failure). Edits to a
     * still-pending create fold into that create instead (see
     * [DamageRecordCreateSync.foldEdit]); a safety-net dependency gate defers a
     * stray UPDATE behind an unresolved same-record create.
     */
    private val damageUpdateSync = DamageRecordUpdateSync(damageRepo, pendingWrites)

    /**
     * Replay coordinator for block-damage record soft-DELETE only (Android Stage
     * M-3). DAMAGE_RECORD / DELETE — the soft-delete of an already-synced record
     * deleted offline (or whose online delete hit a transient failure). A
     * never-synced record is cancelled in place by the caller instead of queued.
     * A dependency gate defers a delete behind an unresolved same-record
     * create/update. Role-restricted (operators may create/edit but not delete) —
     * a permission rejection becomes BLOCKED, never an infinite retry.
     */
    private val damageDeleteSync = DamageRecordDeleteSync(damageRepo, pendingWrites)

    /**
     * Replay coordinator for launcher button configuration UPDATE only (Android
     * Stage N). BUTTON_CONFIG / UPDATE — the merge-duplicates upsert of the
     * Repairs/Growth launcher buttons edited offline (or whose online upsert hit
     * a transient failure). Coalesced one-per (vineyard, config type). Owner/
     * manager-only via RLS — a permission rejection becomes BLOCKED, never an
     * infinite retry. Placed after the damage group and before pin photos in
     * every replay pipeline.
     */
    private val buttonConfigUpdateSync = ButtonConfigUpdateSync(buttonConfigRepo, pendingWrites)

    private val yieldSessionRepo = YieldEstimationSessionRepository(session)

    /**
     * Replay coordinator for yield-estimation session SAVE (upsert) only (Android
     * Stage Q). YIELD_SESSION / UPDATE — the merge-duplicates upsert of a working
     * session created/edited offline (or whose online upsert hit a transient
     * failure). Coalesced one-per session id; deferred/cancelled by a queued
     * same-session delete. Placed after the button-config group and before pin
     * photos in every replay pipeline.
     */
    private val yieldSessionSaveSync = YieldSessionSaveSync(yieldSessionRepo, pendingWrites)

    /**
     * Replay coordinator for yield-estimation session soft-DELETE only (Android
     * Stage Q). YIELD_SESSION / DELETE — the soft-delete of a session removed
     * offline (or whose online delete hit a transient failure). Cancels any
     * pending same-session save. Owner/manager/supervisor-only via RLS — a
     * permission rejection becomes BLOCKED, never an infinite retry. Runs after
     * the save pass.
     */
    private val yieldSessionDeleteSync = YieldSessionDeleteSync(yieldSessionRepo, pendingWrites)

    private val pinPhotoSync = PinPhotoSync(pinPhotoRepo, pinRepo, pendingPhotos, pendingWrites)

    /**
     * Offline replay coordinator for pin COMPLETION toggles only (Stage 9A).
     * Replays the completion-only write shape so a queued Done/Open change
     * lands without clobbering editable fields. Completion-only — never edit,
     * delete, or photo writes. Triggered on reconnect and after a successful
     * vineyard load, separately from pin-create/photo replay.
     */
    private val pinCompletionSync = PinCompletionSync(pinRepo, pendingWrites)

    /**
     * Offline replay coordinator for descriptive pin EDITS only (Stage 9B-3).
     * Replays the descriptive-only write shape (title/category/mode/notes) with
     * a stale-guard so a queued offline edit lands without clobbering newer
     * server data and without touching completion, delete, photo, paddock, or
     * row/snap fields. Triggered on reconnect and after a successful vineyard
     * load, separately from pin-create/photo/completion replay.
     */
    private val pinEditSync = PinEditSync(pinRepo, pendingWrites)

    /**
     * Offline replay coordinator for pin soft-DELETE only (Tier-A Stage G-1).
     * Replays the soft-delete write shape for a pin the server already knows
     * about, deferring while same-pin create/completion/edit/photo work is
     * unresolved. Soft-delete-only — never hard delete, trip delete, or any
     * destructive local recovery. Triggered on reconnect and after a successful
     * vineyard load, in the pin replay group before the trip replays.
     */
    private val pinDeleteSync = PinDeleteSync(pinRepo, pendingWrites, pendingPhotos)

    /**
     * Offline replay coordinator for safe scalar trip-detail edits only
     * (Tier-A Stage B-1): metadata / pause-resume / start engine hours for an
     * existing active server trip. Replays the narrow scalar write shape with a
     * stale-guard so a queued offline edit lands without clobbering newer
     * server data and without touching path points, coverage, tank sessions,
     * or trip start/end/delete. Triggered on reconnect and after a successful
     * vineyard load, separately from the pin replay coordinators.
     */
    private val tripMetadataSync = TripMetadataSync(tripRepo, pendingWrites)

    /** Replays offline trip seeding-details edits (Android Stage S). */
    private val tripSeedingSync = TripSeedingSync(tripRepo, pendingWrites)

    /**
     * Durable local persistence for the single in-progress trip (Tier-A Stage A).
     * Restores active-trip state after process death / offline launch / silent
     * autosave failure. Local-only: NO replay, NO server writes — server write
     * contracts are unchanged.
     */
    private val activeTripStore = ActiveTripStore(app)

    /**
     * Offline replay coordinator for trip GPS/path progress only (Tier-A Stage
     * C-1). Uses one coalesced TRIP_GPS marker per trip plus the Stage A
     * snapshot as the local path source, merging against the live server path
     * before a guarded progress PATCH — never trip start/end, metadata, row
     * coverage, tank sessions, or delete. Triggered on reconnect and after a
     * successful vineyard load, separately from the other replay coordinators.
     */
    private val tripGpsSync = TripGpsSync(tripRepo, pendingWrites, activeTripStore)

    /**
     * Offline replay coordinator for trip row-coverage progress only (Tier-A
     * Stage D-1). Uses one coalesced TRIP_ROW marker per trip plus the Stage A
     * snapshot as the local coverage source, union-merging done/skip/undo
     * progress against the live server coverage before a guarded coverage PATCH
     * — never trip start/end, metadata, GPS/path, tank sessions, or delete.
     * Triggered on reconnect and after a successful vineyard load, separately
     * from the other replay coordinators.
     */
    private val tripRowSync = TripRowSync(tripRepo, pendingWrites, activeTripStore)

    /**
     * Offline replay coordinator for trip tank/fill progress only (Tier-A Stage
     * E-1). Uses one coalesced TRIP_TANK marker per trip plus the Stage A
     * snapshot as the local tank/fill source, union-merging tank sessions by id
     * and reconciling live tank scalars conservatively against the live server
     * tank state before a guarded tank PATCH — never trip start/end, metadata,
     * GPS/path, row coverage, engine hours, or delete. Triggered on reconnect
     * and after a successful vineyard load, separately from the other replay
     * coordinators.
     */
    private val tripTankSync = TripTankSync(tripRepo, pendingWrites, activeTripStore)

    /**
     * Offline replay coordinator for the trip-END summary only (Tier-A Stage
     * B-2-1). Uses one coalesced TRIP_END marker per trip carrying only the end
     * summary scalars (completion notes, end engine hours, requested end time).
     * DEPENDENCY-GATES on the same-trip TRIP_GPS / TRIP_ROW / TRIP_TANK /
     * TRIP_METADATA markers so a queued end never finalises with stale GPS / row
     * / tank / metadata state, then derives the final path/distance from the live
     * server trip before a guarded endTrip PATCH. Triggered on reconnect and
     * after a successful vineyard load, after the dependency replays.
     */
    private val tripEndSync = TripEndSync(tripRepo, pendingWrites, activeTripStore)

    /**
     * Trip soft-DELETE replay coordinator (Tier-A Stage G-2). Ended/inactive
     * trips only — never the active trip, never a locally-started unsynced trip,
     * never hard delete. Dependency-gates on same-trip start/metadata/GPS/row/
     * tank/end markers so a delete never races or orphans unsynced trip work.
     */
    private val tripDeleteSync = TripDeleteSync(tripRepo, pendingWrites)

    /**
     * Offline replay coordinator for trip START only (Tier-A Stage B-3-1). Uses
     * one coalesced TRIP_START / CREATE marker per locally-started trip carrying
     * only the scalar insert fields. The client-generated trip UUID is reused as
     * the server row id (idempotency key), so an idempotency probe avoids
     * duplicate inserts and every dependent same-trip marker attaches to the same
     * id with no remapping. Replayed FIRST — before metadata/GPS/row/tank/end —
     * on reconnect and after a successful vineyard load, so the server row exists
     * before any dependent marker writes to it.
     */
    private val tripStartSync = TripStartSync(tripRepo, pendingWrites)

    /** Foreground GPS tracker for the currently active trip (null when idle). */
    private var tracker: LocationTracker? = null

    /**
     * Active-trip row-lock state machine. Mirrors iOS so a future trip
     * quick-pin slice can read a confident driving path. This foundation
     * only computes/exposes state — it never writes `driving_row_number`.
     */
    private val rowLockTracker = RowLockTracker()
    private var pointsSinceSave = 0
    private var lastSaveMs = 0L
    // Local-snapshot throttle (Tier-A Stage A): persists the active trip on-device
    // more often than the server autosave so fewer tail GPS points are lost on
    // process death. Discrete events (row/tank/metadata/pause/start) persist
    // immediately and bypass this throttle.
    private var pointsSinceLocalSave = 0
    private var lastLocalSaveMs = 0L

    private val _ui = MutableStateFlow(AppUiState())
    val ui: StateFlow<AppUiState> = _ui.asStateFlow()

    private val _auth = MutableStateFlow(AuthFormState())
    val authState: StateFlow<AuthFormState> = _auth.asStateFlow()

    val userEmail: String? get() = auth.currentEmail

    // Biometric login (parity with iOS BiometricAuthService).

    /** Whether the user has opted into biometric login on this device. */
    val biometricEnabled: Boolean get() = biometricStore.isEnabled

    /** Email shown on the lock screen (falls back to the session email). */
    val biometricSavedEmail: String? get() = biometricStore.savedEmail ?: auth.currentEmail

    /** Whether the one-time enrollment offer has already been shown. */
    val biometricEnrollmentPromptShown: Boolean get() = biometricStore.hasShownEnrollmentPrompt

    fun markBiometricEnrollmentPromptShown() {
        biometricStore.hasShownEnrollmentPrompt = true
    }

    /**
     * Persist the biometric-login preference after the device prompt has already
     * confirmed the user's identity (the UI runs BiometricAuth.authenticate).
     */
    fun setBiometricEnabled(enabled: Boolean) {
        if (enabled) {
            biometricStore.isEnabled = true
            biometricStore.savedEmail = auth.currentEmail
            biometricStore.hasShownEnrollmentPrompt = true
        } else {
            biometricStore.clearAll()
        }
    }

    /**
     * Called from the lock screen after a successful unlock. Continues the
     * restored-session startup flow into vineyard loading.
     */
    fun onBiometricUnlocked() {
        if (_ui.value.route != AppRoute.BiometricLock) return
        _ui.update { it.copy(route = AppRoute.VineyardLoading) }
        viewModelScope.launch { loadVineyards() }
    }

    // First-launch onboarding (parity with iOS OnboardingView / OnboardingState).

    /** Mark the welcome carousel complete; flips [AppUiState.onboardingCompleted]. */
    fun completeOnboarding() {
        onboardingStore.markCompleted()
        _ui.update { it.copy(onboardingCompleted = true) }
    }

    /** Show the welcome carousel again (e.g. from Settings → About). */
    fun replayOnboarding() {
        onboardingStore.reset()
        _ui.update { it.copy(onboardingCompleted = false) }
    }

    /** "Use a different account" on the lock screen — drop biometrics and sign out. */
    fun signOutFromBiometricLock() {
        biometricStore.clearAll()
        signOut()
    }

    /** Display name from auth metadata, falling back to the email local-part. */
    val userName: String?
        get() = auth.currentName?.takeIf { it.isNotBlank() }
            ?: auth.currentEmail?.substringBefore('@')?.takeIf { it.isNotBlank() }

    /** Saved display name (no email fallback) — null when none is set yet. */
    val displayName: String? get() = auth.currentName?.takeIf { it.isNotBlank() }

    /**
     * Update the signed-in user's display name in Supabase auth metadata.
     * Mirrors iOS `EditDisplayNameView`. Calls back with success/failure.
     */
    fun updateDisplayName(name: String, onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            try {
                auth.updateDisplayName(name)
                onResult(true)
            } catch (e: Exception) {
                onResult(false)
            }
        }
    }

    /** Selected vineyard name for the support form contact row (mirrors iOS). */
    val selectedVineyardName: String? get() = _ui.value.selectedVineyard?.name

    /** App / build / device footer shown under the support submit button (mirrors iOS AppBuildInfo line). */
    val supportInfoFooter: String
        get() {
            val d = supportDiagnostics()
            val version = d.appVersion.takeIf { it.isNotBlank() } ?: "—"
            return "VineTrack $version · ${d.deviceModel} · ${d.osVersion}"
        }

    /** Device / app snapshot attached to a support request. */
    private fun supportDiagnostics(): SupportDiagnostics {
        val ctx = getApplication<Application>()
        val (versionName, versionCode) = runCatching {
            val pkg = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
            pkg.versionName.orEmpty() to pkg.longVersionCode.toString()
        }.getOrDefault("" to "")
        return SupportDiagnostics(
            appPlatform = "Android",
            appVersion = versionName,
            appBuild = versionCode,
            deviceModel = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim(),
            osVersion = "Android ${android.os.Build.VERSION.RELEASE}",
        )
    }

    /** Submit an in-app support / feedback / feature request (mirrors iOS SupportRequestView). */
    suspend fun submitSupportRequest(
        category: SupportRequestCategory,
        subject: String,
        message: String,
        submitterName: String?,
        submitterEmail: String?,
        attachments: List<ByteArray>,
    ): SupportSubmissionResult {
        val vineyard = _ui.value.vineyards.firstOrNull { it.id == _ui.value.selectedVineyardId }
        return supportRepo.submit(
            category = category,
            subject = subject,
            message = message,
            submitterName = submitterName,
            submitterEmail = submitterEmail,
            vineyardId = vineyard?.id,
            vineyardName = vineyard?.name,
            attachments = attachments,
            diagnostics = supportDiagnostics(),
        )
    }

    /** Compress a picked image to JPEG bytes for a support attachment. */
    suspend fun compressSupportAttachment(uri: Uri): ByteArray =
        PinPhotoImageUtil.compress(getApplication(), uri)

    /** Run the account-deletion preflight (shared-vineyard ownership check). */
    suspend fun accountDeletionPreflight(): AccountDeletionPreflight =
        accountDeletionRepo.preflight()

    /** Submit an account-deletion request for manual review. */
    suspend fun submitAccountDeletionRequest(reason: String? = null): AccountDeletionRequestResult =
        accountDeletionRepo.submitRequest(reason)

    init {
        observeConnectivity()
        observePendingWrites()
        observePendingPhotos()
        _ui.update {
            it.copy(
                dismissedNoticeIds = homePrefs.dismissedNoticeIds(),
                onboardingCompleted = onboardingStore.isCompleted,
            )
        }
        restore()
    }

    /**
     * Dismiss an app notice ("system message") on this device. Persists the id
     * so the banner stays hidden, mirroring iOS `AppNoticeService.dismiss`.
     */
    fun dismissNotice(id: String) {
        homePrefs.addDismissedNoticeId(id)
        _ui.update { it.copy(dismissedNoticeIds = it.dismissedNoticeIds + id) }
    }

    /**
     * Mirror the local pending-photo count into [AppUiState.pendingPhotoCount].
     * Read-only: observing the count never triggers an upload or retry.
     */
    private fun observePendingPhotos() {
        viewModelScope.launch {
            pendingPhotos.attachments.collect { list ->
                val pending = list.count { it.status in PendingPhotoStatus.unresolved }
                val blocked = list.count { it.status == PendingPhotoStatus.BLOCKED }
                val pendingPhotoIds = list.filter { it.status in PendingPhotoStatus.unresolved }
                    .map { it.clientPinId }.toSet()
                val blockedPhotoIds = list.filter { it.status == PendingPhotoStatus.BLOCKED }
                    .map { it.clientPinId }.toSet()
                _ui.update {
                    it.copy(
                        pendingPhotoCount = pending,
                        pendingPhotoBlockedCount = blocked,
                        pendingPhotoPinIds = pendingPhotoIds,
                        blockedPhotoPinIds = blockedPhotoIds,
                    )
                }
            }
        }
    }

    /**
     * Mirror the local outbox count into [AppUiState.pendingSyncCount]. Read-only:
     * observing the count never triggers a replay, retry, or any write.
     */
    private fun observePendingWrites() {
        viewModelScope.launch {
            pendingWrites.writes.collect { list ->
                val unresolved = list.filter { it.status in PendingWriteStatus.unresolved }
                // Derived dependency context (Tier-A Stage F-1) — read-only.
                // Trip markers key by clientId = tripId, so an unresolved
                // same-trip TRIP_START / trip-change marker is found by clientId.
                val unresolvedStartTripIds = unresolved.filter {
                    it.entityType == PendingEntityType.TRIP_START && it.opType == PendingOpType.CREATE
                }.map { it.clientId }.toSet()
                val tripChangeTypes = setOf(
                    PendingEntityType.TRIP_GPS,
                    PendingEntityType.TRIP_ROW,
                    PendingEntityType.TRIP_TANK,
                    PendingEntityType.TRIP_METADATA,
                )
                val unresolvedTripChangeIds = unresolved.filter { it.entityType in tripChangeTypes }
                    .map { it.clientId }.toSet()
                val items = unresolved.map {
                    it.toSyncItem(unresolvedStartTripIds, unresolvedTripChangeIds)
                }
                val pinCreates = unresolved.filter {
                    it.entityType == PendingEntityType.PIN && it.opType == PendingOpType.CREATE
                }
                val pendingPinIds = pinCreates.map { it.clientId }.toSet()
                val blockedPinIds = pinCreates.filter { it.status == PendingWriteStatus.BLOCKED }
                    .map { it.clientId }.toSet()
                // Stage 9A — queued completion toggles (pin UPDATE writes).
                val pinCompletions = unresolved.filter {
                    it.entityType == PendingEntityType.PIN && it.opType == PendingOpType.UPDATE
                }
                val pendingCompletionPinIds = pinCompletions.map { it.clientId }.toSet()
                val blockedCompletionPinIds = pinCompletions.filter { it.status == PendingWriteStatus.BLOCKED }
                    .map { it.clientId }.toSet()
                // Stage 9B-3 — queued descriptive edits (pin_edit UPDATE writes).
                val pinEdits = unresolved.filter {
                    it.entityType == PendingEntityType.PIN_EDIT && it.opType == PendingOpType.UPDATE
                }
                val pendingEditPinIds = pinEdits.map { it.clientId }.toSet()
                val blockedEditPinIds = pinEdits.filter { it.status == PendingWriteStatus.BLOCKED }
                    .map { it.clientId }.toSet()
                // Tier-A Stage F-2 — a row is retry-eligible only when FAILED
                // (a real transient failure or a dependency-deferred marker).
                // BLOCKED rows are deliberately excluded from "Retry all".
                val canRetry = unresolved.any { it.status == PendingWriteStatus.FAILED }
                _ui.update {
                    it.copy(
                        pendingSyncCount = unresolved.size,
                        pendingSyncItems = items,
                        canRetrySync = canRetry,
                        pendingPinIds = pendingPinIds,
                        blockedPinIds = blockedPinIds,
                        pendingCompletionPinIds = pendingCompletionPinIds,
                        blockedCompletionPinIds = blockedCompletionPinIds,
                        pendingEditPinIds = pendingEditPinIds,
                        blockedEditPinIds = blockedEditPinIds,
                    )
                }
            }
        }
    }

    /**
     * Map an outbox row to a display-only Sync Status summary (Tier-A Stage
     * F-1). Pure derivation: it reads the row plus the same-trip dependency
     * context and never mutates the stored pending row or its status.
     */
    private fun PendingWrite.toSyncItem(
        unresolvedStartTripIds: Set<String>,
        unresolvedTripChangeIds: Set<String>,
    ): PendingSyncItem {
        val title = when {
            entityType == PendingEntityType.TRIP_METADATA -> "Trip details"
            entityType == PendingEntityType.TRIP_GPS -> "Trip GPS"
            entityType == PendingEntityType.TRIP_ROW -> "Trip rows"
            entityType == PendingEntityType.TRIP_TANK -> "Trip tanks"
            entityType == PendingEntityType.TRIP_START -> "Trip start"
            entityType == PendingEntityType.TRIP_END -> "Trip end"
            entityType == PendingEntityType.PIN_EDIT -> "Pin edit"
            entityType == PendingEntityType.PIN && opType == PendingOpType.DELETE -> "Pin delete"
            entityType == PendingEntityType.TRIP && opType == PendingOpType.DELETE -> "Trip delete"
            entityType == PendingEntityType.FUEL_LOG && opType == PendingOpType.CREATE -> "Fuel log"
            entityType == PendingEntityType.FUEL_LOG && opType == PendingOpType.UPDATE -> "Fuel log edit"
            entityType == PendingEntityType.FUEL_LOG && opType == PendingOpType.DELETE -> "Fuel log delete"
            entityType == PendingEntityType.SPRAY_RECORD && opType == PendingOpType.CREATE -> "Spray record"
            entityType == PendingEntityType.SPRAY_RECORD && opType == PendingOpType.UPDATE -> "Spray record edit"
            entityType == PendingEntityType.SPRAY_RECORD && opType == PendingOpType.DELETE -> "Spray record delete"
            entityType == PendingEntityType.WORK_TASK && opType == PendingOpType.CREATE -> "Work task"
            entityType == PendingEntityType.WORK_TASK && opType == PendingOpType.UPDATE -> "Work task edit"
            entityType == PendingEntityType.WORK_TASK && opType == PendingOpType.DELETE -> "Work task delete"
            entityType == PendingEntityType.WORK_TASK_LABOUR && opType == PendingOpType.CREATE -> "Work task labour"
            entityType == PendingEntityType.WORK_TASK_LABOUR && opType == PendingOpType.UPDATE -> "Work task labour edit"
            entityType == PendingEntityType.WORK_TASK_LABOUR && opType == PendingOpType.DELETE -> "Work task labour delete"
            entityType == PendingEntityType.WORK_TASK_MACHINE && opType == PendingOpType.CREATE -> "Work task machine"
            entityType == PendingEntityType.WORK_TASK_MACHINE && opType == PendingOpType.UPDATE -> "Work task machine edit"
            entityType == PendingEntityType.WORK_TASK_MACHINE && opType == PendingOpType.DELETE -> "Work task machine delete"
            entityType == PendingEntityType.MAINTENANCE_LOG && opType == PendingOpType.CREATE -> "Maintenance"
            entityType == PendingEntityType.MAINTENANCE_LOG && opType == PendingOpType.UPDATE -> "Maintenance edit"
            entityType == PendingEntityType.MAINTENANCE_LOG && opType == PendingOpType.DELETE -> "Maintenance delete"
            entityType == PendingEntityType.YIELD_RECORD && opType == PendingOpType.CREATE -> "Yield"
            entityType == PendingEntityType.YIELD_RECORD && opType == PendingOpType.UPDATE -> "Yield edit"
            entityType == PendingEntityType.YIELD_RECORD && opType == PendingOpType.DELETE -> "Yield delete"
            entityType == PendingEntityType.GROWTH_RECORD && opType == PendingOpType.CREATE -> "Growth"
            entityType == PendingEntityType.GROWTH_RECORD && opType == PendingOpType.UPDATE -> "Growth edit"
            entityType == PendingEntityType.GROWTH_RECORD && opType == PendingOpType.DELETE -> "Growth delete"
            entityType == PendingEntityType.PIN && opType == PendingOpType.UPDATE -> "Pin update"
            entityType == PendingEntityType.PIN -> "New pin"
            else -> "Pending change"
        }
        val displayState = deriveDisplayState(unresolvedStartTripIds, unresolvedTripChangeIds)
        // Attempt count only matters for genuinely retrying/blocked rows.
        // Dependency-waiting rows don't consume attempts, so attemptCount is 0
        // and no attempt line is shown.
        val attemptLabel = if (
            (status == PendingWriteStatus.FAILED || status == PendingWriteStatus.BLOCKED) &&
            attemptCount > 0
        ) {
            "Attempt $attemptCount of $MAX_DISPLAY_ATTEMPTS"
        } else {
            null
        }
        val friendly = friendlyDetailFor(displayState, lastError)
        // Keep the raw error for debugging, but only when it adds something
        // beyond the friendly line.
        val raw = lastError?.takeIf { it.isNotBlank() && it != friendly }
        return PendingSyncItem(
            id = id,
            title = title,
            displayStatusLabel = displayState.label,
            friendlyDetail = friendly,
            attemptLabel = attemptLabel,
            rawDetail = raw,
            entityType = entityType,
            opType = opType,
            clientId = clientId,
            status = status,
            canRetry = status == PendingWriteStatus.FAILED,
            attemptCount = attemptCount,
            createdAt = createdAt,
            updatedAt = updatedAt,
            diagnosticText = buildDiagnosticText(
                title = title,
                displayState = displayState,
                friendly = friendly,
                raw = raw,
            ),
        )
    }

    /**
     * Build a copy-ready diagnostics block for a pending row (Tier-A Stage
     * F-3). Includes only non-sensitive metadata — entity/op/status/attempts,
     * timestamps, the related id, and the friendly + raw error lines. The
     * opaque payload JSON, secrets, tokens, and auth/session data are
     * deliberately excluded so the text is always safe to share with support.
     */
    private fun PendingWrite.buildDiagnosticText(
        title: String,
        displayState: PendingSyncDisplayState,
        friendly: String?,
        raw: String?,
    ): String {
        fun ts(millis: Long): String =
            if (millis > 0L) java.time.Instant.ofEpochMilli(millis).toString() else "—"
        return buildString {
            appendLine("Sync item: $title")
            appendLine("Display state: ${displayState.label}")
            appendLine("Entity type: $entityType")
            appendLine("Operation: $opType")
            appendLine("Related id: $clientId")
            appendLine("Status: $status")
            appendLine("Attempts: $attemptCount of $MAX_DISPLAY_ATTEMPTS")
            appendLine("Created: ${ts(createdAt)}")
            appendLine("Updated: ${ts(updatedAt)}")
            appendLine("Detail: ${friendly ?: "—"}")
            append("Diagnostic: ${raw ?: "—"}")
        }
    }

    /**
     * Derive a clearer display state from the stored status plus same-trip
     * dependency context (Tier-A Stage F-1). The stored [PendingWriteStatus]
     * is never changed; in particular the overloaded FAILED state is refined
     * into dependency-waiting vs genuine retrying so a deferred item never
     * looks like a real error.
     */
    private fun PendingWrite.deriveDisplayState(
        unresolvedStartTripIds: Set<String>,
        unresolvedTripChangeIds: Set<String>,
    ): PendingSyncDisplayState = when (status) {
        PendingWriteStatus.PENDING -> PendingSyncDisplayState.Pending
        PendingWriteStatus.IN_PROGRESS -> PendingSyncDisplayState.Syncing
        PendingWriteStatus.BLOCKED -> PendingSyncDisplayState.NeedsAttention
        PendingWriteStatus.FAILED -> {
            val dependsOnStart = entityType == PendingEntityType.TRIP_METADATA ||
                entityType == PendingEntityType.TRIP_GPS ||
                entityType == PendingEntityType.TRIP_ROW ||
                entityType == PendingEntityType.TRIP_TANK ||
                entityType == PendingEntityType.TRIP_END
            when {
                dependsOnStart && clientId in unresolvedStartTripIds ->
                    PendingSyncDisplayState.WaitingForTripStart
                entityType == PendingEntityType.TRIP_END && clientId in unresolvedTripChangeIds ->
                    PendingSyncDisplayState.WaitingForTripChanges
                else -> PendingSyncDisplayState.Retrying
            }
        }
        else -> PendingSyncDisplayState.Pending
    }

    /**
     * Map a stored raw error to a plain-language line for the user (Tier-A
     * Stage F-1). Dependency-waiting rows get a reassuring wait message;
     * genuine failures are mapped to friendly categories. The raw error is
     * retained separately on [PendingSyncItem.rawDetail] for debugging.
     */
    private fun friendlyDetailFor(
        state: PendingSyncDisplayState,
        lastError: String?,
    ): String? {
        when (state) {
            PendingSyncDisplayState.Pending,
            PendingSyncDisplayState.Syncing -> return null
            PendingSyncDisplayState.WaitingForTripStart,
            PendingSyncDisplayState.WaitingForTripChanges ->
                return "Waiting for earlier trip changes to sync first."
            else -> Unit
        }
        if (lastError.isNullOrBlank()) {
            return when (state) {
                PendingSyncDisplayState.NeedsAttention -> "This needs attention."
                else -> "We'll try again automatically."
            }
        }
        val raw = lastError.lowercase()
        return when {
            raw.contains("forbidden") || raw.contains("permission") ||
                raw.contains("not allowed") || raw.contains("unauthor") || raw.contains("403") ->
                "Permission problem. This needs attention."
            raw.contains("validation") || raw.contains("invalid") ||
                raw.contains("bad request") || raw.contains("400") || raw.contains("422") ->
                "This item couldn't be synced because some data is invalid."
            raw.contains("not found") || raw.contains("deleted") || raw.contains("404") ->
                "This item may have been changed or deleted elsewhere."
            raw.contains("corrupt") || raw.contains("decode") ||
                raw.contains("parse") || raw.contains("could not be read") ->
                "This saved item couldn't be read."
            raw.contains("snapshot") || (raw.contains("photo") && raw.contains("missing")) ->
                "Local saved data is missing."
            // Remaining errors are transient-style (network / server). When the
            // row is genuinely blocked, retries have stopped — say so.
            state == PendingSyncDisplayState.NeedsAttention ->
                "Automatic retries stopped after repeated failures."
            raw.contains("timeout") || raw.contains("timed out") || raw.contains("network") ||
                raw.contains("connection") || raw.contains("unable to resolve") ||
                raw.contains("unreachable") || raw.contains("host") ->
                "Connection problem. We'll try again automatically."
            Regex("\\b5\\d\\d\\b").containsMatchIn(raw) ||
                raw.contains("server error") || raw.contains("internal") ->
                "Server problem. We'll try again automatically."
            else -> "We'll try again automatically."
        }
    }

    /**
     * Replay any queued pin creates (Stage 4A-iv). Pin-create only — never any
     * other entity. Skipped when there is no session token so replay can't fire
     * during early startup and wrongly block items. Reconciles each synced pin
     * into state by client id so the optimistic copy is never duplicated.
     */
    private fun replayPendingPinCreates() {
        if (session.accessToken == null) return
        viewModelScope.launch {
            pinCreateSync.replayAll { pin ->
                _ui.update { st ->
                    if (st.pins.any { it.id == pin.id }) {
                        st.copy(pins = st.pins.map { if (it.id == pin.id) pin else it })
                    } else {
                        st.copy(pins = listOf(pin) + st.pins)
                    }
                }
            }
            // Pin creates have synced — now flush any retained pin photos whose
            // pin now exists server-side (Stage 7C). Same coroutine so photos
            // upload only after their pin rows are confirmed.
            syncPendingPinPhotos()
        }
    }

    /**
     * Replay any queued pin completion toggles (Stage 9A). Completion-only —
     * never edit/delete/photo writes. Skipped when offline or with no session
     * so it can't fire during early startup. Reconciles each synced pin into
     * state by id so the optimistic flip is replaced by the server row.
     */
    private fun replayPendingPinCompletions() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            pinCompletionSync.replayAll { pin ->
                _ui.update { st -> st.copy(pins = st.pins.map { if (it.id == pin.id) pin else it }) }
            }
        }
    }

    /**
     * Replay any queued descriptive pin edits (Stage 9B-3). Descriptive-only —
     * never completion/delete/photo/paddock/row writes. Skipped when offline or
     * with no session so it can't fire during early startup. Each replay
     * stale-guards against newer server data and, on success, reconciles the
     * returned server row into state by id so the optimistic edit is replaced.
     */
    private fun replayPendingPinEdits() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            pinEditSync.replayAll { pin ->
                _ui.update { st -> st.copy(pins = st.pins.map { if (it.id == pin.id) pin else it }) }
            }
        }
    }

    /**
     * Replay any queued pin soft-deletes (Tier-A Stage G-1). Soft-delete-only —
     * never create/edit/completion/photo writes, never trip delete or hard
     * delete. Skipped when offline or with no session so it can't fire during
     * early startup. [PinDeleteSync] defers each delete while same-pin
     * create/completion/edit/photo work is unresolved; on a confirmed delete the
     * pin is kept hidden in state by id.
     */
    private fun replayPendingPinDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            pinDeleteSync.replayAll { pinId ->
                _ui.update { st -> st.copy(pins = st.pins.filterNot { it.id == pinId }) }
            }
        }
    }

    /**
     * Replay any queued scalar trip-detail edits (Tier-A Stage B-1). Scalar-only
     * (metadata / pause-resume / start engine hours) — never path points,
     * coverage, tank sessions, or trip start/end/delete. Skipped when offline
     * or with no session so it can't fire during early startup. Each replay
     * stale-guards against newer server data and, on success, reconciles the
     * returned server trip into state by id (refreshing the Stage A snapshot
     * when it is the active trip) so the optimistic edit is replaced.
     */
    private fun replayPendingTripMetadata() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            tripMetadataSync.replayAll { trip ->
                _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == trip.id) trip else it }) }
                persistActiveTripSnapshot()
            }
        }
    }

    /**
     * Replay any queued trip seeding-details edits (Android Stage S). Writes only
     * the `seeding_details` JSONB column for an existing active server trip;
     * stale-guarded and dependency-gated on an unresolved same-trip TRIP_START so
     * it never writes to a not-yet-created server row. Skipped when offline or
     * with no session. On success the returned server trip replaces the local one.
     */
    private fun replayPendingTripSeeding() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            tripSeedingSync.replayAll { trip ->
                _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == trip.id) trip else it }) }
                persistActiveTripSnapshot()
            }
        }
    }

    /**
     * Replay any queued trip-START create markers (Tier-A Stage B-3-1).
     * Start-only — creates the server trip row for a NEW trip begun offline,
     * reusing the client-generated id (an idempotency probe avoids a duplicate
     * insert when a prior create landed but its response was lost); never
     * metadata, GPS/path, coverage, tank, end or delete. Skipped when offline or
     * with no session so it can't fire during early startup. Runs FIRST — before
     * the dependent metadata/GPS/row/tank/end replays — so the server row exists
     * before they write to it. On success the returned/existing server trip is
     * reconciled into state by id, preserving a longer live in-memory path, and
     * the Stage A snapshot is refreshed.
     */
    private fun replayPendingTripStart() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            tripStartSync.replayAll { trip ->
                _ui.update { st ->
                    st.copy(
                        trips = st.trips.map { existing ->
                            if (existing.id != trip.id) {
                                existing
                            } else {
                                val existingCount = existing.pathPoints?.size ?: 0
                                val returnedCount = trip.pathPoints?.size ?: 0
                                if (returnedCount >= existingCount) {
                                    trip
                                } else {
                                    // The freshly-created server row has no path
                                    // yet — keep the longer live in-memory track
                                    // (the TRIP_GPS marker will land it next).
                                    trip.copy(
                                        pathPoints = existing.pathPoints,
                                        totalDistance = existing.totalDistance,
                                    )
                                }
                            }
                        },
                    )
                }
                persistActiveTripSnapshot()
            }
        }
    }

    /**
     * Replay any queued GPS/path progress markers (Tier-A Stage C-1). GPS-only —
     * merges the Stage A snapshot path against the live server path before a
     * guarded progress PATCH; never trip start/end, metadata, coverage, tank
     * sessions, or delete. Skipped when offline or with no session so it can't
     * fire during early startup. On success the returned server trip is
     * reconciled into state by id, but a live-growing in-memory path is never
     * truncated (keep the longer of in-memory vs returned), and the Stage A
     * snapshot is refreshed.
     */
    private fun replayPendingTripGps() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            tripGpsSync.replayAll { trip ->
                _ui.update { st ->
                    st.copy(
                        trips = st.trips.map { existing ->
                            if (existing.id != trip.id) {
                                existing
                            } else {
                                val existingCount = existing.pathPoints?.size ?: 0
                                val returnedCount = trip.pathPoints?.size ?: 0
                                if (returnedCount >= existingCount) {
                                    trip
                                } else {
                                    // Don't let a replay reconcile shrink a path the
                                    // live tracker has grown past since the PATCH.
                                    trip.copy(
                                        pathPoints = existing.pathPoints,
                                        totalDistance = existing.totalDistance,
                                    )
                                }
                            }
                        },
                    )
                }
                persistActiveTripSnapshot()
            }
        }
    }

    /**
     * Replay any queued row-coverage markers (Tier-A Stage D-1). Coverage-only —
     * union-merges the Stage A snapshot coverage against the live server
     * coverage before a guarded coverage PATCH; never trip start/end, metadata,
     * GPS/path, tank sessions, or delete. Skipped when offline or with no
     * session so it can't fire during early startup. On success the returned
     * server trip is reconciled into state by id, but a live-growing in-memory
     * path is never truncated (keep the longer of in-memory vs returned), and
     * the Stage A snapshot is refreshed.
     */
    private fun replayPendingTripRow() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            tripRowSync.replayAll { trip ->
                _ui.update { st ->
                    st.copy(
                        trips = st.trips.map { existing ->
                            if (existing.id != trip.id) {
                                existing
                            } else {
                                val existingCount = existing.pathPoints?.size ?: 0
                                val returnedCount = trip.pathPoints?.size ?: 0
                                if (returnedCount >= existingCount) {
                                    trip
                                } else {
                                    // The coverage PATCH returns the server's path,
                                    // which can lag the live tracker — keep the
                                    // longer in-memory path/distance.
                                    trip.copy(
                                        pathPoints = existing.pathPoints,
                                        totalDistance = existing.totalDistance,
                                    )
                                }
                            }
                        },
                    )
                }
                persistActiveTripSnapshot()
            }
        }
    }

    /**
     * Replay any queued tank/fill markers (Tier-A Stage E-1). Tank-only —
     * union-merges the Stage A snapshot tank sessions (by id) against the live
     * server tank state and reconciles live tank scalars conservatively before a
     * guarded tank PATCH; never trip start/end, metadata, GPS/path, row
     * coverage, engine hours, or delete. Skipped when offline or with no session
     * so it can't fire during early startup. On success the returned server trip
     * is reconciled into state by id, but a live-growing in-memory path is never
     * truncated (keep the longer of in-memory vs returned), and the Stage A
     * snapshot is refreshed.
     */
    private fun replayPendingTripTank() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            tripTankSync.replayAll { trip ->
                _ui.update { st ->
                    st.copy(
                        trips = st.trips.map { existing ->
                            if (existing.id != trip.id) {
                                existing
                            } else {
                                val existingCount = existing.pathPoints?.size ?: 0
                                val returnedCount = trip.pathPoints?.size ?: 0
                                if (returnedCount >= existingCount) {
                                    trip
                                } else {
                                    // The tank PATCH returns the server's path,
                                    // which can lag the live tracker — keep the
                                    // longer in-memory path/distance.
                                    trip.copy(
                                        pathPoints = existing.pathPoints,
                                        totalDistance = existing.totalDistance,
                                    )
                                }
                            }
                        },
                    )
                }
                persistActiveTripSnapshot()
            }
        }
    }

    /**
     * Replay any queued trip-END markers (Tier-A Stage B-2-1). End-only —
     * dependency-gated inside [TripEndSync] so it never finalises while a
     * same-trip GPS / row / tank / metadata marker is still unresolved, then
     * derives the final path/distance from the live server trip before a guarded
     * endTrip PATCH; never trip start, delete, fuel logs, or any field owned by
     * the other markers. Skipped when offline or with no session so it can't
     * fire during early startup. On success the returned (now-ended) server trip
     * is reconciled into state by id, the locally-ended flag is cleared, and the
     * Stage A snapshot is dropped (the trip is finished server-side). Fired after
     * the dependency replays so any same-trip GPS/row/tank/metadata work has a
     * chance to land first in the same pass.
     */
    private fun replayPendingTripEnd() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            tripEndSync.replayAll { trip ->
                _ui.update { st ->
                    st.copy(
                        trips = st.trips.map { if (it.id == trip.id) trip else it },
                        locallyEndedTripIds = st.locallyEndedTripIds - trip.id,
                    )
                }
                // The trip is now inactive server-side, so this clears the
                // durable Stage A snapshot it was preserving for the end replay.
                persistActiveTripSnapshot()
            }
        }
    }

    /**
     * Replay any queued trip soft-deletes (Tier-A Stage G-2). Soft-delete-only,
     * ended/inactive trips — never the active trip, never a locally-started
     * unsynced trip, never hard delete. Skipped when offline or with no session
     * so it can't fire during early startup. [TripDeleteSync] defers each delete
     * while same-trip start/metadata/GPS/row/tank/end work is unresolved; on a
     * confirmed delete the trip is kept hidden in state by id. Runs AFTER the
     * trip-end replay so an ended-trip delete never lands before its own trip
     * markers.
     */
    private fun replayPendingTripDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            tripDeleteSync.replayAll { tripId ->
                _ui.update { st -> st.copy(trips = st.trips.filterNot { it.id == tripId }) }
            }
        }
    }

    /**
     * Replay any queued fuel-log creates (Tier-A Stage H-1). Fuel-create only —
     * never fuel update/delete (both online-only in H-1) or any other entity.
     * Skipped when offline or with no session so it can't fire during early
     * startup. Reconciles each synced fuel log into state by id so the
     * optimistic row is replaced (and never duplicated) by the server row.
     */
    private fun replayPendingFuelCreates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            fuelCreateSync.replayAll { log ->
                _ui.update { st ->
                    if (st.fuelLogs.any { it.id == log.id }) {
                        st.copy(fuelLogs = st.fuelLogs.map { if (it.id == log.id) log else it })
                    } else {
                        st.copy(fuelLogs = listOf(log) + st.fuelLogs)
                    }
                }
            }
        }
    }

    /**
     * Replay any queued fuel-log edits (Tier-A Stage H-2). Fuel-update only —
     * never fuel create (owned by [replayPendingFuelCreates], must land first so
     * the server row exists) or any other entity. The coordinator defers an
     * update while a same-log create is still unresolved, so this is safe to run
     * right after the create pass. Reconciles each synced row into state by id.
     */
    private fun replayPendingFuelUpdates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            fuelUpdateSync.replayAll { log ->
                _ui.update { st ->
                    if (st.fuelLogs.any { it.id == log.id }) {
                        st.copy(fuelLogs = st.fuelLogs.map { if (it.id == log.id) log else it })
                    } else {
                        st.copy(fuelLogs = listOf(log) + st.fuelLogs)
                    }
                }
            }
        }
    }

    /**
     * Replay retained pin photos (Stage 7C). Pin-photo-only — uploads the local
     * JPEG and associates it with the pin once the pin exists server-side, then
     * reconciles the synced `photoPath` into state. Skipped when offline or with
     * no session so it can't fire during early startup.
     */
    private fun replayPendingPinPhotos() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch { syncPendingPinPhotos() }
    }

    /**
     * Replay any queued spray-record creates (Android Stage I-1). Spray-create
     * only — never spray update/delete (still online-only) or any other entity.
     * Each synced row is reconciled into state by id (replacing the optimistic
     * row, or prepending if it's no longer present). Placed after the fuel-log
     * passes and before pin photos in every replay pipeline. Skipped when offline
     * or with no session so it can't fire during early startup.
     */
    private fun replayPendingSprayCreates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            sprayCreateSync.replayAll { record ->
                _ui.update { st ->
                    if (st.sprayRecords.any { it.id == record.id }) {
                        st.copy(sprayRecords = st.sprayRecords.map { if (it.id == record.id) record else it })
                    } else {
                        st.copy(sprayRecords = listOf(record) + st.sprayRecords)
                    }
                }
            }
        }
    }

    /**
     * Replay any queued spray-record edits (Android Stage I-2). Spray-update
     * only — never spray create (owned by [replayPendingSprayCreates], which must
     * land/resolve first) or delete (still online-only) or any other entity. The
     * coordinator defers an update while a same-record create is still
     * unresolved, so this is safe to run right after the create pass. Each synced
     * row is reconciled into state by id. Placed immediately after the spray
     * creates and before pin photos in every replay pipeline. Skipped when
     * offline or with no session so it can't fire during early startup.
     */
    private fun replayPendingSprayUpdates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            sprayUpdateSync.replayAll { record ->
                _ui.update { st ->
                    if (st.sprayRecords.any { it.id == record.id }) {
                        st.copy(sprayRecords = st.sprayRecords.map { if (it.id == record.id) record else it })
                    } else {
                        st.copy(sprayRecords = listOf(record) + st.sprayRecords)
                    }
                }
            }
        }
    }

    /**
     * Replay any queued fuel-log deletes (Tier-A Stage H-3). Fuel-delete only —
     * never fuel create/update (owned by [replayPendingFuelCreates] /
     * [replayPendingFuelUpdates], which must land/resolve first) or any other
     * entity. The coordinator defers a delete while a same-log create/update is
     * still unresolved, so this is safe to run right after the update pass.
     * Keeps the log hidden on success.
     */
    private fun replayPendingFuelDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            fuelDeleteSync.replayAll { fuelLogId ->
                _ui.update { st -> st.copy(fuelLogs = st.fuelLogs.filterNot { it.id == fuelLogId }) }
            }
        }
    }

    /**
     * Replay any queued spray-record deletes (Android Stage I-3). Spray-delete
     * only — never spray create/update (owned by [replayPendingSprayCreates] /
     * [replayPendingSprayUpdates], which must land/resolve first) or any other
     * entity. The coordinator defers a delete while a same-record create/update is
     * still unresolved, so this is safe to run right after the update pass. Keeps
     * the record hidden on success. Placed immediately after the spray updates and
     * before pin photos in every replay pipeline. Skipped when offline or with no
     * session so it can't fire during early startup.
     */
    private fun replayPendingSprayDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            sprayDeleteSync.replayAll { sprayRecordId ->
                _ui.update { st -> st.copy(sprayRecords = st.sprayRecords.filterNot { it.id == sprayRecordId }) }
            }
        }
    }

    /**
     * Replay any queued work-task header creates (Android Stage J-1). Work-task
     * create only — never work-task update/finalize/delete (still online-only) or
     * any labour/machine line (parked) or any other entity. Each synced row is
     * reconciled into state by id (replacing the optimistic row, or prepending if
     * it's no longer present). Placed after the spray passes and before pin photos
     * in every replay pipeline. Skipped when offline or with no session so it
     * can't fire during early startup.
     */
    private fun replayPendingWorkTaskCreates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            workTaskCreateSync.replayAll { task ->
                _ui.update { st ->
                    if (st.workTasks.any { it.id == task.id }) {
                        st.copy(workTasks = st.workTasks.map { if (it.id == task.id) task else it })
                    } else {
                        st.copy(workTasks = listOf(task) + st.workTasks)
                    }
                }
            }
        }
    }

    /**
     * Replay queued work-task header edits (Android Stage J-2). WORK_TASK /
     * UPDATE only — never work-task create (owned by
     * [replayPendingWorkTaskCreates], which must land/resolve first), never
     * work-task delete (online-only) and never any labour/machine line (parked).
     * Each synced row is reconciled into state by id. Placed immediately after
     * the work-task creates and before pin photos in every replay pipeline.
     * Skipped when offline or with no session so it can't fire during early
     * startup.
     */
    private fun replayPendingWorkTaskUpdates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            workTaskUpdateSync.replayAll { task ->
                _ui.update { st ->
                    st.copy(workTasks = st.workTasks.map { if (it.id == task.id) task else it })
                }
            }
        }
    }

    /**
     * Replay queued work-task LABOUR lines (Android Stage J-4). WORK_TASK_LABOUR
     * create/update/delete only — never the work-task header (owned by the
     * header create/update/delete passes) and never any machine line (parked).
     * The coordinator processes creates, then updates, then deletes, and defers
     * every write while the parent task's create is still unresolved — so this is
     * safe to run right after the header create/update passes and before the
     * header delete pass. Each upsert reconciles the open task's line list by id
     * (DB totals) and each delete keeps the line hidden, both only when the
     * matching task is still open in detail. Skipped when offline or with no
     * session so it can't fire during early startup.
     */
    private fun replayPendingWorkTaskLabour() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            workTaskLabourSync.replayAll(
                onUpserted = { line ->
                    _ui.update { st ->
                        if (st.taskLinesTaskId != line.workTaskId) return@update st
                        val others = st.taskLabourLines.filterNot { it.id == line.id }
                        st.copy(taskLabourLines = others + line)
                    }
                },
                onDeleted = { lineId, workTaskId ->
                    _ui.update { st ->
                        if (st.taskLinesTaskId != workTaskId) return@update st
                        st.copy(taskLabourLines = st.taskLabourLines.filterNot { it.id == lineId })
                    }
                },
            )
        }
    }

    /**
     * Replay queued work-task MACHINE lines (Android Stage J-5). WORK_TASK_MACHINE
     * create/update/delete only — never the work-task header (owned by the
     * header create/update/delete passes) and never any labour line (owned by
     * [replayPendingWorkTaskLabour]). The coordinator processes creates, then
     * updates, then deletes, and defers every write while the parent task's
     * create is still unresolved — so this is safe to run right after the header
     * create/update passes and the labour pass, and before the header delete
     * pass. Each upsert reconciles the open task's machine-line list by id (DB
     * totals) and each delete keeps the line hidden, both only when the matching
     * task is still open in detail. Skipped when offline or with no session so it
     * can't fire during early startup.
     */
    private fun replayPendingWorkTaskMachine() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            workTaskMachineSync.replayAll(
                onUpserted = { line ->
                    _ui.update { st ->
                        if (st.taskLinesTaskId != line.workTaskId) return@update st
                        val others = st.taskMachineLines.filterNot { it.id == line.id }
                        st.copy(taskMachineLines = others + line)
                    }
                },
                onDeleted = { lineId, workTaskId ->
                    _ui.update { st ->
                        if (st.taskLinesTaskId != workTaskId) return@update st
                        st.copy(taskMachineLines = st.taskMachineLines.filterNot { it.id == lineId })
                    }
                },
            )
        }
    }

    /**
     * Replay queued work-task -> paddock join rows (Android Stage R).
     * WORK_TASK_PADDOCK create/delete only — never the work-task header (owned by
     * the header create/update/delete passes) and never any labour/machine line
     * (owned by [replayPendingWorkTaskLabour]/[replayPendingWorkTaskMachine]).
     * The coordinator processes creates then deletes and defers every write while
     * the parent task's create is still unresolved — so this is safe to run right
     * after the header create/update passes and the line passes, and before the
     * header delete pass. Each create/delete reconciles [AppUiState.workTaskPaddocks]
     * by id. Skipped when offline or with no session so it can't fire during early
     * startup.
     */
    private fun replayPendingWorkTaskPaddocks() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            workTaskPaddockSync.replayAll(
                onCreated = { row ->
                    _ui.update { st ->
                        val others = st.workTaskPaddocks.filterNot { it.id == row.id }
                        st.copy(workTaskPaddocks = others + row)
                    }
                },
                onDeleted = { joinId, _ ->
                    _ui.update { st ->
                        st.copy(workTaskPaddocks = st.workTaskPaddocks.filterNot { it.id == joinId })
                    }
                },
            )
        }
    }

    /**
     * Replay queued work-task soft-deletes (Android Stage J-3). WORK_TASK /
     * DELETE only — never work-task create (owned by
     * [replayPendingWorkTaskCreates]) or edit (owned by
     * [replayPendingWorkTaskUpdates]), and never any labour/machine line
     * (parked). The coordinator defers while a same-task create/update is still
     * unresolved, so this is safe to run right after the update pass. Keeps the
     * task hidden on success. Placed immediately after the work-task updates and
     * before pin photos in every replay pipeline. Skipped when offline or with no
     * session so it can't fire during early startup.
     */
    private fun replayPendingWorkTaskDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            workTaskDeleteSync.replayAll { workTaskId ->
                _ui.update { st -> st.copy(workTasks = st.workTasks.filterNot { it.id == workTaskId }) }
            }
        }
    }

    /**
     * Replay any queued maintenance-log creates (Android Stage K-1).
     * MAINTENANCE_LOG / CREATE only — never maintenance edit/delete (still
     * online-only) or any other entity. Each synced row is reconciled into state
     * by id (replacing the optimistic row, or prepending if it's no longer
     * present). Placed after the work-task group and before pin photos in every
     * replay pipeline. Skipped when offline or with no session so it can't fire
     * during early startup.
     */
    private fun replayPendingMaintenanceCreates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            maintenanceCreateSync.replayAll { log ->
                _ui.update { st ->
                    if (st.maintenanceLogs.any { it.id == log.id }) {
                        st.copy(maintenanceLogs = st.maintenanceLogs.map { if (it.id == log.id) log else it })
                    } else {
                        st.copy(maintenanceLogs = listOf(log) + st.maintenanceLogs)
                    }
                }
            }
        }
    }

    /**
     * Replay any queued maintenance-log updates (Android Stage K-2).
     * MAINTENANCE_LOG / UPDATE only — never maintenance create/delete or any
     * other entity. Each synced row is reconciled into state by id. The
     * coordinator's safety-net dependency gate defers a stray UPDATE behind an
     * unresolved same-log create (no attempt consumed). Placed immediately after
     * maintenance creates and before pin photos in every replay pipeline.
     * Skipped when offline or with no session.
     */
    private fun replayPendingMaintenanceUpdates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            maintenanceUpdateSync.replayAll { log ->
                _ui.update { st ->
                    st.copy(maintenanceLogs = st.maintenanceLogs.map { if (it.id == log.id) log else it })
                }
            }
        }
    }

    /**
     * Replay any queued maintenance-log deletes (Android Stage K-3).
     * MAINTENANCE_LOG / DELETE only — never maintenance create/update or any
     * other entity. Each successfully soft-deleted log is kept hidden by id (a
     * no-op when it was already removed optimistically). The coordinator's
     * dependency gate defers a delete behind an unresolved same-log create/update
     * (no attempt consumed). Placed immediately after maintenance updates and
     * before pin photos in every replay pipeline. Skipped when offline or with no
     * session.
     */
    private fun replayPendingMaintenanceDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            maintenanceDeleteSync.replayAll { logId ->
                _ui.update { st -> st.copy(maintenanceLogs = st.maintenanceLogs.filterNot { it.id == logId }) }
            }
        }
    }

    /**
     * Replay any queued yield-record creates (Android Stage L-1). YIELD_RECORD /
     * CREATE only — never yield update/delete or any other entity. Each synced
     * row is reconciled into state by id (replace if present, else prepend).
     * Placed immediately after maintenance deletes and before pin photos in
     * every replay pipeline. Skipped when offline or with no session.
     */
    private fun replayPendingYieldCreates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            yieldCreateSync.replayAll { record ->
                _ui.update { st ->
                    if (st.yieldRecords.any { it.id == record.id }) {
                        st.copy(yieldRecords = st.yieldRecords.map { if (it.id == record.id) record else it })
                    } else {
                        st.copy(yieldRecords = listOf(record) + st.yieldRecords)
                    }
                }
            }
        }
    }

    /**
     * Replay any queued yield-record updates (Android Stage L-2). YIELD_RECORD /
     * UPDATE only — never yield create/delete or any other entity. Each synced
     * row is reconciled into state by id. The coordinator's safety-net dependency
     * gate defers a stray UPDATE behind an unresolved same-record create (no
     * attempt consumed). Placed immediately after yield creates and before pin
     * photos in every replay pipeline. Skipped when offline or with no session.
     */
    private fun replayPendingYieldUpdates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            yieldUpdateSync.replayAll { record ->
                _ui.update { st ->
                    st.copy(yieldRecords = st.yieldRecords.map { if (it.id == record.id) record else it })
                }
            }
        }
    }

    /**
     * Replay any queued yield-record deletes (Android Stage L-3). YIELD_RECORD /
     * DELETE only — never yield create/update or any other entity. Each
     * successfully soft-deleted record is kept hidden by id (a no-op when it was
     * already removed optimistically). The coordinator's dependency gate defers a
     * delete behind an unresolved same-record create/update (no attempt
     * consumed). Placed immediately after yield updates and before pin photos in
     * every replay pipeline. Skipped when offline or with no session.
     */
    private fun replayPendingYieldDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            yieldDeleteSync.replayAll { recordId ->
                _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.filterNot { it.id == recordId }) }
            }
        }
    }

    /**
     * Replay any queued growth-stage record creates (Android Stage N-1).
     * GROWTH_RECORD / CREATE only — never growth update/delete, growth photos, or
     * any other entity. Each synced row is reconciled into state by id (replace
     * if present, else prepend). Placed immediately after yield deletes and
     * before pin photos in every replay pipeline. Skipped when offline or with no
     * session.
     */
    private fun replayPendingGrowthCreates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            growthCreateSync.replayAll { record ->
                _ui.update { st ->
                    if (st.growthRecords.any { it.id == record.id }) {
                        st.copy(growthRecords = st.growthRecords.map { if (it.id == record.id) record else it })
                    } else {
                        st.copy(growthRecords = listOf(record) + st.growthRecords)
                    }
                }
            }
        }
    }

    /**
     * Replay any queued growth-stage record updates (Android Stage N-2).
     * GROWTH_RECORD / UPDATE only — never growth create/delete, growth photos, or
     * any other entity. Each synced row is reconciled into state by id. The
     * coordinator's safety-net dependency gate defers a stray UPDATE behind an
     * unresolved same-record create (no attempt consumed). Placed immediately
     * after growth creates and before pin photos in every replay pipeline.
     * Skipped when offline or with no session.
     */
    private fun replayPendingGrowthUpdates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            growthUpdateSync.replayAll { record ->
                _ui.update { st ->
                    st.copy(growthRecords = st.growthRecords.map { if (it.id == record.id) record else it })
                }
            }
        }
    }

    /**
     * Replay any queued growth-stage record soft-deletes (Android Stage N-3).
     * GROWTH_RECORD / DELETE only — never growth create/update, growth photos, or
     * any other entity. Each successful delete keeps the row hidden (it's already
     * removed optimistically). The coordinator's safety-net dependency gate defers
     * a delete behind an unresolved same-record create/update (no attempt
     * consumed). Placed immediately after growth updates and before pin photos in
     * every replay pipeline. Skipped when offline or with no session.
     */
    private fun replayPendingGrowthDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            growthDeleteSync.replayAll { recordId ->
                _ui.update { st ->
                    st.copy(growthRecords = st.growthRecords.filterNot { it.id == recordId })
                }
            }
        }
    }

    /**
     * Replay any queued block-damage record creates (Android Stage M-1).
     * DAMAGE_RECORD / CREATE only — never damage update/delete or any other
     * entity. Each synced row is reconciled into state by id (replacing the
     * optimistic row, or prepending if it was dropped). Skipped when offline or
     * with no session.
     */
    private fun replayPendingDamageCreates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            damageCreateSync.replayAll { record ->
                _ui.update { st ->
                    if (st.damageRecords.any { it.id == record.id }) {
                        st.copy(damageRecords = st.damageRecords.map { if (it.id == record.id) record else it })
                    } else {
                        st.copy(damageRecords = listOf(record) + st.damageRecords)
                    }
                }
            }
        }
    }

    /**
     * Replay any queued block-damage record updates (Android Stage M-2).
     * DAMAGE_RECORD / UPDATE only — never damage create/delete or any other
     * entity. Each synced row is reconciled into state by id. The coordinator's
     * safety-net dependency gate defers a stray UPDATE behind an unresolved
     * same-record create (no attempt consumed). Skipped when offline or with no
     * session.
     */
    private fun replayPendingDamageUpdates() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            damageUpdateSync.replayAll { record ->
                _ui.update { st ->
                    st.copy(damageRecords = st.damageRecords.map { if (it.id == record.id) record else it })
                }
            }
        }
    }

    /**
     * Replay any queued block-damage record soft-deletes (Android Stage M-3).
     * DAMAGE_RECORD / DELETE only — never damage create/update or any other
     * entity. Each successful delete keeps the row hidden (it's already removed
     * optimistically). The coordinator's safety-net dependency gate defers a
     * delete behind an unresolved same-record create/update (no attempt
     * consumed). Skipped when offline or with no session.
     */
    private fun replayPendingDamageDeletes() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            damageDeleteSync.replayAll { recordId ->
                _ui.update { st ->
                    st.copy(damageRecords = st.damageRecords.filterNot { it.id == recordId })
                }
            }
        }
    }

    /**
     * Replay any queued launcher button-config updates (Android Stage N).
     * BUTTON_CONFIG / UPDATE only — never any other entity. Each synced layout is
     * reflected into the matching repair/growth button list by config type.
     * Skipped when offline or with no session.
     */
    private fun replayPendingButtonConfig() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            buttonConfigUpdateSync.replayAll { payload ->
                _ui.update { st ->
                    if (payload.vineyardId != st.selectedVineyardId) return@update st
                    when (payload.configType) {
                        "growth_buttons" -> st.copy(growthButtons = payload.buttons.sortedBy { it.index })
                        else -> st.copy(repairButtons = payload.buttons.sortedBy { it.index })
                    }
                }
            }
        }
    }

    /**
     * Replay any queued yield-estimation session saves then deletes (Android
     * Stage Q). YIELD_SESSION / UPDATE then DELETE only — never any other entity.
     * The save pass runs first so a session row exists before a delete targets
     * it; the delete pass cancels any same-session save. Synced rows are
     * reconciled into [AppUiState.yieldSessions] by id for the selected vineyard.
     * Skipped when offline or with no session.
     */
    private fun replayPendingYieldSessions() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        viewModelScope.launch {
            yieldSessionSaveSync.replayAll { saved ->
                _ui.update { st ->
                    if (saved.vineyardId != st.selectedVineyardId) return@update st
                    if (st.yieldSessions.any { it.id == saved.id }) {
                        st.copy(yieldSessions = st.yieldSessions.map { if (it.id == saved.id) saved else it })
                    } else {
                        st.copy(yieldSessions = listOf(saved) + st.yieldSessions)
                    }
                }
            }
            yieldSessionDeleteSync.replayAll { sessionId ->
                _ui.update { st ->
                    st.copy(yieldSessions = st.yieldSessions.filterNot { it.id == sessionId })
                }
            }
        }
    }

    private suspend fun syncPendingPinPhotos() {
        if (session.accessToken == null || !_ui.value.isOnline) return
        pinPhotoSync.replayAll { pinId, path ->
            _ui.update { st ->
                st.copy(pins = st.pins.map { if (it.id == pinId) it.copy(photoPath = path) else it })
            }
        }
    }

    /**
     * Explicit user-triggered "Retry all" from the Sync Status screen (Tier-A
     * Stage F-2). Conservative and non-destructive: it resets every
     * retry-eligible FAILED row back to PENDING (BLOCKED rows untouched, attempt
     * counts preserved, nothing removed) and then re-runs the SAME ordered
     * replay pipeline used on reconnect/post-load. It performs no direct server
     * write itself and never bypasses a coordinator's dependency gate or attempt
     * cap — the required order is preserved (trip start first, then
     * metadata/GPS/row/tank/end, then the pin create/completion/edit/photo
     * replays), so an offline start → work → end chain stays safe.
     *
     * No-op when offline or without a session (replay can't run), or when
     * nothing is eligible. The transient [AppUiState.isRetryingSync] flag guards
     * against double-taps; the pending list updates reactively as rows resolve.
     */
    fun retryPendingSync() {
        if (_ui.value.isRetryingSync) return
        if (!_ui.value.isOnline || session.accessToken == null) return
        val reset = pendingWrites.resetFailedForRetry()
        if (reset == 0) return
        _ui.update { it.copy(isRetryingSync = true) }
        // Same safe order as reconnect/post-load. Each replay launches its own
        // mutex-guarded coroutine; per-coordinator dependency gates keep the
        // ordering correct even though these are scheduled fire-and-forget.
        replayPendingPinCreates()
        replayPendingPinCompletions()
        replayPendingPinEdits()
        replayPendingPinDeletes()
        replayPendingTripStart()
        replayPendingTripMetadata()
        replayPendingTripSeeding()
        replayPendingTripGps()
        replayPendingTripRow()
        replayPendingTripTank()
        replayPendingTripEnd()
        replayPendingTripDeletes()
        replayPendingFuelCreates()
        replayPendingFuelUpdates()
        replayPendingFuelDeletes()
        replayPendingSprayCreates()
        replayPendingSprayUpdates()
        replayPendingSprayDeletes()
        replayPendingWorkTaskCreates()
        replayPendingWorkTaskUpdates()
        replayPendingWorkTaskLabour()
        replayPendingWorkTaskMachine()
        replayPendingWorkTaskPaddocks()
        replayPendingWorkTaskDeletes()
        replayPendingMaintenanceCreates()
        replayPendingMaintenanceUpdates()
        replayPendingMaintenanceDeletes()
        replayPendingYieldCreates()
        replayPendingYieldUpdates()
        replayPendingYieldDeletes()
        replayPendingGrowthCreates()
        replayPendingGrowthUpdates()
        replayPendingGrowthDeletes()
        replayPendingDamageCreates()
        replayPendingDamageUpdates()
        replayPendingDamageDeletes()
        replayPendingButtonConfig()
        replayPendingYieldSessions()
        replayPendingPinPhotos()
        // Clear the transient hint on the next loop tick; resolution is shown
        // reactively through the pending list, not this flag.
        viewModelScope.launch { _ui.update { it.copy(isRetryingSync = false) } }
    }

    /**
     * Explicit per-item retry of a single retry-eligible row (Tier-A Stage
     * F-2b). Resets only the named FAILED row back to PENDING, then re-runs the
     * SAME full ordered replay pipeline used by [retryPendingSync] — it never
     * calls a single coordinator in isolation, so every dependency gate and
     * attempt cap stays in force (an offline start → work → end chain remains
     * safe). Conservative and non-destructive: attempt counts are preserved and
     * no row is removed.
     *
     * No-op when offline / without a session (replay can't run), while another
     * retry is in flight, or when the row is no longer FAILED (e.g. it already
     * resolved or became BLOCKED). Returns true when a retry was actually
     * started so the screen can show the right confirmation/hint.
     */
    fun retryPendingSyncItem(id: String): Boolean {
        if (_ui.value.isRetryingSync) return false
        if (!_ui.value.isOnline || session.accessToken == null) return false
        val reset = pendingWrites.resetFailedRowForRetry(id)
        if (!reset) return false
        _ui.update { it.copy(isRetryingSync = true) }
        // Identical safe order to "Retry all" / reconnect / post-load. Resetting
        // one row then replaying the whole pipeline keeps dependants correctly
        // ordered (a single coordinator in isolation could bypass a gate).
        replayPendingPinCreates()
        replayPendingPinCompletions()
        replayPendingPinEdits()
        replayPendingPinDeletes()
        replayPendingTripStart()
        replayPendingTripMetadata()
        replayPendingTripSeeding()
        replayPendingTripGps()
        replayPendingTripRow()
        replayPendingTripTank()
        replayPendingTripEnd()
        replayPendingTripDeletes()
        replayPendingFuelCreates()
        replayPendingFuelUpdates()
        replayPendingFuelDeletes()
        replayPendingSprayCreates()
        replayPendingSprayUpdates()
        replayPendingSprayDeletes()
        replayPendingWorkTaskCreates()
        replayPendingWorkTaskUpdates()
        replayPendingWorkTaskLabour()
        replayPendingWorkTaskMachine()
        replayPendingWorkTaskPaddocks()
        replayPendingWorkTaskDeletes()
        replayPendingMaintenanceCreates()
        replayPendingMaintenanceUpdates()
        replayPendingMaintenanceDeletes()
        replayPendingYieldCreates()
        replayPendingYieldUpdates()
        replayPendingYieldDeletes()
        replayPendingGrowthCreates()
        replayPendingGrowthUpdates()
        replayPendingGrowthDeletes()
        replayPendingDamageCreates()
        replayPendingDamageUpdates()
        replayPendingDamageDeletes()
        replayPendingButtonConfig()
        replayPendingYieldSessions()
        replayPendingPinPhotos()
        viewModelScope.launch { _ui.update { it.copy(isRetryingSync = false) } }
        return true
    }

    /**
     * Mirror device connectivity into [AppUiState.isOnline]. Read-only: this
     * never triggers loads, retries, or write replays — it only powers the
     * offline banner and Sync Status surface.
     */
    private fun observeConnectivity() {
        viewModelScope.launch {
            connectivity.observe().collect { online ->
                _ui.update { it.copy(isOnline = online) }
                // Reconnected (or first known status is online): flush any queued
                // pin creates, then queued completion toggles. No-op when the
                // outbox is empty or no session yet.
                if (online) {
                    replayPendingPinCreates()
                    replayPendingPinCompletions()
                    replayPendingPinEdits()
                    replayPendingPinDeletes()
                    // TRIP_START first: the server row must exist before any
                    // dependent same-trip marker can write to it.
                    replayPendingTripStart()
                    replayPendingTripMetadata()
                    replayPendingTripSeeding()
                    replayPendingTripGps()
                    replayPendingTripRow()
                    replayPendingTripTank()
                    replayPendingTripEnd()
                    replayPendingTripDeletes()
                    replayPendingFuelCreates()
                    replayPendingFuelUpdates()
                    replayPendingFuelDeletes()
                    replayPendingSprayCreates()
                    replayPendingSprayUpdates()
                    replayPendingSprayDeletes()
                    replayPendingWorkTaskCreates()
                    replayPendingWorkTaskUpdates()
                    replayPendingWorkTaskLabour()
                    replayPendingWorkTaskMachine()
                    replayPendingWorkTaskPaddocks()
                    replayPendingWorkTaskDeletes()
                    replayPendingMaintenanceCreates()
                    replayPendingMaintenanceUpdates()
                    replayPendingMaintenanceDeletes()
                    replayPendingYieldCreates()
                    replayPendingYieldUpdates()
                    replayPendingYieldDeletes()
                    replayPendingGrowthCreates()
                    replayPendingGrowthUpdates()
                    replayPendingGrowthDeletes()
                    replayPendingDamageCreates()
                    replayPendingDamageUpdates()
                    replayPendingDamageDeletes()
                    replayPendingButtonConfig()
                    replayPendingYieldSessions()
                }
            }
        }
    }

    private fun restore() {
        viewModelScope.launch {
            val user = try {
                auth.restoreSession()
            } catch (e: Exception) {
                null
            }
            if (user == null) {
                _ui.update { it.copy(route = AppRoute.Login) }
            } else if (biometricStore.isEnabled) {
                // Session restored, but the user gated this device behind a
                // biometric/device-credential unlock (parity with iOS
                // BiometricLockView). Hold here until they pass the prompt.
                _ui.update { it.copy(route = AppRoute.BiometricLock) }
            } else {
                _ui.update { it.copy(route = AppRoute.VineyardLoading) }
                loadVineyards()
            }
        }
    }

    fun signIn(email: String, password: String) {
        viewModelScope.launch {
            _auth.update { it.copy(isLoading = true, error = null) }
            try {
                auth.signIn(email, password)
                _auth.update { AuthFormState() }
                // Keep the saved biometric email in step with the active account.
                if (biometricStore.isEnabled) biometricStore.savedEmail = auth.currentEmail
                _ui.update { it.copy(route = AppRoute.VineyardLoading) }
                loadVineyards()
            } catch (e: BackendError.Server) {
                _auth.update { it.copy(isLoading = false, error = e.body.ifBlank { "Sign in failed." }) }
            } catch (e: BackendError) {
                _auth.update { it.copy(isLoading = false, error = e.message) }
            } catch (e: Exception) {
                _auth.update { it.copy(isLoading = false, error = "Couldn't reach the server. Check your connection.") }
            }
        }
    }

    fun signUp(name: String, email: String, password: String) {
        viewModelScope.launch {
            _auth.update { it.copy(isLoading = true, error = null) }
            try {
                auth.signUp(name, email, password)
                _auth.update { AuthFormState() }
                if (session.hasSession) {
                    _ui.update { it.copy(route = AppRoute.VineyardLoading) }
                    loadVineyards()
                } else {
                    _auth.update { it.copy(error = "Check your email to confirm your account, then sign in.") }
                }
            } catch (e: BackendError.Server) {
                _auth.update { it.copy(isLoading = false, error = e.body.ifBlank { "Sign up failed." }) }
            } catch (e: Exception) {
                _auth.update { it.copy(isLoading = false, error = "Couldn't reach the server. Check your connection.") }
            }
        }
    }

    fun sendPasswordReset(email: String, onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            val ok = try { auth.sendPasswordReset(email) } catch (e: Exception) { false }
            onResult(ok)
        }
    }

    /**
     * Complete a PIN-based password reset (request code → enter code + new
     * password). Mirrors iOS `resetPasswordWithPin`. Calls back with success and
     * an optional error message.
     */
    fun resetPasswordWithPin(
        email: String,
        pin: String,
        newPassword: String,
        onResult: (Boolean, String?) -> Unit,
    ) {
        viewModelScope.launch {
            try {
                auth.resetPasswordWithPin(email, pin, newPassword)
                onResult(true, null)
            } catch (e: BackendError.Server) {
                onResult(false, e.body.ifBlank { "That code didn't work. Check it and try again." })
            } catch (e: Exception) {
                onResult(false, e.message ?: "Couldn't reset password. Try again.")
            }
        }
    }

    fun signOut() {
        viewModelScope.launch {
            try { auth.signOut() } catch (_: Exception) {}
            // Stage 8 — defence-in-depth: clear local offline-reliability data so
            // no pending/cache state for the signed-out account lingers on the
            // device. Local-only (no server/Storage deletes, no replay); cleanup
            // failures must never block sign-out, hence the runCatching guards.
            runCatching { pendingWrites.clearAll() }
            runCatching { pendingPhotos.clearAll() }
            runCatching { domainCache.clearAll() }
            runCatching { activeTripStore.clear() }
            _ui.value = AppUiState(route = AppRoute.Login)
            _auth.value = AuthFormState()
        }
    }

    fun retryVineyardLoad() {
        viewModelScope.launch {
            _ui.update { it.copy(route = AppRoute.VineyardLoading) }
            loadVineyards()
        }
    }

    /**
     * Resolve platform System Admin status for the signed-in user (parity with
     * iOS `SystemAdminService.refresh`). Best-effort and non-fatal: a failure
     * leaves [AppUiState.isSystemAdmin] false so the Admin entry stays hidden.
     * Runs in the background so it never blocks vineyard loading.
     */
    private fun loadAdminStatus() {
        viewModelScope.launch {
            val admin = runCatching { systemAdminRepository.isSystemAdmin() }.getOrDefault(false)
            _ui.update { it.copy(isSystemAdmin = admin) }
        }
    }

    private suspend fun loadVineyards() {
        try {
            loadAdminStatus()
            val vineyards = repo.listMyVineyards()
            // Write-through: a successful online list is cached for future
            // offline launch (Stage 6A). Cache-only — never hydrated yet.
            domainCache.saveVineyards(session.userId, vineyards)
            val memberIds = vineyards.map { it.id }.toSet()
            // Resolve the per-user default vineyard from the profile (server is
            // source of truth). Fall back to the locally cached copy when the
            // profile fetch fails so an offline launch still honours it.
            var defaultId = try {
                profileRepo.getDefaultVineyardId()
            } catch (e: BackendError.Unauthorized) {
                throw e
            } catch (_: Exception) {
                session.defaultVineyardId
            }
            // Drop a stale default the user no longer has access to, clearing it
            // remotely too (best-effort), mirroring iOS.
            if (defaultId != null && defaultId !in memberIds) {
                viewModelScope.launch { runCatching { profileRepo.setDefaultVineyard(null) } }
                defaultId = null
            }
            session.defaultVineyardId = defaultId

            // Selection priority (matches iOS applyDefaultVineyardSelection):
            // 1. profile default if still a member,
            // 2. existing local selection if still valid,
            // 3. first available vineyard.
            val previous = session.selectedVineyardId
            val selected = when {
                defaultId != null && defaultId in memberIds -> defaultId
                previous != null && previous in memberIds -> previous
                else -> vineyards.firstOrNull()?.id
            }
            session.selectedVineyardId = selected
            _ui.update {
                it.copy(
                    vineyards = vineyards,
                    selectedVineyardId = selected,
                    defaultVineyardId = defaultId,
                    // Apply cached region settings instantly for the restored vineyard.
                    regionSettings = if (selected != null) regionSettingsStore.load(selected) else RegionSettings.defaults,
                    // Fresh online list — we're no longer on cached field data.
                    isUsingCachedFieldData = false,
                    cachedFieldDataLastSyncedAt = null,
                    route = if (selected == null) AppRoute.NoVineyards else AppRoute.Main,
                )
            }
            if (selected != null) loadVineyardData(selected)
            if (selected != null) refreshRegionSettings(selected)
            refreshSelectedVineyardLogo()
            refreshGrowthStageImages()
            refreshCacheStatus()
            // A session is now established and we're online enough to have
            // loaded — flush any pin creates queued during a previous offline
            // session, then any retained pin photos whose pin now exists
            // (Stage 7C). Pin-create + pin-photo only; no other write replays.
            if (_ui.value.isOnline) {
                replayPendingPinCreates()
                replayPendingPinCompletions()
                replayPendingPinEdits()
                replayPendingPinDeletes()
                // TRIP_START first: the server row must exist before any
                // dependent same-trip marker can write to it.
                replayPendingTripStart()
                replayPendingTripMetadata()
                replayPendingTripSeeding()
                replayPendingTripGps()
                replayPendingTripRow()
                replayPendingTripTank()
                replayPendingTripEnd()
                replayPendingTripDeletes()
                replayPendingFuelCreates()
                replayPendingFuelUpdates()
                replayPendingFuelDeletes()
                replayPendingSprayCreates()
                replayPendingSprayUpdates()
                replayPendingSprayDeletes()
                replayPendingWorkTaskCreates()
                replayPendingWorkTaskUpdates()
                replayPendingWorkTaskLabour()
                replayPendingWorkTaskMachine()
                replayPendingWorkTaskPaddocks()
                replayPendingWorkTaskDeletes()
                replayPendingMaintenanceCreates()
                replayPendingMaintenanceUpdates()
                replayPendingMaintenanceDeletes()
                replayPendingYieldCreates()
                replayPendingYieldUpdates()
                replayPendingYieldDeletes()
                replayPendingGrowthCreates()
                replayPendingGrowthUpdates()
                replayPendingGrowthDeletes()
                replayPendingDamageCreates()
                replayPendingDamageUpdates()
                replayPendingDamageDeletes()
                replayPendingButtonConfig()
                replayPendingYieldSessions()
            }
        } catch (e: BackendError.Unauthorized) {
            signOut()
        } catch (e: Exception) {
            // Offline / transient. A restored session is still required (this
            // catch is only reached after auth succeeded), so falling back to
            // the local read-cache never bypasses authentication.
            if (!hydrateVineyardsFromCache()) {
                _ui.update {
                    if (it.vineyards.isEmpty()) it.copy(route = AppRoute.VineyardLoadFailed)
                    else it.copy(route = AppRoute.Main)
                }
            }
        }
    }

    /**
     * Cached vineyard-list fallback for a cold offline launch (Stage 6B). Only
     * fires when no vineyards are in memory and the local cache holds an
     * owner-matched list. Picks the selected/default vineyard with the same
     * priority as the online path, routes into Main on saved data, and flags
     * cached mode. Returns false when there is no usable cache so the caller
     * keeps the existing VineyardLoadFailed behaviour.
     */
    private suspend fun hydrateVineyardsFromCache(): Boolean {
        if (_ui.value.vineyards.isNotEmpty()) return false
        val userId = session.userId
        val cached = domainCache.loadVineyards(userId)
        if (cached.isNullOrEmpty()) return false
        val memberIds = cached.map { it.id }.toSet()
        val defaultId = session.defaultVineyardId?.takeIf { it in memberIds }
        val previous = session.selectedVineyardId
        val selected = when {
            defaultId != null -> defaultId
            previous != null && previous in memberIds -> previous
            else -> cached.firstOrNull()?.id
        }
        session.selectedVineyardId = selected
        _ui.update {
            it.copy(
                vineyards = cached,
                selectedVineyardId = selected,
                defaultVineyardId = defaultId,
                currentUserId = userId,
                isUsingCachedFieldData = true,
                cachedFieldDataLastSyncedAt = domainCache.vineyardsSyncedAt(userId),
                route = if (selected == null) AppRoute.NoVineyards else AppRoute.Main,
            )
        }
        if (selected != null) loadVineyardData(selected)
        refreshCacheStatus()
        return true
    }

    /**
     * Set (or clear, with null) the user's preferred default vineyard. The
     * vineyard that opens on the next launch. Best-effort and silent on
     * failure, mirroring iOS — the active session is unaffected either way.
     */
    fun setDefaultVineyard(vineyardId: String?) {
        val target = if (vineyardId == _ui.value.defaultVineyardId) null else vineyardId
        viewModelScope.launch {
            val ok = runCatching { profileRepo.setDefaultVineyard(target) }.isSuccess
            if (ok) {
                session.defaultVineyardId = target
                _ui.update { it.copy(defaultVineyardId = target) }
            }
        }
    }

    fun selectVineyard(id: String) {
        session.selectedVineyardId = id
        // Clear the previous vineyard's data so the UI doesn't briefly show
        // stale blocks/pins while the new vineyard loads.
        _ui.update { it.copy(selectedVineyardId = id, selectedVineyardLogo = null, paddocks = emptyList(), pins = emptyList(), trips = emptyList(), machines = emptyList(), workTasks = emptyList(), members = emptyList(), operatorCategories = emptyList(), vineyardTripFunctions = emptyList(), sprayRecords = emptyList(), sprayEquipment = emptyList(), savedChemicals = emptyList(), savedInputs = emptyList(), savedSprayPresets = emptyList(), maintenanceLogs = emptyList(), growthRecords = emptyList(), fuelLogs = emptyList(), fuelPurchases = emptyList(), equipmentItems = emptyList(), repairButtons = emptyList(), growthButtons = emptyList(), yieldRecords = emptyList(), damageRecords = emptyList(), yieldSessions = emptyList(), workTaskPaddocks = emptyList(), growthStageImages = emptyList()) }
        loadedLogoKey = null
        // Apply the cached region settings instantly so units/currency render
        // correctly on first paint, then refresh from the backend below.
        _ui.update { it.copy(regionSettings = regionSettingsStore.load(id)) }
        refreshSelectedVineyardLogo()
        refreshGrowthStageImages()
        refreshRegionSettings(id)
        viewModelScope.launch { loadVineyardData(id) }
    }

    /**
     * Refresh the selected vineyard's region & units settings from the backend
     * (authoritative), caching the result for instant display next launch. Soft-
     * fails to the cached value so a fetch hiccup never reverts units mid-session.
     */
    private fun refreshRegionSettings(vineyardId: String) {
        viewModelScope.launch {
            val fetched = runCatching { regionSettingsRepo.get(vineyardId) }.getOrNull() ?: return@launch
            regionSettingsStore.save(vineyardId, fetched)
            if (_ui.value.selectedVineyardId == vineyardId) {
                _ui.update { it.copy(regionSettings = fetched) }
            }
        }
    }

    fun refresh() {
        val id = _ui.value.selectedVineyardId ?: return
        refreshSelectedVineyardLogo()
        refreshGrowthStageImages()
        viewModelScope.launch { loadVineyardData(id) }
    }

    /**
     * Rename a vineyard and/or change its country (owner/manager only), mirroring
     * the iOS vineyard detail sheet. Optimistically updates the in-memory list so
     * the change shows immediately, then reverts on failure.
     */
    fun updateVineyard(id: String, name: String, country: String?, onResult: (Boolean) -> Unit) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) { onResult(false); return }
        val previous = _ui.value.vineyards
        _ui.update { state ->
            state.copy(vineyards = state.vineyards.map { if (it.id == id) it.copy(name = trimmed, country = country) else it })
        }
        viewModelScope.launch {
            val ok = runCatching { repo.updateVineyard(id, trimmed, country) }.isSuccess
            if (ok) {
                runCatching { domainCache.saveVineyards(session.userId, _ui.value.vineyards) }
            } else {
                _ui.update { it.copy(vineyards = previous) }
            }
            onResult(ok)
        }
    }

    /**
     * Persist the active vineyard's coordinates, elevation and timezone via the
     * owner/manager-gated `set_vineyard_location` RPC, mirroring the iOS Vineyard
     * Location editor. Optimistically updates the in-memory vineyard so the GDD
     * tools reflect the change immediately, reverting on failure.
     */
    fun updateVineyardLocation(
        id: String,
        latitude: Double?,
        longitude: Double?,
        elevationMetres: Double?,
        onResult: (Boolean) -> Unit,
    ) {
        val previous = _ui.value.vineyards
        _ui.update { state ->
            state.copy(
                vineyards = state.vineyards.map {
                    if (it.id == id) it.copy(
                        latitude = latitude,
                        longitude = longitude,
                        elevationMetres = elevationMetres,
                    ) else it
                },
            )
        }
        viewModelScope.launch {
            val ok = runCatching {
                repo.setVineyardLocation(
                    vineyardId = id,
                    latitude = latitude,
                    longitude = longitude,
                    elevationMetres = elevationMetres,
                    timezone = null,
                )
            }.isSuccess
            if (ok) {
                runCatching { domainCache.saveVineyards(session.userId, _ui.value.vineyards) }
            } else {
                _ui.update { it.copy(vineyards = previous) }
            }
            onResult(ok)
        }
    }

    /**
     * Archive a vineyard for the whole team (owner only) via the server RPC.
     * On success removes it locally and reselects another vineyard, mirroring
     * the iOS archive flow.
     */
    fun archiveVineyard(id: String, onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            val ok = runCatching { repo.archiveVineyard(id) }.isSuccess
            if (ok) {
                val remaining = _ui.value.vineyards.filter { it.id != id }
                runCatching { domainCache.saveVineyards(session.userId, remaining) }
                _ui.update { it.copy(vineyards = remaining) }
                if (_ui.value.selectedVineyardId == id) {
                    val next = remaining.firstOrNull()?.id
                    if (next != null) selectVineyard(next)
                    else _ui.update { it.copy(selectedVineyardId = null, route = AppRoute.NoVineyards) }
                }
            }
            onResult(ok)
        }
    }

    // MARK: - Pin write path

    /**
     * Create a pin. Online (the common path) this posts straight to Supabase
     * and inserts the server-confirmed row. Offline — or when the post fails
     * with a clear network/transient error — the create is queued in the
     * pending-write outbox with a client-generated id and an optimistic local
     * pin is shown, then replayed automatically once connectivity returns
     * (Stage 4A-iv). Only pin CREATE is queue-enabled; validation/permission
     * failures are surfaced as errors and never queued.
     */
    fun createPin(
        title: String,
        mode: String,
        category: String?,
        notes: String?,
        side: String?,
        paddockId: String?,
        rowNumber: Int?,
        isCompleted: Boolean,
        latitude: Double?,
        longitude: Double?,
        photoUri: Uri? = null,
        // True only for launcher pins dropped at a real GPS fix: snap the pin to
        // the nearest mapped vine row and persist the row-attachment columns.
        attachToRow: Boolean = false,
        // Quick-pin parity: fires with the created (or queued optimistic) pin so the
        // launcher's success card and auto-photo prompt have the concrete row to
        // work with. Independent of [onResult], which still reports save success.
        onCreatedPin: (Pin) -> Unit = {},
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        // Resolve row attachment from block geometry when a GPS fix is available.
        val attachment = if (attachToRow) {
            RowAttachment.resolve(
                paddock = _ui.value.paddocks.firstOrNull { it.id == paddockId },
                latitude = latitude,
                longitude = longitude,
                side = side?.ifBlank { null },
            )
        } else {
            null
        }
        // Backfill the legacy row_number from the snapped row when the user left
        // it blank, so the existing row column stays consistent with the snap.
        val resolvedRowNumber = rowNumber ?: attachment?.pinRowNumber?.toInt()
        // Mint the client id up front so the same UUID flows through the
        // optimistic pin, the network insert, and (if queued) the outbox
        // payload — keeping replay idempotent.
        val input = PinRepository.PinInput(
            id = UUID.randomUUID().toString(),
            vineyardId = vineyardId,
            paddockId = paddockId,
            title = title.ifBlank { null },
            category = category?.ifBlank { null },
            mode = mode.ifBlank { null },
            notes = notes?.ifBlank { null },
            side = side?.ifBlank { null },
            rowNumber = resolvedRowNumber,
            pinRowNumber = attachment?.pinRowNumber,
            pinSide = attachment?.pinSide,
            alongRowDistanceM = attachment?.alongRowDistanceM,
            isCompleted = isCompleted,
            latitude = latitude,
            longitude = longitude,
            createdBy = session.userId,
        )

        // Known-offline: queue immediately without attempting the network.
        if (!_ui.value.isOnline) {
            val queued = enqueuePinCreate(input, photoUri = photoUri)
            onCreatedPin(queued)
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(pinError = null) }
            try {
                var created = pinRepo.createPin(input)
                // A new pin only has its server id after creation, so any
                // selected photo is uploaded here (mirrors iOS deferred upload).
                if (photoUri != null) {
                    val jpeg = runCatching { PinPhotoImageUtil.compress(getApplication(), photoUri) }.getOrNull()
                    try {
                        if (jpeg == null) error("Couldn't read the selected image.")
                        val path = pinPhotoRepo.upload(vineyardId, created.id, jpeg)
                        created = pinRepo.updatePhotoPath(created.id, path)
                    } catch (e: Exception) {
                        // Pin row exists but the photo upload failed — retain the
                        // compressed photo locally so it isn't lost (Stage 7B).
                        // Upload retry itself lands in a later slice.
                        if (jpeg != null) {
                            pendingPhotos.enqueue(created.id, vineyardId, jpeg)
                            _ui.update { it.copy(pinError = "Pin saved — photo saved and will retry when connection is available.") }
                            // The pin row exists, so attempt an immediate retry of
                            // the retained photo (Stage 7C). Best-effort — if it
                            // fails again it stays queued for the next trigger.
                            replayPendingPinPhotos()
                        } else {
                            _ui.update { it.copy(pinError = "Pin saved, but the photo couldn't be read. Open the pin to add it again.") }
                        }
                    }
                }
                _ui.update { it.copy(pins = listOf(created) + it.pins) }
                onCreatedPin(created)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut()
                onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / server rejection — surface, don't queue.
                _ui.update { it.copy(pinError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Clear network/transient failure — queue for automatic replay
                // rather than dropping the pin.
                val queued = enqueuePinCreate(input, photoUri = photoUri)
                onCreatedPin(queued)
                onResult(true)
            }
        }
    }

    /**
     * Queue a pin create in the outbox and show an optimistic local pin so the
     * user sees it on the map/list immediately. When a photo was attached, the
     * compressed JPEG is retained locally and keyed to the same client pin id
     * (Stage 7B) so it isn't lost; the upload itself happens in a later slice.
     */
    private fun enqueuePinCreate(input: PinRepository.PinInput, photoUri: Uri?): Pin {
        pinCreateSync.enqueue(input)
        val clientPinId = input.id ?: UUID.randomUUID().toString()
        val hasPhoto = photoUri != null
        val optimistic = Pin(
            id = clientPinId,
            vineyardId = input.vineyardId,
            paddockId = input.paddockId,
            title = input.title,
            category = input.category,
            mode = input.mode,
            notes = input.notes,
            side = input.side,
            rowNumber = input.rowNumber,
            isCompleted = input.isCompleted,
            latitude = input.latitude,
            longitude = input.longitude,
            pinRowNumber = input.pinRowNumber,
            pinSide = input.pinSide,
            alongRowDistanceM = input.alongRowDistanceM,
        )
        _ui.update { st ->
            st.copy(
                pins = listOf(optimistic) + st.pins,
                pinError = if (hasPhoto) {
                    "Pin saved offline — photo saved and will upload when sync is available."
                } else {
                    st.pinError
                },
            )
        }
        // Retain the photo locally (compress + copy to app-private storage)
        // keyed by the same client pin id. No upload in this slice.
        if (photoUri != null) persistPendingPhoto(clientPinId, input.vineyardId, photoUri)
        return optimistic
    }

    /**
     * Compress [uri] and copy it into app-private storage as a pending photo
     * attachment for [clientPinId] (Stage 7B). Best-effort: a compression
     * failure is swallowed since there's nothing to upload anyway, and the pin
     * itself is already queued. No upload/retry happens here.
     */
    private fun persistPendingPhoto(clientPinId: String, vineyardId: String, uri: Uri) {
        viewModelScope.launch {
            try {
                val jpeg = PinPhotoImageUtil.compress(getApplication(), uri)
                pendingPhotos.enqueue(clientPinId, vineyardId, jpeg)
            } catch (e: Exception) {
                // Couldn't read/compress the image — nothing retained, pin still queued.
            }
        }
    }

    /** Update an existing pin, optimistically reflecting edits then reconciling. */
    fun updatePin(
        pinId: String,
        title: String,
        mode: String,
        category: String?,
        notes: String?,
        side: String?,
        paddockId: String?,
        rowNumber: Int?,
        isCompleted: Boolean,
        onResult: (Boolean) -> Unit,
    ) {
        val previous = _ui.value.pins

        // Known-offline: queue a descriptive-only edit and optimistically reflect
        // just title/category/mode/notes. Paddock, side, row/snap, and completion
        // are deliberately left online-only and are NOT queued here (Stage 9B-3).
        if (!_ui.value.isOnline) {
            val newTitle = title.ifBlank { null }
            val newCategory = category?.ifBlank { null }
            val newMode = mode.ifBlank { null }
            val newNotes = notes?.ifBlank { null }
            val base = previous.firstOrNull { it.id == pinId }?.clientUpdatedAt
            _ui.update { st ->
                st.copy(
                    pins = st.pins.map {
                        if (it.id == pinId) {
                            it.copy(title = newTitle, category = newCategory, mode = newMode, notes = newNotes)
                        } else {
                            it
                        }
                    },
                    pinError = "Pin changes saved offline — they'll sync when connection returns.",
                )
            }
            pinEditSync.enqueue(
                pinId = pinId,
                title = newTitle,
                category = newCategory,
                mode = newMode,
                notes = newNotes,
                baseClientUpdatedAt = base,
            )
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(pinError = null) }
            try {
                val updated = pinRepo.updatePin(
                    id = pinId,
                    paddockId = paddockId,
                    title = title.ifBlank { null },
                    category = category?.ifBlank { null },
                    mode = mode.ifBlank { null },
                    notes = notes?.ifBlank { null },
                    side = side?.ifBlank { null },
                    rowNumber = rowNumber,
                    isCompleted = isCompleted,
                )
                _ui.update { st -> st.copy(pins = st.pins.map { if (it.id == pinId) updated else it }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut()
                onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(pins = previous, pinError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(pins = previous, pinError = "Couldn't save the pin. Check your connection.") }
                onResult(false)
            }
        }
    }

    /**
     * Toggle a pin's completion state with an optimistic flip (Stage 9A).
     *
     * Online (the common path) this PATCHes only `is_completed` and reconciles
     * the server row. Offline — or when the narrow PATCH fails with a clear
     * network/transient/5xx error — the optimistic flip is kept and a
     * completion-only change is queued in the outbox for automatic replay
     * (latest toggle wins per pin). Completion-only — it never queues edits,
     * deletes, or photos. Unauthorized still signs out; validation/permission
     * failures roll the flip back and surface an error rather than queueing.
     */
    fun togglePinCompleted(pin: Pin) {
        val previous = _ui.value.pins
        val target = !pin.isCompleted
        _ui.update { st -> st.copy(pins = st.pins.map { if (it.id == pin.id) it.copy(isCompleted = target) else it }) }

        // Known-offline: keep the optimistic flip and queue without a network call.
        if (!_ui.value.isOnline) {
            pinCompletionSync.enqueue(pin.id, target)
            _ui.update { it.copy(pinError = "Pin completion saved offline — it will sync when connection returns.") }
            return
        }

        viewModelScope.launch {
            try {
                val updated = pinRepo.updatePinCompletion(pin.id, target)
                _ui.update { st -> st.copy(pins = st.pins.map { if (it.id == pin.id) updated else it }) }
            } catch (e: BackendError.Unauthorized) {
                signOut()
            } catch (e: BackendError.Server) {
                if (e.code in 500..599) {
                    // Transient server failure — keep the flip and queue for replay.
                    pinCompletionSync.enqueue(pin.id, target)
                    _ui.update { it.copy(pinError = "Completion saved on this device — it will retry when the server is reachable.") }
                } else {
                    // Validation / permission rejection — don't queue; roll back.
                    _ui.update { it.copy(pins = previous, pinError = friendlyWriteError(e.code)) }
                }
            } catch (e: Exception) {
                // Clear network/transient failure — keep the flip and queue for replay.
                pinCompletionSync.enqueue(pin.id, target)
                _ui.update { it.copy(pinError = "Pin completion saved offline — it will sync when connection returns.") }
            }
        }
    }

    /**
     * Soft-delete a pin (Tier-A Stage G-1 — offline/retryable). Three paths:
     *
     *  - Local-only pin still queued for CREATE: this pin never reached the
     *    server, so cancel the queued create and drop its retained photo rather
     *    than queueing a server delete. This is the only safe way to stop
     *    [PinCreateSync] from later resurrecting a pin the user already deleted.
     *  - Synced pin, offline (or transient network failure): keep the optimistic
     *    hide and enqueue a single PIN / DELETE marker for automatic replay
     *    through [PinDeleteSync].
     *  - Synced pin, online: call the soft-delete RPC immediately; a permission /
     *    validation rejection rolls the pin back, Unauthorized signs out.
     */
    fun deletePin(pinId: String, onResult: (Boolean) -> Unit) {
        // Local-only offline-created pin: cancel the queued create instead of
        // sending a server delete, so PinCreateSync can never resurrect it. Its
        // retained photo is dropped too — the parent pin will never sync.
        val pendingCreate = pendingWrites.list().firstOrNull {
            it.entityType == PendingEntityType.PIN &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == pinId &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (pendingCreate != null) {
            pendingWrites.remove(pendingCreate.id)
            pendingPhotos.list()
                .filter { it.clientPinId == pinId }
                .forEach { pendingPhotos.remove(it.id) }
            _ui.update { st -> st.copy(pins = st.pins.filterNot { it.id == pinId }) }
            onResult(true)
            return
        }

        val previous = _ui.value.pins
        // Optimistic hide for a synced pin.
        _ui.update { st -> st.copy(pins = st.pins.filterNot { it.id == pinId }) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            pinDeleteSync.enqueue(pinId)
            _ui.update { it.copy(pinError = "Pin deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                pinRepo.softDeletePin(pinId)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut()
                onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll back, surface, don't queue.
                _ui.update { it.copy(pins = previous, pinError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                pinDeleteSync.enqueue(pinId)
                _ui.update { it.copy(pinError = "Pin deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    fun clearPinError() {
        _ui.update { it.copy(pinError = null) }
    }

    /**
     * Compress and upload a photo for an existing pin, then persist the
     * `photo_path` reference. Reports a friendly error on failure without
     * losing the rest of the pin's data (the pin row is untouched until the
     * upload succeeds).
     */
    fun uploadPinPhoto(pin: Pin, uri: Uri, onResult: (Boolean) -> Unit) {
        val vineyardId = pin.vineyardId
        _ui.update { it.copy(pinPhotoBusy = true, pinError = null) }
        viewModelScope.launch {
            try {
                val jpeg = PinPhotoImageUtil.compress(getApplication(), uri)
                val path = pinPhotoRepo.upload(vineyardId, pin.id, jpeg)
                val updated = pinRepo.updatePhotoPath(pin.id, path)
                _ui.update { st ->
                    st.copy(
                        pins = st.pins.map { if (it.id == pin.id) updated else it },
                        pinPhotoBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(pinPhotoBusy = false) }
                signOut()
                onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(pinPhotoBusy = false, pinError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(pinPhotoBusy = false, pinError = "Couldn't upload the photo. Check your connection and try again.") }
                onResult(false)
            }
        }
    }

    /**
     * Attach a photo to a just-created quick pin, reusing the existing upload /
     * pending-photo plumbing. When offline (or the network upload fails), the
     * compressed photo is retained locally via the existing pending-photo queue
     * keyed to the pin id so it uploads automatically once sync is available —
     * no new photo queue is introduced. Online it uploads immediately like
     * [uploadPinPhoto].
     */
    fun attachQuickPinPhoto(pin: Pin, uri: Uri, onResult: (Boolean) -> Unit) {
        // Known-offline: keep the photo pending against this pin (Stage 7B queue).
        if (!_ui.value.isOnline) {
            persistPendingPhoto(pin.id, pin.vineyardId, uri)
            _ui.update { it.copy(pinError = "Photo saved offline \u2014 it will upload when sync is available.") }
            onResult(true)
            return
        }
        val vineyardId = pin.vineyardId
        _ui.update { it.copy(pinPhotoBusy = true, pinError = null) }
        viewModelScope.launch {
            val jpeg = runCatching { PinPhotoImageUtil.compress(getApplication(), uri) }.getOrNull()
            try {
                if (jpeg == null) error("Couldn't read the selected image.")
                val path = pinPhotoRepo.upload(vineyardId, pin.id, jpeg)
                val updated = pinRepo.updatePhotoPath(pin.id, path)
                _ui.update { st ->
                    st.copy(
                        pins = st.pins.map { if (it.id == pin.id) updated else it },
                        pinPhotoBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(pinPhotoBusy = false) }
                signOut()
                onResult(false)
            } catch (e: Exception) {
                // Transient/network failure — retain the photo against the pin so it
                // isn't lost, mirroring the createPin deferred-photo behaviour.
                _ui.update { it.copy(pinPhotoBusy = false) }
                if (jpeg != null) {
                    pendingPhotos.enqueue(pin.id, vineyardId, jpeg)
                    _ui.update { it.copy(pinError = "Photo saved \u2014 it will upload when connection is available.") }
                    replayPendingPinPhotos()
                    onResult(true)
                } else {
                    _ui.update { it.copy(pinError = "Couldn't read the selected image.") }
                    onResult(false)
                }
            }
        }
    }

    /** Remove a pin's photo from storage and clear its reference. */
    fun removePinPhoto(pin: Pin, onResult: (Boolean) -> Unit) {
        val path = pin.photoPath
        if (path.isNullOrBlank()) { onResult(true); return }
        _ui.update { it.copy(pinPhotoBusy = true, pinError = null) }
        viewModelScope.launch {
            try {
                pinPhotoRepo.delete(path)
                val updated = pinRepo.updatePhotoPath(pin.id, null)
                _ui.update { st ->
                    st.copy(
                        pins = st.pins.map { if (it.id == pin.id) updated else it },
                        pinPhotoBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(pinPhotoBusy = false) }
                signOut()
                onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(pinPhotoBusy = false, pinError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(pinPhotoBusy = false, pinError = "Couldn't remove the photo. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Mint a signed URL so Coil can load the private pin photo. */
    fun requestPinPhotoUrl(path: String, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            try {
                onResult(pinPhotoRepo.signedUrl(path))
            } catch (e: Exception) {
                onResult(null)
            }
        }
    }

    // MARK: - Vineyard logo

    /**
     * Upload a new vineyard logo: compress the picked image, upsert it into the
     * private `vineyard-logos` bucket, then record `logo_path`/`logo_updated_at`
     * on the vineyard row so every member's app refetches it. Mirrors the iOS
     * logo upload flow; owners/managers only (gated server-side by RLS).
     */
    fun uploadVineyardLogo(vineyardId: String, uri: Uri, onResult: (Boolean) -> Unit) {
        _ui.update { it.copy(vineyardLogoBusy = true) }
        viewModelScope.launch {
            try {
                val jpeg = PinPhotoImageUtil.compress(getApplication(), uri)
                val path = vineyardLogoRepo.upload(vineyardId, jpeg)
                val updatedAt = repo.updateVineyardLogoPath(vineyardId, path)
                _ui.update { st ->
                    st.copy(
                        vineyards = st.vineyards.map {
                            if (it.id == vineyardId) it.copy(logoPath = path, logoUpdatedAt = updatedAt) else it
                        },
                        vineyardLogoBusy = false,
                    )
                }
                runCatching { domainCache.saveVineyards(session.userId, _ui.value.vineyards) }
                // Refresh the cached bitmap from the just-uploaded bytes so the
                // dashboard and PDFs reflect the new logo immediately.
                if (vineyardId == _ui.value.selectedVineyardId) {
                    val bitmap = runCatching { BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) }.getOrNull()
                    loadedLogoKey = "$path|${updatedAt ?: ""}"
                    _ui.update { it.copy(selectedVineyardLogo = bitmap) }
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(vineyardLogoBusy = false) }
                signOut()
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(vineyardLogoBusy = false) }
                onResult(false)
            }
        }
    }

    /** Remove the vineyard logo for everyone: clear the row reference, then delete the object. */
    fun removeVineyardLogo(vineyardId: String, onResult: (Boolean) -> Unit) {
        val existingPath = _ui.value.vineyards.firstOrNull { it.id == vineyardId }?.logoPath
        _ui.update { it.copy(vineyardLogoBusy = true) }
        viewModelScope.launch {
            try {
                repo.updateVineyardLogoPath(vineyardId, null)
                if (!existingPath.isNullOrBlank()) {
                    runCatching { vineyardLogoRepo.delete(existingPath) }
                }
                _ui.update { st ->
                    st.copy(
                        vineyards = st.vineyards.map {
                            if (it.id == vineyardId) it.copy(logoPath = null, logoUpdatedAt = null) else it
                        },
                        vineyardLogoBusy = false,
                    )
                }
                runCatching { domainCache.saveVineyards(session.userId, _ui.value.vineyards) }
                if (vineyardId == _ui.value.selectedVineyardId) {
                    loadedLogoKey = null
                    _ui.update { it.copy(selectedVineyardLogo = null) }
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(vineyardLogoBusy = false) }
                signOut()
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(vineyardLogoBusy = false) }
                onResult(false)
            }
        }
    }

    /** Mint a signed URL so Coil can load the private vineyard logo. */
    fun requestVineyardLogoUrl(path: String, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            try {
                onResult(vineyardLogoRepo.signedUrl(path))
            } catch (e: Exception) {
                onResult(null)
            }
        }
    }

    /** Cache key (path + updatedAt) for the currently decoded logo bitmap. */
    private var loadedLogoKey: String? = null

    /**
     * Keep [AppUiState.selectedVineyardLogo] in sync with the selected vineyard.
     * Downloads + decodes the private logo once per (path, updatedAt) and caches
     * it for the dashboard and PDF exports; clears it when there's no logo.
     * Mirrors how iOS hydrates `logoData` for the selected vineyard.
     */
    private fun refreshSelectedVineyardLogo() {
        val vineyard = _ui.value.selectedVineyard
        val path = vineyard?.logoPath
        if (path.isNullOrBlank()) {
            loadedLogoKey = null
            if (_ui.value.selectedVineyardLogo != null) {
                _ui.update { it.copy(selectedVineyardLogo = null) }
            }
            return
        }
        val key = "$path|${vineyard.logoUpdatedAt ?: ""}"
        if (key == loadedLogoKey && _ui.value.selectedVineyardLogo != null) return
        viewModelScope.launch {
            try {
                val bytes = vineyardLogoRepo.download(path)
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bitmap != null && _ui.value.selectedVineyard?.logoPath == path) {
                    loadedLogoKey = key
                    _ui.update { it.copy(selectedVineyardLogo = bitmap) }
                }
            } catch (e: Exception) {
                // Keep any previously cached logo; the dashboard falls back to the
                // placeholder mark and PDFs simply omit the logo.
            }
        }
    }

    // MARK: - Growth-stage reference images

    /**
     * Load the selected vineyard's custom E-L reference images. Online-first and
     * soft-failing: a fetch hiccup keeps any images already in state rather than
     * blanking the management list. Called after a vineyard is selected.
     */
    private fun refreshGrowthStageImages() {
        val vineyardId = _ui.value.selectedVineyardId ?: return
        viewModelScope.launch {
            val images = try {
                growthImageRepo.listImages(vineyardId)
            } catch (e: Exception) {
                return@launch
            }
            if (_ui.value.selectedVineyardId == vineyardId) {
                _ui.update { it.copy(growthStageImages = images) }
            }
        }
    }

    /**
     * Upload a custom reference image for [stageCode]: compress the picked image,
     * upsert it into the private `vineyard-el-stage-images` bucket, then upsert
     * the metadata row so every member's app sees it. Owners/managers only
     * (gated server-side by RLS).
     */
    fun uploadGrowthStageImage(stageCode: String, uri: Uri, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: return onResult(false)
        _ui.update { it.copy(growthStageImageBusyCode = stageCode) }
        viewModelScope.launch {
            try {
                val jpeg = PinPhotoImageUtil.compress(getApplication(), uri)
                val path = growthImageRepo.uploadObject(vineyardId, stageCode, jpeg)
                val row = growthImageRepo.upsertImage(vineyardId, stageCode, path)
                _ui.update { st ->
                    val rest = st.growthStageImages.filterNot { it.stageCode == stageCode }
                    st.copy(
                        growthStageImages = rest + row,
                        growthStageImageBusyCode = null,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(growthStageImageBusyCode = null) }
                signOut()
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(growthStageImageBusyCode = null) }
                onResult(false)
            }
        }
    }

    /** Remove the custom reference image for [stageCode] for everyone in the vineyard. */
    fun removeGrowthStageImage(stageCode: String, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: return onResult(false)
        val existing = _ui.value.growthStageImages.firstOrNull { it.stageCode == stageCode }
            ?: return onResult(false)
        _ui.update { it.copy(growthStageImageBusyCode = stageCode) }
        viewModelScope.launch {
            try {
                growthImageRepo.softDeleteImage(existing.id)
                runCatching { growthImageRepo.deleteObject(existing.imagePath) }
                _ui.update { st ->
                    st.copy(
                        growthStageImages = st.growthStageImages.filterNot { it.stageCode == stageCode },
                        growthStageImageBusyCode = null,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(growthStageImageBusyCode = null) }
                signOut()
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(growthStageImageBusyCode = null) }
                onResult(false)
            }
        }
    }

    /** Mint a signed URL so Coil can load a private E-L stage reference image. */
    fun requestGrowthStageImageUrl(path: String, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            try {
                onResult(growthImageRepo.signedUrl(path))
            } catch (e: Exception) {
                onResult(null)
            }
        }
    }

    // MARK: - Trip write path

    /**
     * Start a new trip: create the active row on Supabase, then begin
     * foreground GPS capture if location permission has been granted.
     *
     * Stage B-3-1: the final trip UUID is generated up front so a trip started
     * offline (or whose online create fails transiently) becomes a local
     * provisional active trip with the SAME id the server row will eventually
     * use. The trip is inserted into [AppUiState.trips], tracking begins, the
     * Stage A snapshot is persisted, and a coalesced TRIP_START marker is queued.
     * Every dependent same-trip marker (GPS/row/tank/metadata/end) attaches to
     * that id with no remapping, and the dependent replays gate behind the
     * unresolved TRIP_START until the server row exists. Unauthorized still signs
     * out and queues nothing.
     */
    fun startTrip(
        paddockId: String?,
        paddockName: String?,
        personName: String?,
        tripFunction: String?,
        tripTitle: String?,
        machineId: String? = null,
        workTaskId: String? = null,
        operatorUserId: String? = null,
        operatorCategoryId: String? = null,
        startEngineHours: Double? = null,
        paddockIds: List<String> = emptyList(),
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        // Final id + start instant generated up front so an offline/transient
        // fallback provisional trip shares the eventual server row's identity.
        val tripId = java.util.UUID.randomUUID().toString()
        val startTime = java.time.Instant.now().toString()
        val provisional = Trip(
            id = tripId,
            vineyardId = vineyardId,
            paddockId = paddockId,
            paddockName = paddockName?.ifBlank { null },
            paddockIds = paddockIds,
            startTime = startTime,
            isActive = true,
            isPaused = false,
            totalDistance = 0.0,
            pathPoints = emptyList(),
            personName = personName?.ifBlank { null },
            tripFunction = tripFunction?.ifBlank { null },
            tripTitle = tripTitle?.ifBlank { null },
            machineId = machineId,
            workTaskId = workTaskId,
            operatorUserId = operatorUserId,
            operatorCategoryId = operatorCategoryId,
            startEngineHours = startEngineHours,
            clientUpdatedAt = startTime,
        )
        // Known offline: start locally and queue the create marker; no network.
        if (!_ui.value.isOnline) {
            startTripLocally(provisional)
            onResult(true)
            return
        }
        viewModelScope.launch {
            _ui.update { it.copy(tripBusy = true, tripError = null) }
            try {
                val created = tripRepo.createTrip(
                    vineyardId = vineyardId,
                    paddockId = paddockId,
                    paddockName = paddockName?.ifBlank { null },
                    personName = personName?.ifBlank { null },
                    tripFunction = tripFunction?.ifBlank { null },
                    tripTitle = tripTitle?.ifBlank { null },
                    machineId = machineId,
                    workTaskId = workTaskId,
                    operatorUserId = operatorUserId,
                    operatorCategoryId = operatorCategoryId,
                    startEngineHours = startEngineHours,
                    paddockIds = paddockIds,
                    id = tripId,
                    startTime = startTime,
                    clientUpdatedAt = startTime,
                )
                _ui.update { it.copy(trips = listOf(created) + it.trips, tripBusy = false) }
                beginTracking(created)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(tripBusy = false) }
                signOut(); onResult(false)
            } catch (e: Exception) {
                // Transient (network / server) while we believed we were online:
                // fall back to the local provisional start with the same id and
                // queue the create marker rather than lose the attempted trip.
                startTripLocally(provisional)
                onResult(true)
            }
        }
    }

    /**
     * Begin a NEW trip locally (Stage B-3-1) when offline or after a transient
     * online create failure. Inserts [provisional] as the active trip, starts
     * foreground capture, persists the Stage A snapshot, queues a coalesced
     * TRIP_START create marker, and surfaces a friendly offline message. The
     * trip's id is the final server row id, so dependent markers attach to it
     * with no remapping.
     */
    private fun startTripLocally(provisional: Trip) {
        _ui.update {
            it.copy(
                trips = listOf(provisional) + it.trips,
                tripBusy = false,
                tripError = "Trip started offline — it'll sync when connection returns.",
            )
        }
        tripStartSync.enqueue(provisional)
        // beginTracking persists the Stage A snapshot for the freshly-started trip.
        beginTracking(provisional)
    }

    /** Edit an active or finished trip's job details (no progress changes). */
    fun updateTripMetadata(
        tripId: String,
        paddockId: String?,
        paddockName: String?,
        personName: String?,
        tripFunction: String?,
        tripTitle: String?,
        machineId: String? = null,
        workTaskId: String? = null,
        operatorUserId: String? = null,
        operatorCategoryId: String? = null,
        paddockIds: List<String> = emptyList(),
        onResult: (Boolean) -> Unit,
    ) {
        val previous = _ui.value.trips
        // Stage B-1: queue the scalar edit offline for an existing active server
        // trip instead of failing. Optimistically apply locally, refresh the
        // Stage A snapshot, enqueue a coalesced TRIP_METADATA write, and surface
        // a friendly offline message — no network call is made.
        val target = previous.firstOrNull { it.id == tripId }
        if (!_ui.value.isOnline && target != null && target.isActive) {
            val optimistic = target.copy(
                paddockId = paddockId,
                paddockName = paddockName?.ifBlank { null },
                paddockIds = paddockIds,
                personName = personName?.ifBlank { null },
                tripFunction = tripFunction?.ifBlank { null },
                tripTitle = tripTitle?.ifBlank { null },
                machineId = machineId,
                workTaskId = workTaskId,
                operatorUserId = operatorUserId,
                operatorCategoryId = operatorCategoryId,
            )
            _ui.update { st ->
                st.copy(
                    trips = st.trips.map { if (it.id == tripId) optimistic else it },
                    tripError = "Trip details saved offline — they'll sync when connection returns.",
                )
            }
            persistActiveTripSnapshot()
            tripMetadataSync.enqueue(optimistic)
            onResult(true)
            return
        }
        viewModelScope.launch {
            _ui.update { it.copy(tripError = null) }
            try {
                val updated = tripRepo.updateMetadata(
                    id = tripId,
                    paddockId = paddockId,
                    paddockName = paddockName?.ifBlank { null },
                    personName = personName?.ifBlank { null },
                    tripFunction = tripFunction?.ifBlank { null },
                    tripTitle = tripTitle?.ifBlank { null },
                    machineId = machineId,
                    workTaskId = workTaskId,
                    operatorUserId = operatorUserId,
                    operatorCategoryId = operatorCategoryId,
                    paddockIds = paddockIds,
                )
                _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == tripId) updated else it }) }
                // Refresh the local snapshot if the edited trip is the active one.
                persistActiveTripSnapshot()
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(trips = previous, tripError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(trips = previous, tripError = "Couldn't save the trip. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Pause or resume GPS capture for the active trip. */
    fun setTripPaused(tripId: String, paused: Boolean) {
        _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == tripId) it.copy(isPaused = paused) else it }) }
        persistActiveTripSnapshot()
        val trip = _ui.value.trips.firstOrNull { it.id == tripId } ?: return
        // Stage B-1: when offline, queue the pause/resume as a scalar edit so it
        // isn't silently lost (the online saveProgress below would throw and be
        // swallowed). Active server trips only; no network call when offline.
        if (!_ui.value.isOnline) {
            if (trip.isActive) tripMetadataSync.enqueue(trip)
            return
        }
        viewModelScope.launch {
            try {
                tripRepo.saveProgress(tripId, trip.pathPoints ?: emptyList(), trip.totalDistance ?: 0.0, paused)
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Finish the active trip: stop capture and persist the final track.
     *
     * Stage B-2-1: when the device is known offline (or the online end fails
     * transiently) the trip is ended LOCALLY — the captured path/distance are
     * folded into the local trip + Stage A snapshot, a coalesced TRIP_GPS marker
     * is queued so the latest path lands first, and a coalesced TRIP_END marker
     * is queued carrying the end summary scalars. The trip id is added to
     * [AppUiState.locallyEndedTripIds] so the UI shows it finished and no further
     * GPS / row / tank work accrues, while the durable snapshot is preserved
     * until the dependency-gated end replay finalises server-side. Unauthorized
     * still signs out.
     */
    fun endTrip(notes: String?, endEngineHours: Double? = null, onResult: (Boolean) -> Unit) {
        val trip = _ui.value.activeTrip ?: run { onResult(false); return }
        val tripId = trip.id
        val capturedPoints = tracker?.points?.toList() ?: trip.pathPoints ?: emptyList()
        val capturedDistance = tracker?.distanceMetres ?: trip.totalDistance ?: 0.0
        val requestedEndTime = java.time.Instant.now().toString()
        val cleanNotes = notes?.ifBlank { null }
        tracker?.stop()
        tracker = null
        _ui.update { it.copy(isTracking = false) }
        clearRowLockState()
        // Fold the final captured path/distance into the local trip + snapshot so
        // the (still server-active) trip carries the freshest local track for the
        // TRIP_GPS dependency replay and survives a process death.
        _ui.update { st ->
            st.copy(
                trips = st.trips.map {
                    if (it.id == tripId) it.copy(pathPoints = capturedPoints, totalDistance = capturedDistance) else it
                },
            )
        }
        persistActiveTripSnapshot()
        // Known offline: end locally and queue the markers; no network call.
        if (!_ui.value.isOnline) {
            markTripEndedLocally(tripId, cleanNotes, endEngineHours, requestedEndTime)
            onResult(true)
            return
        }
        viewModelScope.launch {
            _ui.update { it.copy(tripBusy = true, tripError = null) }
            try {
                val ended = tripRepo.endTrip(tripId, capturedPoints, capturedDistance, cleanNotes, endEngineHours)
                _ui.update { st ->
                    st.copy(
                        trips = st.trips.map { if (it.id == tripId) ended else it },
                        locallyEndedTripIds = st.locallyEndedTripIds - tripId,
                        tripBusy = false,
                    )
                }
                // Trip finished server-side — drop the durable local snapshot.
                persistActiveTripSnapshot()
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(tripBusy = false) }
                signOut(); onResult(false)
            } catch (e: Exception) {
                // Transient (network / server) while we believed we were online:
                // keep the optimistic ended state and queue the markers rather
                // than roll back and lose the end. Coalesced by trip id.
                markTripEndedLocally(tripId, cleanNotes, endEngineHours, requestedEndTime)
                onResult(true)
            }
        }
    }

    /**
     * Apply the optimistic locally-ended state for [tripId] (Stage B-2-1) and
     * queue the dependency + end markers. Queues a coalesced TRIP_GPS marker so
     * the final captured path lands before the TRIP_END dependency gate clears,
     * then a coalesced TRIP_END marker carrying the end summary scalars. The
     * trip is flagged locally ended (so it leaves [AppUiState.activeTrip] and
     * further GPS/row/tank actions are gated) while its Stage A snapshot is
     * preserved until the end replay succeeds. No-op when the trip is no longer
     * a known active server trip.
     */
    private fun markTripEndedLocally(
        tripId: String,
        notes: String?,
        endEngineHours: Double?,
        requestedEndTime: String,
    ) {
        val current = _ui.value.trips.firstOrNull { it.id == tripId } ?: return
        if (!current.isActive) return
        // The latest captured path must land first — queue/refresh the GPS marker
        // so the dependency gate holds the end until the path is synced.
        tripGpsSync.enqueue(current)
        tripEndSync.enqueue(current, notes, endEngineHours, requestedEndTime)
        _ui.update {
            it.copy(
                locallyEndedTripIds = it.locallyEndedTripIds + tripId,
                tripBusy = false,
                tripError = "Trip ended offline — it'll finish syncing when connection returns.",
            )
        }
    }

    /**
     * End-trip row review / reconciliation (Stage 3D-4). Before finishing a
     * planned spray trip, the operator can tick any still-uncovered planned
     * paths as completed. This appends them to `completed_paths` (additive,
     * de-duplicated — never removes existing completed/skipped coverage),
     * recomputes the sequence index/current/next, persists via the dedicated
     * coverage patch, then finalises the trip via the normal end path.
     *
     * Free Drive / no-row-plan trips, or a finish with no review ticks, skip
     * straight to the existing [endTrip] flow unchanged. If the coverage
     * reconciliation patch fails, the trip is NOT finished and the operator's
     * review choices are preserved so they can retry.
     */
    fun endTripWithRowReview(
        extraCompletedPaths: List<Double>,
        notes: String?,
        endEngineHours: Double? = null,
        onResult: (Boolean) -> Unit,
    ) {
        val trip = _ui.value.activeTrip ?: run { onResult(false); return }
        val sequence = trip.rowSequence
        if (extraCompletedPaths.isEmpty() || sequence.isEmpty()) {
            endTrip(notes, endEngineHours, onResult)
            return
        }
        viewModelScope.launch {
            _ui.update { it.copy(tripBusy = true, tripError = null) }
            val completed = trip.completedPaths.orEmpty().toMutableList()
            val skipped = trip.skippedPaths.orEmpty().toMutableList()
            for (path in extraCompletedPaths) {
                if (!completed.contains(path) && !skipped.contains(path)) completed.add(path)
            }
            // Advance the index past every path that is now covered.
            var newIndex = 0
            while (newIndex < sequence.size &&
                (completed.contains(sequence[newIndex]) || skipped.contains(sequence[newIndex]))
            ) {
                newIndex++
            }
            val current = sequence.getOrNull(newIndex)
            val next = sequence.getOrNull(newIndex + 1)
            // Apply the review coverage optimistically to the local trip +
            // snapshot first so the review-before-end choices are never lost,
            // whether the save lands online now or is deferred to a marker.
            _ui.update { st ->
                st.copy(
                    trips = st.trips.map {
                        if (it.id == trip.id) it.copy(
                            completedPaths = completed,
                            skippedPaths = skipped,
                            sequenceIndex = newIndex,
                            currentRowNumber = current,
                            nextRowNumber = next,
                        ) else it
                    },
                )
            }
            persistActiveTripSnapshot()
            // Known offline: queue a TRIP_ROW marker so the review coverage lands
            // (the TRIP_END dependency gate then holds the end until it syncs),
            // and finalise via the offline end path below.
            if (!_ui.value.isOnline) {
                val cur = _ui.value.trips.firstOrNull { it.id == trip.id }
                if (cur != null && cur.isActive) tripRowSync.enqueue(cur)
                endTrip(notes, endEngineHours, onResult)
                return@launch
            }
            try {
                val updated = tripRepo.updateTripCoverage(trip.id, completed, skipped, newIndex, current, next)
                _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == trip.id) updated else it }) }
                persistActiveTripSnapshot()
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(tripBusy = false) }
                signOut(); onResult(false); return@launch
            } catch (e: Exception) {
                // Transient: keep the optimistic review coverage and queue a
                // TRIP_ROW marker so it lands; the TRIP_END dependency gate will
                // wait for it. Then finalise via the (also-deferred) end path.
                val cur = _ui.value.trips.firstOrNull { it.id == trip.id }
                if (cur != null && cur.isActive) tripRowSync.enqueue(cur)
                endTrip(notes, endEngineHours, onResult)
                return@launch
            }
            // Coverage saved — finalise the trip via the unchanged end path.
            endTrip(notes, endEngineHours, onResult)
        }
    }

    /**
     * Soft-delete a trip (Tier-A Stage G-2 — offline/retryable for ended trips).
     *
     * Eligibility is intentionally narrow in G-2: only an ended / inactive trip
     * with NO unresolved same-trip markers can be queued for offline delete.
     *
     *  - Active / in-flight trip (current active trip or `isActive`): kept on the
     *    existing ONLINE-only path — no offline queue. Active-trip offline delete
     *    is parked for Stage G-3.
     *  - Ended trip still waiting on same-trip start/metadata/GPS/row/tank/end
     *    markers: refused with a friendly hint, left visible, never queued — so a
     *    delete can't race or orphan unsynced trip work.
     *  - Eligible ended trip, offline (or transient network failure): keep the
     *    optimistic hide and enqueue a single TRIP / DELETE marker for automatic
     *    replay through [TripDeleteSync].
     *  - Eligible ended trip, online: call the soft-delete RPC immediately; a
     *    permission / validation rejection rolls the trip back, Unauthorized
     *    signs out.
     */
    fun deleteTrip(tripId: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.trips
        val isActiveTrip = _ui.value.activeTrip?.id == tripId ||
            previous.firstOrNull { it.id == tripId }?.isActive == true

        // Active / in-flight trip: keep the existing online-only behaviour. No
        // offline queue is added here — that's parked for Stage G-3.
        if (isActiveTrip) {
            if (_ui.value.activeTrip?.id == tripId) {
                tracker?.stop(); tracker = null
                _ui.update { it.copy(isTracking = false) }
                clearRowLockState()
            }
            _ui.update { st -> st.copy(trips = st.trips.filterNot { it.id == tripId }) }
            // Drop the local snapshot if the deleted trip was the active one.
            persistActiveTripSnapshot()
            viewModelScope.launch {
                try {
                    tripRepo.softDeleteTrip(tripId)
                    onResult(true)
                } catch (e: BackendError.Unauthorized) {
                    signOut(); onResult(false)
                } catch (e: BackendError.Server) {
                    _ui.update { it.copy(trips = previous, tripError = friendlyWriteError(e.code)) }
                    persistActiveTripSnapshot()
                    onResult(false)
                } catch (e: Exception) {
                    _ui.update { it.copy(trips = previous, tripError = "Couldn't delete the trip. Check your connection.") }
                    persistActiveTripSnapshot()
                    onResult(false)
                }
            }
            return
        }

        // Same-trip unresolved-marker guard: an ended trip that still has queued
        // start/metadata/GPS/row/tank/end work must finish syncing before it can
        // be deleted, so a delete never races or orphans that work.
        val hasUnresolvedTripMarkers = pendingWrites.list().any {
            it.clientId == tripId &&
                it.entityType in TripDeleteSync.DEPENDENCY_TYPES &&
                it.status in PendingWriteStatus.unresolved
        }
        if (hasUnresolvedTripMarkers) {
            _ui.update { it.copy(tripError = "Finish syncing this trip before deleting it.") }
            onResult(false)
            return
        }

        // Eligible ended trip: optimistic hide, then queue or send.
        _ui.update { st -> st.copy(trips = st.trips.filterNot { it.id == tripId }) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            tripDeleteSync.enqueue(tripId)
            _ui.update { it.copy(tripError = "Trip deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                tripRepo.softDeleteTrip(tripId)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll back, surface, don't queue.
                _ui.update { it.copy(trips = previous, tripError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                tripDeleteSync.enqueue(tripId)
                _ui.update { it.copy(tripError = "Trip deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Resume foreground capture for an already-active trip (e.g. after the
     * Trips tab opens and location permission has just been granted). No-op
     * when already tracking or there's no active trip.
     */
    fun resumeTrackingForActive() {
        if (tracker != null) return
        val trip = _ui.value.activeTrip ?: return
        beginTracking(trip)
    }

    fun clearTripError() {
        _ui.update { it.copy(tripError = null) }
    }

    /** Id of the currently active trip, if any (used to navigate after start). */
    fun activeTripIdOrNull(): String? = _ui.value.activeTrip?.id

    /**
     * One-shot current GPS fix for dropping a pin from the Repairs/Growth
     * launcher. Returns lat/lng when permission is granted and a fix is
     * available, otherwise null so callers fall back to the paddock centroid.
     */
    fun fetchCurrentLocation(onResult: (Pair<Double, Double>?) -> Unit) {
        viewModelScope.launch {
            val point = try {
                LocationTracker(getApplication()).currentLocation()
            } catch (_: Exception) {
                null
            }
            onResult(point?.let { it.latitude to it.longitude })
        }
    }

    /** Whether foreground location permission is currently granted. */
    fun hasLocationPermission(): Boolean = LocationTracker(getApplication()).hasPermission

    private fun beginTracking(trip: Trip) {
        val t = LocationTracker(getApplication())
        if (!t.hasPermission) {
            tracker = null
            _ui.update { it.copy(isTracking = false) }
            return
        }
        tracker = t
        pointsSinceSave = 0
        lastSaveMs = System.currentTimeMillis()
        pointsSinceLocalSave = 0
        lastLocalSaveMs = System.currentTimeMillis()
        rowLockTracker.reset()
        _ui.update {
            it.copy(
                isTracking = true,
                latestBearingDegrees = null,
                latestSpeedMetresPerSecond = null,
                latestAccuracyMetres = null,
                currentDrivingPathNumber = null,
                rowLockConfidence = 0.0,
                rowLockIsConfident = false,
            )
        }
        t.start(seed = trip.pathPoints ?: emptyList()) { points, distance, sample ->
            _ui.update { st ->
                st.copy(trips = st.trips.map { if (it.id == trip.id) it.copy(pathPoints = points, totalDistance = distance) else it })
            }
            updateRowLockState(trip.id, sample)
            maybeAutosave(trip.id, points, distance)
            maybeAutosaveLocal()
        }
        // Capture the freshly-started/resumed trip locally straight away.
        persistActiveTripSnapshot()
    }

    /**
     * Update live movement context + the row-lock state from one GPS fix.
     * Resolves the active block geometry to derive the live driving path
     * (nearest row − 0.5) and corridor membership, then advances the lock
     * state machine. Read-only: never persists to pins or trips.
     */
    private fun updateRowLockState(tripId: String, sample: LocationTracker.MovementSample?) {
        if (sample == null) return
        val st = _ui.value
        val trip = st.trips.firstOrNull { it.id == tripId }
        // Resolve the block the operator is in: prefer the trip's block, then
        // any block whose polygon contains the fix.
        val paddock = st.paddocks.firstOrNull { it.id == trip?.paddockId }
            ?: st.paddocks.firstOrNull { RowAttachment.containsPoint(it, sample.latitude, sample.longitude) }
        val hit = RowAttachment.nearestRow(paddock, sample.latitude, sample.longitude)
        if (hit != null) {
            // iOS numbers the driving path as the row's mid-row (row − 0.5).
            val livePath = hit.rowNumber - 0.5
            val corridorTolerance = (hit.rowWidthM / 2.0).coerceAtLeast(1.0)
            val inCorridor = hit.perpendicularDistanceM <= corridorTolerance
            rowLockTracker.update(livePath, inCorridor, sample.timestampMs)
        }
        _ui.update {
            it.copy(
                latestBearingDegrees = sample.bearingDegrees ?: it.latestBearingDegrees,
                latestSpeedMetresPerSecond = sample.speedMetresPerSecond ?: it.latestSpeedMetresPerSecond,
                latestAccuracyMetres = sample.accuracyMetres ?: it.latestAccuracyMetres,
                currentDrivingPathNumber = rowLockTracker.drivingPathNumber,
                rowLockConfidence = rowLockTracker.confidence,
                rowLockIsConfident = rowLockTracker.isConfident,
            )
        }
    }

    /** Reset live movement + row-lock state when tracking stops. */
    private fun clearRowLockState() {
        rowLockTracker.reset()
        _ui.update {
            it.copy(
                latestBearingDegrees = null,
                latestSpeedMetresPerSecond = null,
                latestAccuracyMetres = null,
                currentDrivingPathNumber = null,
                rowLockConfidence = 0.0,
                rowLockIsConfident = false,
            )
        }
    }

    /** Throttle server writes: persist roughly every 8 fixes or 20 seconds. */
    private fun maybeAutosave(tripId: String, points: List<CoordinatePoint>, distance: Double) {
        pointsSinceSave++
        val now = System.currentTimeMillis()
        if (pointsSinceSave < 8 && now - lastSaveMs < 20_000L) return
        pointsSinceSave = 0
        lastSaveMs = now
        val trip = _ui.value.trips.firstOrNull { it.id == tripId } ?: return
        val paused = trip.isPaused
        // Stage C-1: when known offline, don't attempt a network write that would
        // throw and be swallowed — just queue/refresh the coalesced TRIP_GPS
        // marker. The captured path already lives in the Stage A snapshot
        // (persisted via maybeAutosaveLocal); the marker only flags that this
        // active server trip has unsynced progress to merge/replay later.
        if (!_ui.value.isOnline) {
            if (trip.isActive) tripGpsSync.enqueue(trip)
            return
        }
        viewModelScope.launch {
            try {
                tripRepo.saveProgress(tripId, points, distance, paused)
            } catch (_: Exception) {
                // Server autosave failed while we believed we were online. Queue a
                // marker so the progress is merged/replayed on reconnect rather
                // than silently lost. Coalesced by trip id, so repeated failures
                // never bloat the outbox.
                val current = _ui.value.trips.firstOrNull { it.id == tripId }
                if (current != null && current.isActive) tripGpsSync.enqueue(current)
            }
        }
    }

    /**
     * Throttled local snapshot of the active trip during GPS capture (Tier-A
     * Stage A). Persists roughly every 4 fixes or 8 seconds — more frequent than
     * the server autosave — so a process death loses at most a few tail points.
     * Discrete edits persist immediately via [persistActiveTripSnapshot].
     */
    private fun maybeAutosaveLocal() {
        pointsSinceLocalSave++
        val now = System.currentTimeMillis()
        if (pointsSinceLocalSave < 4 && now - lastLocalSaveMs < 8_000L) return
        pointsSinceLocalSave = 0
        lastLocalSaveMs = now
        persistActiveTripSnapshot()
    }

    /**
     * Persist (or clear) the durable local active-trip snapshot from current
     * state (Tier-A Stage A). Local-only — no server writes, no replay. Saves
     * the active trip scoped to the current user + selected vineyard; clears the
     * store when there is no active trip (e.g. after the trip is ended/deleted).
     */
    private fun persistActiveTripSnapshot() {
        val state = _ui.value
        // A trip the operator ended locally (Stage B-2-1) is excluded from
        // [AppUiState.activeTrip], but its snapshot must be preserved until the
        // queued TRIP_END marker syncs so the end replay and its GPS/row/tank
        // dependency replays still have the local source. Fall back to it here.
        val trip = state.activeTrip
            ?: state.trips.firstOrNull { it.isActive && it.id in state.locallyEndedTripIds }
        val vineyardId = state.selectedVineyardId
        val userId = session.userId
        if (trip == null || vineyardId == null || userId == null) {
            runCatching { activeTripStore.clear() }
            return
        }
        runCatching { activeTripStore.save(userId, vineyardId, trip) }
    }

    /**
     * Restore the durable local active-trip snapshot into the loaded trip list
     * (Tier-A Stage A). Local-only — no replay, no server writes.
     *
     * Safety rules:
     *  - the snapshot must belong to the current user + vineyard, else it is
     *    cleared and ignored;
     *  - a non-active snapshot is cleared and ignored;
     *  - when the server returned the same trip and it is still active, the
     *    locally-persisted in-progress fields (path/coverage/tank/engine) are
     *    overlaid on the server row — local is the freshest record of this
     *    device's work, since the server autosave is throttled and can silently
     *    fail;
     *  - when the server returned the trip but it is no longer active (ended or
     *    deleted elsewhere), the server wins and the snapshot is cleared;
     *  - when the trip is absent from a fresh server list it was ended/deleted
     *    elsewhere, so it is NOT resurrected and the snapshot is cleared;
     *  - when the trip is absent only because the list is stale/offline, the
     *    snapshot is injected so the active-trip view restores.
     *
     * No server-created trip is ever faked: a snapshot only exists once a trip
     * has a real server id (start requires the server). A start that failed
     * before the server returned an id stores nothing — parked for Stage B.
     */
    private fun restoreActiveTrip(
        userId: String?,
        vineyardId: String,
        loadedTrips: List<Trip>,
        tripsFromServer: Boolean,
    ): List<Trip> {
        val snapshot = runCatching { activeTripStore.load() }.getOrNull() ?: return loadedTrips
        if (snapshot.ownerUserId != userId || snapshot.vineyardId != vineyardId) {
            runCatching { activeTripStore.clear() }
            return loadedTrips
        }
        val saved = snapshot.trip
        if (!saved.isActive) {
            runCatching { activeTripStore.clear() }
            return loadedTrips
        }
        val index = loadedTrips.indexOfFirst { it.id == saved.id }
        if (index >= 0) {
            val server = loadedTrips[index]
            if (!server.isActive) {
                // Ended/deleted elsewhere — server wins.
                runCatching { activeTripStore.clear() }
                return loadedTrips
            }
            val merged = mergeLocalProgress(server, saved)
            return loadedTrips.toMutableList().also { it[index] = merged }
        }
        // Absent from the loaded list.
        // Stage B-3-1: a trip started offline is legitimately absent from the
        // server until its TRIP_START create marker lands. While that marker is
        // unresolved the provisional trip is NOT gone — restore it (even from a
        // fresh server list) so the active-trip view and its queued GPS/row/tank
        // work survive a restart instead of being wiped.
        if (TripStartSync.Dependency.hasUnresolvedStart(pendingWrites, saved.id)) {
            return listOf(saved) + loadedTrips
        }
        return if (tripsFromServer) {
            // Fresh server list without it — the trip is gone; don't resurrect.
            runCatching { activeTripStore.clear() }
            loadedTrips
        } else {
            // Stale/offline list — restore so the active-trip view survives.
            listOf(saved) + loadedTrips
        }
    }

    /**
     * Overlay the locally-persisted in-progress fields onto the server trip
     * (Tier-A Stage A). The path is only taken from local when local has at
     * least as many points, so a shorter local snapshot never truncates a
     * longer server track.
     */
    private fun mergeLocalProgress(server: Trip, local: Trip): Trip {
        val serverPointCount = server.pathPoints?.size ?: 0
        val localPointCount = local.pathPoints?.size ?: 0
        val useLocalPath = localPointCount >= serverPointCount
        return server.copy(
            pathPoints = if (useLocalPath) local.pathPoints else server.pathPoints,
            totalDistance = if (useLocalPath) local.totalDistance else server.totalDistance,
            isPaused = local.isPaused,
            completedPaths = local.completedPaths,
            skippedPaths = local.skippedPaths,
            trackingPattern = local.trackingPattern,
            rowSequence = local.rowSequence,
            sequenceIndex = local.sequenceIndex,
            currentRowNumber = local.currentRowNumber,
            nextRowNumber = local.nextRowNumber,
            tankSessions = local.tankSessions,
            activeTankNumber = local.activeTankNumber,
            isFillingTank = local.isFillingTank,
            fillingTankNumber = local.fillingTankNumber,
            startEngineHours = local.startEngineHours,
            endEngineHours = local.endEngineHours,
        )
    }

    override fun onCleared() {
        tracker?.stop()
        tracker = null
        super.onCleared()
    }

    // MARK: - Work task write path

    /**
     * Log a new work task header, optimistically inserting it at the top of the
     * list (Android Stage J-1 offline create queue). The id and client_updated_at
     * are minted up front so the same id is shared by the optimistic local row,
     * the queued WORK_TASK / CREATE marker, and the eventual server insert. Paths:
     *
     *  - Optimistic: prepend the task immediately so the operator sees it.
     *  - Known-offline: skip the network and enqueue one create marker for
     *    automatic replay through [WorkTaskCreateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic row and enqueue a marker.
     *  - Permanent (validation / permission) rejection: roll the optimistic row
     *    back and surface the error; never queued as retryable. Unauthorized
     *    signs out.
     *
     * Work-task update / finalize / delete remain online-only in J-1, and the
     * labour/machine line writes are parked for J-4/J-5.
     */
    fun createWorkTask(
        taskType: String,
        paddockIds: List<String>,
        date: String,
        durationHours: Double,
        notes: String?,
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = workTaskRepo.newId()
        val clientUpdatedAt = Instant.now().toString()
        val blocks = selectedBlocks(paddockIds)
        val paddockId = blocks.firstOrNull()?.id
        val paddockName = blockNameSnapshot(blocks)
        val trimmedType = taskType.trim()
        val trimmedNotes = notes?.ifBlank { null }
        val optimistic = WorkTask(
            id = id,
            vineyardId = vineyardId,
            paddockId = paddockId,
            paddockName = paddockName,
            date = date,
            taskType = trimmedType,
            durationHours = durationHours,
            notes = trimmedNotes,
            isFinalized = false,
        )
        // Optimistic insert at the top — the operator sees the task straight away.
        _ui.update { it.copy(workTasks = listOf(optimistic) + it.workTasks, workTaskError = null) }

        // Known-offline: queue the create marker without touching the network.
        if (!_ui.value.isOnline) {
            workTaskCreateSync.enqueue(id, vineyardId, paddockId, paddockName, date, trimmedType, durationHours, trimmedNotes, clientUpdatedAt)
            // Join rows queue too — gated behind the header create until it syncs.
            reconcileWorkTaskPaddocks(id, vineyardId, paddockIds)
            _ui.update { it.copy(workTaskError = "Work task saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(workTaskBusy = true) }
            try {
                val created = workTaskRepo.createWorkTask(
                    vineyardId = vineyardId,
                    paddockId = paddockId,
                    paddockName = paddockName,
                    date = date,
                    taskType = trimmedType,
                    durationHours = durationHours,
                    notes = trimmedNotes,
                    id = id,
                    clientUpdatedAt = clientUpdatedAt,
                )
                _ui.update { st -> st.copy(workTasks = st.workTasks.map { if (it.id == id) created else it }, workTaskBusy = false) }
                // Header now exists server-side — write the join rows online.
                reconcileWorkTaskPaddocks(id, vineyardId, paddockIds)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(workTaskBusy = false) }
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic row
                // back, surface, don't queue as retryable.
                _ui.update { st -> st.copy(workTaskBusy = false, workTasks = st.workTasks.filterNot { it.id == id }, workTaskError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic row and queue a
                // create marker for automatic replay rather than rolling back.
                workTaskCreateSync.enqueue(id, vineyardId, paddockId, paddockName, date, trimmedType, durationHours, trimmedNotes, clientUpdatedAt)
                // Join rows queue behind the now-pending header create.
                reconcileWorkTaskPaddocks(id, vineyardId, paddockIds)
                _ui.update { it.copy(workTaskBusy = false, workTaskError = "Work task saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /** Resolve a selection of paddock ids to their loaded [Paddock]s, order preserved. */
    private fun selectedBlocks(paddockIds: List<String>): List<Paddock> {
        val byId = _ui.value.paddocks.associateBy { it.id }
        return paddockIds.distinct().mapNotNull { byId[it] }
    }

    /**
     * Display snapshot stored on the work-task header `paddock_name` for a block
     * selection: the single block's name, a comma-joined list for several, or
     * null for none. Mirrors the iOS `blockNames` snapshot. The authoritative
     * multi-block set lives in the `work_task_paddocks` join rows.
     */
    private fun blockNameSnapshot(blocks: List<Paddock>): String? = when {
        blocks.isEmpty() -> null
        blocks.size == 1 -> blocks.first().name
        else -> blocks.joinToString(", ") { it.name }
    }

    /**
     * Reconcile the `work_task_paddocks` join rows for [taskId] against the
     * desired [desiredPaddockIds] set (Android Stage R): insert rows for newly
     * added blocks, soft-delete rows for removed blocks, leave unchanged blocks
     * alone. Optimistically updates [AppUiState.workTaskPaddocks] first.
     *
     * Parent gate: when the header still has an unresolved create marker (a
     * not-yet-synced task), every child write is QUEUED rather than sent online,
     * so [WorkTaskPaddockSync]'s parent gate holds it until the header lands —
     * never raced against a task the server doesn't have yet. Otherwise online
     * inserts/deletes run immediately, falling back to the offline queue on a
     * transient failure. A never-synced row removed before it synced is cancelled
     * locally rather than sending a delete for a row that never existed.
     */
    private fun reconcileWorkTaskPaddocks(
        taskId: String,
        vineyardId: String,
        desiredPaddockIds: List<String>,
    ) {
        val desired = desiredPaddockIds.distinct()
        val existing = _ui.value.workTaskPaddocks.filter { it.workTaskId == taskId }
        val existingPaddockIds = existing.map { it.paddockId }.toSet()
        val clientUpdatedAt = Instant.now().toString()
        val headerPending = pendingWrites.list().any {
            it.entityType == PendingEntityType.WORK_TASK &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == taskId &&
                it.status in PendingWriteStatus.unresolved
        }
        val online = _ui.value.isOnline && !headerPending

        // Additions — one join row per newly selected block.
        for (pid in desired.filterNot { it in existingPaddockIds }) {
            val joinId = workTaskPaddockRepo.newId()
            val areaHa = _ui.value.paddocks.firstOrNull { it.id == pid }?.areaHectares?.takeIf { it > 0 }
            val row = WorkTaskPaddock(joinId, taskId, vineyardId, pid, areaHa)
            _ui.update { st -> st.copy(workTaskPaddocks = st.workTaskPaddocks + row) }
            if (!online) {
                workTaskPaddockSync.enqueueCreate(joinId, taskId, vineyardId, pid, areaHa, clientUpdatedAt)
            } else {
                viewModelScope.launch {
                    try {
                        val saved = workTaskPaddockRepo.insert(joinId, taskId, vineyardId, pid, areaHa, clientUpdatedAt)
                        _ui.update { st -> st.copy(workTaskPaddocks = st.workTaskPaddocks.map { if (it.id == joinId) saved else it }) }
                    } catch (e: BackendError.Unauthorized) {
                        signOut()
                    } catch (e: BackendError.Server) {
                        // Permission/validation — roll the optimistic add back.
                        _ui.update { st -> st.copy(workTaskPaddocks = st.workTaskPaddocks.filterNot { it.id == joinId }) }
                    } catch (e: Exception) {
                        workTaskPaddockSync.enqueueCreate(joinId, taskId, vineyardId, pid, areaHa, clientUpdatedAt)
                    }
                }
            }
        }

        // Removals — soft-delete the join row for each de-selected block.
        for (rowToRemove in existing.filterNot { it.paddockId in desired }) {
            _ui.update { st -> st.copy(workTaskPaddocks = st.workTaskPaddocks.filterNot { it.id == rowToRemove.id }) }
            // Never-synced row: drop its queued create locally, no server delete.
            if (workTaskPaddockSync.cancelLocalCreate(rowToRemove.id)) continue
            if (!online) {
                workTaskPaddockSync.enqueueDelete(rowToRemove.id, taskId)
            } else {
                viewModelScope.launch {
                    try {
                        workTaskPaddockRepo.softDelete(rowToRemove.id)
                    } catch (e: BackendError.Unauthorized) {
                        signOut()
                    } catch (e: Exception) {
                        workTaskPaddockSync.enqueueDelete(rowToRemove.id, taskId)
                    }
                }
            }
        }
    }

    /**
     * Edit an existing work task's details (Android Stage J-2 — offline/retryable;
     * no completion changes here). The edit is applied optimistically first, then
     * resolved by path:
     *
     *  - Edit-before-create: if the same task still has an unresolved create, the
     *    edit (with its unchanged finalize state) is folded into that create
     *    payload (no UPDATE marker) so the eventual insert carries the latest
     *    values; Sync Status stays "Work task".
     *  - Known-offline: skip the network and enqueue/coalesce one WORK_TASK /
     *    UPDATE marker for automatic replay through [WorkTaskUpdateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic edit and enqueue a marker
     *    (or fold into a pending create).
     *  - Permanent (validation / permission) rejection: roll the list back and
     *    surface the error; never queued. Unauthorized signs out.
     *
     * Finalize/reopen is owned by [setWorkTaskComplete]; the labour/machine line
     * writes are parked for J-4/J-5.
     */
    fun updateWorkTask(
        taskId: String,
        taskType: String,
        paddockIds: List<String>,
        date: String,
        durationHours: Double,
        notes: String?,
        onResult: (Boolean) -> Unit,
    ) {
        val previous = _ui.value.workTasks
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        // Preserve the current finalize state — a metadata edit must not flip it,
        // and the offline marker / fold must carry it through unchanged.
        val current = previous.firstOrNull { it.id == taskId }
        val clientUpdatedAt = Instant.now().toString()
        val blocks = selectedBlocks(paddockIds)
        val paddockId = blocks.firstOrNull()?.id
        val paddockName = blockNameSnapshot(blocks)
        val trimmedType = taskType.trim()
        val trimmedNotes = notes?.ifBlank { null }
        val isFinalized = current?.isFinalized ?: false
        // Optimistic edit — the operator sees the change straight away.
        _ui.update { st ->
            st.copy(
                workTasks = st.workTasks.map {
                    if (it.id == taskId) it.copy(
                        paddockId = paddockId,
                        paddockName = paddockName,
                        date = date,
                        taskType = trimmedType,
                        durationHours = durationHours,
                        notes = trimmedNotes,
                    ) else it
                },
                workTaskError = null,
            )
        }
        // Reconcile the multi-block join rows independently of the header metadata
        // path — queued behind a not-yet-synced header create, online otherwise.
        reconcileWorkTaskPaddocks(taskId, vineyardId, paddockIds)

        // Edit-before-create: fold into the still-pending create rather than
        // queueing a separate UPDATE (and never PATCH a row that doesn't exist).
        if (workTaskCreateSync.foldEdit(taskId, paddockId, paddockName, date, trimmedType, durationHours, trimmedNotes, isFinalized, clientUpdatedAt)) {
            _ui.update { it.copy(workTaskError = "Work task edit saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        // Known-offline: queue the update marker without touching the network.
        if (!_ui.value.isOnline) {
            workTaskUpdateSync.enqueue(taskId, paddockId, paddockName, date, trimmedType, durationHours, trimmedNotes, isFinalized, current?.finalizedAt, current?.finalizedBy, clientUpdatedAt)
            _ui.update { it.copy(workTaskError = "Work task edit saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                val updated = workTaskRepo.updateMetadata(
                    id = taskId,
                    paddockId = paddockId,
                    paddockName = paddockName,
                    date = date,
                    taskType = trimmedType,
                    durationHours = durationHours,
                    notes = trimmedNotes,
                    clientUpdatedAt = clientUpdatedAt,
                )
                _ui.update { st -> st.copy(workTasks = st.workTasks.map { if (it.id == taskId) updated else it }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic edit
                // back, surface, don't queue as retryable.
                _ui.update { it.copy(workTasks = previous, workTaskError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic edit and queue
                // an update marker for automatic replay rather than rolling back.
                workTaskUpdateSync.enqueue(taskId, paddockId, paddockName, date, trimmedType, durationHours, trimmedNotes, isFinalized, current?.finalizedAt, current?.finalizedBy, clientUpdatedAt)
                _ui.update { it.copy(workTaskError = "Work task edit saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Mark a work task complete or reopen it (Android Stage J-2 —
     * offline/retryable), with an optimistic flip. The new finalize state is
     * applied immediately, then resolved by path:
     *
     *  - Finalize-before-create: if the same task still has an unresolved create,
     *    the finalize state (with the task's current metadata) is folded into
     *    that create payload (no UPDATE marker) so the insert lands finalized.
     *  - Known-offline: skip the network and enqueue/coalesce one WORK_TASK /
     *    UPDATE marker carrying the new finalize state plus current metadata.
     *  - Online success: reconcile by id; no marker.
     *  - Transient online failure: keep the optimistic flip and enqueue a marker.
     *  - Permanent (validation / permission) rejection: roll the list back and
     *    surface the error. Unauthorized signs out.
     */
    fun setWorkTaskComplete(taskId: String, complete: Boolean, onResult: (Boolean) -> Unit = {}) {
        val previous = _ui.value.workTasks
        val current = previous.firstOrNull { it.id == taskId }
        val clientUpdatedAt = Instant.now().toString()
        val finalizedAt = if (complete) clientUpdatedAt else null
        val finalizedBy = if (complete) session.userId else null
        _ui.update { st ->
            st.copy(
                workTasks = st.workTasks.map {
                    if (it.id == taskId) it.copy(isFinalized = complete, finalizedAt = finalizedAt, finalizedBy = finalizedBy) else it
                },
                workTaskError = null,
            )
        }

        // Finalize-before-create: fold the new state into the still-pending
        // create rather than queueing a separate UPDATE.
        if (current != null && workTaskCreateSync.foldEdit(taskId, current.paddockId, current.paddockName, current.date ?: "", current.taskType ?: "", current.durationHours, current.notes, complete, clientUpdatedAt)) {
            _ui.update { it.copy(workTaskError = "Work task update saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        // Known-offline: queue the update marker without touching the network.
        if (!_ui.value.isOnline) {
            workTaskUpdateSync.enqueue(taskId, current?.paddockId, current?.paddockName, current?.date ?: "", current?.taskType ?: "", current?.durationHours ?: 0.0, current?.notes, complete, finalizedAt, finalizedBy, clientUpdatedAt)
            _ui.update { it.copy(workTaskError = "Work task update saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                val updated = workTaskRepo.setFinalized(taskId, complete, clientUpdatedAt)
                _ui.update { st -> st.copy(workTasks = st.workTasks.map { if (it.id == taskId) updated else it }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(workTasks = previous, workTaskError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic flip and queue
                // an update marker for automatic replay rather than rolling back.
                workTaskUpdateSync.enqueue(taskId, current?.paddockId, current?.paddockName, current?.date ?: "", current?.taskType ?: "", current?.durationHours ?: 0.0, current?.notes, complete, finalizedAt, finalizedBy, clientUpdatedAt)
                _ui.update { it.copy(workTaskError = "Work task update saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Soft-delete a work task (Android Stage J-3), optimistically removing it.
     * Paths:
     *  - Local-only offline-created task (unresolved WORK_TASK / CREATE marker):
     *    cancel the queued create and any same-task update, drop the optimistic
     *    row, and never call the server delete RPC — so [WorkTaskCreateSync] can
     *    never resurrect a task the operator deleted before it ever synced.
     *  - Known-offline synced task: optimistically hide, enqueue one WORK_TASK /
     *    DELETE marker, and show a friendly message.
     *  - Online synced task: optimistically hide and call the soft-delete RPC.
     *    A transient failure keeps the hide and queues a marker; a permanent
     *    validation/permission rejection restores the row and surfaces an error.
     */
    fun deleteWorkTask(taskId: String, onResult: (Boolean) -> Unit) {
        // Local-only offline-created task: cancel the queued create (and any
        // same-task update) instead of sending a server delete, so
        // WorkTaskCreateSync can never resurrect it. The task never existed
        // server-side, so its queued labour markers (Stage J-4) and machine
        // markers (Stage J-5) are dropped too — they reference a parent that will
        // never exist.
        val pendingCreate = pendingWrites.list().firstOrNull {
            it.entityType == PendingEntityType.WORK_TASK &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == taskId &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (pendingCreate != null) {
            pendingWrites.remove(pendingCreate.id)
            pendingWrites.list()
                .filter {
                    it.entityType == PendingEntityType.WORK_TASK &&
                        it.opType == PendingOpType.UPDATE &&
                        it.clientId == taskId &&
                        it.status != PendingWriteStatus.SYNCED
                }
                .forEach { pendingWrites.remove(it.id) }
            // Drop any queued labour, machine & paddock-join markers for this
            // never-synced task and clear its optimistic lines / join rows. The
            // task never existed server-side, so none of its children did either.
            workTaskLabourSync.cleanupForWorkTask(taskId)
            workTaskMachineSync.cleanupForWorkTask(taskId)
            workTaskPaddockSync.cleanupForWorkTask(taskId)
            _ui.update { st ->
                st.copy(
                    workTasks = st.workTasks.filterNot { it.id == taskId },
                    workTaskPaddocks = st.workTaskPaddocks.filterNot { it.workTaskId == taskId },
                    taskLabourLines = if (st.taskLinesTaskId == taskId) emptyList() else st.taskLabourLines,
                    taskMachineLines = if (st.taskLinesTaskId == taskId) emptyList() else st.taskMachineLines,
                )
            }
            onResult(true)
            return
        }

        val previous = _ui.value.workTasks
        // Optimistic hide for a synced task.
        _ui.update { st -> st.copy(workTasks = st.workTasks.filterNot { it.id == taskId }) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            workTaskDeleteSync.enqueue(taskId)
            sweepWorkTaskChildMarkers(taskId)
            _ui.update { it.copy(workTaskError = "Work task deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                workTaskRepo.softDeleteWorkTask(taskId)
                sweepWorkTaskChildMarkers(taskId)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll back, surface, don't queue.
                // No child-marker sweep: the delete didn't happen, so any queued
                // labour/machine edits must survive.
                _ui.update { it.copy(workTasks = previous, workTaskError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                workTaskDeleteSync.enqueue(taskId)
                sweepWorkTaskChildMarkers(taskId)
                _ui.update { it.copy(workTaskError = "Work task deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Sweep unresolved same-task child-line markers when a SYNCED work task is
     * being deleted (Android Stage J-6). Once the header soft-delete is committed
     * (queued offline, queued after a transient failure, or applied online), any
     * still-pending labour/machine line create/update/delete for that task is
     * moot: a create would insert a line under a row that's being removed, and an
     * edit/delete targets a line that's going away with its parent. Dropping only
     * the UNRESOLVED markers (never synced history — [WorkTaskLabourSync.cleanupForWorkTask]
     * / [WorkTaskMachineSync.cleanupForWorkTask] filter on status != SYNCED) keeps
     * the outbox tidy without any extra server writes. Optimistic line lists are
     * cleared too when that task's detail is still open. Never called on the
     * permanent-failure rollback path, where the task survives and its edits must
     * be preserved.
     */
    private fun sweepWorkTaskChildMarkers(taskId: String) {
        workTaskLabourSync.cleanupForWorkTask(taskId)
        workTaskMachineSync.cleanupForWorkTask(taskId)
        // Soft-delete the task's synced paddock-join rows so they don't linger
        // active under a removed header; never-synced rows have their queued
        // create cancelled locally. Online deletes go straight out; offline /
        // transient failures fall back to the WORK_TASK_PADDOCK delete queue.
        val joinRows = _ui.value.workTaskPaddocks.filter { it.workTaskId == taskId }
        _ui.update { st -> st.copy(workTaskPaddocks = st.workTaskPaddocks.filterNot { it.workTaskId == taskId }) }
        for (row in joinRows) {
            if (workTaskPaddockSync.cancelLocalCreate(row.id)) continue
            if (_ui.value.isOnline) {
                viewModelScope.launch {
                    runCatching { workTaskPaddockRepo.softDelete(row.id) }
                        .onFailure { workTaskPaddockSync.enqueueDelete(row.id, taskId) }
                }
            } else {
                workTaskPaddockSync.enqueueDelete(row.id, taskId)
            }
        }
        _ui.update { st ->
            if (st.taskLinesTaskId != taskId) return@update st
            st.copy(taskLabourLines = emptyList(), taskMachineLines = emptyList())
        }
    }

    fun clearWorkTaskError() {
        _ui.update { it.copy(workTaskError = null) }
    }

    // MARK: - Work task costing lines (labour + machine)

    /**
     * Load the labour & machine lines for a task opened in detail. Each list
     * soft-fails independently so a single failure doesn't blank the screen.
     */
    fun loadTaskLines(taskId: String) {
        _ui.update {
            it.copy(
                taskLinesTaskId = taskId,
                taskLinesLoading = true,
                taskLineError = null,
                // Clear stale lines when switching tasks.
                taskLabourLines = if (it.taskLinesTaskId == taskId) it.taskLabourLines else emptyList(),
                taskMachineLines = if (it.taskLinesTaskId == taskId) it.taskMachineLines else emptyList(),
            )
        }
        viewModelScope.launch {
            val userId = session.userId
            // Server reads: null on soft-failure so we can fall back to cache.
            val serverLabour = try {
                workTaskLineRepo.listLabourLines(taskId)
            } catch (e: BackendError.Unauthorized) {
                signOut(); return@launch
            } catch (_: Exception) {
                null
            }
            val serverMachine = try {
                workTaskLineRepo.listMachineLines(taskId)
            } catch (e: BackendError.Unauthorized) {
                signOut(); return@launch
            } catch (_: Exception) {
                null
            }
            // Write-through (Stage P-3): persist only genuinely fresh server reads,
            // keyed by task id (child lines load per task), before the overlay so
            // the cache stays a clean server snapshot.
            if (serverLabour != null) domainCache.saveLabourLines(userId, taskId, serverLabour)
            if (serverMachine != null) domainCache.saveMachineLines(userId, taskId, serverMachine)
            // Baseline: server success, else existing same-task state, else the
            // task-scoped cache, else empty.
            var labourFromCache = false
            val labourBaseline = serverLabour
                ?: _ui.value.taskLabourLines.ifEmpty {
                    domainCache.loadLabourLines(userId, taskId)?.also { labourFromCache = true } ?: emptyList()
                }
            var machineFromCache = false
            val machineBaseline = serverMachine
                ?: _ui.value.taskMachineLines.ifEmpty {
                    domainCache.loadMachineLines(userId, taskId)?.also { machineFromCache = true } ?: emptyList()
                }
            // Parent gate: child lines are only shown when the parent header is in
            // the visible (already-overlaid) set — orphan rows are never surfaced.
            val visibleWorkTaskIds = _ui.value.workTasks.mapTo(HashSet()) { it.id }
            val pendingSnapshot = pendingWrites.list()
            val overlaidLabour = PendingWriteOverlay.overlayLabourLines(
                labourBaseline, pendingSnapshot, visibleWorkTaskIds, taskId,
            )
            val overlaidMachine = PendingWriteOverlay.overlayMachineLines(
                machineBaseline, pendingSnapshot, visibleWorkTaskIds, taskId,
            )
            _ui.update { st ->
                if (st.taskLinesTaskId != taskId) return@update st
                st.copy(
                    taskLabourLines = overlaidLabour,
                    taskMachineLines = overlaidMachine,
                    taskLinesLoading = false,
                    // Only a genuine read failure with no cache baseline is an error.
                    taskLineError = if (
                        serverLabour == null && serverMachine == null &&
                        !labourFromCache && !machineFromCache &&
                        overlaidLabour.isEmpty() && overlaidMachine.isEmpty()
                    ) {
                        "Couldn't load cost lines. Check your connection."
                    } else null,
                    // Surface the saved-field banner when lines came from cache.
                    isUsingCachedFieldData = st.isUsingCachedFieldData || labourFromCache || machineFromCache,
                    cachedFieldDataLastSyncedAt = if (labourFromCache || machineFromCache) {
                        st.cachedFieldDataLastSyncedAt
                            ?: domainCache.labourLinesSyncedAt(userId, taskId)
                            ?: domainCache.machineLinesSyncedAt(userId, taskId)
                    } else {
                        st.cachedFieldDataLastSyncedAt
                    },
                )
            }
        }
    }

    fun clearTaskLines() {
        _ui.update {
            it.copy(
                taskLinesTaskId = null,
                taskLabourLines = emptyList(),
                taskMachineLines = emptyList(),
                taskLineError = null,
            )
        }
    }

    fun clearTaskLineError() {
        _ui.update { it.copy(taskLineError = null) }
    }

    /**
     * Create or update a labour line (Android Stage J-4 offline queue). The id and
     * client_updated_at are minted up front for new lines so the same id is shared
     * by the optimistic local row, the queued WORK_TASK_LABOUR marker, and the
     * eventual server upsert. Paths:
     *
     *  - Optimistic: add/replace the line in the open task's list immediately so
     *    the operator sees it (with local resolved hours/cost until the server
     *    returns DB totals).
     *  - Known-offline: skip the network and fold into a pending create
     *    ([WorkTaskLabourSync.foldCreate]) or enqueue a create (new line) /
     *    update (synced line) for automatic replay.
     *  - Online success: reconcile the optimistic row with the returned server
     *    row (DB-computed totals); no marker.
     *  - Transient online failure: keep the optimistic row and queue/fold.
     *  - Permanent (validation / permission) rejection: restore the previous line
     *    state and surface the error; never queued as retryable. Unauthorized
     *    signs out.
     *
     * The parent gate lives in [WorkTaskLabourSync]: a line queued against an
     * offline-created task defers until the work-task header create has synced.
     */
    fun saveLabourLine(
        lineId: String?,
        taskId: String,
        workDate: String,
        operatorCategoryId: String?,
        workerType: String,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        notes: String?,
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = lineId ?: workTaskLineRepo.newLineId()
        val clientUpdatedAt = Instant.now().toString()
        val trimmedType = workerType.trim()
        val trimmedNotes = notes?.ifBlank { null }
        // Snapshot the current lines for rollback (covers both create and update).
        val previous = _ui.value.taskLabourLines
        val optimistic = WorkTaskLabourLine(
            id = id,
            workTaskId = taskId,
            vineyardId = vineyardId,
            workDate = workDate,
            operatorCategoryId = operatorCategoryId,
            workerType = trimmedType,
            workerCount = workerCount.coerceAtLeast(0),
            hoursPerWorker = hoursPerWorker.coerceAtLeast(0.0),
            hourlyRate = hourlyRate,
            // DB-generated totals are unknown until sync — leave null so the
            // model's resolvedHours/resolvedCost fall back to local products.
            totalHours = null,
            totalCost = null,
            notes = trimmedNotes ?: "",
        )
        // Optimistic add/replace, but only while the matching task is open.
        _ui.update { st ->
            if (st.taskLinesTaskId != taskId) return@update st
            val others = st.taskLabourLines.filterNot { it.id == id }
            st.copy(taskLabourLines = others + optimistic, taskLineError = null)
        }

        fun queueOffline() {
            val folded = workTaskLabourSync.foldCreate(
                id, taskId, vineyardId, workDate, operatorCategoryId,
                trimmedType, workerCount, hoursPerWorker, hourlyRate, trimmedNotes, clientUpdatedAt,
            )
            if (!folded) {
                if (lineId == null) {
                    workTaskLabourSync.enqueueCreate(
                        id, taskId, vineyardId, workDate, operatorCategoryId,
                        trimmedType, workerCount, hoursPerWorker, hourlyRate, trimmedNotes, clientUpdatedAt,
                    )
                } else {
                    workTaskLabourSync.enqueueUpdate(
                        id, taskId, vineyardId, workDate, operatorCategoryId,
                        trimmedType, workerCount, hoursPerWorker, hourlyRate, trimmedNotes, clientUpdatedAt,
                    )
                }
            }
        }

        // Known-offline: queue without touching the network.
        if (!_ui.value.isOnline) {
            queueOffline()
            _ui.update { it.copy(taskLineError = "Labour line saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(taskLineBusy = true) }
            try {
                val saved = workTaskLineRepo.upsertLabourLine(
                    id = id,
                    workTaskId = taskId,
                    vineyardId = vineyardId,
                    workDate = workDate,
                    operatorCategoryId = operatorCategoryId,
                    workerType = trimmedType,
                    workerCount = workerCount,
                    hoursPerWorker = hoursPerWorker,
                    hourlyRate = hourlyRate,
                    notes = trimmedNotes,
                    clientUpdatedAt = clientUpdatedAt,
                )
                _ui.update { st ->
                    val others = st.taskLabourLines.filterNot { it.id == saved.id }
                    st.copy(taskLabourLines = others + saved, taskLineBusy = false)
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(taskLineBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — restore previous lines,
                // surface, don't queue as retryable.
                _ui.update { it.copy(taskLabourLines = previous, taskLineBusy = false, taskLineError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic row and queue/fold.
                queueOffline()
                _ui.update { it.copy(taskLineBusy = false, taskLineError = "Labour line saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Soft-delete a labour line (Android Stage J-4), optimistically removing it.
     * Paths:
     *  - Never-synced offline line (unresolved WORK_TASK_LABOUR / CREATE): cancel
     *    the queued create and any same-line update, drop the optimistic row, and
     *    never call the server delete RPC.
     *  - Known-offline synced line: optimistically hide, enqueue one
     *    WORK_TASK_LABOUR / DELETE marker, and show a friendly message.
     *  - Online synced line: optimistically hide and call the soft-delete RPC. A
     *    transient failure keeps the hide and queues a marker; a permanent
     *    rejection restores the line and surfaces an error.
     */
    fun deleteLabourLine(lineId: String, onResult: (Boolean) -> Unit = {}) {
        val previous = _ui.value.taskLabourLines
        // Resolve the parent task id from the line (fallback to the open task).
        val workTaskId = previous.firstOrNull { it.id == lineId }?.workTaskId
            ?: _ui.value.taskLinesTaskId

        // Never-synced offline line: cancel the queued create/update locally so
        // WorkTaskLabourSync can never resurrect a line the operator removed.
        if (workTaskLabourSync.cancelLocalCreate(lineId)) {
            _ui.update { st -> st.copy(taskLabourLines = st.taskLabourLines.filterNot { it.id == lineId }) }
            onResult(true)
            return
        }

        _ui.update { st -> st.copy(taskLabourLines = st.taskLabourLines.filterNot { it.id == lineId }) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            if (workTaskId != null) workTaskLabourSync.enqueueDelete(lineId, workTaskId)
            _ui.update { it.copy(taskLineError = "Labour line removed offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                workTaskLineRepo.deleteLabourLine(lineId)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(taskLabourLines = previous, taskLineError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                if (workTaskId != null) workTaskLabourSync.enqueueDelete(lineId, workTaskId)
                _ui.update { it.copy(taskLineError = "Labour line removed offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Create or update a machine line (Android Stage J-5 offline queue). The id
     * and client_updated_at are minted up front for new lines so the same id is
     * shared by the optimistic local row, the queued WORK_TASK_MACHINE marker,
     * and the eventual server upsert. Paths (mirrors [saveLabourLine]):
     *
     *  - Optimistic: add/replace the line in the open task's list immediately so
     *    the operator sees it (with local resolved cost until the server returns
     *    DB totals).
     *  - Known-offline: skip the network and fold into a pending create
     *    ([WorkTaskMachineSync.foldCreate]) or enqueue a create (new line) /
     *    update (synced line) for automatic replay.
     *  - Online success: reconcile the optimistic row with the returned server
     *    row (DB-computed totals); no marker.
     *  - Transient online failure: keep the optimistic row and queue/fold.
     *  - Permanent (validation / permission) rejection: restore the previous line
     *    state and surface the error; never queued as retryable. Unauthorized
     *    signs out.
     *
     * The parent gate lives in [WorkTaskMachineSync]: a line queued against an
     * offline-created task defers until the work-task header create has synced.
     */
    fun saveMachineLine(
        lineId: String?,
        taskId: String,
        workDate: String,
        equipmentRefId: String?,
        equipmentNameSnapshot: String,
        operatorCategoryId: String?,
        durationHours: Double?,
        fuelLitres: Double?,
        fuelCost: Double?,
        hourlyMachineRate: Double?,
        totalMachineCost: Double?,
        notes: String?,
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = lineId ?: workTaskLineRepo.newLineId()
        val clientUpdatedAt = Instant.now().toString()
        val trimmedSnapshot = equipmentNameSnapshot.trim()
        val trimmedNotes = notes?.ifBlank { null }
        // `equipment_source` mirrors the repository's derivation (linked machine
        // vs free-text snapshot) so the optimistic row matches the eventual save.
        val source = if (equipmentRefId != null) "vineyard_machine" else "free_text"
        // Snapshot the current lines for rollback (covers both create and update).
        val previous = _ui.value.taskMachineLines
        val optimistic = WorkTaskMachineLine(
            id = id,
            workTaskId = taskId,
            vineyardId = vineyardId,
            workDate = workDate,
            equipmentSource = source,
            equipmentRefId = equipmentRefId,
            equipmentNameSnapshot = trimmedSnapshot,
            operatorCategoryId = operatorCategoryId,
            durationHours = durationHours,
            fuelLitres = fuelLitres,
            fuelCost = fuelCost,
            hourlyMachineRate = hourlyMachineRate,
            // DB may recompute the total — leave the caller's value (or null) so
            // the model's resolvedCost falls back to the local derivation.
            totalMachineCost = totalMachineCost,
            notes = trimmedNotes ?: "",
        )
        // Optimistic add/replace, but only while the matching task is open.
        _ui.update { st ->
            if (st.taskLinesTaskId != taskId) return@update st
            val others = st.taskMachineLines.filterNot { it.id == id }
            st.copy(taskMachineLines = others + optimistic, taskLineError = null)
        }

        fun queueOffline() {
            val folded = workTaskMachineSync.foldCreate(
                id, taskId, vineyardId, workDate, equipmentRefId, trimmedSnapshot,
                operatorCategoryId, durationHours, fuelLitres, fuelCost, hourlyMachineRate,
                totalMachineCost, trimmedNotes, clientUpdatedAt,
            )
            if (!folded) {
                if (lineId == null) {
                    workTaskMachineSync.enqueueCreate(
                        id, taskId, vineyardId, workDate, equipmentRefId, trimmedSnapshot,
                        operatorCategoryId, durationHours, fuelLitres, fuelCost, hourlyMachineRate,
                        totalMachineCost, trimmedNotes, clientUpdatedAt,
                    )
                } else {
                    workTaskMachineSync.enqueueUpdate(
                        id, taskId, vineyardId, workDate, equipmentRefId, trimmedSnapshot,
                        operatorCategoryId, durationHours, fuelLitres, fuelCost, hourlyMachineRate,
                        totalMachineCost, trimmedNotes, clientUpdatedAt,
                    )
                }
            }
        }

        // Known-offline: queue without touching the network.
        if (!_ui.value.isOnline) {
            queueOffline()
            _ui.update { it.copy(taskLineError = "Machine line saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(taskLineBusy = true, taskLineError = null) }
            try {
                val saved = workTaskLineRepo.upsertMachineLine(
                    id = id,
                    workTaskId = taskId,
                    vineyardId = vineyardId,
                    workDate = workDate,
                    equipmentRefId = equipmentRefId,
                    equipmentNameSnapshot = trimmedSnapshot,
                    operatorCategoryId = operatorCategoryId,
                    durationHours = durationHours,
                    fuelLitres = fuelLitres,
                    fuelCost = fuelCost,
                    hourlyMachineRate = hourlyMachineRate,
                    totalMachineCost = totalMachineCost,
                    notes = trimmedNotes,
                    clientUpdatedAt = clientUpdatedAt,
                )
                _ui.update { st ->
                    val others = st.taskMachineLines.filterNot { it.id == saved.id }
                    st.copy(taskMachineLines = others + saved, taskLineBusy = false)
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(taskLineBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — restore previous lines,
                // surface, don't queue as retryable.
                _ui.update { it.copy(taskMachineLines = previous, taskLineBusy = false, taskLineError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic row and queue/fold.
                queueOffline()
                _ui.update { it.copy(taskLineBusy = false, taskLineError = "Machine line saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Soft-delete a machine line (Android Stage J-5), optimistically removing it.
     * Paths (mirrors [deleteLabourLine]):
     *  - Never-synced offline line (unresolved WORK_TASK_MACHINE / CREATE): cancel
     *    the queued create and any same-line update, drop the optimistic row, and
     *    never call the server delete RPC.
     *  - Known-offline synced line: optimistically hide, enqueue one
     *    WORK_TASK_MACHINE / DELETE marker, and show a friendly message.
     *  - Online synced line: optimistically hide and call the soft-delete RPC. A
     *    transient failure keeps the hide and queues a marker; a permanent
     *    rejection restores the line and surfaces an error.
     */
    fun deleteMachineLine(lineId: String, onResult: (Boolean) -> Unit = {}) {
        val previous = _ui.value.taskMachineLines
        // Resolve the parent task id from the line (fallback to the open task).
        val workTaskId = previous.firstOrNull { it.id == lineId }?.workTaskId
            ?: _ui.value.taskLinesTaskId

        // Never-synced offline line: cancel the queued create/update locally so
        // WorkTaskMachineSync can never resurrect a line the operator removed.
        if (workTaskMachineSync.cancelLocalCreate(lineId)) {
            _ui.update { st -> st.copy(taskMachineLines = st.taskMachineLines.filterNot { it.id == lineId }) }
            onResult(true)
            return
        }

        _ui.update { st -> st.copy(taskMachineLines = st.taskMachineLines.filterNot { it.id == lineId }) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            if (workTaskId != null) workTaskMachineSync.enqueueDelete(lineId, workTaskId)
            _ui.update { it.copy(taskLineError = "Machine line removed offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                workTaskLineRepo.deleteMachineLine(lineId)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(taskMachineLines = previous, taskLineError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                if (workTaskId != null) workTaskMachineSync.enqueueDelete(lineId, workTaskId)
                _ui.update { it.copy(taskLineError = "Machine line removed offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    // MARK: - Spray record write path

    /**
     * Log a new spray record (Android Stage I-1 — offline/retryable) for the
     * plain spray-record create path only. The id and client_updated_at are
     * minted up front so the same id is shared by the optimistic local row, the
     * queued SPRAY_RECORD / CREATE marker, and the eventual server insert. Paths:
     *
     *  - Optimistic: prepend the record immediately so the operator sees it.
     *  - Known-offline: skip the network and enqueue one create marker for
     *    automatic replay through [SprayRecordCreateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic row and enqueue a marker.
     *  - Permanent (validation / permission) rejection: roll the optimistic row
     *    back and surface the error; never queued as retryable. Unauthorized
     *    signs out.
     *
     * The trip-coupled spray-create variants ([createSprayJobForLater] etc.)
     * remain on their existing online behaviour — they must create a trip first,
     * which is not queued in I-1.
     */
    fun createSprayRecord(input: SprayRecordRepository.SprayInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = sprayRepo.newId()
        val clientUpdatedAt = Instant.now().toString()
        val optimistic = SprayRecord(
            id = id,
            vineyardId = vineyardId,
            tripId = input.tripId,
            date = input.date,
            startTime = input.startTime,
            temperature = input.temperature,
            windSpeed = input.windSpeed,
            windDirection = input.windDirection,
            humidity = input.humidity,
            sprayReference = input.sprayReference,
            notes = input.notes,
            numberOfFansJets = input.numberOfFansJets,
            averageSpeed = input.averageSpeed,
            equipmentType = input.equipmentType,
            tractor = input.tractor,
            tractorGear = input.tractorGear,
            machineId = input.machineId,
            sprayEquipmentId = input.sprayEquipmentId,
            isTemplate = input.isTemplate,
            operationType = input.operationType,
            tanks = input.tanks,
        )
        // Optimistic insert at the top — the operator sees the record straight away.
        _ui.update { it.copy(sprayRecords = listOf(optimistic) + it.sprayRecords, sprayError = null) }

        // Known-offline: queue the create marker without touching the network.
        if (!_ui.value.isOnline) {
            sprayCreateSync.enqueue(id, vineyardId, input, clientUpdatedAt)
            _ui.update { it.copy(sprayError = "Spray record saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(sprayBusy = true) }
            try {
                val created = sprayRepo.createSprayRecord(vineyardId, input, id, clientUpdatedAt)
                _ui.update { st -> st.copy(sprayRecords = st.sprayRecords.map { if (it.id == id) created else it }, sprayBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(sprayBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic row
                // back, surface, don't queue as retryable.
                _ui.update { st -> st.copy(sprayBusy = false, sprayRecords = st.sprayRecords.filterNot { it.id == id }, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic row and queue a
                // create marker for automatic replay rather than rolling back.
                sprayCreateSync.enqueue(id, vineyardId, input, clientUpdatedAt)
                _ui.update { it.copy(sprayBusy = false, sprayError = "Spray record saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Save a calculator result as a "Not Started" spray job: create an inactive
     * spray trip first (so the record shows under "Not Started" rather than as a
     * standalone record), then create the spray record linked to it via
     * [SprayRecordRepository.SprayInput.tripId]. Mirrors the iOS
     * `SprayCalculatorView.saveForLater` flow (placeholder inactive trip + linked
     * record). The [input]'s `tripId` is overwritten with the new trip's id.
     *
     * If the trip is created but the record insert fails, the orphan trip is
     * rolled back via the existing `soft_delete_trip` RPC so no empty "Not
     * Started" job is left behind.
     */
    fun createSprayJobForLater(
        input: SprayRecordRepository.SprayInput,
        paddockId: String?,
        paddockName: String?,
        rowPlan: SprayJobRowPlan? = null,
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(sprayBusy = true, sprayError = null) }
            var trip: Trip? = null
            try {
                trip = tripRepo.createImportedTrip(
                    vineyardId = vineyardId,
                    paddockId = paddockId,
                    paddockName = paddockName?.ifBlank { null },
                    personName = null,
                    startTime = input.startTime,
                    endTime = null,
                )
                val created = sprayRepo.createSprayRecord(vineyardId, input.copy(tripId = trip.id))
                // Seed the planned row sequence onto the new inactive trip. A
                // failure here is non-fatal: the spray job is already saved, so
                // we keep it and surface a soft warning rather than rolling back.
                var seededTrip: Trip = trip
                var rowPlanWarning: String? = null
                if (rowPlan != null) {
                    try {
                        seededTrip = tripRepo.updateTripRowPlan(
                            id = trip.id,
                            trackingPattern = rowPlan.trackingPattern,
                            rowSequence = rowPlan.rowSequence,
                            sequenceIndex = 0,
                            totalTanks = rowPlan.totalTanks,
                        )
                    } catch (e: Exception) {
                        android.util.Log.e("AppViewModel", "Failed to seed spray job row plan", e)
                        rowPlanWarning = "Spray job saved, but the row plan couldn't be stored. You can set it when starting the job."
                    }
                }
                _ui.update {
                    it.copy(
                        sprayBusy = false,
                        sprayError = rowPlanWarning,
                        trips = listOf(seededTrip) + it.trips,
                        sprayRecords = listOf(created) + it.sprayRecords,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(sprayBusy = false) }; signOut(); onResult(false)
            } catch (e: Exception) {
                // Roll back the orphan trip so no empty "Not Started" job lingers.
                trip?.let { t ->
                    try {
                        tripRepo.softDeleteTrip(t.id)
                    } catch (cleanup: Exception) {
                        android.util.Log.e("AppViewModel", "Failed to roll back spray job trip", cleanup)
                    }
                }
                val message = (e as? BackendError.Server)?.let { friendlyWriteError(it.code) }
                    ?: "Couldn't save the spray job. Check your connection."
                _ui.update { it.copy(sprayBusy = false, sprayError = message) }
                onResult(false)
            }
        }
    }

    /**
     * Start a calculator-created "Not Started" spray job: activate the existing
     * linked inactive trip in place (no new trip is created), then begin the
     * normal foreground GPS capture. The spray record then resolves to
     * In Progress automatically because its linked trip becomes active.
     *
     * Refuses to start when another trip is already active so we never run two
     * concurrent trackers, mirroring the manual-start rule (the Trips FAB is
     * hidden while a trip is active).
     */
    fun startSprayJob(tripId: String, onResult: (Boolean) -> Unit) {
        val existing = _ui.value.trips.firstOrNull { it.id == tripId }
        if (existing == null) {
            _ui.update { it.copy(sprayError = "This spray job's trip is no longer available.") }
            onResult(false); return
        }
        if (existing.isActive) { onResult(true); return }
        val active = _ui.value.activeTrip
        if (active != null) {
            _ui.update { it.copy(sprayError = "Finish the active trip before starting another spray job.") }
            onResult(false); return
        }
        viewModelScope.launch {
            _ui.update { it.copy(tripBusy = true, tripError = null, sprayError = null) }
            try {
                val activated = tripRepo.activateTrip(tripId)
                _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == tripId) activated else it }, tripBusy = false) }
                beginTracking(activated)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(tripBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(tripBusy = false, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(tripBusy = false, sprayError = "Couldn't start the spray job. Check your connection.") }
                onResult(false)
            }
        }
    }

    /**
     * Calculate a spray job and start it immediately as an active trip
     * (Spray Calculator → Start now). Reuses the same primitives as Save job
     * for later, but creates an already-active trip and begins GPS capture:
     *
     *  1. refuse if another trip is already active (same rule as [startSprayJob]),
     *  2. create an active spraying trip via [TripRepository.createTrip],
     *  3. create the linked spray record (so it resolves to In Progress),
     *  4. seed the row plan via [TripRepository.updateTripRowPlan] (non-fatal),
     *  5. begin foreground tracking through the normal [beginTracking] path.
     *
     * If the trip is created but the record insert fails, the orphan trip is
     * rolled back. A row-plan seed failure is non-fatal: the started job is
     * kept and a soft warning is surfaced.
     */
    fun startSprayJobNow(
        input: SprayRecordRepository.SprayInput,
        paddockId: String?,
        paddockName: String?,
        rowPlan: SprayJobRowPlan? = null,
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        if (_ui.value.activeTrip != null) {
            _ui.update { it.copy(sprayError = "Finish the active trip before starting another spray job.") }
            onResult(false); return
        }
        viewModelScope.launch {
            _ui.update { it.copy(sprayBusy = true, tripBusy = true, sprayError = null, tripError = null) }
            var trip: Trip? = null
            try {
                trip = tripRepo.createTrip(
                    vineyardId = vineyardId,
                    paddockId = paddockId,
                    paddockName = paddockName?.ifBlank { null },
                    personName = null,
                    tripFunction = null,
                    tripTitle = paddockName?.ifBlank { null },
                )
                val created = sprayRepo.createSprayRecord(vineyardId, input.copy(tripId = trip.id))
                // Seed the planned row sequence onto the new active trip. A
                // failure here is non-fatal: the trip is already started, so we
                // keep it and surface a soft warning rather than rolling back.
                var seededTrip: Trip = trip
                var rowPlanWarning: String? = null
                if (rowPlan != null) {
                    try {
                        seededTrip = tripRepo.updateTripRowPlan(
                            id = trip.id,
                            trackingPattern = rowPlan.trackingPattern,
                            rowSequence = rowPlan.rowSequence,
                            sequenceIndex = 0,
                            totalTanks = rowPlan.totalTanks,
                        )
                    } catch (e: Exception) {
                        android.util.Log.e("AppViewModel", "Failed to seed spray job row plan", e)
                        rowPlanWarning = "Spray job started, but the row plan couldn't be stored. You can still drive and use Free Drive."
                    }
                }
                _ui.update {
                    it.copy(
                        sprayBusy = false,
                        tripBusy = false,
                        sprayError = rowPlanWarning,
                        trips = listOf(seededTrip) + it.trips,
                        sprayRecords = listOf(created) + it.sprayRecords,
                    )
                }
                beginTracking(seededTrip)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(sprayBusy = false, tripBusy = false) }; signOut(); onResult(false)
            } catch (e: Exception) {
                // Roll back the orphan trip so no empty active job lingers.
                trip?.let { t ->
                    try {
                        tripRepo.softDeleteTrip(t.id)
                    } catch (cleanup: Exception) {
                        android.util.Log.e("AppViewModel", "Failed to roll back spray job trip", cleanup)
                    }
                }
                val message = (e as? BackendError.Server)?.let { friendlyWriteError(it.code) }
                    ?: "Couldn't start the spray job. Check your connection."
                _ui.update { it.copy(sprayBusy = false, tripBusy = false, sprayError = message) }
                onResult(false)
            }
        }
    }

    // MARK: - Manual row coverage (Stage 3D-1)

    /**
     * Mark the current planned path of the active trip as completed. Manual,
     * operator-driven only — there is no automatic GPS/row-lock completion.
     * Appends the current path to `completed_paths` (de-duplicated), removes it
     * from `skipped_paths` if it was previously skipped, then advances the
     * sequence past any already-covered paths.
     */
    fun markCurrentPathComplete(tripId: String) = applyRowCoverage(tripId, markComplete = true)

    /** Skip the current planned path of the active trip (manual only). */
    fun skipCurrentPath(tripId: String) = applyRowCoverage(tripId, markComplete = false)

    private fun applyRowCoverage(tripId: String, markComplete: Boolean) {
        val trip = _ui.value.trips.firstOrNull { it.id == tripId }
        if (trip == null || !trip.isActive) {
            _ui.update { it.copy(tripError = "No active trip to update.") }
            return
        }
        val sequence = trip.rowSequence
        val index = trip.sequenceIndex
        if (sequence.isEmpty() || index < 0 || index >= sequence.size) {
            // Free Drive / no row plan, or already at the end of the sequence.
            return
        }
        val currentPath = sequence[index]
        val completed = trip.completedPaths.orEmpty().toMutableList()
        val skipped = trip.skippedPaths.orEmpty().toMutableList()
        if (markComplete) {
            skipped.remove(currentPath)
            if (!completed.contains(currentPath)) completed.add(currentPath)
        } else {
            completed.remove(currentPath)
            if (!skipped.contains(currentPath)) skipped.add(currentPath)
        }
        // Advance past any paths already completed or skipped.
        var newIndex = index + 1
        while (newIndex < sequence.size &&
            (completed.contains(sequence[newIndex]) || skipped.contains(sequence[newIndex]))
        ) {
            newIndex++
        }
        persistCoverage(tripId, completed, skipped, newIndex, sequence)
    }

    /**
     * Undo the last manual row action: step the sequence back one, restore that
     * path as current, and clear it from both completed/skipped. No-op when at
     * the start of the sequence.
     */
    fun undoLastRowAction(tripId: String) {
        val trip = _ui.value.trips.firstOrNull { it.id == tripId }
        if (trip == null || !trip.isActive) {
            _ui.update { it.copy(tripError = "No active trip to update.") }
            return
        }
        val sequence = trip.rowSequence
        if (sequence.isEmpty() || trip.sequenceIndex <= 0) return
        val newIndex = (trip.sequenceIndex - 1).coerceIn(0, sequence.size - 1)
        val restoredPath = sequence[newIndex]
        val completed = trip.completedPaths.orEmpty().toMutableList().also { it.remove(restoredPath) }
        val skipped = trip.skippedPaths.orEmpty().toMutableList().also { it.remove(restoredPath) }
        persistCoverage(tripId, completed, skipped, newIndex, sequence)
    }

    private fun persistCoverage(
        tripId: String,
        completed: List<Double>,
        skipped: List<Double>,
        newIndex: Int,
        sequence: List<Double>,
    ) {
        // Stage B-2-1: ignore row actions for a trip the operator already ended
        // locally (its TRIP_END marker is queued) — no new coverage may accrue.
        if (tripId in _ui.value.locallyEndedTripIds) return
        val current = sequence.getOrNull(newIndex)
        val next = sequence.getOrNull(newIndex + 1)
        val previous = _ui.value.trips
        // Optimistic local update so the UI reflects the action immediately.
        _ui.update { st ->
            st.copy(
                trips = st.trips.map {
                    if (it.id == tripId) it.copy(
                        completedPaths = completed,
                        skippedPaths = skipped,
                        sequenceIndex = newIndex,
                        currentRowNumber = current,
                        nextRowNumber = next,
                    ) else it
                },
            )
        }
        // Durable local snapshot before the network round-trip so row work
        // survives a process death even if the server write later fails.
        persistActiveTripSnapshot()
        // Stage D-1: when known offline, keep the optimistic coverage change
        // (don't roll it back just because there's no network), queue/refresh a
        // coalesced TRIP_ROW marker, and surface a friendly offline message.
        // The coverage already lives in the Stage A snapshot; the marker only
        // flags that this active server trip has unsynced coverage to merge.
        val optimisticTrip = _ui.value.trips.firstOrNull { it.id == tripId }
        if (!_ui.value.isOnline) {
            if (optimisticTrip != null && optimisticTrip.isActive) tripRowSync.enqueue(optimisticTrip)
            _ui.update { it.copy(tripError = "Row coverage saved offline — it'll sync when connection returns.") }
            return
        }
        viewModelScope.launch {
            try {
                val updated = tripRepo.updateTripCoverage(tripId, completed, skipped, newIndex, current, next)
                _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == tripId) updated else it }) }
                persistActiveTripSnapshot()
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(trips = previous) }; signOut()
            } catch (e: Exception) {
                // Server write failed while we believed we were online. Keep the
                // optimistic coverage and queue a coalesced marker so the row
                // action is merged/replayed on reconnect rather than rolled back
                // and lost. Coalesced by trip id, so repeated failures never
                // bloat the outbox.
                val current2 = _ui.value.trips.firstOrNull { it.id == tripId }
                if (current2 != null && current2.isActive) tripRowSync.enqueue(current2)
                _ui.update { it.copy(tripError = "Row coverage saved offline — it'll sync when connection returns.") }
            }
        }
    }

    // MARK: - Live tank sessions (Stage 3F-2b)

    /**
     * Start a new tank session on the active spray trip. Mirrors the iOS
     * `startTank()` semantics: if a session is still open it is closed first
     * (capturing its end row), then a new session is opened with the next tank
     * number, the current time and the current planned row as its start row.
     * Sets `activeTankNumber` and clears the (parked) fill state. Manual only;
     * never touches GPS progress, row coverage or fill timing.
     */
    fun startTankSession(tripId: String) {
        val trip = _ui.value.trips.firstOrNull { it.id == tripId }
        if (trip == null || !trip.isActive) {
            _ui.update { it.copy(tripError = "No active trip to update.") }
            return
        }
        val currentRow = trip.currentRowNumber ?: trip.rowSequence.getOrNull(trip.sequenceIndex)
        val now = java.time.Instant.now().toString()
        val sessions = trip.tankSessions.map { session ->
            // Close any still-open session before opening the new one.
            if (session.isOpen) session.copy(endTime = now, endRow = session.endRow ?: currentRow) else session
        }.toMutableList()
        val nextNumber = (sessions.maxOfOrNull { it.tankNumber } ?: 0) + 1
        sessions.add(
            TankSession(
                id = java.util.UUID.randomUUID().toString(),
                tankNumber = nextNumber,
                startTime = now,
                startRow = currentRow,
            ),
        )
        persistTankSessions(
            tripId,
            sessions,
            activeTankNumber = nextNumber,
            isFillingTank = trip.isFillingTank,
            fillingTankNumber = trip.fillingTankNumber,
        )
    }

    /**
     * End the currently open tank session on the active spray trip. Mirrors the
     * iOS `endTank()`: sets the open session's end time and end row, then clears
     * `activeTankNumber`. Fill state is left untouched (parked for 3F-2c).
     */
    fun endTankSession(tripId: String) {
        val trip = _ui.value.trips.firstOrNull { it.id == tripId }
        if (trip == null || !trip.isActive) {
            _ui.update { it.copy(tripError = "No active trip to update.") }
            return
        }
        val openIndex = trip.tankSessions.indexOfLast { it.isOpen }
        if (openIndex < 0) return
        val currentRow = trip.currentRowNumber ?: trip.rowSequence.getOrNull(trip.sequenceIndex)
        val now = java.time.Instant.now().toString()
        val sessions = trip.tankSessions.toMutableList()
        sessions[openIndex] = sessions[openIndex].copy(endTime = now, endRow = currentRow)
        persistTankSessions(
            tripId,
            sessions,
            activeTankNumber = null,
            isFillingTank = trip.isFillingTank,
            fillingTankNumber = trip.fillingTankNumber,
        )
    }

    /**
     * Start the optional tank fill timer (Stage 3F-2c), mirroring the iOS
     * `startFillTimer()`. If a tank session is still open, the fill is recorded
     * on it; otherwise a new fill-only session is created with the next tank
     * number. Sets `isFillingTank` and `fillingTankNumber`. Operator-driven and
     * gated behind the device-local fill-timer preference in the UI; never
     * touches GPS progress, row coverage or active-tank semantics here.
     */
    fun startFillTimer(tripId: String) {
        val trip = _ui.value.trips.firstOrNull { it.id == tripId }
        if (trip == null || !trip.isActive) {
            _ui.update { it.copy(tripError = "No active trip to update.") }
            return
        }
        if (trip.isFillingTank) return
        val now = java.time.Instant.now().toString()
        val sessions = trip.tankSessions.toMutableList()
        val openIndex = sessions.indexOfLast { it.isOpen }
        val fillingNumber: Int
        if (openIndex >= 0) {
            sessions[openIndex] = sessions[openIndex].copy(fillStartTime = now, fillEndTime = null)
            fillingNumber = sessions[openIndex].tankNumber
        } else {
            val nextNumber = (sessions.maxOfOrNull { it.tankNumber } ?: 0) + 1
            sessions.add(
                TankSession(
                    id = java.util.UUID.randomUUID().toString(),
                    tankNumber = nextNumber,
                    startTime = now,
                    fillStartTime = now,
                ),
            )
            fillingNumber = nextNumber
        }
        persistTankSessions(
            tripId,
            sessions,
            activeTankNumber = trip.activeTankNumber,
            isFillingTank = true,
            fillingTankNumber = fillingNumber,
        )
    }

    /**
     * Stop the tank fill timer (Stage 3F-2c), mirroring the iOS `stopFillTimer()`.
     * Records `fillEndTime` on the open fill session and clears the live filling
     * state. The explicit-null-safe patch ensures `filling_tank_number` is
     * cleared server-side.
     */
    fun stopFillTimer(tripId: String) {
        val trip = _ui.value.trips.firstOrNull { it.id == tripId }
        if (trip == null || !trip.isActive) {
            _ui.update { it.copy(tripError = "No active trip to update.") }
            return
        }
        val now = java.time.Instant.now().toString()
        val sessions = trip.tankSessions.toMutableList()
        val fillIndex = sessions.indexOfLast { it.fillStartTime != null && it.fillEndTime == null }
        if (fillIndex >= 0) {
            sessions[fillIndex] = sessions[fillIndex].copy(fillEndTime = now)
        }
        persistTankSessions(
            tripId,
            sessions,
            activeTankNumber = trip.activeTankNumber,
            isFillingTank = false,
            fillingTankNumber = null,
        )
    }

    private fun persistTankSessions(
        tripId: String,
        sessions: List<TankSession>,
        activeTankNumber: Int?,
        isFillingTank: Boolean,
        fillingTankNumber: Int?,
    ) {
        // Stage B-2-1: ignore tank/fill actions for a trip the operator already
        // ended locally (its TRIP_END marker is queued) — no new tank work may
        // accrue after a local end.
        if (tripId in _ui.value.locallyEndedTripIds) return
        val previous = _ui.value.trips
        // Optimistic local update so the controls reflect the action immediately.
        _ui.update { st ->
            st.copy(
                trips = st.trips.map {
                    if (it.id == tripId) it.copy(
                        tankSessions = sessions,
                        activeTankNumber = activeTankNumber,
                        isFillingTank = isFillingTank,
                        fillingTankNumber = fillingTankNumber,
                    ) else it
                },
            )
        }
        // Durable local snapshot before the network round-trip so tank/fill work
        // survives a process death even if the server write later fails.
        persistActiveTripSnapshot()
        // Stage E-1: when known offline, keep the optimistic tank/fill change
        // (don't roll it back just because there's no network), queue/refresh a
        // coalesced TRIP_TANK marker, and surface a friendly offline message.
        // The tank state already lives in the Stage A snapshot; the marker only
        // flags that this active server trip has unsynced tank work to merge.
        val optimisticTrip = _ui.value.trips.firstOrNull { it.id == tripId }
        if (!_ui.value.isOnline) {
            if (optimisticTrip != null && optimisticTrip.isActive) tripTankSync.enqueue(optimisticTrip)
            _ui.update { it.copy(tripError = "Tank changes saved offline — they'll sync when connection returns.") }
            return
        }
        viewModelScope.launch {
            try {
                val updated = tripRepo.updateTripTankSessions(
                    tripId,
                    sessions,
                    activeTankNumber,
                    isFillingTank,
                    fillingTankNumber,
                )
                _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == tripId) updated else it }) }
                persistActiveTripSnapshot()
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(trips = previous) }; signOut()
            } catch (e: Exception) {
                // Server write failed while we believed we were online. Keep the
                // optimistic tank state and queue a coalesced marker so the tank
                // action is merged/replayed on reconnect rather than rolled back
                // and lost. Coalesced by trip id, so repeated failures never
                // bloat the outbox.
                val current2 = _ui.value.trips.firstOrNull { it.id == tripId }
                if (current2 != null && current2.isActive) tripTankSync.enqueue(current2)
                _ui.update { it.copy(tripError = "Tank changes saved offline — they'll sync when connection returns.") }
            }
        }
    }

    /**
     * Edit an existing spray record (Android Stage I-2 — offline/retryable). The
     * edit is applied optimistically first, then resolved by path:
     *
     *  - Edit-before-create: if the same record still has an unresolved create,
     *    the edit is folded into that create payload (no UPDATE marker) so the
     *    eventual insert carries the latest values; Sync Status stays "Spray
     *    record".
     *  - Known-offline: skip the network and enqueue/coalesce one SPRAY_RECORD /
     *    UPDATE marker for automatic replay through [SprayRecordUpdateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic edit and enqueue a marker
     *    (or fold into a pending create).
     *  - Permanent (validation / permission) rejection: roll the row back to its
     *    previous state and surface the error; never queued. Unauthorized signs
     *    out.
     *
     * The trip-coupled spray-create variants, import, and delete are untouched.
     */
    fun updateSprayRecord(id: String, input: SprayRecordRepository.SprayInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.sprayRecords
        val clientUpdatedAt = Instant.now().toString()
        // Optimistic edit — the operator sees the change straight away. Preserve
        // server-managed fields (createdBy etc.) by copying the existing row.
        _ui.update { st ->
            st.copy(
                sprayRecords = st.sprayRecords.map {
                    if (it.id == id) it.copy(
                        tripId = input.tripId,
                        date = input.date,
                        startTime = input.startTime,
                        temperature = input.temperature,
                        windSpeed = input.windSpeed,
                        windDirection = input.windDirection,
                        humidity = input.humidity,
                        sprayReference = input.sprayReference,
                        notes = input.notes,
                        numberOfFansJets = input.numberOfFansJets,
                        averageSpeed = input.averageSpeed,
                        equipmentType = input.equipmentType,
                        tractor = input.tractor,
                        tractorGear = input.tractorGear,
                        machineId = input.machineId,
                        sprayEquipmentId = input.sprayEquipmentId,
                        isTemplate = input.isTemplate,
                        operationType = input.operationType,
                        tanks = input.tanks,
                    ) else it
                },
                sprayError = null,
            )
        }

        // Edit-before-create: fold into the still-pending create rather than
        // queueing a separate UPDATE (and never PATCH a row that doesn't exist).
        if (sprayCreateSync.foldEdit(id, input, clientUpdatedAt)) {
            _ui.update { it.copy(sprayError = "Spray record edit saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        // Known-offline: queue the update marker without touching the network.
        if (!_ui.value.isOnline) {
            sprayUpdateSync.enqueue(id, input, clientUpdatedAt)
            _ui.update { it.copy(sprayError = "Spray record edit saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(sprayBusy = true) }
            try {
                val updated = sprayRepo.updateSprayRecord(id, input, clientUpdatedAt)
                _ui.update { st -> st.copy(sprayRecords = st.sprayRecords.map { if (it.id == id) updated else it }, sprayBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(sprayBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic edit
                // back, surface, don't queue as retryable.
                _ui.update { it.copy(sprayBusy = false, sprayRecords = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic edit and queue
                // an update marker for automatic replay rather than rolling back.
                sprayUpdateSync.enqueue(id, input, clientUpdatedAt)
                _ui.update { it.copy(sprayBusy = false, sprayError = "Spray record edit saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Soft-delete a spray record (Android Stage I-3 — offline/retryable) for
     * already-synced records, with a local-only cancellation path for records
     * that never reached the server. The optimistic hide is applied first, then
     * resolved by path:
     *
     *  - Local-only pending create: cancel the queued create (and any same-record
     *    update) and drop the optimistic row, with no DELETE marker and no RPC, so
     *    [SprayRecordCreateSync] can never resurrect it.
     *  - Known-offline: skip the network and enqueue/coalesce one SPRAY_RECORD /
     *    DELETE marker for automatic replay through [SprayRecordDeleteSync].
     *  - Online success: behaves as before; no marker.
     *  - Transient online failure: keep the optimistic hide and enqueue a marker.
     *  - Permanent (validation / permission) rejection: restore the previous spray
     *    list and surface the error; never queued. Unauthorized signs out.
     *
     * Server soft-delete is RLS-restricted (owner / manager / supervisor), so a
     * permanent permission rejection rolls the row back rather than queueing.
     */
    fun deleteSprayRecord(id: String, onResult: (Boolean) -> Unit) {
        // Local-only offline-created record: cancel the queued create (and any
        // same-record update) instead of sending a server delete, so
        // SprayRecordCreateSync can never resurrect it.
        val pendingCreate = pendingWrites.list().firstOrNull {
            it.entityType == PendingEntityType.SPRAY_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (pendingCreate != null) {
            pendingWrites.remove(pendingCreate.id)
            pendingWrites.list()
                .filter {
                    it.entityType == PendingEntityType.SPRAY_RECORD &&
                        it.opType == PendingOpType.UPDATE &&
                        it.clientId == id &&
                        it.status != PendingWriteStatus.SYNCED
                }
                .forEach { pendingWrites.remove(it.id) }
            _ui.update { st -> st.copy(sprayRecords = st.sprayRecords.filterNot { it.id == id }) }
            onResult(true)
            return
        }

        val previous = _ui.value.sprayRecords
        // Optimistic hide for a synced record.
        _ui.update { st -> st.copy(sprayRecords = st.sprayRecords.filterNot { it.id == id }) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            sprayDeleteSync.enqueue(id)
            _ui.update { it.copy(sprayError = "Spray record deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                sprayRepo.softDeleteSprayRecord(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll back, surface, don't queue.
                _ui.update { it.copy(sprayRecords = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                sprayDeleteSync.enqueue(id)
                _ui.update { it.copy(sprayError = "Spray record deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    fun clearSprayError() {
        _ui.update { it.copy(sprayError = null) }
    }

    // MARK: - Saved chemicals (owner/manager-managed library)

    /** Create a saved chemical, optimistically inserting it in name order. */
    fun createSavedChemical(input: SavedChemicalRepository.ChemicalInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val created = savedChemicalRepo.create(vineyardId, input)
                _ui.update { st ->
                    st.copy(savedChemicals = (st.savedChemicals + created).sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(sprayError = "Couldn't save the chemical. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Edit an existing saved chemical, reconciling with the server-resolved row. */
    fun updateSavedChemical(id: String, input: SavedChemicalRepository.ChemicalInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.savedChemicals
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val updated = savedChemicalRepo.update(id, input)
                _ui.update { st ->
                    st.copy(savedChemicals = st.savedChemicals.map { if (it.id == id) updated else it }
                        .sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(savedChemicals = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(savedChemicals = previous, sprayError = "Couldn't save the chemical. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Archive (soft-delete) a saved chemical via the server RPC, optimistically removing it. */
    fun deleteSavedChemical(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.savedChemicals
        _ui.update { st -> st.copy(savedChemicals = st.savedChemicals.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                savedChemicalRepo.softDelete(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(savedChemicals = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(savedChemicals = previous, sprayError = "Couldn't archive the chemical. Check your connection.") }
                onResult(false)
            }
        }
    }

    /**
     * Permanently delete an unused saved chemical via the server RPC. The
     * backend refuses (reporting in-use) if the chemical is referenced by any
     * record; on that branch we restore the row and surface the message.
     * Mirrors the iOS "Delete Permanently" path.
     */
    fun hardDeleteSavedChemical(
        id: String,
        onResult: (SavedChemicalRepository.HardDeleteOutcome?) -> Unit,
    ) {
        val previous = _ui.value.savedChemicals
        _ui.update { st -> st.copy(savedChemicals = st.savedChemicals.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                val outcome = savedChemicalRepo.hardDeleteUnused(id)
                if (outcome is SavedChemicalRepository.HardDeleteOutcome.InUse) {
                    // Server kept the row — restore it locally so the list stays truthful.
                    _ui.update { it.copy(savedChemicals = previous) }
                }
                onResult(outcome)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(null)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(savedChemicals = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(null)
            } catch (e: Exception) {
                _ui.update { it.copy(savedChemicals = previous, sprayError = "Couldn't delete the chemical. Check your connection.") }
                onResult(null)
            }
        }
    }

    // MARK: - Grape variety master list (owner/manager-managed setup)

    /**
     * Create or rename a grape variety via the server `upsert_vineyard_grape_variety`
     * RPC, reconciling state with the server-resolved row. Passing `existing == null`
     * creates a custom variety (server mints a stable `custom:` key). Editing routes
     * through the existing key; the optimal-GDD override is only written for custom
     * varieties (built-ins keep their catalog default), mirroring the iOS
     * `EditGrapeVarietySheet.save()`. Calls back with `null` on success or a
     * user-facing error message to display in the sheet.
     */
    fun saveGrapeVariety(
        existing: GrapeVarietyRow?,
        name: String,
        optimalGdd: Double,
        onResult: (String?) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run {
            onResult("No vineyard selected. Open a vineyard before managing varieties.")
            return
        }
        val trimmed = name.trim()
        if (trimmed.isEmpty()) { onResult("Enter a variety name."); return }
        viewModelScope.launch {
            try {
                val row = repo.upsertVineyardVariety(
                    vineyardId = vineyardId,
                    key = existing?.varietyKey,
                    displayName = trimmed,
                    optimalGddOverride = if (existing != null && !existing.isCustom) null else optimalGdd,
                    isActive = true,
                )
                _ui.update { st ->
                    val others = st.grapeVarieties.filterNot { it.id == row.id || it.varietyKey == row.varietyKey }
                    st.copy(grapeVarieties = (others + row).sortedBy { it.displayName.lowercase() })
                }
                onResult(null)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult("Your session expired. Please sign in again.")
            } catch (e: BackendError.Server) {
                onResult("Couldn't save to the shared catalogue (${e.code}). Tap Save to retry.")
            } catch (e: Exception) {
                onResult("Couldn't save to the shared catalogue. Check your connection and tap Save to retry.")
            }
        }
    }

    /**
     * Archive a grape variety (hide from active lists, keep historical records)
     * via `archive_vineyard_grape_variety`, optimistically removing it. Mirrors
     * the iOS archive flow used as the fallback when a delete is blocked.
     */
    fun archiveGrapeVariety(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.grapeVarieties
        _ui.update { st -> st.copy(grapeVarieties = st.grapeVarieties.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                repo.archiveVineyardVariety(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(grapeVarieties = previous) }
                onResult(false)
            }
        }
    }

    /**
     * Permanently delete an unused custom grape variety via the server safety
     * gate. If the server refuses (variety in use / not custom / not authorised),
     * the row is restored locally and the outcome surfaced so the UI can offer an
     * archive-instead fallback. Mirrors the iOS `hardDelete`.
     */
    fun hardDeleteGrapeVariety(id: String, onResult: (GrapeVarietyDeleteOutcome?) -> Unit) {
        val previous = _ui.value.grapeVarieties
        _ui.update { st -> st.copy(grapeVarieties = st.grapeVarieties.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                val outcome = repo.hardDeleteUnusedCustomGrapeVariety(id)
                if (outcome !is GrapeVarietyDeleteOutcome.Deleted &&
                    outcome !is GrapeVarietyDeleteOutcome.NotFound
                ) {
                    // Server kept the row — restore it so the list stays truthful.
                    _ui.update { it.copy(grapeVarieties = previous) }
                }
                onResult(outcome)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(null)
            } catch (e: Exception) {
                _ui.update { it.copy(grapeVarieties = previous) }
                onResult(null)
            }
        }
    }

    private val chemicalInfoService = ChemicalInfoService()

    /** Country used to localize AI chemical lookups (vineyard country or device region). */
    private fun chemicalLookupCountry(): String =
        ChemicalInfoService.resolveCountry(_ui.value.selectedVineyard?.country)

    /**
     * Run an AI chemical search, returning candidate products or an error
     * message. Mirrors the iOS `ChemicalAILookupSheet.search`.
     */
    fun searchChemicals(
        query: String,
        onResult: (Result<List<ChemicalInfoService.ChemicalSearchResult>>) -> Unit,
    ) {
        viewModelScope.launch {
            try {
                val results = chemicalInfoService.searchChemicals(query.trim(), chemicalLookupCountry())
                onResult(Result.success(results))
            } catch (e: ChemicalInfoService.LookupException) {
                onResult(Result.failure(e))
            } catch (e: Exception) {
                onResult(Result.failure(ChemicalInfoService.LookupException("AI lookup failed. Check your connection.")))
            }
        }
    }

    /**
     * Fetch full AI detail for a chosen product, used to prefill the chemical
     * editor. Mirrors the iOS `ChemicalInfoService.lookupChemicalInfo`.
     */
    fun lookupChemicalInfo(
        productName: String,
        onResult: (Result<ChemicalInfoService.ChemicalInfoResponse>) -> Unit,
    ) {
        viewModelScope.launch {
            try {
                val info = chemicalInfoService.lookupChemicalInfo(productName.trim(), chemicalLookupCountry())
                onResult(Result.success(info))
            } catch (e: ChemicalInfoService.LookupException) {
                onResult(Result.failure(e))
            } catch (e: Exception) {
                onResult(Result.failure(ChemicalInfoService.LookupException("AI lookup failed. Check your connection.")))
            }
        }
    }

    /**
     * Persist a trip's structured seeding payload (mix lines + box settings).
     * Optimistically applies the new details locally, then writes only the
     * `seeding_details` JSONB column. On failure the previous value is restored
     * and a friendly message is surfaced. Owner/manager/operator gated by RLS.
     */
    fun updateTripSeedingDetails(
        tripId: String,
        details: com.rork.vinetrack.data.model.SeedingDetails?,
        onResult: (Boolean) -> Unit,
    ) {
        val previous = _ui.value.trips
        val normalised = details?.takeIf { it.hasAnyValue }
        _ui.update { st ->
            st.copy(trips = st.trips.map { if (it.id == tripId) it.copy(seedingDetails = normalised) else it })
        }
        // Stage S: queue the seeding edit offline for an existing active server
        // trip instead of reverting. Optimistically applied above; refresh the
        // Stage A snapshot, enqueue a coalesced TRIP_SEEDING write, and surface a
        // friendly offline message — no network call is made.
        val target = previous.firstOrNull { it.id == tripId }
        if (!_ui.value.isOnline && target != null && target.isActive) {
            persistActiveTripSnapshot()
            tripSeedingSync.enqueue(target.copy(seedingDetails = normalised))
            _ui.update { it.copy(tripError = "Seeding details saved offline — they'll sync when connection returns.") }
            onResult(true)
            return
        }
        viewModelScope.launch {
            _ui.update { it.copy(tripError = null) }
            try {
                val updated = tripRepo.updateSeedingDetails(tripId, normalised)
                _ui.update { st -> st.copy(trips = st.trips.map { if (it.id == tripId) updated else it }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(trips = previous, tripError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(trips = previous, tripError = "Couldn't save seeding details. Check your connection.") }
                onResult(false)
            }
        }
    }

    // MARK: - Saved inputs (seed/fertiliser library backing seeding-trip costing)

    /** Create a saved input, optimistically inserting it in name order. */
    fun createSavedInput(form: SavedInputRepository.InputForm, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val created = savedInputRepo.create(vineyardId, form)
                _ui.update { st ->
                    st.copy(savedInputs = (st.savedInputs + created).sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(sprayError = "Couldn't save the input. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Edit an existing saved input, reconciling with the server-resolved row. */
    fun updateSavedInput(id: String, form: SavedInputRepository.InputForm, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.savedInputs
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val updated = savedInputRepo.update(id, form)
                _ui.update { st ->
                    st.copy(savedInputs = st.savedInputs.map { if (it.id == id) updated else it }
                        .sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(savedInputs = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(savedInputs = previous, sprayError = "Couldn't save the input. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Archive (soft-delete) a saved input via the server RPC, optimistically removing it. */
    fun deleteSavedInput(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.savedInputs
        _ui.update { st -> st.copy(savedInputs = st.savedInputs.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                savedInputRepo.softDelete(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(savedInputs = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(savedInputs = previous, sprayError = "Couldn't archive the input. Check your connection.") }
                onResult(false)
            }
        }
    }

    // MARK: - Operator categories (owner/manager-managed labour cost categories)

    /** Create an operator category, optimistically inserting it in name order. */
    fun createOperatorCategory(input: OperatorCategoryRepository.CategoryInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val created = operatorCategoryRepo.create(vineyardId, input)
                _ui.update { st ->
                    st.copy(operatorCategories = (st.operatorCategories + created).sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(sprayError = "Couldn't save the category. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Edit an existing operator category, reconciling with the server-resolved row. */
    fun updateOperatorCategory(id: String, input: OperatorCategoryRepository.CategoryInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.operatorCategories
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val updated = operatorCategoryRepo.update(id, input)
                _ui.update { st ->
                    st.copy(operatorCategories = st.operatorCategories.map { if (it.id == id) updated else it }
                        .sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(operatorCategories = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(operatorCategories = previous, sprayError = "Couldn't save the category. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Archive (soft-delete) an operator category via the server RPC, optimistically removing it. */
    fun deleteOperatorCategory(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.operatorCategories
        _ui.update { st -> st.copy(operatorCategories = st.operatorCategories.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                operatorCategoryRepo.softDelete(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(operatorCategories = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(operatorCategories = previous, sprayError = "Couldn't archive the category. Check your connection.") }
                onResult(false)
            }
        }
    }

    // MARK: - Custom Trip Functions (owner/manager-managed, vineyard-scoped)

    /**
     * Active, non-deleted custom trip functions for the selected vineyard,
     * sorted alphabetically by label. Mirrors iOS `activeSortedByLabel`.
     */
    private fun activeTripFunctions(from: List<VineyardTripFunction>): List<VineyardTripFunction> =
        from.filter { it.isSelectable }.sortedBy { it.label.lowercase() }

    /**
     * Create a custom trip function. Derives a stable slug from the label and
     * rejects collisions with built-in raw values and existing active slugs.
     * Returns false (with [AppUiState.sprayError]) when validation fails.
     */
    fun createTripFunction(label: String, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val trimmed = label.trim()
        if (trimmed.isEmpty()) { onResult(false); return }
        val slug = slugifyTripFunction(trimmed)
        if (builtInTripFunctions.any { it.first == slug } || tripFunctionDisplayName(slug) != null) {
            _ui.update { it.copy(sprayError = "\"$trimmed\" matches a built-in function. Pick another name.") }
            onResult(false); return
        }
        if (activeTripFunctions(_ui.value.vineyardTripFunctions).any { it.slug == slug }) {
            _ui.update { it.copy(sprayError = "A custom function with that name already exists.") }
            onResult(false); return
        }
        val nextOrder = (_ui.value.vineyardTripFunctions.maxOfOrNull { it.sortOrder } ?: 0) + 10
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val created = tripFunctionRepo.upsert(
                    id = java.util.UUID.randomUUID().toString(),
                    vineyardId = vineyardId,
                    label = trimmed,
                    slug = slug,
                    isActive = true,
                    sortOrder = nextOrder,
                )
                _ui.update { st -> st.copy(vineyardTripFunctions = st.vineyardTripFunctions + created) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(sprayError = "Couldn't save the function. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Rename a custom trip function. The slug stays stable so trips keep their reference. */
    fun renameTripFunction(id: String, label: String, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val existing = _ui.value.vineyardTripFunctions.firstOrNull { it.id == id } ?: run { onResult(false); return }
        val trimmed = label.trim()
        if (trimmed.isEmpty() || trimmed == existing.label) { onResult(false); return }
        val previous = _ui.value.vineyardTripFunctions
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val updated = tripFunctionRepo.upsert(
                    id = existing.id,
                    vineyardId = vineyardId,
                    label = trimmed,
                    slug = existing.slug,
                    isActive = existing.isActive,
                    sortOrder = existing.sortOrder,
                )
                _ui.update { st -> st.copy(vineyardTripFunctions = st.vineyardTripFunctions.map { if (it.id == id) updated else it }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(vineyardTripFunctions = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(vineyardTripFunctions = previous, sprayError = "Couldn't save the function. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Archive (soft-delete) a custom trip function via the server RPC. */
    fun archiveTripFunction(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.vineyardTripFunctions
        _ui.update { st ->
            st.copy(vineyardTripFunctions = st.vineyardTripFunctions.map {
                if (it.id == id) it.copy(isActive = false, deletedAt = java.time.Instant.now().toString()) else it
            })
        }
        viewModelScope.launch {
            try {
                tripFunctionRepo.archive(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(vineyardTripFunctions = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(vineyardTripFunctions = previous, sprayError = "Couldn't archive the function. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Restore a previously-archived custom trip function via the server RPC. */
    fun restoreTripFunction(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.vineyardTripFunctions
        _ui.update { st ->
            st.copy(vineyardTripFunctions = st.vineyardTripFunctions.map {
                if (it.id == id) it.copy(isActive = true, deletedAt = null) else it
            })
        }
        viewModelScope.launch {
            try {
                tripFunctionRepo.restore(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(vineyardTripFunctions = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(vineyardTripFunctions = previous, sprayError = "Couldn't restore the function. Check your connection.") }
                onResult(false)
            }
        }
    }

    // MARK: - Team & Access (owner/manager-managed team membership)

    /** Re-fetch the selected vineyard's team members into state. */
    private suspend fun refreshTeamMembers() {
        val vineyardId = _ui.value.selectedVineyardId ?: return
        runCatching { repo.listTeamMembers(vineyardId) }
            .onSuccess { members -> _ui.update { it.copy(members = members) } }
    }

    /** Load pending invitations for the selected vineyard (Team & Access). */
    fun loadPendingInvitations() {
        val vineyardId = _ui.value.selectedVineyardId ?: return
        viewModelScope.launch {
            runCatching { teamRepo.listPendingInvitations(vineyardId) }
                .onSuccess { invites -> _ui.update { it.copy(pendingInvitations = invites) } }
        }
    }

    /** Invite a member by email + role (owner/manager only, enforced server-side). */
    fun inviteMember(email: String, role: String, operatorCategoryId: String?, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(teamBusy = true, teamError = null) }
            try {
                teamRepo.inviteMember(vineyardId, email, role, operatorCategoryId)
                loadPendingInvitations()
                _ui.update { it.copy(teamBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(teamBusy = false, teamError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(teamBusy = false, teamError = "Couldn't send the invitation. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Update a member's role and/or operator category (owner/manager only). */
    fun updateMember(userId: String, role: String, operatorCategoryId: String?, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val current = _ui.value.members.firstOrNull { it.userId == userId }
        viewModelScope.launch {
            _ui.update { it.copy(teamBusy = true, teamError = null) }
            try {
                if (current?.role?.lowercase() != role.lowercase()) {
                    teamRepo.updateMemberRole(vineyardId, userId, role)
                }
                if (current?.operatorCategoryId != operatorCategoryId) {
                    teamRepo.updateMemberOperatorCategory(vineyardId, userId, operatorCategoryId)
                }
                refreshTeamMembers()
                _ui.update { it.copy(teamBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(teamBusy = false, teamError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(teamBusy = false, teamError = "Couldn't update the member. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Remove a member from the selected vineyard (owner/manager only). */
    fun removeMember(userId: String, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(teamBusy = true, teamError = null) }
            try {
                teamRepo.removeMember(vineyardId, userId)
                refreshTeamMembers()
                _ui.update { it.copy(teamBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(teamBusy = false, teamError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(teamBusy = false, teamError = "Couldn't remove the member. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Transfer ownership to another member (owner only, enforced server-side). */
    fun transferOwnership(newOwnerId: String, removeOldOwner: Boolean, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(teamBusy = true, teamError = null) }
            try {
                teamRepo.transferOwnership(vineyardId, newOwnerId, removeOldOwner)
                refreshTeamMembers()
                _ui.update { it.copy(teamBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(teamBusy = false, teamError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(teamBusy = false, teamError = "Couldn't transfer ownership. Check your connection.") }
                onResult(false)
            }
        }
    }

    // MARK: - Alert preferences (per-vineyard, owner/manager-editable)

    /** Load saved alert preferences for the selected vineyard, falling back to defaults. */
    fun loadAlertPreferences() {
        val vineyardId = _ui.value.selectedVineyardId ?: return
        viewModelScope.launch {
            _ui.update { it.copy(alertPrefsLoading = true, alertPrefsError = null) }
            try {
                val loaded = alertPrefsRepo.load(vineyardId) ?: AlertPreferences.defaults(vineyardId)
                _ui.update { it.copy(alertPreferences = loaded, alertPrefsLoading = false) }
            } catch (e: BackendError.Unauthorized) {
                signOut()
            } catch (e: Exception) {
                _ui.update {
                    it.copy(
                        alertPreferences = it.alertPreferences ?: AlertPreferences.defaults(vineyardId),
                        alertPrefsLoading = false,
                    )
                }
            }
        }
    }

    /** Persist alert preferences (upsert). Owner/manager only, enforced server-side. */
    fun saveAlertPreferences(prefs: AlertPreferences, onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            _ui.update { it.copy(alertPrefsBusy = true, alertPrefsError = null) }
            try {
                val saved = alertPrefsRepo.save(prefs)
                _ui.update { it.copy(alertPreferences = saved, alertPrefsBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(alertPrefsBusy = false, alertPrefsError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(alertPrefsBusy = false, alertPrefsError = "Couldn't save preferences. Check your connection.") }
                onResult(false)
            }
        }
    }

    fun clearTeamError() { _ui.update { it.copy(teamError = null) } }

    // MARK: - Spray equipment (owner/manager-managed spray rigs & tanks)

    /** Create a spray equipment item, optimistically inserting it in name order. */
    fun createSprayEquipment(input: SprayEquipmentRepository.EquipmentInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val created = sprayEquipmentRepo.create(vineyardId, input)
                _ui.update { st ->
                    st.copy(sprayEquipment = (st.sprayEquipment + created).sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(sprayError = "Couldn't save the equipment. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Edit an existing spray equipment item, reconciling with the server-resolved row. */
    fun updateSprayEquipment(id: String, input: SprayEquipmentRepository.EquipmentInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.sprayEquipment
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val updated = sprayEquipmentRepo.update(id, input)
                _ui.update { st ->
                    st.copy(sprayEquipment = st.sprayEquipment.map { if (it.id == id) updated else it }
                        .sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(sprayEquipment = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(sprayEquipment = previous, sprayError = "Couldn't save the equipment. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Archive (soft-delete) a spray equipment item via the server RPC, optimistically removing it. */
    fun deleteSprayEquipment(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.sprayEquipment
        _ui.update { st -> st.copy(sprayEquipment = st.sprayEquipment.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                sprayEquipmentRepo.softDelete(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(sprayEquipment = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(sprayEquipment = previous, sprayError = "Couldn't archive the equipment. Check your connection.") }
                onResult(false)
            }
        }
    }

    // MARK: - Vineyard machines, other equipment & fuel purchases (Equipment area)

    fun clearEquipmentError() { _ui.update { it.copy(equipmentError = null) } }

    /** Create a vineyard machine (tractor/ATV/etc.), optimistically inserting it in name order. */
    fun createVineyardMachine(input: VineyardMachineRepository.MachineInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(equipmentError = null) }
            try {
                val created = machineRepo.create(vineyardId, input)
                _ui.update { st -> st.copy(machines = (st.machines + created).sortedBy { it.displayName.lowercase() }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(equipmentError = "Couldn't save the machine. Check your connection.") }; onResult(false)
            }
        }
    }

    /** Edit an existing vineyard machine, reconciling with the server-resolved row. */
    fun updateVineyardMachine(id: String, input: VineyardMachineRepository.MachineInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.machines
        viewModelScope.launch {
            _ui.update { it.copy(equipmentError = null) }
            try {
                val updated = machineRepo.update(id, input)
                _ui.update { st -> st.copy(machines = st.machines.map { if (it.id == id) updated else it }.sortedBy { it.displayName.lowercase() }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(machines = previous, equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(machines = previous, equipmentError = "Couldn't save the machine. Check your connection.") }; onResult(false)
            }
        }
    }

    /** Archive (soft-delete) a vineyard machine via the server RPC, optimistically removing it. */
    fun deleteVineyardMachine(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.machines
        _ui.update { st -> st.copy(machines = st.machines.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                machineRepo.softDelete(id); onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(machines = previous, equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(machines = previous, equipmentError = "Couldn't archive the machine. Check your connection.") }; onResult(false)
            }
        }
    }

    /** Create an "Other" equipment item, optimistically inserting it in name order. */
    fun createEquipmentItem(input: EquipmentItemRepository.ItemInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(equipmentError = null) }
            try {
                val created = equipmentItemRepo.create(vineyardId, input)
                _ui.update { st -> st.copy(equipmentItems = (st.equipmentItems + created).sortedBy { it.displayName.lowercase() }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(equipmentError = "Couldn't save the item. Check your connection.") }; onResult(false)
            }
        }
    }

    /** Edit an existing "Other" equipment item. */
    fun updateEquipmentItem(id: String, input: EquipmentItemRepository.ItemInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.equipmentItems
        viewModelScope.launch {
            _ui.update { it.copy(equipmentError = null) }
            try {
                val updated = equipmentItemRepo.update(id, input)
                _ui.update { st -> st.copy(equipmentItems = st.equipmentItems.map { if (it.id == id) updated else it }.sortedBy { it.displayName.lowercase() }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(equipmentItems = previous, equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(equipmentItems = previous, equipmentError = "Couldn't save the item. Check your connection.") }; onResult(false)
            }
        }
    }

    /** Archive (soft-delete) an "Other" equipment item via the server RPC. */
    fun deleteEquipmentItem(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.equipmentItems
        _ui.update { st -> st.copy(equipmentItems = st.equipmentItems.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                equipmentItemRepo.softDelete(id); onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(equipmentItems = previous, equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(equipmentItems = previous, equipmentError = "Couldn't archive the item. Check your connection.") }; onResult(false)
            }
        }
    }

    /** Create a fuel purchase, optimistically inserting it newest-first. */
    fun createFuelPurchase(input: FuelPurchaseRepository.PurchaseInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(equipmentError = null) }
            try {
                val created = fuelPurchaseRepo.create(vineyardId, input)
                _ui.update { st -> st.copy(fuelPurchases = (st.fuelPurchases + created).sortedByDescending { it.date ?: "" }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(equipmentError = "Couldn't save the purchase. Check your connection.") }; onResult(false)
            }
        }
    }

    /** Edit an existing fuel purchase. */
    fun updateFuelPurchase(id: String, input: FuelPurchaseRepository.PurchaseInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.fuelPurchases
        viewModelScope.launch {
            _ui.update { it.copy(equipmentError = null) }
            try {
                val updated = fuelPurchaseRepo.update(id, input)
                _ui.update { st -> st.copy(fuelPurchases = st.fuelPurchases.map { if (it.id == id) updated else it }.sortedByDescending { it.date ?: "" }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(fuelPurchases = previous, equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(fuelPurchases = previous, equipmentError = "Couldn't save the purchase. Check your connection.") }; onResult(false)
            }
        }
    }

    /** Archive (soft-delete) a fuel purchase via the server RPC. */
    fun deleteFuelPurchase(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.fuelPurchases
        _ui.update { st -> st.copy(fuelPurchases = st.fuelPurchases.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                fuelPurchaseRepo.softDelete(id); onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(fuelPurchases = previous, equipmentError = friendlyWriteError(e.code)) }; onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(fuelPurchases = previous, equipmentError = "Couldn't archive the purchase. Check your connection.") }; onResult(false)
            }
        }
    }

    // MARK: - Saved spray presets (owner/manager-managed reusable tank presets)

    /** Create a tank preset, optimistically inserting it in name order. */
    fun createSavedSprayPreset(input: SavedSprayPresetRepository.PresetInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val created = savedSprayPresetRepo.create(vineyardId, input)
                _ui.update { st ->
                    st.copy(savedSprayPresets = (st.savedSprayPresets + created).sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(sprayError = "Couldn't save the preset. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Edit an existing tank preset, reconciling with the server-resolved row. */
    fun updateSavedSprayPreset(id: String, input: SavedSprayPresetRepository.PresetInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.savedSprayPresets
        viewModelScope.launch {
            _ui.update { it.copy(sprayError = null) }
            try {
                val updated = savedSprayPresetRepo.update(id, input)
                _ui.update { st ->
                    st.copy(savedSprayPresets = st.savedSprayPresets.map { if (it.id == id) updated else it }
                        .sortedBy { it.displayName.lowercase() })
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(savedSprayPresets = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(savedSprayPresets = previous, sprayError = "Couldn't save the preset. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Archive (soft-delete) a tank preset via the server RPC, optimistically removing it. */
    fun deleteSavedSprayPreset(id: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.savedSprayPresets
        _ui.update { st -> st.copy(savedSprayPresets = st.savedSprayPresets.filterNot { it.id == id }) }
        viewModelScope.launch {
            try {
                savedSprayPresetRepo.softDelete(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(savedSprayPresets = previous, sprayError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(savedSprayPresets = previous, sprayError = "Couldn't archive the preset. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Outcome of a Spray Program CSV import. */
    data class SprayImportOutcome(val imported: Int, val failed: Int)

    /**
     * Import parsed Spray Program CSV rows into `spray_records`. Mirrors the iOS
     * importer: each row gets an inactive, already-finished trip (carrying the
     * matched block + operator) and a linked spray record. Block names are
     * matched against loaded paddocks case-insensitively; an unmatched block is
     * still kept as the trip's free-text `paddock_name`. Chemical amounts are
     * stored as-entered alongside the unit string, matching the Android spray
     * form. Runs sequentially online; partial success is reported back.
     */
    fun importSprayRecords(
        rows: List<SprayProgramCsvImporter.ImportedSprayRow>,
        onResult: (SprayImportOutcome) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(SprayImportOutcome(0, rows.size)); return }
        viewModelScope.launch {
            _ui.update { it.copy(sprayBusy = true, sprayError = null) }
            val paddocks = _ui.value.paddocks
            var imported = 0
            var failed = 0
            val createdTrips = ArrayList<Trip>()
            val createdRecords = ArrayList<SprayRecord>()
            try {
                for (row in rows) {
                    try {
                        val paddock = paddocks.firstOrNull { p ->
                            row.blockName.isNotBlank() && (
                                p.name.equals(row.blockName, ignoreCase = true) ||
                                    p.name.contains(row.blockName, ignoreCase = true) ||
                                    row.blockName.contains(p.name, ignoreCase = true)
                                )
                        }
                        val iso = java.time.Instant.ofEpochMilli(row.dateEpochMs).toString()
                        val trip = tripRepo.createImportedTrip(
                            vineyardId = vineyardId,
                            paddockId = paddock?.id,
                            paddockName = row.blockName.ifBlank { paddock?.name },
                            personName = row.operatorName.ifBlank { null },
                            startTime = iso,
                            endTime = if (row.isTemplate) null else iso,
                        )
                        createdTrips.add(trip)

                        val chemicals = row.chemicals.map { chem ->
                            com.rork.vinetrack.data.model.SprayChemical(
                                id = java.util.UUID.randomUUID().toString(),
                                name = chem.name,
                                volumePerTank = chem.amountPerTank,
                                ratePerHa = chem.ratePerHa,
                                ratePer100L = chem.ratePer100L,
                                costPerUnit = chem.costPerUnit,
                                unit = chem.unit,
                                savedChemicalId = chem.savedChemicalId,
                            )
                        }
                        val tank = com.rork.vinetrack.data.model.SprayTank(
                            id = java.util.UUID.randomUUID().toString(),
                            tankNumber = 1,
                            waterVolume = row.waterVolume,
                            sprayRatePerHa = row.sprayRate,
                            concentrationFactor = row.concentrationFactor,
                            chemicals = chemicals,
                        )
                        val input = SprayRecordRepository.SprayInput(
                            date = iso,
                            startTime = iso,
                            temperature = row.temperature,
                            windSpeed = row.windSpeed,
                            windDirection = row.windDirection.ifBlank { null },
                            humidity = row.humidity,
                            sprayReference = row.sprayName.ifBlank { null },
                            notes = row.notes.ifBlank { null },
                            numberOfFansJets = row.fansJets.ifBlank { null },
                            averageSpeed = null,
                            equipmentType = row.equipment.ifBlank { null },
                            tractor = row.tractor.ifBlank { null },
                            tractorGear = row.gear.ifBlank { null },
                            machineId = null,
                            sprayEquipmentId = null,
                            operationType = row.operationType,
                            tripId = trip.id,
                            isTemplate = row.isTemplate,
                            tanks = listOf(tank),
                        )
                        val record = sprayRepo.createSprayRecord(vineyardId, input)
                        createdRecords.add(record)
                        imported++
                    } catch (e: BackendError.Unauthorized) {
                        throw e
                    } catch (e: Exception) {
                        android.util.Log.e("AppViewModel", "Spray import row failed", e)
                        failed++
                    }
                }
                _ui.update {
                    it.copy(
                        sprayBusy = false,
                        trips = createdTrips + it.trips,
                        sprayRecords = createdRecords + it.sprayRecords,
                    )
                }
                onResult(SprayImportOutcome(imported, failed))
            } catch (e: BackendError.Unauthorized) {
                _ui.update {
                    it.copy(
                        sprayBusy = false,
                        trips = createdTrips + it.trips,
                        sprayRecords = createdRecords + it.sprayRecords,
                    )
                }
                signOut()
                onResult(SprayImportOutcome(imported, rows.size - imported))
            }
        }
    }

    // MARK: - Maintenance log write path

    /**
     * Log a new maintenance record (Android Stage K-1 — offline/retryable). The
     * id and client_updated_at are minted up front so the same id is shared by
     * the optimistic local row, the queued MAINTENANCE_LOG / CREATE marker, and
     * the eventual server insert. Paths:
     *
     *  - Optimistic: prepend the log immediately so the operator sees it.
     *  - Known-offline: skip the network and enqueue one create marker for
     *    automatic replay through [MaintenanceLogCreateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic row and enqueue a marker.
     *  - Permanent (validation / permission) rejection: roll the optimistic row
     *    back and surface the error; never queued as retryable. Unauthorized
     *    signs out.
     */
    fun createMaintenanceLog(
        input: MaintenanceLogRepository.MaintenanceInput,
        photoUri: Uri? = null,
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = maintenanceRepo.newId()
        val clientUpdatedAt = Instant.now().toString()
        val optimistic = MaintenanceLog(
            id = id,
            vineyardId = vineyardId,
            itemName = input.itemName,
            equipmentSource = input.equipmentSource,
            equipmentRefId = input.equipmentRefId,
            hours = input.hours,
            machineHours = input.machineHours,
            workCompleted = input.workCompleted,
            partsUsed = input.partsUsed,
            partsCost = input.partsCost,
            labourCost = input.labourCost,
            date = input.date,
            isArchived = input.isArchived,
            isFinalized = input.isFinalized,
        )
        // Optimistic insert at the top — the operator sees the log straight away.
        _ui.update { it.copy(maintenanceLogs = listOf(optimistic) + it.maintenanceLogs, maintenanceError = null) }

        // Known-offline: queue the create marker without touching the network.
        if (!_ui.value.isOnline) {
            maintenanceCreateSync.enqueue(id, vineyardId, input, clientUpdatedAt)
            _ui.update { it.copy(maintenanceError = "Maintenance log saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(maintenanceBusy = true) }
            try {
                val created = maintenanceRepo.createMaintenanceLog(vineyardId, input, id, clientUpdatedAt)
                _ui.update { st -> st.copy(maintenanceLogs = st.maintenanceLogs.map { if (it.id == id) created else it }, maintenanceBusy = false) }
                // Attach the invoice photo (if one was picked) now that the row exists.
                if (photoUri != null) uploadMaintenancePhoto(created, photoUri) {}
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(maintenanceBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic row
                // back, surface, don't queue as retryable.
                _ui.update { st -> st.copy(maintenanceBusy = false, maintenanceLogs = st.maintenanceLogs.filterNot { it.id == id }, maintenanceError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic row and queue a
                // create marker for automatic replay rather than rolling back.
                maintenanceCreateSync.enqueue(id, vineyardId, input, clientUpdatedAt)
                _ui.update { it.copy(maintenanceBusy = false, maintenanceError = "Maintenance log saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Edit an existing maintenance log (Android Stage K-2 — offline/retryable).
     * The client_updated_at is minted up front so the optimistic edit, any
     * folded create payload, and the eventual server PATCH all share one
     * last-writer-wins stamp. Paths:
     *
     *  - Optimistic: replace the row immediately so the operator sees the edit.
     *  - Edit-before-create fold: if the same log still has an unresolved create,
     *    rewrite that create payload in place (no UPDATE marker queued) so the
     *    eventual insert carries the edited values directly.
     *  - Known-offline (no pending create): skip the network and coalesce one
     *    MAINTENANCE_LOG / UPDATE marker for automatic replay.
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic edit and fold/queue a
     *    marker.
     *  - Permanent (validation / permission) rejection: restore the previous list
     *    and surface the error; never queued as retryable. Unauthorized signs
     *    out.
     */
    fun updateMaintenanceLog(id: String, input: MaintenanceLogRepository.MaintenanceInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.maintenanceLogs
        val vineyardId = _ui.value.selectedVineyardId
        val clientUpdatedAt = Instant.now().toString()
        // Optimistic edit in place — the operator sees the change straight away.
        _ui.update { st -> st.copy(maintenanceLogs = st.maintenanceLogs.map { if (it.id == id) it.applyMaintenanceInput(input) else it }, maintenanceError = null) }

        // Known-offline: fold into a pending create if present, else coalesce one
        // UPDATE marker. No network.
        if (!_ui.value.isOnline) {
            queueMaintenanceEdit(id, vineyardId, input, clientUpdatedAt)
            _ui.update { it.copy(maintenanceError = "Maintenance log saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(maintenanceBusy = true) }
            try {
                val updated = maintenanceRepo.updateMaintenanceLog(id, input, clientUpdatedAt)
                _ui.update { st -> st.copy(maintenanceLogs = st.maintenanceLogs.map { if (it.id == id) updated else it }, maintenanceBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(maintenanceBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — restore the previous list,
                // surface, don't queue as retryable.
                _ui.update { it.copy(maintenanceBusy = false, maintenanceLogs = previous, maintenanceError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic edit and
                // fold/queue a marker for automatic replay rather than rolling back.
                queueMaintenanceEdit(id, vineyardId, input, clientUpdatedAt)
                _ui.update { it.copy(maintenanceBusy = false, maintenanceError = "Maintenance log saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Route a maintenance-log edit to the right outbox marker (Android Stage
     * K-2). If the same log still has an unresolved CREATE, fold the edit into
     * that create payload (no UPDATE queued); otherwise coalesce a single
     * MAINTENANCE_LOG / UPDATE marker. Folding needs no vineyard id (the pending
     * create already carries it); a standalone update falls back to the optimistic
     * row's scope when no selection is available.
     */
    private fun queueMaintenanceEdit(
        id: String,
        vineyardId: String?,
        input: MaintenanceLogRepository.MaintenanceInput,
        clientUpdatedAt: String,
    ) {
        if (maintenanceCreateSync.foldEdit(id, input, clientUpdatedAt)) return
        val scope = vineyardId
            ?: _ui.value.maintenanceLogs.firstOrNull { it.id == id }?.vineyardId
            ?: return
        maintenanceUpdateSync.enqueue(id, scope, input, clientUpdatedAt)
    }

    /**
     * Soft-delete a maintenance log (Android Stage K-3 — offline/retryable).
     * Paths:
     *
     *  - Delete-before-create cancellation: if the log still has an unresolved
     *    CREATE, drop that create (and any same-log update) marker and remove the
     *    optimistic row locally — no DELETE marker is queued and the soft-delete
     *    RPC is never called, since the server never saw the log.
     *  - Optimistic hide for a synced log: remove it from the list immediately.
     *  - Known-offline: skip the network and coalesce one MAINTENANCE_LOG /
     *    DELETE marker for automatic replay through [MaintenanceLogDeleteSync].
     *  - Online success: leave no marker.
     *  - Transient online failure: keep the row hidden and enqueue/coalesce a
     *    DELETE marker.
     *  - Permanent (validation / permission) rejection — e.g. an operator who may
     *    create/edit but not delete: restore the previous list, surface the
     *    error, and never queue as retryable. Unauthorized signs out.
     */
    fun deleteMaintenanceLog(id: String, onResult: (Boolean) -> Unit) {
        // Local-only offline-created log: cancel the queued create (and any
        // same-log update) instead of sending a server delete, so
        // MaintenanceLogCreateSync can never resurrect it. The log never existed
        // server-side, so no DELETE marker is queued and the RPC is skipped.
        if (maintenanceDeleteSync.cancelLocalCreate(id)) {
            _ui.update { st -> st.copy(maintenanceLogs = st.maintenanceLogs.filterNot { it.id == id }, maintenanceError = null) }
            onResult(true)
            return
        }

        val previous = _ui.value.maintenanceLogs
        // Optimistic hide for a synced log.
        _ui.update { st -> st.copy(maintenanceLogs = st.maintenanceLogs.filterNot { it.id == id }, maintenanceError = null) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            maintenanceDeleteSync.enqueue(id)
            _ui.update { it.copy(maintenanceError = "Maintenance log deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                maintenanceRepo.softDeleteMaintenanceLog(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — restore, surface, don't queue.
                _ui.update { it.copy(maintenanceLogs = previous, maintenanceError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                maintenanceDeleteSync.enqueue(id)
                _ui.update { it.copy(maintenanceError = "Maintenance log deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    fun clearMaintenanceError() {
        _ui.update { it.copy(maintenanceError = null) }
    }

    /**
     * Compress and upload an invoice/receipt photo for an existing maintenance
     * log, then persist the `photo_path` reference. The shared
     * `vineyard-maintenance-photos` bucket means iOS and Android read the same
     * image. Reports a friendly error on failure without disturbing the rest of
     * the log's data.
     */
    fun uploadMaintenancePhoto(log: MaintenanceLog, uri: Uri, onResult: (Boolean) -> Unit) {
        val vineyardId = log.vineyardId
        _ui.update { it.copy(maintenancePhotoBusy = true, maintenanceError = null) }
        viewModelScope.launch {
            try {
                val jpeg = PinPhotoImageUtil.compress(getApplication(), uri)
                val path = maintenancePhotoRepo.upload(vineyardId, log.id, jpeg)
                val updated = maintenanceRepo.updatePhotoPath(log.id, path)
                _ui.update { st ->
                    st.copy(
                        maintenanceLogs = st.maintenanceLogs.map { if (it.id == log.id) updated else it },
                        maintenancePhotoBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(maintenancePhotoBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(maintenancePhotoBusy = false, maintenanceError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(maintenancePhotoBusy = false, maintenanceError = "Couldn't upload the photo. Check your connection and try again.") }
                onResult(false)
            }
        }
    }

    /** Remove a maintenance log's invoice photo from storage and clear its reference. */
    fun removeMaintenancePhoto(log: MaintenanceLog, onResult: (Boolean) -> Unit) {
        val path = log.photoPath
        if (path.isNullOrBlank()) { onResult(true); return }
        _ui.update { it.copy(maintenancePhotoBusy = true, maintenanceError = null) }
        viewModelScope.launch {
            try {
                runCatching { maintenancePhotoRepo.delete(path) }
                val updated = maintenanceRepo.updatePhotoPath(log.id, null)
                _ui.update { st ->
                    st.copy(
                        maintenanceLogs = st.maintenanceLogs.map { if (it.id == log.id) updated else it },
                        maintenancePhotoBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(maintenancePhotoBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(maintenancePhotoBusy = false, maintenanceError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(maintenancePhotoBusy = false, maintenanceError = "Couldn't remove the photo. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Mint a signed URL so Coil can load the private maintenance invoice photo. */
    fun requestMaintenancePhotoUrl(path: String, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            try {
                onResult(maintenancePhotoRepo.signedUrl(path))
            } catch (e: Exception) {
                onResult(null)
            }
        }
    }

    // MARK: - Fuel log write path

    /**
     * Record a new fuel fill (Tier-A Stage H-1 — offline/retryable). The id and
     * client_updated_at are minted up front so the same id is shared by the
     * optimistic local row, the queued FUEL_LOG / CREATE marker, and the
     * eventual server insert. Paths:
     *
     *  - Optimistic: prepend the fill immediately so the operator sees it.
     *  - Known-offline: skip the network and enqueue one create marker for
     *    automatic replay through [FuelLogCreateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic row and enqueue a marker.
     *  - Permanent (validation / permission) rejection: roll the optimistic row
     *    back and surface the error; never queued as retryable. Unauthorized
     *    signs out.
     */
    fun createFuelLog(input: FuelLogRepository.FuelInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = fuelRepo.newId()
        val clientUpdatedAt = Instant.now().toString()
        val optimistic = TractorFuelLog(
            id = id,
            vineyardId = vineyardId,
            tractorId = input.tractorId,
            machineId = input.machineId,
            fillDatetime = input.fillDatetime,
            litresAdded = input.litresAdded,
            engineHours = input.engineHours,
            operatorUserId = session.userId,
            operatorName = input.operatorName,
            costPerLitre = input.costPerLitre,
            totalCost = input.totalCost,
            filledToFull = input.filledToFull,
            notes = input.notes,
        )
        // Optimistic insert at the top — the operator sees the fill straight away.
        _ui.update { it.copy(fuelLogs = listOf(optimistic) + it.fuelLogs, fuelError = null) }

        // Known-offline: queue the create marker without touching the network.
        if (!_ui.value.isOnline) {
            fuelCreateSync.enqueue(id, vineyardId, input, clientUpdatedAt)
            _ui.update { it.copy(fuelError = "Fuel log saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(fuelBusy = true) }
            try {
                val created = fuelRepo.createFuelLog(vineyardId, input, id, clientUpdatedAt)
                _ui.update { st -> st.copy(fuelLogs = st.fuelLogs.map { if (it.id == id) created else it }, fuelBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(fuelBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic row
                // back, surface, don't queue as retryable.
                _ui.update { st -> st.copy(fuelBusy = false, fuelLogs = st.fuelLogs.filterNot { it.id == id }, fuelError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic row and queue a
                // create marker for automatic replay rather than rolling back.
                fuelCreateSync.enqueue(id, vineyardId, input, clientUpdatedAt)
                _ui.update { it.copy(fuelBusy = false, fuelError = "Fuel log saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Edit an existing fuel fill (Tier-A Stage H-2 — offline/retryable). The edit
     * is applied optimistically first, then resolved by path:
     *
     *  - Edit-before-create: if the same log still has an unresolved create, the
     *    edit is folded into that create payload (no UPDATE marker) so the
     *    eventual insert carries the latest values; Sync Status stays "Fuel log".
     *  - Known-offline: skip the network and enqueue/coalesce one FUEL_LOG /
     *    UPDATE marker for automatic replay through [FuelLogUpdateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic edit and enqueue a marker
     *    (or fold into a pending create).
     *  - Permanent (validation / permission) rejection: roll the row back to its
     *    previous state and surface the error; never queued. Unauthorized signs
     *    out.
     */
    fun updateFuelLog(id: String, input: FuelLogRepository.FuelInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.fuelLogs
        val clientUpdatedAt = Instant.now().toString()
        // Optimistic edit — the operator sees the change straight away. Preserve
        // server-managed fields (operatorUserId etc.) by copying the existing row.
        _ui.update { st ->
            st.copy(
                fuelLogs = st.fuelLogs.map {
                    if (it.id == id) it.copy(
                        machineId = input.machineId,
                        tractorId = input.tractorId,
                        fillDatetime = input.fillDatetime,
                        litresAdded = input.litresAdded,
                        engineHours = input.engineHours,
                        operatorName = input.operatorName,
                        costPerLitre = input.costPerLitre,
                        totalCost = input.totalCost,
                        filledToFull = input.filledToFull,
                        notes = input.notes,
                    ) else it
                },
                fuelError = null,
            )
        }

        // Edit-before-create: fold into the still-pending create rather than
        // queueing a separate UPDATE (and never PATCH a row that doesn't exist).
        if (fuelCreateSync.foldEdit(id, input, clientUpdatedAt)) {
            _ui.update { it.copy(fuelError = "Fuel log edit saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        // Known-offline: queue the update marker without touching the network.
        if (!_ui.value.isOnline) {
            fuelUpdateSync.enqueue(id, input, clientUpdatedAt)
            _ui.update { it.copy(fuelError = "Fuel log edit saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(fuelBusy = true) }
            try {
                val updated = fuelRepo.updateFuelLog(id, input, clientUpdatedAt)
                _ui.update { st -> st.copy(fuelLogs = st.fuelLogs.map { if (it.id == id) updated else it }, fuelBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(fuelBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic edit
                // back, surface, don't queue as retryable.
                _ui.update { it.copy(fuelBusy = false, fuelLogs = previous, fuelError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic edit and queue
                // an update marker for automatic replay rather than rolling back.
                fuelUpdateSync.enqueue(id, input, clientUpdatedAt)
                _ui.update { it.copy(fuelBusy = false, fuelError = "Fuel log edit saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Soft-delete a fuel fill (Tier-A Stage H-3 — offline/retryable), optimistically
     * removing it. Resolved by path:
     *
     *  - Local-only cancellation: if the log still has an unresolved create, it was
     *    never sent to the server — cancel the queued create (and any same-log
     *    update) and drop the optimistic row, with no DELETE marker and no RPC, so
     *    [FuelLogCreateSync] can never resurrect it.
     *  - Known-offline: skip the network and enqueue/coalesce one FUEL_LOG / DELETE
     *    marker for automatic replay through [FuelLogDeleteSync].
     *  - Online success: behaves as before; no marker.
     *  - Transient online failure: keep the optimistic hide and enqueue a marker.
     *  - Permanent (validation / permission) rejection: restore the previous fuel
     *    list and surface the error; never queued. Unauthorized signs out.
     */
    fun deleteFuelLog(id: String, onResult: (Boolean) -> Unit) {
        // Local-only offline-created log: cancel the queued create (and any same-log
        // update) instead of sending a server delete, so FuelLogCreateSync can never
        // resurrect it.
        val pendingCreate = pendingWrites.list().firstOrNull {
            it.entityType == PendingEntityType.FUEL_LOG &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (pendingCreate != null) {
            pendingWrites.remove(pendingCreate.id)
            pendingWrites.list()
                .filter {
                    it.entityType == PendingEntityType.FUEL_LOG &&
                        it.opType == PendingOpType.UPDATE &&
                        it.clientId == id &&
                        it.status != PendingWriteStatus.SYNCED
                }
                .forEach { pendingWrites.remove(it.id) }
            _ui.update { st -> st.copy(fuelLogs = st.fuelLogs.filterNot { it.id == id }) }
            onResult(true)
            return
        }

        val previous = _ui.value.fuelLogs
        // Optimistic hide for a synced log.
        _ui.update { st -> st.copy(fuelLogs = st.fuelLogs.filterNot { it.id == id }) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            fuelDeleteSync.enqueue(id)
            _ui.update { it.copy(fuelError = "Fuel log deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                fuelRepo.softDeleteFuelLog(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll back, surface, don't queue.
                _ui.update { it.copy(fuelLogs = previous, fuelError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                fuelDeleteSync.enqueue(id)
                _ui.update { it.copy(fuelError = "Fuel log deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    fun clearFuelError() {
        _ui.update { it.copy(fuelError = null) }
    }

    // MARK: - Growth-stage record write path

    /**
     * Log a new growth-stage observation (Android Stage N-1 — offline/retryable).
     * The record id and client_updated_at are minted up front so the same
     * identity is shared by the optimistic local row, the queued GROWTH_RECORD /
     * CREATE marker, and the eventual server insert. Paths:
     *
     *  - Optimistic: prepend the record immediately so the operator sees it.
     *  - Known-offline: skip the network and enqueue one create marker for
     *    automatic replay through [GrowthRecordCreateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic row and enqueue a marker.
     *  - Permanent (validation / permission) rejection: roll the optimistic row
     *    back and surface the error; never queued as retryable. Unauthorized
     *    signs out.
     *
     * Photo upload/removal remains online-only (parked); this path never queues
     * photo writes.
     */
    fun createGrowthStageRecord(input: GrowthStageRecordRepository.GrowthInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = java.util.UUID.randomUUID().toString()
        val now = java.time.Instant.now().toString()
        val optimistic = growthRepo.buildGrowthRecord(vineyardId, input, id, now)
        // Optimistic insert at the top — the operator sees the observation straight away.
        _ui.update { it.copy(growthRecords = listOf(optimistic) + it.growthRecords, growthError = null) }

        // Known-offline: queue the create marker without touching the network.
        if (!_ui.value.isOnline) {
            growthCreateSync.enqueue(optimistic, now)
            _ui.update { it.copy(growthError = "Observation saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(growthBusy = true) }
            try {
                val created = growthRepo.createGrowthStageRecord(vineyardId, input, id, now)
                _ui.update { st -> st.copy(growthRecords = st.growthRecords.map { if (it.id == id) created else it }, growthBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(growthBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic row
                // back, surface, don't queue as retryable.
                _ui.update { st -> st.copy(growthBusy = false, growthRecords = st.growthRecords.filterNot { it.id == id }, growthError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic row and queue a
                // create marker for automatic replay rather than rolling back.
                growthCreateSync.enqueue(optimistic, now)
                _ui.update { it.copy(growthBusy = false, growthError = "Observation saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Edit an existing growth-stage observation (Android Stage N-2 —
     * offline/retryable). Mints [clientUpdatedAt] and builds the full updated
     * optimistic snapshot before any network, then:
     *
     *  - Optimistic edit in place: the operator sees the change immediately;
     *    existing pin/photo/created-at and other non-form fields are preserved.
     *  - Known-offline: fold into a pending create if present, else coalesce one
     *    GROWTH_RECORD / UPDATE marker. No network.
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic edit and fold/queue a
     *    marker for automatic replay.
     *  - Permanent (validation / permission) rejection: restore the previous list
     *    and surface the error; never queued as retryable. Unauthorized signs out.
     *
     * Photo upload/removal stays online-only; this path never queues photo writes
     * and never sends photo paths in the UPDATE payload (the optimistic snapshot
     * keeps existing paths only for display).
     */
    fun updateGrowthStageRecord(id: String, input: GrowthStageRecordRepository.GrowthInput, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.growthRecords
        val current = previous.firstOrNull { it.id == id } ?: run { onResult(false); return }
        val clientUpdatedAt = java.time.Instant.now().toString()
        val optimistic = current.applyGrowthInput(input)
        // Optimistic edit in place — the operator sees the change straight away.
        _ui.update { st -> st.copy(growthRecords = st.growthRecords.map { if (it.id == id) optimistic else it }, growthError = null) }

        // Known-offline: fold into a pending create if present, else coalesce one
        // UPDATE marker. No network.
        if (!_ui.value.isOnline) {
            queueGrowthEdit(optimistic, clientUpdatedAt)
            _ui.update { it.copy(growthError = "Observation saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(growthBusy = true) }
            try {
                val updated = growthRepo.updateGrowthStageRecord(id, input, clientUpdatedAt)
                _ui.update { st -> st.copy(growthRecords = st.growthRecords.map { if (it.id == id) updated else it }, growthBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(growthBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — restore the previous list,
                // surface, don't queue as retryable.
                _ui.update { it.copy(growthBusy = false, growthRecords = previous, growthError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic edit and
                // fold/queue a marker for automatic replay rather than rolling back.
                queueGrowthEdit(optimistic, clientUpdatedAt)
                _ui.update { it.copy(growthBusy = false, growthError = "Observation saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Route a growth-record edit to the right outbox marker (Android Stage N-2).
     * If the same record still has an unresolved CREATE, fold the edit into that
     * create payload (no UPDATE queued); otherwise coalesce a single
     * GROWTH_RECORD / UPDATE marker. The [record] snapshot carries the stable id
     * and vineyard scope the queue needs.
     */
    private fun queueGrowthEdit(record: GrowthStageRecord, clientUpdatedAt: String) {
        if (growthCreateSync.foldEdit(record, clientUpdatedAt)) return
        growthUpdateSync.enqueue(record, clientUpdatedAt)
    }

    /**
     * Soft-delete a growth-stage observation (Android Stage N-3 —
     * offline/retryable). Cancels a still-pending local create in place, hides a
     * synced record optimistically, queues a GROWTH_RECORD / DELETE marker when
     * offline or after a transient failure, and rolls the row back on a permanent
     * permission/validation rejection (operators may create/edit but not delete).
     */
    fun deleteGrowthStageRecord(id: String, onResult: (Boolean) -> Unit) {
        // Local-only offline-created record: cancel the queued create (and any
        // same-record update) instead of sending a server delete, so
        // GrowthRecordCreateSync can never resurrect it. The record never existed
        // server-side, so no DELETE marker is queued and the RPC is skipped.
        if (growthDeleteSync.cancelLocalCreate(id)) {
            _ui.update { st -> st.copy(growthRecords = st.growthRecords.filterNot { it.id == id }, growthError = null) }
            onResult(true)
            return
        }

        val previous = _ui.value.growthRecords
        // Optimistic hide for a synced record.
        _ui.update { st -> st.copy(growthRecords = st.growthRecords.filterNot { it.id == id }, growthError = null) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            growthDeleteSync.enqueue(id)
            _ui.update { it.copy(growthError = "Observation deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                growthRepo.softDeleteGrowthStageRecord(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — restore, surface, don't queue.
                _ui.update { it.copy(growthRecords = previous, growthError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                growthDeleteSync.enqueue(id)
                _ui.update { it.copy(growthError = "Observation deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    fun clearGrowthError() {
        _ui.update { it.copy(growthError = null) }
    }

    // MARK: - Growth-stage record photos

    /**
     * Compress and upload a single photo for a directly-authored growth-stage
     * record, then persist the `photo_paths` reference. Mirrors iOS's one-photo
     * contract and the pin-photo flow: the record row is untouched until the
     * storage upload succeeds, and pin-mirrored records are never edited here.
     */
    fun uploadGrowthPhoto(record: GrowthStageRecord, uri: Uri, onResult: (Boolean) -> Unit) {
        if (record.isFromPin) { onResult(false); return }
        _ui.update { it.copy(growthPhotoBusy = true, growthError = null) }
        viewModelScope.launch {
            try {
                val jpeg = PinPhotoImageUtil.compress(getApplication(), uri)
                val path = pinPhotoRepo.uploadAtPath(
                    pinPhotoRepo.growthStoragePath(record.vineyardId, record.id),
                    jpeg,
                )
                val updated = growthRepo.updatePhotoPaths(record.id, listOf(path))
                _ui.update { st ->
                    st.copy(
                        growthRecords = st.growthRecords.map { if (it.id == record.id) updated else it },
                        growthPhotoBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(growthPhotoBusy = false) }
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(growthPhotoBusy = false, growthError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(growthPhotoBusy = false, growthError = "Couldn't upload the photo. Check your connection and try again.") }
                onResult(false)
            }
        }
    }

    /** Remove a growth-stage record's photo from storage and clear its reference. */
    fun removeGrowthPhoto(record: GrowthStageRecord, onResult: (Boolean) -> Unit) {
        if (record.isFromPin) { onResult(false); return }
        val path = record.photoPaths?.firstOrNull()
        if (path.isNullOrBlank()) { onResult(true); return }
        _ui.update { it.copy(growthPhotoBusy = true, growthError = null) }
        viewModelScope.launch {
            try {
                pinPhotoRepo.delete(path)
                val updated = growthRepo.updatePhotoPaths(record.id, null)
                _ui.update { st ->
                    st.copy(
                        growthRecords = st.growthRecords.map { if (it.id == record.id) updated else it },
                        growthPhotoBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(growthPhotoBusy = false) }
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(growthPhotoBusy = false, growthError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(growthPhotoBusy = false, growthError = "Couldn't remove the photo. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Mint a signed URL so Coil can load a private growth-record photo (shared bucket). */
    fun requestGrowthPhotoUrl(path: String, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            try {
                onResult(pinPhotoRepo.signedUrl(path))
            } catch (e: Exception) {
                onResult(null)
            }
        }
    }

    // MARK: - Paddock phenology write path

    /**
     * PATCH only a block's phenology milestone dates (budburst/flowering/
     * veraison/harvest). Optimistically updates the cached paddock and rolls
     * back on failure. Geometry, rows, variety, and area are never touched.
     */
    fun updatePaddockPhenologyDates(paddockId: String, dates: PaddockRepository.PhenologyDates, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.paddocks
        _ui.update { st ->
            st.copy(paddocks = st.paddocks.map {
                if (it.id == paddockId) it.copy(
                    budburstDate = dates.budburstDate,
                    floweringDate = dates.floweringDate,
                    veraisonDate = dates.veraisonDate,
                    harvestDate = dates.harvestDate,
                ) else it
            }, growthError = null)
        }
        viewModelScope.launch {
            try {
                val updated = paddockRepo.updatePhenologyDates(paddockId, dates)
                _ui.update { st -> st.copy(paddocks = st.paddocks.map { if (it.id == paddockId) updated else it }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(paddocks = previous) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(paddocks = previous, growthError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(paddocks = previous, growthError = "Couldn't save phenology dates. Check your connection.") }
                onResult(false)
            }
        }
    }

    /**
     * PATCH only a block's variety allocations. Powers the Optimal Ripeness
     * "Fix Block Varieties" sheet. Optimistically updates the cached paddock and
     * rolls back on failure; geometry, rows, and phenology dates are untouched.
     */
    fun updatePaddockVarietyAllocations(
        paddockId: String,
        allocations: List<PaddockVarietyAllocation>,
        onResult: (Boolean) -> Unit,
    ) {
        val previous = _ui.value.paddocks
        _ui.update { st ->
            st.copy(
                paddocks = st.paddocks.map {
                    if (it.id == paddockId) it.copy(varietyAllocations = allocations) else it
                },
                growthError = null,
            )
        }
        viewModelScope.launch {
            try {
                val updated = paddockRepo.updateVarietyAllocations(paddockId, allocations)
                _ui.update { st -> st.copy(paddocks = st.paddocks.map { if (it.id == paddockId) updated else it }) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(paddocks = previous) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(paddocks = previous, growthError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(paddocks = previous, growthError = "Couldn't save varieties. Check your connection.") }
                onResult(false)
            }
        }
    }

    // MARK: - Block (paddock) create / edit / delete write path

    /**
     * Create or update a block. Mirrors iOS `EditPaddockSheet.savePaddock` +
     * `store.addPaddock`/`updatePaddock`: rows are (re)generated from the
     * boundary polygon and row config via [calculateRowLines], then the full
     * row is upserted (`paddocks` on-conflict `id`). Optimistically inserts/
     * replaces the cached block and reconciles with the server-resolved row.
     */
    fun savePaddock(
        existing: Paddock?,
        name: String,
        polygonPoints: List<CoordinatePoint>,
        rowDirection: Double,
        rowCount: Int,
        rowWidth: Double,
        rowOffset: Double,
        rowStartNumber: Int,
        rowNumberAscending: Boolean,
        vineSpacing: Double?,
        intermediatePostSpacing: Double?,
        flowPerEmitter: Double?,
        emitterSpacing: Double?,
        vineCountOverride: Int?,
        rowLengthOverride: Double?,
        plantingYear: Int?,
        calculationModeOverride: String?,
        resetModeOverride: String?,
        varietyAllocations: List<PaddockVarietyAllocation>,
        budburstDate: String?,
        floweringDate: String?,
        veraisonDate: String?,
        harvestDate: String?,
        onResult: (Boolean) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId
        if (vineyardId == null) {
            _ui.update { it.copy(blockEditError = "Select a vineyard first.") }
            onResult(false)
            return
        }
        val lines = calculateRowLines(polygonPoints, rowDirection, maxOf(rowCount, 0), rowWidth, rowOffset)
        val rows: List<PaddockRow> = (0 until maxOf(rowCount, 0)).map { index ->
            val number = if (rowNumberAscending) rowStartNumber + index else rowStartNumber + (rowCount - 1 - index)
            val line = lines.getOrNull(index)
            PaddockRow(
                number = number,
                startPoint = line?.start ?: CoordinatePoint(0.0, 0.0),
                endPoint = line?.end ?: CoordinatePoint(0.0, 0.0),
            )
        }
        val candidate = (existing ?: Paddock(id = java.util.UUID.randomUUID().toString(), vineyardId = vineyardId, name = name)).copy(
            vineyardId = vineyardId,
            name = name,
            polygonPoints = polygonPoints,
            rows = rows,
            rowDirection = rowDirection,
            rowWidth = rowWidth,
            rowOffset = rowOffset,
            vineSpacing = vineSpacing,
            vineCountOverride = vineCountOverride,
            rowLengthOverride = rowLengthOverride,
            flowPerEmitter = flowPerEmitter,
            emitterSpacing = emitterSpacing,
            intermediatePostSpacing = intermediatePostSpacing,
            varietyAllocations = varietyAllocations,
            budburstDate = budburstDate,
            floweringDate = floweringDate,
            veraisonDate = veraisonDate,
            harvestDate = harvestDate,
            plantingYear = plantingYear,
            calculationModeOverride = calculationModeOverride,
            resetModeOverride = resetModeOverride,
        )
        val previous = _ui.value.paddocks
        val isUpdate = existing != null
        _ui.update { st ->
            val list = if (isUpdate) st.paddocks.map { if (it.id == candidate.id) candidate else it }
            else st.paddocks + candidate
            st.copy(paddocks = list.sortedBy { it.name.lowercase() }, blockEditError = null)
        }
        viewModelScope.launch {
            try {
                val saved = paddockRepo.upsertPaddock(candidate, createdBy = session.userId)
                _ui.update { st ->
                    st.copy(paddocks = st.paddocks.map { if (it.id == saved.id) saved else it }
                        .sortedBy { it.name.lowercase() })
                }
                session.userId?.let { uid -> domainCache.savePaddocks(uid, vineyardId, _ui.value.paddocks) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(paddocks = previous) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(paddocks = previous, blockEditError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(paddocks = previous, blockEditError = "Couldn't save block. Check your connection.") }
                onResult(false)
            }
        }
    }

    /**
     * Bulk-import blocks parsed from a JSON file (iOS BlocksHubView import).
     * Upserts each paddock into the current vineyard, optimistically merging
     * them into the list, then persists to the server and local cache. Reports
     * the parsed summary on success or a user-facing error on failure.
     */
    fun importPaddocks(
        rawJson: String,
        onResult: (summary: PaddockTransferService.ImportSummary?, error: String?) -> Unit,
    ) {
        val vineyardId = _ui.value.selectedVineyardId
        if (vineyardId == null) {
            onResult(null, "Select a vineyard before importing.")
            return
        }
        val parse = try {
            PaddockTransferService.parseJson(rawJson, vineyardId, _ui.value.paddocks)
        } catch (e: PaddockTransferService.ImportError) {
            onResult(null, e.userMessage)
            return
        } catch (e: Exception) {
            onResult(null, "This file is not a valid VineTrack blocks JSON file.")
            return
        }
        val previous = _ui.value.paddocks
        // Optimistic merge: replace matching ids, append new ones.
        _ui.update { st ->
            val byId = st.paddocks.associateBy { it.id }.toMutableMap()
            for (p in parse.paddocks) byId[p.id] = p
            st.copy(paddocks = byId.values.sortedBy { it.name.lowercase() }, blockEditError = null)
        }
        viewModelScope.launch {
            try {
                for (paddock in parse.paddocks) {
                    val saved = paddockRepo.upsertPaddock(paddock, createdBy = session.userId)
                    _ui.update { st ->
                        st.copy(paddocks = st.paddocks.map { if (it.id == saved.id) saved else it }
                            .sortedBy { it.name.lowercase() })
                    }
                }
                session.userId?.let { uid -> domainCache.savePaddocks(uid, vineyardId, _ui.value.paddocks) }
                onResult(parse.summary, null)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(paddocks = previous) }; signOut(); onResult(null, "Your session expired. Sign in and try again.")
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(paddocks = previous) }
                onResult(null, friendlyWriteError(e.code))
            } catch (e: Exception) {
                _ui.update { it.copy(paddocks = previous) }
                onResult(null, "Couldn't import blocks. Check your connection.")
            }
        }
    }

    /** Archive (soft-delete) a block. Optimistically removes it from the list. */
    fun archivePaddock(paddockId: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.paddocks
        _ui.update { st -> st.copy(paddocks = st.paddocks.filterNot { it.id == paddockId }, blockEditError = null) }
        viewModelScope.launch {
            try {
                paddockRepo.softDeletePaddock(paddockId)
                session.userId?.let { uid -> _ui.value.selectedVineyardId?.let { vid -> domainCache.savePaddocks(uid, vid, _ui.value.paddocks) } }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(paddocks = previous) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(paddocks = previous, blockEditError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(paddocks = previous, blockEditError = "Couldn't archive block. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Permanently delete a block (server enforces zero linked records). */
    fun hardDeletePaddock(paddockId: String, onResult: (Boolean) -> Unit) {
        val previous = _ui.value.paddocks
        _ui.update { st -> st.copy(paddocks = st.paddocks.filterNot { it.id == paddockId }, blockEditError = null) }
        viewModelScope.launch {
            try {
                paddockRepo.hardDeletePaddock(paddockId)
                session.userId?.let { uid -> _ui.value.selectedVineyardId?.let { vid -> domainCache.savePaddocks(uid, vid, _ui.value.paddocks) } }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(paddocks = previous) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(paddocks = previous, blockEditError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                _ui.update { it.copy(paddocks = previous, blockEditError = "Couldn't delete block. Check your connection.") }
                onResult(false)
            }
        }
    }

    /** Fetch a block's linked-record reference counts (for the delete gate). */
    fun loadPaddockReferenceCounts(paddockId: String, onResult: (PaddockReferenceCounts?) -> Unit) {
        viewModelScope.launch {
            try {
                onResult(paddockRepo.paddockReferenceCounts(paddockId))
            } catch (e: Exception) {
                onResult(null)
            }
        }
    }

    fun clearBlockEditError() {
        _ui.update { it.copy(blockEditError = null) }
    }

    // MARK: - Yield record write path

    /**
     * Archive a single block's actual yield (Android Stage L-1 —
     * offline/retryable). Mirrors iOS's `RecordActualYieldSheet`: one block per
     * Android-authored record, consumed by Cost Reports for cost-per-tonne. The
     * record id, block-result id and client_updated_at are minted up front so
     * the same identity is shared by the optimistic local row, the queued
     * YIELD_RECORD / CREATE marker, and the eventual server insert. Paths:
     *
     *  - Optimistic: prepend the record immediately so the operator sees it.
     *  - Known-offline: skip the network and enqueue one create marker for
     *    automatic replay through [YieldRecordCreateSync].
     *  - Online success: reconcile the optimistic row with the returned server
     *    row; no marker.
     *  - Transient online failure: keep the optimistic row and enqueue a marker.
     *  - Permanent (validation / permission) rejection: roll the optimistic row
     *    back and surface the error; never queued as retryable. Unauthorized
     *    signs out.
     */
    fun createYieldRecord(input: YieldRepository.CreateInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = java.util.UUID.randomUUID().toString()
        val blockResultId = java.util.UUID.randomUUID().toString()
        val now = java.time.Instant.now().toString()
        val optimistic = yieldRepo.buildActualRecord(vineyardId, input, id, blockResultId, now)
        // Optimistic insert at the top — the operator sees the record straight away.
        _ui.update { it.copy(yieldRecords = listOf(optimistic) + it.yieldRecords, yieldError = null) }

        // Known-offline: queue the create marker without touching the network.
        if (!_ui.value.isOnline) {
            yieldCreateSync.enqueue(optimistic, now)
            _ui.update { it.copy(yieldError = "Yield record saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(yieldBusy = true) }
            try {
                val created = yieldRepo.createYieldRecord(vineyardId, input, id, blockResultId, now, now)
                _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.map { if (it.id == id) created else it }, yieldBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(yieldBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic row
                // back, surface, don't queue as retryable.
                _ui.update { st -> st.copy(yieldBusy = false, yieldRecords = st.yieldRecords.filterNot { it.id == id }, yieldError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic row and queue a
                // create marker for automatic replay rather than rolling back.
                yieldCreateSync.enqueue(optimistic, now)
                _ui.update { it.copy(yieldBusy = false, yieldError = "Yield record saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Create a sampling-based estimate record (Android Stage L-1 —
     * offline/retryable). Mirrors the iOS estimate flow: the block stores the
     * sampling snapshot plus the computed estimated tonnes, with no actual
     * recorded yet. Identity (record id, block-result id, client_updated_at) is
     * minted up front; same offline/optimistic/replay paths as
     * [createYieldRecord].
     */
    fun createYieldEstimate(input: YieldRepository.EstimateInput, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId ?: run { onResult(false); return }
        val id = java.util.UUID.randomUUID().toString()
        val blockResultId = java.util.UUID.randomUUID().toString()
        val now = java.time.Instant.now().toString()
        val optimistic = yieldRepo.buildEstimateRecord(vineyardId, input, id, blockResultId, now)
        _ui.update { it.copy(yieldRecords = listOf(optimistic) + it.yieldRecords, yieldError = null) }

        if (!_ui.value.isOnline) {
            yieldCreateSync.enqueue(optimistic, now)
            _ui.update { it.copy(yieldError = "Estimate saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(yieldBusy = true) }
            try {
                val created = yieldRepo.createEstimateRecord(vineyardId, input, id, blockResultId, now, now)
                _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.map { if (it.id == id) created else it }, yieldBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(yieldBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { st -> st.copy(yieldBusy = false, yieldRecords = st.yieldRecords.filterNot { it.id == id }, yieldError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                yieldCreateSync.enqueue(optimistic, now)
                _ui.update { it.copy(yieldBusy = false, yieldError = "Estimate saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Re-author an existing single-block estimate record from new sampling
     * inputs, preserving any recorded actual (Android Stage L-2 —
     * offline/retryable). Identity (record id, vineyard id, archived-at) is
     * preserved; [clientUpdatedAt] is minted before the network. The full updated
     * snapshot is built up front and used for the optimistic row, the queued
     * payload and the PATCH so all three carry identical values.
     *
     *  - Optimistic: replace the record in place immediately.
     *  - Known-offline: skip the network and fold into a pending create if
     *    present, else coalesce one UPDATE marker.
     *  - Online success: reconcile by id; no marker.
     *  - Transient online failure: keep the optimistic edit and fold/queue.
     *  - Permanent (validation / permission) rejection: restore the previous
     *    list and surface the error; never queued. Unauthorized signs out.
     */
    fun updateYieldEstimate(
        record: HistoricalYieldRecord,
        input: YieldRepository.EstimateInput,
        onResult: (Boolean) -> Unit,
    ) {
        val previous = _ui.value.yieldRecords
        val clientUpdatedAt = java.time.Instant.now().toString()
        val optimistic = yieldRepo.buildUpdatedEstimateRecord(record, input)
        _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.map { if (it.id == record.id) optimistic else it }, yieldError = null) }

        if (!_ui.value.isOnline) {
            queueYieldEdit(optimistic, clientUpdatedAt)
            _ui.update { it.copy(yieldError = "Estimate saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        _ui.update { it.copy(yieldBusy = true) }
        viewModelScope.launch {
            try {
                val saved = yieldRepo.updateEstimateRecord(record, input, clientUpdatedAt)
                _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.map { if (it.id == record.id) saved else it }, yieldBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(yieldRecords = previous, yieldBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(yieldRecords = previous, yieldBusy = false, yieldError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                queueYieldEdit(optimistic, clientUpdatedAt)
                _ui.update { it.copy(yieldBusy = false, yieldError = "Estimate saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Route a yield-record edit to the right outbox marker (Android Stage L-2).
     * If the same record still has an unresolved CREATE, fold the edit into that
     * create payload (no UPDATE queued); otherwise coalesce a single
     * YIELD_RECORD / UPDATE marker. The [record] snapshot carries the full edited
     * state (id, vineyard id, archived-at, totals, notes, block results).
     */
    private fun queueYieldEdit(record: HistoricalYieldRecord, clientUpdatedAt: String) {
        if (yieldCreateSync.foldEdit(record, clientUpdatedAt)) return
        yieldUpdateSync.enqueue(record, clientUpdatedAt)
    }

    /**
     * Edit a record's per-block actual yields and notes. Recomputes each block's
     * actual-recorded timestamp/per-hectare and the record's actual total before
     * patching; the estimated totals are preserved. Optimistic with rollback.
     */
    fun updateYieldActuals(
        record: HistoricalYieldRecord,
        actualsByBlockId: Map<String, Double?>,
        notes: String,
        onResult: (Boolean) -> Unit,
    ) {
        val previous = _ui.value.yieldRecords
        val clientUpdatedAt = java.time.Instant.now().toString()
        val updatedBlocks = record.blocks.map { block ->
            val newActual = actualsByBlockId[block.id]
            // Keep the original recorded timestamp when the actual is unchanged.
            val recordedAt = when {
                newActual == null -> null
                newActual == block.actualYieldTonnes -> block.actualRecordedAt ?: clientUpdatedAt
                else -> clientUpdatedAt
            }
            block.copy(
                actualYieldTonnes = newActual,
                actualRecordedAt = recordedAt,
            )
        }
        val optimistic = record.copy(blockResults = updatedBlocks, notes = notes.trim())
        _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.map { if (it.id == record.id) optimistic else it }, yieldError = null) }

        if (!_ui.value.isOnline) {
            queueYieldEdit(optimistic, clientUpdatedAt)
            _ui.update { it.copy(yieldError = "Yield record saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        _ui.update { it.copy(yieldBusy = true) }
        viewModelScope.launch {
            try {
                val saved = yieldRepo.updateYieldRecord(
                    id = optimistic.id,
                    season = optimistic.season,
                    year = optimistic.year,
                    totalYieldTonnes = optimistic.totalYieldTonnes,
                    totalAreaHectares = optimistic.totalAreaHectares,
                    notes = optimistic.notes,
                    blockResults = updatedBlocks,
                    clientUpdatedAt = clientUpdatedAt,
                )
                _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.map { if (it.id == record.id) saved else it }, yieldBusy = false) }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(yieldRecords = previous, yieldBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(yieldRecords = previous, yieldBusy = false, yieldError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                queueYieldEdit(optimistic, clientUpdatedAt)
                _ui.update { it.copy(yieldBusy = false, yieldError = "Yield record saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Soft-delete a yield record (Android Stage L-3 — offline/retryable). The
     * optimistic hide happens immediately, then one of:
     *  - Local-only offline-created record: cancel the queued create (and any
     *    same-record update) instead of sending a server delete, so
     *    [YieldRecordCreateSync] can never resurrect it. No DELETE marker is
     *    queued and the RPC is skipped.
     *  - Known-offline / transient failure: keep the hide and queue a
     *    YIELD_RECORD / DELETE marker for automatic replay.
     *  - Clean online success: leaves no marker.
     *  - Permanent (validation / permission) rejection — e.g. an operator who may
     *    create/edit but not delete: restore the previous list, surface the
     *    error, and never queue as retryable. Unauthorized signs out.
     */
    fun deleteYieldRecord(id: String, onResult: (Boolean) -> Unit) {
        // Local-only offline-created record: cancel the queued create (and any
        // same-record update) instead of sending a server delete, so
        // YieldRecordCreateSync can never resurrect it. The record never existed
        // server-side, so no DELETE marker is queued and the RPC is skipped.
        if (yieldDeleteSync.cancelLocalCreate(id)) {
            _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.filterNot { it.id == id }, yieldError = null) }
            onResult(true)
            return
        }

        val previous = _ui.value.yieldRecords
        // Optimistic hide for a synced record.
        _ui.update { st -> st.copy(yieldRecords = st.yieldRecords.filterNot { it.id == id }, yieldError = null) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            yieldDeleteSync.enqueue(id)
            _ui.update { it.copy(yieldError = "Yield record deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                yieldRepo.softDeleteYieldRecord(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — restore, surface, don't queue.
                _ui.update { it.copy(yieldRecords = previous, yieldError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                yieldDeleteSync.enqueue(id)
                _ui.update { it.copy(yieldError = "Yield record deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    fun clearYieldError() {
        _ui.update { it.copy(yieldError = null) }
    }

    // MARK: - Damage record write path

    /**
     * Create or update a block-damage record (online-first with optimistic UI,
     * mirroring the iOS Record/Edit Damage flow). The caller hands us a fully
     * formed [DamageRecord] (id already minted for creates); we apply it to state
     * immediately, then reconcile with the server row or roll back on failure.
     */
    fun saveDamageRecord(record: DamageRecord, isNew: Boolean, onResult: (Boolean) -> Unit) {
        val vineyardId = _ui.value.selectedVineyardId
        if (vineyardId == null) { onResult(false); return }
        val clientUpdatedAt = Instant.now().toString()
        val scoped = record.copy(vineyardId = vineyardId, date = record.date ?: clientUpdatedAt)
        val previous = _ui.value.damageRecords
        // Optimistic insert/edit — the operator sees the change straight away.
        _ui.update { st ->
            val next = if (isNew) listOf(scoped) + st.damageRecords
            else st.damageRecords.map { if (it.id == scoped.id) scoped else it }
            st.copy(damageRecords = next, damageError = null)
        }

        // Known-offline: queue the right marker without touching the network.
        if (!_ui.value.isOnline) {
            queueDamageWrite(scoped, isNew, clientUpdatedAt)
            _ui.update { it.copy(damageError = "Damage record saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(damageBusy = true) }
            try {
                val saved = if (isNew) damageRepo.insertDamageRecord(scoped, clientUpdatedAt)
                else damageRepo.updateDamageRecord(scoped, clientUpdatedAt)
                _ui.update { st ->
                    st.copy(
                        damageRecords = st.damageRecords.map { if (it.id == saved.id) saved else it },
                        damageBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(damageBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                // Validation / permission / rejection — roll the optimistic change
                // back, surface, don't queue as retryable.
                _ui.update { it.copy(damageRecords = previous, damageBusy = false, damageError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic change and queue a
                // marker for automatic replay rather than rolling back.
                queueDamageWrite(scoped, isNew, clientUpdatedAt)
                _ui.update { it.copy(damageBusy = false, damageError = "Damage record saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Route a damage-record write to the right outbox marker (Android Stage M).
     * A create queues a DAMAGE_RECORD / CREATE marker. An edit folds into a
     * still-pending create if present (no UPDATE queued) so a create+edit pair
     * replays as a single edited insert; otherwise it coalesces one
     * DAMAGE_RECORD / UPDATE marker.
     */
    private fun queueDamageWrite(record: DamageRecord, isNew: Boolean, clientUpdatedAt: String) {
        if (isNew) {
            damageCreateSync.enqueue(record, clientUpdatedAt)
            return
        }
        if (damageCreateSync.foldEdit(record, clientUpdatedAt)) return
        damageUpdateSync.enqueue(record, clientUpdatedAt)
    }

    /**
     * Soft-delete a damage record (owner/manager/supervisor only via RLS;
     * Android Stage M-3 — offline/retryable). Paths:
     *
     *  - Delete-before-create cancellation: if the record still has an unresolved
     *    CREATE, drop that create (and any same-record update) marker and remove
     *    the optimistic row locally — no DELETE marker is queued and the RPC is
     *    never called, since the server never saw the record.
     *  - Optimistic hide for a synced record.
     *  - Known-offline: coalesce one DAMAGE_RECORD / DELETE marker.
     *  - Online success: leave no marker.
     *  - Transient online failure: keep the row hidden and enqueue a marker.
     *  - Permanent (validation / permission) rejection: restore, surface, never
     *    queue. Unauthorized signs out.
     */
    fun deleteDamageRecord(id: String, onResult: (Boolean) -> Unit) {
        // Local-only offline-created record: cancel the queued create instead of
        // sending a server delete, so DamageRecordCreateSync can't resurrect it.
        if (damageDeleteSync.cancelLocalCreate(id)) {
            _ui.update { st -> st.copy(damageRecords = st.damageRecords.filterNot { it.id == id }, damageError = null) }
            onResult(true)
            return
        }

        val previous = _ui.value.damageRecords
        _ui.update { st -> st.copy(damageRecords = st.damageRecords.filterNot { it.id == id }, damageError = null) }

        // Known-offline: queue the soft-delete marker without touching the network.
        if (!_ui.value.isOnline) {
            damageDeleteSync.enqueue(id)
            _ui.update { it.copy(damageError = "Damage record deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                damageRepo.softDeleteDamageRecord(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(damageRecords = previous, damageError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic hide and queue a
                // soft-delete marker for automatic replay rather than rolling back.
                damageDeleteSync.enqueue(id)
                _ui.update { it.copy(damageError = "Damage record deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    fun clearDamageError() {
        _ui.update { it.copy(damageError = null) }
    }

    // MARK: - Yield estimation sessions (Stage Q)

    /** The working yield-estimation session for the selected vineyard, if any. */
    fun currentYieldSession(): YieldEstimationSession? {
        val vid = _ui.value.selectedVineyardId ?: return null
        return _ui.value.yieldSessions.firstOrNull { it.vineyardId.equals(vid, ignoreCase = true) }
    }

    /**
     * Save (insert or update — server upsert) a yield-estimation session for the
     * selected vineyard. Offline-aware and optimistic: the session is reflected
     * into state immediately, then either upserted online or queued for replay.
     * Both create and edit fold into one YIELD_SESSION / UPDATE marker keyed by
     * the session id.
     */
    fun saveYieldSession(session: YieldEstimationSession, onResult: (Boolean) -> Unit = {}) {
        val vineyardId = _ui.value.selectedVineyardId
        if (vineyardId == null) { onResult(false); return }
        val clientUpdatedAt = Instant.now().toString()
        val scoped = session.copy(vineyardId = vineyardId)
        val previous = _ui.value.yieldSessions
        _ui.update { st ->
            val next = if (st.yieldSessions.any { it.id == scoped.id }) {
                st.yieldSessions.map { if (it.id == scoped.id) scoped else it }
            } else {
                listOf(scoped) + st.yieldSessions
            }
            st.copy(yieldSessions = next, yieldSessionError = null)
        }

        if (!_ui.value.isOnline) {
            yieldSessionSaveSync.enqueue(scoped, clientUpdatedAt)
            _ui.update { it.copy(yieldSessionError = "Estimation saved offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(yieldSessionBusy = true) }
            try {
                val saved = yieldSessionRepo.upsertSession(scoped, clientUpdatedAt)
                _ui.update { st ->
                    st.copy(
                        yieldSessions = st.yieldSessions.map { if (it.id == saved.id) saved else it },
                        yieldSessionBusy = false,
                    )
                }
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                _ui.update { it.copy(yieldSessionBusy = false) }; signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(yieldSessions = previous, yieldSessionBusy = false, yieldSessionError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                yieldSessionSaveSync.enqueue(scoped, clientUpdatedAt)
                _ui.update { it.copy(yieldSessionBusy = false, yieldSessionError = "Estimation saved offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    /**
     * Soft-delete a yield-estimation session (owner/manager/supervisor only via
     * RLS). Offline-aware: optimistic hide, then either the soft-delete RPC
     * online or a queued YIELD_SESSION / DELETE marker. The delete enqueue also
     * cancels any still-pending save for the same session.
     */
    fun deleteYieldSession(id: String, onResult: (Boolean) -> Unit = {}) {
        val previous = _ui.value.yieldSessions
        _ui.update { st -> st.copy(yieldSessions = st.yieldSessions.filterNot { it.id == id }, yieldSessionError = null) }

        if (!_ui.value.isOnline) {
            yieldSessionDeleteSync.enqueue(id)
            _ui.update { it.copy(yieldSessionError = "Estimation deleted offline — will sync when connection is available.") }
            onResult(true)
            return
        }

        viewModelScope.launch {
            try {
                yieldSessionRepo.softDeleteSession(id)
                onResult(true)
            } catch (e: BackendError.Unauthorized) {
                signOut(); onResult(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(yieldSessions = previous, yieldSessionError = friendlyWriteError(e.code)) }
                onResult(false)
            } catch (e: Exception) {
                yieldSessionDeleteSync.enqueue(id)
                _ui.update { it.copy(yieldSessionError = "Estimation deleted offline — will sync when connection is available.") }
                onResult(true)
            }
        }
    }

    fun clearYieldSessionError() {
        _ui.update { it.copy(yieldSessionError = null) }
    }

    private fun friendlyWriteError(code: Int): String = when (code) {
        403 -> "You don't have permission to do that."
        else -> "Something went wrong. Please try again."
    }

    private suspend fun loadVineyardData(vineyardId: String) {
        _ui.update { it.copy(isLoadingVineyardData = true) }
        val userId = session.userId
        var paddockError: String? = null
        var pinError: String? = null
        var paddocksFromServer = false
        var pinsFromServer = false
        var paddocksFromCache = false
        var pinsFromCache = false
        val paddocks = try {
            repo.listPaddocks(vineyardId).also { paddocksFromServer = true }
        } catch (e: BackendError) {
            paddockError = e.message
            // Prefer existing in-memory data; otherwise hydrate from the read-cache (Stage 6B).
            _ui.value.paddocks.ifEmpty {
                domainCache.loadPaddocks(userId, vineyardId)?.also { paddocksFromCache = true } ?: emptyList()
            }
        } catch (e: Exception) {
            paddockError = "Couldn't load blocks. Check your connection."
            _ui.value.paddocks.ifEmpty {
                domainCache.loadPaddocks(userId, vineyardId)?.also { paddocksFromCache = true } ?: emptyList()
            }
        }
        val pins = try {
            repo.listPins(vineyardId).also { pinsFromServer = true }
        } catch (e: BackendError) {
            pinError = e.message
            cachedPinsOrExisting(userId, vineyardId)?.also { pinsFromCache = true } ?: _ui.value.pins
        } catch (e: Exception) {
            pinError = "Couldn't load pins. Check your connection."
            cachedPinsOrExisting(userId, vineyardId)?.also { pinsFromCache = true } ?: _ui.value.pins
        }
        // Write-through (Stage 6A): only persist genuinely fresh server reads so a
        // good cache is never clobbered by an offline fallback to existing state.
        if (paddocksFromServer) domainCache.savePaddocks(userId, vineyardId, paddocks)
        if (pinsFromServer) domainCache.savePins(userId, vineyardId, pins)
        var tripError: String? = null
        var tripsFromServer = false
        var tripsFromCache = false
        // Historical trips are an operational list; soft-fail to existing, then to
        // the Stage P-4 server-snapshot cache so an offline restart still shows the
        // last known finished trips. Snapshot-only — trip pending markers are
        // scalar deltas, not reconstructable rows, so NO pending-write overlay is
        // applied to trips. The active trip remains governed by ActiveTripStore.
        val loadedTrips = try {
            repo.listTrips(vineyardId).also { tripsFromServer = true }
        } catch (e: BackendError) {
            tripError = e.message
            _ui.value.trips.ifEmpty {
                domainCache.loadTrips(userId, vineyardId)?.also { tripsFromCache = true } ?: emptyList()
            }
        } catch (e: Exception) {
            tripError = "Couldn't load trips. Check your connection."
            _ui.value.trips.ifEmpty {
                domainCache.loadTrips(userId, vineyardId)?.also { tripsFromCache = true } ?: emptyList()
            }
        }
        // Write-through (Stage P-4): persist only genuinely fresh server reads, and
        // only the raw server list — written BEFORE restoreActiveTrip() so a
        // restored active-trip provisional row is never baked into the historical
        // snapshot. A trip already present in the server list is cached normally.
        if (tripsFromServer) domainCache.saveTrips(userId, vineyardId, loadedTrips)
        // Tier-A Stage A: restore the durable local active-trip snapshot so an
        // in-progress trip survives process death / offline launch / silent
        // autosave failure. Local-only — no replay, no server writes.
        val trips = restoreActiveTrip(userId, vineyardId, loadedTrips, tripsFromServer)
        // Equipment + work tasks are reference lists used by the trip forms.
        // They're non-critical, so failures fall back to the existing list
        // (or empty) without surfacing an error.
        val machines = try {
            repo.listMachines(vineyardId)
        } catch (e: Exception) {
            _ui.value.machines
        }
        // Work-task headers are now an operational cached list (Stage P-3); soft-
        // fail to existing, then to the server-snapshot cache so an offline
        // restart still shows the last known headers as an overlay baseline.
        var workTasksFromServer = false
        var workTasksFromCache = false
        val workTasks = try {
            repo.listWorkTasks(vineyardId).also { workTasksFromServer = true }
        } catch (e: Exception) {
            _ui.value.workTasks.ifEmpty {
                domainCache.loadWorkTasks(userId, vineyardId)?.also { workTasksFromCache = true } ?: emptyList()
            }
        }
        // Work-task -> paddock join rows (sql/051) let a task span multiple
        // blocks. Optional reference list — soft-fail to the existing set so a
        // fetch hiccup never blanks the block selection on the task editor.
        val workTaskPaddocks = try {
            workTaskPaddockRepo.listForVineyard(vineyardId)
        } catch (e: Exception) {
            _ui.value.workTaskPaddocks
        }
        // Team members + operator categories back the trip operator picker.
        // Both are optional reference lists — soft-fail to the existing list
        // (or empty) so the Trips screen still works if either is unavailable.
        val members = try {
            repo.listTeamMembers(vineyardId)
        } catch (e: Exception) {
            _ui.value.members
        }
        val operatorCategories = try {
            repo.listOperatorCategories(vineyardId)
        } catch (e: Exception) {
            _ui.value.operatorCategories
        }
        // Custom trip functions are an optional reference list backing the trip
        // start picker + Settings; soft-fail to the existing list (or empty).
        val vineyardTripFunctions = try {
            tripFunctionRepo.fetchAll(vineyardId)
        } catch (e: Exception) {
            _ui.value.vineyardTripFunctions
        }
        // Spray records are an operational list; soft-fail to existing, then to
        // the Stage P-2 server-snapshot cache so an offline restart still shows
        // the last known server rows as an overlay baseline.
        var sprayFromServer = false
        var sprayFromCache = false
        val sprayRecords = try {
            repo.listSprayRecords(vineyardId).also { sprayFromServer = true }
        } catch (e: Exception) {
            _ui.value.sprayRecords.ifEmpty {
                domainCache.loadSpray(userId, vineyardId)?.also { sprayFromCache = true } ?: emptyList()
            }
        }
        // Spray equipment is an optional reference list backing the spray form
        // picker; soft-fail to the existing list (or empty).
        val sprayEquipment = try {
            repo.listSprayEquipment(vineyardId)
        } catch (e: Exception) {
            _ui.value.sprayEquipment
        }
        // Saved chemicals back the spray-form chemical picker + costing prefill;
        // optional reference list, soft-fail to the existing list (or empty).
        val savedChemicals = try {
            repo.listSavedChemicals(vineyardId)
        } catch (e: Exception) {
            _ui.value.savedChemicals
        }
        // Saved inputs back the seeding-trip cost-per-unit resolution + the
        // Saved Inputs management list; optional reference, soft-fail to existing.
        val savedInputs = try {
            repo.listSavedInputs(vineyardId)
        } catch (e: Exception) {
            _ui.value.savedInputs
        }
        // Saved tank presets back the spray-form "Apply preset" action; optional
        // reference list, soft-fail to the existing list (or empty).
        val savedSprayPresets = try {
            repo.listSavedSprayPresets(vineyardId)
        } catch (e: Exception) {
            _ui.value.savedSprayPresets
        }
        // Maintenance logs are an operational list; soft-fail to the existing
        // list, then to the Stage O-2 server-snapshot cache so an offline restart
        // still shows the last known server rows as an overlay baseline.
        var maintenanceFromServer = false
        var maintenanceFromCache = false
        val maintenanceLogs = try {
            repo.listMaintenanceLogs(vineyardId).also { maintenanceFromServer = true }
        } catch (e: Exception) {
            _ui.value.maintenanceLogs.ifEmpty {
                domainCache.loadMaintenance(userId, vineyardId)?.also { maintenanceFromCache = true } ?: emptyList()
            }
        }
        // Growth-stage observations are an operational list; soft-fail to existing,
        // then to the Stage O-2 server-snapshot cache.
        var growthFromServer = false
        var growthFromCache = false
        val growthRecords = try {
            repo.listGrowthStageRecords(vineyardId).also { growthFromServer = true }
        } catch (e: Exception) {
            _ui.value.growthRecords.ifEmpty {
                domainCache.loadGrowth(userId, vineyardId)?.also { growthFromCache = true } ?: emptyList()
            }
        }
        // Fuel logs are an operational list; soft-fail to existing, then to the
        // Stage P-1 server-snapshot cache.
        var fuelFromServer = false
        var fuelFromCache = false
        val fuelLogs = try {
            repo.listFuelLogs(vineyardId).also { fuelFromServer = true }
        } catch (e: Exception) {
            _ui.value.fuelLogs.ifEmpty {
                domainCache.loadFuel(userId, vineyardId)?.also { fuelFromCache = true } ?: emptyList()
            }
        }
        // Fuel purchases back the owner/manager trip fuel-cost estimate (3F-3a).
        // Read-only operational list; soft-fail to the existing list (or empty).
        val fuelPurchases = try {
            repo.listFuelPurchases(vineyardId)
        } catch (e: Exception) {
            _ui.value.fuelPurchases
        }
        // Other equipment items back the Equipment area + Maintenance picker;
        // optional reference list, soft-fail to the existing list (or empty).
        val equipmentItems = try {
            equipmentItemRepo.list(vineyardId)
        } catch (e: Exception) {
            _ui.value.equipmentItems
        }
        // Per-vineyard launcher button configuration shared with iOS/portal.
        // Read-only on Android; soft-fail to the existing config (or empty so the
        // launcher falls back to its built-in defaults).
        val launcherButtons = try {
            buttonConfigRepo.fetch(vineyardId)
        } catch (e: Exception) {
            ButtonConfigRepository.LauncherButtons(
                repair = _ui.value.repairButtons,
                growth = _ui.value.growthButtons,
            )
        }
        // Grape variety catalog is an optional read-only reference list backing
        // the agronomy Varieties surface; soft-fail to the existing list (or empty).
        val grapeVarieties = try {
            repo.listGrapeVarieties(vineyardId)
        } catch (e: Exception) {
            _ui.value.grapeVarieties
        }
        // Archived seasonal yield records are an operational list; soft-fail to
        // existing, then to the Stage O-2 server-snapshot cache.
        var yieldFromServer = false
        var yieldFromCache = false
        val yieldRecords = try {
            yieldRepo.listYieldRecords(vineyardId).also { yieldFromServer = true }
        } catch (e: Exception) {
            _ui.value.yieldRecords.ifEmpty {
                domainCache.loadYield(userId, vineyardId)?.also { yieldFromCache = true } ?: emptyList()
            }
        }
        // Block-damage records are an operational list; soft-fail to existing,
        // then to the server-snapshot cache (matches the yield fallback).
        var damageFromServer = false
        val damageRecords = try {
            damageRepo.listDamageRecords(vineyardId).also { damageFromServer = true }
        } catch (e: Exception) {
            _ui.value.damageRecords.ifEmpty {
                domainCache.loadDamage(userId, vineyardId) ?: emptyList()
            }
        }
        // Yield-estimation working sessions (Stage Q): same soft-fail ladder —
        // existing state, then the server-snapshot cache.
        var yieldSessionsFromServer = false
        val yieldSessions = try {
            yieldSessionRepo.listSessions(vineyardId).also { yieldSessionsFromServer = true }
        } catch (e: Exception) {
            _ui.value.yieldSessions.ifEmpty {
                domainCache.loadYieldSessions(userId, vineyardId) ?: emptyList()
            }
        }
        // Write-through (Stage O-2): persist only genuinely fresh server reads so a
        // good cache is never clobbered by an offline fallback. Written before the
        // O-1 overlay so the cache stays a clean server snapshot (no optimistic
        // pending rows leak into it).
        if (maintenanceFromServer) domainCache.saveMaintenance(userId, vineyardId, maintenanceLogs)
        if (growthFromServer) domainCache.saveGrowth(userId, vineyardId, growthRecords)
        if (yieldFromServer) domainCache.saveYield(userId, vineyardId, yieldRecords)
        if (damageFromServer) domainCache.saveDamage(userId, vineyardId, damageRecords)
        if (yieldSessionsFromServer) domainCache.saveYieldSessions(userId, vineyardId, yieldSessions)
        if (fuelFromServer) domainCache.saveFuel(userId, vineyardId, fuelLogs)
        if (sprayFromServer) domainCache.saveSpray(userId, vineyardId, sprayRecords)
        if (workTasksFromServer) domainCache.saveWorkTasks(userId, vineyardId, workTasks)
        // Pending-write restart hydration (Stage O-1): overlay any unresolved
        // outbox markers for the selected vineyard so offline creates/edits/
        // deletes survive an offline app restart rather than vanishing until
        // reconnection. Pure/local — no marker is mutated and no network fires.
        // When the server read succeeded the overlay is a near no-op (synced
        // markers are gone); when it fell back to an empty/cached baseline the
        // overlay restores the optimistic rows. Limited to the safe single-entity
        // modules: maintenance, yield and growth-stage.
        val pendingSnapshot = pendingWrites.list()
        val overlaidMaintenance =
            PendingWriteOverlay.overlayMaintenance(maintenanceLogs, pendingSnapshot, vineyardId)
        val overlaidGrowth =
            PendingWriteOverlay.overlayGrowth(growthRecords, pendingSnapshot, vineyardId)
        val overlaidYield =
            PendingWriteOverlay.overlayYield(yieldRecords, pendingSnapshot, vineyardId)
        val overlaidFuel =
            PendingWriteOverlay.overlayFuel(fuelLogs, pendingSnapshot, vineyardId)
        val overlaidSpray =
            PendingWriteOverlay.overlaySpray(sprayRecords, pendingSnapshot, vineyardId)
        // Work-task header overlay (Stage P-3). Child labour/machine lines load
        // per task in loadTaskLines() — not here — and are overlaid there behind a
        // parent gate against this (already-overlaid) header set.
        val overlaidWorkTasks =
            PendingWriteOverlay.overlayWorkTaskHeaders(workTasks, pendingSnapshot, vineyardId)
        // Block-damage overlay (Android Stage M): restore offline damage
        // creates/edits/deletes after a cold restart.
        val overlaidDamage =
            PendingWriteOverlay.overlayDamage(damageRecords, pendingSnapshot, vineyardId)
        // Yield-session overlay (Android Stage Q): restore an offline session
        // save/delete after a cold restart.
        val overlaidYieldSessions =
            PendingWriteOverlay.overlayYieldSessions(yieldSessions, pendingSnapshot, vineyardId)
        // Launcher button overlay (Android Stage N): restore an offline button
        // layout edit over the fetched/default config.
        val (overlaidRepairButtons, overlaidGrowthButtons) =
            PendingWriteOverlay.overlayButtonConfig(
                launcherButtons.repair,
                launcherButtons.growth,
                pendingSnapshot,
                vineyardId,
            )
        // App-wide notices ("system messages") are an optional, app-scoped read.
        // Soft-fail to the existing list so a fetch hiccup never blanks the
        // Home banner; dismissals stay device-local.
        val appNotices = try {
            repo.listActiveNotices()
        } catch (e: Exception) {
            _ui.value.appNotices
        }
        _ui.update {
            it.copy(
                paddocks = paddocks,
                pins = pins,
                trips = trips,
                machines = machines,
                workTasks = overlaidWorkTasks,
                workTaskPaddocks = PendingWriteOverlay.overlayWorkTaskPaddocks(
                    workTaskPaddocks,
                    pendingSnapshot,
                    vineyardId,
                ),
                members = members,
                operatorCategories = operatorCategories,
                vineyardTripFunctions = vineyardTripFunctions,
                sprayRecords = overlaidSpray,
                sprayEquipment = sprayEquipment,
                savedChemicals = savedChemicals,
                savedInputs = savedInputs,
                savedSprayPresets = savedSprayPresets,
                maintenanceLogs = overlaidMaintenance,
                growthRecords = overlaidGrowth,
                fuelLogs = overlaidFuel,
                fuelPurchases = fuelPurchases,
                equipmentItems = equipmentItems,
                repairButtons = overlaidRepairButtons,
                growthButtons = overlaidGrowthButtons,
                currentUserId = session.userId,
                grapeVarieties = grapeVarieties,
                yieldRecords = overlaidYield,
                damageRecords = overlaidDamage,
                yieldSessions = overlaidYieldSessions,
                isLoadingVineyardData = false,
                paddockError = paddockError,
                pinError = pinError,
                tripError = tripError,
                appNotices = appNotices,
                // Showing saved field data when either launch-critical list came
                // from the cache; cleared once a fresh server read replaces it.
                isUsingCachedFieldData = it.isUsingCachedFieldData ||
                    paddocksFromCache || pinsFromCache ||
                    maintenanceFromCache || growthFromCache || yieldFromCache ||
                    fuelFromCache || sprayFromCache || workTasksFromCache || tripsFromCache,
                cachedFieldDataLastSyncedAt = if (
                    paddocksFromCache || pinsFromCache ||
                    maintenanceFromCache || growthFromCache || yieldFromCache ||
                    fuelFromCache || sprayFromCache || workTasksFromCache || tripsFromCache
                ) {
                    it.cachedFieldDataLastSyncedAt
                        ?: domainCache.pinsSyncedAt(userId, vineyardId)
                        ?: domainCache.paddocksSyncedAt(userId, vineyardId)
                        ?: domainCache.maintenanceSyncedAt(userId, vineyardId)
                        ?: domainCache.growthSyncedAt(userId, vineyardId)
                        ?: domainCache.yieldSyncedAt(userId, vineyardId)
                        ?: domainCache.fuelSyncedAt(userId, vineyardId)
                        ?: domainCache.spraySyncedAt(userId, vineyardId)
                        ?: domainCache.workTasksSyncedAt(userId, vineyardId)
                        ?: domainCache.tripsSyncedAt(userId, vineyardId)
                } else {
                    it.cachedFieldDataLastSyncedAt
                },
            )
        }
        refreshCacheStatus()
    }

    /**
     * Cached pins for [vineyardId] reconciled with any optimistic offline-created
     * pins still in the outbox (Stage 6B). The cache predates those queued
     * creates, so we keep queued pins (matched by their client UUID) visible and
     * de-duplicate by id. Returns null when no owner-matched pin cache exists so
     * the caller falls back to existing in-memory state.
     */
    private fun cachedPinsOrExisting(userId: String?, vineyardId: String): List<Pin>? {
        val cached = domainCache.loadPins(userId, vineyardId) ?: return null
        val cachedIds = cached.map { it.id }.toSet()
        val queuedIds = pendingWrites.list()
            .filter { it.entityType == PendingEntityType.PIN && it.opType == PendingOpType.CREATE }
            .map { it.clientId }
            .toSet()
        val optimistic = _ui.value.pins.filter { it.id in queuedIds && it.id !in cachedIds }
        return optimistic + cached
    }

    /**
     * Recompute the read-cache status surfaced on the Sync Status screen
     * (Stage 6A). Reads only from the local [DomainCacheRepository]; this never
     * hydrates app state or drives routing.
     */
    private fun refreshCacheStatus() {
        val userId = session.userId
        val selected = _ui.value.selectedVineyardId
        val status = DomainCacheStatus(
            hasVineyards = domainCache.loadVineyards(userId) != null,
            vineyardsSyncedAt = domainCache.vineyardsSyncedAt(userId),
            paddockCount = selected?.let { domainCache.loadPaddocks(userId, it)?.size } ?: 0,
            pinCount = selected?.let { domainCache.loadPins(userId, it)?.size } ?: 0,
            selectedSyncedAt = selected?.let { domainCache.paddocksSyncedAt(userId, it) },
        )
        _ui.update { it.copy(cacheStatus = status) }
    }

    /**
     * Owner/manager save of the Repairs or Growth launcher buttons. Persists the
     * full button set to the shared `vineyard_button_configs` contract (last-write-
     * wins) then reloads from the server so iOS-saved metadata stays canonical.
     * Non-authorised callers are short-circuited; RLS is the final guard.
     *
     * @param mode "Repairs" or "Growth".
     * @param buttons the full button list (8 entries: 4 rows paired Left/Right).
     */
    fun saveLauncherButtons(mode: String, buttons: List<LauncherButton>, onDone: (Boolean) -> Unit = {}) {
        val vineyardId = _ui.value.selectedVineyardId
        if (vineyardId == null || !_ui.value.canEditLauncherButtons) {
            onDone(false)
            return
        }
        val configType = if (mode == "Growth") "growth_buttons" else "repair_buttons"
        val sorted = buttons.sortedBy { it.index }
        val previousRepair = _ui.value.repairButtons
        val previousGrowth = _ui.value.growthButtons
        val clientUpdatedAt = Instant.now().toString()
        // Optimistic apply — the launcher reflects the new layout immediately.
        _ui.update {
            if (configType == "growth_buttons") it.copy(growthButtons = sorted, buttonConfigError = null)
            else it.copy(repairButtons = sorted, buttonConfigError = null)
        }

        // Known-offline: coalesce one BUTTON_CONFIG / UPDATE marker without
        // touching the network.
        if (!_ui.value.isOnline) {
            buttonConfigUpdateSync.enqueue(vineyardId, configType, sorted, clientUpdatedAt)
            _ui.update { it.copy(buttonConfigError = "Buttons saved offline — will sync when connection is available.") }
            onDone(true)
            return
        }

        viewModelScope.launch {
            _ui.update { it.copy(buttonConfigBusy = true, buttonConfigError = null) }
            try {
                buttonConfigRepo.upsert(vineyardId, configType, sorted, clientUpdatedAt)
                // Re-read so the UI reflects exactly what the server stored.
                val refreshed = buttonConfigRepo.fetch(vineyardId)
                _ui.update {
                    it.copy(
                        repairButtons = refreshed.repair,
                        growthButtons = refreshed.growth,
                        buttonConfigBusy = false,
                    )
                }
                onDone(true)
            } catch (e: BackendError.Unauthorized) {
                // Permission rejection — restore the previous layout, surface, don't queue.
                _ui.update { it.copy(repairButtons = previousRepair, growthButtons = previousGrowth, buttonConfigBusy = false, buttonConfigError = "Only owners and managers can change these buttons.") }
                onDone(false)
            } catch (e: BackendError.Server) {
                _ui.update { it.copy(repairButtons = previousRepair, growthButtons = previousGrowth, buttonConfigBusy = false, buttonConfigError = "Couldn't save buttons. Check your connection and try again.") }
                onDone(false)
            } catch (e: Exception) {
                // Transient network failure — keep the optimistic layout and queue a
                // marker for automatic replay rather than rolling back.
                buttonConfigUpdateSync.enqueue(vineyardId, configType, sorted, clientUpdatedAt)
                _ui.update { it.copy(buttonConfigBusy = false, buttonConfigError = "Buttons saved offline — will sync when connection is available.") }
                onDone(true)
            }
        }
    }
}

/**
 * Planned row sequence to seed onto a calculator-created "Not Started" spray
 * trip (Stage 3B). [trackingPattern] is the iOS-compatible raw value (e.g.
 * "sequential", "freeDrive"); [rowSequence] is empty for Free Drive or when the
 * selected blocks have no row geometry. [totalTanks] comes from the calculator
 * result.
 */
data class SprayJobRowPlan(
    val trackingPattern: String,
    val rowSequence: List<Double>,
    val totalTanks: Int?,
)
