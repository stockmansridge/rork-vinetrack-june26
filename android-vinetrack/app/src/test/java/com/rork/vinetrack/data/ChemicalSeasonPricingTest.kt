package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.*
import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.json.*

class ChemicalSeasonPricingTest {
    @Test fun legacyEditorPreservesOnlyUnchangedHistoricalLines() {
        val frozen = 0.0123456789
        assertEquals(frozen, SprayChemicalPricingPolicy.roundTripLegacyCost(frozen, false, true, true), 0.0)
        assertEquals(0.0, SprayChemicalPricingPolicy.roundTripLegacyCost(frozen, true, true, true), 0.0)
        assertEquals(0.0, SprayChemicalPricingPolicy.roundTripLegacyCost(frozen, false, false, true), 0.0)
        assertEquals(0.0, SprayChemicalPricingPolicy.roundTripLegacyCost(frozen, false, true, false), 0.0)
        val line = SprayChemical("line", "Product", costPerUnit = SprayChemicalPricingPolicy.roundTripLegacyCost(frozen, true, true, true))
        val json = SupabaseClient.json.encodeToJsonElement(line).jsonObject
        assertEquals(0.0, json.getValue("costPerUnit").jsonPrimitive.double, 0.0)
    }

    @Test fun tripCsvUsesSeasonalResultAndLabelsUnavailableAndLegacy() {
        val trip = Trip("trip", "vineyard")
        val line = SprayChemical("line", "Product", 1000.0, costPerUnit = 99.0, savedChemicalId = "chemical")
        val record = SprayRecord("spray", "vineyard", tripId = trip.id, tanks = listOf(SprayTank("tank", chemicals = listOf(line))))
        val batch = ChemicalSeasonPriceBatch("vineyard", 2027, listOf(ChemicalSeasonPrice("chemical", 2027, 0.006, "mL", "AUD", 2, 30000.0, 180.0, "season_weighted_purchase_average")))
        val csv = TripCsvExporter.buildCsv(trip, "Test", "", null, true, record, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), batch)
        val rows = csv.trim().lines().map { it.split(',') }
        val chemicalColumn = rows[0].indexOf("chemical_cost")
        assertEquals("6.00", rows[1][chemicalColumn])
        assertTrue(csv.contains("season_weighted_purchase_average"))
        assertFalse(csv.contains("99000.00"))
        val missing = record.copy(tanks = listOf(SprayTank("tank", chemicals = listOf(line.copy(costPerUnit = 0.0)))))
        val unavailable = TripCsvExporter.buildCsv(trip, "Test", "", null, true, missing, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), null)
        assertEquals("", unavailable.trim().lines()[1].split(',')[chemicalColumn])
        assertTrue(unavailable.contains("season_purchase_cost_unavailable"))
        val legacy = TripCsvExporter.buildCsv(trip, "Test", "", null, true, record, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), null)
        assertTrue(legacy.contains("legacy_stored_spray_snapshot"))
        val compliance = TripCsvExporter.buildCsv(trip, "Test", "", null, false, record, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), batch)
        assertFalse(compliance.contains("chemical_cost"))
    }

    @Test fun canonicalOverridesLegacyAndZeroIsAvailable() {
        val trip = Trip("trip", "vineyard")
        val line = SprayChemical("line", "Product", 1000.0, costPerUnit = 99.0, savedChemicalId = "chemical")
        val record = SprayRecord("spray", "vineyard", tripId = trip.id, tanks = listOf(SprayTank("tank", chemicals = listOf(line))))
        for (cpu in listOf(0.006, 0.0)) {
            val price = ChemicalSeasonPrice("chemical", 2027, cpu, "mL", "AUD", 2, 30000.0, cpu * 30000, "season_weighted_purchase_average")
            val result = TripCostEstimator.estimate(trip, record, emptyList(), emptyList(), emptyList(), chemicalPrices = ChemicalSeasonPriceBatch("vineyard", 2027, listOf(price)))
            assertEquals(cpu * 1000, result.chemical!!.cost, 0.0)
            assertNull(result.chemical.warning)
            assertEquals(listOf("season_weighted_purchase_average"), result.chemical.pricingBases)
        }
    }

    @Test fun completeActualUsesActualAndIncompleteUsesPlanned() {
        val trip = Trip("trip", "vineyard", tankSessions = listOf(TankSession("session")))
        val planned = SprayChemical("planned", "Product", 1000.0, savedChemicalId = "chemical")
        val record = SprayRecord("spray", "vineyard", tripId = trip.id, tanks = listOf(SprayTank("tank", chemicals = listOf(planned))))
        val usage = SprayTankActualChemical("usage", "planned", "chemical", "Product", 500.0, "Litres")
        val price = ChemicalSeasonPrice("chemical", 2027, 0.006, "mL", "AUD", 2, 30000.0, 180.0, "season_weighted_purchase_average")
        for (water in listOf(100.0, null)) {
            val actual = SprayTankActual("actual", "vineyard", "spray", "trip", "session", 1, water, listOf(usage), "2026-09-01T00:00:00Z", "user")
            val result = TripCostEstimator.estimate(trip, record, emptyList(), emptyList(), emptyList(), tankActuals = listOf(actual), chemicalPrices = ChemicalSeasonPriceBatch("vineyard", 2027, listOf(price)))
            assertEquals(if (water == null) 6.0 else 3.0, result.chemical!!.cost, 0.0)
            assertEquals(if (water == null) TripCostEstimator.ChemicalCostBasis.Estimated else TripCostEstimator.ChemicalCostBasis.Actual, result.chemical.basis)
        }
    }

    @Test fun substitutionAndAdditionalUseTheirOwnSavedChemicalPrices() {
        val trip = Trip("trip", "vineyard", tankSessions = listOf(TankSession("session")))
        val planned = SprayChemical("planned", "Original", 1000.0, costPerUnit = 99.0, savedChemicalId = "original")
        val record = SprayRecord("spray", "vineyard", tripId = trip.id, tanks = listOf(SprayTank("tank", chemicals = listOf(planned))))
        val sub = SprayTankActualChemical("sub", null, "substitute", "Replacement", 500.0, "Litres", "planned", "substitution")
        val extra = SprayTankActualChemical("extra", null, "addition", "Addition", 250.0, "Litres", usageKind = "additional")
        val actual = SprayTankActual("actual", "vineyard", "spray", "trip", "session", 1, 100.0, listOf(sub, extra), "2026-09-01T00:00:00Z", "user")
        val prices = listOf(ChemicalSeasonPrice("substitute", 2027, 0.01, "mL", "AUD", 1, 1000.0, 10.0, "season_weighted_purchase_average"), ChemicalSeasonPrice("addition", 2027, 0.02, "mL", "AUD", 1, 1000.0, 20.0, "season_weighted_purchase_average"))
        val result = TripCostEstimator.estimate(trip, record, emptyList(), emptyList(), emptyList(), tankActuals = listOf(actual), chemicalPrices = ChemicalSeasonPriceBatch("vineyard", 2027, prices))
        assertEquals(10.0, result.chemical!!.cost, 0.0)
        assertNull(result.chemical.warning)
        val unknown = actual.copy(chemicals = listOf(sub.copy(savedChemicalId = null, name = "Original")))
        val missing = TripCostEstimator.estimate(trip, record, emptyList(), emptyList(), emptyList(), tankActuals = listOf(unknown), chemicalPrices = ChemicalSeasonPriceBatch("vineyard", 2027, prices))
        assertEquals(0.0, missing.chemical!!.cost, 0.0)
        assertNotNull(missing.chemical.warning)
    }

    @Test fun legacySnapshotReadableButNewPricingNeverUsesEditorPurchase() {
        val saved = SavedChemical("chemical", "vineyard", name = "Old", purchase = ChemicalPurchase(costDollars = 100.0, containerSizeML = 1.0))
        assertNotNull(saved.purchase)
        assertNull(saved.costPerUnit)
        assertNull(ChemicalSprayDefaultHandoff.costPerRateUnit(saved, "L"))
        val trip = Trip("trip", "vineyard")
        val line = SprayChemical("line", "Old", 1000.0, costPerUnit = 0.02, savedChemicalId = "chemical")
        val decoded = SupabaseClient.json.decodeFromJsonElement<SprayChemical>(SupabaseClient.json.encodeToJsonElement(line))
        assertEquals(0.02, decoded.costPerUnit, 0.0)
        val record = SprayRecord("spray", "vineyard", tripId = trip.id, tanks = listOf(SprayTank("tank", chemicals = listOf(decoded))))
        val result = TripCostEstimator.estimate(trip, record, emptyList(), emptyList(), emptyList())
        assertEquals(20.0, result.chemical!!.cost, 0.0)
        assertEquals(listOf("legacy_stored_spray_snapshot"), result.chemical.pricingBases)
        val unpriced = record.copy(tanks = listOf(SprayTank("tank", chemicals = listOf(line.copy(costPerUnit = 0.0)))))
        assertNotNull(TripCostEstimator.estimate(trip, unpriced, emptyList(), emptyList(), emptyList()).chemical!!.warning)
    }

    @Test fun planningConvertsCanonicalBasePriceWithoutEditorDependency() {
        val saved = SavedChemical("chemical", "vineyard", unit = "Litres", purchase = ChemicalPurchase(costDollars = 999.0, containerSizeML = 1.0))
        val price = ChemicalSeasonPrice("chemical", 2027, 0.006, "mL", "AUD", 2, 30000.0, 180.0, "season_weighted_purchase_average")
        assertEquals(6.0, ChemicalSprayDefaultHandoff.costPerRateUnit(saved, "L", listOf(price))!!, 0.0)
        assertEquals(0.006, ChemicalSprayDefaultHandoff.costPerRateUnit(saved, "mL", listOf(price))!!, 0.0)
        assertNull(ChemicalSprayDefaultHandoff.costPerRateUnit(saved, "kg", listOf(price)))
    }

    @Test fun displayQuantityNormalizesOnlyForSeasonalPricing() {
        val trip = Trip("trip", "vineyard")
        val line = SprayChemical("line", "Product", 1.0, unit = "Litres", quantityBasis = "display", savedChemicalId = "chemical")
        val record = SprayRecord("spray", "vineyard", tripId = trip.id, tanks = listOf(SprayTank("tank", chemicals = listOf(line))))
        val price = ChemicalSeasonPrice("chemical", 2027, 0.006, "mL", "AUD", 2, 30000.0, 180.0, "season_weighted_purchase_average")
        val result = TripCostEstimator.estimate(trip, record, emptyList(), emptyList(), emptyList(), chemicalPrices = ChemicalSeasonPriceBatch("vineyard", 2027, listOf(price)))
        assertEquals(6.0, result.chemical!!.cost, 0.0)
        assertEquals(1.0, line.volumePerTank, 0.0)
    }

    @Test fun payloadOmitsLegacyPricingOnCreation() {
        val input = SavedChemicalRepository.ChemicalInput(name = "Old", unit = "Litres", ratePerHa = 1.0, rates = emptyList(), activeIngredient = null, chemicalGroup = null, use = null, problem = null, manufacturer = null, notes = null, modeOfAction = null, labelUrl = null, productUrl = null, purchase = ChemicalPurchase(costDollars = 100.0, containerSizeML = 1.0), packSize = 1.0, packUnit = "L", pricePerPack = 100.0)
        val body = SavedChemicalRepository().prepareCreate("vineyard", input, "chemical", "2026-09-01T00:00:00Z")
        val json = SupabaseClient.json.encodeToJsonElement(SavedChemicalRepository.ChemicalInsert.serializer(), body).jsonObject
        listOf("purchase", "pack_size", "pack_unit", "price_per_pack").forEach { assertFalse(it, json.containsKey(it)) }
        assertTrue(json.containsKey("product_form"))
        assertTrue(json.containsKey("inventory_unit"))
    }

    @Test fun currencyConflictNeverFallsBackToStoredSprayPrice() {
        val trip = Trip("trip", "vineyard")
        val line = SprayChemical("line", "Old", 1000.0, costPerUnit = 99.0, savedChemicalId = "chemical")
        val record = SprayRecord("spray", "vineyard", tripId = trip.id, tanks = listOf(SprayTank("tank", chemicals = listOf(line))))
        val price = ChemicalSeasonPrice("chemical", 2027, baseUnit = "mL", purchaseCount = 2, pricingBasis = "currency_conflict")
        val result = TripCostEstimator.estimate(trip, record, emptyList(), emptyList(), emptyList(), chemicalPrices = ChemicalSeasonPriceBatch("vineyard", 2027, listOf(price)))
        assertEquals(0.0, result.chemical!!.cost, 0.0)
        assertNotNull(result.chemical.warning)
        assertEquals(listOf("currency_conflict"), result.chemical.pricingBases)
    }
}
