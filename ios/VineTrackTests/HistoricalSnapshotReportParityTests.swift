import Foundation
import Testing
@testable import VineTrack

/// P10 — historical chemical snapshot + reports/export parity.
///
/// A completed spray is a compliance document. Everything downstream of it —
/// the record detail, the PDF, the CSV, the resistance history — must describe
/// the application AS IT HAPPENED, from the record's own frozen data. The only
/// way to guarantee that is for no historical read to consult the live Chemical
/// Store, and for the recorded rate, basis and geometry to be read back rather
/// than recomputed.
struct HistoricalSnapshotReportParityTests {

    private let formatter = RegionFormatter.australian

    private func chemical(_ json: String) throws -> SavedChemical {
        try JSONDecoder()
            .decode(BackendSavedChemical.self, from: Data(json.utf8))
            .toSavedChemical()
    }

    private func record(
        tanks: [SprayTank],
        endTime: Date? = Date(timeIntervalSince1970: 1_780_003_600),
        isTemplate: Bool = false,
        geometry: SprayApplicationSnapshot? = nil
    ) -> SprayRecord {
        SprayRecord(
            date: Date(timeIntervalSince1970: 1_780_000_000),
            startTime: Date(timeIntervalSince1970: 1_780_000_000),
            endTime: endTime,
            sprayReference: "SPRAY-P10",
            tanks: tanks,
            isTemplate: isTemplate,
            applicationGeometry: geometry
        )
    }

    // MARK: - Fixtures

    /// A single-active DMI. Its group is corrected LATER in the re-verify test.
    private let dmiJSON = """
    {
      "id": "cccccccc-0000-0000-0000-000000000001",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Example DMI",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "62764",
      "verification_status": "verified",
      "verification": {
        "status": "verified",
        "sources": [{ "kind": "official_register", "name": "APVMA PUBCRIS", "reference": "62764" }]
      },
      "active_ingredients": [
        {
          "name": "Tebuconazole",
          "activity_group": { "scheme": "frac", "code": "3" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["3"],
      "intelligence_schema_version": 1
    }
    """

    /// A co-formulation: FRAC 3 + FRAC 7. Both groups must survive everywhere.
    private let mixJSON = """
    {
      "id": "cccccccc-0000-0000-0000-000000000002",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Example Duo",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_number": "91636",
      "verification_status": "verified",
      "verification": {
        "status": "verified",
        "sources": [{ "kind": "official_register", "name": "APVMA PUBCRIS", "reference": "91636" }]
      },
      "active_ingredients": [
        {
          "name": "Tebuconazole",
          "activity_group": { "scheme": "frac", "code": "3" },
          "group_source": "authoritative_classification"
        },
        {
          "name": "Fluxapyroxad",
          "activity_group": { "scheme": "frac", "code": "7" },
          "group_source": "authoritative_classification"
        }
      ],
      "activity_groups": ["3", "7"],
      "intelligence_schema_version": 1
    }
    """

    /// A HRAC 9 herbicide — the scheme-collision fixture.
    private let glyphosateJSON = """
    {
      "id": "cccccccc-0000-0000-0000-000000000003",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Example Knockdown",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_number": "70011",
      "verification_status": "verified",
      "verification": {
        "status": "verified",
        "sources": [{ "kind": "official_register", "name": "APVMA PUBCRIS", "reference": "70011" }]
      },
      "active_ingredients": [
        {
          "name": "Glyphosate",
          "activity_group": { "scheme": "hrac", "code": "9" },
          "group_source": "authoritative_classification"
        }
      ],
      "activity_groups": ["9"],
      "intelligence_schema_version": 1
    }
    """

    /// A product whose only registered rate is `basis:"other"` — reference
    /// wording, never an applicable number.
    private let referenceOnlyJSON = """
    {
      "id": "cccccccc-0000-0000-0000-000000000004",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Prosaro 420 SC Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "registration_country": "AU",
      "registration_number": "63243",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "BOTRYTIS",
          "rates": [
            {
              "label": "",
              "basis": "other",
              "unit": "",
              "raw_text": "Refer to the approved label for grapevine rates"
            }
          ]
        }
      ],
      "intelligence_schema_version": 1
    }
    """

    // MARK: - 1. Re-verification never rewrites a completed spray

    @Test func completedSprayIgnoresLaterReVerification() throws {
        let atApplication = Date(timeIntervalSince1970: 1_780_000_000)
        let saved = try chemical(dmiJSON)
        let frozen = try #require(ChemicalSnapshotCapture.capture(saved, at: atApplication))

        let completed = record(tanks: [
            SprayTank(chemicals: [
                SprayChemical(
                    name: "Example DMI",
                    ratePerHa: 540,
                    unit: .millilitres,
                    rateBasis: .wholeBlockArea,
                    savedChemicalId: saved.id,
                    chemicalSnapshot: frozen
                )
            ])
        ])

        // The Chemical Store is corrected two years later: FRAC 3 -> FRAC 11.
        var corrected = saved
        var intel = try #require(corrected.chemicalIntelligence)
        intel.activeIngredients = [
            ChemicalActiveIngredient(
                name: "Azoxystrobin",
                activityGroup: ChemicalActivityGroup(scheme: .frac, code: "11"),
                groupSource: .authoritativeClassification
            )
        ]
        corrected.chemicalIntelligence = intel
        #expect(corrected.resolvedIntelligence.activityGroupCodes == ["11"])

        // The record still reports what was applied. It has no path back to the
        // store: `productLines` reads the frozen snapshot and nothing else.
        let lines = ResistanceEventSource.productLines(from: completed)
        #expect(lines.count == 1)
        #expect(lines[0].groups.codes == ["FRAC:3"])
        #expect(lines[0].productName == "Example DMI")
        #expect(lines[0].availability == .availableVerified)

        // And it survives a round trip through persistence unchanged.
        let data = try JSONEncoder().encode(completed)
        let reloaded = try JSONDecoder().decode(SprayRecord.self, from: data)
        #expect(ResistanceEventSource.productLines(from: reloaded)[0].groups.codes == ["FRAC:3"])
    }

    // MARK: - 2. Multi-active retention

    @Test func coFormulationRetainsEveryGroup() throws {
        let saved = try chemical(mixJSON)
        let frozen = try #require(ChemicalSnapshotCapture.capture(saved, at: Date()))

        #expect(frozen.activeIngredients.count == 2)
        #expect(Set(frozen.activityGroupCodes) == ["3", "7"])

        let completed = record(tanks: [
            SprayTank(chemicals: [
                SprayChemical(name: "Example Duo", savedChemicalId: saved.id, chemicalSnapshot: frozen)
            ])
        ])
        let groups = ResistanceEventSource.productLines(from: completed)[0].groups
        #expect(Set(groups.codes) == ["FRAC:3", "FRAC:7"])

        // Both survive persistence, not just the in-memory build.
        let data = try JSONEncoder().encode(completed)
        let reloaded = try JSONDecoder().decode(SprayRecord.self, from: data)
        let reloadedGroups = ResistanceEventSource.productLines(from: reloaded)[0].groups
        #expect(Set(reloadedGroups.codes) == ["FRAC:3", "FRAC:7"])
    }

    // MARK: - 3. HRAC 9 stays HRAC 9

    @Test func herbicideGroupNineNeverBecomesFungicideGroupNine() throws {
        let saved = try chemical(glyphosateJSON)
        let frozen = try #require(ChemicalSnapshotCapture.capture(saved, at: Date()))

        let completed = record(tanks: [
            SprayTank(chemicals: [
                SprayChemical(name: "Example Knockdown", savedChemicalId: saved.id, chemicalSnapshot: frozen)
            ])
        ])

        let data = try JSONEncoder().encode(completed)
        let reloaded = try JSONDecoder().decode(SprayRecord.self, from: data)
        let groups = ResistanceEventSource.productLines(from: reloaded)[0].groups

        #expect(groups.codes == ["HRAC:9"])
        // Read under a FRAC strategy it contributes nothing — it is not FRAC 9.
        #expect(groups.projected(into: .frac).codes.isEmpty)
    }

    // MARK: - 4. Per-100 m and per-100 L rates are reported on their own basis

    @Test func distanceBasedRecordKeepsItsAppliedRate() throws {
        // A L/100 m application: the carrier figures live on the frozen
        // geometry, and the derived per-hectare figure is stored ALONGSIDE the
        // per-100 m one rather than replacing it.
        let geometry = SprayApplicationSnapshot(
            grossAreaHa: 4.0,
            treatedAreaHa: 4.0,
            carrierVolumeBasis: .litresPer100Metres,
            totalCarrierLitres: 1_200,
            carrierLitresPerHectare: 300,
            diluteLitresPer100m: 12,
            appliedLitresPer100m: 6,
            concentrationFactor: 2
        )
        let line = SprayChemical(
            name: "Distance Rate Product",
            ratePerHa: 250,
            unit: .millilitres,
            rateBasis: .per100Metres
        )
        let completed = record(tanks: [SprayTank(chemicals: [line])], geometry: geometry)

        let data = try JSONEncoder().encode(completed)
        let reloaded = try JSONDecoder().decode(SprayRecord.self, from: data)
        let reloadedGeometry = try #require(reloaded.applicationGeometry)

        // Both carrier figures are read back verbatim; neither is recomputed
        // from today's equipment or row spacing settings.
        #expect(reloadedGeometry.appliedLitresPer100m == 6)
        #expect(reloadedGeometry.diluteLitresPer100m == 12)
        #expect(reloadedGeometry.carrierLitresPerHectare == 300)
        #expect(reloadedGeometry.concentrationFactor == 2)
        #expect(reloadedGeometry.totalCarrierLitres == 1_200)

        // The product line reports on the basis it was recorded on.
        let reloadedLine = try #require(reloaded.tanks.first?.chemicals.first)
        #expect(reloadedLine.reportedRateBasis == .per100Metres)
        #expect(reloadedLine.reportedRateText(formatter: formatter) == "250.00 mL/100 m")
    }

    @Test func per100LitreLineNoLongerReportsAsZeroPerHectare() {
        // The P10 export defect: `ratePerHa` is 0 on a per-100 L line, so the
        // PDF and CSV printed "0.00 L/ha" for a real application.
        let line = SprayChemical(
            name: "Dilute Product",
            ratePer100L: 45,
            unit: .millilitres,
            rateBasis: .per100Litres
        )
        #expect(line.reportedRateBasis == .per100Litres)
        #expect(line.displayReportedRate == 45)
        #expect(line.reportedRateText(formatter: formatter) == "45.00 mL/100 L")

        // An area line is unchanged, and still region-formatted.
        let areaLine = SprayChemical(
            name: "Area Product",
            ratePerHa: 2_000,
            unit: .litres,
            rateBasis: .wholeBlockArea
        )
        #expect(areaLine.reportedRateText(formatter: formatter) == "2.00 L/ha")
    }

    @Test func legacyLineWithOnlyAPer100LitreRateIsReportedAsSuch() {
        // No stored basis at all (pre-sql/191). Reporting it as per-hectare
        // would print 0; the honest reading is the field that holds a number.
        let legacy = SprayChemical(name: "Old Dilute", ratePer100L: 100, unit: .millilitres)
        #expect(legacy.rateBasis == nil)
        #expect(legacy.reportedRateBasis == .per100Litres)
        #expect(legacy.reportedRateText(formatter: formatter) == "100.00 mL/100 L")

        // But the CALCULATION default is untouched: a legacy area line still
        // means whole block, never treated area.
        let legacyArea = SprayChemical(name: "Old Area", ratePerHa: 2_000, unit: .litres)
        #expect(legacyArea.resolvedRateBasis == .wholeBlockArea)
        #expect(legacyArea.reportedRateBasis == .wholeBlockArea)
    }

    // MARK: - 5. Banded record keeps gross AND treated area

    @Test func bandedRecordRetainsBothAreasAndItsProductTotal() throws {
        let geometry = SprayApplicationSnapshot(
            grossAreaHa: 10.0,
            treatedAreaHa: 2.5,
            applicationMode: .banded,
            bandWidthTotalMetres: 0.75,
            canonicalRowLengthMetres: 8_000,
            rowSpacingMetres: 3.0,
            carrierVolumeBasis: .litresPerHectare,
            totalCarrierLitres: 625,
            carrierLitresPerHectare: 250
        )
        // 2 L/treated ha × 2.5 treated ha = 5 L, recorded as the tank volume.
        let herbicide = SprayChemical(
            name: "Banded Herbicide",
            volumePerTank: 5_000,
            ratePerHa: 2_000,
            unit: .litres,
            rateBasis: .treatedArea
        )
        let completed = record(
            tanks: [SprayTank(waterVolume: 625, sprayRatePerHa: 250, chemicals: [herbicide])],
            geometry: geometry
        )

        let data = try JSONEncoder().encode(completed)
        let reloaded = try JSONDecoder().decode(SprayRecord.self, from: data)
        let reloadedGeometry = try #require(reloaded.applicationGeometry)

        // Gross is never replaced by treated, and treated is never inflated to
        // gross — the two coexist on the record.
        #expect(reloadedGeometry.grossAreaHa == 10.0)
        #expect(reloadedGeometry.treatedAreaHa == 2.5)
        #expect(reloadedGeometry.applicationMode == .banded)
        #expect(reloadedGeometry.bandWidthTotalMetres == 0.75)

        let line = try #require(reloaded.tanks.first?.chemicals.first)
        #expect(line.rateBasis == .treatedArea)
        #expect(line.resolvedRateBasis == .treatedArea)
        #expect(line.displayVolume == 5.0)
        #expect(line.reportedRateText(formatter: formatter) == "2.00 L/ha")
    }

    // MARK: - 6. basis:"other" is never an applied number

    @Test func referenceOnlyRateIsNeverSelectableOrSeedable() throws {
        let saved = try chemical(referenceOnlyJSON)
        let offered = SprayRegisteredUseRates.rates(for: saved)
        let entry = try #require(offered.first)

        // It is OFFERED, so the operator sees what the label says — but it
        // carries no basis, cannot be picked, and cannot seed a number.
        #expect(entry.seed == .referenceOnly)
        #expect(entry.basis == nil)
        #expect(entry.isSelectable == false)
        #expect(SprayRegisteredUseRates.selectableRates(for: saved).isEmpty)
        #expect(SprayRegisteredUseRates.seedValue(for: saved, rateId: entry.id, basis: .perHectare) == nil)
        #expect(SprayRegisteredUseRates.seedValue(for: saved, rateId: entry.id, basis: .per100Litres) == nil)
        #expect(SprayRegisteredUseRates.defaultSelection(for: saved) == nil)

        // The label wording is preserved verbatim for display.
        #expect(entry.displayText == "Refer to the approved label for grapevine rates")
    }

    @Test func aLineWithNoRecordedRateReportsZeroRatherThanInventingOne() {
        // Nothing was applicable, so nothing is claimed. This is the shape a
        // reference-only product would take if it ever reached a record: no
        // number, not a fabricated one.
        let line = SprayChemical(name: "Prosaro 420 SC Fungicide", unit: .litres)
        #expect(line.reportedRateBaseValue == 0)
        #expect(line.reportedRateBasis == .wholeBlockArea)
    }

    // MARK: - 7. Legacy records fail safe

    @Test func legacyRecordWithoutASnapshotIsUnavailableNotReconstructed() throws {
        let saved = try chemical(dmiJSON)
        // Same product, same name, same id — present in today's library.
        let legacyLine = SprayChemical(
            name: "Example DMI",
            ratePerHa: 540,
            unit: .millilitres,
            savedChemicalId: saved.id,
            chemicalSnapshot: nil
        )
        let completed = record(tanks: [SprayTank(chemicals: [legacyLine])])

        let lines = ResistanceEventSource.productLines(from: completed)
        #expect(lines[0].availability == .unavailable)
        #expect(lines[0].groups.codes.isEmpty)
        // The link survives for provenance, but it buys the line no chemistry.
        #expect(lines[0].savedChemicalId == saved.id.uuidString)

        // Explicitly not a pass, and it says why.
        #expect(lines[0].availability.canAssess == false)
        #expect(lines[0].availability.permitsCleanResult == false)
        #expect(lines[0].availability.requiresQualification)
        #expect(lines[0].availability.assessmentCaveat != nil)
        #expect(legacyLine.recordedActivityGroupCodes.isEmpty)
        #expect(legacyLine.hasResistanceSnapshot == false)
    }

    @Test func aLegacyOnlySnapshotIsStillUnassessable() throws {
        // A snapshot that preserved only the old free-text group has something
        // to DISPLAY but nothing structured to reason from.
        let legacyOnly = try #require(
            ChemicalLineSnapshot.capture(
                from: nil,
                legacyChemicalGroup: "Group 3 + 11",
                productName: "Old Product",
                at: Date()
            )
        )
        #expect(legacyOnly.legacyChemicalGroup == "Group 3 + 11")
        #expect(legacyOnly.activeIngredients.isEmpty)
        #expect(legacyOnly.hasResistanceData == false)
        #expect(legacyOnly.resistanceAvailability == .unavailable)
    }

    @Test func theWeakestLineGovernsAWholeTank() throws {
        let saved = try chemical(mixJSON)
        let frozen = try #require(ChemicalSnapshotCapture.capture(saved, at: Date()))
        let tank = SprayTank(chemicals: [
            SprayChemical(name: "Example Duo", savedChemicalId: saved.id, chemicalSnapshot: frozen),
            SprayChemical(name: "Unknown Adjuvant")
        ])
        // A verified product mixed with an unknown one cannot be read as
        // verified: the unknown line could be the group that breaks a rotation.
        #expect(tank.resistanceAvailability == .unavailable)
    }

    // MARK: - History membership

    @Test func onlyCompletedNonTemplateRecordsFeedHistory() throws {
        let saved = try chemical(dmiJSON)
        let frozen = try #require(ChemicalSnapshotCapture.capture(saved, at: Date()))
        let tanks = [
            SprayTank(chemicals: [
                SprayChemical(name: "Example DMI", savedChemicalId: saved.id, chemicalSnapshot: frozen)
            ])
        ]

        let completed = ResistanceEventSource.input(from: record(tanks: tanks))
        let unfinished = ResistanceEventSource.input(from: record(tanks: tanks, endTime: nil))
        let template = ResistanceEventSource.input(from: record(tanks: tanks, isTemplate: true))
        let deleted = ResistanceEventSource.input(from: record(tanks: tanks), isDeleted: true)

        #expect(completed.hasEndTime)
        #expect(completed.isTemplate == false)
        #expect(completed.isDeleted == false)
        #expect(unfinished.hasEndTime == false)
        #expect(template.isTemplate)
        #expect(deleted.isDeleted)

        let result = ResistanceEventSource.events(
            from: [completed, unfinished, template, deleted],
            seasonCalendar: ResistanceSeasonCalendar()
        )
        // Templates and deletions are excluded outright; an unfinished spray is
        // kept but classed as planned rather than counted as an actual.
        #expect(result.templateRecordIds.contains(template.recordId))
        #expect(result.deletedRecordIds.contains(deleted.recordId))
        #expect(result.events.contains { $0.kind == .actual })
        #expect(result.events.contains { $0.kind == .planned })
        #expect(result.events.contains { $0.applicationId.contains(template.recordId) } == false)
        #expect(result.events.contains { $0.applicationId.contains(deleted.recordId) } == false)
    }

    // MARK: - Snapshot scope (P9 boundary)

    @Test func theSnapshotDeliberatelyCarriesNoLegalText() throws {
        // WHP, REI and restrictions are ABSENT from the historical snapshot by
        // design: no historical surface displays them, so there is nothing that
        // could reach back to today's Saved Chemical for them. Adding them is
        // out of scope here — this test pins the current boundary.
        let saved = try chemical(dmiJSON)
        let frozen = try #require(ChemicalSnapshotCapture.capture(saved, at: Date()))
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(frozen)) as? [String: Any]
        )

        #expect(object["withholding_period_days"] == nil)
        #expect(object["re_entry_period_hours"] == nil)
        #expect(object["restrictions"] == nil)
        #expect(object["registered_uses"] == nil)

        // What it DOES freeze: identity, chemistry, trust and versions.
        #expect(frozen.savedChemicalId == saved.id.uuidString)
        #expect(frozen.productName == "Example DMI")
        #expect(frozen.registrationIdentityKey == "AU:apvma:62764")
        #expect(frozen.countryCode == "AU")
        #expect(frozen.verificationStatus == .verified)
        #expect(frozen.schemaVersion == ChemicalIntelligence.currentSchemaVersion)
        #expect(frozen.activityGroupTableVersion == AuthoritativeActivityGroups.tableVersion)
        #expect(frozen.capturedAt != nil)
    }
}
