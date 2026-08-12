package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Reserved allocation-level keys that are deliberately NOT catalogue rows
 * (sql/182). `MASS_SELECTION` marks vines with no certified clone identity;
 * `OWN_ROOTS` marks ungrafted vines (not a biological rootstock). A null
 * key means "not specified / not recorded". Mirrors iOS
 * `CloneRootstockSentinels`.
 */
object CloneRootstockSentinels {
    const val MASS_SELECTION = "mass_selection"
    const val MASS_SELECTION_DISPLAY = "Mass selection"
    const val OWN_ROOTS = "own_roots"
    const val OWN_ROOTS_DISPLAY = "Own roots"
}

/** Row from `get_grape_clone_catalog` (sql/182). A clone belongs to ONE variety. */
@Serializable
data class CloneCatalogEntry(
    val key: String,
    @SerialName("variety_key") val varietyKey: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("clone_code") val cloneCode: String = "",
    @SerialName("selection_system") val selectionSystem: String? = null,
    @SerialName("source_country") val sourceCountry: String? = null,
    val aliases: List<String> = emptyList(),
    @SerialName("source_reference") val sourceReference: String? = null,
    @SerialName("is_builtin") val isBuiltin: Boolean = true,
    @SerialName("is_active") val isActive: Boolean = true,
) {
    /** e.g. "ENTAV-INRA · France" for the picker subtitle. */
    val subtitle: String
        get() = listOfNotNull(selectionSystem, sourceCountry).joinToString(" · ")
}

/** Row from `get_rootstock_catalog` (sql/182). Independent of scion variety. */
@Serializable
data class RootstockCatalogEntry(
    val key: String,
    @SerialName("canonical_name") val canonicalName: String,
    @SerialName("display_name") val displayName: String,
    val aliases: List<String> = emptyList(),
    val parentage: String? = null,
    @SerialName("source_reference") val sourceReference: String? = null,
    @SerialName("is_builtin") val isBuiltin: Boolean = true,
    @SerialName("is_active") val isActive: Boolean = true,
)

/** Row from `list_vineyard_grape_clones` / `upsert_vineyard_grape_clone`. */
@Serializable
data class VineyardCloneRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("clone_key") val cloneKey: String,
    @SerialName("variety_key") val varietyKey: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("is_custom") val isCustom: Boolean = true,
    @SerialName("is_active") val isActive: Boolean = true,
)

/** Row from `list_vineyard_rootstocks` / `upsert_vineyard_rootstock`. */
@Serializable
data class VineyardRootstockRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("rootstock_key") val rootstockKey: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("is_custom") val isCustom: Boolean = true,
    @SerialName("is_active") val isActive: Boolean = true,
)

/**
 * Pure option-filtering helpers shared by the Block Setup pickers and unit
 * tests. Mirrors the iOS picker filtering exactly:
 *   * clone options are ALWAYS scoped to one variety key — a custom Shiraz
 *     clone never surfaces under Chardonnay;
 *   * search matches display name, code, and aliases (case-insensitive);
 *   * rootstock options are global (catalogue + vineyard custom).
 */
object CloneRootstockOptions {

    fun systemClonesForVariety(
        catalog: List<CloneCatalogEntry>,
        varietyKey: String?,
        query: String = "",
    ): List<CloneCatalogEntry> {
        if (varietyKey.isNullOrBlank()) return emptyList()
        val q = query.trim()
        return catalog.filter { entry ->
            entry.isActive && entry.varietyKey == varietyKey && (
                q.isEmpty() ||
                    entry.displayName.contains(q, ignoreCase = true) ||
                    entry.cloneCode.contains(q, ignoreCase = true) ||
                    entry.aliases.any { it.contains(q, ignoreCase = true) }
                )
        }
    }

    fun customClonesForVariety(
        custom: List<VineyardCloneRow>,
        varietyKey: String?,
        query: String = "",
    ): List<VineyardCloneRow> {
        if (varietyKey.isNullOrBlank()) return emptyList()
        val q = query.trim()
        return custom.filter { row ->
            row.isActive && row.varietyKey == varietyKey &&
                (q.isEmpty() || row.displayName.contains(q, ignoreCase = true))
        }
    }

    fun systemRootstocks(
        catalog: List<RootstockCatalogEntry>,
        query: String = "",
    ): List<RootstockCatalogEntry> {
        val q = query.trim()
        return catalog.filter { entry ->
            entry.isActive && (
                q.isEmpty() ||
                    entry.displayName.contains(q, ignoreCase = true) ||
                    entry.canonicalName.contains(q, ignoreCase = true) ||
                    entry.aliases.any { it.contains(q, ignoreCase = true) } ||
                    (entry.parentage?.contains(q, ignoreCase = true) ?: false)
                )
        }
    }

    fun customRootstocks(
        custom: List<VineyardRootstockRow>,
        query: String = "",
    ): List<VineyardRootstockRow> {
        val q = query.trim()
        return custom.filter { row ->
            row.isActive && (q.isEmpty() || row.displayName.contains(q, ignoreCase = true))
        }
    }

    /**
     * True when the typed name matches no existing option, so a
     * "Add as custom" action may be offered.
     */
    fun canOfferCustomClone(
        catalog: List<CloneCatalogEntry>,
        custom: List<VineyardCloneRow>,
        varietyKey: String?,
        query: String,
    ): Boolean {
        val q = query.trim()
        if (q.isEmpty() || varietyKey.isNullOrBlank()) return false
        val inSystem = catalog.any {
            it.isActive && it.varietyKey == varietyKey &&
                (it.displayName.equals(q, ignoreCase = true) || it.cloneCode.equals(q, ignoreCase = true))
        }
        val inCustom = custom.any {
            it.isActive && it.varietyKey == varietyKey && it.displayName.equals(q, ignoreCase = true)
        }
        return !inSystem && !inCustom
    }

    fun canOfferCustomRootstock(
        catalog: List<RootstockCatalogEntry>,
        custom: List<VineyardRootstockRow>,
        query: String,
    ): Boolean {
        val q = query.trim()
        if (q.isEmpty()) return false
        val inSystem = catalog.any { entry ->
            entry.isActive && (
                entry.displayName.equals(q, ignoreCase = true) ||
                    entry.canonicalName.equals(q, ignoreCase = true) ||
                    entry.aliases.any { it.equals(q, ignoreCase = true) }
                )
        }
        val inCustom = custom.any { it.isActive && it.displayName.equals(q, ignoreCase = true) }
        return !inSystem && !inCustom
    }
}

/**
 * Pure helpers for the Grape Varieties settings CATALOGUE BROWSER
 * (Varieties | Clones | Rootstocks). Unlike [CloneRootstockOptions] — which
 * powers the per-allocation pickers and therefore always scopes clones to one
 * variety — the browser can list across ALL varieties (`varietyKey == null`).
 *
 * Also owns allocation-usage matching: an allocation "uses" a catalogue record
 * when its stable key matches, or (legacy rows only, key absent) when its
 * free-text snapshot canonically equals one of the record's names/aliases.
 * Reserved sentinels (`mass_selection`, `own_roots`) are allocation-level
 * conventions, never catalogue rows, so they can never match a record.
 *
 * Mirrored exactly by iOS `CloneRootstockBrowse`; behaviour is pinned by
 * `CloneRootstockBrowseTest.kt` / `CloneRootstockBrowseTests.swift`.
 */
object CloneRootstockBrowse {

    /** Built-in clones, optionally scoped to one variety (`null` = all). */
    fun systemClones(
        catalog: List<CloneCatalogEntry>,
        varietyKey: String?,
        query: String = "",
    ): List<CloneCatalogEntry> {
        val q = query.trim()
        return catalog.filter { entry ->
            entry.isActive &&
                (varietyKey == null || entry.varietyKey == varietyKey) &&
                (
                    q.isEmpty() ||
                        entry.displayName.contains(q, ignoreCase = true) ||
                        entry.cloneCode.contains(q, ignoreCase = true) ||
                        entry.aliases.any { it.contains(q, ignoreCase = true) }
                    )
        }
    }

    /** Vineyard custom clones, optionally scoped to one variety (`null` = all). */
    fun customClones(
        custom: List<VineyardCloneRow>,
        varietyKey: String?,
        query: String = "",
    ): List<VineyardCloneRow> {
        val q = query.trim()
        return custom.filter { row ->
            row.isActive &&
                (varietyKey == null || row.varietyKey == varietyKey) &&
                (q.isEmpty() || row.displayName.contains(q, ignoreCase = true))
        }
    }

    /** Built-in rootstocks (rootstocks are independent of scion variety). */
    fun systemRootstocks(
        catalog: List<RootstockCatalogEntry>,
        query: String = "",
    ): List<RootstockCatalogEntry> = CloneRootstockOptions.systemRootstocks(catalog, query)

    /** Vineyard custom rootstocks. */
    fun customRootstocks(
        custom: List<VineyardRootstockRow>,
        query: String = "",
    ): List<VineyardRootstockRow> = CloneRootstockOptions.customRootstocks(custom, query)

    /** Names a built-in clone can be matched against (legacy free text). */
    fun cloneMatchNames(entry: CloneCatalogEntry): List<String> =
        listOf(entry.displayName, entry.cloneCode) + entry.aliases

    /** Names a built-in rootstock can be matched against (legacy free text). */
    fun rootstockMatchNames(entry: RootstockCatalogEntry): List<String> =
        listOf(entry.displayName, entry.canonicalName) + entry.aliases

    /**
     * True when a block allocation uses the clone identified by [entryKey].
     * Stable-key match wins; legacy free-text (no key) matches canonically
     * against [matchNames]. An allocation carrying a DIFFERENT key (including
     * the `mass_selection` sentinel) never matches, even if its display text
     * happens to collide.
     */
    fun allocationUsesClone(
        allocationCloneKey: String?,
        allocationCloneText: String?,
        entryKey: String,
        matchNames: List<String>,
    ): Boolean {
        if (allocationCloneKey == entryKey) return true
        if (allocationCloneKey != null) return false
        val canonical = allocationCloneText?.let { canonicalVarietyName(it) } ?: return false
        if (canonical.isEmpty()) return false
        return matchNames.any { canonicalVarietyName(it) == canonical }
    }

    /** Rootstock counterpart of [allocationUsesClone]. */
    fun allocationUsesRootstock(
        allocationRootstockKey: String?,
        allocationRootstockText: String?,
        entryKey: String,
        matchNames: List<String>,
    ): Boolean {
        if (allocationRootstockKey == entryKey) return true
        if (allocationRootstockKey != null) return false
        val canonical = allocationRootstockText?.let { canonicalVarietyName(it) } ?: return false
        if (canonical.isEmpty()) return false
        return matchNames.any { canonicalVarietyName(it) == canonical }
    }
}
