package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.SprayJobTemplateRepository
import com.rork.vinetrack.data.SprayRecordRepository
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.model.chemicalUnitToBase
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.util.UUID

/**
 * Why a Program Step could not be saved — pinned so both the repository and
 * the editor surface the SAME words iOS uses.
 */
object SprayProgramStepWriteMessages {
    /** The statement reached the database but changed no row. Under RLS that is
     * indistinguishable from "row not found", and both mean this save did not land. */
    const val NOT_PERMITTED: String =
        "You don't have permission to change this Program Step, or it's no longer in the program."

    /** A portal Program Step edited with no connectivity. There is no offline
     * mutation queue for `spray_jobs`, so the save is blocked rather than faked. */
    const val OFFLINE: String = "Connect to update this Program Step."

    const val NO_VINEYARD: String = "Select a vineyard before editing the spray program."
}

/** Thrown when a `spray_jobs` update affects no rows. */
class SprayProgramStepNotPermitted : Exception(SprayProgramStepWriteMessages.NOT_PERMITTED)

/**
 * Who may edit a Program Step — the DATABASE's rule, restated on the client so
 * the UI does not offer a button the write will reject. Mirrors iOS
 * `SprayProgramStepPermissions` and the `spray_jobs_update_managers` policy
 * (sql/032): portal-backed step -> owner/manager; local step -> whatever could
 * already edit it. Nothing here widens access — RLS remains the enforcement
 * point.
 */
object SprayProgramStepPermissions {
    fun canEdit(
        isPortalManaged: Boolean,
        canManageSprayProgram: Boolean,
        canEditRecords: Boolean,
    ): Boolean = if (isPortalManaged) canManageSprayProgram else canEditRecords

    /** Delete stays exactly where it was: local steps only. Mobile deletion of
     * a shared portal row needs its own decisions about downstream references
     * and soft-delete, and this change does not make them. */
    fun canDelete(isPortalManaged: Boolean, canDeleteRecords: Boolean): Boolean =
        !isPortalManaged && canDeleteRecords
}

/**
 * One editable product line on a Program Step.
 *
 * A Program Step's product line is a POINTER — "apply this Saved Chemical" —
 * not a record of what was applied. Identity fields are editable; frozen
 * chemistry is not: [rawLine] carries the original portal wire object (incl.
 * `chemical_snapshot`) verbatim while the line still points at the same
 * product, and is DROPPED the moment the product is replaced — a snapshot
 * describes a specific product, and no new snapshot is captured because a
 * Program Step reads today's Chemical Store by design.
 */
data class SprayProgramProductDraft(
    /** Stable UI identity for Compose lists. */
    val lineKey: String = UUID.randomUUID().toString(),
    val savedChemicalId: String? = null,
    val name: String = "",
    val activeIngredient: String? = null,
    /** The rate in [unitRaw], as the operator reads and types it. */
    val rate: Double = 0.0,
    val unitRaw: String = "Litres",
    val basis: SprayProductRateBasis = SprayProductRateBasis.WHOLE_BLOCK_AREA,
    /** The portal's per-line carrier rate. Carried so a round trip cannot drop it. */
    val waterRate: Double? = null,
    val lineNotes: String? = null,
    /** Cost snapshot on the existing local line. Preserved, never edited here. */
    val costPerUnit: Double = 0.0,
    /** The tank this line came from on a local record, so a multi-tank local
     * recipe writes back into the tank it belongs to instead of collapsing. */
    val tankIndex: Int? = null,
    /** The original local `SprayChemical.id`, so an edit updates the same line. */
    val existingLineId: String? = null,
    /** Frozen chemistry on an existing LOCAL line, round-tripped verbatim. */
    val chemicalSnapshot: ChemicalLineSnapshot? = null,
    /** The original PORTAL wire line, for opaque round trip of every key this
     * draft does not model (`chemical_snapshot` above all). Null for new lines
     * and for lines whose product was replaced. */
    val rawLine: JsonObject? = null,
) {
    /** The rate in BASE units (mL or g) — the form both storage contracts use. */
    val baseRate: Double get() = chemicalUnitToBase(unitRaw, rate)

    val trimmedName: String get() = name.trim()

    /**
     * Point this line at a different Saved Chemical. Explicit replacement only
     * — never called from a name match. Deliberately NO seed rate: the dose
     * belongs to the spray, not the programme. The operator's number is
     * restated in the new product's unit so "2" does not silently change
     * meaning from 2 L to 2 kg.
     */
    fun replacedWith(chemical: SavedChemical): SprayProgramProductDraft {
        val previousBase = baseRate
        return copy(
            savedChemicalId = chemical.id,
            name = chemical.name,
            activeIngredient = chemical.activeIngredient.trim().ifEmpty { null },
            unitRaw = chemical.unit,
            rate = chemicalUnitFromBase(chemical.unit, previousBase),
            chemicalSnapshot = null,
            rawLine = null,
            costPerUnit = 0.0,
        )
    }

    /** Detach this line from its Saved Chemical, keeping the typed name. */
    fun cleared(typedName: String): SprayProgramProductDraft = copy(
        savedChemicalId = null,
        name = typedName,
        activeIngredient = null,
        chemicalSnapshot = null,
        rawLine = null,
    )

    /**
     * The local `tanks` JSONB representation. The rate goes into the field its
     * basis owns, and `rateBasis` is left null when there is no rate at all —
     * an honest "not stated" rather than a default that would report as 0/ha.
     */
    fun toSprayChemical(): SprayChemical {
        val base = baseRate
        val per100 = basis == SprayProductRateBasis.PER_100_LITRES
        return SprayChemical(
            id = existingLineId ?: UUID.randomUUID().toString(),
            name = trimmedName,
            volumePerTank = 0.0,
            ratePerHa = if (per100) 0.0 else base,
            ratePer100L = if (per100) base else 0.0,
            costPerUnit = costPerUnit,
            unit = unitRaw,
            rateBasis = if (base > 0) basis.raw else null,
            savedChemicalId = savedChemicalId,
            chemicalSnapshot = chemicalSnapshot,
        )
    }

    /** The portal `chemical_lines` element, in the shape the portal already writes. */
    fun toWireLine(): JsonObject = buildJsonObject {
        // Opaque round trip first: every key this draft does not model —
        // `chemical_snapshot` above all — survives verbatim. The keys the
        // draft owns are then written over the top.
        rawLine?.forEach { (key, value) -> put(key, value) }
        put("chemical_id", savedChemicalId?.let(::JsonPrimitive) ?: JsonNull)
        put("name", JsonPrimitive(trimmedName))
        put("active_ingredient", activeIngredient?.let(::JsonPrimitive) ?: JsonNull)
        put("rate", JsonPrimitive(rate))
        put(
            "unit",
            JsonPrimitive(
                SprayJobTemplateRepository.composeLineUnit(
                    unitRaw,
                    basis == SprayProductRateBasis.PER_100_LITRES,
                ),
            ),
        )
        put("water_rate", waterRate?.let(::JsonPrimitive) ?: JsonNull)
        put("notes", lineNotes?.trim()?.takeIf { it.isNotEmpty() }?.let(::JsonPrimitive) ?: JsonNull)
        if (rawLine?.containsKey("chemical_snapshot") != true) put("chemical_snapshot", JsonNull)
    }

    companion object {
        /** Parse one raw portal `chemical_lines` element into an editable draft. */
        fun fromWireLine(index: Int, element: JsonObject): SprayProgramProductDraft? {
            fun str(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
                (element[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
            }

            fun num(vararg keys: String): Double? = keys.firstNotNullOfOrNull { key ->
                (element[key] as? JsonPrimitive)?.let { it.doubleOrNull ?: it.contentOrNull?.toDoubleOrNull() }
            }

            val name = str("name", "product_name", "productName", "product", "chemical_name", "chemicalName")
                ?: return null
            val (unit, per100) = SprayJobTemplateRepository.parseLineUnit(str("unit", "rate_unit", "rateUnit"))
            return SprayProgramProductDraft(
                lineKey = "portal-line-$index",
                savedChemicalId = str("chemical_id", "chemicalId", "saved_chemical_id", "savedChemicalId"),
                name = name,
                activeIngredient = str("active_ingredient", "activeIngredient"),
                rate = num("rate", "rate_per_ha", "ratePerHa", "rate_value", "amount") ?: 0.0,
                unitRaw = unit,
                basis = if (per100) SprayProductRateBasis.PER_100_LITRES else SprayProductRateBasis.WHOLE_BLOCK_AREA,
                waterRate = num("water_rate", "waterRate"),
                lineNotes = str("notes"),
                rawLine = element,
            )
        }
    }
}

/**
 * The editable configuration of one Program Step — reusable configuration
 * ONLY. There is deliberately no date, weather, tanks applied, rows sprayed,
 * operator, cost or application geometry on this type: those describe an
 * application that happened, and a Program Step never happened. Mirrors the
 * iOS `SprayProgramStepDraft` exactly, including its two persistence targets:
 *
 *  * local  -> the existing `spray_records` template path ([toLocalInput])
 *  * portal -> the existing `public.spray_jobs` row, updated in place
 *    ([portalPayload])
 */
data class SprayProgramStepDraft(
    val stepId: String,
    val isPortalManaged: Boolean,
    val name: String = "",
    /** Canonical `growth_stage_code`, e.g. "EL12". Null is a legitimate answer. */
    val growthStageCode: String? = null,
    val targets: List<SprayTargetTag> = emptyList(),
    val operationType: String? = null,
    val equipmentId: String? = null,
    val tractorId: String? = null,
    val notes: String = "",
    val products: List<SprayProgramProductDraft> = emptyList(),
) {
    val trimmedName: String get() = name.trim()
    val trimmedNotes: String get() = notes.trim()

    /** The tags in stored order, de-duplicated. */
    val normalisedTargets: List<SprayTargetTag> get() = SprayTargetVocabulary.normalised(targets)

    /** The display line, also written to the legacy `target` column. */
    val targetDisplay: String? get() = SprayTargetVocabulary.displayString(targets)

    /** Add a tag, ignoring one this step already has (by identifier). */
    fun addingTarget(tag: SprayTargetTag): SprayProgramStepDraft =
        if (targets.any { it.identifier == tag.identifier }) this
        else copy(targets = SprayTargetVocabulary.normalised(targets + tag))

    /** Remove a tag from THIS step. Never touches the vineyard's library. */
    fun removingTarget(tag: SprayTargetTag): SprayProgramStepDraft =
        copy(targets = targets.filterNot { it.identifier == tag.identifier })

    /** The first reason this draft cannot be saved, or null. Mirrors iOS. */
    val validationError: String?
        get() {
            if (trimmedName.isEmpty()) return "Give the Program Step a name."
            if (products.any { it.trimmedName.isEmpty() }) return "Every product needs a name."
            if (products.any { it.rate < 0 }) return "A product rate cannot be negative."
            if (isPortalManaged) {
                // `spray_jobs.chemical_lines` unit strings can only express /ha
                // and /100 L. Rather than write "/ha" over a treated-area rate
                // and silently restate it, refuse.
                val odd = products.firstOrNull {
                    it.basis != SprayProductRateBasis.WHOLE_BLOCK_AREA &&
                        it.basis != SprayProductRateBasis.PER_100_LITRES
                }
                if (odd != null) {
                    return "${odd.trimmedName} uses ${odd.basis.label}, which the shared program " +
                        "can't store. Choose per hectare or per 100 L."
                }
            }
            return null
        }

    val isValid: Boolean get() = validationError == null

    // MARK: - Portal write

    /**
     * The partial update for the existing `spray_jobs` row.
     *
     * Deliberately a PARTIAL update with EXPLICIT nulls: every key below is a
     * column the step's own configuration owns; everything else on the row —
     * `id`, `vineyard_id`, `is_template`, `status`, `planned_date`,
     * `water_volume`, `spray_rate_per_ha`, `created_by`,
     * `resistance_plan_id` — is simply ABSENT, so a PATCH leaves it exactly
     * as the portal wrote it. Nullable columns encode as JSON null rather
     * than being omitted, because "the operator removed the tractor" must not
     * silently become "leave the tractor alone". `updated_at` is owned by the
     * `spray_jobs_set_updated_at` trigger (sql/032).
     */
    fun portalPayload(updatedById: String?): JsonObject = buildJsonObject {
        put("name", JsonPrimitive(trimmedName))
        put("chemical_lines", chemicalLines())
        put("operation_type", operationType?.let(::JsonPrimitive) ?: JsonNull)
        // Structured identifiers are the source of truth; the wording line is
        // written alongside as a compatibility projection for readers that
        // still consume it.
        put("targets", buildJsonArray { SprayTargetVocabulary.identifiers(targets).forEach { add(JsonPrimitive(it)) } })
        put("target", targetDisplay?.let(::JsonPrimitive) ?: JsonNull)
        put("notes", trimmedNotes.takeIf { it.isNotEmpty() }?.let(::JsonPrimitive) ?: JsonNull)
        put("growth_stage_code", growthStageCode?.let(::JsonPrimitive) ?: JsonNull)
        put("equipment_id", equipmentId?.let(::JsonPrimitive) ?: JsonNull)
        put("tractor_id", tractorId?.let(::JsonPrimitive) ?: JsonNull)
        // The signed-in user, for the row's audit column. Never `created_by`.
        put("updated_by", updatedById?.let(::JsonPrimitive) ?: JsonNull)
    }

    fun chemicalLines(): JsonArray = buildJsonArray {
        products.forEach { add(it.toWireLine()) }
    }

    // MARK: - Local write

    /**
     * Project this draft back onto the local `spray_records` template row as a
     * [SprayRecordRepository.SprayInput] for the EXISTING update path — every
     * operational field (date, trip, weather, machine, gear) survives
     * verbatim, and every line returns to the tank it came from so a
     * multi-tank local recipe is not silently collapsed into one.
     *
     * Targets ride the snapshot: typed cases AND this vineyard's own, so the
     * custom half persists into the same `spray_records.targets` array
     * instead of being dropped on save. Targets and nothing else — a reusable
     * step carries no geometry because it does not know where it is going.
     */
    fun toLocalInput(existing: SprayRecord): SprayRecordRepository.SprayInput {
        val typed = SprayTargetVocabulary.builtIns(targets)
        val custom = SprayTargetVocabulary.customs(targets).map { it.identifier }
        val snapshot = if (typed.isEmpty() && custom.isEmpty()) {
            null
        } else {
            SprayApplicationSnapshot(
                targets = typed.takeIf { it.isNotEmpty() },
                customTargets = custom.takeIf { it.isNotEmpty() },
            )
        }
        return SprayRecordRepository.SprayInput(
            date = existing.date ?: existing.startTime ?: existing.createdAt.orEmpty(),
            startTime = existing.startTime ?: existing.date ?: existing.createdAt.orEmpty(),
            temperature = existing.temperature,
            windSpeed = existing.windSpeed,
            windDirection = existing.windDirection,
            humidity = existing.humidity,
            sprayReference = trimmedName.ifEmpty { null },
            notes = trimmedNotes.ifEmpty { null },
            numberOfFansJets = existing.numberOfFansJets,
            averageSpeed = existing.averageSpeed,
            equipmentType = existing.equipmentType,
            tractor = existing.tractor,
            tractorGear = existing.tractorGear,
            machineId = existing.machineId,
            tractorId = tractorId,
            sprayEquipmentId = equipmentId,
            operationType = operationType,
            tripId = existing.tripId,
            isTemplate = true,
            tanks = rebuiltTanks(existing.tanks.orEmpty()),
            applicationGeometry = snapshot,
        )
    }

    /** Every line returns to the tank it came from; new lines join the first. */
    fun rebuiltTanks(existingTanks: List<SprayTank>): List<SprayTank> {
        val tanks = existingTanks.ifEmpty {
            listOf(SprayTank(id = UUID.randomUUID().toString(), tankNumber = 1))
        }
        val chemicalsByTank = MutableList(tanks.size) { mutableListOf<SprayChemical>() }
        for (product in products) {
            val index = product.tankIndex?.coerceIn(0, tanks.size - 1) ?: 0
            chemicalsByTank[index].add(product.toSprayChemical())
        }
        return tanks.mapIndexed { index, tank -> tank.copy(chemicals = chemicalsByTank[index]) }
    }

    companion object {
        /** Load a draft from a LOCAL Program Step (`spray_records`, `is_template`). */
        fun fromLocal(record: SprayRecord, labels: Map<String, String> = emptyMap()): SprayProgramStepDraft {
            val products = mutableListOf<SprayProgramProductDraft>()
            record.tanks.orEmpty().forEachIndexed { tankIndex, tank ->
                tank.chemicals.forEach { chemical ->
                    if (chemical.name.isBlank()) return@forEach
                    val basis = SprayProductRateBasis.entries.firstOrNull { it.raw == chemical.rateBasis }
                        ?: SprayProductRateBasis.WHOLE_BLOCK_AREA
                    val base = if (basis == SprayProductRateBasis.PER_100_LITRES) {
                        chemical.ratePer100L
                    } else {
                        chemical.ratePerHa
                    }
                    products.add(
                        SprayProgramProductDraft(
                            lineKey = chemical.id,
                            savedChemicalId = chemical.savedChemicalId,
                            name = chemical.name,
                            activeIngredient = null,
                            rate = chemicalUnitFromBase(chemical.unit, base),
                            unitRaw = chemical.unit,
                            basis = basis,
                            costPerUnit = chemical.costPerUnit,
                            tankIndex = tankIndex,
                            existingLineId = chemical.id,
                            chemicalSnapshot = chemical.chemicalSnapshot,
                        ),
                    )
                }
            }
            return SprayProgramStepDraft(
                stepId = record.id,
                isPortalManaged = false,
                name = record.sprayReference.orEmpty(),
                growthStageCode = record.templateGrowthStageCode,
                targets = SprayTargetVocabulary.tags(
                    identifiers = record.targets.orEmpty(),
                    wording = null,
                    labels = labels,
                ),
                operationType = record.operationType,
                equipmentId = record.sprayEquipmentId,
                tractorId = record.tractorId,
                notes = record.notes.orEmpty(),
                products = products,
            )
        }

        /**
         * Load a draft from the PORTAL row as the server currently holds it —
         * raw `chemical_lines` included, so every key the draft does not model
         * survives the round trip verbatim.
         */
        fun fromPortalRow(
            row: SprayJobTemplateRepository.PortalProgramStepRow,
            labels: Map<String, String> = emptyMap(),
        ): SprayProgramStepDraft = SprayProgramStepDraft(
            stepId = row.id,
            isPortalManaged = true,
            name = row.name,
            growthStageCode = row.growthStageCode,
            targets = SprayTargetVocabulary.tags(
                identifiers = row.targets.orEmpty(),
                wording = row.target,
                labels = labels,
            ),
            operationType = row.operationType,
            equipmentId = row.equipmentId,
            tractorId = row.tractorId,
            notes = row.notes.orEmpty(),
            products = row.chemicalLines.orEmpty().mapIndexedNotNull { index, element ->
                (element as? JsonObject)?.let { SprayProgramProductDraft.fromWireLine(index, it) }
            },
        )
    }
}
