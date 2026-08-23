import Foundation
import Testing
@testable import VineTrack

/// The carrier basis and the product's label rate basis are two different
/// questions, and the device build had merged them.
///
/// A Dithane line showed `Application basis  [100 m — Recommended] [Per ha]`
/// with Per ha greyed out, because the label states `150–200 g/100 L` and no
/// per-hectare grapevine rate. The operator read that as VineTrack refusing to
/// let them spray Dithane on a hectare carrier basis. It never was:
///
/// ```text
/// carrier basis     L/100 m  or  L/ha    how this vineyard measures water
/// label rate basis    /100 L  or   /ha   what the regulator printed
/// ```
///
/// A `150–200 g/100 L` label is dosed the same way from either carrier basis —
/// concentration × dilute carrier litres ÷ 100 — and no per-hectare "registered
/// rate" is ever invented to make a hectare workflow work.
struct SprayCarrierProductBasisTests {

    private let geometry = SprayApplicationGeometry(
        grossAreaHectares: 10,
        totalRowLengthMetres: 25_000,
        uniformRowSpacingMetres: 3,
        source: .mappedRows,
        unresolvedBlocks: []
    )

    // MARK: - 11, 12. Both carrier bases are valid for a per-100 L label

    @Test("100 m carrier with a per-100 L label rate is a valid state")
    func hundredMetreCarrierWithPer100LRate() throws {
        let carrier = try #require(SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 30,
            diluteLitresPer100Metres: 45,
            rowLengthMetres: 25_000,
            rowSpacingMetres: 3
        ))
        #expect(carrier.basis == .litresPer100Metres)
        #expect(carrier.concentrationFactor == 1.5)

        let context = SprayQuantityContext(
            grossAreaHectares: 10,
            carrierLitres: carrier.totalLitres,
            concentrationFactor: carrier.concentrationFactor
        )
        // 175 g/100 L × 7,500 L ÷ 100 × 1.5 = 19,687.5 g
        let total = SprayProductQuantityCalculator.totalQuantity(
            rate: 175,
            basis: .per100Litres,
            context: context
        )
        #expect(total == 19_687.5)
    }

    /// The point of the whole task. The label rate basis does not move.
    @Test("Per ha carrier with a per-100 L label rate is ALSO a valid state")
    func hectareCarrierWithPer100LRate() {
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 750,
            areaHectares: 10,
            concentrationFactor: 1.5
        )
        #expect(carrier.basis == .litresPerHectare)
        #expect(carrier.totalLitres == 7_500)

        let context = SprayQuantityContext(
            grossAreaHectares: 10,
            carrierLitres: carrier.totalLitres,
            concentrationFactor: carrier.concentrationFactor
        )
        let total = SprayProductQuantityCalculator.totalQuantity(
            rate: 175,
            basis: .per100Litres,
            context: context
        )
        // Identical arithmetic, identical answer. The carrier basis decided how
        // the litres were reached, not what the label says.
        #expect(total == 19_687.5)
    }

    // MARK: - 13. Changing carrier basis never rewrites the label

    @Test("The carrier basis preference orders label bases without converting one")
    func carrierPreferenceNeverConvertsALabelRate() {
        #expect(SprayRateBasisPreference.order(for: .litresPer100Metres)
            == [.per100Litres, .perHectare])
        #expect(SprayRateBasisPreference.order(for: .litresPerHectare)
            == [.perHectare, .per100Litres])
        // Both bases appear in BOTH orders. The preference decides which is
        // tried first, never which is allowed — a per-hectare-only product on
        // the 100 m workflow keeps its per-hectare rate.
        for carrier in SprayCarrierBasis.allCases {
            #expect(Set(SprayRateBasisPreference.order(for: carrier))
                == [.per100Litres, .perHectare])
        }
    }

    /// A per-hectare label is measured against hectares no matter how the water
    /// was entered. Nothing reinterprets it as a concentration.
    @Test("A per-hectare label rate ignores carrier litres entirely")
    func perHectareLabelIgnoresCarrier() {
        let context = SprayQuantityContext(
            grossAreaHectares: 10,
            carrierLitres: 7_500,
            concentrationFactor: 3.0
        )
        let total = SprayProductQuantityCalculator.totalQuantity(
            rate: 2.5,
            basis: .wholeBlockArea,
            context: context
        )
        // 2.5 × 10 ha. The 3× concentration is a carrier fact and must not
        // touch an area-rated product.
        #expect(total == 25)
    }

    // MARK: - 15, 16, 17. Dependency-specific unavailable states

    private func line(
        rate: Double,
        basis: SprayProductRateBasis,
        totalQuantity: Double?,
        basisInput: Double? = nil
    ) -> SprayProductLineResult {
        SprayProductLineResult(
            productId: "p",
            name: "DITHANE RAINSHIELD",
            unit: "Kg",
            basis: basis,
            rate: rate,
            totalQuantity: totalQuantity,
            quantityPerFullTank: nil,
            quantityInLastTank: nil,
            costPerUnit: nil,
            basisInput: basisInput
        )
    }

    @Test("A missing applied rate names the RATE, not the block or the carrier")
    func missingRateIsNamedSpecifically() {
        let result = line(rate: 0, basis: .per100Litres, totalQuantity: nil, basisInput: 351)
        #expect(result.unresolvedReason == .rateUnavailable)
        #expect(SprayGuidedFormat.productRequirement(result) == "Product rate required")
        let prompt = try? #require(SprayGuidedFormat.productBlockerPrompt(result))
        #expect(prompt?.contains("range") == true)
    }

    /// The exact device screenshot: `0.0 Kg/100 L × 351 L carrier`. A rate of
    /// zero was never chosen, and no arithmetic was under way.
    @Test("No calculation line is shown while the rate is unresolved")
    func noFabricatedCalculationLine() {
        let result = line(rate: 0, basis: .per100Litres, totalQuantity: nil, basisInput: 351)
        #expect(SprayGuidedFormat.productCalculation(result) == nil)
    }

    @Test("A missing carrier names the canopy / runoff step")
    func missingCarrierNamesCanopy() {
        let result = line(rate: 175, basis: .per100Litres, totalQuantity: nil)
        #expect(result.unresolvedReason == .carrierUnavailable)
        #expect(SprayGuidedFormat.productRequirement(result) == "Carrier volume required")
        let prompt = try? #require(SprayGuidedFormat.productBlockerPrompt(result))
        #expect(prompt?.contains("canopy") == true)
    }

    @Test("A missing treated area is never confused with a missing carrier")
    func missingTreatedAreaIsItsOwnReason() {
        let result = line(rate: 2.5, basis: .treatedArea, totalQuantity: nil)
        #expect(result.unresolvedReason == .treatedAreaUnavailable)
        #expect(SprayGuidedFormat.productRequirement(result) == "Treated area unavailable")
    }

    @Test("Once every required input exists the quantity is shown, not a prompt")
    func resolvedLineShowsTheQuantity() {
        let result = line(
            rate: 175,
            basis: .per100Litres,
            totalQuantity: 19_687.5,
            basisInput: 7_500
        )
        #expect(result.unresolvedReason == nil)
        #expect(SprayGuidedFormat.productBlockerPrompt(result) == nil)
        #expect(SprayGuidedFormat.productRequirement(result).hasSuffix("required"))
        #expect(SprayGuidedFormat.productCalculation(result) != nil)
    }

    // MARK: - 18. The canopy engine is unchanged

    /// P7's routing is frozen. The canopy still supplies dilute, dilute still
    /// divides applied, and the factor still floors at 1.0.
    @Test("100 m carrier still resolves through the existing canopy engine")
    func canopyEngineIsUnchanged() throws {
        let carrier = try #require(SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 30,
            diluteLitresPer100Metres: 45,
            geometry: geometry
        ))
        #expect(carrier.diluteLitresPer100Metres == 45)
        #expect(carrier.appliedLitresPer100Metres == 30)
        #expect(carrier.concentrationFactor == 1.5)
        #expect(carrier.totalLitres == 7_500)
        #expect(carrier.diluteEquivalentLitres == 11_250)

        // A dilute reference BELOW the applied rate is not a concentration.
        let notConcentrated = try #require(SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 60,
            diluteLitresPer100Metres: 45,
            geometry: geometry
        ))
        #expect(notConcentrated.concentrationFactor == 1.0)
    }
}
