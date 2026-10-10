package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.json.*

/** Display-only reconciliation. Never replays, acknowledges or mutates pending evidence. */
internal object PendingPinReadOverlay {
    private val json = Json { ignoreUnknownKeys = true }

    /** Unknown operations remain explicit; they protect only records with proven identity. */
    data class Result(
        val rows: List<Pin>,
        val unresolvedWriteIds: Set<String>,
        val protectedRecordIds: Set<String>,
        // Raw server rows plus retained local evidence for pending targets absent remotely.
        // This preserves vineyard-less edit ownership across restart without caching overlays.
        val cacheRows: List<Pin>,
    )

    /** Compatibility entry point for existing regression callers; production consumes [reconcile]. */
    fun overlay(baseline: List<Pin>, existing: List<Pin>, pending: List<PendingWrite>, vineyardId: String): List<Pin>? =
        reconcile(baseline, existing, pending, vineyardId).let { if (it.unresolvedWriteIds.isEmpty()) it.rows else null }

    fun reconcile(baseline: List<Pin>, existing: List<Pin>, pending: List<PendingWrite>, vineyardId: String): Result {
        fun scoped(pin: Pin): Boolean = pin.vineyardId.equals(vineyardId, true)
        val rows = baseline.filter(::scoped).associateByTo(linkedMapOf()) { it.id }
        val local = existing.filter(::scoped).associateBy { it.id }
        val evidence = LinkedHashMap(rows)
        val owners = (baseline + existing).groupBy { it.id }.mapValues { (_, pins) ->
            pins.map { it.vineyardId.lowercase() }.toSet()
        }
        val unresolved = linkedSetOf<String>()
        val protected = linkedSetOf<String>()
        val deleted = linkedSetOf<String>()
        val writes = pending.filter { it.status in PendingWriteStatus.unresolved && it.entityType in
            setOf(PendingEntityType.PIN, PendingEntityType.PIN_EDIT, PendingEntityType.CUSTOM_PIN, PendingEntityType.MANUAL_ISSUE) }
            .sortedWith(compareBy<PendingWrite> { if (it.opType == PendingOpType.CREATE) 0 else 1 }
                .thenBy { it.createdAt })

        // Only complete, identity-matching creates establish ownership for dependent writes.
        val createdOwners = writes.mapNotNull { write -> runCatching {
            when (write.entityType) {
                PendingEntityType.PIN -> if (write.opType == PendingOpType.CREATE) {
                    val pin = json.decodeFromString(Pin.serializer(), write.payloadJson)
                    if (pin.id == write.clientId && pin.vineyardId.isNotBlank()) pin.id to pin.vineyardId.lowercase() else null
                } else null
                PendingEntityType.CUSTOM_PIN -> json.decodeFromString(CustomPinSync.QueuedOp.serializer(), write.payloadJson)
                    .takeIf { it.kind == CustomPinSync.QueuedOp.KIND_PIN_CREATE && write.opType == PendingOpType.CREATE }
                    ?.pinParams?.takeIf { it.id == write.clientId && it.vineyardId.isNotBlank() }?.let { it.id to it.vineyardId.lowercase() }
                PendingEntityType.MANUAL_ISSUE -> json.decodeFromString(ManualIssueSync.QueuedOp.serializer(), write.payloadJson)
                    .takeIf { it.kind == ManualIssueSync.QueuedOp.KIND_CREATE && write.opType == PendingOpType.CREATE }
                    ?.createParams?.takeIf { it.id == write.clientId && it.vineyardId.isNotBlank() }?.let { it.id to it.vineyardId.lowercase() }
                else -> null
            }
        }.getOrNull() }.groupBy({ it.first }, { it.second })

        fun protect(id: String) {
            protected += id
            local[id]?.let {
                rows.putIfAbsent(id, it)
                evidence.putIfAbsent(id, it)
            }
        }
        for (write in writes) {
            val raw = runCatching { json.parseToJsonElement(write.payloadJson).jsonObject }.getOrNull()
            fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
            val params = listOf("pin_params", "type_params", "create_params", "update_params")
                .mapNotNull { raw?.get(it) as? JsonObject }
            val ids = (listOfNotNull(raw?.text("id"), raw?.text("pinId"), raw?.text("pin_id")) +
                params.mapNotNull { it.text("p_id") }).toSet()
            val id = ids.singleOrNull() ?: write.clientId
            val payloadOwners = (listOfNotNull(raw?.text("vineyard_id")) +
                params.mapNotNull { it.text("p_vineyard_id") }).map { it.lowercase() }.toSet()
            val knownOwners = owners[id].orEmpty() + createdOwners[id].orEmpty()
            val allOwners = payloadOwners + knownOwners
            if (ids.size > 1 || (ids.isNotEmpty() && id != write.clientId) || allOwners.size > 1) {
                unresolved += write.id
                // Conflicting ownership cannot authorise a new row or a deletion.
                local[write.clientId]?.let { rows[it.id] = it; evidence[it.id] = it; protected += it.id }
                continue
            }
            val owner = allOwners.singleOrNull()
            if (owner == null) { unresolved += write.id; continue }
            if (!owner.equals(vineyardId, true)) continue
            // Type catalogue writes do not affect the map's Pin collection.
            if (write.entityType == PendingEntityType.CUSTOM_PIN && raw?.text("kind") == CustomPinSync.QueuedOp.KIND_TYPE_CREATE) continue
            protect(id)
            val applied = runCatching {
                when (write.entityType) {
                    PendingEntityType.PIN -> when (write.opType) {
                        PendingOpType.CREATE -> {
                            val created = json.decodeFromString(Pin.serializer(), write.payloadJson)
                            check(created.id == id && scoped(created))
                            // Capture payload wins over a server row; current local enrichment (photo/segments) is retained.
                            rows[id] = local[id] ?: created
                        }
                        PendingOpType.UPDATE -> {
                            val toggle = json.decodeFromString(PinCompletionSync.Payload.serializer(), write.payloadJson)
                            check(toggle.pinId == id)
                            rows[id]?.let { rows[id] = it.copy(isCompleted = toggle.isCompleted) }
                        }
                        PendingOpType.DELETE -> {
                            val deletion = json.decodeFromString(PinDeleteSync.Payload.serializer(), write.payloadJson)
                            check(deletion.pinId == id)
                            deleted += id
                            rows.remove(id)
                        }
                        else -> error("Unsupported Pin operation")
                    }
                    PendingEntityType.PIN_EDIT -> {
                        check(write.opType == PendingOpType.UPDATE)
                        val edit = json.decodeFromString(PinEditSync.Payload.serializer(), write.payloadJson)
                        check(edit.pinId == id)
                        rows[id]?.let { rows[id] = it.copy(title = edit.title, category = edit.category,
                            mode = edit.mode, notes = edit.notes, clientUpdatedAt = edit.clientUpdatedAt) }
                    }
                    PendingEntityType.CUSTOM_PIN -> {
                        val op = json.decodeFromString(CustomPinSync.QueuedOp.serializer(), write.payloadJson)
                        when (op.kind) {
                            CustomPinSync.QueuedOp.KIND_PIN_CREATE -> {
                                val p = requireNotNull(op.pinParams)
                                check(p.id == id && p.vineyardId.equals(vineyardId, true))
                                val pin = ManualIssue(id = p.id, vineyardId = p.vineyardId, paddockId = p.paddockId,
                                    title = p.title, description = p.notes, locationScope = p.locationScope,
                                    latitude = p.latitude, longitude = p.longitude, snappedLatitude = p.snappedLatitude,
                                    snappedLongitude = p.snappedLongitude, drivingRowNumber = p.drivingRowNumber,
                                    pinRowNumber = p.pinRowNumber, alongRowDistanceM = p.alongRowDistanceM,
                                    snappedToRow = p.snappedToRow, createdAt = p.clientUpdatedAt,
                                    updatedAt = p.clientUpdatedAt, clientUpdatedAt = p.clientUpdatedAt).toMapPin()
                                pin?.let { rows[id] = local[id] ?: it }
                            }
                            CustomPinSync.QueuedOp.KIND_SEGMENTS -> {
                                check(op.pinId == id)
                                rows[id]?.let { rows[id] = it.copy(rowSegments = op.segments.orEmpty().map { segment ->
                                    PinRowSegmentValue(segment.row, segment.segment) }) }
                            }
                            else -> error("Unsupported custom operation")
                        }
                    }
                    PendingEntityType.MANUAL_ISSUE -> {
                        val op = json.decodeFromString(ManualIssueSync.QueuedOp.serializer(), write.payloadJson)
                        when (op.kind) {
                            ManualIssueSync.QueuedOp.KIND_CREATE -> {
                                val p = requireNotNull(op.createParams)
                                check(p.id == id && p.vineyardId.equals(vineyardId, true))
                                val pin = ManualIssue(id = p.id, vineyardId = p.vineyardId, paddockId = p.paddockId,
                                    title = p.title, description = p.description, category = p.category, priority = p.priority,
                                    locationScope = p.locationScope, latitude = p.latitude, longitude = p.longitude,
                                    snappedLatitude = p.snappedLatitude, snappedLongitude = p.snappedLongitude,
                                    drivingRowNumber = p.drivingRowNumber, pinRowNumber = p.pinRowNumber, pinSide = p.pinSide,
                                    alongRowDistanceM = p.alongRowDistanceM, snappedToRow = p.snappedToRow,
                                    assignedUserId = p.assignedUserId, dueDate = p.dueDate, createdAt = p.clientUpdatedAt,
                                    updatedAt = p.clientUpdatedAt, clientUpdatedAt = p.clientUpdatedAt).toMapPin()
                                pin?.let { rows[id] = local[id] ?: it }
                            }
                            ManualIssueSync.QueuedOp.KIND_UPDATE -> {
                                val p = requireNotNull(op.updateParams)
                                check(p.id == id)
                                rows[id]?.let { rows[id] = it.copy(title = p.title, buttonName = p.title,
                                    notes = p.description, category = p.category, priority = p.priority,
                                    locationScope = p.locationScope, paddockId = p.paddockId, latitude = p.latitude,
                                    longitude = p.longitude, snappedLatitude = p.snappedLatitude,
                                    snappedLongitude = p.snappedLongitude, drivingRowNumber = p.drivingRowNumber,
                                    pinRowNumber = p.pinRowNumber, pinSide = p.pinSide, alongRowDistanceM = p.alongRowDistanceM,
                                    snappedToRow = p.snappedToRow, assignedUserId = p.assignedUserId,
                                    dueDate = p.dueDate, clientUpdatedAt = p.clientUpdatedAt) }
                            }
                            ManualIssueSync.QueuedOp.KIND_STATUS -> {
                                val status = requireNotNull(op.status)
                                rows[id]?.let { rows[id] = it.copy(status = status, isCompleted = status == ManualIssueStatuses.COMPLETED) }
                            }
                            ManualIssueSync.QueuedOp.KIND_CANCEL -> rows[id]?.let {
                                rows[id] = it.copy(status = ManualIssueStatuses.CANCELLED, isCompleted = false)
                            }
                            ManualIssueSync.QueuedOp.KIND_DELETE -> { deleted += id; rows.remove(id) }
                            else -> error("Unsupported manual operation")
                        }
                    }
                }
            }.isSuccess
            if (!applied) {
                unresolved += write.id
                // Undecodable intent protects just its known local record, not unrelated rows.
                local[id]?.let { rows[id] = it; evidence[id] = it }
            }
        }
        // Retry status timestamps cannot resurrect an unresolved deletion, even
        // when a later overlay restores a local target to apply an edit/toggle.
        return Result(rows.values.filterNot { it.id in deleted }, unresolved.toSet(), protected.toSet(), evidence.values.toList())
    }
}
