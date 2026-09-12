package com.rork.vinetrack.ui.screens

import com.rork.vinetrack.data.model.BuiltInGrapeVarietyGDD
import com.rork.vinetrack.data.model.GrapeVarietyRow
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.canonicalVarietyName
import java.util.Locale

/** Display-only allocation resolution shared by Vineyard Overview and Setup. */
internal object VineyardVarietyPresentation {
    data class Resolved(
        val name: String?,
        val isResolved: Boolean,
    )

    data class Line(
        val identity: String,
        val name: String?,
        val percentText: String?,
        val clone: String?,
        val rootstock: String?,
    ) {
        val compactText: String
            get() = buildList {
                val head = listOfNotNull(name, percentText).joinToString(" ")
                if (head.isNotBlank()) add(head)
                clone?.let { add("Clone $it") }
                rootstock?.let { add("Rootstock $it") }
            }.joinToString(" · ")
    }

    fun resolve(allocation: PaddockVarietyAllocation, varieties: List<GrapeVarietyRow>): Resolved {
        val allocationKey = allocation.varietyKey?.trim()?.takeIf { it.isNotEmpty() }
        if (allocationKey != null) {
            varieties.firstOrNull { it.varietyKey == allocationKey }?.let {
                return Resolved(it.displayName.trim().takeIf(String::isNotEmpty), true)
            }
            BuiltInGrapeVarietyGDD.displayNameForKey(allocationKey)?.let {
                return Resolved(it, true)
            }
        }

        val allocationId = allocation.varietyId?.trim()?.takeIf { it.isNotEmpty() }
        if (allocationId != null) {
            varieties.firstOrNull { it.id.equals(allocationId, ignoreCase = true) }?.let {
                return Resolved(it.displayName.trim().takeIf(String::isNotEmpty), true)
            }
        }

        val rawName = allocation.displayName?.trim()?.takeIf { it.isNotEmpty() }
        if (rawName != null) {
            val canonical = canonicalVarietyName(rawName)
            varieties.firstOrNull { canonicalVarietyName(it.displayName) == canonical }?.let {
                return Resolved(it.displayName.trim().takeIf(String::isNotEmpty), true)
            }
            BuiltInGrapeVarietyGDD.displayNameForName(rawName)?.let {
                return Resolved(it, true)
            }
            return Resolved(rawName, true)
        }
        return Resolved(null, false)
    }

    fun lines(allocations: List<PaddockVarietyAllocation>, varieties: List<GrapeVarietyRow>): List<Line> =
        allocations.withIndex()
            .sortedWith(compareByDescending<IndexedValue<PaddockVarietyAllocation>> { it.value.displayPercent ?: 0.0 }.thenBy { it.index })
            .mapNotNull { indexed ->
                val allocation = indexed.value
                val resolved = resolve(allocation, varieties)
                val clone = allocation.clone?.trim()?.takeIf { it.isNotEmpty() }
                val rootstock = allocation.rootstock?.trim()?.takeIf { it.isNotEmpty() }
                if (resolved.name == null && clone == null && rootstock == null) return@mapNotNull null
                Line(
                    identity = allocation.id ?: "${indexed.index}:${allocation.varietyKey}:${allocation.varietyId}",
                    name = resolved.name,
                    percentText = allocation.displayPercent?.takeIf { it > 0 }?.let(::percentText),
                    clone = clone,
                    rootstock = rootstock,
                )
            }

    fun isComplete(allocations: List<PaddockVarietyAllocation>, varieties: List<GrapeVarietyRow>): Boolean {
        if (allocations.isEmpty()) return false
        val total = allocations.sumOf { it.displayPercent ?: 0.0 }
        if (kotlin.math.abs(total - 100.0) >= 0.5) return false
        return allocations.all { allocation ->
            val resolved = resolve(allocation, varieties)
            val name = resolved.name?.trim().orEmpty()
            resolved.isResolved && name.isNotEmpty() && !name.equals("Unknown", ignoreCase = true)
        }
    }

    private fun percentText(value: Double): String =
        if (value == value.toLong().toDouble()) "${value.toLong()}%"
        else String.format(Locale.US, "%.1f%%", value)
}

/** iOS-equivalent presentation calculations; no operational calculation consumes these. */
internal object VineyardBlockPresentation {
    fun litresPerHour(block: Paddock): Double? {
        val spacing = block.emitterSpacing?.takeIf { it > 0 } ?: return null
        val flow = block.flowPerEmitter?.takeIf { it > 0 } ?: return null
        if (block.rows.isNullOrEmpty()) return null
        return (block.effectiveTotalRowLength / spacing) * flow
    }

    fun totalEmitters(block: Paddock): Int? {
        val spacing = block.emitterSpacing?.takeIf { it > 0 } ?: return null
        return (block.effectiveTotalRowLength / spacing).toInt()
    }

    fun intermediatePostCount(block: Paddock): Int? {
        val spacing = block.intermediatePostSpacing?.takeIf { it > 0 } ?: return null
        val total = block.effectiveTotalRowLength.takeIf { it > 0 } ?: return null
        return ((total / spacing).toInt() - 2 * block.rowCount).coerceAtLeast(0)
    }

    fun litresPerVinePerHour(block: Paddock): Double? {
        val flow = block.flowPerEmitter ?: return null
        val emitterSpacing = block.emitterSpacing?.takeIf { it > 0 } ?: return null
        val vineSpacing = block.vineSpacing?.takeIf { it > 0 } ?: return null
        return (vineSpacing / emitterSpacing) * flow
    }
}
