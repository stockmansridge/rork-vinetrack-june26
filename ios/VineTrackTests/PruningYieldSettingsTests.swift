import Foundation
import Testing
@testable import VineTrack

/// Cross-platform parity vectors for the Pruning Yield Calculator.
///
/// The SAME input vectors and expected outputs are asserted by
/// `PruningYieldFormulaParityTest.kt` in the Android unit-test source set,
/// so both platforms are pinned to identical formula results
/// (sql/181 shared per-block configuration contract).
struct PruningYieldSettingsTests {

    private let vineyard = UUID()
    private let blockA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private let blockB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

    // MARK: - Formula parity vectors (must match Android exactly)

    @Test func spurVector() {
        let budsPerVine = YieldDeterminationFormula.budsPerVine(
            method: .spur, budsPerSpur: 2, spursPerVine: 6, budsPerCane: 10, canesPerVine: 4
        )
        #expect(budsPerVine == 12)
        let bunchesPerHa = YieldDeterminationFormula.bunchesPerHectare(
            bunchesPerBud: 1.5, budsPerVine: budsPerVine, vinesPerHa: 2000
        )
        #expect(bunchesPerHa == 36_000)
        let kgPerHa = YieldDeterminationFormula.yieldKgPerHectare(bunchesPerHa: bunchesPerHa, bunchWeightGrams: 120)
        #expect(kgPerHa == 4320)
        let tPerHa = YieldDeterminationFormula.yieldTonnesPerHectare(yieldKgPerHa: kgPerHa)
        #expect(tPerHa == 4.32)
        let total = YieldDeterminationFormula.totalYieldTonnes(yieldTonnesPerHa: tPerHa, areaHectares: 1.8)
        #expect(total != nil)
        #expect(abs((total ?? 0) - 7.776) < 1e-9)
    }

    @Test func caneVector() {
        let budsPerVine = YieldDeterminationFormula.budsPerVine(
            method: .cane, budsPerSpur: 2, spursPerVine: 6, budsPerCane: 10, canesPerVine: 4
        )
        #expect(budsPerVine == 40)
        let bunchesPerHa = YieldDeterminationFormula.bunchesPerHectare(
            bunchesPerBud: 1.2, budsPerVine: budsPerVine, vinesPerHa: 1650
        )
        #expect(bunchesPerHa == 79_200)
        let kgPerHa = YieldDeterminationFormula.yieldKgPerHectare(bunchesPerHa: bunchesPerHa, bunchWeightGrams: 95)
        #expect(abs(kgPerHa - 7524) < 1e-9)
        let tPerHa = YieldDeterminationFormula.yieldTonnesPerHectare(yieldKgPerHa: kgPerHa)
        #expect(abs(tPerHa - 7.524) < 1e-9)
        let total = YieldDeterminationFormula.totalYieldTonnes(yieldTonnesPerHa: tPerHa, areaHectares: 2.5)
        #expect(abs((total ?? 0) - 18.81) < 1e-9)
    }

    @Test func zeroAreaHasNoBlockTotal() {
        #expect(YieldDeterminationFormula.totalYieldTonnes(yieldTonnesPerHa: 4.32, areaHectares: 0) == nil)
    }

    // MARK: - Defaults match the shared contract (sql/181 column defaults)

    @Test func canonicalDefaults() {
        let s = PruningYieldSettings(vineyardId: vineyard, paddockId: blockA)
        #expect(s.pruneMethod == "spur")
        #expect(s.bunchesPerBud == 1.5)
        #expect(s.budsPerSpur == 2)
        #expect(s.spursPerVine == 6)
        #expect(s.budsPerCane == 10)
        #expect(s.canesPerVine == 4)
        #expect(s.vinesPerHa == nil)
        #expect(s.bunchWeightGrams == 120)
    }

    // MARK: - Field text round-trip (same convention as Android)

    @Test func inputTextFormatting() {
        #expect(PruningYieldInputFormat.text(2.0) == "2")
        #expect(PruningYieldInputFormat.text(1.5) == "1.5")
        #expect(PruningYieldInputFormat.text(120.0) == "120")
        #expect(PruningYieldInputFormat.text(0.125) == "0.125")
        #expect(PruningYieldInputFormat.text(nil) == "")
        #expect(PruningYieldInputFormat.parse("1,5") == 1.5)
        #expect(PruningYieldInputFormat.parse("junk") == 0)
        #expect(PruningYieldInputFormat.parseOptional("") == nil)
        #expect(PruningYieldInputFormat.parseOptional(" 1800 ") == 1800)
    }

    // MARK: - Per-block independence via value equality

    @Test func inputsEqualIgnoresIdentity() {
        let a = PruningYieldSettings(vineyardId: vineyard, paddockId: blockA, vinesPerHa: 2000)
        var b = PruningYieldSettings(vineyardId: vineyard, paddockId: blockB, vinesPerHa: 2000)
        #expect(a.inputsEqual(to: b))
        b.spursPerVine = 8
        #expect(!a.inputsEqual(to: b))
    }

    // MARK: - Legacy device-local save migrates faithfully

    @Test func legacyConversion() {
        let legacy = LegacyPruningCalculatorSettings(
            pruneMethod: "Cane",
            bunchesPerBud: "1,2",
            budsPerSpur: "2",
            spursPerVine: "6",
            budsPerCane: "12",
            canesPerVine: "3",
            vinesPerHa: "",
            bunchWeight: "95"
        )
        let converted = PruningYieldSettings.fromLegacy(legacy, vineyardId: vineyard, paddockId: blockA)
        #expect(converted.pruneMethod == "cane")
        #expect(converted.bunchesPerBud == 1.2)
        #expect(converted.budsPerCane == 12)
        #expect(converted.canesPerVine == 3)
        #expect(converted.vinesPerHa == nil)
        #expect(converted.bunchWeightGrams == 95)
        #expect(converted.paddockId == blockA)
    }
}
