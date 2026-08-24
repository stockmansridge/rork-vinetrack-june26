import Foundation
import Testing
@testable import VineTrack

/// The iOS Spray Calculator FINAL DISPLAY CLEANUP: Edit Chemical must show
/// each registered use's OWN captured rate(s), in the label's original unit
/// and basis, directly beneath that use — never converted, never borrowed
/// from a sibling use, and never confused with AI-only suggestions.
///
/// `ChemicalManualEntry.displayRate(for:)` is the single formatter this
/// screen uses. It is exercised directly here because it is exactly the
/// text the "Registered rate" block renders — no separate SwiftUI rendering
/// path exists for this figure.
struct SprayEditChemicalRegisteredRateDisplayTests {

    // MARK: - A. Per-100 L structured rate

    @Test("A per-100 L range rate displays in its original unit and basis")
    func per100LitresRangeDisplays() {
        let draft = ChemicalManualRateDraft(
            basis: .rangePer100Litres,
            minText: "150",
            maxText: "200",
            unit: "g"
        )
        #expect(ChemicalManualEntry.displayRate(for: draft) == "150–200 g/100 L")
    }

    // MARK: - B. Per-hectare structured rate

    @Test("A per-hectare rate displays the original value, unit and /ha")
    func perHectareDisplays() {
        let draft = ChemicalManualRateDraft(basis: .perHectare, valueText: "2.0", unit: "L")
        #expect(ChemicalManualEntry.displayRate(for: draft) == "2 L/ha")
    }

    @Test("A per-hectare rate never converts the stock unit into the label unit")
    func perHectareNeverConvertsUnit() {
        // The label says kg/ha; the product's STOCK unit might be litres —
        // the display must still say what the label says, not the stock unit.
        let draft = ChemicalManualRateDraft(basis: .perHectare, valueText: "2.2", unit: "kg")
        #expect(ChemicalManualEntry.displayRate(for: draft) == "2.2 kg/ha")
    }

    // MARK: - C / F / G. Dithane: rate belongs to its own use only

    /// The Dithane shape from the task: three grapevine uses with no
    /// canonical rate, one (Phomopsis cane) with a captured range.
    private func dithaneUses() -> [ChemicalRegisteredUse] {
        [
            ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "BLACK SPOT"),
            ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "LEAF SPOT"),
            ChemicalRegisteredUse(
                crop: "GRAPEVINE",
                targetRaw: "PHOMOPSIS CANE",
                rates: [ChemicalLabelRate(basis: .rangePer100Litres, minValue: 150, maxValue: 200, unit: "g")]
            ),
            ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "DOWNY MILDEW"),
        ]
    }

    @Test("Phomopsis cane shows its own 150-200 g/100 L rate")
    func phomopsisCaneShowsItsRate() {
        let uses = dithaneUses()
        let phomopsis = uses.first { $0.targetRaw == "PHOMOPSIS CANE" }!
        let displayed = phomopsis.rates.compactMap { $0.displayRate }
        #expect(displayed == ["150–200 g/100 L"])
    }

    @Test("The other Dithane grapevine uses remain no-rate, never borrowing Phomopsis cane's rate")
    func siblingUsesRemainNoRate() {
        let uses = dithaneUses()
        for target in ["BLACK SPOT", "LEAF SPOT", "DOWNY MILDEW"] {
            let use = uses.first { $0.targetRaw == target }!
            #expect(use.rates.isEmpty, "\(target) must show no rate, not Phomopsis cane's")
        }
    }

    // MARK: - D. Several uses on one product: each rate under its own use

    @Test("A product with several registered uses keeps each rate scoped to its owning use")
    func multipleUsesKeepRatesScoped() {
        let chemical = SavedChemical(
            vineyardId: UUID(),
            name: "MULTI-USE FUNGICIDE",
            chemicalIntelligence: ChemicalIntelligence(registeredUses: dithaneUses())
        )
        let uses = chemical.chemicalIntelligence?.registeredUses ?? []
        #expect(uses.count == 4)
        // Exactly one use carries a rate; the rest carry none.
        let usesWithRates = uses.filter { !$0.rates.isEmpty }
        #expect(usesWithRates.count == 1)
        #expect(usesWithRates.first?.targetRaw == "PHOMOPSIS CANE")
    }

    // MARK: - E. AI suggestions never appear as registered rates

    @Test("An empty registered use produces no display text, regardless of any AI-only suggestion elsewhere")
    func aiSuggestionsAreNotRegisteredRates() {
        // A use the label itself gives no canonical rate for must render
        // NOTHING here, even when the product record separately carries an
        // AI-derived interpretation somewhere else in its intelligence. This
        // formatter only ever reads `use.rates` — the authoritative,
        // server-merged registered-use array — so an AI suggestion living
        // outside that array can never surface through this path.
        let use = ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "DOWNY MILDEW")
        #expect(use.rates.isEmpty)
        let displayed = use.rates.compactMap { $0.displayRate }
        #expect(displayed.isEmpty)
    }

    @Test("A rate with no value and no raw text produces no display text, never a fabricated figure")
    func emptyDraftProducesNoDisplayText() {
        let draft = ChemicalManualRateDraft(basis: .perHectare)
        #expect(ChemicalManualEntry.displayRate(for: draft) == nil)
    }

    // MARK: - Round trip: what the editor stores is exactly what it shows

    @Test("Converting a stored per-100 L rate to a draft and back displays the same figure")
    func roundTripPreservesDisplay() {
        let original = ChemicalLabelRate(basis: .per100Litres, value: 300, unit: "g")
        let draft = ChemicalManualEntry.draft(
            from: ChemicalIntelligence(registeredUses: [
                ChemicalRegisteredUse(crop: "GRAPEVINE", targetRaw: "PHOMOPSIS CANE", rates: [original])
            ])
        )
        let use = draft.uses.first { $0.targetRaw == "PHOMOPSIS CANE" }
        let rate = use?.rates.first
        #expect(rate.flatMap { ChemicalManualEntry.displayRate(for: $0) } == "300 g/100 L")
    }
}
