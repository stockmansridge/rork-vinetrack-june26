import XCTest
@testable import VineTrack

/// The user-confirmed manual rate contract.
///
/// A rate the operator typed because the label reader could not extract one is
/// real VineTrack data once they confirm it. It must be usable in Spray Program
/// WITHOUT acquiring a fabricated official identity, and must stay permanently
/// distinguishable from a registered label direction.
///
/// The mirror of Android `ChemicalManualRateContractTest`.
final class ChemicalManualRateContractTests: XCTestCase {

    // MARK: - Fixtures

    private func canonicalSlot(
        value: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        unit: String = "L",
        basis: ChemicalDefaultRateBasis = .perHectare
    ) -> StoredChemicalDefaultRate {
        StoredChemicalDefaultRate(
            optionKey: "default_option_v1_abc",
            rateIds: ["rate_v1_a"],
            basis: basis.rawValue,
            unit: unit,
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            source: StoredChemicalDefaultRate.sourceOperator
        )
    }

    private func defaults(
        perHectare: StoredChemicalDefaultRate? = nil,
        per100Litres: StoredChemicalDefaultRate? = nil
    ) -> StoredChemicalDefaultRates {
        StoredChemicalDefaultRates(perHectare: perHectare, per100Litres: per100Litres)
    }

    private func chemical(_ defaults: StoredChemicalDefaultRates?) -> SavedChemical {
        SavedChemical(vineyardId: UUID(), name: "Stifle", unit: .litres, defaultRates: defaults)
    }

    /// The SACOA/Stifle case: 2–3 L/100 L, typed and confirmed by the operator.
    private func manualRange() -> StoredChemicalDefaultRate {
        .manual(basis: .per100Litres, unit: "L", minValue: 2, maxValue: 3)
    }

    private func manualScalar() -> StoredChemicalDefaultRate {
        .manual(basis: .per100Litres, unit: "L", value: 2)
    }

    // MARK: - No fabricated official identity

    func testAManualRateCarriesNoOfficialIdentityAtAll() throws {
        let slot = manualRange()
        XCTAssertEqual(slot.optionKey, "")
        XCTAssertTrue(slot.rateIds.isEmpty)
        XCTAssertTrue(slot.isManualEntry)

        let encoded = String(decoding: try JSONEncoder().encode(slot), as: UTF8.self)
        for fake in ["default_option_v1_", "rate_v1_", "manual_rate", "user_rate", "custom"] {
            XCTAssertFalse(encoded.contains(fake), "must not mint \(fake): \(encoded)")
        }
    }

    func testAManualRateValidatesDespiteHavingNoOptionKeyOrRateIds() {
        let valid = ChemicalDefaultRateValidity.validSlot(
            defaults(per100Litres: manualRange()),
            basis: .per100Litres
        )
        XCTAssertNotNil(valid, "a user-confirmed rate must be believable")
        XCTAssertTrue(valid?.isManualEntry == true)
        XCTAssertTrue(valid?.isConfirmedByOperator == true)
    }

    /// A row claiming to be manual while carrying a citation contradicts itself.
    func testAManualRowCarryingAnOfficialCitationIsRejected() {
        var contradictory = manualRange()
        contradictory.optionKey = "default_option_v1_abc"
        contradictory.rateIds = ["rate_v1_a"]
        XCTAssertNil(
            ChemicalDefaultRateValidity.validSlot(
                defaults(per100Litres: contradictory),
                basis: .per100Litres
            )
        )
    }

    // MARK: - Scalar: saves, reloads, prefills

    func testAUserConfirmedScalarSavesReloadsAndPrefillsSprayProgram() throws {
        let stored = defaults(per100Litres: manualScalar())
        let reloaded = try JSONDecoder().decode(
            StoredChemicalDefaultRates.self,
            from: try JSONEncoder().encode(stored)
        )

        let resolution = ChemicalSprayRateHandoff.resolution(reloaded)
        let prefill = try XCTUnwrap(resolution?.prefill)
        XCTAssertEqual(prefill.rate, 2)
        XCTAssertEqual(prefill.unit, "L")
        XCTAssertEqual(prefill.basis, .per100Litres)
        XCTAssertTrue(prefill.isUserEntered, "provenance must survive the round trip")
        XCTAssertTrue(ChemicalSprayRateHandoff.isSprayReady(reloaded))
    }

    // MARK: - Range: spray-ready, but requires an in-range choice

    func testAUserConfirmedRangeIsSprayReadyButRequiresAChosenDose() throws {
        let stored = defaults(per100Litres: manualRange())

        XCTAssertTrue(
            ChemicalSprayRateHandoff.isSprayReady(stored),
            "a confirmed band must no longer read as 'confirmation required'"
        )

        let resolution = ChemicalSprayRateHandoff.resolution(stored)
        let selection = try XCTUnwrap(resolution?.rangeSelection)
        XCTAssertEqual(selection.min, 2)
        XCTAssertEqual(selection.max, 3)
        XCTAssertEqual(selection.unit, "L")
        XCTAssertEqual(selection.basis, .per100Litres)
        XCTAssertTrue(selection.isUserEntered)

        // Nothing is prefilled: choosing 2, 3 or 2.5 would be deciding the dose
        // on the operator's behalf.
        XCTAssertNil(ChemicalSprayRateHandoff.prefill(stored))
        XCTAssertNil(resolution?.prefill)
    }

    func testAChosenDoseIsValidatedAgainstTheConfirmedBand() throws {
        let stored = defaults(per100Litres: manualRange())
        let selection = try XCTUnwrap(ChemicalSprayRateHandoff.resolution(stored)?.rangeSelection)

        XCTAssertEqual(
            ChemicalSprayRateHandoff.validateApplicationRate(2.5, in: selection).acceptedValue,
            2.5
        )
        // Both bounds are legal doses of the direction.
        XCTAssertTrue(ChemicalSprayRateHandoff.validateApplicationRate(2, in: selection).isAccepted)
        XCTAssertTrue(ChemicalSprayRateHandoff.validateApplicationRate(3, in: selection).isAccepted)

        XCTAssertEqual(
            ChemicalSprayRateHandoff.validateApplicationRate(1.9, in: selection),
            .belowMinimum(min: 2)
        )
        XCTAssertEqual(
            ChemicalSprayRateHandoff.validateApplicationRate(3.1, in: selection),
            .aboveMaximum(max: 3)
        )
        XCTAssertEqual(
            ChemicalSprayRateHandoff.validateApplicationRate(nil, in: selection),
            .notANumber
        )
        XCTAssertEqual(
            ChemicalSprayRateHandoff.validateApplicationRate(0, in: selection),
            .notANumber
        )
    }

    // MARK: - The range never collapses

    func testA2To3LPer100LBandNeverCollapsesToMinMaxOrMidpoint() throws {
        let stored = defaults(per100Litres: manualRange())
        let reloaded = try JSONDecoder().decode(
            StoredChemicalDefaultRates.self,
            from: try JSONEncoder().encode(stored)
        )
        XCTAssertEqual(reloaded.per100Litres?.minValue, 2)
        XCTAssertEqual(reloaded.per100Litres?.maxValue, 3)
        XCTAssertNil(reloaded.per100Litres?.value, "no scalar may appear")

        let projected = chemical(reloaded).legacyRatePerHaProjection
        XCTAssertNil(projected)
        for invented in [0.0, 2.0, 2.5, 3.0] {
            XCTAssertNotEqual(projected, invented)
        }
    }

    func testAPer100LManualRateNeverMigratesOntoThePerHectareBasis() {
        let stored = defaults(per100Litres: manualRange())
        XCTAssertNil(ChemicalDefaultRateValidity.validSlot(stored, basis: .perHectare))
        let resolutions = ChemicalSprayRateHandoff.resolutions(stored)
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions.first?.basis, .per100Litres)
    }

    // MARK: - Existing canonical behaviour is unchanged

    func testACanonicalScalarStillPrefillsAndIsNotMarkedUserEntered() throws {
        let stored = defaults(perHectare: canonicalSlot(value: 2))
        let prefill = try XCTUnwrap(ChemicalSprayRateHandoff.prefill(stored))
        XCTAssertEqual(prefill.rate, 2)
        XCTAssertFalse(prefill.isUserEntered, "a label rate is not user-entered")
        XCTAssertEqual(chemical(stored).legacyRatePerHaProjection, 2)
    }

    func testACanonicalRowMissingItsIdentityIsStillRejected() {
        var noKey = canonicalSlot(value: 2)
        noKey.optionKey = ""
        XCTAssertNil(
            ChemicalDefaultRateValidity.validSlot(defaults(perHectare: noKey), basis: .perHectare),
            "only a manual row may omit the official identity"
        )

        var fakeKey = canonicalSlot(value: 2)
        fakeKey.optionKey = "manual_rate"
        fakeKey.rateIds = ["user_rate_1"]
        XCTAssertNil(
            ChemicalDefaultRateValidity.validSlot(defaults(perHectare: fakeKey), basis: .perHectare)
        )
    }

    /// A row written before `entry_method` existed is canonical by construction.
    func testALegacyRowWithNoEntryMethodDecodesAsCanonical() throws {
        let legacy = """
        {"version":1,"per_hectare":{"option_key":"default_option_v1_abc",
        "rate_ids":["rate_v1_a"],"basis":"per_hectare","unit":"L","value":2,
        "source":"operator"}}
        """
        let decoded = try JSONDecoder().decode(
            StoredChemicalDefaultRates.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.perHectare?.entryMethod, StoredChemicalDefaultRate.entryCanonical)
        XCTAssertEqual(decoded.perHectare?.isManualEntry, false)
        XCTAssertNotNil(ChemicalDefaultRateValidity.validSlot(decoded, basis: .perHectare))
    }

    // MARK: - Offline round trip

    func testAnOfflineManualChemicalRoundTripsWithItsContractIntact() throws {
        let offline = chemical(defaults(per100Litres: manualRange()))
        let reloaded = try JSONDecoder().decode(
            SavedChemical.self,
            from: try JSONEncoder().encode(offline)
        )

        XCTAssertNil(reloaded.ratePerHa, "no manufactured legacy scalar")
        let slot = try XCTUnwrap(reloaded.defaultRates?.per100Litres)
        XCTAssertEqual(slot.minValue, 2)
        XCTAssertEqual(slot.maxValue, 3)
        XCTAssertTrue(slot.isManualEntry)
        XCTAssertEqual(slot.optionKey, "")
        XCTAssertTrue(slot.rateIds.isEmpty)
        XCTAssertTrue(ChemicalSprayRateHandoff.isSprayReady(reloaded.defaultRates))
    }

    // MARK: - Spray record provenance

    func testTheSprayRecordSnapshotsTheAppliedDoseAndItsProvenance() throws {
        let stored = defaults(per100Litres: manualRange())
        let selection = try XCTUnwrap(ChemicalSprayRateHandoff.resolution(stored)?.rangeSelection)
        let chosen = try XCTUnwrap(
            ChemicalSprayRateHandoff.validateApplicationRate(2.5, in: selection).acceptedValue
        )

        let snapshot = ChemicalLineSnapshot(
            savedChemicalId: "chem-1",
            productName: "Stifle"
        ).recordingApplied(
            rate: chosen,
            unit: selection.unit,
            basis: .per100Litres,
            entryMethod: StoredChemicalDefaultRate.entryManual,
            confirmedRange: (min: 2, max: 3)
        )

        XCTAssertEqual(snapshot.appliedRate, 2.5)
        XCTAssertEqual(snapshot.appliedRateUnit, "L")
        XCTAssertEqual(snapshot.appliedRateBasis, "per_100_litres")
        XCTAssertEqual(snapshot.savedChemicalId, "chem-1")
        XCTAssertEqual(snapshot.productName, "Stifle")
        XCTAssertTrue(snapshot.isUserEnteredRate, "history must remember this was user-confirmed")
        XCTAssertEqual(snapshot.rateRangeMin, 2)
        XCTAssertEqual(snapshot.rateRangeMax, 3)

        // The saved chemical is untouched: the 2.5 belonged to one tank.
        XCTAssertEqual(stored.per100Litres?.minValue, 2)
        XCTAssertEqual(stored.per100Litres?.maxValue, 3)
        XCTAssertNil(stored.per100Litres?.value)
    }

    func testACanonicalSprayLineRecordsCanonicalProvenance() {
        let snapshot = ChemicalLineSnapshot(savedChemicalId: "chem-2").recordingApplied(
            rate: 2,
            unit: "L",
            basis: .perHectare,
            entryMethod: StoredChemicalDefaultRate.entryCanonical
        )
        XCTAssertFalse(snapshot.isUserEnteredRate)
        XCTAssertEqual(snapshot.appliedRateBasis, "per_hectare")
        XCTAssertNil(snapshot.rateRangeMin)
    }

    func testTheAppliedRateSnapshotSurvivesAJSONRoundTrip() throws {
        let snapshot = ChemicalLineSnapshot(savedChemicalId: "chem-1").recordingApplied(
            rate: 2.5,
            unit: "L",
            basis: .per100Litres,
            entryMethod: StoredChemicalDefaultRate.entryManual,
            confirmedRange: (min: 2, max: 3)
        )
        let reloaded = try JSONDecoder().decode(
            ChemicalLineSnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(reloaded.appliedRate, 2.5)
        XCTAssertEqual(reloaded.appliedRateBasis, "per_100_litres")
        XCTAssertTrue(reloaded.isUserEnteredRate)
    }
}
