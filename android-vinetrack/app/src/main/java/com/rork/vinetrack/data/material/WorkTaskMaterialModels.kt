package com.rork.vinetrack.data.material

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.math.RoundingMode

/**
 * Work Task Material Costs — domain models (sql/247). The Android twin of the
 * iOS `WorkTaskMaterial.swift`; both platforms interpret the SAME backend rows
 * and use the SAME stable catalogue keys.
 *
 * The whole concept is `material + quantity + unit + unit cost = material cost`.
 * This is NOT inventory: no stock on hand, no stock movement, no warehouse, no
 * purchase order, no supplier, no invoice, no receipt, no minimum-stock alert,
 * no SKU/barcode, no tax and no pack-to-unit conversion appear anywhere here.
 *
 * Three layers, mirroring the database exactly:
 *
 *  1. [MaterialCatalogueItem] — global VineTrack base catalogue
 *     (`public.material_catalogue`). High level, system owned, PRICE FREE.
 *  2. [VineyardMaterial]      — one vineyard's library
 *     (`public.vineyard_materials`): its default costs for base items plus its
 *     own custom materials. Prices live HERE.
 *  3. [WorkTaskMaterial]      — what was actually used on a task
 *     (`public.work_task_materials`), carrying a FROZEN snapshot.
 *
 * ## Money
 *
 * Quantity and money cross the wire as JSON numbers and are held as [String]
 * in the serializable DTOs, then read through [BigDecimal] accessors. Kotlin
 * `Double` is never the authoritative representation: `0.1 + 0.2` problems
 * have no place in a grower's costs, and the database columns are `numeric`.
 */

// ---------------------------------------------------------------------------
// Units
// ---------------------------------------------------------------------------

/**
 * Suggested units. Deliberately NOT an enum end-to-end — the database column is
 * free text so a future custom unit needs no migration. This only drives
 * suggestions.
 */
object MaterialUnitCatalog {
    val suggested: List<String> = listOf("Each", "Metre", "Roll", "Pack", "Box", "Bag")

    /**
     * Trim, falling back to `Each` when a caller supplies nothing. The database
     * rejects a blank unit; this stops the client ever attempting that write.
     */
    fun normalised(raw: String?): String {
        val trimmed = raw?.trim().orEmpty()
        return trimmed.ifEmpty { "Each" }
    }
}

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

/**
 * The base catalogue's category names. Free text in the database (so a
 * vineyard's custom material can sit anywhere); listed here only for stable
 * display ordering.
 */
object MaterialCategoryCatalog {
    const val TRELLIS = "Trellis"
    const val FASTENERS = "Fasteners & Training"
    const val NETTING = "Netting & Protection"
    const val IRRIGATION = "Irrigation"
    const val ESTABLISHMENT = "Vine Establishment"
    const val OTHER = "Other"

    val ordered: List<String> = listOf(TRELLIS, FASTENERS, NETTING, IRRIGATION, ESTABLISHMENT, OTHER)

    /** Unknown (vineyard-invented) categories sort after the known ones, never hidden. */
    fun order(category: String): Int =
        ordered.indexOf(category).let { if (it < 0) ordered.size else it }
}

// ---------------------------------------------------------------------------
// Money helpers
// ---------------------------------------------------------------------------

object MaterialMoney {
    /** Parse a persisted/serialised numeric without going through `Double`. */
    fun decimal(raw: String?): BigDecimal =
        raw?.takeIf { it.isNotBlank() }?.let { runCatching { BigDecimal(it) }.getOrNull() } ?: BigDecimal.ZERO

    /** Parse a nullable numeric — null means "no default cost set", not zero. */
    fun decimalOrNull(raw: String?): BigDecimal? =
        raw?.takeIf { it.isNotBlank() }?.let { runCatching { BigDecimal(it) }.getOrNull() }

    /**
     * `quantity × unitCost` rounded to 2dp HALF_UP — identical to the generated
     * `work_task_materials.total_cost` column and to the iOS calculation, so a
     * device and the server can never disagree.
     */
    fun lineTotal(quantity: BigDecimal, unitCost: BigDecimal): BigDecimal =
        quantity.multiply(unitCost).setScale(2, RoundingMode.HALF_UP)

    /** Canonical wire form for a numeric: plain string, never scientific notation. */
    fun wire(value: BigDecimal): String = value.stripTrailingZeros().toPlainString()
}

// ---------------------------------------------------------------------------
// A. Base catalogue
// ---------------------------------------------------------------------------

/**
 * One row of the global base catalogue (`public.material_catalogue`).
 *
 * IDENTITY IS [key], not the row UUID: the server mints its own UUIDs so the
 * bundled offline copy cannot know them, but Supabase, iOS and Android all
 * agree on the key. [remoteId] is the server row id once known and is required
 * before a vineyard OVERRIDE can be written (the database's
 * `vineyard_materials_custom_shape` check needs a real `base_material_id`).
 */
@Serializable
data class MaterialCatalogueItem(
    val key: String,
    @SerialName("id") val remoteId: String? = null,
    val name: String = "",
    val category: String = MaterialCategoryCatalog.OTHER,
    @SerialName("default_unit") val defaultUnit: String = "Each",
    @SerialName("sort_order") val sortOrder: Int = 0,
    @SerialName("is_active") val isActive: Boolean = true,
)

/**
 * The bundled offline copy of the base catalogue.
 *
 * VineTrack is offline first, so a fresh install with no connectivity must
 * still open a usable material picker. These entries use the EXACT keys,
 * names, categories, units and sort orders seeded by sql/247 and mirrored in
 * the iOS `MaterialCatalogueSeed`, so the same material is never two different
 * materials across Supabase, iOS and Android. A synced server catalogue is
 * authoritative and wins.
 */
object MaterialCatalogueSeed {
    val items: List<MaterialCatalogueItem> = listOf(
        // Trellis
        MaterialCatalogueItem("material.trellis.line_post", name = "Line / Trellis Post",
            category = MaterialCategoryCatalog.TRELLIS, defaultUnit = "Each", sortOrder = 10),
        MaterialCatalogueItem("material.trellis.end_post", name = "End / Strainer Post",
            category = MaterialCategoryCatalog.TRELLIS, defaultUnit = "Each", sortOrder = 20),
        MaterialCatalogueItem("material.trellis.wire", name = "Trellis Wire",
            category = MaterialCategoryCatalog.TRELLIS, defaultUnit = "Metre", sortOrder = 30),
        MaterialCatalogueItem("material.trellis.anchor", name = "Anchor / Stay",
            category = MaterialCategoryCatalog.TRELLIS, defaultUnit = "Each", sortOrder = 40),
        MaterialCatalogueItem("material.trellis.gripple", name = "Gripple / Wire Joiner-Tensioner",
            category = MaterialCategoryCatalog.TRELLIS, defaultUnit = "Each", sortOrder = 50),
        // Fasteners & Training
        MaterialCatalogueItem("material.fastener.trellis_clip", name = "Trellis Clip / Staple",
            category = MaterialCategoryCatalog.FASTENERS, defaultUnit = "Each", sortOrder = 60),
        MaterialCatalogueItem("material.fastener.vine_tie", name = "Vine / Wire Tie",
            category = MaterialCategoryCatalog.FASTENERS, defaultUnit = "Each", sortOrder = 70),
        MaterialCatalogueItem("material.fastener.zip_tie", name = "Cable / Zip Tie",
            category = MaterialCategoryCatalog.FASTENERS, defaultUnit = "Each", sortOrder = 80),
        // Netting & Protection
        MaterialCatalogueItem("material.netting.post_cap", name = "Post / Netting Cap",
            category = MaterialCategoryCatalog.NETTING, defaultUnit = "Each", sortOrder = 90),
        MaterialCatalogueItem("material.netting.bird_netting", name = "Bird Netting",
            category = MaterialCategoryCatalog.NETTING, defaultUnit = "Metre", sortOrder = 100),
        MaterialCatalogueItem("material.netting.clip_repair", name = "Netting Clip / Repair Material",
            category = MaterialCategoryCatalog.NETTING, defaultUnit = "Each", sortOrder = 110),
        // Irrigation
        MaterialCatalogueItem("material.irrigation.dripline", name = "Dripline / Poly Pipe",
            category = MaterialCategoryCatalog.IRRIGATION, defaultUnit = "Metre", sortOrder = 120),
        MaterialCatalogueItem("material.irrigation.dripper", name = "Dripper / Emitter",
            category = MaterialCategoryCatalog.IRRIGATION, defaultUnit = "Each", sortOrder = 130),
        MaterialCatalogueItem("material.irrigation.fitting", name = "Irrigation Fitting / Repair Joiner",
            category = MaterialCategoryCatalog.IRRIGATION, defaultUnit = "Each", sortOrder = 140),
        // Vine Establishment
        MaterialCatalogueItem("material.establishment.vine_stake", name = "Vine Stake",
            category = MaterialCategoryCatalog.ESTABLISHMENT, defaultUnit = "Each", sortOrder = 150),
        MaterialCatalogueItem("material.establishment.vine_guard", name = "Vine Guard",
            category = MaterialCategoryCatalog.ESTABLISHMENT, defaultUnit = "Each", sortOrder = 160),
        MaterialCatalogueItem("material.establishment.vine", name = "Replacement Vine",
            category = MaterialCategoryCatalog.ESTABLISHMENT, defaultUnit = "Each", sortOrder = 170),
        // Other
        MaterialCatalogueItem("material.other.miscellaneous", name = "Other / Miscellaneous Material",
            category = MaterialCategoryCatalog.OTHER, defaultUnit = "Each", sortOrder = 180),
    )

    /** Every seeded key, for parity assertions against iOS and the database. */
    val keys: List<String> = items.map { it.key }

    /**
     * Resolve the catalogue through `server → cached → bundled`. A failed or
     * empty server read never blanks a picker; the bundled fallback keeps a
     * fresh offline install usable with the same keys the server uses.
     */
    fun resolve(server: List<MaterialCatalogueItem>?, cached: List<MaterialCatalogueItem>?): List<MaterialCatalogueItem> =
        when {
            !server.isNullOrEmpty() -> server
            !cached.isNullOrEmpty() -> cached
            else -> items
        }
}

// ---------------------------------------------------------------------------
// B. Vineyard material library
// ---------------------------------------------------------------------------

/**
 * One row of a vineyard's own library (`public.vineyard_materials`).
 *
 * Two shapes, enforced by the database's `vineyard_materials_custom_shape`
 * check and mirrored by [isCustom]:
 *
 *  * OVERRIDE of a base item — [baseMaterialId] set, `isCustom == false`.
 *    "Gripple / Wire Joiner-Tensioner · $1.82 Each".
 *  * CUSTOM vineyard material — [baseMaterialId] null, `isCustom == true`.
 *    "Gripple Plus Medium · $2.15 Each".
 *
 * [defaultUnitCostRaw] and [unit] are DEFAULTS applied when adding the material
 * to a task. Changing them later never rewrites a [WorkTaskMaterial].
 */
@Serializable
data class VineyardMaterial(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("base_material_id") val baseMaterialId: String? = null,
    /**
     * The base catalogue KEY this overrides, resolved locally so an override
     * still matches its base item when only the bundled catalogue is loaded.
     * Not a database column.
     */
    @SerialName("base_material_key") val baseMaterialKey: String? = null,
    val name: String = "",
    val category: String = "",
    val unit: String = "Each",
    @SerialName("default_unit_cost") val defaultUnitCostRaw: String? = null,
    @SerialName("is_custom") val isCustom: Boolean = false,
    @SerialName("is_active") val isActive: Boolean = true,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    /** The vineyard's default cost, or null when it has not set one. */
    val defaultUnitCost: BigDecimal? get() = MaterialMoney.decimalOrNull(defaultUnitCostRaw)
}

// ---------------------------------------------------------------------------
// C. Work Task material line
// ---------------------------------------------------------------------------

/**
 * One material line on a Work Task (`public.work_task_materials`).
 *
 * ## The historical rule
 *
 * [materialName], [category], [unit], [quantityRaw] and [unitCostRaw] are a
 * SNAPSHOT owned by the task from the moment the material was added.
 * [baseMaterialId] / [vineyardMaterialId] are provenance only — both may become
 * null (the database sets them null on delete) and the line still reads
 * correctly from its own snapshot.
 *
 * ```text
 * Today:      Trellis Post · 3 Each · $12.40  =  $37.20
 * Library repriced to $14.50 next season
 * Still:      Trellis Post · 3 Each · $12.40  =  $37.20
 * ```
 */
@Serializable
data class WorkTaskMaterial(
    val id: String,
    @SerialName("work_task_id") val workTaskId: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("base_material_id") val baseMaterialId: String? = null,
    @SerialName("vineyard_material_id") val vineyardMaterialId: String? = null,
    @SerialName("material_name") val materialName: String = "",
    val category: String = "",
    val unit: String = "Each",
    @SerialName("quantity") val quantityRaw: String = "0",
    @SerialName("unit_cost") val unitCostRaw: String = "0",
    /** GENERATED column — read back for verification, never written. */
    @SerialName("total_cost") val totalCostRaw: String? = null,
    val notes: String = "",
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    val quantity: BigDecimal get() = MaterialMoney.decimal(quantityRaw)
    val unitCost: BigDecimal get() = MaterialMoney.decimal(unitCostRaw)

    /**
     * The line cost. Prefers the server's generated total when present and
     * otherwise computes the identical `quantity × unitCost` locally, so an
     * offline-created line costs correctly before it has ever synced.
     */
    val totalCost: BigDecimal
        get() = MaterialMoney.decimalOrNull(totalCostRaw) ?: MaterialMoney.lineTotal(quantity, unitCost)
}

// ---------------------------------------------------------------------------
// Library merge (catalogue + vineyard)
// ---------------------------------------------------------------------------

/**
 * One selectable entry in a vineyard's effective library: a base catalogue
 * item, a base item the vineyard has priced, or a vineyard-only custom
 * material.
 */
data class MaterialLibraryEntry(
    /** `material.<...>` for a base item, or the vineyard material id for a custom one. */
    val id: String,
    val name: String,
    val category: String,
    val unit: String,
    val defaultUnitCost: BigDecimal?,
    val baseMaterialKey: String?,
    val baseMaterialId: String?,
    val vineyardMaterialId: String?,
    val isCustom: Boolean,
    val sortOrder: Int,
) {
    /**
     * Seed a task line from this entry. The entry's unit and default cost
     * become the line's OWN snapshot from here on; editing the line later never
     * touches the library item.
     */
    fun toTaskMaterial(
        id: String,
        workTaskId: String,
        vineyardId: String,
        quantity: BigDecimal,
        unitCost: BigDecimal? = null,
        unit: String? = null,
        notes: String = "",
    ): WorkTaskMaterial = WorkTaskMaterial(
        id = id,
        workTaskId = workTaskId,
        vineyardId = vineyardId,
        baseMaterialId = baseMaterialId,
        vineyardMaterialId = vineyardMaterialId,
        materialName = name,
        category = category,
        unit = MaterialUnitCatalog.normalised(unit ?: this.unit),
        quantityRaw = MaterialMoney.wire(quantity),
        unitCostRaw = MaterialMoney.wire(unitCost ?: defaultUnitCost ?: BigDecimal.ZERO),
        notes = notes,
    )
}

object MaterialLibrary {

    /**
     * Merge the base catalogue with a vineyard's overrides and custom items AT
     * READ TIME.
     *
     * This is why no vineyard is pre-populated with eighteen empty rows: a
     * vineyard row only exists once someone sets a price or adds a custom
     * material. An override replaces its base entry in place (keeping the base
     * sort order); custom materials follow, ordered by category then name.
     * Inactive entries are excluded from SELECTION only — nothing here touches
     * historical task lines.
     */
    fun merged(
        catalogue: List<MaterialCatalogueItem>,
        vineyardMaterials: List<VineyardMaterial>,
        vineyardId: String,
    ): List<MaterialLibraryEntry> {
        val scoped = vineyardMaterials.filter {
            it.vineyardId == vineyardId && it.isActive && it.deletedAt == null
        }
        val overridesByKey = scoped.filterNot { it.isCustom }
            .mapNotNull { m -> m.baseMaterialKey?.let { it to m } }
            .toMap()
        val overridesById = scoped.filterNot { it.isCustom }
            .mapNotNull { m -> m.baseMaterialId?.let { it to m } }
            .toMap()

        val entries = mutableListOf<MaterialLibraryEntry>()

        catalogue.filter { it.isActive }.sortedBy { it.sortOrder }.forEach { item ->
            val match = overridesByKey[item.key] ?: item.remoteId?.let { overridesById[it] }
            entries += MaterialLibraryEntry(
                id = item.key,
                name = match?.name?.takeIf { it.isNotBlank() } ?: item.name,
                category = item.category,
                unit = match?.unit ?: item.defaultUnit,
                defaultUnitCost = match?.defaultUnitCost,
                baseMaterialKey = item.key,
                baseMaterialId = match?.baseMaterialId ?: item.remoteId,
                vineyardMaterialId = match?.id,
                isCustom = false,
                sortOrder = item.sortOrder,
            )
        }

        scoped.filter { it.isCustom }
            .sortedWith(
                compareBy<VineyardMaterial> { MaterialCategoryCatalog.order(it.category) }
                    .thenBy { it.name.lowercase() },
            )
            .forEachIndexed { index, custom ->
                entries += MaterialLibraryEntry(
                    id = custom.id,
                    name = custom.name,
                    category = custom.category.ifBlank { MaterialCategoryCatalog.OTHER },
                    unit = custom.unit,
                    defaultUnitCost = custom.defaultUnitCost,
                    baseMaterialKey = null,
                    baseMaterialId = null,
                    vineyardMaterialId = custom.id,
                    isCustom = true,
                    sortOrder = 1_000 + index,
                )
            }

        return entries
    }
}

// ---------------------------------------------------------------------------
// Costing
// ---------------------------------------------------------------------------

/**
 * Material cost roll-ups. Structured so later reporting (per task, per block,
 * per vineyard, per hectare, per category, per season) needs no schema change —
 * but NO report is built in this phase.
 */
object WorkTaskMaterialCosting {

    /** Active material lines of ONE task, in stable display order. */
    fun lines(all: List<WorkTaskMaterial>, workTaskId: String): List<WorkTaskMaterial> =
        all.filter { it.workTaskId == workTaskId && it.deletedAt == null }
            .sortedWith(
                compareBy<WorkTaskMaterial> { MaterialCategoryCatalog.order(it.category) }
                    .thenBy { it.materialName.lowercase() },
            )

    /**
     * Total material cost of one task.
     *
     * A task with no material lines costs `0` — it does NOT need a row to say
     * so, which is exactly why Material Costs is additive and optional.
     */
    fun total(all: List<WorkTaskMaterial>, workTaskId: String): BigDecimal =
        total(all.filter { it.workTaskId == workTaskId && it.deletedAt == null })

    /** Total across any supplied set of lines — the caller decides the scope. */
    fun total(lines: List<WorkTaskMaterial>): BigDecimal =
        lines.fold(BigDecimal.ZERO) { acc, line -> acc.add(line.totalCost) }
            .setScale(2, RoundingMode.HALF_UP)

    /**
     * Material cost grouped by the FROZEN category on each line, so a later
     * category rename can never retro-reclassify historical spend.
     */
    fun totalByCategory(lines: List<WorkTaskMaterial>): Map<String, BigDecimal> {
        val totals = linkedMapOf<String, BigDecimal>()
        lines.forEach { line ->
            val key = line.category.ifBlank { MaterialCategoryCatalog.OTHER }
            totals[key] = (totals[key] ?: BigDecimal.ZERO).add(line.totalCost)
        }
        return totals.mapValues { it.value.setScale(2, RoundingMode.HALF_UP) }
    }
}
