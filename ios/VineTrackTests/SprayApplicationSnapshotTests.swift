import Foundation
import Testing
@testable import VineTrack

/// Persistence contract for the canonical spray calculation snapshot
/// (sql/191 + sql/192).
///
/// These tests exist to protect three properties that a compliance record must
/// have and that are easy to break silently:
///
///  1. **Calculate once.** The persisted values are a projection of ONE
///     `SprayApplicationPlan`, not a second derivation.
///  2. **Gross and treated both survive.** Treated area never overwrites gross.
///  3. **A completed record is frozen.** Editing the vineyard afterwards must
///     not retroactively change what was recorded.
///
/// The Android suite `SprayApplicationSnapshotTest` asserts the same fixtures.
struct SprayApplicationSnapshotTests {

    private let tolerance = 0.0001

    /// THE worked example from the spec: 10 ha gross, 31,250 m of row,
    /// 0.8 m total band → 2.5 ha treated.
    private func bandedPlan(
        rowLengthMetres: Double = 31_250,
        grossHectares: Double = 10,
        rowSpacing: Double = 3.2,
        bandWidth: Double = 0.8
    ) -> SprayApplicationPlan {
        let block = SprayBlockInput(
            blockId: "A",
            grossAreaHectares: grossHectares,
            mappedRowLengthMetres: rowLengthMetres,
            rowSpacingMetres: rowSpacing
        )
        let geometry = SprayGeometryResolver.resolve([block])
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 500,
            areaHectares: grossHectares,
            rowLengthMetres: geometry.totalRowLengthMetres,
            rowSpacingMetres: geometry.uniformRowSpacingMetres
        )
        return SprayApplicationPlanner.plan(
            blocks: [block],
            mode: .banded,
            bandWidth: SprayBandWidth.total(bandWidth),
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: []
        )
    }

    private func encodeDecode(_ record: SprayRecord) throws -> SprayRecord {
        let data = try JSONEncoder().encode(record)
        return try JSONDecoder().decode(SprayRecord.self, from: data)
    }

    // MARK: - Banded persistence

    @Test("Banded spray persists BOTH gross and treated area")
    func bandedSnapshotKeepsGrossAndTreated() {
        let snapshot = SprayApplicationSnapshot(plan: bandedPlan())

        // Gross is NOT overwritten by treated.
        #expect(abs((snapshot.grossAreaHa ?? 0) - 10) < tolerance)
        // 31,250 m × 0.8 m ÷ 10,000 = 2.5 ha
        #expect(abs((snapshot.treatedAreaHa ?? 0) - 2.5) < tolerance)
        #expect(abs((snapshot.canonicalRowLengthMetres ?? 0) - 31_250) < tolerance)
        #expect(abs((snapshot.bandWidthTotalMetres ?? 0) - 0.8) < tolerance)
        #expect(snapshot.applicationMode == .banded)
        #expect(snapshot.treatedAreaMethod == .canonicalRowLength)
        #expect(snapshot.geometrySource == .mappedRows)
        #expect(snapshot.hasGenuineTreatedArea)
    }

    @Test("Banded snapshot survives a full encode/decode round trip on the record")
    func bandedSnapshotRoundTrips() throws {
        let record = SprayRecord(
            sprayReference: "Banded pass",
            applicationGeometry: SprayApplicationSnapshot(plan: bandedPlan())
        )
        let reloaded = try encodeDecode(record)

        let geometry = try #require(reloaded.applicationGeometry)
        #expect(abs((geometry.grossAreaHa ?? 0) - 10) < tolerance)
        #expect(abs((geometry.treatedAreaHa ?? 0) - 2.5) < tolerance)
        #expect(abs((geometry.canonicalRowLengthMetres ?? 0) - 31_250) < tolerance)
        #expect(geometry.applicationMode == .banded)
        #expect(geometry.treatedAreaMethod == .canonicalRowLength)
        #expect(geometry == record.applicationGeometry)
    }

    // MARK: - Standard L/ha foliar behaviour is unchanged

    @Test("Whole-block L/ha foliar records treated == gross and no L/100 m values")
    func wholeBlockFoliarUnchanged() {
        let block = SprayBlockInput(
            blockId: "A",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block],
            mode: .wholeBlock,
            carrier: SprayCarrierVolumeCalculator.perHectare(litresPerHectare: 500, areaHectares: 10),
            tankCapacityLitres: 2_000,
            productLines: []
        )
        let snapshot = SprayApplicationSnapshot(plan: plan)

        #expect(abs((snapshot.grossAreaHa ?? 0) - 10) < tolerance)
        // Whole-canopy: the treated area legitimately IS the gross area.
        #expect(abs((snapshot.treatedAreaHa ?? 0) - 10) < tolerance)
        #expect(snapshot.treatedAreaMethod == .wholeBlock)
        #expect(snapshot.carrierVolumeBasis == .litresPerHectare)
        #expect(abs((snapshot.totalCarrierLitres ?? 0) - 5_000) < tolerance)
        #expect(abs((snapshot.carrierLitresPerHectare ?? 0) - 500) < tolerance)
        // L/100 m columns belong to the other basis and must stay null.
        #expect(snapshot.diluteLitresPer100m == nil)
        #expect(snapshot.appliedLitresPer100m == nil)
        #expect(snapshot.bandWidthTotalMetres == nil)
    }

    // MARK: - Carrier volume (L/100 m) reproducibility

    @Test("L/100 m carrier snapshot is reproducible without current block geometry")
    func litresPer100MetresSnapshotIsSelfContained() throws {
        let block = SprayBlockInput(
            blockId: "A",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        let geometry = SprayGeometryResolver.resolve([block])
        let carrier = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 8,
                diluteLitresPer100Metres: 16,
                rowLengthMetres: geometry.totalRowLengthMetres,
                rowSpacingMetres: geometry.uniformRowSpacingMetres
            )
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block],
            mode: .wholeBlock,
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: []
        )
        let snapshot = SprayApplicationSnapshot(plan: plan)

        // 31,250 m ÷ 100 × 8 L = 2,500 L actually applied.
        #expect(abs((snapshot.totalCarrierLitres ?? 0) - 2_500) < tolerance)
        #expect(abs((snapshot.appliedLitresPer100m ?? 0) - 8) < tolerance)
        #expect(abs((snapshot.diluteLitresPer100m ?? 0) - 16) < tolerance)
        // 16 ÷ 8 = 2× concentrate.
        #expect(abs((snapshot.concentrationFactor ?? 0) - 2) < tolerance)
        // 8 × 100 ÷ 3.2 = 250 L/ha derived.
        #expect(abs((snapshot.carrierLitresPerHectare ?? 0) - 250) < tolerance)
        #expect(snapshot.carrierVolumeBasis == .litresPer100Metres)
        // Row spacing is snapshotted so the derived L/ha stays explainable even
        // after the block's spacing is later edited.
        #expect(abs((snapshot.rowSpacingMetres ?? 0) - 3.2) < tolerance)
        #expect(abs((snapshot.canonicalRowLengthMetres ?? 0) - 31_250) < tolerance)
    }

    // MARK: - Snapshot immutability after the vineyard changes

    @Test("Completed record is unchanged when the block geometry is edited afterwards")
    func completedRecordIsFrozenAgainstLaterGeometryEdits() throws {
        // Spray is calculated and completed against today's geometry.
        let completed = SprayRecord(
            sprayReference: "Completed",
            applicationGeometry: SprayApplicationSnapshot(plan: bandedPlan())
        )
        let stored = try encodeDecode(completed)

        // The grower now corrects the block: an operator override halves the row
        // length. Recalculating TODAY would give a completely different answer.
        let editedBlock = SprayBlockInput(
            blockId: "A",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            operatorRowLengthOverrideMetres: 15_000,
            rowSpacingMetres: 3.2
        )
        let recalculated = SprayGeometryResolver.resolve([editedBlock])
        #expect(abs((recalculated.totalRowLengthMetres ?? 0) - 15_000) < tolerance)

        // The historical record must NOT move.
        let geometry = try #require(stored.applicationGeometry)
        #expect(abs((geometry.canonicalRowLengthMetres ?? 0) - 31_250) < tolerance)
        #expect(abs((geometry.treatedAreaHa ?? 0) - 2.5) < tolerance)
        #expect(geometry.geometrySource == .mappedRows)
    }

    // MARK: - Legacy records: no backfill, no invention

    @Test("A pre-sql/191 record decodes with a nil snapshot, not a guessed one")
    func legacyRecordHasNoGeometry() throws {
        // A record encoded without the field at all — exactly what every
        // historical row looks like.
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "tripId": "\(UUID().uuidString)",
          "vineyardId": "\(UUID().uuidString)",
          "date": 0,
          "startTime": 0,
          "tanks": []
        }
        """
        let record = try JSONDecoder().decode(SprayRecord.self, from: Data(legacyJSON.utf8))
        #expect(record.applicationGeometry == nil)
        #expect(record.tanks.isEmpty)
    }

    @Test("An all-null snapshot normalises to nil so absence has one representation")
    func allNullSnapshotNormalisesToNil() throws {
        let record = SprayRecord(
            sprayReference: "Empty geometry",
            applicationGeometry: SprayApplicationSnapshot()
        )
        #expect(SprayApplicationSnapshot().isEmpty)
        // Round-tripping must collapse the empty struct to nil rather than
        // preserving a row of NULLs that reads as "recorded".
        let reloaded = try encodeDecode(record)
        #expect(reloaded.applicationGeometry == nil)
    }

    @Test("A banded job with no band width records gross but refuses to invent treated")
    func bandedWithoutBandWidthLeavesTreatedNull() {
        let block = SprayBlockInput(
            blockId: "A",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block],
            mode: .banded,
            bandWidth: nil,
            carrier: SprayCarrierVolumeCalculator.perHectare(litresPerHectare: 500, areaHectares: 10),
            tankCapacityLitres: 2_000,
            productLines: []
        )
        let snapshot = SprayApplicationSnapshot(plan: plan)

        #expect(abs((snapshot.grossAreaHa ?? 0) - 10) < tolerance)
        // Never falls back to gross for a banded job — that would overstate the
        // treated area fourfold in this fixture.
        #expect(snapshot.treatedAreaHa == nil)
        #expect(snapshot.treatedAreaMethod == .unavailable)
        #expect(!snapshot.hasGenuineTreatedArea)
    }

    @Test("Zero-valued measurements persist as nil, honouring the sql/191 positivity checks")
    func zeroMeasurementsBecomeNil() {
        let block = SprayBlockInput(blockId: "A", grossAreaHectares: 0, rowSpacingMetres: 3.2)
        let plan = SprayApplicationPlanner.plan(
            blocks: [block],
            mode: .wholeBlock,
            carrier: SprayCarrierVolumeCalculator.perHectare(litresPerHectare: 0, areaHectares: 0),
            tankCapacityLitres: 2_000,
            productLines: []
        )
        let snapshot = SprayApplicationSnapshot(plan: plan)

        // A row length of 0 is not a measurement; it must be NULL so it can
        // never silently dose a tank.
        #expect(snapshot.canonicalRowLengthMetres == nil)
        #expect(snapshot.bandWidthTotalMetres == nil)
        // Non-negative columns may legitimately be 0.
        #expect(snapshot.grossAreaHa == 0)
        #expect(snapshot.totalCarrierLitres == 0)
    }

    // MARK: - Templates: configuration intent, not historical output

    @Test("Template keeps configuration and drops geometry-dependent totals")
    func templateStoresConfigurationNotOutputs() throws {
        let planned = SprayApplicationSnapshot(plan: bandedPlan())
        let template = try #require(planned.templateConfiguration())

        // KEPT — reusable operator intent.
        #expect(template.applicationMode == .banded)
        #expect(abs((template.bandWidthTotalMetres ?? 0) - 0.8) < tolerance)
        #expect(template.carrierVolumeBasis == .litresPerHectare)
        // L/ha mode: the per-hectare figure is what the operator typed, so it is
        // a reusable input.
        #expect(abs((template.carrierLitresPerHectare ?? 0) - 500) < tolerance)

        // CLEARED — recalculated against whatever blocks the next spray selects.
        #expect(template.grossAreaHa == nil)
        #expect(template.treatedAreaHa == nil)
        #expect(template.canonicalRowLengthMetres == nil)
        #expect(template.rowSpacingMetres == nil)
        #expect(template.geometrySource == nil)
        #expect(template.geometryQuality == nil)
        #expect(template.totalCarrierLitres == nil)
        #expect(template.treatedAreaMethod == nil)
    }

    @Test("Template in L/100 m mode drops the derived L/ha but keeps the entered rates")
    func templateDropsDerivedLitresPerHectare() throws {
        let block = SprayBlockInput(
            blockId: "A",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        let geometry = SprayGeometryResolver.resolve([block])
        let carrier = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 8,
                diluteLitresPer100Metres: 16,
                rowLengthMetres: geometry.totalRowLengthMetres,
                rowSpacingMetres: geometry.uniformRowSpacingMetres
            )
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block],
            mode: .wholeBlock,
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: []
        )
        let template = try #require(SprayApplicationSnapshot(plan: plan).templateConfiguration())

        // Entered rates are intent and are reused.
        #expect(abs((template.appliedLitresPer100m ?? 0) - 8) < tolerance)
        #expect(abs((template.diluteLitresPer100m ?? 0) - 16) < tolerance)
        #expect(template.carrierVolumeBasis == .litresPer100Metres)
        // In this mode L/ha was DERIVED from row spacing, so it is an output and
        // must be recalculated for the new blocks.
        #expect(template.carrierLitresPerHectare == nil)
        #expect(template.rowSpacingMetres == nil)
    }

    @Test("Saving a record as a template persists configuration only, at the write boundary")
    func templateRuleIsEnforcedInThePersistenceMapping() {
        let geometry = SprayApplicationSnapshot(plan: bandedPlan())

        let template = SprayRecord(sprayReference: "Reusable", isTemplate: true, applicationGeometry: geometry)
        let templateUpsert = BackendSprayRecord.upsert(from: template, createdBy: nil, clientUpdatedAt: Date())
        // The template must not carry a frozen 31,250 m into next season.
        #expect(templateUpsert.canonicalRowLengthMetres == nil)
        #expect(templateUpsert.treatedAreaHa == nil)
        #expect(templateUpsert.grossAreaHa == nil)
        // ...but it keeps the operator's configuration.
        #expect(templateUpsert.applicationMode == "banded")
        #expect(abs((templateUpsert.bandWidthTotalMetres ?? 0) - 0.8) < tolerance)

        // The very same geometry on a real spray persists in full.
        let spray = SprayRecord(sprayReference: "Actual", isTemplate: false, applicationGeometry: geometry)
        let sprayUpsert = BackendSprayRecord.upsert(from: spray, createdBy: nil, clientUpdatedAt: Date())
        #expect(abs((sprayUpsert.canonicalRowLengthMetres ?? 0) - 31_250) < tolerance)
        #expect(abs((sprayUpsert.treatedAreaHa ?? 0) - 2.5) < tolerance)
        #expect(abs((sprayUpsert.grossAreaHa ?? 0) - 10) < tolerance)
    }

    // MARK: - Backend column round trip

    @Test("Snapshot survives the backend column mapping in both directions")
    func backendColumnRoundTrip() throws {
        let original = SprayApplicationSnapshot(plan: bandedPlan())
        let record = SprayRecord(sprayReference: "Wire", applicationGeometry: original)
        let upsert = BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date())

        // Encode the upsert and decode it back as a server row, which is what a
        // read-after-write actually does.
        let payload = try JSONEncoder().encode(upsert)
        let decoded = try JSONDecoder().decode(BackendSprayRecord.self, from: payload)
        let roundTripped = try #require(decoded.toSprayRecord().applicationGeometry)

        #expect(roundTripped == original)
    }

    @Test("Backend row with no geometry columns maps to a nil snapshot")
    func backendLegacyRowMapsToNil() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "vineyard_id": "\(UUID().uuidString)",
          "tanks": []
        }
        """
        let decoded = try JSONDecoder().decode(BackendSprayRecord.self, from: Data(json.utf8))
        #expect(decoded.toSprayRecord().applicationGeometry == nil)
    }

    @Test("Deprecated stored_row_length geometry source still decodes from storage")
    func deprecatedGeometrySourceDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "vineyard_id": "\(UUID().uuidString)",
          "tanks": [],
          "canonical_row_length_metres": 12345,
          "geometry_source": "stored_row_length"
        }
        """
        let decoded = try JSONDecoder().decode(BackendSprayRecord.self, from: Data(json.utf8))
        let geometry = try #require(decoded.toSprayRecord().applicationGeometry)
        #expect(geometry.geometrySource == .storedRowLength)
        #expect(abs((geometry.canonicalRowLengthMetres ?? 0) - 12_345) < tolerance)
    }

    // MARK: - Per-product rate basis (persisted per chemical line)

    @Test("One tank preserves a different rate basis on every chemical line")
    func mixedProductBasesRoundTrip() throws {
        // The spec's mixed-basis tank: these three lines must stay individually
        // explainable, so the basis lives on the LINE, not on the job.
        let tank = SprayTank(
            tankNumber: 1,
            waterVolume: 6_250,
            sprayRatePerHa: 500,
            concentrationFactor: 1,
            chemicals: [
                SprayChemical(name: "Kelp", ratePerHa: 2, unit: .litres, rateBasis: .wholeBlockArea),
                SprayChemical(name: "Herbicide", ratePerHa: 2, unit: .litres, rateBasis: .treatedArea),
                SprayChemical(name: "Adjuvant", ratePer100L: 100, unit: .millilitres, rateBasis: .per100Litres),
            ]
        )
        let record = SprayRecord(sprayReference: "Mixed", tanks: [tank])
        let reloaded = try encodeDecode(record)

        let chemicals = try #require(reloaded.tanks.first?.chemicals)
        #expect(chemicals.count == 3)
        #expect(chemicals[0].rateBasis == .wholeBlockArea)
        #expect(chemicals[1].rateBasis == .treatedArea)
        #expect(chemicals[2].rateBasis == .per100Litres)
        // Each line keeps its own resolved basis, so a treated-area herbicide
        // can never be silently recomputed against gross hectares.
        #expect(chemicals[1].resolvedRateBasis == .treatedArea)
    }

    @Test("A legacy chemical line resolves to whole-block area, never treated area")
    func legacyChemicalLineResolvesToWholeBlock() throws {
        // A line written before the basis existed.
        let legacy = SprayChemical(name: "Old product", ratePerHa: 2, unit: .litres)
        #expect(legacy.rateBasis == nil)
        // Reading it as treated area would silently under-dose it, because every
        // historical record multiplied the rate by GROSS hectares.
        #expect(legacy.resolvedRateBasis == .wholeBlockArea)

        // And a legacy stored spelling maps deterministically.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Imported",
          "rateBasis": "per_hectare"
        }
        """
        let decoded = try JSONDecoder().decode(SprayChemical.self, from: Data(json.utf8))
        #expect(decoded.rateBasis == .wholeBlockArea)
    }

    @Test("Per-line basis survives the backend tanks JSONB mapping")
    func rateBasisSurvivesBackendMapping() throws {
        let tank = SprayTank(
            tankNumber: 1,
            chemicals: [SprayChemical(name: "Herbicide", ratePerHa: 2, unit: .litres, rateBasis: .treatedArea)]
        )
        let record = SprayRecord(sprayReference: "Basis", tanks: [tank])
        let upsert = BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date())
        let payload = try JSONEncoder().encode(upsert)
        let decoded = try JSONDecoder().decode(BackendSprayRecord.self, from: payload)

        let chemical = try #require(decoded.toSprayRecord().tanks.first?.chemicals.first)
        #expect(chemical.rateBasis == .treatedArea)
    }
}
