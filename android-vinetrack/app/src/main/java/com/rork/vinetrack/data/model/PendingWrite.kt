package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable

/**
 * Local pending-write / outbox record (Stage 4A-ii — skeleton only).
 *
 * This models a single deferred write that a future offline queue will replay
 * against Supabase once connectivity returns. It is intentionally generic
 * (entity + operation + opaque JSON payload) so any repository can eventually
 * enqueue through it without a bespoke table per entity.
 *
 * IMPORTANT (this slice): nothing in the production write paths enqueues these
 * yet. The model, store, and repository exist purely as plumbing. No replay,
 * retry, or repository write behaviour is wired in.
 *
 * Idempotency: [clientId] is a stable client-generated key the server replay
 * can use to de-duplicate so a retried write never double-applies.
 */
@Serializable
data class PendingWrite(
    /** Local primary key for this outbox row (client-generated UUID string). */
    val id: String,
    /** Which domain entity this write targets (see [PendingEntityType]). */
    val entityType: String,
    /** The operation kind: create / update / delete (see [PendingOpType]). */
    val opType: String,
    /** Opaque serialized payload for the future replay (repository-defined shape). */
    val payloadJson: String,
    /**
     * Stable client-side idempotency key for the affected record. Lets the
     * eventual replay de-duplicate so a retried write is applied at most once.
     */
    val clientId: String,
    /** Epoch millis when the write was first enqueued. */
    val createdAt: Long,
    /** Epoch millis of the last status/error change. */
    val updatedAt: Long,
    /** How many replay attempts have been made (0 until replay exists). */
    val attemptCount: Int = 0,
    /** Last failure message, if any, for diagnostics/UX. */
    val lastError: String? = null,
    /** Lifecycle status (see [PendingWriteStatus]). */
    val status: String = PendingWriteStatus.PENDING,
)

/** Domain entities that may eventually be queued. String-valued for forward-compat. */
object PendingEntityType {
    const val PIN = "pin"
    /**
     * Descriptive pin field edits (title/notes/category/mode) queued offline
     * (Stage 9B-3). Deliberately distinct from [PIN] so the Stage 9A completion
     * queue — which owns PIN / UPDATE — never picks up an edit write and an
     * edit replay never picks up a completion toggle. Completion, delete,
     * photo, paddock and row/snap changes are NOT carried here.
     */
    const val PIN_EDIT = "pin_edit"
    const val TRIP = "trip"
    /**
     * Safe scalar trip-detail updates (metadata / pause-resume / start engine
     * hours) queued offline for an existing active server trip (Tier-A Stage
     * B-1). Deliberately distinct from [TRIP] so the later GPS-breadcrumb,
     * row-coverage, tank-session and trip-end/start event work stays on its own
     * discriminators and never collides with this scalar queue — mirroring the
     * [PIN] vs [PIN_EDIT] split. Path points, coverage arrays, tank sessions,
     * trip start/end and delete are NOT carried here.
     */
    const val TRIP_METADATA = "trip_metadata"
    /**
     * Coalesced GPS/path-progress marker for an existing active server trip
     * (Tier-A Stage C-1). Exactly one unresolved marker per trip
     * ([PendingWrite.clientId] = tripId) signals that the trip has unsynced
     * captured path progress; the actual path lives in the Stage A active-trip
     * snapshot, not in the outbox row — so high-frequency GPS fixes never
     * produce one pending row per fix. Deliberately distinct from [TRIP] and
     * [TRIP_METADATA] so the scalar metadata queue, the GPS-progress marker, and
     * the later trip start/end/row/tank work each stay on their own
     * discriminators. Trip start/end, row coverage, tank sessions, fuel logs and
     * final summaries are NOT carried here.
     */
    const val TRIP_GPS = "trip_gps"
    /**
     * Coalesced row-coverage marker for an existing active server trip (Tier-A
     * Stage D-1). Exactly one unresolved marker per trip
     * ([PendingWrite.clientId] = tripId) signals that the trip has unsynced
     * done/skip/undo row-coverage progress; the actual completed/skipped paths
     * live in the Stage A active-trip snapshot, not in the outbox row — so a
     * burst of row actions never produces one pending row per tap. Deliberately
     * distinct from [TRIP], [TRIP_METADATA] and [TRIP_GPS] so the scalar
     * metadata queue, the GPS-progress marker, the row-coverage marker, and the
     * later trip start/end/tank work each stay on their own discriminators.
     * Trip start/end, GPS/path points, tank sessions, fuel logs and final
     * summaries are NOT carried here.
     */
    const val TRIP_ROW = "trip_row"
    /**
     * Coalesced tank/fill marker for an existing active server trip (Tier-A
     * Stage E-1). Exactly one unresolved marker per trip
     * ([PendingWrite.clientId] = tripId) signals that the trip has unsynced
     * tank-session / fill-timer progress (start/end tank, start/stop fill); the
     * actual tank sessions and live tank scalars live in the Stage A active-trip
     * snapshot, not in the outbox row — so a burst of tank actions never
     * produces one pending row per event. Deliberately distinct from [TRIP],
     * [TRIP_METADATA], [TRIP_GPS] and [TRIP_ROW] so the scalar metadata queue,
     * the GPS-progress marker, the row-coverage marker, the tank marker, and the
     * later trip start/end work each stay on their own discriminators. Trip
     * start/end, GPS/path points, row coverage, engine hours, fuel logs and
     * final summaries are NOT carried here. (Distinct from the legacy unused
     * [TANK_SESSION] placeholder, which is left untouched.)
     */
    const val TRIP_TANK = "trip_tank"
    /**
     * Lightweight trip-END summary marker for an existing active server trip
     * (Tier-A Stage B-2-1). Exactly one unresolved marker per trip
     * ([PendingWrite.clientId] = tripId) signals that the operator finished the
     * trip offline (or a transient end failed) and the server still has it
     * active. The marker carries only the end summary scalars (completion notes,
     * end engine hours, requested end time) — never path points, row coverage,
     * tank sessions, metadata, fuel logs, or delete/start fields. The final path
     * and distance are derived from the LIVE server trip at replay time (after
     * the same-trip GPS marker has landed), never from a stale local array.
     *
     * Deliberately distinct from [TRIP], [TRIP_METADATA], [TRIP_GPS],
     * [TRIP_ROW] and [TRIP_TANK]. Crucially, [TripEndSync] DEPENDENCY-GATES on
     * those per-trip markers: a TRIP_END marker is never finalised while an
     * unresolved same-trip TRIP_GPS / TRIP_ROW / TRIP_TANK / TRIP_METADATA write
     * still exists, so the trip is never ended with stale GPS / row / tank /
     * metadata state frozen in.
     */
    const val TRIP_END = "trip_end"
    /**
     * Lightweight trip-START create marker for a NEW trip begun offline (Tier-A
     * Stage B-3-1). The client generates the final trip UUID up front and uses
     * it as both [PendingWrite.clientId] and the eventual server row id, so no
     * id remapping is ever needed: the same id is the idempotency key and the
     * anchor every dependent same-trip marker (TRIP_METADATA / TRIP_GPS /
     * TRIP_ROW / TRIP_TANK / TRIP_END) attaches to. Exactly one unresolved
     * marker per trip / CREATE. The payload carries only the scalar insert
     * fields (vineyard/paddock/job/operator identity, start time, start engine
     * hours) — never path points, distance, row coverage, row-plan, tank
     * sessions, completion/end fields, delete fields or fuel logs.
     *
     * Replay ordering (mandatory): [com.rork.vinetrack.data.TripStartSync]
     * replays FIRST — before metadata/GPS/row/tank/end — because the server row
     * must exist before any dependent marker can write to it. Conversely every
     * dependent coordinator DEPENDENCY-GATES on an unresolved same-trip
     * TRIP_START so it never writes to a not-yet-created server trip; and
     * [com.rork.vinetrack.data.TripEndSync] includes TRIP_START in its gate so a
     * start -> work -> end sequence can only finalise once the row exists and
     * all dependent markers have cleared. Distinct from [TRIP], [TRIP_METADATA],
     * [TRIP_GPS], [TRIP_ROW], [TRIP_TANK] and [TRIP_END].
     */
    const val TRIP_START = "trip_start"
    /**
     * Structured trip seeding-details edit queued offline (Android Stage S). Backs
     * the `trips.seeding_details` JSONB column only — mix lines + box settings —
     * for an existing active server trip. Deliberately distinct from [TRIP] and
     * [TRIP_METADATA] so the scalar metadata queue, the GPS/row/tank markers and
     * the trip start/end work never pick up a seeding write and a seeding replay
     * never disturbs progress, coverage, row-plan or any other iOS-managed field.
     * Coalesced one-per trip ([PendingWrite.clientId] = tripId, UPDATE only) so
     * the latest seeding snapshot wins. Dependency-gated on an unresolved same-trip
     * [TRIP_START] so it never writes to a not-yet-created server trip, and
     * stale-guarded against newer server edits. Path points, coverage arrays, tank
     * sessions and trip start/end/delete are NOT carried here.
     */
    const val TRIP_SEEDING = "trip_seeding"
    const val SPRAY_RECORD = "spray_record"
    const val FUEL_LOG = "fuel_log"
    const val WORK_TASK = "work_task"
    /**
     * A single work-task LABOUR costing line queued offline (Android Stage J-4).
     * Backs `work_task_labour_lines`. CREATE / UPDATE / DELETE are carried on
     * this discriminator, keyed by the labour line id ([PendingWrite.clientId] =
     * labourLineId), so the header queues ([WORK_TASK] create/update/delete) can
     * never pick up a line write and a line replay never touches the header.
     *
     * Parent dependency gate: [com.rork.vinetrack.data.WorkTaskLabourSync]
     * defers every labour write while the SAME `workTaskId` still has an
     * unresolved [WORK_TASK] / CREATE marker — a child line is never POSTed or
     * deleted before its parent task exists server-side. Replay ordering places
     * labour (create -> update -> delete) AFTER the work-task header
     * create/update passes and BEFORE the header delete pass. Machine lines and
     * any other child records are NOT carried here (machine parked for J-5).
     */
    const val WORK_TASK_LABOUR = "work_task_labour"
    /**
     * A single work-task MACHINE costing line queued offline (Android Stage J-5).
     * Backs `work_task_machine_lines`. CREATE / UPDATE / DELETE are carried on
     * this discriminator, keyed by the machine line id ([PendingWrite.clientId] =
     * machineLineId), so the header queues ([WORK_TASK] create/update/delete) and
     * the labour queue ([WORK_TASK_LABOUR]) can never pick up a machine write and
     * a machine replay never touches the header or any labour line.
     *
     * Parent dependency gate: [com.rork.vinetrack.data.WorkTaskMachineSync]
     * defers every machine write while the SAME `workTaskId` still has an
     * unresolved [WORK_TASK] / CREATE marker — a child line is never POSTed or
     * deleted before its parent task exists server-side. Replay ordering places
     * machine (create -> update -> delete) AFTER the work-task header
     * create/update passes and the labour pass, and BEFORE the header delete
     * pass. No other child records are carried here.
     */
    const val WORK_TASK_MACHINE = "work_task_machine"
    /**
     * A single work-task -> paddock join row queued offline (Android Stage R).
     * Backs `work_task_paddocks` (sql/051), letting a task span multiple
     * paddocks. Only CREATE (insert, merge-duplicates upsert keyed by row id)
     * and DELETE (soft-delete RPC) are carried — a join row is never edited in
     * place; a changed area re-inserts the same id. Keyed by the join-row id
     * ([PendingWrite.clientId] = workTaskPaddockId) so no other queue can pick
     * up a join write and a join replay never touches the header, a labour line
     * or a machine line.
     *
     * Parent dependency gate: [com.rork.vinetrack.data.WorkTaskPaddockSync]
     * defers every join write while the SAME `workTaskId` still has an
     * unresolved [WORK_TASK] / CREATE marker — a child join row is never POSTed
     * or deleted before its parent task exists server-side. Replay ordering
     * places paddock joins AFTER the header create/update passes and BEFORE the
     * header delete pass, alongside the labour/machine line queues. Soft-delete
     * is RLS-restricted (owner/manager/supervisor) so a permission rejection
     * BLOCKS rather than retrying forever.
     */
    const val WORK_TASK_PADDOCK = "work_task_paddock"
    const val TANK_SESSION = "tank_session"
    const val GROWTH_RECORD = "growth_record"
    const val MAINTENANCE_LOG = "maintenance_log"
    const val YIELD_RECORD = "yield_record"
    /**
     * A single block-damage record queued offline (Android Stage M). Backs the
     * `damage_records` table. CREATE / UPDATE / DELETE are carried on this
     * discriminator, keyed by the damage-record id ([PendingWrite.clientId] =
     * damageRecordId), so no other entity's queue can ever pick up a damage
     * write and a damage replay never touches another entity. Damage records are
     * top-level records (no parent gate). Soft-delete is RLS-restricted
     * (owner/manager/supervisor only) so a permission rejection BLOCKS rather
     * than retrying forever.
     */
    const val DAMAGE_RECORD = "damage_record"
    /**
     * Per-vineyard Repairs/Growth launcher button configuration queued offline
     * (Android Stage N). Backs `vineyard_button_configs`, an upsert keyed by
     * (vineyard_id, config_type). Only an UPDATE op is ever carried — the row is
     * a merge-duplicates upsert, never created or deleted from Android — and is
     * coalesced one-per ([PendingWrite.clientId] = "$vineyardId|$configType")
     * so the latest button layout wins. Owner/manager-only via RLS, so a
     * permission rejection BLOCKS rather than retrying forever.
     */
    const val BUTTON_CONFIG = "button_config"
    /**
     * A single yield-estimation working session queued offline (Android Stage Q).
     * Backs `yield_estimation_sessions`, an upsert keyed by the session id with
     * the whole session (selected blocks, generated sample sites, inline bunch
     * counts, per-block bunch weights, path waypoints, completion) carried in the
     * JSONB `payload`. CREATE/EDIT both fold into a single UPDATE (upsert) op
     * coalesced one-per session id ([PendingWrite.clientId] = sessionId) so the
     * latest session state wins; DELETE is a separate op (soft-delete RPC,
     * RLS-restricted to owner/manager/supervisor, so a permission rejection
     * BLOCKS rather than retrying forever). No other entity's queue can pick up a
     * session write and a session replay never touches another entity.
     */
    const val YIELD_SESSION = "yield_session"
    /**
     * A pruning-season (block setup) upsert queued offline. Backs
     * `pruning_seasons` — UPDATE (merge-duplicates upsert keyed by the
     * deterministic season id) and DELETE (soft-delete RPC). Coalesced
     * one-per season ([PendingWrite.clientId] = seasonId) so the latest
     * setup wins.
     */
    const val PRUNING_SEASON = "pruning_season"
    /**
     * A pruning "Complete Today" entry queued offline. Backs the idempotent
     * `record_pruning_entry` RPC (CREATE, keyed by the client entry id) and
     * the `delete_pruning_entry` RPC (DELETE). Replaying a CREATE can never
     * double-count a quarter — the server attributes each quarter to the
     * first entry that completed it.
     */
    const val PRUNING_ENTRY = "pruning_entry"
    /**
     * A fertiliser calculation/application record upsert queued offline.
     * Backs `fertiliser_records` + `fertiliser_record_allocations` — UPDATE
     * (record upsert followed by its per-block allocation upserts, coalesced
     * one-per record) and DELETE (soft-delete RPC). The product library is
     * the shared `saved_chemicals` table (sql/111) and is never queued here —
     * the former "fertiliser_product" discriminator is retired.
     */
    const val FERTILISER_RECORD = "fertiliser_record"
}

/** The kind of write a pending row represents. */
object PendingOpType {
    const val CREATE = "create"
    const val UPDATE = "update"
    const val DELETE = "delete"
}

/** Lifecycle a pending write moves through once a queue/replay loop exists. */
object PendingWriteStatus {
    /** Enqueued, waiting for a replay attempt. */
    const val PENDING = "pending"
    /** A replay attempt is currently in flight. */
    const val IN_PROGRESS = "in_progress"
    /** The last attempt failed; eligible for retry. */
    const val FAILED = "failed"
    /** Cannot proceed (e.g. a dependency write hasn't synced yet). */
    const val BLOCKED = "blocked"
    /** Successfully applied on the server; safe to remove. */
    const val SYNCED = "synced"

    /** Statuses that still count toward the "waiting to sync" total. */
    val unresolved: Set<String> = setOf(PENDING, IN_PROGRESS, FAILED, BLOCKED)
}
