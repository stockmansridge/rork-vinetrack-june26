import Foundation
import Testing
@testable import VineTrack

/// The withholding-period display rule (P2A).
///
/// The resolver only ever parses a label's "NOT REQUIRED WHEN USED AS
/// DIRECTED" statement to 0 days — it never derives 0 from anything else. So
/// the friendly wording may appear ONLY when that label evidence is present:
/// either the use's own verbatim statements carry the phrase, or the payload
/// cites the manufacturer's approved label as a source. Every other value
/// renders exactly as before, and a missing value stays missing.
struct ChemicalWithholdingDisplayTests {

    // MARK: - Label-backed zero (Sprayseal 80160)

    @Test func labelSourcedZeroReadsNotRequired() {
        // Sprayseal 80160: WHP "NOT REQUIRED WHEN USED AS DIRECTED" is served
        // as 0 days with manufacturer_label provenance end to end.
        #expect(
            ChemicalWithholdingDisplay.text(
                days: 0,
                restrictions: "Shake or stir container well before use.",
                hasManufacturerLabelSource: true
            ) == "Not required when used as directed"
        )
    }

    @Test func cropScopedNotRequiredWordingReadsNotRequired() {
        // A crop-scoped label statement carries the phrase verbatim inside the
        // use's own restrictions, even without checking the source list.
        #expect(
            ChemicalWithholdingDisplay.text(
                days: 0,
                restrictions: "ALMONDS: NOT REQUIRED WHEN USED AS DIRECTED.",
                hasManufacturerLabelSource: false
            ) == "Not required when used as directed"
        )
    }

    // MARK: - Zero without label evidence stays a plain count

    @Test func unevidencedZeroStaysZeroDays() {
        // An operator-typed manual zero has no label wording behind it: the
        // friendly wording would be fabricated evidence.
        #expect(
            ChemicalWithholdingDisplay.text(
                days: 0,
                restrictions: nil,
                hasManufacturerLabelSource: false
            ) == "0 days"
        )
        #expect(
            ChemicalWithholdingDisplay.text(
                days: 0,
                restrictions: "Do not graze treated vines.",
                hasManufacturerLabelSource: false
            ) == "0 days"
        )
    }

    // MARK: - Stated day counts are never converted (Custodia Forte 91636)

    @Test func statedDaysRenderUnchanged() {
        // Custodia Forte's 28-day grape WHP stays 28 days even though the
        // payload is label-sourced.
        #expect(
            ChemicalWithholdingDisplay.text(
                days: 28,
                restrictions: "GRAPEVINE: DO NOT HARVEST FOR 28 DAYS AFTER APPLICATION.",
                hasManufacturerLabelSource: true
            ) == "28 days"
        )
        // Even the phrase appearing elsewhere in the statements never
        // overrides a stated number.
        #expect(
            ChemicalWithholdingDisplay.text(
                days: 14,
                restrictions: "Grazing: not required when used as directed.",
                hasManufacturerLabelSource: true
            ) == "14 days"
        )
    }

    // MARK: - Unresolved stays unresolved

    @Test func missingWithholdingStaysMissing() {
        // No wording and no source flag can ever invent a withholding period.
        #expect(
            ChemicalWithholdingDisplay.text(
                days: nil,
                restrictions: "GRAPEVINE: NOT REQUIRED WHEN USED AS DIRECTED.",
                hasManufacturerLabelSource: true
            ) == nil
        )
        #expect(
            ChemicalWithholdingDisplay.text(
                days: nil,
                restrictions: nil,
                hasManufacturerLabelSource: false
            ) == nil
        )
    }
}
