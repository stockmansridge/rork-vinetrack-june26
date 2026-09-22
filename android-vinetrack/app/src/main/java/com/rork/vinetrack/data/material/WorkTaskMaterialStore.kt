package com.rork.vinetrack.data.material

import android.content.Context
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Local persistence for Work Task Material Costs (sql/247).
 *
 * Backs three slices with JSON blobs in SharedPreferences, following the same
 * lightweight local-only pattern as [com.rork.vinetrack.data.PendingWriteStore]
 * and `CanopyWaterRatesStore`. Room + KSP would be disproportionate: these
 * slices are small and whole-list read/replace.
 *
 * Durability requirement: a material line created offline must survive app
 * termination, relaunch and network loss, then sync exactly once. Writes use
 * `commit()` (not `apply()`) so the caller learns whether the bytes actually
 * reached disk before an optimistic line is treated as saved.
 *
 * ## The base catalogue is global
 *
 * `material_catalogue` is not vineyard scoped — the same 18 high-level items
 * for everyone — so it is one slice. When nothing has ever synced,
 * [MaterialCatalogueSeed] supplies the bundled offline fallback using the SAME
 * stable keys as Supabase and iOS.
 */
interface WorkTaskMaterialStoring {
    fun loadCatalogue(): List<MaterialCatalogueItem>?
    fun saveCatalogue(items: List<MaterialCatalogueItem>): Boolean

    fun loadVineyardMaterials(): List<VineyardMaterial>
    fun saveVineyardMaterials(items: List<VineyardMaterial>): Boolean

    fun loadTaskMaterials(): List<WorkTaskMaterial>
    fun saveTaskMaterials(items: List<WorkTaskMaterial>): Boolean

    fun clear(): Boolean
}

class WorkTaskMaterialStore(context: Context) : WorkTaskMaterialStoring {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_work_task_materials", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val catalogueSerializer = ListSerializer(MaterialCatalogueItem.serializer())
    private val vineyardSerializer = ListSerializer(VineyardMaterial.serializer())
    private val taskSerializer = ListSerializer(WorkTaskMaterial.serializer())

    /** The cached SERVER catalogue, or null when nothing has ever synced. */
    override fun loadCatalogue(): List<MaterialCatalogueItem>? {
        val raw = prefs.getString(KEY_CATALOGUE, null) ?: return null
        return runCatching { json.decodeFromString(catalogueSerializer, raw) }.getOrNull()
    }

    /**
     * Cache an authoritative server catalogue. An EMPTY list is refused rather
     * than stored: it would blank every picker, and in practice only happens
     * when the migration has not been applied yet.
     */
    override fun saveCatalogue(items: List<MaterialCatalogueItem>): Boolean {
        if (items.isEmpty()) return false
        return prefs.edit()
            .putString(KEY_CATALOGUE, json.encodeToString(catalogueSerializer, items))
            .commit()
    }

    override fun loadVineyardMaterials(): List<VineyardMaterial> {
        val raw = prefs.getString(KEY_VINEYARD_MATERIALS, null) ?: return emptyList()
        return runCatching { json.decodeFromString(vineyardSerializer, raw) }.getOrDefault(emptyList())
    }

    override fun saveVineyardMaterials(items: List<VineyardMaterial>): Boolean =
        prefs.edit()
            .putString(KEY_VINEYARD_MATERIALS, json.encodeToString(vineyardSerializer, items))
            .commit()

    override fun loadTaskMaterials(): List<WorkTaskMaterial> {
        val raw = prefs.getString(KEY_TASK_MATERIALS, null) ?: return emptyList()
        return runCatching { json.decodeFromString(taskSerializer, raw) }.getOrDefault(emptyList())
    }

    override fun saveTaskMaterials(items: List<WorkTaskMaterial>): Boolean =
        prefs.edit()
            .putString(KEY_TASK_MATERIALS, json.encodeToString(taskSerializer, items))
            .commit()

    override fun clear(): Boolean = prefs.edit()
        .remove(KEY_CATALOGUE)
        .remove(KEY_VINEYARD_MATERIALS)
        .remove(KEY_TASK_MATERIALS)
        .commit()

    private companion object {
        const val KEY_CATALOGUE = "material_catalogue_json"
        const val KEY_VINEYARD_MATERIALS = "vineyard_materials_json"
        const val KEY_TASK_MATERIALS = "work_task_materials_json"
    }
}

/** Volatile [WorkTaskMaterialStoring] for unit tests. */
class InMemoryWorkTaskMaterialStore(
    private var catalogue: List<MaterialCatalogueItem>? = null,
    private var vineyardMaterials: List<VineyardMaterial> = emptyList(),
    private var taskMaterials: List<WorkTaskMaterial> = emptyList(),
) : WorkTaskMaterialStoring {

    /** When true, every save fails — models a full or unwritable disk. */
    var failWrites: Boolean = false

    override fun loadCatalogue(): List<MaterialCatalogueItem>? = catalogue

    override fun saveCatalogue(items: List<MaterialCatalogueItem>): Boolean {
        if (failWrites || items.isEmpty()) return false
        catalogue = items
        return true
    }

    override fun loadVineyardMaterials(): List<VineyardMaterial> = vineyardMaterials

    override fun saveVineyardMaterials(items: List<VineyardMaterial>): Boolean {
        if (failWrites) return false
        vineyardMaterials = items
        return true
    }

    override fun loadTaskMaterials(): List<WorkTaskMaterial> = taskMaterials

    override fun saveTaskMaterials(items: List<WorkTaskMaterial>): Boolean {
        if (failWrites) return false
        taskMaterials = items
        return true
    }

    override fun clear(): Boolean {
        catalogue = null
        vineyardMaterials = emptyList()
        taskMaterials = emptyList()
        return true
    }
}
