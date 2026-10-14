package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayProgramLanding
import com.rork.vinetrack.data.spray.SprayProgramProductDraft
import com.rork.vinetrack.data.spray.SprayProgramStepDraft
import com.rork.vinetrack.data.spray.SprayProgramStepPermissions
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SprayProgramStepCreationTest {
    @Test fun blankDraftIsCanonicalAndIdentitySurvivesEdits() {
        val draft = SprayProgramStepDraft.newShared()
        assertTrue(draft.isPortalManaged)
        assertEquals("Foliar Spray", draft.operationType)
        assertEquals("", draft.name); assertEquals("", draft.notes)
        assertTrue(draft.products.isEmpty()); assertTrue(draft.targets.isEmpty())
        assertNull(draft.growthStageCode); assertNull(draft.equipmentId); assertNull(draft.tractorId); assertNull(draft.planningIntent)
        assertEquals(draft.stepId, draft.copy(name = "New name", notes = "Keep me").stepId)
    }

    @Test fun normalUserGetsExactlyThreeMethods() {
        assertEquals(listOf("Foliar Spray", "Banded Spray", "Spreader"), SprayProgramLanding.programMethods(false, true))
    }

    @Test fun adminAlsoGetsFertigationOnlyOnCanonicalProgram() {
        assertEquals(listOf("Foliar Spray", "Banded Spray", "Spreader", "Fertigation"), SprayProgramLanding.programMethods(true, true))
        assertFalse(SprayProgramLanding.programMethods(true, false).contains("Fertigation"))
        assertFalse(SprayProgramLanding.canPlanSpray("Fertigation"))
    }

    @Test fun adminNeverOverridesVineyardCreateRole() {
        for (admin in listOf(false, true)) {
            assertFalse(SprayProgramStepPermissions.canCreate(false, "Foliar Spray", admin))
            assertFalse(SprayProgramStepPermissions.canCreate(false, "Fertigation", admin))
            assertTrue(SprayProgramStepPermissions.canCreate(true, "Foliar Spray", admin))
            assertEquals(admin, SprayProgramStepPermissions.canCreate(true, "Fertigation", admin))
        }
    }

    @Test fun normalCreateIsSharedTemplateWithStableUUIDAndNoOperationalData() {
        for (method in listOf("Foliar Spray", "Banded Spray", "Spreader")) {
            val draft = SprayProgramStepDraft.newShared().copy(name = "Reusable", operationType = method, growthStageCode = "EL12", notes = "Unsent notes")
            val body = draft.createPayload("vineyard", "owner")
            assertEquals(draft.stepId, body["id"]!!.jsonPrimitive.content)
            assertEquals(JsonPrimitive(true), body["is_template"])
            assertEquals(JsonPrimitive("draft"), body["status"])
            assertEquals(JsonPrimitive("vineyard"), body["vineyard_id"])
            assertEquals(JsonPrimitive("owner"), body["created_by"])
            assertEquals(JsonPrimitive(method), body["operation_type"])
            listOf("trip_id", "tanks", "planned_date", "water_volume", "resistance_plan_id").forEach { assertFalse(body.containsKey(it)) }
            assertEquals(body, draft.createPayload("vineyard", "owner"))
        }
    }

    @Test fun fertigationCreatePreservesSavedChemicalRateAndOmitsSprayFields() {
        val chemical = UUID.randomUUID().toString()
        val product = SprayProgramProductDraft(savedChemicalId = chemical, name = "Saved nutrient", rate = 12.0, fertigationRateBasis = "per_vine", fertigationRateUnit = "mL/vine")
        val draft = SprayProgramStepDraft.newShared().copy(name = "Nutrients", operationType = "Fertigation", products = listOf(product), equipmentId = "must-not-leak", tractorId = "must-not-leak")
        val body = draft.createPayload("vineyard", "owner")
        SprayProgramStepDraft.SPRAY_ONLY_CREATE_KEYS.forEach { assertFalse("Unexpected spray field $it", body.containsKey(it)) }
        val line = body["chemical_lines"]!!.jsonArray.single().jsonObject
        assertEquals(JsonPrimitive(chemical), line["chemical_id"])
        assertEquals(JsonPrimitive(12.0), line["rate"])
        assertEquals(JsonPrimitive("per_vine"), line["fertigation_rate_basis"])
        assertEquals(JsonPrimitive("mL/vine"), line["fertigation_rate_unit"])
        listOf("unit", "water_rate", "rate_basis").forEach { assertFalse(line.containsKey(it)) }
    }

    @Test fun chemicalCreationReturnPreservesUnsavedDraftWithoutInferring100L() {
        val line = SprayProgramProductDraft(name = "Pending choice")
        val draft = SprayProgramStepDraft.newShared().copy(name = "Unsaved", growthStageCode = "EL12", operationType = "Fertigation", notes = "Keep these", products = listOf(line))
        val chemical = SavedChemical(UUID.randomUUID().toString(), UUID.randomUUID().toString(), name = "Created nutrient", unit = "Litres")
        val returned = draft.copy(products = draft.products.map { if (it.lineKey == line.lineKey) it.replacedFertigationWith(chemical) else it })
        assertEquals(draft.stepId, returned.stepId); assertEquals(draft.name, returned.name); assertEquals(draft.notes, returned.notes)
        assertEquals(draft.growthStageCode, returned.growthStageCode); assertEquals(draft.operationType, returned.operationType)
        assertEquals(line.lineKey, returned.products[0].lineKey); assertEquals(chemical.id, returned.products[0].savedChemicalId)
        assertEquals(0.0, returned.products[0].rate, 0.0)
        assertNull(returned.products[0].fertigationRateBasis); assertNull(returned.products[0].fertigationRateUnit)
    }

    @Test fun overlappingRefreshRetainsAcknowledgedSharedRow() {
        val saved = com.rork.vinetrack.data.model.SprayRecord(id = UUID.randomUUID().toString(), vineyardId = UUID.randomUUID().toString(), isTemplate = true, operationType = "Fertigation")
        assertEquals(listOf(saved), SprayProgramLanding.refreshedTemplates(emptyList(), listOf(saved), 0L, 1L))
        assertEquals(listOf(saved), SprayProgramLanding.refreshedTemplates(listOf(saved), emptyList(), 1L, 1L))
        assertTrue(SprayProgramLanding.refreshedTemplates(emptyList(), listOf(saved), 1L, 1L).isEmpty())
    }

    @Test fun createCannotUseLocalFertigationOrGuessMissingBasis() {
        assertNotNull(SprayProgramStepDraft("id", false, name = "Local", operationType = "Fertigation").validationError)
        val draft = SprayProgramStepDraft.newShared().copy(name = "Missing basis", operationType = "Fertigation", products = listOf(SprayProgramProductDraft(savedChemicalId = UUID.randomUUID().toString(), name = "Saved", rate = 10.0)))
        assertNotNull(draft.validationError)
        try { draft.createPayload("vineyard", "owner"); fail("Must refuse missing Fertigation basis") } catch (_: IllegalArgumentException) { }
    }
}
