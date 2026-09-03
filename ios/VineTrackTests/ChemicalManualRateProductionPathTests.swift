import XCTest
@testable import VineTrack

/// The manual-rate contract exercised through the PRODUCTION code path, end to
/// end, on the objects the screens actually drive:
///
/// ```text
/// manual entry (ChemicalReviewSession)
///   → Save Chemical (session.intelligenceToPersist + session.storedDefaultRates)
///   → reload Chemical Store (SavedChemical JSON round trip)
///   → reopen in the editor (ChemicalReviewSession.make reconstructs the slot)
///   → select in Spray Program (SprayConfirmedRateSeeding.seededLine)
///   → choose an application rate inside the range (the card's gate)
///   → plan + save the spray (SprayApplicationPlanner + SprayConfirmedRateSeeding.snapshot
///       → SprayChemical/SprayTank)
///   → reload the spray (SprayTank JSON round trip)
/// ```
///
/// No handoff and no snapshot is built by hand here: every object comes from
/// the same call the production screen makes.
final class ChemicalManualRateProductionPathTests: XCTestCase {

    // MARK: - Production helpers

    /// The Chemical Store's manual entry: a grapevine use with one typed rate.
    private func manualSession(rate: ChemicalManualRateDraft) -> ChemicalReviewSession {
        var session = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        session.chemistryDraft.productName = "Stifle"
        session.chemistryDraft.uses = [
            ChemicalManualUseDraft(crop: "Grapes", targetRaw: "Powdery mildew", rates: [rate])
        ]
        return session
    }

    /// EXACTLY what `EditSavedChemicalSheet.persist()` writes for a new
    /// chemical: the session's intelligence and the session's stored default.
    private func saveChemical(from session: ChemicalReviewSession) -> SavedChemical {
        SavedChemical(
            vineyardId: UUID(),
            name: session.name,
            unit: .litres,
            chemicalIntelligence: session.intelligenceToPersist,
            defaultRates: session.storedDefaultRates
        )
    }

    /// "Reload Chemical Store": the persisted row, decoded again.
    private func reload(_ chemical: SavedChemical) throws -> SavedChemical {
        try JSONDecoder().decode(SavedChemical.self, from: JSONEncoder().encode(chemical))
    }

    /// The production planner over one 1 ha block at 1000 L/ha.
    private func plan(for chemical: SavedChemical, line: ChemicalLine) -> SprayProductLineResult {
        // The SAME mapping `guidedProductLines` performs for this line.
        let seeded = SprayRegisteredUseRates.seedValue(for: chemical, rateId: line.selectedRateId, basis: line.basis)
        let rate = line.overrideRate ?? seeded ?? 0
        let selected = SprayRegisteredUseRates.rate(for: chemical, id: line.selectedRateId)
        let labelUnit = selected?.labelUnit.trimmedNonEmpty ?? chemical.unit.rawValue
        let basis: SprayProductRateBasis = line.basis == .per100Litres ? .per100Litres : .wholeBlockArea
        let labelRate: SprayLabelRateDescriptor? = rate > 0
            ? SprayLabelRateDescriptor(
                value: SprayRegisteredUseRates.displayValue(rate, labelUnit: labelUnit, chemical: chemical)
                    ?? chemical.unit.fromBase(rate),
                unit: labelUnit,
                basis: basis
            )
            : nil
        let input = SprayProductLineInput(
            productId: chemical.id.uuidString,
            name: chemical.name,
            unit: chemical.unit.rawValue,
            basis: basis,
            rate: rate,
            labelRate: labelRate,
            unitDisplay: SprayProductUnitDisplay(
                displayUnit: chemical.unit.rawValue,
                baseUnitsPerDisplayUnit: chemical.unit.toBase(1)
            )
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [SprayBlockInput(blockId: "b1", grossAreaHectares: 1)],
            mode: .wholeBlock,
            carrier: SprayCarrierVolumeCalculator.perHectare(litresPerHectare: 1000, areaHectares: 1),
            tankCapacityLitres: 1000,
            productLines: [input]
        )
        return plan.productLines[0]
    }

    /// EXACTLY what `buildSprayTanks` does for one line, then a JSON round
    /// trip through the `tanks` JSONB shape.
    private func saveAndReloadSpray(
        chemical: SavedChemical,
        line: ChemicalLine,
        planLine: SprayProductLineResult
    ) throws -> SprayChemical {
        let captured = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: line.chemicalId,
            productName: planLine.name,
            library: [chemical],
            allowNameMatch: false
        ).snapshot
        let snapshot = SprayConfirmedRateSeeding.snapshot(
            base: captured, chemical: chemical, line: line, planLine: planLine
        )
        let tank = SprayTank(
            tankNumber: 1,
            waterVolume: 1000,
            sprayRatePerHa: 1000,
            concentrationFactor: 1,
            chemicals: [
                SprayChemical(
                    name: planLine.name,
                    volumePerTank: planLine.quantityPerFullTank ?? 0,
                    ratePer100L: planLine.rate,
                    unit: chemical.unit,
                    rateBasis: .per100Litres,
                    savedChemicalId: line.chemicalId,
                    chemicalSnapshot: snapshot
                )
            ]
        )
        let reloaded = try JSONDecoder().decode(SprayTank.self, from: JSONEncoder().encode(tank))
        return reloaded.chemicals[0]
    }

    // MARK: - Range: 2–3 L/100 L, sprayed at 2.5

    func testManualRangeReachesDefaultRatesThenSprayAtTwoPointFive() throws {
        // 1. Manual entry.
        var session = manualSession(
            rate: ChemicalManualRateDraft(basis: .rangePer100Litres, minText: "2", maxText: "3", unit: "L")
        )
        // The editor offers the typed rate as a default-rate option.
        let group = session.defaultRatePlan.group(.per100Litres)
        let option = try XCTUnwrap(group.options.first, "the typed range must be offered")
        XCTAssertTrue(option.isLabelRange)
        XCTAssertTrue(session.isManualDefaultOption(option), "a typed rate carries no register identity")
        XCTAssertNil(session.storedDefaultRates, "nothing persists until the operator confirms")

        // 2. The operator confirms it — the same call the Default Rates row makes.
        session.selectDefaultRate(option, for: .per100Litres)
        XCTAssertTrue(session.isDefaultRateConfirmed(for: .per100Litres))

        // 3. Save Chemical → reload Chemical Store.
        let saved = saveChemical(from: session)
        let stored = try XCTUnwrap(saved.defaultRates, "the manual range must reach default_rates")
        let slot = try XCTUnwrap(stored.per100Litres)
        XCTAssertEqual(slot.optionKey, "")
        XCTAssertEqual(slot.rateIds, [])
        XCTAssertEqual(slot.basis, "per_100_litres")
        XCTAssertEqual(slot.unit, "L")
        XCTAssertNil(slot.value)
        XCTAssertEqual(slot.minValue, 2)
        XCTAssertEqual(slot.maxValue, 3)
        XCTAssertEqual(slot.source, "operator")
        XCTAssertEqual(slot.entryMethod, "manual")
        XCTAssertNotNil(slot.selectedAt)
        XCTAssertNil(stored.perHectare, "no basis conversion")
        XCTAssertNil(saved.ratePerHa, "no scalar projection for a range (sql/222)")

        let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        XCTAssertTrue(json.contains("\"entry_method\":\"manual\""))
        for fake in ["default_option_v1_", "rate_v1_", "manual_rate", "user_rate", "custom"] {
            XCTAssertFalse(json.contains(fake), "must not mint \(fake)")
        }

        let reloaded = try reload(saved)
        XCTAssertEqual(reloaded.defaultRates, stored)

        // 4. Reopen in the editor: the exact manual range is reconstructed and
        //    re-saving rewrites it byte for byte.
        let reopened = ChemicalReviewSession.make(chemical: reloaded, prefill: nil, fallbackCountry: "AU")
        XCTAssertNotNil(reopened.selectedDefaultRateIds[.per100Litres], "the confirmed range is re-selected")
        XCTAssertEqual(reopened.storedDefaultRates, stored, "reopen must reconstruct the identical manual slot")

        // 5. Select in Spray Program.
        var line = SprayConfirmedRateSeeding.seededLine(
            for: reloaded, preferring: [.per100Litres, .perHectare], fallbackBasis: .perHectare
        )
        XCTAssertEqual(line.basis, .per100Litres)
        XCTAssertNil(line.overrideRate, "no endpoint or midpoint is ever pre-selected")
        XCTAssertNil(
            SprayRegisteredUseRates.seedValue(for: reloaded, rateId: line.selectedRateId, basis: .per100Litres),
            "the band seeds no dose"
        )
        let resolution = try XCTUnwrap(SprayConfirmedRateSeeding.resolution(for: reloaded, basis: .per100Litres))
        let range = try XCTUnwrap(resolution.rangeSelection, "a confirmed range requires selection")
        XCTAssertEqual(range.min, 2)
        XCTAssertEqual(range.max, 3)
        XCTAssertEqual(range.unit, "L")
        XCTAssertTrue(range.isUserEntered)
        XCTAssertTrue(ChemicalSprayRateHandoff.isSprayReady(reloaded.defaultRates))

        // Unresolved until the operator enters a rate inside the range.
        XCTAssertTrue(plan(for: reloaded, line: line).isUnresolved)

        // 6. Application-rate field: the gate the card applies.
        XCTAssertFalse(SprayConfirmedRateSeeding.validate(typed: 1.5, against: range).isAccepted)
        XCTAssertFalse(SprayConfirmedRateSeeding.validate(typed: 3.5, against: range).isAccepted)
        XCTAssertNotNil(SprayConfirmedRateSeeding.rejectionMessage(
            SprayConfirmedRateSeeding.validate(typed: 3.5, against: range), range: range, basisSuffix: "/100 L"
        ))
        let accepted = try XCTUnwrap(SprayConfirmedRateSeeding.validate(typed: 2.5, against: range).acceptedValue)
        line.overrideRate = SprayRegisteredUseRates.baseValue(accepted, labelUnit: "L", chemical: reloaded)
        XCTAssertEqual(line.overrideRate, 2500, "2.5 L held in base millilitres")

        // 7. Plan → save spray → reload spray.
        let planLine = plan(for: reloaded, line: line)
        XCTAssertFalse(planLine.isUnresolved)
        XCTAssertEqual(planLine.labelRate?.value, 2.5)
        XCTAssertEqual(planLine.labelRate?.unit, "L")

        let sprayed = try saveAndReloadSpray(chemical: reloaded, line: line, planLine: planLine)
        let snapshot = try XCTUnwrap(sprayed.chemicalSnapshot)
        XCTAssertEqual(snapshot.appliedRate, 2.5)
        XCTAssertEqual(snapshot.appliedRateUnit, "L")
        XCTAssertEqual(snapshot.appliedRateBasis, "per_100_litres")
        XCTAssertEqual(snapshot.rateEntryMethod, "manual")
        XCTAssertTrue(snapshot.isUserEnteredRate)
        XCTAssertEqual(snapshot.rateRangeMin, 2)
        XCTAssertEqual(snapshot.rateRangeMax, 3)
        XCTAssertEqual(snapshot.savedChemicalId, reloaded.id.uuidString)

        // The Chemical Store's band is untouched by the spray.
        XCTAssertEqual(reloaded.defaultRates?.per100Litres?.minValue, 2)
        XCTAssertEqual(reloaded.defaultRates?.per100Litres?.maxValue, 3)
        XCTAssertNil(reloaded.defaultRates?.per100Litres?.value)
    }

    // MARK: - Scalar: 2 L/100 L populates the line

    func testManualScalarPopulatesTheSprayLineAndRecordsProvenance() throws {
        var session = manualSession(
            rate: ChemicalManualRateDraft(basis: .per100Litres, valueText: "2", unit: "L")
        )
        let option = try XCTUnwrap(session.defaultRatePlan.group(.per100Litres).options.first)
        session.selectDefaultRate(option, for: .per100Litres)

        let saved = saveChemical(from: session)
        let slot = try XCTUnwrap(saved.defaultRates?.per100Litres)
        XCTAssertEqual(slot.value, 2)
        XCTAssertNil(slot.minValue)
        XCTAssertNil(slot.maxValue)
        XCTAssertEqual(slot.entryMethod, "manual")
        XCTAssertEqual(slot.optionKey, "")
        XCTAssertTrue(slot.rateIds.isEmpty)

        let reloaded = try reload(saved)
        let reopened = ChemicalReviewSession.make(chemical: reloaded, prefill: nil, fallbackCountry: "AU")
        XCTAssertEqual(reopened.storedDefaultRates, saved.defaultRates)

        // Spray Program: the confirmed scalar populates the line.
        let line = SprayConfirmedRateSeeding.seededLine(
            for: reloaded, preferring: [.perHectare, .per100Litres], fallbackBasis: .perHectare
        )
        XCTAssertEqual(line.basis, .per100Litres, "the confirmed basis wins over the carrier preference")
        let prefill = try XCTUnwrap(SprayConfirmedRateSeeding.resolution(for: reloaded, basis: .per100Litres)?.prefill)
        XCTAssertEqual(prefill.rate, 2)
        XCTAssertEqual(prefill.unit, "L")
        XCTAssertTrue(prefill.isUserEntered)
        XCTAssertEqual(
            SprayRegisteredUseRates.seedValue(for: reloaded, rateId: line.selectedRateId, basis: .per100Litres),
            2000,
            "the line is populated with the confirmed 2 L"
        )

        let planLine = plan(for: reloaded, line: line)
        XCTAssertFalse(planLine.isUnresolved)
        let sprayed = try saveAndReloadSpray(chemical: reloaded, line: line, planLine: planLine)
        let snapshot = try XCTUnwrap(sprayed.chemicalSnapshot)
        XCTAssertEqual(snapshot.appliedRate, 2)
        XCTAssertEqual(snapshot.appliedRateUnit, "L")
        XCTAssertEqual(snapshot.appliedRateBasis, "per_100_litres")
        XCTAssertEqual(snapshot.rateEntryMethod, "manual")
        XCTAssertNil(snapshot.rateRangeMin)
        XCTAssertNil(snapshot.rateRangeMax)
    }

    // MARK: - Canonical behaviour unchanged

    func testAnOptionBackedByServerRateIdsIsNotTreatedAsManual() throws {
        var session = manualSession(
            rate: ChemicalManualRateDraft(basis: .per100Litres, valueText: "2", unit: "L")
        )
        // Give the typed rate a register identity, as a lookup would.
        let intelligence = ChemicalManualEntry.proposedIntelligence(from: session.chemistryDraft, existing: nil)
        var lookedUp = intelligence
        lookedUp.registeredUses = intelligence.registeredUses.map { registered in
            var copy = registered
            copy.rates = registered.rates.map { rate in
                var r = rate
                r.rateId = "rate_v1_abc"
                return r
            }
            return copy
        }
        let chemical = SavedChemical(vineyardId: UUID(), name: "Looked up", unit: .litres, chemicalIntelligence: lookedUp)
        session = ChemicalReviewSession.make(chemical: chemical, prefill: nil, fallbackCountry: "AU")
        let option = try XCTUnwrap(session.defaultRatePlan.group(.per100Litres).options.first)
        XCTAssertFalse(session.isManualDefaultOption(option), "label evidence never becomes manual")
        session.selectDefaultRate(option, for: .per100Litres)
        XCTAssertNil(session.storedDefaultRates, "the existing canonical refusal is untouched")
    }

    func testCanonicalScalarSprayRecordsCanonicalProvenance() throws {
        let canonical = StoredChemicalDefaultRate(
            optionKey: "default_option_v1_abc",
            rateIds: ["rate_v1_a"],
            basis: "per_100_litres",
            unit: "L",
            value: 2,
            source: StoredChemicalDefaultRate.sourceOperator
        )
        let chemical = SavedChemical(
            vineyardId: UUID(), name: "Official", unit: .litres,
            defaultRates: StoredChemicalDefaultRates(per100Litres: canonical)
        )
        let line = SprayConfirmedRateSeeding.seededLine(
            for: chemical, preferring: [.per100Litres], fallbackBasis: .perHectare
        )
        XCTAssertEqual(line.basis, .per100Litres)
        XCTAssertEqual(line.overrideRate, 2000, "a confirmed scalar with no registered twin still populates the line")
        let planLine = plan(for: chemical, line: line)
        let sprayed = try saveAndReloadSpray(chemical: chemical, line: line, planLine: planLine)
        let snapshot = try XCTUnwrap(sprayed.chemicalSnapshot)
        XCTAssertEqual(snapshot.appliedRate, 2)
        XCTAssertEqual(snapshot.rateEntryMethod, "canonical")
        XCTAssertFalse(snapshot.isUserEnteredRate)
    }
}
