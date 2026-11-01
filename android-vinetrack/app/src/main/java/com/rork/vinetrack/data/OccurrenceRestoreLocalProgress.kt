package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip

/**
 * P0 (3.1.9): occurrence-Trip restore must not let a server row displace this
 * device's locally committed tank state.
 *
 * The occurrence restore projects onto the server row when one exists. Before
 * this fix, that projection also took the server's `tank_sessions`,
 * `active_tank_number` and filling fields, then saved the result to the
 * active-Trip snapshot. A Tank 1 session committed by Start Tank, but not yet
 * replayed, was silently lost. TRIP_TANK replay reads that snapshot. Its spray
 * actual then pointed at a session that no longer existed anywhere.
 *
 * This keeps the server row's occurrence-protected fields (identity, lifecycle,
 * route, coverage) and restores only device-owned progress:
 *  - tank sessions are unioned by session id using the production
 *    [TankSessionReplayMerge] (never synthesised, never dropped);
 *  - active/filling tank scalars follow that merge;
 *  - pause state stays local while the device holds the Trip, matching the
 *    legacy [ActiveTripReconciliation.mergeProgress] behaviour.
 *
 * If the two tank histories conflict (same id with a different tank number or
 * start), local tank evidence is kept unchanged, and the result is marked
 * [Result.tankConflict] so the caller can hold it with a fixed code. No
 * quantity, session id or actual is altered.
 */
internal object OccurrenceRestoreLocalProgress {
    data class Result(
        val trip: Trip,
        /** Local tank state adds something the server row does not have, so TRIP_TANK replay is required. */
        val tankReplayRequired: Boolean,
        val tankConflict: Boolean,
        val localSessionIds: List<String>,
        val serverSessionIds: List<String>,
    )

    const val TANK_CONFLICT_CODE = "OCCURRENCE_RESTORE_TANK_CONFLICT_HELD"

    fun apply(projected: Trip, server: Trip?, saved: Trip): Result {
        val localIds = saved.tankSessions.map { it.id }
        if (server == null) {
            // Projected from the saved snapshot already; nothing to displace.
            return Result(projected, tankReplayRequired = false, tankConflict = false,
                localSessionIds = localIds, serverSessionIds = emptyList())
        }
        val serverIds = server.tankSessions.map { it.id }
        val withPause = projected.copy(
            isPaused = saved.isPaused,
            pauseTimestamps = longer(saved.pauseTimestamps, server.pauseTimestamps),
            resumeTimestamps = longer(saved.resumeTimestamps, server.resumeTimestamps),
        )
        val merge = TankSessionReplayMerge.merge(server, saved)
        if (merge == null) {
            return Result(
                withPause.copy(
                    tankSessions = saved.tankSessions,
                    activeTankNumber = saved.activeTankNumber,
                    isFillingTank = saved.isFillingTank,
                    fillingTankNumber = saved.fillingTankNumber,
                ),
                tankReplayRequired = false, tankConflict = true,
                localSessionIds = localIds, serverSessionIds = serverIds,
            )
        }
        return Result(
            withPause.copy(
                tankSessions = merge.sessions,
                activeTankNumber = merge.activeTankNumber,
                isFillingTank = merge.isFillingTank,
                fillingTankNumber = merge.fillingTankNumber,
            ),
            tankReplayRequired = merge.addsSomething(server),
            tankConflict = false,
            localSessionIds = localIds, serverSessionIds = serverIds,
        )
    }

    private fun longer(a: List<String>?, b: List<String>?): List<String>? =
        if (a.orEmpty().size >= b.orEmpty().size) a ?: b else b
}
