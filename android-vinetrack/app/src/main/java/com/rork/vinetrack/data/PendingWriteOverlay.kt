package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.LauncherButton
import com.rork.vinetrack.data.model.MaintenanceLog
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.TractorFuelLog
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.WorkTaskMachineLine
import com.rork.vinetrack.data.model.WorkTaskPaddock
import com.rork.vinetrack.data.model.YieldEstimationSession
import kotlinx.serialization.json.Json

/**
 * Pending-write read overlay / restart hydration (Android Stage O-1).
 *
 * After an offline app restart the in-memory operational lists are empty and the
 * server reads fail, so an operator's offline creates/edits/deletes would vanish
 * until reconnection. This pure, side-effect-free helper rebuilds the expected
 * local rows by overlaying the *existing* persistent outbox markers
 * ([PendingWriteRepository.list]) on top of whatever baseline is available
 * (fresh server rows, cached rows, or an empty list).
 *
 * Scope (O-1): only the three safest recently-closed single-entity modules are
 * overlaid — maintenance logs, yield records and growth-stage records. Each
 * reuses the coordinator's own CREATE/UPDATE payload shape, so no display
 * metadata is duplicated and no secrets are read (payloads never carry
 * auth/session/tokens/keys, `created_by`, server audit/sync columns, pin-mirror
 * fields or photo paths).
 *
 * This helper NEVER mutates a marker, never marks anything synced, never clears
 * or replays the outbox, never changes attempt counts, and never performs a
 * network call — it only computes a display list. Trips, work-task child lines,
 * spray, fuel, pins and photo markers are deliberately out of scope here.
 *
 * Merge rules (per entity, scoped to the selected vineyard):
 *  - CREATE: reconstruct a display row from the create payload and insert it,
 *    de-duplicated by id (a baseline row with the same id wins — the create has
 *    presumably already synced).
 *  - UPDATE: if a baseline/created row with the same id exists, apply the latest
 *    unresolved update's form-owned fields; if no such row exists, skip — never
 *    invent a row from an update alone.
 *  - DELETE: hide/remove the same-id row. A delete only carries an id, so it is
 *    applied solely against rows already present for the selected vineyard —
 *    cross-vineyard rows are never touched.
 *  - CREATE + DELETE for the same id resolves to no visible row.
 *  - Only unresolved markers ([PendingWriteStatus.unresolved]) are considered;
 *    SYNCED markers and undecodable payloads are ignored.
 */
object PendingWriteOverlay {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /**
     * Overlay unresolved MAINTENANCE_LOG markers for [vineyardId] onto [baseline].
     * CREATE rows are reconstructed, UPDATE form-fields applied to existing rows,
     * DELETE rows hidden.
     */
    fun overlayMaintenance(
        baseline: List<MaintenanceLog>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<MaintenanceLog> {
        val markers = pending.unresolvedFor(PendingEntityType.MAINTENANCE_LOG)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<MaintenanceLogCreateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId && it.id !in baselineIds }
            .map { it.toRow() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<MaintenanceLogUpdateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<MaintenanceLogDeleteSync.Payload>(it)?.maintenanceLogId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved YIELD_RECORD markers for [vineyardId] onto [baseline].
     */
    fun overlayYield(
        baseline: List<HistoricalYieldRecord>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<HistoricalYieldRecord> {
        val markers = pending.unresolvedFor(PendingEntityType.YIELD_RECORD)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<YieldRecordCreateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId && it.id !in baselineIds }
            .map { it.toRow() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<YieldRecordUpdateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<YieldRecordDeleteSync.Payload>(it)?.yieldRecordId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved GROWTH_RECORD markers for [vineyardId] onto [baseline].
     * Reconstructed CREATE rows keep `pin_id` null (Android authors direct
     * records) and carry no photo paths; UPDATE preserves the existing row's
     * pin/photo/geo/created-at fields and changes only the form-owned columns.
     */
    fun overlayGrowth(
        baseline: List<GrowthStageRecord>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<GrowthStageRecord> {
        val markers = pending.unresolvedFor(PendingEntityType.GROWTH_RECORD)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<GrowthRecordCreateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId && it.id !in baselineIds }
            .map { it.toRow() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<GrowthRecordUpdateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<GrowthRecordDeleteSync.Payload>(it)?.growthRecordId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved DAMAGE_RECORD markers for [vineyardId] onto [baseline]
     * (Android Stage M). CREATE rows are reconstructed from the damage create
     * payload, UPDATE form-owned damage fields applied to existing rows, DELETE
     * rows hidden. DELETE markers carry only the damage-record id, so they are
     * applied solely against rows already present for the selected vineyard —
     * cross-vineyard rows are never touched.
     */
    fun overlayDamage(
        baseline: List<DamageRecord>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<DamageRecord> {
        val markers = pending.unresolvedFor(PendingEntityType.DAMAGE_RECORD)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<DamageRecordCreateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId && it.id !in baselineIds }
            .map { it.toRecord() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<DamageRecordUpdateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<DamageRecordDeleteSync.Payload>(it)?.damageRecordId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved YIELD_SESSION markers for [vineyardId] onto [baseline]
     * (Android Stage Q). The whole session lives in the save payload, so a
     * pending SAVE (upsert) replaces an existing baseline row by id or is
     * appended when brand-new; a pending DELETE hides the row. Only the latest
     * unresolved save per session id is applied; other vineyards are never
     * touched. Vineyard id is compared case-insensitively (sessions authored on
     * iOS carry uppercase UUIDs).
     */
    fun overlayYieldSessions(
        baseline: List<YieldEstimationSession>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<YieldEstimationSession> {
        val markers = pending.unresolvedFor(PendingEntityType.YIELD_SESSION)
        if (markers.isEmpty()) return baseline

        val savedById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<YieldSessionSaveSync.Payload>(it)?.session }
            .filter { it.vineyardId.equals(vineyardId, ignoreCase = true) }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<YieldSessionDeleteSync.Payload>(it)?.id }

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val newlyCreated = savedById.values.filter { it.id !in baselineIds }
        return (newlyCreated + baseline)
            .map { row -> savedById[row.id] ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved BUTTON_CONFIG markers for [vineyardId] onto the baseline
     * launcher button lists (Android Stage N). Any pending Repairs/Growth layout
     * the owner saved offline replaces the corresponding baseline list so an
     * offline edit survives a cold restart rather than reverting to the
     * server/default layout. Only the latest unresolved update per config type is
     * applied; other vineyards are never touched.
     */
    fun overlayButtonConfig(
        repairBaseline: List<LauncherButton>,
        growthBaseline: List<LauncherButton>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): Pair<List<LauncherButton>, List<LauncherButton>> {
        val markers = pending.unresolvedFor(PendingEntityType.BUTTON_CONFIG)
        if (markers.isEmpty()) return repairBaseline to growthBaseline

        val latestByType = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<ButtonConfigUpdateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId }
            .associateBy { it.configType }

        val repair = latestByType["repair_buttons"]?.buttons?.sortedBy { it.index } ?: repairBaseline
        val growth = latestByType["growth_buttons"]?.buttons?.sortedBy { it.index } ?: growthBaseline
        return repair to growth
    }

    /**
     * Overlay unresolved FUEL_LOG markers for [vineyardId] onto [baseline]
     * (Stage P-1). CREATE rows are reconstructed from the fuel create payload,
     * UPDATE form-owned fuel fields applied to existing rows, DELETE rows hidden.
     * DELETE markers carry only the fuel-log id, so they are applied solely
     * against rows already present for the selected vineyard — cross-vineyard
     * rows are never touched.
     */
    fun overlayFuel(
        baseline: List<TractorFuelLog>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<TractorFuelLog> {
        val markers = pending.unresolvedFor(PendingEntityType.FUEL_LOG)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<FuelLogCreateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId && it.id !in baselineIds }
            .map { it.toRow() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<FuelLogUpdateSync.Payload>(it) }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<FuelLogDeleteSync.Payload>(it)?.fuelLogId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved SPRAY_RECORD markers for [vineyardId] onto [baseline]
     * (Stage P-2). CREATE rows are reconstructed from the spray create payload
     * (nested tanks preserved), UPDATE form-owned spray fields + tanks applied to
     * existing rows, DELETE rows hidden. Only the plain spray-record CREATE queue
     * is overlaid; trip-coupled spray variants are queued elsewhere and never
     * reconstructed here. DELETE markers carry only the spray-record id, so they
     * are applied solely against rows already present for the selected vineyard —
     * cross-vineyard rows are never touched.
     */
    fun overlaySpray(
        baseline: List<SprayRecord>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<SprayRecord> {
        val markers = pending.unresolvedFor(PendingEntityType.SPRAY_RECORD)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<SprayRecordCreateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId && it.id !in baselineIds }
            .map { it.toRow() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<SprayRecordUpdateSync.Payload>(it) }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<SprayRecordDeleteSync.Payload>(it)?.sprayRecordId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved WORK_TASK header markers for [vineyardId] onto
     * [baseline] (Stage P-3). CREATE rows are reconstructed from the work-task
     * create payload, UPDATE form-owned header fields applied to existing rows,
     * DELETE rows hidden. The update payload carries no vineyard id, so updates
     * apply only against the already vineyard-scoped baseline/created rows;
     * DELETE markers carry only the task id and likewise hide only rows already
     * present for the selected vineyard — cross-vineyard rows are never touched.
     */
    fun overlayWorkTaskHeaders(
        baseline: List<WorkTask>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<WorkTask> {
        val markers = pending.unresolvedFor(PendingEntityType.WORK_TASK)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<WorkTaskCreateSync.Payload>(it) }
            .filter { it.vineyardId == vineyardId && it.id !in baselineIds }
            .map { it.toRow() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<WorkTaskUpdateSync.Payload>(it) }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<WorkTaskDeleteSync.Payload>(it)?.workTaskId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved WORK_TASK_LABOUR markers for a single opened task
     * ([workTaskId]) onto its [baseline] lines (Stage P-3). Child lines load per
     * task, so this is scoped to one task at a time.
     *
     * Parent gate (mandatory): if [workTaskId] is not in [visibleWorkTaskIds]
     * (the final header set after the header overlay/delete pass), every line is
     * hidden — an orphan child is never shown. CREATE lines are reconstructed
     * only when their parent matches the opened, visible task; UPDATE applies
     * only to an existing baseline/created line; DELETE hides by line id. The
     * DB-generated `total_hours` / `total_cost` are left null on reconstructed
     * CREATE rows (the model derives a display fallback) so a pending line is
     * never passed off as a server-confirmed total.
     */
    fun overlayLabourLines(
        baseline: List<WorkTaskLabourLine>,
        pending: List<PendingWrite>,
        visibleWorkTaskIds: Set<String>,
        workTaskId: String,
    ): List<WorkTaskLabourLine> {
        if (workTaskId !in visibleWorkTaskIds) return emptyList()
        val markers = pending.unresolvedFor(PendingEntityType.WORK_TASK_LABOUR)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<WorkTaskLabourSync.UpsertPayload>(it) }
            .filter { it.workTaskId == workTaskId && it.id !in baselineIds }
            .map { it.toRow() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<WorkTaskLabourSync.UpsertPayload>(it) }
            .filter { it.workTaskId == workTaskId }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<WorkTaskLabourSync.DeletePayload>(it)?.labourLineId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved WORK_TASK_MACHINE markers for a single opened task
     * ([workTaskId]) onto its [baseline] lines (Stage P-3). Mirrors
     * [overlayLabourLines]: same parent gate, same CREATE/UPDATE/DELETE rules.
     * The client-supplied `total_machine_cost` carried in the payload is
     * preserved (it is computed client-side, not a pure DB-generated total);
     * `operator_user_id` and `deleted_at` are never invented.
     */
    fun overlayMachineLines(
        baseline: List<WorkTaskMachineLine>,
        pending: List<PendingWrite>,
        visibleWorkTaskIds: Set<String>,
        workTaskId: String,
    ): List<WorkTaskMachineLine> {
        if (workTaskId !in visibleWorkTaskIds) return emptyList()
        val markers = pending.unresolvedFor(PendingEntityType.WORK_TASK_MACHINE)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<WorkTaskMachineSync.UpsertPayload>(it) }
            .filter { it.workTaskId == workTaskId && it.id !in baselineIds }
            .map { it.toRow() }

        val updatesById = markers
            .decodeLatest(PendingOpType.UPDATE) { decode<WorkTaskMachineSync.UpsertPayload>(it) }
            .filter { it.workTaskId == workTaskId }
            .associateBy { it.id }

        val deleteIds = markers.deleteIds { decode<WorkTaskMachineSync.DeletePayload>(it)?.machineLineId }

        return (created + baseline)
            .map { row -> updatesById[row.id]?.applyTo(row) ?: row }
            .filterNot { it.id in deleteIds }
    }

    /**
     * Overlay unresolved WORK_TASK_PADDOCK markers for [vineyardId] onto the
     * fetched [baseline] join rows (Stage R). Unlike the per-task line overlays,
     * the join set is loaded vineyard-wide, so this is scoped by vineyard. CREATE
     * markers reconstruct a join row not already present (by id); DELETE markers
     * hide a row by id. Only one op is ever carried per id (no UPDATE), so no
     * field-merge is needed.
     */
    fun overlayWorkTaskPaddocks(
        baseline: List<WorkTaskPaddock>,
        pending: List<PendingWrite>,
        vineyardId: String,
    ): List<WorkTaskPaddock> {
        val markers = pending.unresolvedFor(PendingEntityType.WORK_TASK_PADDOCK)
        if (markers.isEmpty()) return baseline

        val baselineIds = baseline.mapTo(HashSet()) { it.id }
        val created = markers
            .decodeLatest(PendingOpType.CREATE) { decode<WorkTaskPaddockSync.CreatePayload>(it) }
            .filter { it.vineyardId == vineyardId && it.id !in baselineIds }
            .map { it.toRow() }

        val deleteIds = markers.deleteIds { decode<WorkTaskPaddockSync.DeletePayload>(it)?.workTaskPaddockId }

        return (created + baseline).filterNot { it.id in deleteIds }
    }

    // --- marker filtering helpers -------------------------------------------

    /** Unresolved (pending/in-progress/failed/blocked) markers for one entity type. */
    private fun List<PendingWrite>.unresolvedFor(entityType: String): List<PendingWrite> =
        filter { it.entityType == entityType && it.status in PendingWriteStatus.unresolved }

    /**
     * Decode every marker of [opType] into a typed payload, keeping only the
     * latest per client id (by marker [PendingWrite.updatedAt]) so coalesced /
     * stale duplicates collapse to one — the latest edit wins. Undecodable
     * payloads are dropped.
     */
    private inline fun <T> List<PendingWrite>.decodeLatest(
        opType: String,
        decode: (PendingWrite) -> T?,
    ): List<T> =
        filter { it.opType == opType }
            .groupBy { it.clientId }
            .values
            .mapNotNull { group -> group.maxByOrNull { it.updatedAt }?.let(decode) }

    /** Collect the target ids of every unresolved DELETE marker. */
    private inline fun List<PendingWrite>.deleteIds(idOf: (PendingWrite) -> String?): Set<String> =
        filter { it.opType == PendingOpType.DELETE }.mapNotNull(idOf).toHashSet()

    private inline fun <reified T> decode(write: PendingWrite): T? =
        runCatching { json.decodeFromString<T>(write.payloadJson) }.getOrNull()

    // --- row reconstruction --------------------------------------------------

    private fun WorkTaskPaddockSync.CreatePayload.toRow(): WorkTaskPaddock = WorkTaskPaddock(
        id = id,
        workTaskId = workTaskId,
        vineyardId = vineyardId,
        paddockId = paddockId,
        areaHa = areaHa,
    )

    private fun MaintenanceLogCreateSync.Payload.toRow(): MaintenanceLog = MaintenanceLog(
        id = id,
        vineyardId = vineyardId,
        itemName = itemName,
        equipmentSource = equipmentSource,
        equipmentRefId = equipmentRefId,
        hours = hours,
        machineHours = machineHours,
        workCompleted = workCompleted,
        partsUsed = partsUsed,
        partsCost = partsCost,
        labourCost = labourCost,
        date = date,
        isArchived = isArchived,
        isFinalized = isFinalized,
    )

    private fun MaintenanceLogUpdateSync.Payload.applyTo(row: MaintenanceLog): MaintenanceLog =
        row.copy(
            itemName = itemName,
            equipmentSource = equipmentSource,
            equipmentRefId = equipmentRefId,
            hours = hours,
            machineHours = machineHours,
            workCompleted = workCompleted,
            partsUsed = partsUsed,
            partsCost = partsCost,
            labourCost = labourCost,
            date = date,
            isArchived = isArchived,
            isFinalized = isFinalized,
        )

    private fun DamageRecordUpdateSync.Payload.applyTo(row: DamageRecord): DamageRecord =
        row.copy(
            paddockId = paddockId,
            date = date,
            damageType = damageType,
            damagePercent = damagePercent,
            polygonPoints = polygonPoints,
            notes = notes,
        )

    private fun YieldRecordCreateSync.Payload.toRow(): HistoricalYieldRecord = HistoricalYieldRecord(
        id = id,
        vineyardId = vineyardId,
        season = season,
        year = year,
        archivedAt = archivedAt,
        totalYieldTonnes = totalYieldTonnes,
        totalAreaHectares = totalAreaHectares,
        notes = notes,
        blockResults = blockResults,
    )

    private fun YieldRecordUpdateSync.Payload.applyTo(row: HistoricalYieldRecord): HistoricalYieldRecord =
        row.copy(
            season = season,
            year = year,
            archivedAt = archivedAt,
            totalYieldTonnes = totalYieldTonnes,
            totalAreaHectares = totalAreaHectares,
            notes = notes,
            blockResults = blockResults,
        )

    private fun GrowthRecordCreateSync.Payload.toRow(): GrowthStageRecord = GrowthStageRecord(
        id = id,
        vineyardId = vineyardId,
        paddockId = paddockId,
        pinId = null,
        stageCode = stageCode,
        stageLabel = stageLabel,
        variety = variety,
        observedAt = observedAt,
        rowNumber = rowNumber,
        notes = notes,
    )

    private fun GrowthRecordUpdateSync.Payload.applyTo(row: GrowthStageRecord): GrowthStageRecord =
        row.copy(
            paddockId = paddockId,
            stageCode = stageCode,
            stageLabel = stageLabel,
            variety = variety,
            observedAt = observedAt,
            rowNumber = rowNumber,
            notes = notes,
        )

    private fun FuelLogCreateSync.Payload.toRow(): TractorFuelLog = TractorFuelLog(
        id = id,
        vineyardId = vineyardId,
        tractorId = tractorId,
        machineId = machineId,
        fillDatetime = fillDatetime,
        litresAdded = litresAdded,
        engineHours = engineHours,
        operatorName = operatorName,
        costPerLitre = costPerLitre,
        totalCost = totalCost,
        filledToFull = filledToFull,
        notes = notes,
    )

    private fun FuelLogUpdateSync.Payload.applyTo(row: TractorFuelLog): TractorFuelLog =
        row.copy(
            tractorId = tractorId,
            machineId = machineId,
            fillDatetime = fillDatetime,
            litresAdded = litresAdded,
            engineHours = engineHours,
            operatorName = operatorName,
            costPerLitre = costPerLitre,
            totalCost = totalCost,
            filledToFull = filledToFull,
            notes = notes,
        )

    private fun SprayRecordCreateSync.Payload.toRow(): SprayRecord = SprayRecord(
        id = id,
        vineyardId = vineyardId,
        tripId = tripId,
        date = date,
        startTime = startTime,
        temperature = temperature,
        windSpeed = windSpeed,
        windDirection = windDirection,
        humidity = humidity,
        sprayReference = sprayReference,
        notes = notes,
        numberOfFansJets = numberOfFansJets,
        averageSpeed = averageSpeed,
        equipmentType = equipmentType,
        tractor = tractor,
        tractorGear = tractorGear,
        machineId = machineId,
        sprayEquipmentId = sprayEquipmentId,
        isTemplate = isTemplate,
        operationType = operationType,
        tanks = tanks,
    )

    private fun SprayRecordUpdateSync.Payload.applyTo(row: SprayRecord): SprayRecord =
        row.copy(
            date = date,
            startTime = startTime,
            temperature = temperature,
            windSpeed = windSpeed,
            windDirection = windDirection,
            humidity = humidity,
            sprayReference = sprayReference,
            notes = notes,
            numberOfFansJets = numberOfFansJets,
            averageSpeed = averageSpeed,
            equipmentType = equipmentType,
            tractor = tractor,
            tractorGear = tractorGear,
            machineId = machineId,
            sprayEquipmentId = sprayEquipmentId,
            operationType = operationType,
            tripId = tripId,
            isTemplate = isTemplate,
            tanks = tanks,
        )

    private fun WorkTaskCreateSync.Payload.toRow(): WorkTask = WorkTask(
        id = id,
        vineyardId = vineyardId,
        paddockId = paddockId,
        paddockName = paddockName,
        date = date,
        taskType = taskType,
        durationHours = durationHours,
        notes = notes,
        isFinalized = isFinalized,
    )

    private fun WorkTaskUpdateSync.Payload.applyTo(row: WorkTask): WorkTask =
        row.copy(
            paddockId = paddockId,
            paddockName = paddockName,
            date = date,
            taskType = taskType,
            durationHours = durationHours,
            notes = notes,
            isFinalized = isFinalized,
            finalizedAt = finalizedAt,
            finalizedBy = finalizedBy,
        )

    private fun WorkTaskLabourSync.UpsertPayload.toRow(): WorkTaskLabourLine = WorkTaskLabourLine(
        id = id,
        workTaskId = workTaskId,
        vineyardId = vineyardId,
        workDate = workDate,
        operatorCategoryId = operatorCategoryId,
        workerType = workerType,
        workerCount = workerCount,
        hoursPerWorker = hoursPerWorker,
        hourlyRate = hourlyRate,
        // DB-generated totals are never reconstructed; the model derives a
        // display-only fallback from the inputs.
        totalHours = null,
        totalCost = null,
        notes = notes,
    )

    private fun WorkTaskLabourSync.UpsertPayload.applyTo(row: WorkTaskLabourLine): WorkTaskLabourLine =
        row.copy(
            workDate = workDate,
            operatorCategoryId = operatorCategoryId,
            workerType = workerType,
            workerCount = workerCount,
            hoursPerWorker = hoursPerWorker,
            hourlyRate = hourlyRate,
            notes = notes,
            // Preserve server-generated totals from the baseline row.
        )

    private fun WorkTaskMachineSync.UpsertPayload.toRow(): WorkTaskMachineLine = WorkTaskMachineLine(
        id = id,
        workTaskId = workTaskId,
        vineyardId = vineyardId,
        workDate = workDate,
        equipmentSource = equipmentSource,
        equipmentRefId = equipmentRefId,
        equipmentNameSnapshot = equipmentNameSnapshot,
        operatorCategoryId = operatorCategoryId,
        durationHours = durationHours,
        fuelLitres = fuelLitres,
        fuelCost = fuelCost,
        hourlyMachineRate = hourlyMachineRate,
        totalMachineCost = totalMachineCost,
        notes = notes,
    )

    private fun WorkTaskMachineSync.UpsertPayload.applyTo(row: WorkTaskMachineLine): WorkTaskMachineLine =
        row.copy(
            workDate = workDate,
            equipmentSource = equipmentSource,
            equipmentRefId = equipmentRefId,
            equipmentNameSnapshot = equipmentNameSnapshot,
            operatorCategoryId = operatorCategoryId,
            durationHours = durationHours,
            fuelLitres = fuelLitres,
            fuelCost = fuelCost,
            hourlyMachineRate = hourlyMachineRate,
            totalMachineCost = totalMachineCost,
            notes = notes,
        )
}
