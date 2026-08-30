package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.resolveSprayTrip

/**
 * Sort options for the Spray Program landing. The Program tab defaults to
 * phenological order (E-L ascending) — a reusable Program Step is not dated,
 * so date sorts only mean something on the Sprays tab. Mirrors the iOS
 * `SprayProgramStepSortOption` / `SprayProgramSortOption` pair.
 */
enum class SprayProgramSort(val label: String) {
    EL_ASC("E-L stage (low \u2192 high)"),
    EL_DESC("E-L stage (high \u2192 low)"),
    DATE_NEWEST("Newest"),
    DATE_OLDEST("Oldest"),
    NAME_AZ("Name (A\u2013Z)"),
    NAME_ZA("Name (Z\u2013A)"),
}

/**
 * Pure list rules for the Spray Program landing — merge, sort, search — the
 * Android mirror of the iOS `SprayProgramCatalog`. Pure so the rules the two
 * tabs disagree about least often are provable without a Compose host.
 */
object SprayProgramLanding {

    /**
     * Finds an E-L (Eichhorn–Lorenz) stage mention in free text — "EL12",
     * "EL 12", "E-L 12", "el-7" — so sorting can use the numeric stage value.
     * The leading look-behind stops words like "Model 3" or "Diesel 5"
     * matching.
     */
    private val EL_STAGE_TEXT_REGEX = Regex("""(?i)(?<![a-z0-9])e-?l[\s.\-]*([0-9]{1,3})""")

    /**
     * The numeric E-L stage for a record. Portal Program Steps carry the
     * canonical `growth_stage_code` (sql/034); every other record falls back
     * to an "EL n" mention in its reference or notes. Null when no stage is
     * known — an unknown stage is never given a plausible one.
     */
    fun elStageNumber(record: SprayRecord): Int? {
        record.templateGrowthStageCode?.let { code ->
            code.filter { it.isDigit() }.take(3).toIntOrNull()?.takeIf { it > 0 }?.let { return it }
        }
        val text = "${record.displayLabel} ${record.notes ?: ""}"
        return EL_STAGE_TEXT_REGEX.find(text)?.groupValues?.getOrNull(1)?.toIntOrNull()?.takeIf { it > 0 }
    }

    /** Badge text such as "EL4", or null when no stage is known. */
    fun elStageLabel(record: SprayRecord): String? =
        record.templateGrowthStageCode?.trim()?.takeIf { it.isNotEmpty() }?.uppercase()
            ?: elStageNumber(record)?.let { "EL$it" }

    /**
     * Applies the selected sort. E-L sorts numerically by actual stage value
     * (EL 7 < EL 12 < EL 31, never alphabetical); records with no known stage
     * always sink to the bottom in either direction — an unknown stage is not
     * a low stage — newest-first among themselves.
     */
    fun sort(records: List<SprayRecord>, sort: SprayProgramSort): List<SprayRecord> = when (sort) {
        SprayProgramSort.DATE_NEWEST -> records.sortedByDescending { it.dateEpochMs ?: 0L }
        SprayProgramSort.DATE_OLDEST -> records.sortedBy { it.dateEpochMs ?: 0L }
        SprayProgramSort.NAME_AZ -> records.sortedBy { it.displayLabel.lowercase() }
        SprayProgramSort.NAME_ZA -> records.sortedByDescending { it.displayLabel.lowercase() }
        SprayProgramSort.EL_ASC, SprayProgramSort.EL_DESC -> {
            val ascending = sort == SprayProgramSort.EL_ASC
            records
                .map { it to elStageNumber(it) }
                .sortedWith(
                    Comparator { a, b ->
                        val ea = a.second
                        val eb = b.second
                        when {
                            ea != null && eb != null && ea != eb -> if (ascending) ea - eb else eb - ea
                            ea != null && eb == null -> -1
                            ea == null && eb != null -> 1
                            else -> (b.first.dateEpochMs ?: 0L).compareTo(a.first.dateEpochMs ?: 0L)
                        }
                    },
                )
                .map { it.first }
        }
    }

    /**
     * Merge local Program Steps (`spray_records` with `is_template`) with
     * portal steps (`spray_jobs`), deduped by id. Local wins on an id
     * collision — a record the device owns must not be shadowed by a
     * read-mapped copy. Mirrors iOS `SprayProgramCatalog.steps`.
     */
    fun mergedProgramSteps(
        localRecords: List<SprayRecord>,
        portalTemplates: List<SprayRecord>,
    ): List<SprayRecord> {
        val local = localRecords.filter { it.isTemplate }
        val localIds = local.map { it.id }.toSet()
        val seenPortal = mutableSetOf<String>()
        val portal = portalTemplates.filter { it.id !in localIds && seenPortal.add(it.id) }
        return local + portal
    }

    /**
     * Client-side match across everything a Program Step actually states:
     * name, notes, method, stage, target wording and product names. "EL12"
     * also matches a step whose stage came from a code written differently
     * ("E-L 12") by comparing stage NUMBERS. Mirrors iOS
     * `SprayProgramStep.matches`.
     */
    fun programStepMatches(
        record: SprayRecord,
        query: String,
        labels: Map<String, String> = emptyMap(),
    ): Boolean {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return true

        val queryStage = EL_STAGE_TEXT_REGEX.find(trimmed)
            ?.groupValues?.getOrNull(1)?.toIntOrNull()?.takeIf { it > 0 }
        if (queryStage != null && queryStage == elStageNumber(record)) return true

        val targetLabels = SprayTargetVocabulary.tags(
            identifiers = record.targets.orEmpty(),
            wording = null,
            labels = labels,
        ).map { it.label }

        val haystack = buildList {
            add(record.displayLabel)
            record.notes?.let(::add)
            record.operationType?.let(::add)
            elStageLabel(record)?.let(::add)
            addAll(targetLabels)
            addAll(record.chemicalNames)
        }
        return haystack.any { it.contains(trimmed, ignoreCase = true) }
    }

    /**
     * Case-insensitive match for an operational spray record, mirroring the
     * iOS Sprays-tab search: reference, paddock, chemicals, notes, equipment.
     */
    fun sprayMatches(record: SprayRecord, trips: List<Trip>, query: String): Boolean {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return true
        val paddock = resolveSprayTrip(record, trips)?.paddockName ?: ""
        val chemicals = record.chemicalNames.joinToString(" ")
        val combined = "${record.displayLabel} $paddock $chemicals ${record.notes ?: ""} ${record.equipmentType ?: ""}"
        return combined.contains(trimmed, ignoreCase = true)
    }
}
