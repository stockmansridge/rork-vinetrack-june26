import Foundation
import Testing
import PDFKit
@testable import VineTrack

@MainActor struct ProgramGroupedPDFTests {
    @Test func representativeGroupsKeepDistinctProductsAndIdentity() {
        let cases: [(String, String, [String])] = [
            ("EL1 — Dormancy", "EL1", ["Spray Seal"]),
            ("EL12-16 — Shoot Development", "EL12", ["Kocide Blue", "Belanty"]),
            ("EL9 — 3-5 Leaves", "EL9", ["Crop SIL", "Advance Promote", "Advance Energize", "Crop Starter", "In Crop"]),
            ("EL17-18 — Pre-Flowering", "EL17", ["Zampro", "Flute", "Prolectus", "Avatar"]),
            ("EL27-29 — Fruit Set / pepper-corn", "EL27", ["Product A", "Product B", "Product C", "Product D", "Product E", "Product F"])
        ]
        let rows = cases.enumerated().flatMap { index, item in
            item.2.map { product in SprayProgramReferenceRow(stage: item.1, description: "Growth description", name: item.0,
                targets: "Downy mildew · Powdery mildew", method: "Foliar", equipment: "Quantum 420", product: product,
                rate: "Rate set when planning", notes: "Repeat if necessary", pdfStepID: String(index), pdfProduct: ProgramPDFProduct(name: product)) }
        }
        let blocks = ProgramStepExportBlock.grouped(rows)
        #expect(blocks.count == 5)
        #expect(blocks.map { $0.products.count } == [1, 2, 5, 4, 6])
        #expect(blocks[1].stage == "E-L Stage 12-16")
        #expect(blocks[1].timing == "Shoot Development")
        #expect(blocks[2].products.map(\.name) == cases[2].2)
        var separate = rows[0]; separate.pdfStepID = "other identity"
        #expect(ProgramStepExportBlock.grouped([rows[0], separate]).count == 2)
        #expect(SprayProgramReferenceDataset.csv(rows).components(separatedBy: "\r\n").count == rows.count + 2)
    }

    @Test func dynamicColumnsUseWholeDocumentAndReclaimWidth() {
        let row = SprayProgramReferenceRow(stage: "EL9", description: "", name: "Leaves", targets: "", method: "", equipment: "", product: "Product", rate: "Rate set when planning", notes: "N/A")
        let empty = ProgramStepExportBlock(reference: row, products: [ProgramPDFProduct(name: "Product")])
        #expect(ProgramPDFLayout.columns([empty]) == [.timing, .product])
        let minimal = ProgramPDFLayout.widths([.timing, .product])
        #expect(abs(minimal.reduce(0, +) - 770) < 0.001)
        let populated = ProgramPDFProduct(name: "Product", per100L: "80 mL/100 L", perHa: "1.50 kg/treated ha", moa: "9 + 12", estimatedCost: "16.00")
        var fullRow = row
        fullRow = SprayProgramReferenceRow(stage: row.stage, description: "", name: row.name, targets: "Downy", method: "Banded", equipment: "Quantum 420", product: row.product, rate: row.rate, notes: "Within 6 days of pruning")
        let full = ProgramStepExportBlock(reference: fullRow, products: [populated])
        #expect(ProgramPDFLayout.columns([empty, full]) == ProgramPDFColumn.allCases)
        for column in [ProgramPDFColumn.per100L, .perHa, .moa, .cost] {
            var product = populated
            switch column { case .per100L: product.per100L = ""; case .perHa: product.perHa = ""; case .moa: product.moa = ""; default: product.estimatedCost = "" }
            let reduced = ProgramPDFLayout.columns([ProgramStepExportBlock(reference: fullRow, products: [product])])
            #expect(!reduced.contains(column))
            #expect(abs(ProgramPDFLayout.widths(reduced).reduce(0, +) - 770) < 0.001)
            #expect(ProgramPDFLayout.widths(reduced)[0] > ProgramPDFLayout.widths(ProgramPDFColumn.allCases)[0])
        }
        #expect(empty.products[0].unknownRate)
        #expect(!ProgramPDFProduct(name: "").unknownRate)
    }

    @Test func programmedRatesKeepBasisAndCSVBytes() {
        let products = [SprayChemical(name: "Dilute", ratePer100L: 80, unit: .millilitres, rateBasis: .per100Litres),
                        SprayChemical(name: "Area", ratePerHa: 1500, unit: .litres, rateBasis: .wholeBlockArea),
                        SprayChemical(name: "Treated", ratePerHa: 1500, unit: .kilograms, rateBasis: .treatedArea),
                        SprayChemical(name: "Unknown")]
        let record = SprayRecord(sprayReference: "EL12 — Shoot", tanks: [SprayTank(chemicals: products)], isTemplate: true)
        let step = SprayProgramStep(record: record, source: .local)
        let rows = SprayProgramReferenceDataset.rows(steps: [step], chemicals: [])
        #expect(rows[0].pdfProduct?.per100L == rows[0].rate)
        #expect(rows[0].pdfProduct?.perHa == "")
        #expect(rows[1].pdfProduct?.perHa == "1.50 L/ha")
        #expect(rows[2].pdfProduct?.perHa == "1.50 kg/treated ha")
        #expect(rows[3].pdfProduct?.unknownRate == true)
        let before = SprayProgramReferenceDataset.csv(rows)
        _ = ProgramStepExportBlock.grouped(rows)
        #expect(SprayProgramReferenceDataset.csv(rows) == before)
        #expect(rows[3].rate == "Rate set when planning")
    }

    @Test func registeredFallbackUsesStructuredDenominatorsAndMOAOnly() {
        var chemical = SavedChemical(name: "Product", unit: .kilograms, chemicalIntelligence: ChemicalIntelligence(registeredUses: [
            ChemicalRegisteredUse(crop: "Grapevines", targetRaw: "Downy mildew", rates: [
                ChemicalLabelRate(label: "Dilute", basis: .rangePer100Litres, minValue: 150, maxValue: 200, unit: "g"),
                ChemicalLabelRate(label: "Area", basis: .perHectare, value: 1.5, unit: "kg")]),
            ChemicalRegisteredUse(crop: "Tobacco", targetRaw: "Downy mildew", rates: [ChemicalLabelRate(basis: .perHectare, value: 999, unit: "kg")])
        ]))
        chemical.backendActivityGroups = ["M1"]
        let product = SprayChemical(name: "Product", savedChemicalId: chemical.id)
        let step = SprayProgramStep(record: SprayRecord(sprayReference: "EL12 — Shoot", isTemplate: true), source: .portal, targetRaw: "Downy mildew")
        let result = ProgramPDFProduct.make(product, step: step, chemicals: [chemical])
        #expect(result.per100L.contains("150")); #expect(result.per100L.contains("200"))
        #expect(result.perHa.contains("1.5")); #expect(!result.perHa.contains("999"))
        #expect(!result.per100L.contains("175")); #expect(result.moa == "M1")
        #expect(result.estimatedCost.isEmpty)
        let unmatched = SprayProgramStep(record: step.record, source: .portal, targetRaw: "Unknown target")
        #expect(ProgramPDFProduct.make(product, step: unmatched, chemicals: [chemical]).unknownRate)
        chemical.backendActivityGroups = []
        chemical.chemicalIntelligence = nil
        chemical.chemicalGroup = "Group 3"
        #expect(ProgramPDFProduct.make(product, step: step, chemicals: [chemical]).moa.isEmpty)
        let empty = SprayProgramReferenceDataset.rows(steps: [step], chemicals: [])
        let block = ProgramStepExportBlock.grouped(empty)[0]
        #expect(block.products[0].name.isEmpty)
        #expect(!block.products[0].unknownRate)
    }

    @Test func legacyCleanupKeepsInstructionsButNeverManufacturesEvidence() {
        let notes = "Within 6 days of pruning\nProduct details - Kocide Blue: rate/100L 135-190 g; MOA M1; est $/ha 17.25; Or Tri Base Blue\nDo not apply with copper\nRepeat after initial application\nAlternative is Lime Sulphur"
        let displayed = ProgramPDFLayout.comments(notes)
        #expect(!displayed.contains("135-190"))
        #expect(!displayed.contains("MOA M1"))
        #expect(!displayed.contains("17.25"))
        for instruction in ["Within 6 days of pruning", "Or Tri Base Blue", "Do not apply with copper", "Repeat after initial application", "Alternative is Lime Sulphur"] { #expect(displayed.contains(instruction)) }
        #expect(ProgramPDFLayout.comments("Rate set when planning\nNone\nN/A") == "")
        let instruction = "Do not exceed rate 2 L/ha"
        #expect(ProgramPDFLayout.comments("Product details - Copper: \(instruction); Keep away from waterways.\nMixing order:").contains(instruction))
        #expect(ProgramPDFLayout.comments("Product details - Copper: Keep away from waterways.\nMixing order:").contains("Keep away from waterways."))
        #expect(ProgramPDFLayout.comments("Product details - Copper: rate/100L 150 g; MOA M1; est $/ha 12.50").isEmpty)
        #expect(ProgramPDFLayout.methodStyle("Foliar") == "gold")
        #expect(ProgramPDFLayout.methodStyle("Banded") == "green")
        #expect(ProgramPDFLayout.methodStyle("Unknown") == "neutral")
    }

    @Test func pageBreakRulesKeepGroupsTogetherAndSplitOnSafeBoundaries() {
        #expect(!ProgramPDFLayout.needsFreshPage(height: 100, y: 100, top: 94))
        #expect(ProgramPDFLayout.needsFreshPage(height: 100, y: 500, top: 94))
        #expect(!ProgramPDFLayout.needsFreshPage(height: 1000, y: 94, top: 94))
        #expect(ProgramPDFLayout.slice(height: 100, offset: 0, available: 200, boundaries: [20, 40]) == 100)
        #expect(ProgramPDFLayout.slice(height: 1000, offset: 0, available: 454, boundaries: [200, 400, 600]) == 404)
        #expect(ProgramPDFLayout.slice(height: 1000, offset: 404, available: 426, boundaries: []) == 420)
    }

    @Test func wrapsWordsAndOnlySplitsOversizeTokens() {
        #expect(ProgramPDFLayout.wrap("Product fertiliser uptake", width: 10, measure: { Double($0.count) }) == ["Product", "fertiliser", "uptake"])
        #expect(ProgramPDFLayout.wrap("extraordinary", width: 5, measure: { Double($0.count) }) == ["extra", "ordin", "ary"])
    }

    @Test func renderedGroupsRepeatHeadersAndKeepProductsTogether() throws {
        let rows = (0..<12).flatMap { index in
            ["Kocide Blue", "Belanty"].map { product in SprayProgramReferenceRow(stage: "EL12", description: "5 leaves separated; shoots about 10 cm long", name: "Timing \(index)", targets: "Downy mildew · Powdery mildew", method: "Foliar", equipment: "Quantum 420", product: product, rate: "80 mL/100 L", notes: "Or Tri Base Blue", pdfStepID: String(index), pdfProduct: ProgramPDFProduct(name: product, per100L: "80 mL/100 L")) }
        }
        let url = try SprayProgramReferenceExport.pdf(rows: rows, vineyard: "PDF fixture", logo: nil)
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount > 1)
        for index in 0..<pdf.pageCount {
            let page = try #require(pdf.page(at: index))
            #expect(page.bounds(for: .mediaBox).width == 842)
            #expect(page.bounds(for: .mediaBox).height == 595)
            let text = page.string ?? ""
            #expect(text.contains("TIMING"))
            #expect(text.contains("Page \(index + 1)"))
            #expect(text.contains("Program reference only"))
            #expect(text.components(separatedBy: "Kocide Blue").count == text.components(separatedBy: "Belanty").count)
        }
        let allText = pdf.string ?? ""
        #expect(allText.components(separatedBy: "Quantum 420").count - 1 == 12)
        #expect(allText.components(separatedBy: "Or Tri Base Blue").count - 1 == 12)
    }

    @Test func oversizedGroupContinuesWithoutLosingProducts() throws {
        let rows = (0..<100).map { index in SprayProgramReferenceRow(stage: "EL27", description: "Fruit Set", name: "Disease spray", targets: "Downy mildew", method: "Banded", equipment: "Quantum 420", product: "UniqueProduct\(index)", rate: "1.50 L/ha", notes: "Repeat if necessary", pdfStepID: "large", pdfProduct: ProgramPDFProduct(name: "UniqueProduct\(index)", perHa: "1.50 L/ha")) }
        let url = try SprayProgramReferenceExport.pdf(rows: rows, vineyard: "Oversized fixture", logo: nil)
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount >= 3)
        #expect((pdf.page(at: 1)?.string ?? "").contains("continued"))
        for index in 0..<100 { #expect((pdf.string ?? "").contains("UniqueProduct\(index)")) }
    }
}
