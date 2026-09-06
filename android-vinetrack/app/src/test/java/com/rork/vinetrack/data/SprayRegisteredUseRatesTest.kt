package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.SprayConfirmedRateSeeding
import com.rork.vinetrack.data.chemical.SprayRateAmount
import com.rork.vinetrack.data.chemical.SprayRateOrigin
import com.rork.vinetrack.data.chemical.SprayRatePreset
import com.rork.vinetrack.data.chemical.SprayRegisteredUseRates
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRate
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRates
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.spray.SprayProductQuantityCalculator
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayQuantityContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SprayRegisteredUseRatesTest {
    private fun rate(
        id: String,
        basis: ChemicalLabelRateBasis,
        value: Double? = null,
        min: Double? = null,
        max: Double? = null,
        unit: String = "g",
        label: String = "",
    ): ChemicalLabelRate = ChemicalLabelRate(
        label = label,
        basis = basis,
        value = value,
        minValue = min,
        maxValue = max,
        unit = unit,
        rateId = id,
    )

    private fun use(
        crop: String,
        target: String,
        rates: List<ChemicalLabelRate>,
        direction: String = "direction-${crop.lowercase()}-${target.lowercase()}",
    ): ChemicalRegisteredUse = ChemicalRegisteredUse(
        crop = crop,
        targetRaw = target,
        rates = rates,
        directionId = direction,
    )

    private fun chemical(
        uses: List<ChemicalRegisteredUse>? = null,
        legacy: List<ChemicalRate> = emptyList(),
        defaults: StoredChemicalDefaultRates? = null,
        unit: String = "Kg",
    ): SavedChemical = SavedChemical(
        id = "dithane",
        vineyardId = "vineyard",
        name = "Dithane Rainshield",
        unit = unit,
        registeredUses = uses,
        rates = legacy,
        defaultRates = defaults,
    )

    private val grapeRange = rate(
        id = "rate_v1_grapes",
        basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
        min = 150.0,
        max = 200.0,
        unit = "g",
    )
    private val tobacco = rate(
        id = "rate_v1_tobacco",
        basis = ChemicalLabelRateBasis.PER_HECTARE,
        value = 2.2,
        unit = "kg",
    )

    @Test
    fun `structured vineyard picker excludes tobacco citrus and unrelated crops`() {
        val chem = chemical(
            uses = listOf(
                use("Grapevines", "Downy mildew", listOf(grapeRange)),
                use("Tobacco", "Blue mould", listOf(tobacco)),
                use("Citrus", "Black spot", listOf(rate("rate_v1_citrus", ChemicalLabelRateBasis.PER_HECTARE, value = 2.0, unit = "kg"))),
                use("Mandarins", "Brown spot", listOf(rate("rate_v1_mandarin", ChemicalLabelRateBasis.PER_HECTARE, value = 1.5, unit = "kg"))),
            ),
        )

        val offered = SprayRegisteredUseRates.vineyardRates(chem)
        assertTrue(offered.isNotEmpty())
        assertTrue(offered.all { it.crop == "Grapevines" })
        assertFalse(offered.any { it.id == "rate_v1_tobacco" || it.unit == "kg" })
    }

    @Test
    fun `product-level rates are included but rates assigned to another crop are not`() {
        val product = use(
            crop = "",
            target = "",
            rates = listOf(rate("rate_v1_product", ChemicalLabelRateBasis.PER_HECTARE, value = 1.25, unit = "kg")),
            direction = "product-rate",
        )
        val offered = SprayRegisteredUseRates.vineyardRates(
            chemical(uses = listOf(product, use("Tobacco", "Blue mould", listOf(tobacco)))),
        )
        assertEquals(listOf("rate_v1_product"), offered.map { it.id })
        assertEquals("Product label rate", offered.single().groupTitle)
    }

    @Test
    fun `structured non-vineyard rates suppress legacy fallback`() {
        val legacy = ChemicalRate("legacy", "Old rate", 900.0, "per_hectare")
        val chem = chemical(uses = listOf(use("Tobacco", "Blue mould", listOf(tobacco))), legacy = listOf(legacy))
        assertTrue(SprayRegisteredUseRates.hasStructuredRates(chem))
        assertTrue(SprayRegisteredUseRates.vineyardRates(chem).isEmpty())
    }

    @Test
    fun `legacy rates are used only when structured rates are absent`() {
        val legacy = ChemicalRate("legacy", "Saved", 2000.0, "per_hectare")
        val offered = SprayRegisteredUseRates.vineyardRates(chemical(uses = emptyList(), legacy = listOf(legacy)))
        assertEquals(1, offered.size)
        assertEquals(SprayRateOrigin.LEGACY, offered.single().origin)
        assertEquals(2.0, offered.single().appliedValue!!, 0.0)
    }

    @Test
    fun `fixed registered rate is directly selectable with stable identity and grouping`() {
        val fixed = rate("rate_v1_fixed", ChemicalLabelRateBasis.PER_HECTARE, value = 1.5, unit = "kg", label = "Before flowering")
        val chem = chemical(uses = listOf(use("Wine grapes", "Black rot", listOf(fixed), direction = "dir-black-rot")))
        val first = SprayRegisteredUseRates.vineyardRates(chem).single()
        val second = SprayRegisteredUseRates.vineyardRates(chem).single()
        assertEquals("rate_v1_fixed", first.id)
        assertEquals(first.id, second.id)
        assertEquals("dir-black-rot", first.registeredUseId)
        assertEquals("Wine grapes · Black rot", first.groupTitle)
        assertEquals(1.5, first.appliedValue!!, 0.0)
    }

    @Test
    fun `basis availability follows genuine offered label bases without conversion`() {
        val perHa = rate("rate_v1_ha", ChemicalLabelRateBasis.PER_HECTARE, value = 2.2, unit = "kg")
        val chem = chemical(uses = listOf(use("Grapes", "Mildew", listOf(grapeRange, perHa))))
        assertEquals(
            listOf(SprayCalculator.RateBasis.PER_100L, SprayCalculator.RateBasis.PER_HECTARE),
            SprayRegisteredUseRates.availableBases(chem),
        )
        val volume = SprayRegisteredUseRates.firstOffered(chem, SprayCalculator.RateBasis.PER_100L)!!
        val area = SprayRegisteredUseRates.firstOffered(chem, SprayCalculator.RateBasis.PER_HECTARE)!!
        assertTrue(volume.amount is SprayRateAmount.Range)
        assertEquals("g", volume.unit)
        assertEquals(2.2, area.appliedValue!!, 0.0)
        assertNotEquals(volume.id, area.id)
    }

    @Test
    fun `Dithane plain range offers minimum midpoint maximum in label grams`() {
        val rates = SprayRegisteredUseRates.selectableVineyardRates(
            chemical(uses = listOf(use("Grapevines", "Downy mildew", listOf(grapeRange)))),
        )
        val presets = rates.filter { it.preset != null }
        assertEquals(listOf(150.0, 175.0, 200.0), presets.map { it.appliedValue })
        assertEquals(
            listOf(SprayRatePreset.MINIMUM, SprayRatePreset.MIDPOINT, SprayRatePreset.MAXIMUM),
            presets.map { it.preset },
        )
        assertEquals(listOf("g", "g", "g"), presets.map { it.unit })
        assertTrue(presets[1].menuText.contains("mid-range"))
        assertFalse(presets[1].menuText.contains("recommended", ignoreCase = true))
        assertTrue(presets.all { it.labelRangeText == "150–200 g/100 L" })
    }

    @Test
    fun `multiple named conditions do not manufacture range presets`() {
        val low = rate("rate_v1_low", ChemicalLabelRateBasis.RANGE_PER_100_LITRES, min = 100.0, max = 150.0, label = "Low pressure")
        val high = rate("rate_v1_high", ChemicalLabelRateBasis.RANGE_PER_100_LITRES, min = 150.0, max = 200.0, label = "High pressure")
        val rates = SprayRegisteredUseRates.vineyardRates(chemical(uses = listOf(use("Grapes", "Mildew", listOf(low, high)))))
        assertEquals(2, rates.size)
        assertTrue(rates.none { it.preset != null })
        assertEquals(listOf("Low pressure", "High pressure"), rates.map { it.condition })
    }

    @Test
    fun `Dithane manual range validation accepts 175 and rejects empty 149 and 201`() {
        val range = SprayRegisteredUseRates.vineyardRates(
            chemical(uses = listOf(use("Grapevines", "Downy mildew", listOf(grapeRange)))),
        ).first { it.amount is SprayRateAmount.Range }
        assertEquals(175.0, SprayRegisteredUseRates.validateManual("175", range)!!, 0.0)
        assertNull(SprayRegisteredUseRates.validateManual("", range))
        assertNull(SprayRegisteredUseRates.validateManual("0", range))
        assertNull(SprayRegisteredUseRates.validateManual("-1", range))
        assertNull(SprayRegisteredUseRates.validateManual("149", range))
        assertNull(SprayRegisteredUseRates.validateManual("201", range))
    }

    @Test
    fun `confirmed default seeds only its exact amount unit and basis`() {
        val default = StoredChemicalDefaultRate(
            optionKey = "default_option_v1_dithane",
            rateIds = listOf("rate_v1_grapes"),
            basis = ChemicalDefaultRateBasis.PER_100_LITRES.raw,
            unit = "g",
            value = 175.0,
        )
        val chem = chemical(
            uses = listOf(use("Grapevines", "Downy mildew", listOf(grapeRange))),
            defaults = StoredChemicalDefaultRates(per100Litres = default),
        )
        val seed = SprayConfirmedRateSeeding.seedFor(chem)!!
        assertEquals(SprayCalculator.RateBasis.PER_100L, seed.basis)
        assertEquals(175.0, seed.rateAmount!!, 0.0)
        assertEquals("g", seed.rateUnit)
        assertNull("175 is inside a range but is not itself the confirmed label row", SprayRegisteredUseRates.confirmedSelection(chem))
    }

    @Test
    fun `a confirmed default citing another crop never seeds a vineyard line`() {
        val foreignDefault = StoredChemicalDefaultRate(
            optionKey = "default_option_v1_tobacco",
            rateIds = listOf("rate_v1_tobacco"),
            basis = ChemicalDefaultRateBasis.PER_HECTARE.raw,
            unit = "kg",
            value = 2.2,
        )
        val chem = chemical(
            uses = listOf(
                use("Grapevines", "Downy mildew", listOf(grapeRange)),
                use("Tobacco", "Blue mould", listOf(tobacco)),
            ),
            defaults = StoredChemicalDefaultRates(perHectare = foreignDefault),
        )
        assertNull(SprayConfirmedRateSeeding.seedFor(chem))
    }

    @Test
    fun `unconfirmed structured rate is offered but never becomes confirmed default`() {
        val chem = chemical(uses = listOf(use("Grapevines", "Downy mildew", listOf(grapeRange))))
        assertTrue(SprayRegisteredUseRates.selectableVineyardRates(chem).isNotEmpty())
        assertNull(SprayConfirmedRateSeeding.seedFor(chem))
        assertNull(SprayRegisteredUseRates.confirmedSelection(chem))
    }

    @Test
    fun `Dithane per-100-L rate uses actual carrier and concentration without changing 3000 litres`() {
        val context = SprayQuantityContext(
            grossAreaHectares = 10.0,
            carrierLitres = 3_000.0,
            concentrationFactor = 1.1904761904761905,
        )
        val total = SprayProductQuantityCalculator.totalQuantity(
            rate = 175.0,
            basis = SprayProductRateBasis.PER_100_LITRES,
            context = context,
        )
        assertEquals(6_250.0, total!!, 0.000001)
        assertEquals(3_000.0, context.carrierLitres, 0.0)

        val perHa = SprayProductQuantityCalculator.totalQuantity(
            rate = 2.2,
            basis = SprayProductRateBasis.WHOLE_BLOCK_AREA,
            context = context,
        )
        assertEquals(22.0, perHa!!, 0.0)
    }

    @Test
    fun `preset and identical manual value calculate equally but retain distinct provenance`() {
        val chem = chemical(uses = listOf(use("Grapevines", "Downy mildew", listOf(grapeRange))))
        val rates = SprayRegisteredUseRates.vineyardRates(chem)
        val range = rates.first { it.amount is SprayRateAmount.Range }
        val midpoint = rates.first { it.preset == SprayRatePreset.MIDPOINT }
        assertEquals(midpoint.appliedValue, SprayRegisteredUseRates.validateManual("175", range))

        val presetSnapshot = SprayConfirmedRateSeeding.snapshotWithProvenance(
            base = ChemicalLineSnapshot(), chemical = chem, basis = SprayProductRateBasis.PER_100_LITRES,
            appliedRate = 175.0, unit = "g", isOverride = false, capturedAt = "now", selectedRate = midpoint,
        )!!
        val manualSnapshot = SprayConfirmedRateSeeding.snapshotWithProvenance(
            base = ChemicalLineSnapshot(), chemical = chem, basis = SprayProductRateBasis.PER_100_LITRES,
            appliedRate = 175.0, unit = "g", isOverride = true, capturedAt = "now", selectedRate = range,
        )!!
        assertEquals(175.0, presetSnapshot.appliedRate!!, 0.0)
        assertEquals(175.0, manualSnapshot.appliedRate!!, 0.0)
        assertEquals("canonical", presetSnapshot.rateEntryMethod)
        assertEquals("midpoint", presetSnapshot.ratePreset)
        assertEquals("manual", manualSnapshot.rateEntryMethod)
        assertNull(manualSnapshot.ratePreset)
        assertEquals("rate_v1_grapes", manualSnapshot.selectedRateId)
        assertEquals("direction-grapevines-downy mildew", manualSnapshot.registeredUseId)
        assertEquals(150.0, manualSnapshot.rateRangeMin!!, 0.0)
        assertEquals(200.0, manualSnapshot.rateRangeMax!!, 0.0)
    }
}
