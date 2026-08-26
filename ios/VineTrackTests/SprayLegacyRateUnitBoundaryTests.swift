import Foundation
import Testing
@testable import VineTrack

/// Gate D2 — the legacy per-hectare rate unit boundary.
///
/// # The defect
///
/// Two models spell `ratePerHa` identically and mean different things:
///
/// - `SavedChemical.ratePerHa` is a **display-unit** number. Chemicals
///   Management and Spray Presets print it straight beside `unit.rawValue`
///   with no conversion, so `2.5` on a Litres product means `2.5 L/ha`.
/// - `SprayChemical.ratePerHa` is a **base-unit** number (mL / g). Its own
///   editor reads it through `unit.fromBase` and writes it back through
///   `unit.toBase`, and `displayRate` is defined as `unit.fromBase(ratePerHa)`.
///
/// Two call sites copied the first into the second unconverted:
///
/// - `SprayRecordFormView.bind(_:at:)` — picking a saved chemical pre-filled
///   the line's rate.
/// - `SprayCalculatorView.guidedProductLines` — the last-resort legacy scalar
///   fallback for pre-Chemical-Intelligence records.
///
/// For a Litres or Kg product that is a **1000× under-dose**: `2.5 L/ha`
/// became `2.5 mL/ha`. For mL and g products `toBase` is the identity, so
/// nothing was wrong — which is precisely why it survived: the defect is
/// invisible on half the catalogue and the wrong number is always plausible.
///
/// These tests assert the RULE at each boundary rather than reaching into
/// private view state, which is how `ResistanceParityTests` and
/// `PlanJobProvenanceIntegrityTests` already pin view-owned logic here.
struct SprayLegacyRateUnitBoundaryTests {

    // MARK: - Rule replicas
    //
    // Byte-for-byte the repaired expressions from the two call sites. If either
    // view drifts back to the raw assignment these keep passing while the app
    // breaks, so each replica is additionally anchored to a real model contract
    // below (`displayRate`, `seedValue`, `hasStructuredRates`).

    /// `SprayRecordFormView.bind(_:at:)`, product branch.
    private func bind(_ chosen: SavedChemical, into line: SprayChemical) -> SprayChemical {
        var line = line
        let previousChemicalId = line.savedChemicalId
        let isProductIdentityChange = previousChemicalId != nil
            && previousChemicalId != chosen.id
        line.savedChemicalId = chosen.id
        line.name = chosen.name
        line.unit = chosen.unit
        if isProductIdentityChange {
            line.ratePerHa = 0
        }
        if line.ratePerHa == 0, chosen.ratePerHa > 0 {
            line.ratePerHa = chosen.unit.toBase(chosen.ratePerHa)
        }
        return line
    }

    /// A line already bound to `product` and carrying `baseRate` in BASE units —
    /// the state every re-bind starts from.
    private func boundLine(to product: SavedChemical, baseRate: Double) -> SprayChemical {
        var line = SprayChemical(name: product.name, unit: product.unit)
        line.savedChemicalId = product.id
        line.ratePerHa = baseRate
        return line
    }

    private func boundLineRate(line: SprayChemical, chosen: SavedChemical) -> Double {
        bind(chosen, into: line).ratePerHa
    }

    /// `SprayCalculatorView.guidedProductLines`.
    private func legacyScalarRate(
        for chemical: SavedChemical,
        basis: ChemicalRateBasis
    ) -> Double? {
        SprayRegisteredUseRates.hasStructuredRates(chemical)
            ? nil
            : (basis == .perHectare ? chemical.unit.toBase(chemical.ratePerHa) : nil)
    }

    private func saved(
        name: String = "Legacy Product",
        ratePerHa: Double,
        unit: ChemicalUnit
    ) -> SavedChemical {
        SavedChemical(name: name, ratePerHa: ratePerHa, unit: unit)
    }

    // MARK: - §1 Liquid

    /// The reported defect in the flesh: a 2.5 L/ha legacy product.
    @Test("A litre-quoted legacy rate seeds a record line as millilitres")
    func liquidRateCrossesTheBoundaryWhenSeedingARecordLine() {
        let chosen = saved(ratePerHa: 2.5, unit: .litres)
        let seeded = boundLineRate(line: SprayChemical(unit: .litres), chosen: chosen)

        #expect(abs(seeded - 2_500) < 0.0001)
        // The defect, stated as the number it actually produced.
        #expect(abs(seeded - 2.5) > 1)

        // Anchored to the real model: the line must now READ as 2.5 L/ha.
        let line = SprayChemical(name: "x", ratePerHa: seeded, unit: .litres)
        #expect(abs(line.displayRate - 2.5) < 0.0001)
        #expect(line.unitLabel == "L")
    }

    @Test("A litre-quoted legacy rate crosses the boundary in the calculator")
    func liquidRateCrossesTheBoundaryInTheCalculator() {
        let chemical = saved(ratePerHa: 2.5, unit: .litres)
        let rate = legacyScalarRate(for: chemical, basis: .perHectare)

        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 2_500) < 0.0001)
        #expect(abs(chemical.unit.fromBase(rate ?? 0) - 2.5) < 0.0001)
    }

    // MARK: - §2 Solid

    /// Solids take the same 1000× factor: `2.2 kg/ha` is `2200 g/ha`.
    @Test("A kilogram-quoted legacy rate converts to grams at both boundaries")
    func solidRateCrossesBothBoundaries() {
        let chosen = saved(name: "Dithane", ratePerHa: 2.2, unit: .kilograms)

        let seeded = boundLineRate(line: SprayChemical(unit: .kilograms), chosen: chosen)
        #expect(abs(seeded - 2_200) < 0.0001)

        let calculated = legacyScalarRate(for: chosen, basis: .perHectare)
        #expect(abs((calculated ?? 0) - 2_200) < 0.0001)

        // Both boundaries must agree — a rate seeded into a record and the same
        // rate dosed by the calculator cannot be a thousand-fold apart.
        #expect(abs(seeded - (calculated ?? 0)) < 0.0001)

        let line = SprayChemical(name: "x", ratePerHa: seeded, unit: .kilograms)
        #expect(abs(line.displayRate - 2.2) < 0.0001)
        #expect(line.unitLabel == "Kg")
    }

    /// Products already quoted in base units must NOT move. `toBase` is the
    /// identity for mL and g, so this pins that the repair added no second
    /// conversion for the half of the catalogue that was always correct.
    @Test("Millilitre and gram legacy rates are unchanged by the repair")
    func baseUnitProductsAreUnaffected() {
        for unit in [ChemicalUnit.millilitres, ChemicalUnit.grams] {
            let chosen = saved(ratePerHa: 750, unit: unit)
            #expect(boundLineRate(line: SprayChemical(unit: unit), chosen: chosen) == 750)
            #expect(legacyScalarRate(for: chosen, basis: .perHectare) == 750)
        }
    }

    // MARK: - §3 Zero rate

    /// `0` is the storage default for "no rate on record", not a rate of zero.
    /// Converting it must neither invent a value nor overwrite a rate the
    /// operator already typed.
    @Test("A zero legacy rate seeds nothing and never overwrites a typed rate")
    func zeroRateIsNotSeeded() {
        let empty = saved(ratePerHa: 0, unit: .litres)
        #expect(boundLineRate(line: SprayChemical(unit: .litres), chosen: empty) == 0)
        #expect(legacyScalarRate(for: empty, basis: .perHectare) == 0)

        // A line that already carries a rate is left alone, whatever the
        // product says — the guard is `line.ratePerHa == 0`.
        let typed = SprayChemical(name: "x", ratePerHa: 1_500, unit: .litres)
        let chosen = saved(ratePerHa: 2.5, unit: .litres)
        #expect(boundLineRate(line: typed, chosen: chosen) == 1_500)
    }

    /// A per-100 L line never takes the per-hectare scalar — converted or not.
    @Test("The legacy per-hectare scalar is refused on a per-100 L line")
    func per100LitreLineRefusesTheHectareScalar() {
        let chemical = saved(ratePerHa: 2.5, unit: .litres)
        #expect(legacyScalarRate(for: chemical, basis: .per100Litres) == nil)
    }

    // MARK: - §4 Structured-rate protection

    /// A structured product whose grapevine use states `1.5 L/ha`.
    ///
    /// Decoded through `BackendSavedChemical` — the real sync path — so this
    /// asserts the JSON the portal actually writes.
    private func structuredChemical() throws -> SavedChemical {
        let json = """
        {
          "id": "bbbbbbbb-0000-0000-0000-000000000002",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Structured Fungicide",
          "unit": "Litres",
          "rate_per_ha": 1.5,
          "rates": [],
          "registration_country": "AU",
          "registration_number": "33182",
          "registered_uses": [
            {
              "crop": "GRAPEVINE",
              "target_raw": "DOWNY MILDEW",
              "rates": [
                {
                  "label": "Standard",
                  "basis": "per_hectare",
                  "value": 1.5,
                  "unit": "L",
                  "raw_text": "1.5 L/ha"
                }
              ]
            }
          ]
        }
        """
        return try JSONDecoder()
            .decode(BackendSavedChemical.self, from: Data(json.utf8))
            .toSavedChemical()
    }

    /// The structured seed is ALREADY base units. The repair must not touch it,
    /// or `1.5 L/ha` would be dosed as `1,500,000 mL/ha` — the same defect
    /// inverted, and far more dangerous than the one being fixed.
    @Test("A structured rate is seeded in base units and never re-converted")
    func structuredRatesAreNotDoubleConverted() throws {
        let chemical = try structuredChemical()
        #expect(SprayRegisteredUseRates.hasStructuredRates(chemical))

        let selection = SprayRegisteredUseRates.defaultSelection(
            for: chemical,
            preferring: .perHectare
        )
        let selected = try #require(selection)
        let seed = try #require(
            SprayRegisteredUseRates.seedValue(
                for: chemical,
                rateId: selected.id,
                basis: .perHectare
            )
        )

        // Base units already: 1.5 L/ha is 1500 mL/ha.
        #expect(abs(seed - 1_500) < 0.0001)
        #expect(abs(chemical.unit.fromBase(seed) - 1.5) < 0.0001)

        // And a second conversion would be catastrophic, so prove the seed is
        // nowhere near it.
        #expect(abs(seed - chemical.unit.toBase(seed)) > 1_000)

        // The legacy scalar is not consulted at all once structure exists —
        // this is what stops the two paths compounding.
        #expect(legacyScalarRate(for: chemical, basis: .perHectare) == nil)
    }

    /// The fallback is genuinely last-resort: identical products differing only
    /// in whether they carry structured rates take different routes to the same
    /// base-unit answer.
    @Test("Structured and legacy products agree on the dosed base value")
    func structuredAndLegacyAgreeOnBaseUnits() throws {
        let structured = try structuredChemical()
        let legacy = saved(ratePerHa: 1.5, unit: .litres)

        let selected = try #require(
            SprayRegisteredUseRates.defaultSelection(for: structured, preferring: .perHectare)
        )
        let structuredSeed = try #require(
            SprayRegisteredUseRates.seedValue(
                for: structured, rateId: selected.id, basis: .perHectare
            )
        )
        let legacySeed = try #require(legacyScalarRate(for: legacy, basis: .perHectare))

        #expect(abs(structuredSeed - legacySeed) < 0.0001)
    }

    // MARK: - §5 Round trip

    /// What an operator sees must survive the crossing in both directions, for
    /// every unit — the property the raw assignment broke.
    @Test("Every unit round-trips display → base → display")
    func everyUnitRoundTrips() {
        let cases: [(ChemicalUnit, Double)] = [
            (.litres, 2.5), (.kilograms, 2.2), (.millilitres, 750), (.grams, 540)
        ]
        for (unit, display) in cases {
            let chosen = saved(ratePerHa: display, unit: unit)
            let base = boundLineRate(line: SprayChemical(unit: unit), chosen: chosen)
            let line = SprayChemical(name: "x", ratePerHa: base, unit: unit)

            #expect(abs(line.displayRate - display) < 0.0001)
            #expect(abs(unit.fromBase(unit.toBase(display)) - display) < 0.0001)
        }
    }

    /// The record-form editor writes through `toBase`, so a seeded rate must be
    /// indistinguishable from the same figure typed by hand. If it were not,
    /// merely opening the field would silently restate the rate.
    @Test("A seeded rate equals the same rate typed into the editor")
    func seededRateMatchesATypedRate() {
        let unit = ChemicalUnit.kilograms
        let chosen = saved(ratePerHa: 2.2, unit: unit)

        let seeded = boundLineRate(line: SprayChemical(unit: unit), chosen: chosen)
        // Exactly what the Rate/Ha TextField's setter does with "2.2".
        let typed = unit.toBase(2.2)

        #expect(abs(seeded - typed) < 0.0001)
    }

    // MARK: - D2.1 §A–E: product unit binding integrity
    //
    // A spray line is created with the DEFAULT unit (Litres). Binding a product
    // left that default in place, so the line's unit described the LINE rather
    // than the product it now referred to. Every reader renders through
    // `line.unit` — the Rate/Ha and Vol/Tank fields, `displayRate`,
    // `displayVolume`, `unitLabel`, and the report and CSV writers — so a
    // perfectly correct stored magnitude could print as "2.2 Litres/Ha" for a
    // product sold in kilograms. Right number, wrong substance.

    /// §A — the reported case: a Litres line binding a Kg product.
    @Test("A Litres line adopts Kg when a kilogram product is bound")
    func litresLineAdoptsKilogramProductUnit() {
        let chosen = saved(name: "Dithane", ratePerHa: 2.2, unit: .kilograms)
        let line = bind(chosen, into: SprayChemical(unit: .litres))

        #expect(line.unit == .kilograms)
        #expect(line.unitLabel == "Kg")
        #expect(abs(line.ratePerHa - 2_200) < 0.0001)
        #expect(abs(line.displayRate - 2.2) < 0.0001)
        // The defect it replaces: the right magnitude under the wrong unit.
        #expect(line.unit != .litres)
    }

    /// §B — the mirror: a Kg line binding a Litres product.
    @Test("A Kg line adopts Litres when a litre product is bound")
    func kilogramLineAdoptsLitreProductUnit() {
        let chosen = saved(name: "Liquid Fungicide", ratePerHa: 2.5, unit: .litres)
        let line = bind(chosen, into: SprayChemical(unit: .kilograms))

        #expect(line.unit == .litres)
        #expect(line.unitLabel == "L")
        #expect(abs(line.ratePerHa - 2_500) < 0.0001)
        #expect(abs(line.displayRate - 2.5) < 0.0001)
    }

    /// §C — identity units are still CARRIED, not assumed.
    ///
    /// mL and g need no conversion, but they do need the unit copied: a Litres
    /// line binding a 500 mL/ha product must not keep saying Litres just
    /// because the arithmetic happened to be a no-op.
    @Test("Millilitre and gram products still bind their own unit")
    func identityUnitProductsStillBindTheirUnit() {
        let millilitres = saved(ratePerHa: 500, unit: .millilitres)
        let mlLine = bind(millilitres, into: SprayChemical(unit: .litres))
        #expect(mlLine.unit == .millilitres)
        #expect(mlLine.ratePerHa == 500)
        #expect(abs(mlLine.displayRate - 500) < 0.0001)

        let grams = saved(ratePerHa: 750, unit: .grams)
        let gLine = bind(grams, into: SprayChemical(unit: .kilograms))
        #expect(gLine.unit == .grams)
        #expect(gLine.ratePerHa == 750)
        #expect(abs(gLine.displayRate - 750) < 0.0001)
    }

    /// §D — the structured path keeps its already-base rate AND gains the right
    /// unit. Binding must not re-convert the seed or overwrite it with the
    /// legacy scalar.
    @Test("A structured product binds its unit without touching its base rate")
    func structuredProductBindsUnitWithoutReconverting() throws {
        let chemical = try structuredChemical()
        let selected = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chemical, preferring: .perHectare)
        )
        let seed = try #require(
            SprayRegisteredUseRates.seedValue(
                for: chemical, rateId: selected.id, basis: .perHectare
            )
        )

        // A line already carrying the structured seed, as the calculator sets it.
        var seeded = SprayChemical(unit: .kilograms)
        seeded.ratePerHa = seed
        let line = bind(chemical, into: seeded)

        // Unit corrected...
        #expect(line.unit == .litres)
        // ...rate untouched: the `ratePerHa == 0` guard means the legacy scalar
        // never overwrites a structured seed, and nothing re-converts it.
        #expect(abs(line.ratePerHa - seed) < 0.0001)
        #expect(abs(line.ratePerHa - 1_500) < 0.0001)
        #expect(abs(line.displayRate - 1.5) < 0.0001)
        // Basis is not this gate's business and must be unchanged.
        #expect(line.rateBasis == seeded.rateBasis)
    }

    /// §E — changing product on an existing line moves identity AND unit.
    ///
    /// The stale-unit case is the dangerous one: a line bound to a Kg product
    /// and then re-pointed at a Litres product must not keep saying Kg.
    @Test("Re-binding a line to a different product replaces identity and unit")
    func rebindingReplacesIdentityAndUnit() {
        let solid = saved(name: "Dithane", ratePerHa: 2.2, unit: .kilograms)
        let liquid = saved(name: "Liquid Fungicide", ratePerHa: 2.5, unit: .litres)

        let first = bind(solid, into: SprayChemical(unit: .litres))
        #expect(first.unit == .kilograms)
        #expect(first.savedChemicalId == solid.id)
        #expect(first.name == "Dithane")

        let second = bind(liquid, into: first)
        #expect(second.unit == .litres)
        #expect(second.savedChemicalId == liquid.id)
        #expect(second.name == "Liquid Fungicide")
        #expect(second.unit != first.unit)

        // D2.2 — the solid product's dose does NOT survive into the liquid
        // product; the line states the NEW product's own default instead.
        #expect(abs(second.ratePerHa - 2_500) < 0.0001)
        #expect(abs(second.displayRate - 2.5) < 0.0001)
        #expect(abs(second.ratePerHa - first.ratePerHa) > 1)
    }

    // MARK: - D2.2 §A–G: product re-bind rate integrity
    //
    // A dosage belongs to the product it was established for. The `== 0` guard
    // was written to protect an operator's typed rate, but on a CHANGE OF
    // PRODUCT it protected the wrong thing: Product A's 2.5 L/ha, held as
    // 2500 mL, survived a re-bind to a kilogram product and — once D2.1 began
    // correcting the unit — was re-read as 2.5 kg/ha. One product's dose,
    // presented as another's, in a unit neither of them agreed to.

    /// §A — different products, different units.
    @Test("Re-binding across units seeds the new product's rate, not the old")
    func rebindAcrossUnitsSeedsTheNewProductsRate() {
        let productA = saved(name: "Product A", ratePerHa: 2.5, unit: .litres)
        let productB = saved(name: "Product B", ratePerHa: 1.2, unit: .kilograms)

        let line = bind(productB, into: boundLine(to: productA, baseRate: 2_500))

        #expect(line.unit == .kilograms)
        #expect(abs(line.ratePerHa - 1_200) < 0.0001)
        #expect(abs(line.displayRate - 1.2) < 0.0001)
        // The defect: A's 2500 reinterpreted as 2500 g/ha of B.
        #expect(abs(line.ratePerHa - 2_500) > 1)
    }

    /// §B — different products, SAME unit. No unit change to make the staleness
    /// visible, so this is the case that would have gone unnoticed longest.
    @Test("Re-binding within one unit still replaces the old product's rate")
    func rebindWithinOneUnitStillReplacesTheRate() {
        let productA = saved(name: "Product A", ratePerHa: 2.5, unit: .litres)
        let productB = saved(name: "Product B", ratePerHa: 1.0, unit: .litres)

        let line = bind(productB, into: boundLine(to: productA, baseRate: 2_500))

        #expect(line.unit == .litres)
        #expect(abs(line.ratePerHa - 1_000) < 0.0001)
        #expect(abs(line.displayRate - 1.0) < 0.0001)
        #expect(abs(line.ratePerHa - 2_500) > 1)
    }

    /// §C — the new product states no default. Unset is the honest answer:
    /// an operator typing a rate is a smaller failure than a wrong rate they
    /// had no reason to question.
    @Test("A new product with no default leaves the rate unset, not inherited")
    func newProductWithoutDefaultLeavesRateUnset() {
        let productA = saved(name: "Product A", ratePerHa: 2.5, unit: .litres)
        let productB = saved(name: "Product B", ratePerHa: 0, unit: .kilograms)

        let line = bind(productB, into: boundLine(to: productA, baseRate: 2_500))

        #expect(line.unit == .kilograms)
        #expect(line.ratePerHa == 0)
        #expect(line.displayRate == 0)
    }

    /// §D — the SAME product re-selected. A hand-edited rate is the operator's
    /// decision about this exact product and must not be reverted to the
    /// store's default merely because the picker was reopened.
    @Test("Re-selecting the same product preserves an edited rate")
    func reselectingTheSameProductPreservesAnEditedRate() {
        // Store default is 2.5 L/ha; the operator has typed 1.8 L/ha.
        let product = saved(name: "Product A", ratePerHa: 2.5, unit: .litres)
        let line = bind(product, into: boundLine(to: product, baseRate: 1_800))

        #expect(line.savedChemicalId == product.id)
        #expect(line.unit == .litres)
        #expect(abs(line.ratePerHa - 1_800) < 0.0001)
        #expect(abs(line.displayRate - 1.8) < 0.0001)
        // Explicitly NOT the store default.
        #expect(abs(line.ratePerHa - 2_500) > 1)
    }

    /// §E — solid to liquid. A gram magnitude must not be re-read as millilitres
    /// of a different product.
    @Test("A solid product's base magnitude never becomes a liquid's")
    func solidMagnitudeIsNotReinterpretedAsLiquid() {
        let solid = saved(name: "Dithane", ratePerHa: 2.2, unit: .kilograms)
        let liquid = saved(name: "Liquid Fungicide", ratePerHa: 2.5, unit: .litres)

        let line = bind(liquid, into: boundLine(to: solid, baseRate: 2_200))

        #expect(line.unit == .litres)
        #expect(line.savedChemicalId == liquid.id)
        #expect(abs(line.ratePerHa - 2_500) < 0.0001)
        #expect(abs(line.displayRate - 2.5) < 0.0001)
        // 2200 g must not resurface as 2200 mL (2.2 L/ha) of the liquid.
        #expect(abs(line.ratePerHa - 2_200) > 1)
    }

    /// §F — a structured rate belonging to the NEWLY selected product survives
    /// intact: it is not cleared, not replaced by the legacy scalar, and not
    /// re-converted. Re-selecting the same product is not an identity change.
    @Test("A structured rate for the same product survives re-selection")
    func structuredRateForSameProductSurvivesReselection() throws {
        let chemical = try structuredChemical()
        let selected = try #require(
            SprayRegisteredUseRates.defaultSelection(for: chemical, preferring: .perHectare)
        )
        let seed = try #require(
            SprayRegisteredUseRates.seedValue(
                for: chemical, rateId: selected.id, basis: .perHectare
            )
        )

        let line = bind(chemical, into: boundLine(to: chemical, baseRate: seed))

        #expect(line.unit == .litres)
        #expect(abs(line.ratePerHa - seed) < 0.0001)
        #expect(abs(line.ratePerHa - 1_500) < 0.0001)
        #expect(abs(line.displayRate - 1.5) < 0.0001)
        // Not double-converted, and not overwritten by the legacy 1.5 scalar
        // (which would coincidentally agree here — so assert the seed path
        // stayed base-correct rather than that the number merely matches).
        #expect(abs(line.ratePerHa - chemical.unit.toBase(seed)) > 1_000)
    }

    /// §G — identity, unit and rate all belong to the same chemical afterwards.
    @Test("After an identity change, id, unit and rate share one product")
    func identityUnitAndRateMoveTogether() {
        let productA = saved(name: "Product A", ratePerHa: 2.5, unit: .litres)
        let productB = saved(name: "Product B", ratePerHa: 1.2, unit: .kilograms)

        let line = bind(productB, into: boundLine(to: productA, baseRate: 2_500))

        #expect(line.savedChemicalId == productB.id)
        #expect(line.name == productB.name)
        #expect(line.unit == productB.unit)
        #expect(abs(line.ratePerHa - productB.unit.toBase(productB.ratePerHa)) < 0.0001)

        // Nothing of Product A remains.
        #expect(line.savedChemicalId != productA.id)
        #expect(line.unit != productA.unit)
        #expect(line.name != productA.name)
    }

    /// An UNBOUND line keeps its typed rate when a product is first selected.
    ///
    /// `nil -> chosen` is NOT treated as an identity change: the Rate/Ha field
    /// is editable before a product is picked, so a rate sitting there may be
    /// the operator's own. Pinned so the distinction cannot be erased silently.
    @Test("First binding a product keeps an operator's typed rate")
    func firstBindingKeepsATypedRate() {
        var manual = SprayChemical(unit: .litres)
        manual.ratePerHa = 1_800   // typed as 1.8 L/ha before picking a product
        #expect(manual.savedChemicalId == nil)

        let product = saved(name: "Product A", ratePerHa: 2.5, unit: .litres)
        let line = bind(product, into: manual)

        #expect(line.savedChemicalId == product.id)
        #expect(abs(line.ratePerHa - 1_800) < 0.0001)
    }

    /// Releasing a line back to manual entry clears identity but must NOT reset
    /// the unit — there is no product to take one from, and changing it would
    /// restate the rate on screen.
    @Test("Releasing to manual clears the product but keeps the unit")
    func releasingToManualKeepsTheUnit() {
        let chosen = saved(ratePerHa: 2.2, unit: .kilograms)
        var line = bind(chosen, into: SprayChemical(unit: .litres))

        // The manual branch: only the identifier is cleared.
        line.savedChemicalId = nil

        #expect(line.unit == .kilograms)
        #expect(abs(line.displayRate - 2.2) < 0.0001)
        #expect(line.name == "Legacy Product")
    }
}
