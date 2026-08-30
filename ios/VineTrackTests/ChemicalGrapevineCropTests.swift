import Foundation
import Testing
@testable import VineTrack

/// The vineyard-only partition rule.
///
/// The Chemical Store must contain the grapevine label and nothing else. That
/// depends entirely on one predicate answering "is this crop grapevines?", and
/// the predicate must give the SAME answer as the server, which is what decides
/// which directions land in `grapevine_uses`.
///
/// The rule that matters most is the negative one. `"GRAPEFRUIT"` contains
/// `"grape"`, so a substring test classifies a citrus as a grapevine and offers
/// its rate as a vineyard default — a wrong dose wearing a plausible name,
/// which is far worse than a visible gap.
struct ChemicalGrapevineCropTests {

    @Test("Grapefruit is never a grapevine", arguments: [
        "GRAPEFRUIT",
        "Grapefruit",
        "Grapefruit trees",
        "Citrus (grapefruit)",
        "grapefruit, oranges and lemons"
    ])
    func grapefruitIsNeverGrapevine(_ crop: String) {
        #expect(ChemicalGrapevineCrop.matches(crop) == false)
    }

    @Test("Genuine grapevine wordings are recognised", arguments: [
        "Grapes",
        "GRAPES",
        "Grapevine",
        "Grapevines",
        "Vines",
        "Vineyard",
        "Wine grapes",
        "Table grapes",
        "Dried grapes",
        "Grape vines",
        "Winegrapes",
        "Grapes (wine)"
    ])
    func grapevineWordingsAreRecognised(_ crop: String) {
        #expect(ChemicalGrapevineCrop.matches(crop) == true)
    }

    @Test("Other crops are not grapevines", arguments: [
        "Apples",
        "Pome fruit",
        "Citrus",
        "Almonds",
        "Peaches",
        "Stone fruit",
        "Bananas",
        "",
        "   "
    ])
    func otherCropsAreNotGrapevines(_ crop: String) {
        #expect(ChemicalGrapevineCrop.matches(crop) == false)
    }

    /// A bare "wine" or "dried" must not pass on its own — only the adjacent
    /// pair with "grape"/"grapes" does.
    @Test("Phrase halves do not match alone")
    func phraseHalvesDoNotMatchAlone() {
        #expect(ChemicalGrapevineCrop.matches("Wine") == false)
        #expect(ChemicalGrapevineCrop.matches("Dried fruit") == false)
        #expect(ChemicalGrapevineCrop.matches("Table olives") == false)
    }

    /// The registered-use partition is what the whole vineyard-only workflow
    /// rests on, so it is asserted through the real model, not just the helper.
    @Test("A grapefruit direction never enters the grapevine partition")
    func grapefruitDirectionIsNotViticultural() {
        let grapefruit = ChemicalRegisteredUse(
            crop: "Grapefruit",
            targetRaw: "Scale",
            rates: [
                ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L", rateId: "rate_v1_citrus")
            ]
        )
        let grapevine = ChemicalRegisteredUse(
            crop: "Grapevines",
            targetRaw: "Powdery mildew",
            rates: [
                ChemicalLabelRate(basis: .perHectare, value: 1, unit: "L", rateId: "rate_v1_vine")
            ]
        )
        #expect(grapefruit.isViticultural == false)
        #expect(grapevine.isViticultural == true)

        let partition = [grapefruit, grapevine].viticultural
        #expect(partition.count == 1)
        #expect(partition.first?.crop == "Grapevines")
    }

    /// A citrus rate must never be offered as a vineyard default, which is the
    /// operational consequence of the rule above.
    @Test("A citrus rate is never a vineyard default option")
    func citrusRateIsNeverADefaultOption() {
        let grapefruit = ChemicalRegisteredUse(
            crop: "Grapefruit",
            targetRaw: "Scale",
            rates: [
                ChemicalLabelRate(basis: .perHectare, value: 99, unit: "L", rateId: "rate_v1_citrus")
            ]
        )
        let grapevineOnly = [grapefruit].viticultural
        let options = ChemicalDefaultRate.options(.perHectare, from: grapevineOnly)
        #expect(options.isEmpty)
    }
}
