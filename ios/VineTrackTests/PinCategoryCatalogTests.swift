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

    @Test func repairsPinsDisplayCanonicalColoursRegardlessOfStoredToken() {
        // Two "Vine Issue" pins with different stored colours must render
        // identically — the canonical category colour, not the stored token.
        let a = VinePin(
            latitude: -34.0, longitude: 138.0, heading: nil,
            buttonName: "Vine Issue", buttonColor: "red",
            side: .left, mode: .repairs, timestamp: Date()
        )
        let b = VinePin(
            latitude: -34.0, longitude: 138.0, heading: nil,
            buttonName: "Vine Issue", buttonColor: "green",
            side: .right, mode: .repairs, timestamp: Date()
        )
        #expect(a.displayColorToken == "green")
        #expect(b.displayColorToken == "green")
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
