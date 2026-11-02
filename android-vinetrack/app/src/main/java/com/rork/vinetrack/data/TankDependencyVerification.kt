package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import kotlin.math.abs

/**
 * P0 3.1.9 Phase B: dependency verification for Trip tank markers and Tank actuals.
 *
 * A TRIP_TANK marker is never acknowledged while a tank session referenced by a
 * local Tank actual is absent from the server (or from the PATCH response), and a
 * Tank actual is never marked synced until a server readback returns the exact
 * recorded evidence. Codes are fixed and contain no private values.
 */
object TankDependencyVerification {
    const val REQUIRED_SESSION_MISSING = "TRIP_TANK_REQUIRED_SESSION_MISSING"
    const val REQUIRED_SESSIONS_UNREADABLE = "TRIP_TANK_REQUIRED_SESSIONS_UNREADABLE"
    const val PATCH_READBACK_MISMATCH = "TRIP_TANK_PATCH_READBACK_MISMATCH"
    const val ACTUAL_SESSION_NOT_ON_SERVER = "TANK_ACTUAL_SESSION_NOT_ON_SERVER"
    const val ACTUAL_READBACK_MISMATCH = "TANK_ACTUAL_READBACK_MISMATCH"

    private const val EPSILON = 1e-9

    /**
     * Session IDs required by local actuals that neither the local snapshot nor the
     * server row can supply. Non-empty means the marker must be held, not acknowledged.
     */
    fun unsatisfiableSessions(required: Set<String>, local: List<TankSession>, server: List<TankSession>): Set<String> =
        required - local.map { it.id }.toSet() - server.map { it.id }.toSet()

    /** Session IDs the server row must contain before the marker can be removed. */
    fun missingFromServer(required: Set<String>, server: List<TankSession>): Set<String> =
        required - server.map { it.id }.toSet()

    /** The PATCH response must contain every merged session and every required session. */
    fun patchVerified(returned: Trip, tripId: String, vineyardId: String, merged: List<TankSession>, required: Set<String>): Boolean {
        if (returned.id != tripId || returned.vineyardId != vineyardId) return false
        val ids = returned.tankSessions.map { it.id }.toSet()
        return merged.all { expected -> returned.tankSessions.singleOrNull { it.id == expected.id } == expected } && required.all { it in ids }
    }

    /** Exact recorded evidence survives on the server row: identity, links and actual quantities. */
    fun actualMatches(local: SprayTankActual, server: SprayTankActual?): Boolean {
        if (server == null) return false
        if (server.id != local.id || server.vineyardId != local.vineyardId || server.tripId != local.tripId ||
            server.sprayRecordId != local.sprayRecordId || server.tankSessionId != local.tankSessionId ||
            server.tankNumber != local.tankNumber || server.correctionVersion < local.correctionVersion) return false
        val lw = local.waterVolumeL
        val sw = server.waterVolumeL
        if ((lw == null) != (sw == null)) return false
        if (lw != null && sw != null && abs(lw - sw) > EPSILON) return false
        if (local.chemicals.size != server.chemicals.size) return false
        val remote = server.chemicals.associateBy { it.id }
        if (remote.size != server.chemicals.size) return false
        return local.chemicals.all { chem ->
            val other = remote[chem.id] ?: return@all false
            other.name == chem.name && other.unit == chem.unit && abs(other.actualAmountBase - chem.actualAmountBase) <= EPSILON
        }
    }
}
