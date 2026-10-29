import Foundation
import Testing
@testable import VineTrack

struct SprayFixedRateMismatchTests {
    @Test("A manually typed dose differing from a fixed label direction gets an explicit warning")
    func fixedRateMismatch() {
        let rate = SpraySelectableRate(
            id: UUID(), origin: .registeredUse, crop: "Grapevines",
            targetRaw: "Suckers", label: "Spotlight Plus",
            basis: .per100Litres, seed: .value(300),
            displayText: "300 mL/100 L", labelUnit: "mL")
        #expect(SprayLabelRangeCheck.warning(appliedBaseValue: 140, rate: rate)?.contains("300 mL/100 L") == true)
        #expect(SprayLabelRangeCheck.warning(appliedBaseValue: 300, rate: rate) == nil)
    }
}
