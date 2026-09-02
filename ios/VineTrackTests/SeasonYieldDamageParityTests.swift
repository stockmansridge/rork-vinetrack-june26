import XCTest
@testable import VineTrack

/// The shared cross-platform damage contract from
/// `docs/season-yield-damage-parity-fixtures.md`, mirrored by
/// `SeasonYieldDamageParityTest.kt` on Android.
///
/// Two tolerances, deliberately:
///  * **Arithmetic fixtures — `1e-9`.** Areas are supplied, so the loss
///    fraction, reduction and adjusted tonnes are pure arithmetic every
///    platform must reproduce exactly.
///  * **Geometry fixtures — `1e-6`.** Hectares come from each platform's own
///    implementation of the sql/095 projection; identical coordinates still
///    differ in the last bits across Postgres numeric and Swift `Double`.
///
/// Fixture 2 is the defect distinguisher: the retired multiplicative engine
/// returned a *remaining* factor of 0.8 and an adjusted 1.728 t for a 20%
/// record over 10% of a block. The correct answer is a 2% loss → 2.1168 t.
final class SeasonYieldDamageParityTests: XCTestCase {

    /// Arithmetic must agree exactly.
    private let arithmeticAccuracy = 1e-9
    /// Polygon → hectares only agrees to a practical tolerance.
    private let geometryAccuracy = 1e-6

    private let blockA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let blockB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    // Shared block fixtures (§2 of the contract doc).
    private let blockAAreaHa = 2.0
    private let blockBAreaHa = 1.5
    private let blockABaseTonnes = 2.16       // V2027
    private let blockABaseTonnesV2026 = 1.8
    private let blockBBaseTonnes = 3.6

    // MARK: - Helpers

    private func mapped(_ areaHectares: Double, _ damagePercent: Double) -> SeasonYieldDamage.MappedRecord {
        SeasonYieldDamage.MappedRecord(areaHectares: areaHectares, damagePercent: damagePercent)
    }

    private func damage(
        block: UUID,
        areaHa: Double,
        _ records: [SeasonYieldDamage.MappedRecord],
        excluded: Int = 0
    ) -> SeasonYieldDamage.BlockDamage {
        SeasonYieldDamage.blockDamage(
            paddockId: block,
            blockAreaHectares: areaHa,
            mappedRecords: records,
            excludedRecordCount: excluded
        )
    }

    /// Loss fraction and remaining multiplier must always be complements —
    /// reading one under the other's name inverts the answer.
    private func assertComplementary(
        _ result: SeasonYieldDamage.BlockDamage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            result.damageLossFraction + result.remainingYieldMultiplier,
            1.0,
            accuracy: arithmeticAccuracy,
            "loss fraction and remaining multiplier must sum to 1",
            file: file,
            line: line
        )
    }

    // MARK: - Fixture 1 — No damage

    func testFixture1NoDamageLeavesBaseUntouched() {
        let result = damage(block: blockA, areaHa: blockAAreaHa, [])

        XCTAssertEqual(result.eligibleRecordCount, 0)
        XCTAssertEqual(result.mappedAreaHectares, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.effectiveLossHectares, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.damageLossFraction, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.remainingYieldMultiplier, 1, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.reductionTonnes(base: blockABaseTonnes), 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.adjustedTonnes(base: blockABaseTonnes), 2.16, accuracy: arithmeticAccuracy)
        XCTAssertTrue(result.warnings.isEmpty)
        assertComplementary(result)
    }

    // MARK: - Fixture 2 — 20% intensity over 10% of the block (defect distinguisher)

    func testFixture2TwentyPercentOverTenPercentOfBlockIsATwoPercentLoss() {
        let result = damage(block: blockA, areaHa: blockAAreaHa, [mapped(0.2, 20)])

        XCTAssertEqual(result.eligibleRecordCount, 1)
        XCTAssertEqual(result.mappedAreaHectares, 0.2, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.effectiveLossHectares, 0.04, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.damageLossFraction, 0.02, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.remainingYieldMultiplier, 0.98, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.reductionTonnes(base: blockABaseTonnes), 0.0432, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.adjustedTonnes(base: blockABaseTonnes), 2.1168, accuracy: arithmeticAccuracy)
        assertComplementary(result)

        // The retired multiplicative engine's answer, explicitly rejected.
        XCTAssertNotEqual(result.adjustedTonnes(base: blockABaseTonnes), 1.728, accuracy: 1e-6)
    }

    // MARK: - Fixture 3 — Multiple non-overlapping records

    func testFixture3MultipleRecordsSumTheirEffectiveLossAreas() {
        let result = damage(
            block: blockA,
            areaHa: blockAAreaHa,
            [mapped(0.2, 20), mapped(0.3, 10)]
        )

        XCTAssertEqual(result.eligibleRecordCount, 2)
        XCTAssertEqual(result.mappedAreaHectares, 0.5, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.effectiveLossHectares, 0.07, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.damageLossFraction, 0.035, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.remainingYieldMultiplier, 0.965, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.reductionTonnes(base: blockABaseTonnes), 0.0756, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.adjustedTonnes(base: blockABaseTonnes), 2.0844, accuracy: arithmeticAccuracy)
        assertComplementary(result)
    }

    // MARK: - Fixture 4 — Combined loss capped at 100% per block

    func testFixture4CombinedLossIsCappedAtWholeBlock() {
        // 2.0 ha @ 100% + 2.0 ha @ 30% = 2.6 ha effective loss on a 2.0 ha
        // block → 1.3, capped to 1.0.
        let result = damage(
            block: blockA,
            areaHa: blockAAreaHa,
            [mapped(2.0, 100), mapped(2.0, 30)]
        )

        XCTAssertEqual(result.mappedAreaHectares, 4.0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.effectiveLossHectares, 2.6, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.damageLossFraction, 1.0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.remainingYieldMultiplier, 0.0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.reductionTonnes(base: blockABaseTonnes), 2.16, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.adjustedTonnes(base: blockABaseTonnes), 0.0, accuracy: arithmeticAccuracy)
        XCTAssertGreaterThanOrEqual(result.adjustedTonnes(base: blockABaseTonnes), 0)
        assertComplementary(result)
    }

    func testFixture4WholeBlockAtFullIntensityLosesExactlyEverything() {
        let result = damage(block: blockA, areaHa: blockAAreaHa, [mapped(2.0, 100)])

        XCTAssertEqual(result.mappedAreaHectares, 2.0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.effectiveLossHectares, 2.0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.damageLossFraction, 1.0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.adjustedTonnes(base: blockABaseTonnes), 0.0, accuracy: arithmeticAccuracy)
        assertComplementary(result)
    }

    // MARK: - Fixture 5 — Two vintages, damage in only one

    func testFixture5DamageAppliesOnlyToItsOwnVintage() {
        // V2026 carries the record; V2027 has none. Each vintage is its own
        // calculation over its own base.
        let v2026 = damage(block: blockA, areaHa: blockAAreaHa, [mapped(0.2, 20)])
        XCTAssertEqual(v2026.damageLossFraction, 0.02, accuracy: arithmeticAccuracy)
        XCTAssertEqual(
            v2026.reductionTonnes(base: blockABaseTonnesV2026),
            0.036,
            accuracy: arithmeticAccuracy
        )
        XCTAssertEqual(
            v2026.adjustedTonnes(base: blockABaseTonnesV2026),
            1.764,
            accuracy: arithmeticAccuracy
        )

        let v2027 = damage(block: blockA, areaHa: blockAAreaHa, [])
        XCTAssertEqual(v2027.damageLossFraction, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(
            v2027.adjustedTonnes(base: blockABaseTonnes),
            2.16,
            accuracy: arithmeticAccuracy
        )
    }

    /// The vintage filter itself: `damage_records.vintage` decides, and a
    /// record that has not synced falls back to the local season resolver.
    func testDamageRecordsAreFilteredByServerResolvedVintage() {
        let vineyard = UUID()
        let synced2027 = DamageRecord(
            vineyardId: vineyard,
            paddockId: blockA,
            date: date(2027, 3, 1),
            damagePercent: 20,
            vintage: 2027
        )
        let synced2026 = DamageRecord(
            vineyardId: vineyard,
            paddockId: blockA,
            date: date(2027, 3, 1), // date says 2027; the SERVER says 2026
            damagePercent: 20,
            vintage: 2026
        )
        let otherVineyard = DamageRecord(
            vineyardId: UUID(),
            paddockId: blockA,
            date: date(2027, 3, 1),
            damagePercent: 20,
            vintage: 2027
        )

        let scoped = SeasonYieldProjection.damageRecords(
            [synced2027, synced2026, otherVineyard],
            vineyardId: vineyard,
            vintage: 2027,
            seasonStartMonth: 9,
            seasonStartDay: 1
        )

        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.id, synced2027.id)
    }

    func testUnsyncedRecordFallsBackToLocalSeasonResolver() {
        // 2 Sep 2026 with a 1 Sep season start is vineyard-local Vintage 2027.
        let unsynced = DamageRecord(
            vineyardId: UUID(),
            paddockId: blockA,
            date: date(2026, 9, 2),
            damagePercent: 20,
            vintage: nil
        )
        XCTAssertEqual(
            unsynced.resolvedVintage(seasonStartMonth: 9, seasonStartDay: 1),
            2027
        )
    }

    // MARK: - Fixture 6 / 9 — Ineligible and invalid records are excluded

    func testFixture6PolygonlessRecordIsExcludedAndWarns() {
        let result = damage(block: blockA, areaHa: blockAAreaHa, [], excluded: 1)

        XCTAssertEqual(result.eligibleRecordCount, 0)
        XCTAssertEqual(result.excludedRecordCount, 1)
        XCTAssertEqual(result.mappedAreaHectares, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.damageLossFraction, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.adjustedTonnes(base: blockABaseTonnes), 2.16, accuracy: arithmeticAccuracy)
        XCTAssertTrue(result.warnings.contains(SeasonYieldDamage.warningRecordWithoutPolygon))
    }

    func testFixture9InvalidPolygonsAreAllRejectedBeforeAnyAreaMaths() {
        let twoPoints = [
            SeasonYieldDamage.Point(latitude: -33.0, longitude: 149.0),
            SeasonYieldDamage.Point(latitude: -33.0, longitude: 149.002)
        ]
        let nonFinite = [
            SeasonYieldDamage.Point(latitude: -33.0, longitude: 149.0),
            SeasonYieldDamage.Point(latitude: -33.0, longitude: .nan),
            SeasonYieldDamage.Point(latitude: -33.002, longitude: 149.002)
        ]
        let latitudeOutOfRange = [
            SeasonYieldDamage.Point(latitude: -91.5, longitude: 149.0),
            SeasonYieldDamage.Point(latitude: -33.0, longitude: 149.002),
            SeasonYieldDamage.Point(latitude: -33.002, longitude: 149.002)
        ]
        let longitudeOutOfRange = [
            SeasonYieldDamage.Point(latitude: -33.0, longitude: 149.0),
            SeasonYieldDamage.Point(latitude: -33.0, longitude: 180.5),
            SeasonYieldDamage.Point(latitude: -33.002, longitude: 149.002)
        ]
        let infinite = [
            SeasonYieldDamage.Point(latitude: -33.0, longitude: 149.0),
            SeasonYieldDamage.Point(latitude: .infinity, longitude: 149.002),
            SeasonYieldDamage.Point(latitude: -33.002, longitude: 149.002)
        ]

        for polygon in [twoPoints, nonFinite, latitudeOutOfRange, longitudeOutOfRange, infinite] {
            XCTAssertFalse(SeasonYieldDamage.isValidPolygon(polygon))
            XCTAssertEqual(SeasonYieldDamage.areaHectares(polygon: polygon), 0, accuracy: arithmeticAccuracy)
        }

        let records = [twoPoints, nonFinite, latitudeOutOfRange, longitudeOutOfRange].map {
            SeasonYieldDamage.Record(id: UUID(), paddockId: blockA, damagePercent: 50, polygon: $0)
        }
        let result = SeasonYieldDamage.blockDamage(
            paddockId: blockA,
            blockAreaHectares: blockAAreaHa,
            records: records
        )

        XCTAssertEqual(result.eligibleRecordCount, 0)
        XCTAssertEqual(result.excludedRecordCount, 4)
        XCTAssertEqual(result.mappedAreaHectares, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.damageLossFraction, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.adjustedTonnes(base: blockABaseTonnes), 2.16, accuracy: arithmeticAccuracy)
        XCTAssertTrue(result.warnings.contains(SeasonYieldDamage.warningRecordWithoutPolygon))
    }

    /// A block with no usable area cannot produce a loss fraction, and must
    /// not guess 0% or 100%.
    func testBlockWithoutAreaWarnsAndKeepsBaseFigures() {
        let result = damage(block: blockA, areaHa: 0, [mapped(0.2, 20)])

        XCTAssertNil(result.blockAreaHectares)
        XCTAssertTrue(result.isAreaUnavailable)
        XCTAssertEqual(result.damageLossFraction, 0, accuracy: arithmeticAccuracy)
        XCTAssertEqual(result.adjustedTonnes(base: blockABaseTonnes), 2.16, accuracy: arithmeticAccuracy)
        XCTAssertTrue(result.warnings.contains(SeasonYieldDamage.warningBlockAreaUnavailable))
    }

    // MARK: - Fixture 7 — Two blocks, only one damaged

    func testFixture7BlocksAreCalculatedIndependentlyThenSummed() {
        let a = damage(block: blockA, areaHa: blockAAreaHa, [mapped(0.2, 20)])
        let b = damage(block: blockB, areaHa: blockBAreaHa, [])

        XCTAssertEqual(a.damageLossFraction, 0.02, accuracy: arithmeticAccuracy)
        XCTAssertEqual(b.damageLossFraction, 0, accuracy: arithmeticAccuracy)

        let adjustedA = a.adjustedTonnes(base: blockABaseTonnes)
        let adjustedB = b.adjustedTonnes(base: blockBBaseTonnes)
        XCTAssertEqual(adjustedA, 2.1168, accuracy: arithmeticAccuracy)
        XCTAssertEqual(adjustedB, 3.6, accuracy: arithmeticAccuracy)

        // Vineyard totals are sums of per-block figures; no vineyard-wide
        // loss fraction is ever computed.
        XCTAssertEqual(blockABaseTonnes + blockBBaseTonnes, 5.76, accuracy: arithmeticAccuracy)
        XCTAssertEqual(adjustedA + adjustedB, 5.7168, accuracy: arithmeticAccuracy)
    }

    // MARK: - Fixture 8 — Mixed-variety block, loss applied proportionally

    func testFixture8BlockLossFractionAppliesToEveryPlantingGroup() {
        let block = damage(block: blockA, areaHa: blockAAreaHa, [mapped(0.2, 20)])
        let multiplier = block.remainingYieldMultiplier

        let shiraz = 1.296      // 60%
        let cabernet = 0.648    // 30%
        let unallocated = 0.216 // 10%

        XCTAssertEqual(shiraz * multiplier, 1.27008, accuracy: arithmeticAccuracy)
        XCTAssertEqual(cabernet * multiplier, 0.63504, accuracy: arithmeticAccuracy)
        XCTAssertEqual(unallocated * multiplier, 0.21168, accuracy: arithmeticAccuracy)

        XCTAssertEqual(shiraz * block.damageLossFraction, 0.02592, accuracy: arithmeticAccuracy)
        XCTAssertEqual(cabernet * block.damageLossFraction, 0.01296, accuracy: arithmeticAccuracy)
        XCTAssertEqual(unallocated * block.damageLossFraction, 0.00432, accuracy: arithmeticAccuracy)

        // The groups still sum to the block total.
        XCTAssertEqual(
            (shiraz + cabernet + unallocated) * multiplier,
            2.1168,
            accuracy: arithmeticAccuracy
        )
        XCTAssertEqual(shiraz + cabernet + unallocated, blockABaseTonnes, accuracy: arithmeticAccuracy)
    }

    // MARK: - Geometry (practical tolerance)

    func testPolygonAreaMatchesTheSharedProjection() {
        // A ~200 m × 100 m rectangle near Mudgee, NSW.
        let polygon = [
            SeasonYieldDamage.Point(latitude: -32.5, longitude: 149.5),
            SeasonYieldDamage.Point(latitude: -32.5, longitude: 149.5 + 0.002),
            SeasonYieldDamage.Point(latitude: -32.5 - 0.001, longitude: 149.5 + 0.002),
            SeasonYieldDamage.Point(latitude: -32.5 - 0.001, longitude: 149.5)
        ]

        // Reference: the same equirectangular projection sql/095 uses.
        let metresPerDegreeLatitude = 111_320.0
        let metresPerDegreeLongitude = 111_320.0 * cos((-32.5005) * .pi / 180.0)
        let expected = (0.002 * metresPerDegreeLongitude)
            * (0.001 * metresPerDegreeLatitude)
            / 10_000.0

        XCTAssertEqual(
            SeasonYieldDamage.areaHectares(polygon: polygon),
            expected,
            accuracy: geometryAccuracy
        )
    }

    /// The engine's polygon path and its arithmetic core must agree.
    func testPolygonPathMatchesArithmeticCore() {
        let polygon = [
            SeasonYieldDamage.Point(latitude: -32.5, longitude: 149.5),
            SeasonYieldDamage.Point(latitude: -32.5, longitude: 149.502),
            SeasonYieldDamage.Point(latitude: -32.501, longitude: 149.502),
            SeasonYieldDamage.Point(latitude: -32.501, longitude: 149.5)
        ]
        let area = SeasonYieldDamage.areaHectares(polygon: polygon)

        let viaPolygon = SeasonYieldDamage.blockDamage(
            paddockId: blockA,
            blockAreaHectares: blockAAreaHa,
            records: [
                SeasonYieldDamage.Record(id: UUID(), paddockId: blockA, damagePercent: 20, polygon: polygon)
            ]
        )
        let viaArithmetic = damage(block: blockA, areaHa: blockAAreaHa, [mapped(area, 20)])

        XCTAssertEqual(
            viaPolygon.damageLossFraction,
            viaArithmetic.damageLossFraction,
            accuracy: geometryAccuracy
        )
        XCTAssertEqual(
            viaPolygon.adjustedTonnes(base: blockABaseTonnes),
            viaArithmetic.adjustedTonnes(base: blockABaseTonnes),
            accuracy: geometryAccuracy
        )
    }

    // MARK: - Intensity clamping

    func testIntensityIsClampedToZeroHundred() {
        let over = damage(block: blockA, areaHa: blockAAreaHa, [mapped(0.2, 150)])
        XCTAssertEqual(over.effectiveLossHectares, 0.2, accuracy: arithmeticAccuracy)

        let under = damage(block: blockA, areaHa: blockAAreaHa, [mapped(0.2, -20)])
        XCTAssertEqual(under.effectiveLossHectares, 0, accuracy: arithmeticAccuracy)
    }

    // MARK: - Utilities

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }
}
