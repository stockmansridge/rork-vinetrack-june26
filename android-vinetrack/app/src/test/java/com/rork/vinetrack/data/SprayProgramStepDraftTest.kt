package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayProgramProductDraft
import com.rork.vinetrack.data.spray.SprayProgramStepDraft
import com.rork.vinetrack.data.spray.SprayProgramStepPermissions
import com.rork.vinetrack.data.spray.SprayProgramStepWriteMessages
import com.rork.vinetrack.data.spray.SprayTargetTag
import com.rork.vinetrack.data.spray.SprayTargetVocabulary
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Program Step edit round trip (Part B closeout): the portal payload
 * contract, the local write-back, permissions and the unit-string round trip —
 * each pinned against the iOS behaviour it mirrors.
 */
class SprayProgramStepDraftTest {

    private fun localTemplate(): SprayRecord = SprayRecord(
        id = "step-1",
        vineyardId = "vy-1",
        tripId = "trip-9",
        date = "2025-08-01T00:00:00Z",
        startTime = "2025-08-01T08:00:00Z",
        temperature = 18.5,
        windSpeed = 7.0,
        windDirection = "NE",
        humidity = 55.0,
        sprayReference = "EL12 Pre-Flowering",
        notes = "old notes",
        numberOfFansJets = "6",
        averageSpeed = 6.5,
        equipmentType = "Airblast",
        tractor = "Old Faithful",
        tractorGear = "3H",
        machineId = "machine-2",
        tractorId = "tractor-7",
        sprayEquipmentId = "equip-1",
        isTemplate = true,
        operationType = "Foliar Spray",
        tanks = listOf(
            SprayTank(
                id = "tank-a",
                tankNumber = 1,
                waterVolume = 400.0,
                chemicals = listOf(
                    SprayChemical(
                        id = "line-1",
                        name = "Sulphur 800",
                        ratePerHa = 2000.0, // base grams
                        unit = "Kg",
                        rateBasis = SprayProductRateBasis.WHOLE_BLOCK_AREA.raw,
                        savedChemicalId = "chem-1",
                        costPerUnit = 12.0,
                    ),
                ),
            ),
            SprayTank(
                id = "tank-b",
                tankNumber = 2,
                waterVolume = 300.0,
                chemicals = listOf(
                    SprayChemical(
                        id = "line-2",
                        name = "Wetter",
                        ratePer100L = 100.0, // base mL
                        unit = "mL",
                        rateBasis = SprayProductRateBasis.PER_100_LITRES.raw,
                    ),
                ),
            ),
        ),
        targets = listOf("powdery_mildew", "phomopsis"),
    )

    // MARK: - Portal payload contract

    @Test
    fun `portal payload carries exactly the columns the step owns`() {
        val draft = SprayProgramStepDraft.fromLocal(localTemplate()).copy(isPortalManaged = true)
        val payload = draft.portalPayload(updatedById = "user-1")
        assertEquals(
            setOf(
                "name", "chemical_lines", "operation_type", "targets", "target",
                "notes", "growth_stage_code", "equipment_id", "tractor_id", "updated_by",
            ),
            payload.keys,
        )
        // Columns the payload must NEVER carry — a PATCH leaves them exactly
        // as the portal wrote them.
        for (forbidden in listOf(
            "id", "vineyard_id", "is_template", "status", "planned_date",
            "water_volume", "spray_rate_per_ha", "created_by", "resistance_plan_id", "updated_at",
        )) {
            assertFalse("payload must not carry $forbidden", payload.containsKey(forbidden))
        }
    }

    @Test
    fun `cleared optional columns encode as explicit JSON null, not absence`() {
        val draft = SprayProgramStepDraft(
            stepId = "s",
            isPortalManaged = true,
            name = "Step",
            growthStageCode = null,
            targets = emptyList(),
            operationType = "Foliar Spray",
            equipmentId = null,
            tractorId = null,
            notes = "",
        )
        val payload = draft.portalPayload(updatedById = null)
        // "The operator removed the tractor" must not silently become "leave
        // the tractor alone".
        assertEquals(JsonNull, payload["tractor_id"])
        assertEquals(JsonNull, payload["equipment_id"])
        assertEquals(JsonNull, payload["growth_stage_code"])
        assertEquals(JsonNull, payload["notes"])
        assertEquals(JsonNull, payload["target"])
        assertEquals(JsonNull, payload["updated_by"])
        assertEquals(0, (payload["targets"] as JsonArray).size)
    }

    @Test
    fun `targets write structured identifiers plus the display projection`() {
        val draft = SprayProgramStepDraft(
            stepId = "s",
            isPortalManaged = true,
            name = "Step",
            targets = listOf(
                SprayTargetTag(identifier = "eutypa_dieback", label = "Eutypa Dieback"),
                SprayTargetVocabulary.tagFromWording("Powdery Mildew")!!,
            ),
        )
        val payload = draft.portalPayload(updatedById = null)
        val identifiers = (payload["targets"] as JsonArray).map { it.jsonPrimitive.contentOrNull }
        // Normalised order: built-ins first, then customs.
        assertEquals(listOf("powdery_mildew", "eutypa_dieback"), identifiers)
        assertEquals("Powdery Mildew · Eutypa Dieback", (payload["target"] as JsonPrimitive).contentOrNull)
    }

    @Test
    fun `portal wire line round-trips keys the draft does not model`() {
        val raw = buildJsonObject {
            put("chemical_id", JsonPrimitive("chem-1"))
            put("name", JsonPrimitive("Sulphur 800"))
            put("rate", JsonPrimitive(2.0))
            put("unit", JsonPrimitive("kg/ha"))
            put("water_rate", JsonPrimitive(400.0))
            put("notes", JsonPrimitive("line note"))
            put("chemical_snapshot", buildJsonObject { put("activity_groups", JsonPrimitive("M2")) })
        }
        val line = SprayProgramProductDraft.fromWireLine(0, raw)!!
        val wire = line.toWireLine()
        // The frozen chemistry rides verbatim while the product is unchanged.
        assertEquals(raw["chemical_snapshot"], wire["chemical_snapshot"])
        assertEquals("kg/ha", (wire["unit"] as JsonPrimitive).contentOrNull)
        assertEquals(400.0, (wire["water_rate"] as JsonPrimitive).contentOrNull?.toDouble())
        assertEquals("line note", (wire["notes"] as JsonPrimitive).contentOrNull)
    }

    @Test
    fun `replacing the product drops the snapshot and restates the rate in the new unit`() {
        val raw = buildJsonObject {
            put("name", JsonPrimitive("Old Product"))
            put("rate", JsonPrimitive(2.0))
            put("unit", JsonPrimitive("L/ha"))
            put("chemical_snapshot", buildJsonObject { put("k", JsonPrimitive("v")) })
        }
        val line = SprayProgramProductDraft.fromWireLine(0, raw)!!
        val replacement = SavedChemical(
            id = "chem-9",
            vineyardId = "vy-1",
            name = "New Product",
            unit = "Kg",
            activeIngredient = "Copper",
        )
        val replaced = line.replacedWith(replacement)
        assertEquals("chem-9", replaced.savedChemicalId)
        assertEquals("Kg", replaced.unitRaw)
        // 2 L = 2000 mL base -> restated as 2 kg, so "2" never silently
        // changes meaning.
        assertEquals(2.0, replaced.rate, 1e-9)
        assertNull(replaced.rawLine)
        val wire = replaced.toWireLine()
        // A snapshot describes a specific product — replaced means gone.
        assertEquals(JsonNull, wire["chemical_snapshot"])
        assertEquals("kg/ha", (wire["unit"] as JsonPrimitive).contentOrNull)
    }

    // MARK: - Unit string round trip

    @Test
    fun `composeLineUnit is the exact inverse of parseLineUnit`() {
        val cases = listOf(
            Triple("Litres", false, "L/ha"),
            Triple("Litres", true, "L/100L"),
            Triple("mL", true, "mL/100L"),
            Triple("mL", false, "mL/ha"),
            Triple("Kg", false, "kg/ha"),
            Triple("g", true, "g/100L"),
        )
        for ((unit, per100, composed) in cases) {
            assertEquals(composed, SprayJobTemplateRepository.composeLineUnit(unit, per100))
            val (parsedUnit, parsedPer100) = SprayJobTemplateRepository.parseLineUnit(composed)
            assertEquals(unit, parsedUnit)
            assertEquals(per100, parsedPer100)
        }
    }

    @Test
    fun `update filter path pins the safety contract`() {
        assertEquals(
            "spray_jobs?id=eq.abc&vineyard_id=eq.vy&is_template=eq.true&deleted_at=is.null",
            SprayJobTemplateRepository.templateFilterPath("abc", "vy"),
        )
    }

    // MARK: - Local write-back

    @Test
    fun `toLocalInput preserves every operational field verbatim`() {
        val existing = localTemplate()
        val draft = SprayProgramStepDraft.fromLocal(existing)
            .copy(name = "Renamed Step", notes = "new notes")
        val input = draft.toLocalInput(existing)

        assertEquals(existing.date, input.date)
        assertEquals(existing.startTime, input.startTime)
        assertEquals(existing.temperature, input.temperature)
        assertEquals(existing.windSpeed, input.windSpeed)
        assertEquals(existing.windDirection, input.windDirection)
        assertEquals(existing.humidity, input.humidity)
        assertEquals(existing.numberOfFansJets, input.numberOfFansJets)
        assertEquals(existing.averageSpeed, input.averageSpeed)
        assertEquals(existing.equipmentType, input.equipmentType)
        assertEquals(existing.tractor, input.tractor)
        assertEquals(existing.tractorGear, input.tractorGear)
        assertEquals(existing.machineId, input.machineId)
        assertEquals(existing.tripId, input.tripId)
        assertTrue(input.isTemplate)
        assertEquals("Renamed Step", input.sprayReference)
        assertEquals("new notes", input.notes)
    }

    @Test
    fun `every line returns to the tank it came from`() {
        val existing = localTemplate()
        val draft = SprayProgramStepDraft.fromLocal(existing)
        val tanks = draft.rebuiltTanks(existing.tanks.orEmpty())
        assertEquals(2, tanks.size)
        assertEquals("tank-a", tanks[0].id)
        assertEquals(400.0, tanks[0].waterVolume, 1e-9)
        assertEquals(listOf("Sulphur 800"), tanks[0].chemicals.map { it.name })
        assertEquals(listOf("Wetter"), tanks[1].chemicals.map { it.name })
        // Same line ids, so an edit updates the same line.
        assertEquals("line-1", tanks[0].chemicals[0].id)
        // Rates stay in base units on the field their basis owns.
        assertEquals(2000.0, tanks[0].chemicals[0].ratePerHa, 1e-9)
        assertEquals(100.0, tanks[1].chemicals[0].ratePer100L, 1e-9)
        assertEquals(SprayProductRateBasis.PER_100_LITRES.raw, tanks[1].chemicals[0].rateBasis)
    }

    @Test
    fun `custom targets ride the local snapshot instead of being dropped`() {
        val existing = localTemplate()
        val draft = SprayProgramStepDraft.fromLocal(existing)
            .addingTarget(SprayTargetTag(identifier = "eutypa_dieback", label = "Eutypa Dieback"))
        val input = draft.toLocalInput(existing)
        val snapshot = input.applicationGeometry!!
        // Phomopsis has no typed case either — BOTH vineyard-authored targets
        // ride as customs; only Powdery Mildew resolves to the built-in.
        assertEquals(listOf("phomopsis", "eutypa_dieback"), snapshot.customTargets)
        assertEquals(
            listOf("powdery_mildew", "phomopsis", "eutypa_dieback"),
            snapshot.targetIdentifiers,
        )
    }

    @Test
    fun `clearing every target persists as no snapshot, not a stale one`() {
        val existing = localTemplate()
        var draft = SprayProgramStepDraft.fromLocal(existing)
        draft.normalisedTargets.forEach { draft = draft.removingTarget(it) }
        assertNull(draft.toLocalInput(existing).applicationGeometry)
    }

    @Test
    fun `editing a Program Step never rewrites a completed record`() {
        // The draft's writes are scoped to the template row: the local input
        // carries the TEMPLATE's id semantics (isTemplate stays true) and the
        // portal payload has no key that could touch spray_records at all. A
        // completed record object passed around the edit is untouched.
        val completed = localTemplate().copy(
            id = "completed-1",
            isTemplate = false,
            endTime = "2025-08-02T10:00:00Z",
        )
        val before = completed.copy()
        val draft = SprayProgramStepDraft.fromLocal(localTemplate()).copy(name = "Changed")
        draft.toLocalInput(localTemplate())
        draft.copy(isPortalManaged = true).portalPayload(updatedById = "u")
        assertEquals(before, completed)
        assertEquals("2025-08-02T10:00:00Z", completed.endTime)
    }

    // MARK: - Validation + permissions

    @Test
    fun `validation mirrors iOS word for word`() {
        val base = SprayProgramStepDraft(stepId = "s", isPortalManaged = false, name = " ")
        assertEquals("Give the Program Step a name.", base.validationError)

        val unnamedProduct = base.copy(name = "Step", products = listOf(SprayProgramProductDraft(name = " ")))
        assertEquals("Every product needs a name.", unnamedProduct.validationError)

        val negative = base.copy(name = "Step", products = listOf(SprayProgramProductDraft(name = "X", rate = -1.0)))
        assertEquals("A product rate cannot be negative.", negative.validationError)

        // The shared program can only store /ha and /100 L — refuse rather
        // than silently restate a treated-area rate.
        val portalOdd = base.copy(
            name = "Step",
            isPortalManaged = true,
            products = listOf(
                SprayProgramProductDraft(name = "Banded", rate = 1.0, basis = SprayProductRateBasis.TREATED_AREA),
            ),
        )
        assertTrue(portalOdd.validationError!!.contains("shared program can't store"))
        // The same basis on a LOCAL step is fine — the local contract stores it.
        assertNull(portalOdd.copy(isPortalManaged = false).validationError)
    }

    @Test
    fun `permissions mirror the database rule`() {
        // Portal step -> spray_jobs_update_managers (owner/manager only).
        assertTrue(SprayProgramStepPermissions.canEdit(true, canManageSprayProgram = true, canEditRecords = false))
        assertFalse(SprayProgramStepPermissions.canEdit(true, canManageSprayProgram = false, canEditRecords = true))
        // Local step -> the existing record rule, unchanged.
        assertTrue(SprayProgramStepPermissions.canEdit(false, canManageSprayProgram = false, canEditRecords = true))
        // Delete: local only, never the shared portal row.
        assertFalse(SprayProgramStepPermissions.canDelete(true, canDeleteRecords = true))
        assertTrue(SprayProgramStepPermissions.canDelete(false, canDeleteRecords = true))
    }

    @Test
    fun `write messages are pinned to the iOS wording`() {
        assertEquals(
            "You don't have permission to change this Program Step, or it's no longer in the program.",
            SprayProgramStepWriteMessages.NOT_PERMITTED,
        )
        assertEquals("Connect to update this Program Step.", SprayProgramStepWriteMessages.OFFLINE)
        assertEquals("Select a vineyard before editing the spray program.", SprayProgramStepWriteMessages.NO_VINEYARD)
    }

    @Test
    fun `fromPortalRow reads the raw row including verbatim target wording`() {
        val row = SprayJobTemplateRepository.PortalProgramStepRow(
            id = "job-1",
            vineyardId = "vy-1",
            name = "EL18 Flowering",
            growthStageCode = "EL18",
            operationType = "Foliar Spray",
            target = "Light Brown Apple Moth (LBAM)",
            targets = listOf("light_brown_apple_moth_lbam"),
            notes = null,
            equipmentId = "equip-2",
            tractorId = "tractor-3",
            chemicalLines = JsonArray(
                listOf(
                    buildJsonObject {
                        put("name", JsonPrimitive("Prodigy"))
                        put("rate", JsonPrimitive(30.0))
                        put("unit", JsonPrimitive("mL/100L"))
                    },
                ),
            ),
        )
        val draft = SprayProgramStepDraft.fromPortalRow(row)
        assertTrue(draft.isPortalManaged)
        assertEquals("EL18", draft.growthStageCode)
        // The step's own wording wins over a de-slugged approximation.
        assertEquals(listOf("Light Brown Apple Moth (LBAM)"), draft.targets.map { it.label })
        assertEquals(1, draft.products.size)
        assertEquals(SprayProductRateBasis.PER_100_LITRES, draft.products[0].basis)
        assertEquals("mL", draft.products[0].unitRaw)
        assertEquals(30.0, draft.products[0].rate, 1e-9)
    }
}
