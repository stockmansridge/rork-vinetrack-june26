import XCTest
@testable import VineTrack

/// The legacy `rate_per_ha` projection contract (sql/222).
///
/// A chemical must never acquire a fabricated rate merely because an old column
/// requires one. Before sql/222 the column was `NOT NULL DEFAULT 0`, so a writer
/// that honestly omitted it got a manufactured `0` — indistinguishable, on read,
/// from a real operator decision.
///
/// Every case below is one way a number could be invented: a range minimum, a
/// maximum, a midpoint, a per-100 L conversion, or a zero. Cases are lettered to
/// match the agreed contract correction, and mirror the Android
/// `ChemicalLegacyRateProjectionTest` one for one.
final class ChemicalLegacyRateProjectionTests: XCTestCase {

    // MARK: - Fixtures

    private func slot(
        value: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        unit: String = "L",
        basis: ChemicalDefaultRateBasis = .perHectare,
        source: String = StoredChemicalDefaultRate.sourceOperator
    ) -> StoredChemicalDefaultRate {
        StoredChemicalDefaultRate(
            optionKey: "default_option_v1_abc",
            rateIds: ["rate_v1_a"],
            basis: basis.rawValue,
            unit: unit,
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            source: source
        )
    }

    private func defaults(
        perHectare: StoredChemicalDefaultRate? = nil,
        per100Litres: StoredChemicalDefaultRate? = nil
    ) -> StoredChemicalDefaultRates {
        StoredChemicalDefaultRates(perHectare: perHectare, per100Litres: per100Litres)
    }

    private func chemical(
        ratePerHa: Double? = nil,
        defaultRates: StoredChemicalDefaultRates? = nil
    ) -> SavedChemical {
        SavedChemical(
            vineyardId: UUID(),
            name: "Stifle",
            ratePerHa: ratePerHa,
            unit: .litres,
            defaultRates: defaultRates
        )
    }

    // MARK: - A: single per-hectare

    func testASingleConfirmedPerHectareRateProjectsThatExactScalar() {
        let c = chemical(defaultRates: defaults(perHectare: slot(value: 2)))
        XCTAssertEqual(c.legacyRatePerHaProjection, 2)
    }

    // MARK: - B: per-hectare range

    func testBAPerHectareRangeProjectsNilNeverABoundOrMidpoint() {
        let c = chemical(defaultRates: defaults(perHectare: slot(minValue: 2, maxValue: 3)))
        let projected = c.legacyRatePerHaProjection
        XCTAssertNil(projected, "a range has no single per-hectare scalar")
        for invented in [0.0, 2.0, 2.5, 3.0] {
            XCTAssertNotEqual(projected, invented, "must not invent \(invented)")
        }
    }

    // MARK: - C: single per-100 L

    func testCASinglePer100LRateProjectsNilAndIsNeverConverted() {
        let c = chemical(defaultRates: defaults(
            per100Litres: slot(value: 2, basis: .per100Litres)
        ))
        XCTAssertNil(
            c.legacyRatePerHaProjection,
            "converting per-100 L to per-hectare needs a job water volume"
        )
    }

    // MARK: - D: the SACOA / Stifle case

    /// The case that motivated the whole correction. `2–3 L/100 L` is a genuine
    /// registered rate with no truthful per-hectare scalar whatsoever.
    func testD2To3LPer100LNeverBecomes0Or2Or3Or2Point5PerHectare() {
        let stored = defaults(
            per100Litres: slot(minValue: 2, maxValue: 3, basis: .per100Litres)
        )
        let projected = chemical(defaultRates: stored).legacyRatePerHaProjection

        XCTAssertNil(projected, "2–3 L/100 L has no per-hectare scalar at all")
        for invented in [0.0, 2.0, 2.5, 3.0] {
            XCTAssertNotEqual(projected, invented, "must not invent \(invented) L/ha")
        }

        // The structured rate itself survives untouched: still a range, still
        // per-100 L, still 2 and 3 — not narrowed, not converted.
        let valid = ChemicalDefaultRateValidity.validSlot(stored, basis: .per100Litres)
        XCTAssertNotNil(valid)
        let range = valid?.range
        XCTAssertNotNil(range, "must remain a range")
        XCTAssertEqual(range?.min, 2)
        XCTAssertEqual(range?.max, 3)
        XCTAssertEqual(valid?.unit, "L")
        XCTAssertEqual(valid?.basis, .per100Litres)
        XCTAssertNil(valid?.scalar, "a range is not a confirmed dose")
    }

    /// A range survives a JSON round-trip without collapsing to a scalar.
    func testDThe2To3LPer100LRangeSurvivesAReloadUnchanged() throws {
        let stored = defaults(
            per100Litres: slot(minValue: 2, maxValue: 3, basis: .per100Litres)
        )
        let data = try JSONEncoder().encode(stored)
        let reloaded = try JSONDecoder().decode(StoredChemicalDefaultRates.self, from: data)

        XCTAssertEqual(reloaded.per100Litres?.minValue, 2)
        XCTAssertEqual(reloaded.per100Litres?.maxValue, 3)
        XCTAssertNil(reloaded.per100Litres?.value, "no midpoint may appear on reload")
        XCTAssertNil(chemical(defaultRates: reloaded).legacyRatePerHaProjection)
    }

    // MARK: - F: unconfirmed rates are not spray-ready

    func testFAnUnnarrowedRangeIsNotAConfirmedDose() {
        let stored = defaults(
            per100Litres: slot(minValue: 2, maxValue: 3, basis: .per100Litres)
        )
        XCTAssertNil(
            ChemicalDefaultRateValidity.confirmedScalar(stored, basis: .per100Litres),
            "the operator must choose a dose inside the registered band"
        )
        // The band itself is still readable, so a picker can present it.
        XCTAssertNotNil(ChemicalDefaultRateValidity.validSlot(stored, basis: .per100Litres))
    }

    func testCAConfirmedSinglePer100LRateStaysOnItsOwnBasis() {
        let stored = defaults(per100Litres: slot(value: 2, basis: .per100Litres))
        let confirmed = ChemicalDefaultRateValidity.confirmedScalar(stored, basis: .per100Litres)
        XCTAssertEqual(confirmed?.scalar, 2)
        XCTAssertEqual(confirmed?.unit, "L")
        XCTAssertEqual(confirmed?.basis, .per100Litres)
        // And it never leaks onto the per-hectare basis.
        XCTAssertNil(ChemicalDefaultRateValidity.confirmedScalar(stored, basis: .perHectare))
    }

    // MARK: - G: stale legacy value must be CLEARED on update

    /// The stale-value case, stated as the sequence that produces it.
    ///
    /// A chemical saved as `2 L/ha` carries `rate_per_ha = 2`. The operator then
    /// changes its authoritative rate to `2–3 L/100 L`. If the writer merely
    /// omitted the column, PostgreSQL would leave the old `2` in place forever.
    func testGChanging2LPerHaToA2To3LPer100LRateClearsTheLegacyScalar() {
        var c = chemical(ratePerHa: 2, defaultRates: defaults(perHectare: slot(value: 2)))
        XCTAssertEqual(c.legacyRatePerHaProjection, 2, "precondition: the legacy value is live")

        // The authoritative edit: per-hectare slot gone, per-100 L range in.
        c.defaultRates = defaults(
            per100Litres: slot(minValue: 2, maxValue: 3, basis: .per100Litres)
        )
        XCTAssertNil(
            c.legacyRatePerHaProjection,
            "the stale 2 must not survive an authoritative rate change"
        )
    }

    func testGChanging2LPerHaToA2To3LPerHaRangeAlsoClearsTheScalar() {
        let c = chemical(
            ratePerHa: 2,
            defaultRates: defaults(perHectare: slot(minValue: 2, maxValue: 3))
        )
        XCTAssertNil(c.legacyRatePerHaProjection)
    }

    func testGChanging2LPerHaTo2Point5LPerHaProjectsTheNewScalar() {
        let c = chemical(ratePerHa: 2, defaultRates: defaults(perHectare: slot(value: 2.5)))
        XCTAssertEqual(c.legacyRatePerHaProjection, 2.5)
    }

    /// A cleared projection has to reach the wire as a literal `null`.
    ///
    /// This is the assertion that would have caught the bug: an upsert that
    /// merely OMITTED the key would leave the stale value in place.
    func testGAClearedProjectionEncodesAsAnExplicitJSONNull() throws {
        let c = chemical(
            ratePerHa: 2,
            defaultRates: defaults(
                per100Litres: slot(minValue: 2, maxValue: 3, basis: .per100Litres)
            )
        )
        let payload = BackendSavedChemical.upsert(from: c, createdBy: nil, clientUpdatedAt: Date())
        XCTAssertNil(payload.ratePerHa.value, "the projection must clear, not carry a stale 2")

        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(payload)
        ) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertTrue(
            json?.keys.contains("rate_per_ha") == true,
            "an omitted key would leave the stale value in place"
        )
        XCTAssertTrue(
            json?["rate_per_ha"] is NSNull,
            "must be an explicit JSON null, not a number"
        )
    }

    func testGAPresentProjectionEncodesAsANumber() throws {
        let c = chemical(ratePerHa: 2, defaultRates: defaults(perHectare: slot(value: 2)))
        let payload = BackendSavedChemical.upsert(from: c, createdBy: nil, clientUpdatedAt: Date())
        XCTAssertEqual(payload.ratePerHa.value, 2)

        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(payload)
        ) as? [String: Any]
        XCTAssertEqual((json?["rate_per_ha"] as? NSNumber)?.doubleValue, 2)
    }

    // MARK: - H: an unrelated edit must not disturb the projection

    func testHEditingNotesOnlyLeavesAValidPerHectareProjectionIntact() {
        var c = chemical(ratePerHa: 2, defaultRates: defaults(perHectare: slot(value: 2)))
        c.notes = "Store in the shed"
        XCTAssertEqual(c.legacyRatePerHaProjection, 2)

        let payload = BackendSavedChemical.upsert(from: c, createdBy: nil, clientUpdatedAt: Date())
        XCTAssertEqual(payload.ratePerHa.value, 2, "an unrelated edit must not clear the legacy value")
    }

    /// An edit that carries NO rate decision leaves the stored default alone.
    func testHAnEditCarryingNoRateDecisionPassesTheLegacyValueThrough() {
        let c = chemical(ratePerHa: 2, defaultRates: nil)
        XCTAssertEqual(c.legacyRatePerHaProjection, 2)
    }

    // MARK: - I: offline / decode

    /// A null column must decode as absent, not as zero. Coercing here would
    /// recreate on the client exactly the fabrication sql/222 removed from the
    /// database — and an offline row would then sync a manufactured 0 back up.
    func testIANullRatePerHaDecodesAsAbsentRatherThanZero() throws {
        let json = """
        {"id":"\(UUID().uuidString)","vineyardId":"\(UUID().uuidString)","name":"Stifle","ratePerHa":null}
        """
        let decoded = try JSONDecoder().decode(SavedChemical.self, from: Data(json.utf8))
        XCTAssertNil(decoded.ratePerHa)
        XCTAssertNotEqual(decoded.ratePerHa, 0, "null must not become 0")
    }

    func testIAMissingRatePerHaDecodesAsAbsentRatherThanZero() throws {
        let json = """
        {"id":"\(UUID().uuidString)","vineyardId":"\(UUID().uuidString)","name":"Stifle"}
        """
        let decoded = try JSONDecoder().decode(SavedChemical.self, from: Data(json.utf8))
        XCTAssertNil(decoded.ratePerHa)
    }

    func testIAnOfflinePer100LChemicalRoundTripsWithTheLegacyFieldNil() throws {
        let offline = chemical(defaultRates: defaults(
            per100Litres: slot(minValue: 2, maxValue: 3, basis: .per100Litres)
        ))
        let data = try JSONEncoder().encode(offline)
        let reloaded = try JSONDecoder().decode(SavedChemical.self, from: data)

        XCTAssertNil(reloaded.ratePerHa, "the cached row must not manufacture a zero")
        XCTAssertNil(reloaded.legacyRatePerHaProjection)
        XCTAssertEqual(reloaded.defaultRates?.per100Litres?.minValue, 2)
        XCTAssertEqual(reloaded.defaultRates?.per100Litres?.maxValue, 3)
    }

    // MARK: - J: historical legacy-only rows

    func testJAHistoricalRowWithOnlyALegacyScalarKeepsWorking() {
        let legacy = chemical(ratePerHa: 2, defaultRates: nil)
        XCTAssertEqual(legacy.legacyRatePerHaProjection, 2)

        let payload = BackendSavedChemical.upsert(
            from: legacy, createdBy: nil, clientUpdatedAt: Date()
        )
        XCTAssertEqual(payload.ratePerHa.value, 2, "saving a legacy chemical must not rewrite it")
    }

    /// Precedence runs authoritative-first. A structured confirmation outranks
    /// the legacy column, never the reverse.
    func testJAStructuredConfirmationOutranksAStaleLegacyScalar() {
        let c = chemical(ratePerHa: 99, defaultRates: defaults(perHectare: slot(value: 2)))
        XCTAssertEqual(c.legacyRatePerHaProjection, 2, "the confirmed rate wins, not the legacy 99")
    }

    func testJALegacyScalarNeverResurrectsAChemicalWhoseRateIsPer100L() {
        let c = chemical(
            ratePerHa: 99,
            defaultRates: defaults(per100Litres: slot(value: 2, basis: .per100Litres))
        )
        XCTAssertNil(
            c.legacyRatePerHaProjection,
            "a per-100 L confirmation means there is no per-hectare scalar"
        )
    }

    // MARK: - Basis and unit are never converted

    func testBasisAndUnitSurviveExactlyAsStored() {
        let stored = defaults(
            per100Litres: slot(value: 250, unit: "mL", basis: .per100Litres)
        )
        let confirmed = ChemicalDefaultRateValidity.confirmedScalar(stored, basis: .per100Litres)
        XCTAssertEqual(confirmed?.scalar, 250)
        XCTAssertEqual(confirmed?.unit, "mL")
        XCTAssertEqual(confirmed?.basis, .per100Litres)
        XCTAssertNil(
            chemical(defaultRates: stored).legacyRatePerHaProjection,
            "250 mL/100 L has no per-hectare projection"
        )
    }

    // MARK: - Malformed rows are never read as confirmed doses

    func testAMalformedSlotIsNeverTreatedAsAConfirmedRate() {
        // A fabricated identity: no minter produces this option key.
        let fakeIdentity = StoredChemicalDefaultRates(perHectare: StoredChemicalDefaultRate(
            optionKey: "manual_rate",
            rateIds: ["user_rate_1"],
            basis: ChemicalDefaultRateBasis.perHectare.rawValue,
            unit: "L",
            value: 2
        ))
        XCTAssertNil(
            ChemicalDefaultRateValidity.validSlot(fakeIdentity, basis: .perHectare),
            "invented rate identities must not validate"
        )
        XCTAssertNil(chemical(defaultRates: fakeIdentity).legacyRatePerHaProjection)
    }

    func testAnInvertedBandIsCorruptNotNarrow() {
        let inverted = defaults(perHectare: slot(minValue: 3, maxValue: 2))
        XCTAssertNil(ChemicalDefaultRateValidity.validSlot(inverted, basis: .perHectare))
        XCTAssertNil(chemical(defaultRates: inverted).legacyRatePerHaProjection)
    }
}
