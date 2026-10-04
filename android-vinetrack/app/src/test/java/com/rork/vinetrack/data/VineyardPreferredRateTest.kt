package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class VineyardPreferredRateTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true; explicitNulls = false }
    @Test fun manualAndNoGrapevineCatalogueKeepSeparatePreference() {
        for (catalogue in listOf(false, true)) {
            val chemical = SavedChemical(id = "id", vineyardId = "vineyard", name = "Custom", chemicalV3RevisionId = if (catalogue) "revision" else null, vineyardPreferredRate = VineyardPreferredRate(2.0, "L", "per_hectare"))
            val restored = json.decodeFromString(SavedChemical.serializer(), json.encodeToString(SavedChemical.serializer(), chemical))
            assertEquals(chemical, restored)
            assertNull(restored.defaultRates)
            assertTrue(restored.rates.isEmpty())
            assertEquals(2.0, OperationalRateResolver.resolve(restored)!!.rate.amount, 0.0)
        }
    }
    @Test fun registeredRangeRemainsDistinctAndUnchanged() {
        val use = ChemicalRegisteredUse(crop = "Grapes", targetRaw = "Powdery mildew", rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE, minValue = 1.0, maxValue = 2.0, unit = "L")))
        val chemical = SavedChemical(id = "id", vineyardId = "v", name = "Registered", registeredUses = listOf(use), vineyardPreferredRate = VineyardPreferredRate(1.5, "L", "per_hectare"))
        val product = SprayProgramProductDraft().replacedWith(chemical)
        assertEquals(1.5, product.rate, 0.0)
        assertEquals(listOf(use), chemical.registeredUses)
        assertNull(chemical.defaultRates)
        assertNull(OperationalRateResolver.warning(chemical.vineyardPreferredRate!!, chemical))
        assertNotNull(OperationalRateResolver.warning(VineyardPreferredRate(3.0, "L", "per_hectare"), chemical))
    }
    @Test fun programPrefillAndOverrideDoNotChangeChemical() {
        val chemical = SavedChemical(id = "id", vineyardId = "v", name = "Product", vineyardPreferredRate = VineyardPreferredRate(2.0, "L", "per_hectare"))
        val seeded = SprayProgramProductDraft().replacedWith(chemical)
        assertEquals(2.0, seeded.rate, 0.0)
        assertEquals(OperationalRateResolver.Source.VINEYARD_PREFERRED, seeded.rateSource)
        val edited = seeded.copy(rate = 1.5)
        assertEquals(2.0, chemical.vineyardPreferredRate!!.amount, 0.0)
        assertEquals(1.5, OperationalRateResolver.rateFromProgram(edited.toSprayChemical())!!.amount, 0.0)
    }
    @Test fun portalLineRoundTripPreservesAmountUnitAnd100LBasis() {
        val product = SprayProgramProductDraft(name = "Product", savedChemicalId = "id", rate = 150.0, unitRaw = "mL", basis = SprayProductRateBasis.PER_100_LITRES)
        val restored = SprayProgramProductDraft.fromWireLine(0, product.toWireLine())!!
        assertEquals(150.0, restored.rate, 0.0)
        assertEquals("mL", restored.unitRaw)
        assertEquals(SprayProductRateBasis.PER_100_LITRES, restored.basis)
        val local = json.decodeFromString(SprayChemical.serializer(), json.encodeToString(SprayChemical.serializer(), product.toSprayChemical()))
        assertEquals(VineyardPreferredRate(150.0, "mL", "per_100_litres"), OperationalRateResolver.rateFromProgram(local))
    }
    @Test fun priorityProgramThenVineyardThenExistingDefaultThenChoice() {
        val defaults = StoredChemicalDefaultRates(perHectare = StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_HECTARE, "L", value = 1.0))
        val chemical = SavedChemical(id = "id", vineyardId = "v", name = "Product", defaultRates = defaults, vineyardPreferredRate = VineyardPreferredRate(2.0, "L", "per_hectare"))
        val program = VineyardPreferredRate(1.5, "L", "per_hectare")
        assertEquals(OperationalRateResolver.Source.PROGRAM_STEP, OperationalRateResolver.resolve(chemical, program)!!.source)
        assertEquals(1.5, OperationalRateResolver.resolve(chemical, program)!!.rate.amount, 0.0)
        assertEquals(OperationalRateResolver.Source.VINEYARD_PREFERRED, OperationalRateResolver.resolve(chemical)!!.source)
        assertEquals(OperationalRateResolver.Source.CONFIRMED_DEFAULT, OperationalRateResolver.resolve(chemical.copy(vineyardPreferredRate = null))!!.source)
        assertNull(OperationalRateResolver.resolve(chemical.copy(vineyardPreferredRate = null, defaultRates = null)))
    }
    @Test fun missingProgramRateFallsBackAndReplacementDoesNotBorrowOldRate() {
        val chemical = SavedChemical(id = "id", vineyardId = "v", name = "Product", vineyardPreferredRate = VineyardPreferredRate(2.0, "L", "per_hectare"))
        assertEquals(OperationalRateResolver.Source.VINEYARD_PREFERRED, OperationalRateResolver.resolve(chemical, OperationalRateResolver.rateFromProgram(SprayProgramProductDraft(name = "Product").toSprayChemical()))!!.source)
        assertEquals(0.0, SprayProgramProductDraft(rate = 99.0).replacedWith(chemical.copy(vineyardPreferredRate = null)).rate, 0.0)
    }
    @Test fun basesAndMassVolumeAreNeverCrossCompared() {
        val use = ChemicalRegisteredUse(crop = "Grapes", targetRaw = "Mildew", rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 2.0, unit = "L")))
        val chemical = SavedChemical(id = "id", vineyardId = "v", name = "Product", registeredUses = listOf(use), vineyardPreferredRate = VineyardPreferredRate(150.0, "mL", "per_100_litres"))
        assertEquals("per_100_litres", OperationalRateResolver.resolve(chemical)!!.rate.basis)
        assertNull(OperationalRateResolver.warning(chemical.vineyardPreferredRate!!, chemical))
        assertNull(OperationalRateResolver.warning(VineyardPreferredRate(150.0, "g", "per_hectare"), chemical))
        assertNull(OperationalRateResolver.resolve(chemical.copy(vineyardPreferredRate = VineyardPreferredRate(Double.NaN, "L", "per_hectare"))))
    }
    @Test fun registeredScalarFallbackKeepsDisplayAndBaseUnitsDistinct() {
        val use = ChemicalRegisteredUse(crop = "Grapes", targetRaw = "Mildew", rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 2.0, unit = "L")))
        val chemical = SavedChemical(id = "id", vineyardId = "v", name = "Product", registeredUses = listOf(use))
        val product = SprayProgramProductDraft().replacedWith(chemical)
        assertEquals(2.0, product.rate, 0.0)
        assertEquals(2000.0, product.toSprayChemical().ratePerHa, 0.0)
        assertEquals(2.0, OperationalRateResolver.rateFromProgram(product.toSprayChemical())!!.amount, 0.0)
    }
    @Test fun vineyardOperationalDoseNeverClaimsRegisteredProvenance() {
        val defaults = StoredChemicalDefaultRates(perHectare = StoredChemicalDefaultRate(optionKey = "default_option_v1_dd81178fa70649ce9a097ad840805834", rateIds = listOf("rate_v1_chateau"), basis = "per_hectare", unit = "g", minValue = 560.0, maxValue = 700.0))
        val chemical = SavedChemical(id = "id", vineyardId = "v", name = "Product", defaultRates = defaults)
        val snapshot = SprayConfirmedRateSeeding.snapshotWithProvenance(base = null, chemical = chemical, basis = SprayProductRateBasis.WHOLE_BLOCK_AREA, appliedRate = 600.0, unit = "g", isOverride = false, capturedAt = "2026-10-04T00:00:00Z", isOperationalPreference = true)!!
        assertEquals("manual", snapshot.rateEntryMethod)
        assertNull(snapshot.rateRangeMin)
        assertNull(snapshot.selectedRateId)
        assertEquals(defaults, chemical.defaultRates)
    }
    @Test fun exactCatalogueWarningDoesNotClampOrCrossBasis() {
        val revision = CatalogueRow(Json.parseToJsonElement("""{"default_rate_options":{"per_hectare":[{"min_value":1,"max_value":2,"unit":"L"}]}}""").jsonObject)
        val rate = VineyardPreferredRate(2500.0, "mL", "per_hectare")
        assertNotNull(OperationalRateResolver.warning(rate, revision))
        assertEquals(2500.0, rate.amount, 0.0)
        assertNull(OperationalRateResolver.warning(VineyardPreferredRate(1500.0, "mL", "per_hectare"), revision))
        assertNull(OperationalRateResolver.warning(VineyardPreferredRate(2500.0, "g", "per_hectare"), revision))
        assertNull(OperationalRateResolver.warning(VineyardPreferredRate(2500.0, "mL", "per_100_litres"), revision))
    }
    @Test fun durablePreferenceClearRestartAndReplayUseSameChemicalId() = runBlocking {
        val writes = PendingWriteRepository(InMemoryPendingWriteStore())
        var cache: List<SavedChemical> = emptyList()
        val local = object : SavedChemicalLocalStoring {
            override fun load(userId: String, vineyardId: String) = cache
            override fun save(userId: String, vineyardId: String, rows: List<SavedChemical>): Boolean { cache = rows; return true }
        }
        var server = SavedChemical(id = "same-id", vineyardId = "v", name = "Manual")
        val repository = SavedChemicalRepository()
        val sync = SavedChemicalCreateSync(repository, writes, local, { "owner" }, findById = { server }, updatePreference = { row, rate, _ -> row.copy(vineyardPreferredRate = rate).also { server = it } })
        sync.savePreference(server, VineyardPreferredRate(2.0, "L", "per_hectare"))
        assertEquals(2.0, sync.rows("owner", "v").single().vineyardPreferredRate!!.amount, 0.0)
        sync.replayAll()
        assertTrue(writes.list().isEmpty())
        assertEquals("same-id", server.id)
        assertNull(server.defaultRates)
        sync.savePreference(server, null)
        val restarted = SavedChemicalCreateSync(repository, writes, local, { "owner" }, findById = { server }, updatePreference = { row, rate, _ -> row.copy(vineyardPreferredRate = rate).also { server = it } })
        assertNull(restarted.rows("owner", "v").single().vineyardPreferredRate)
        restarted.replayAll()
        assertTrue(writes.list().isEmpty())
        assertNull(server.vineyardPreferredRate)
    }
}
