package com.rork.vinetrack.data

import java.util.UUID

/**
 * Resolves the current blocks represented by dashboard activity sources using
 * UUID identity, matching iOS semantics without changing any stored value.
 */
fun dashboardWorkedBlockIds(
    currentBlockIds: Iterable<String>,
    pinBlockIds: Iterable<String>,
    tripBlockIds: Iterable<String>,
    sprayBlockIds: Iterable<String>,
): Set<String> {
    val current = currentBlockIds.mapNotNullTo(LinkedHashSet(), ::canonicalUuid)
    if (current.isEmpty()) return emptySet()

    return sequenceOf(pinBlockIds, tripBlockIds, sprayBlockIds)
        .flatMap { ids -> ids.asSequence() }
        .mapNotNull(::canonicalUuid)
        .filterTo(LinkedHashSet()) { it in current }
}

private fun canonicalUuid(raw: String): String? =
    runCatching { UUID.fromString(raw.trim()).toString() }.getOrNull()
