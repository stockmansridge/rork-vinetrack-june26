package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip

/** Conservative production merge used when offline tank progress replays. */
internal object TankSessionReplayMerge {
    data class Result(
        val sessions: List<TankSession>,
        val activeTankNumber: Int?,
        val isFillingTank: Boolean,
        val fillingTankNumber: Int?,
    ) {
        fun addsSomething(server: Trip): Boolean =
            sessions != server.tankSessions ||
                activeTankNumber != server.activeTankNumber ||
                isFillingTank != server.isFillingTank ||
                fillingTankNumber != server.fillingTankNumber
    }

    fun merge(server: Trip, local: Trip): Result? {
        val localById = local.tankSessions.associateBy { it.id }
        val serverIds = server.tankSessions.map { it.id }.toSet()
        val merged = ArrayList<TankSession>(server.tankSessions.size + local.tankSessions.size)
        server.tankSessions.forEach { serverSession ->
            val localSession = localById[serverSession.id]
            merged.add(if (localSession != null) moreComplete(serverSession, localSession) else serverSession)
        }
        local.tankSessions.forEach { localSession ->
            if (localSession.id !in serverIds) merged.add(localSession)
        }
        if (!merged.map { it.id }.toSet().containsAll(serverIds)) return null

        val filling = reconcileFilling(server, local, merged)
        return Result(
            sessions = merged,
            activeTankNumber = reconcileActiveTank(server, local, merged),
            isFillingTank = filling.first,
            fillingTankNumber = filling.second,
        )
    }

    private fun moreComplete(server: TankSession, local: TankSession): TankSession = local.copy(
        endTime = local.endTime ?: server.endTime,
        endRow = local.endRow ?: server.endRow,
        fillStartTime = local.fillStartTime ?: server.fillStartTime,
        fillEndTime = local.fillEndTime ?: server.fillEndTime,
    )

    private fun reconcileActiveTank(server: Trip, local: Trip, merged: List<TankSession>): Int? {
        val localActive = local.activeTankNumber
        if (localActive != null && merged.any { it.tankNumber == localActive && it.isOpen }) return localActive
        val serverActive = server.activeTankNumber
        if (serverActive != null && merged.any { it.tankNumber == serverActive && it.isOpen }) return serverActive
        return null
    }

    private fun reconcileFilling(server: Trip, local: Trip, merged: List<TankSession>): Pair<Boolean, Int?> {
        fun openFillFor(number: Int?): TankSession? = number?.let { tankNumber ->
            merged.firstOrNull {
                it.tankNumber == tankNumber && it.fillStartTime != null && it.fillEndTime == null
            }
        }
        if (local.isFillingTank) {
            openFillFor(local.fillingTankNumber)?.let { return true to it.tankNumber }
        }
        if (server.isFillingTank) {
            openFillFor(server.fillingTankNumber)?.let { return true to it.tankNumber }
        }
        return false to null
    }
}
