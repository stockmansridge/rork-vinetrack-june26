package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import kotlin.math.abs

/**
 * Observation-backed aisle identity for automatic pin capture outside trips.
 * History establishes only an aisle; the current accepted raw fix is never
 * averaged or replaced and remains the sole source for snapping and persistence.
 */
object PinAisleObservationLock {
    const val MAX_OBSERVATIONS: Int = 16
    const val MAX_AGE_MS: Long = 20_000L
    const val SUPPORT_REQUIRED: Int = 3
    const val CONTRADICTIONS_REQUIRED: Int = 3

    data class Evidence(
        val observedAtElapsedRealtimeNanos: Long,
        val paddockId: String?,
        val aisleNumber: Double?,
        val isQualified: Boolean,
    )

    data class Lock(
        val paddockId: String,
        val aisleNumber: Double,
        val supportingObservations: Int,
    )

    fun resolve(evidence: List<Evidence>, captureElapsedRealtimeNanos: Long): Lock? {
        val recent = evidence
            .filter { ageMs(it.observedAtElapsedRealtimeNanos, captureElapsedRealtimeNanos) <= MAX_AGE_MS }
            .takeLast(MAX_OBSERVATIONS)

        var block: String? = null
        var locked: Double? = null
        var candidate: Double? = null
        var candidateCount = 0
        var supportCount = 0
        var contradiction: Double? = null
        var contradictionCount = 0

        recent.forEach { item ->
            val itemBlock = item.paddockId
            val aisle = item.aisleNumber
            if (itemBlock == null || aisle == null) {
                block = null
                locked = null
                candidate = null
                candidateCount = 0
                supportCount = 0
                contradiction = null
                contradictionCount = 0
                return@forEach
            }
            if (block != itemBlock) {
                block = itemBlock
                locked = null
                candidate = null
                candidateCount = 0
                supportCount = 0
                contradiction = null
                contradictionCount = 0
            }

            val currentLock = locked
            if (currentLock != null) {
                if (sameAisle(currentLock, aisle)) {
                    if (item.isQualified) supportCount = (supportCount + 1).coerceAtMost(MAX_OBSERVATIONS)
                    contradiction = null
                    contradictionCount = 0
                } else if (item.isQualified) {
                    if (contradiction?.let { sameAisle(it, aisle) } == true) contradictionCount += 1
                    else {
                        contradiction = aisle
                        contradictionCount = 1
                    }
                    if (contradictionCount >= CONTRADICTIONS_REQUIRED) {
                        locked = aisle
                        candidate = aisle
                        candidateCount = contradictionCount
                        supportCount = contradictionCount
                        contradiction = null
                        contradictionCount = 0
                    }
                }
            } else if (item.isQualified) {
                if (candidate?.let { sameAisle(it, aisle) } == true) candidateCount += 1
                else {
                    candidate = aisle
                    candidateCount = 1
                }
                if (candidateCount >= SUPPORT_REQUIRED) {
                    locked = aisle
                    supportCount = candidateCount
                }
            }
        }

        val finalBlock = block ?: return null
        val finalAisle = locked ?: return null
        if (supportCount < SUPPORT_REQUIRED) return null
        return Lock(finalBlock, finalAisle, supportCount)
    }

    fun resolve(fixes: List<QualifiedLocationFix>, current: QualifiedLocationFix, paddock: Paddock?): Lock? {
        paddock ?: return null
        val evidence = fixes
            .filter { it.fixElapsedRealtimeNanos <= current.fixElapsedRealtimeNanos }
            .takeLast(MAX_OBSERVATIONS)
            .map { fix ->
                val inside = RowAttachment.containsPoint(paddock, fix.latitude, fix.longitude)
                val approximate = if (inside) PinAisleGeometry.approximateAisle(paddock, fix.latitude, fix.longitude) else null
                val qualified = if (inside) {
                    PinAisleGeometry.aisleContaining(paddock, fix.latitude, fix.longitude, fix.accuracyMetres)
                } else null
                Evidence(
                    observedAtElapsedRealtimeNanos = fix.fixElapsedRealtimeNanos,
                    paddockId = paddock.id.takeIf { inside },
                    aisleNumber = approximate?.aisleNumber,
                    isQualified = qualified?.aisleNumber == approximate?.aisleNumber,
                )
            }
        val lock = resolve(evidence, current.fixElapsedRealtimeNanos) ?: return null
        val currentApproximate = PinAisleGeometry.approximateAisle(paddock, current.latitude, current.longitude)
        return lock.takeIf { it.paddockId == paddock.id && currentApproximate != null }
    }

    private fun ageMs(observed: Long, capture: Long): Long {
        if (observed <= 0L || capture < observed) return Long.MAX_VALUE
        return (capture - observed) / 1_000_000L
    }

    private fun sameAisle(lhs: Double, rhs: Double): Boolean = abs(lhs - rhs) < 0.01
}
