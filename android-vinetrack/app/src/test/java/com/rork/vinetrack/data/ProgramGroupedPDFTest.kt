package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.data.chemical.*
import org.junit.Assert.*
import org.junit.Test

class ProgramGroupedPDFTest {
    @Test fun representativeGroupsPreserveProductsIdentityAndCSV() {
        val cases = listOf(
            Triple("EL1 — Dormancy", "EL1", listOf("Spray Seal")),
            Triple("EL12-16 — Shoot Development", "EL12", listOf("Kocide Blue", "Belanty")),
            Triple("EL9 — 3-5 Leaves", "EL9", listOf("Crop SIL", "Advance Promote", "Advance Energize", "Crop Starter", "In Crop")),
            Triple("EL17-18 — Pre-Flowering", "EL17", listOf("Zampro", "Flute", "Prolectus", "Avatar")),
            Triple("EL27-29 — Fruit Set / pepper-corn", "EL27", listOf("Product A", "Product B", "Product C", "Product D", "Product E", "Product F")),
        )
        val rows = cases.flatMapIndexed { index, item -> item.third.map { product ->
            SprayProgramReferenceRow(item.second, "Growth description", item.first, "Downy mildew · Powdery mildew", "Foliar", "Quantum 420", product, "Rate set when planning", "Repeat if necessary", index.toString(), ProgramPDFProduct(product))
        } }
        val before = SprayProgramReferenceDataset.csv(rows)
        val blocks = ProgramStepExportBlock.grouped(rows)
        assertEquals(5, blocks.size)
        assertEquals(listOf(1, 2, 5, 4, 6), blocks.map { it.products.size })
        assertEquals("E-L Stage 12-16", blocks[1].stage)
        assertEquals("Shoot Development", blocks[1].timing)
        assertEquals(cases[2].third, blocks[2].products.map { it.name })
        assertEquals(2, ProgramStepExportBlock.grouped(listOf(rows[0], rows[0].copy(pdfStepId = "other identity"))).size)
        assertEquals(before, SprayProgramReferenceDataset.csv(rows))
        assertEquals(rows.size + 2, before.split("\r\n").size)
    }

    @Test fun dynamicColumnsInspectEntireDocumentAndUseFullWidth() {
        val row = SprayProgramReferenceRow("EL9", "", "Leaves", "", "", "", "Product", "Rate set when planning", "N/A")
        val empty = ProgramStepExportBlock(row, listOf(ProgramPDFProduct("Product")))
        assertEquals(listOf(ProgramPDFColumn.TIMING, ProgramPDFColumn.PRODUCT), ProgramPDFLayout.columns(listOf(empty)))
        assertEquals(770.0, ProgramPDFLayout.widths(ProgramPDFLayout.columns(listOf(empty))).sum(), .001)
        val fullRow = row.copy(targets = "Downy", method = "Banded", notes = "Within 6 days of pruning")
        val product = ProgramPDFProduct("Product", "80 mL/100 L", "1.50 kg/treated ha", "9 + 12", "16.00")
        val full = ProgramStepExportBlock(fullRow, listOf(product))
        assertEquals(ProgramPDFColumn.entries, ProgramPDFLayout.columns(listOf(empty, full)))
        for (column in listOf(ProgramPDFColumn.PER100L, ProgramPDFColumn.PERHA, ProgramPDFColumn.MOA, ProgramPDFColumn.COST)) {
            val missing = when (column) {
                ProgramPDFColumn.PER100L -> product.copy(per100L = "")
                ProgramPDFColumn.PERHA -> product.copy(perHa = "")
                ProgramPDFColumn.MOA -> product.copy(moa = "")
                else -> product.copy(estimatedCost = "")
            }
            val reduced = ProgramPDFLayout.columns(listOf(ProgramStepExportBlock(fullRow, listOf(missing))))
            assertFalse(reduced.contains(column))
            assertEquals(770.0, ProgramPDFLayout.widths(reduced).sum(), .001)
            assertTrue(ProgramPDFLayout.widths(reduced)[0] > ProgramPDFLayout.widths(ProgramPDFColumn.entries)[0])
        }
        assertTrue(empty.products.single().unknownRate)
        assertFalse(ProgramPDFProduct("").unknownRate)
    }

    @Test fun programmedBasisIsNeverConvertedAndNoProductHasNoFalseRate() {
        val products = listOf(
            SprayChemical(id = "dilute", name = "Dilute", ratePer100L = 80.0, unit = "mL", rateBasis = "per_100_litres"),
            SprayChemical(id = "area", name = "Area", ratePerHa = 1500.0, unit = "Litres", rateBasis = "whole_block_area"),
            SprayChemical(id = "treated", name = "Treated", ratePerHa = 1500.0, unit = "Kg", rateBasis = "treated_area"),
            SprayChemical(id = "unknown", name = "Unknown"),
        )
        val step = SprayRecord(id = "step", vineyardId = "vineyard", sprayReference = "EL12 — Shoot", isTemplate = true,
            tanks = listOf(SprayTank(id = "tank", chemicals = products)))
        val rows = SprayProgramReferenceDataset.rows(listOf(step), emptyList())
        assertEquals(rows[0].rate, rows[0].pdfProduct?.per100L)
        assertEquals("", rows[0].pdfProduct?.perHa)
        assertEquals("1.50 L/ha", rows[1].pdfProduct?.perHa)
        assertEquals("1.50 kg/treated ha", rows[2].pdfProduct?.perHa)
        assertTrue(rows[3].pdfProduct?.unknownRate == true)
        assertEquals("Rate set when planning", rows[3].rate)
        val empty = SprayProgramReferenceDataset.rows(listOf(step.copy(tanks = emptyList())), emptyList())
        val block = ProgramStepExportBlock.grouped(empty).single()
        assertEquals("", block.products.single().name)
        assertFalse(block.products.single().unknownRate)
    }

    @Test fun registeredFallbackKeepsCorrectDenominatorsWithoutBorrowingOrMidpoints() {
        val chemical = SavedChemical(id = "chemical", vineyardId = "vineyard", name = "Product", unit = "Kg", activityGroups = listOf("M1"), registeredUses = listOf(
            ChemicalRegisteredUse(crop = "Grapevines", targetRaw = "Downy mildew", rates = listOf(
                ChemicalLabelRate(label = "Dilute", basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES, minValue = 150.0, maxValue = 200.0, unit = "g"),
                ChemicalLabelRate(label = "Area", basis = ChemicalLabelRateBasis.PER_HECTARE, value = 1.5, unit = "kg"))),
            ChemicalRegisteredUse(crop = "Tobacco", targetRaw = "Downy mildew", rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 999.0, unit = "kg"))),
        ))
        val product = SprayChemical(id = "line", name = "Product", savedChemicalId = chemical.id)
        val step = SprayRecord(id = "step", vineyardId = "vineyard", targets = listOf("downy"))
        val result = ProgramPDFProduct.make(product, step, listOf(chemical), mapOf("downy" to "Downy mildew"))
        assertTrue(result.per100L.contains("150")); assertTrue(result.per100L.contains("200"))
        assertTrue(result.perHa.contains("1.5")); assertFalse(result.perHa.contains("999"))
        assertFalse(result.per100L.contains("175")); assertEquals("M1", result.moa)
        assertEquals("", result.estimatedCost)
        val unmatched = ProgramPDFProduct.make(product, step.copy(targets = listOf("unknown")), listOf(chemical), emptyMap())
        assertTrue(unmatched.unknownRate)
        val legacy = chemical.copy(activityGroups = null, registeredUses = null, chemicalGroup = "Group 3", modeOfAction = "3")
        assertEquals("", ProgramPDFProduct.make(product, step, listOf(legacy), emptyMap()).moa)
    }

    @Test fun legacyNotesKeepOperationalInstructionsWithoutInventingMetadata() {
        val notes = "Within 6 days of pruning\nProduct details - Kocide Blue: rate/100L 135-190 g; MOA M1; est $/ha 17.25; Or Tri Base Blue\nDo not apply with copper\nRepeat after initial application\nAlternative is Lime Sulphur"
        val display = ProgramPDFLayout.comments(notes)
        assertFalse(display.contains("135-190")); assertFalse(display.contains("MOA M1")); assertFalse(display.contains("17.25"))
        listOf("Within 6 days of pruning", "Or Tri Base Blue", "Do not apply with copper", "Repeat after initial application", "Alternative is Lime Sulphur").forEach { assertTrue(display.contains(it)) }
        assertEquals("", ProgramPDFLayout.comments("Rate set when planning\nNone\nN/A"))
        val instruction = "Do not exceed rate 2 L/ha"
        assertTrue(ProgramPDFLayout.comments("Product details - Copper: $instruction; Keep away from waterways.\nMixing order:").contains(instruction))
        assertTrue(ProgramPDFLayout.comments("Product details - Copper: Keep away from waterways.\nMixing order:").contains("Keep away from waterways."))
        assertEquals("", ProgramPDFLayout.comments("Product details - Copper: rate/100L 150 g; MOA M1; est $/ha 12.50"))
        assertEquals("gold", ProgramPDFLayout.methodStyle("Foliar"))
        assertEquals("green", ProgramPDFLayout.methodStyle("Banded"))
        assertEquals("neutral", ProgramPDFLayout.methodStyle("Unknown"))
    }

    @Test fun groupsMoveToFreshPageAndOversizeSlicesKeepSafeBoundaries() {
        assertFalse(ProgramPDFLayout.needsFreshPage(100.0, 100.0, 94.0))
        assertTrue(ProgramPDFLayout.needsFreshPage(100.0, 500.0, 94.0))
        assertFalse(ProgramPDFLayout.needsFreshPage(1000.0, 94.0, 94.0))
        assertEquals(100.0, ProgramPDFLayout.slice(100.0, 0.0, 200.0, listOf(20.0, 40.0)), .001)
        assertEquals(404.0, ProgramPDFLayout.slice(1000.0, 0.0, 454.0, listOf(200.0, 400.0, 600.0)), .001)
        assertEquals(420.0, ProgramPDFLayout.slice(1000.0, 404.0, 426.0, emptyList()), .001)
    }

    @Test fun wordsWrapWithoutCharacterSplittingUnlessTokenTooWide() {
        assertEquals(listOf("Product", "fertiliser", "uptake"), ProgramPDFLayout.wrap("Product fertiliser uptake", 10.0) { it.length.toDouble() })
        assertEquals(listOf("extra", "ordin", "ary"), ProgramPDFLayout.wrap("extraordinary", 5.0) { it.length.toDouble() })
    }
}
