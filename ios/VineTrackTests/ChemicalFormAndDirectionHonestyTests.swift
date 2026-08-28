import Foundation
import Testing

@testable import VineTrack

/// P2C Chemical Search release — the customer-visible honesty rules.
///
/// Anchored on THIOVIT JET (APVMA 53904): a sulfur MICROGRANULE, 800 g/kg,
/// FRAC M2, whose grapevine Powdery Mildew directions are printed twice —
/// 100–200 g/100 L for table and drying grapes, 200–600 g/100 L for wine
/// grapes — both conditioned "NSW, Vic, Tas, SA, WA only".
///
/// Two ways the app could lie about that product, both pinned here:
///
///   1. describing a SOLID as a Liquid measured in L, because a rate happens
///      to be quoted in `g/100 L` or because no form arrived at all;
///   2. merging the two PM directions into a single 100–600 g/100 L range,
///      which is a rate no label ever registered.
struct ChemicalFormAndDirectionHonestyTests {

    // MARK: - Helpers

    private func lookup(formType: String?) -> ChemicalInfoResponse {
        ChemicalInfoResponse(
            activeIngredient: "Sulfur As Elemental Sulfur",
            brand: "THIOVIT JET MICROGRANULE FUNGICIDE/MITICIDE",
            chemicalGroup: "M2",
            labelURL: "",
            productURL: nil,
            sdsURL: nil,
            primaryUse: "Fungicide/Miticide",
            ratesPerHectare: nil,
            ratesPer100L: nil,
            formType: formType,
            modeOfAction: nil
        )
    }

    private func decodeUse(_ json: String) throws -> ChemicalRegisteredUse {
        try JSONDecoder().decode(ChemicalRegisteredUse.self, from: Data(json.utf8))
    }

    /// The two grapevine PM directions as the repaired backend serves them:
    /// distinct crops, distinct `direction_id`s, the state condition on
    /// `rates[].label` (contract v1 carries it there and nowhere else).
    private var thiovitPowderyMildewDirections: String {
        """
        [
          {
            "crop": "Grapes table grapes, fruit destined for drying",
            "target_raw": "Powdery Mildew",
            "direction_id": "dir-table-drying",
            "withholding_period_days": 0,
            "restrictions": "Apply every 10 to 14 days",
            "rates": [{
              "label": "NSW, Vic, Tas, SA, WA only",
              "basis": "range_per_100_litres",
              "min_value": 100, "max_value": 200, "unit": "g",
              "rate_id": "rate-table-drying-pm"
            }]
          },
          {
            "crop": "Grapes wine grapes",
            "target_raw": "Powdery Mildew",
            "direction_id": "dir-wine",
            "withholding_period_days": 0,
            "restrictions": "Apply every 14 to 21 days",
            "rates": [{
              "label": "NSW, Vic, Tas, SA, WA only",
              "basis": "range_per_100_litres",
              "min_value": 200, "max_value": 600, "unit": "g",
              "rate_id": "rate-wine-pm"
            }]
          }
        ]
        """
    }

    private func decodeDirections() throws -> [ChemicalRegisteredUse] {
        try JSONDecoder().decode(
            [ChemicalRegisteredUse].self,
            from: Data(thiovitPowderyMildewDirections.utf8)
        )
    }

    // MARK: - §1 Form is never invented

    @Test("A stated solid form stays solid and never becomes a liquid")
    func solidStaysSolid() {
        #expect(lookup(formType: "solid").isLiquid == false)
        #expect(lookup(formType: "solid").defaultUnit == .kilograms)
        // The register's own word for 53904, straight from PubCRIS `fdesc`.
        #expect(lookup(formType: "MICROGRANULE").isLiquid == false)
        #expect(lookup(formType: "MICROGRANULE").defaultUnit == .kilograms)
        #expect(lookup(formType: "water dispersible granule").isLiquid == false)
    }

    @Test("An UNSTATED form stays unknown — it never defaults to Liquid or L")
    func unknownFormIsNotLiquid() {
        // The bug this pins: `nil` used to mean `true`, so a product whose
        // form failed to arrive was described to a grower as a Liquid and
        // measured in litres. Absence of evidence is not evidence of liquid.
        #expect(lookup(formType: nil).isLiquid == nil)
        #expect(lookup(formType: nil).defaultUnit == nil)
        #expect(lookup(formType: "").isLiquid == nil)
        #expect(lookup(formType: "").defaultUnit == nil)
        // An unrecognised formulation word is equally not a liquid claim.
        #expect(lookup(formType: "microencapsulated something").isLiquid == nil)
    }

    @Test("A genuinely liquid form still resolves to liquid and litres")
    func liquidStillWorks() {
        #expect(lookup(formType: "liquid").isLiquid == true)
        #expect(lookup(formType: "suspension concentrate").isLiquid == true)
        #expect(lookup(formType: "emulsifiable concentrate").isLiquid == true)
        #expect(lookup(formType: "liquid").defaultUnit == .litres)
    }

    @Test("A g/100 L rate never makes the PRODUCT a liquid")
    func rateUnitDoesNotDecideForm() throws {
        // Every Thiovit rate is quoted in grams per 100 litres of water. The
        // litres belong to the spray tank, not to the product, and the grams
        // are an application quantity, not a pack size.
        let directions = try decodeDirections()
        let units = Set(directions.flatMap(\.rates).map(\.unit))
        #expect(units == ["g"])
        // Form comes from the register, and stays solid regardless.
        #expect(lookup(formType: "solid").isLiquid == false)
        #expect(lookup(formType: "solid").defaultUnit == .kilograms)
    }

    @Test("Form, inventory unit, concentration unit and rate unit stay four separate facts")
    func fiveMeasurementConceptsStaySeparate() throws {
        let solid = lookup(formType: "solid")
        #expect(solid.isLiquid == false)          // physical form
        #expect(solid.defaultUnit == .kilograms)  // inventory/container unit
        #expect(solid.activeIngredient == "Sulfur As Elemental Sulfur")
        // Application-rate unit and basis, read from the directions only.
        let rate = try #require(try decodeDirections().first?.rates.first)
        #expect(rate.unit == "g")
        #expect(rate.basis == .rangePer100Litres)
        // The rate unit and the inventory unit are deliberately different.
        #expect(rate.unit != solid.defaultUnit?.labelRateToken)
    }

    // MARK: - §2 The two Powdery Mildew directions stay distinct

    @Test("Both grapevine PM directions survive decoding as separate uses")
    func bothDirectionsSurvive() throws {
        let directions = try decodeDirections()
        #expect(directions.count == 2)
        #expect(directions.allSatisfy { $0.targetRaw == "Powdery Mildew" })
        #expect(directions.allSatisfy { $0.target == .powderyMildew })
        // Same target, DIFFERENT crop context — the fact that distinguishes
        // them. A crop+target key alone would collapse these two into one.
        #expect(Set(directions.map(\.crop)).count == 2)
    }

    @Test("Direction identity is distinct and survives the wire")
    func directionIdentityIsDistinct() throws {
        let ids = try decodeDirections().compactMap(\.directionId)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        let rateIds = try decodeDirections().flatMap(\.rates).compactMap(\.rateId)
        #expect(Set(rateIds).count == 2)
    }

    @Test("The two ranges NEVER merge into 100–600 g/100 L")
    func rangesNeverMerge() throws {
        let rates = try decodeDirections().flatMap(\.rates)
        #expect(rates.count == 2)

        let table = try #require(rates.first { $0.minValue == 100 })
        #expect(table.maxValue == 200)
        let wine = try #require(rates.first { $0.minValue == 200 })
        #expect(wine.maxValue == 600)

        // 100–600 is a rate no label registered: it would let a grower apply
        // 600 g/100 L to table grapes, three times their registered maximum.
        #expect(!rates.contains { $0.minValue == 100 && $0.maxValue == 600 })
    }

    @Test("The state condition wording survives on rate.label (contract v1)")
    func conditionWordingSurvivesOnLabel() throws {
        // v1 has no direction-level `condition` key; `label` is its only home,
        // and it is what tells a grower which direction they are reading.
        for rate in try decodeDirections().flatMap(\.rates) {
            #expect(rate.label == "NSW, Vic, Tas, SA, WA only")
        }
    }

    @Test("An unknown direction-level key does not break decoding")
    func unknownKeysAreTolerated() throws {
        // Forward compatibility: if a future v2 server adds `condition`, a
        // shipping client must keep decoding rather than dropping the use.
        let use = try decodeUse("""
        {
          "crop": "Grapes wine grapes",
          "target_raw": "Powdery Mildew",
          "condition": "NSW, Vic, Tas, SA, WA only",
          "rates": [{
            "label": "NSW, Vic, Tas, SA, WA only",
            "basis": "range_per_100_litres",
            "min_value": 200, "max_value": 600, "unit": "g"
          }]
        }
        """)
        #expect(use.crop == "Grapes wine grapes")
        #expect(use.rates.first?.minValue == 200)
        #expect(use.rates.first?.label == "NSW, Vic, Tas, SA, WA only")
    }

    // MARK: - §3 WHP / REI honesty

    @Test("A zero WHP is preserved as a real answer, not lost as 'unstated'")
    func whpZeroIsPreserved() throws {
        // Thiovit's label says "NOT REQUIRED WHEN USED AS DIRECTED", which
        // projects to 0 days. 0 and nil are different answers and must not
        // collapse into each other.
        for direction in try decodeDirections() {
            #expect(direction.withholdingPeriodDays == 0)
        }
    }

    @Test("REI stays unresolved — never inferred as zero")
    func reiStaysUnresolved() throws {
        for direction in try decodeDirections() {
            #expect(direction.reEntryPeriodHours == nil)
            #expect(direction.reEntryStatement == nil)
        }
    }

    @Test("Each direction keeps only its OWN restrictions")
    func restrictionsDoNotBleed() throws {
        let directions = try decodeDirections()
        let table = try #require(directions.first { $0.crop.contains("table") })
        let wine = try #require(directions.first { $0.crop.contains("wine") })
        #expect(table.restrictions == "Apply every 10 to 14 days")
        #expect(wine.restrictions == "Apply every 14 to 21 days")
        #expect(table.restrictions != wine.restrictions)
    }
}
