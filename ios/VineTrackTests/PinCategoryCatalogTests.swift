import Testing
import Foundation
@testable import VineTrack

/// Canonical pin-category colour contract tests — mirrored by Android's
/// `PinCategoryCatalogTest.kt`. The id/colour pairs asserted here MUST stay
/// identical to the Kotlin suite so both platforms render every category the
/// same colour, and unknown/historical categories the same neutral gray.
struct PinCategoryCatalogTests {

    @Test func storedDisplayTextNormalisesToStableCategoryIds() {
        #expect(PinCategoryCatalog.canonicalId(forRaw: "Vine Issue") == PinCategoryCatalog.vineIssue)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "vine-issue") == PinCategoryCatalog.vineIssue)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "  VINE   ISSUE  ") == PinCategoryCatalog.vineIssue)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "Broken Post") == PinCategoryCatalog.brokenPost)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "broken_wire") == PinCategoryCatalog.brokenWire)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "Irrigation") == PinCategoryCatalog.irrigation)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "Other") == PinCategoryCatalog.other)
    }

    @Test func unknownOrMissingCategoriesResolveToNil() {
        #expect(PinCategoryCatalog.canonicalId(forRaw: nil) == nil)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "") == nil)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "   ") == nil)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "Netting") == nil)
        #expect(PinCategoryCatalog.canonicalId(forRaw: "Growth Stage 12") == nil)
    }

    @Test func canonicalColourTokensAreDeterministicPerCategoryId() {
        #expect(PinCategoryCatalog.colorToken(forCanonicalId: PinCategoryCatalog.irrigation) == "blue")
        #expect(PinCategoryCatalog.colorToken(forCanonicalId: PinCategoryCatalog.brokenPost) == "brown")
        #expect(PinCategoryCatalog.colorToken(forCanonicalId: PinCategoryCatalog.vineIssue) == "green")
        #expect(PinCategoryCatalog.colorToken(forCanonicalId: PinCategoryCatalog.brokenWire) == "orange")
        #expect(PinCategoryCatalog.colorToken(forCanonicalId: PinCategoryCatalog.other) == "gray")
    }

    @Test func unknownCategoriesRenderAsUnassignedGray() {
        #expect(PinCategoryCatalog.colorToken(forCanonicalId: nil) == "gray")
        #expect(PinCategoryCatalog.colorToken(forCanonicalId: "mystery_id") == "gray")
        #expect(PinCategoryCatalog.colorToken(forRaw: nil) == "gray")
        #expect(PinCategoryCatalog.colorToken(forRaw: "Netting") == "gray")
    }

    @Test func rawStoredValueResolvesStraightToItsCanonicalColour() {
        #expect(PinCategoryCatalog.colorToken(forRaw: "Vine Issue") == "green")
        #expect(PinCategoryCatalog.colorToken(forRaw: "Broken Post") == "brown")
        #expect(PinCategoryCatalog.colorToken(forRaw: "Broken Wire") == "orange")
        #expect(PinCategoryCatalog.colorToken(forRaw: "irrigation") == "blue")
    }

    @Test func configuredRepairAndGrowthColoursOverrideHistoricalSnapshots() {
        let vineyardID = UUID()
        let repairID = UUID()
        let growthID = UUID()
        let repair = VinePin(
            vineyardId: vineyardID, latitude: -34, longitude: 138, heading: nil,
            buttonName: "Vine Issue", buttonColor: "green", launcherButtonId: repairID,
            side: .left, mode: .repairs
        )
        let growth = VinePin(
            vineyardId: vineyardID, latitude: -34, longitude: 138, heading: nil,
            buttonName: "Powdery", buttonColor: "gray", launcherButtonId: growthID,
            side: .right, mode: .growth
        )
        let repairs = [ButtonConfig(id: repairID, vineyardId: vineyardID, name: "Renamed issue", color: "yellow", index: 0, mode: .repairs)]
        let growths = [ButtonConfig(id: growthID, vineyardId: vineyardID, name: "Powdery", color: "pink", index: 0, mode: .growth)]
        #expect(PinColorResolver.token(for: repair, repairButtons: repairs, growthButtons: growths) == "yellow")
        #expect(PinColorResolver.token(for: growth, repairButtons: repairs, growthButtons: growths) == "pink")
    }

    @Test func legacyAndVineyardScopedFallbacksAreSafe() {
        let vineyardA = UUID()
        let vineyardB = UUID()
        let pin = VinePin(
            vineyardId: vineyardA, latitude: -34, longitude: 138, heading: nil,
            buttonName: "Custom A", buttonColor: "purple", side: .left, mode: .repairs
        )
        let wrongVineyard = [ButtonConfig(vineyardId: vineyardB, name: "Custom A", color: "blue", index: 0, mode: .repairs)]
        #expect(PinColorResolver.token(for: pin, repairButtons: wrongVineyard, growthButtons: []) == "purple")
    }

    @Test func allTokensUseTheExactSharedHexContract() {
        let expected: [String: UInt32] = [
            "red": 0xFF3B30, "orange": 0xFF9500, "yellow": 0xFFCC00,
            "green": 0x34C759, "darkgreen": 0x1B7F3B, "mint": 0x00C7BE,
            "teal": 0x30B0C7, "cyan": 0x32ADE6, "blue": 0x007AFF,
            "indigo": 0x5856D6, "purple": 0xAF52DE, "pink": 0xFF2D55,
            "brown": 0xA2845E, "gray": 0x8E8E93, "black": 0x000000,
            "white": 0xFFFFFF,
        ]
        #expect(PinColorTokenContract.hexByToken == expected)
        #expect(PinColorTokenContract.normalized("grey") == "gray")
    }

    @Test func historicalPinsWithoutACategoryDisplayAsUnassigned() {
        let orphan = VinePin(
            latitude: -34.0, longitude: 138.0, heading: nil,
            buttonName: "", buttonColor: "",
            side: .left, mode: .repairs, timestamp: Date()
        )
        #expect(orphan.displayColorToken == "gray")
        #expect(orphan.displayNameOrUnassigned == "Unassigned")
    }
}
