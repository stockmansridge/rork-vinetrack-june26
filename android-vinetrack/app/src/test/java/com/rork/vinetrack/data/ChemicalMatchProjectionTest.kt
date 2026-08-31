package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateSelection
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.viticultural
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_HECTARE
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Match & Verify save projection (A4/A7/A8) — physical form, application
 * unit and the vineyard default rate, exactly as iOS persists them.
 *
 * The contract under test:
 * * `form_type` solid → Solid/kg, liquid → Liquid/L, unknown → UNSET.
 *   Unknown never becomes Liquid, and nothing infers form from `g/kg`,
 *   `g/L`, rate units or carrier volumes.
 * * The default-rate projection writes the legacy operational columns FROM
 *   the structured record — never the other way — and never alters the
 *   authoritative label rates.
 */
class ChemicalMatchProjectionTest {

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    private fun grapeUse(vararg rates: ChemicalLabelRate) = ChemicalRegisteredUse(
        crop = "Grapes (winegrapes)",
        targetRaw = "Powdery mildew",
        rates = rates.toList(),
    )

    private fun intel(
        uses: List<ChemicalRegisteredUse> = emptyList(),
        registration: ChemicalRegistration? = null,
    ) = ChemicalIntelligence(
        registration = registration,
        registeredUses = uses,
        productCategory = "fungicide",
    )

    // ---- A4: physical form and units ----

    @Test
    fun `an authoritative solid saves as solid with kilograms`() {
        val input = ChemicalStoreMatching.inputFor(
            null, "Thiovit Jet", intel(),
            formTypeRaw = "Water dispersible granule",
        )
        assertEquals("solid", input.productForm)
        assertEquals("Kg", input.unit)
    }

    @Test
    fun `an authoritative liquid saves as liquid with litres`() {
        val input = ChemicalStoreMatching.inputFor(
            null, "Custodia Forte", intel(),
            formTypeRaw = "Suspension concentrate",
        )
        assertEquals("liquid", input.productForm)
        assertEquals("Litres", input.unit)
    }

    @Test
    fun `an unknown form stays unknown and never becomes liquid`() {
        val input = ChemicalStoreMatching.inputFor(null, "Mystery Product", intel())
        assertEquals("", input.productForm)
        assertEquals("", input.unit)
    }

    @Test
    fun `a rate unit may establish the unit but never the form`() {
        // The label quotes g/100 L: the application unit is grams, but a rate
        // unit is NOT a formulation statement, so the form stays unknown.
        val input = ChemicalStoreMatching.inputFor(
            null, "Powder Product",
            intel(
                listOf(
                    grapeUse(
                        ChemicalLabelRate(
                            basis = ChemicalLabelRateBasis.PER_100_LITRES,
                            value = 200.0,
                            unit = "g",
                        ),
                    ),
                ),
            ),
        )
        assertEquals("g", input.unit)
        assertEquals("", input.productForm)
    }

    @Test
    fun `active concentration units never establish anything`() {
        // formDescription reads the formulation wording only. "750 g/kg" is
        // composition, not dose, and must not read as solid.
        assertEquals("", ChemicalStoreMatching.formDescription("750 g/kg"))
        assertEquals("solid", ChemicalStoreMatching.formDescription("Wettable Powder"))
        assertEquals("liquid", ChemicalStoreMatching.formDescription("Emulsifiable Concentrate"))
        assertEquals("liquid", ChemicalStoreMatching.formDescription("SOLUBLE CONCENTRATE"))
        assertEquals("", ChemicalStoreMatching.formDescription(null))
        assertEquals("", ChemicalStoreMatching.formDescription(""))
    }

    @Test
    fun `an existing record re-matched with an unknown form keeps its own unit and form`() {
        val existing = SavedChemical(
            id = "chem-1",
            vineyardId = "vineyard-1",
            name = "Old Solid",
            unit = "Kg",
            productForm = "solid",
        )
        val input = ChemicalStoreMatching.inputFor(existing, "Old Solid", intel())
        // Silence keeps what the record already said — the lookup's ignorance
        // must never overwrite the operator's statement.
        assertEquals("solid", input.productForm)
        assertEquals("Kg", input.unit)
    }

    // ---- A7: default-rate projection ----

    @Test
    fun `the chosen exact dose projects into the legacy operational columns`() {
        val range = ChemicalLabelRate(
            label = "NSW, Vic, SA",
            basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            minValue = 100.0,
            maxValue = 200.0,
            unit = "g",
        )
        val lookupIntel = intel(listOf(grapeUse(range)))
        val plan = ChemicalDefaultRate.plan(lookupIntel.registeredUses.viticultural())
        val defaults = ChemicalDefaultRateSelection(plan)
            .settingValue(150.0, ChemicalDefaultRateBasis.PER_100_LITRES)!!

        val input = ChemicalStoreMatching.inputFor(
            null, "Range Product", lookupIntel,
            formTypeRaw = "Wettable powder",
            defaults = defaults,
        )

        // Solid product dosing 150 g/100 L: one legacy row, base units (g).
        assertEquals("Kg", input.unit)
        val row = input.rates.single()
        assertEquals(CHEMICAL_RATE_PER_100L, row.basis)
        assertEquals(150.0, row.value, 1e-9)
        // The stored operational rate names the registered condition it came from.
        assertEquals("NSW, Vic, SA", row.label)
        // No per-ha rate was invented from a /100 L label.
        assertEquals(0.0, input.ratePerHa, 1e-9)
        // And the authoritative label range was never narrowed.
        val storedRange = input.intelligence!!.registeredUses.single().rates.single()
        assertEquals(100.0, storedRange.minValue)
        assertEquals(200.0, storedRange.maxValue)
        assertNull(storedRange.value)
    }

    @Test
    fun `an unnarrowed band projects nothing at all`() {
        // This REVERSES the earlier rule, which projected the band's BOTTOM.
        //
        // Defaulting to the low end looked conservative and was still a dose
        // decision made on the operator's behalf, written into the very legacy
        // columns an older client would spray from. `40-60 mL/100 L` states
        // what the label permits and says nothing about what this vineyard
        // pours, so nothing is projected until somebody says.
        val range = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            minValue = 40.0,
            maxValue = 60.0,
            unit = "mL",
        )
        val lookupIntel = intel(listOf(grapeUse(range)))
        val defaults = ChemicalDefaultRateSelection(
            ChemicalDefaultRate.plan(lookupIntel.registeredUses.viticultural()),
        )
        val input = ChemicalStoreMatching.inputFor(
            null, "Band Product", lookupIntel,
            formTypeRaw = "Suspension concentrate",
            defaults = defaults,
        )
        assertTrue(input.rates.isEmpty())
        assertEquals(0.0, input.ratePerHa, 1e-9)

        // Naming the dose is what produces the projection.
        val confirmed = defaults.settingValue(40.0, ChemicalDefaultRateBasis.PER_100_LITRES)!!
        val dosed = ChemicalStoreMatching.inputFor(
            null, "Band Product", lookupIntel,
            formTypeRaw = "Suspension concentrate",
            defaults = confirmed,
        )
        assertEquals(40.0, dosed.rates.single().value, 1e-9)
    }

    @Test
    fun `a per-hectare default projects the display scalar and base row`() {
        val perHa = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.PER_HECTARE,
            value = 2.0,
            unit = "L",
        )
        val lookupIntel = intel(listOf(grapeUse(perHa)))
        val plan = ChemicalDefaultRate.plan(lookupIntel.registeredUses.viticultural())
        // A recommendation is not consent, so the projection only happens once
        // the operator has actually confirmed the rate.
        val unconfirmed = ChemicalStoreMatching.inputFor(
            null, "Hectare Product", lookupIntel,
            formTypeRaw = "Suspension concentrate",
            defaults = ChemicalDefaultRateSelection(plan),
        )
        assertTrue(unconfirmed.rates.isEmpty())

        val defaults = ChemicalDefaultRateSelection(plan).selecting(
            plan.perHectare.options.first(),
            ChemicalDefaultRateBasis.PER_HECTARE,
        )
        val input = ChemicalStoreMatching.inputFor(
            null, "Hectare Product", lookupIntel,
            formTypeRaw = "Suspension concentrate",
            defaults = defaults,
        )
        val row = input.rates.single()
        assertEquals(CHEMICAL_RATE_PER_HECTARE, row.basis)
        // 2 L/ha -> 2000 mL base, 2.0 in the display-unit legacy scalar.
        assertEquals(2000.0, row.value, 1e-9)
        assertEquals(2.0, input.ratePerHa, 1e-9)
    }

    @Test
    fun `re-saving keeps the operational rate row id stable`() {
        val existingRow = ChemicalRate(
            id = "row-per-100l",
            label = "Old label",
            value = 120.0,
            basis = CHEMICAL_RATE_PER_100L,
        )
        val existing = SavedChemical(
            id = "chem-1",
            vineyardId = "vineyard-1",
            name = "Range Product",
            unit = "g",
            rates = listOf(existingRow),
        )
        val range = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            minValue = 100.0,
            maxValue = 200.0,
            unit = "g",
        )
        val lookupIntel = intel(listOf(grapeUse(range)))
        val defaults = ChemicalDefaultRateSelection(
            ChemicalDefaultRate.plan(lookupIntel.registeredUses.viticultural()),
        ).settingValue(100.0, ChemicalDefaultRateBasis.PER_100_LITRES)!!
        val input = ChemicalStoreMatching.inputFor(
            existing, "Range Product", lookupIntel,
            formTypeRaw = "Wettable powder",
            defaults = defaults,
        )
        // The same basis updates the SAME row instead of duplicating it.
        assertEquals("row-per-100l", input.rates.single().id)
        assertEquals(100.0, input.rates.single().value, 1e-9)
    }

    // ---- A3: Change Product semantics ----

    @Test
    fun `change product replaces label details and keeps the growers own fields`() {
        val existing = SavedChemical(
            id = "chem-1",
            vineyardId = "vineyard-1",
            name = "Product A",
            unit = "Litres",
            productForm = "liquid",
            manufacturer = "Old Registrant",
            labelUrl = "https://old.example/label.pdf",
            packSize = 20.0,
            pricePerPack = 350.0,
            inventoryQuantity = 3.0,
            notes = "Shed B, top shelf",
        )
        val newProduct = intel(
            uses = listOf(
                grapeUse(
                    ChemicalLabelRate(
                        basis = ChemicalLabelRateBasis.PER_100_LITRES,
                        value = 200.0,
                        unit = "g",
                    ),
                ),
            ),
            registration = ChemicalRegistration(
                countryCode = "AU",
                registrationNumber = "91636",
                registrant = "New Registrant",
                labelReference = "https://new.example/label.pdf",
            ),
        )
        val newPlan = ChemicalDefaultRate.plan(newProduct.registeredUses.viticultural())
        val defaults = ChemicalDefaultRateSelection(newPlan).selecting(
            newPlan.per100Litres.options.first(),
            ChemicalDefaultRateBasis.PER_100_LITRES,
        )
        val input = ChemicalStoreMatching.inputFor(
            existing, "Product B", newProduct,
            formTypeRaw = "Wettable powder",
            defaults = defaults,
        )
        // Price, pack, stock and notes are kept...
        assertEquals(20.0, input.packSize)
        assertEquals(350.0, input.pricePerPack)
        assertEquals(3.0, input.inventoryQuantity)
        assertEquals("Shed B, top shelf", input.notes)
        // ...the label details are replaced...
        assertEquals("Product B", input.name)
        assertEquals("New Registrant", input.manufacturer)
        assertEquals("https://new.example/label.pdf", input.labelUrl)
        assertEquals("solid", input.productForm)
        assertEquals("Kg", input.unit)
        // ...and the default rate chosen for the old product is gone — the
        // projection comes entirely from the NEW product's registered rates.
        assertEquals(1, input.rates.size)
        assertEquals(200.0, input.rates.single().value, 1e-9)
    }

    // ---- A8: save/reload round trip ----

    @Test
    fun `solid liquid and unknown forms survive a persistence round trip`() {
        for ((form, unit) in listOf("solid" to "Kg", "liquid" to "Litres", "" to "")) {
            val stored = SavedChemical(
                id = "chem-$form",
                vineyardId = "vineyard-1",
                name = "Round Trip $form",
                unit = unit,
                productForm = form,
            )
            val reloaded: SavedChemical = json.decodeFromString(json.encodeToString(SavedChemical.serializer(), stored))
            assertEquals(form, reloaded.productForm)
            assertEquals(unit, reloaded.unit)
        }
    }

    @Test
    fun `the projected operational rate survives a persistence round trip`() {
        val stored = SavedChemical(
            id = "chem-1",
            vineyardId = "vineyard-1",
            name = "Range Product",
            unit = "g",
            ratePerHa = 0.0,
            rates = listOf(
                ChemicalRate(
                    id = "row-1",
                    label = "NSW, Vic, SA",
                    value = 150.0,
                    basis = CHEMICAL_RATE_PER_100L,
                ),
            ),
        )
        val reloaded: SavedChemical = json.decodeFromString(json.encodeToString(SavedChemical.serializer(), stored))
        assertEquals(150.0, reloaded.ratePer100LDisplay!!, 1e-9)
        assertEquals("NSW, Vic, SA", reloaded.rates.single().label)
        assertTrue(reloaded.ratePerHaDisplay == null)
    }
}
