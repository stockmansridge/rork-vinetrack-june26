import Foundation
import Testing
@testable import VineTrack

struct SprayProductAreaInheritanceTests {
    @Test("A banded spray inherits its selected treated hectares")
    func bandedDefaultsToTreated() {
        #expect(SprayProductRateBasis.forCurrentApplication(
            isBanded: true, carrierAreaBasis: .treatedArea,
            explicitProductChoice: nil) == .treatedArea)
    }

    @Test("A deliberate whole-block water-area selection also carries forward")
    func bandedGrossChoice() {
        #expect(SprayProductRateBasis.forCurrentApplication(
            isBanded: true, carrierAreaBasis: .wholeBlockArea,
            explicitProductChoice: nil) == .wholeBlockArea)
    }

    @Test("A label-specific per-product override wins over inherited band choice")
    func lineOverrideWins() {
        #expect(SprayProductRateBasis.forCurrentApplication(
            isBanded: true, carrierAreaBasis: .treatedArea,
            explicitProductChoice: .wholeBlockArea) == .wholeBlockArea)
    }

    @Test("Ordinary whole-block sprays remain rated against gross hectares")
    func wholeBlockUnchanged() {
        #expect(SprayProductRateBasis.forCurrentApplication(
            isBanded: false, carrierAreaBasis: .treatedArea,
            explicitProductChoice: nil) == .wholeBlockArea)
    }

    @Test("Treated-area and whole-block rate produce different quantities")
    func quantityUsesAreaBasis() {
        let context = SprayQuantityContext(
            grossAreaHectares: 6.15,
            treatedAreaHectares: 2.21,
            carrierLitres: 615,
            concentrationFactor: 1
        )
        let gross = SprayProductQuantityCalculator.totalQuantity(rate: 3.2, basis: .wholeBlockArea, context: context)
        let band = SprayProductQuantityCalculator.totalQuantity(rate: 3.2, basis: .treatedArea, context: context)
        #expect(abs((gross ?? 0) - 19.68) < 0.001)
        #expect(abs((band ?? 0) - 7.072) < 0.001)
    }
}
