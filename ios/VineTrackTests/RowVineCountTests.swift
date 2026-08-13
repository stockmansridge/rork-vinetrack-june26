import Foundation
import Testing
@testable import VineTrack

/// PER-ROW VINE COUNTS (sql/188) — the iOS twin of `RowVineCountTest.kt`.
/// Both suites assert the SAME fixtures from the SAME coordinates, so any
/// divergence between the platforms fails a build.
///
/// THE rule under test:
/// ```text
/// calculatedVineCount = round(row length in metres ÷ vine spacing in metres)
/// effectiveVineCount  = vineCountOverride ?? calculatedVineCount
/// ```
///
/// Both inputs already exist in the app — the row's own start/end geometry and
/// the BLOCK's vine spacing — so a grower who only ever uses the phone gets a
/// vine count for every row without typing anything.
struct RowVineCountTests {

    // MARK: - Shared fixtures (identical on Android)

    /// The block's vine spacing. Everything below divides by this.
    private let vineSpacing: Double = 1.5

    private let baseLatitude: Double = -34.5121
    private let baseLongitude: Double = 138.7128

    /// Metres per degree of latitude — the constant the production geometry
    /// helpers use. Building rows that run due north/south makes their length
    /// exact regardless of the longitude scale factor.
    private let metresPerDegreeLatitude: Double = 111_320.0

    /// A realistic vineyard row: runs due north for `lengthMetres`, offset east
    /// by `index` row widths. Real coordinates, not hand-fed distances.
    private func row(
        number: Int,
        lengthMetres: Double,
        index: Int,
        override: Int? = nil,
        id: UUID? = nil
    ) -> PaddockRow {
        let longitude = baseLongitude + Double(index) * 0.000027
        return PaddockRow(
            id: id ?? UUID(),
            number: number,
            startPoint: CoordinatePoint(latitude: baseLatitude, longitude: longitude),
            endPoint: CoordinatePoint(
                latitude: baseLatitude + lengthMetres / metresPerDegreeLatitude,
                longitude: longitude
            ),
            vineCountOverride: override
        )
    }

    /// THE fixture block, shared verbatim with the Android suite:
    ///
    /// ```text
    /// Row 42 — 240 m → 160 calculated, manual override 158
    /// Row 43 — 252 m → 168 calculated
    /// Row 44 — 250 m → 166.67 → 167 calculated
    /// ```
    private func fixtureBlock() -> Paddock {
        Paddock(
            name: "Piece Rate Fixture",
            rows: [
                row(number: 42, lengthMetres: 240, index: 0, override: 158),
                row(number: 43, lengthMetres: 252, index: 1),
                row(number: 44, lengthMetres: 250, index: 2)
            ],
            vineSpacing: vineSpacing
        )
    }

    private func rowNumbered(_ number: Int, in paddock: Paddock) throws -> PaddockRow {
        try #require(paddock.rows.first { $0.number == number })
    }

    // MARK: - 1. The calculation happens automatically

    @Test func aRowsVinesAreCalculatedFromItsOwnGeometryAndTheBlocksVineSpacing() throws {
        let paddock = fixtureBlock()
        let row44 = try rowNumbered(44, in: paddock)

        // The row is 250 m of real mapped geometry.
        #expect(abs(paddock.rowLengthMetres(row44) - 250) < 0.01)

        // 250 ÷ 1.5 = 166.67 → 167 vines. Nothing was typed to get this.
        #expect(paddock.calculatedVineCount(for: row44) == 167)
    }

    @Test func theRoundingRuleIsHalfAwayFromZeroOnWholeVines() {
        // The worked example from the contract.
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 250, vineSpacing: 1.5) == 167)
        // Exactly on a vine.
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 252, vineSpacing: 1.5) == 168)
        // Just below the half — rounds down.
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 249.7, vineSpacing: 1.5) == 166)
        // Exactly on the half — rounds away from zero.
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 249.75, vineSpacing: 1.5) == 167)
        // The rounding primitive itself, including the negative direction the
        // Kotlin twin has to mirror explicitly.
        #expect(PaddockRowVineCount.roundVines(166.5) == 167)
        #expect(PaddockRowVineCount.roundVines(-166.5) == -167)
        #expect(PaddockRowVineCount.roundVines(166.4999) == 166)
    }

    // MARK: - 2/3/4. Override precedence

    @Test func withNoOverrideTheEffectiveCountIsTheCalculatedOne() throws {
        let paddock = fixtureBlock()
        let row44 = try rowNumbered(44, in: paddock)
        #expect(row44.vineCountOverride == nil)
        #expect(paddock.calculatedVineCount(for: row44) == 167)
        #expect(paddock.effectiveVineCount(for: row44) == 167)
    }

    @Test func aManualOverrideWinsOverTheCalculatedCount() throws {
        let paddock = fixtureBlock()
        let row42 = try rowNumbered(42, in: paddock)
        // 240 m ÷ 1.5 = 160 calculated, but the operator counted 158.
        #expect(paddock.calculatedVineCount(for: row42) == 160)
        #expect(paddock.effectiveVineCount(for: row42) == 158)
    }

    @Test func clearingTheOverrideReturnsToTheCalculatedCount() throws {
        var paddock = fixtureBlock()
        var row42 = try rowNumbered(42, in: paddock)
        #expect(paddock.effectiveVineCount(for: row42) == 158)

        row42.vineCountOverride = nil
        paddock.rows = paddock.rows.map { $0.number == 42 ? row42 : $0 }

        let cleared = try rowNumbered(42, in: paddock)
        #expect(paddock.effectiveVineCount(for: cleared) == 160)
        #expect(paddock.calculatedVineCount(for: cleared) == 160)
    }

    @Test func zeroAndNegativeAreNotOverridesAtAll() {
        #expect(PaddockRowVineCount.effective(override: 0, rowLengthMetres: 250, vineSpacing: 1.5) == 167)
        #expect(PaddockRowVineCount.effective(override: -5, rowLengthMetres: 250, vineSpacing: 1.5) == 167)
        #expect(PaddockRowVineCount.sanitiseOverride(0) == nil)
        #expect(PaddockRowVineCount.sanitiseOverride(-5) == nil)
    }

    // MARK: - 5. Each row is measured individually

    @Test func rowsOfDifferentLengthsGetDifferentVineCounts() {
        // An irregular boundary: every row a different length. The block
        // average would report the same number for all three, which is exactly
        // the bug this rule exists to prevent.
        let paddock = Paddock(
            name: "Irregular",
            rows: [
                row(number: 1, lengthMetres: 120, index: 0),
                row(number: 2, lengthMetres: 250, index: 1),
                row(number: 3, lengthMetres: 318, index: 2)
            ],
            vineSpacing: vineSpacing
        )
        let counts = paddock.rows.compactMap { paddock.calculatedVineCount(for: $0) }
        #expect(counts == [80, 167, 212])
        // And the average-length shortcut would have been wrong for all three.
        let averageBased = PaddockRowVineCount.calculated(
            rowLengthMetres: (120 + 250 + 318) / 3,
            vineSpacing: vineSpacing
        )
        #expect(averageBased == 153)
        #expect(!counts.contains(153))
    }

    // MARK: - 6/7. Missing data is "—", never 0

    @Test func missingVineSpacingMakesTheCountUnavailableRatherThanZero() {
        let calculation = PaddockRowVineCount.calculation(rowLengthMetres: 250, vineSpacing: 0)
        #expect(calculation.value == nil)
        #expect(calculation.unavailable == .missingVineSpacing)
        #expect(calculation.message == "Set vine spacing in block details to calculate vines.")

        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 250, vineSpacing: nil) == nil)
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 250, vineSpacing: -1) == nil)
        // A manual count still works with no spacing — it needs no calculation.
        #expect(PaddockRowVineCount.effective(override: 158, rowLengthMetres: 250, vineSpacing: 0) == 158)
        // …but with neither, there is genuinely nothing to show.
        #expect(PaddockRowVineCount.effective(override: nil, rowLengthMetres: 250, vineSpacing: 0) == nil)
    }

    @Test func invalidRowGeometryMakesTheCountUnavailableRatherThanZero() {
        let calculation = PaddockRowVineCount.calculation(rowLengthMetres: 0, vineSpacing: 1.5)
        #expect(calculation.value == nil)
        #expect(calculation.unavailable == .invalidGeometry)

        // An unmapped row: start and end at the same place.
        let unmapped = PaddockRow(
            number: 9,
            startPoint: CoordinatePoint(latitude: baseLatitude, longitude: baseLongitude),
            endPoint: CoordinatePoint(latitude: baseLatitude, longitude: baseLongitude)
        )
        let paddock = Paddock(name: "Unmapped", rows: [unmapped], vineSpacing: vineSpacing)
        #expect(paddock.calculatedVineCount(for: unmapped) == nil)
        #expect(paddock.effectiveVineCount(for: unmapped) == nil)
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: .nan, vineSpacing: 1.5) == nil)
    }

    // MARK: - 8. The override survives save/reload

    @Test func aRowsManualCountSurvivesASaveAndReload() throws {
        let paddock = fixtureBlock()
        let encoded = try JSONEncoder().encode(paddock.rows)
        let reloaded = try JSONDecoder().decode([PaddockRow].self, from: encoded)

        let row42 = try #require(reloaded.first { $0.number == 42 })
        #expect(row42.vineCountOverride == 158)
        // Its stable id came back too, so pruning progress stays attached.
        let originalRow42 = try rowNumbered(42, in: paddock)
        #expect(row42.id == originalRow42.id)

        // Rows the operator never overrode keep the EXACT older JSON shape —
        // the key is absent, not null, so the portal parses them unchanged.
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.components(separatedBy: "vineCountOverride").count - 1 == 1)

        var rebuilt = paddock
        rebuilt.rows = reloaded
        #expect(rebuilt.effectiveVineCount(for: row42) == 158)
    }

    // MARK: - 9. The override survives geometry regeneration

    @Test func aRowsManualCountSurvivesOrdinaryGeometryRegeneration() throws {
        let existing = fixtureBlock().rows
        // The editor rebuilds every row from the boundary — fresh ids, slightly
        // different lengths, no overrides.
        let regenerated = [
            row(number: 42, lengthMetres: 244, index: 0),
            row(number: 43, lengthMetres: 256, index: 1),
            row(number: 44, lengthMetres: 254, index: 2)
        ]
        let preserved = PaddockRowRegeneration.preserveIdentity(
            regenerated: regenerated,
            existing: existing
        )

        let row42 = try #require(preserved.first { $0.number == 42 })
        let existingRow42 = try #require(existing.first { $0.number == 42 })
        // Identity AND the manual count carried across.
        #expect(row42.id == existingRow42.id)
        #expect(row42.vineCountOverride == 158)
        // The NEW geometry is in use, so untouched rows re-calculate.
        let paddock = Paddock(name: "Regenerated", rows: preserved, vineSpacing: vineSpacing)
        #expect(paddock.calculatedVineCount(for: row42) == 163)
        #expect(paddock.effectiveVineCount(for: row42) == 158)
        let row44 = try rowNumbered(44, in: paddock)
        #expect(paddock.effectiveVineCount(for: row44) == 169)

        // A genuinely new row keeps its fresh id and has no manual count.
        let grown = PaddockRowRegeneration.preserveIdentity(
            regenerated: regenerated + [row(number: 45, lengthMetres: 250, index: 3)],
            existing: existing
        )
        let row45 = try #require(grown.first { $0.number == 45 })
        #expect(row45.vineCountOverride == nil)
    }

    // MARK: - 10. Row-based block total

    @Test func theRowBasedBlockTotalIsTheSumOfTheEffectiveCounts() {
        let paddock = fixtureBlock()
        // 158 (manual) + 168 + 167 = 493
        #expect(paddock.rowsEffectiveVineCount == 493)
        #expect(paddock.hasRowVineCountOverrides)

        // The BLOCK-level override is a separate number and is NOT touched by
        // any of this (sql/188 keeps the two independent).
        var withBlockOverride = paddock
        withBlockOverride.vineCountOverride = 500
        #expect(withBlockOverride.effectiveVineCount == 500)
        #expect(withBlockOverride.rowsEffectiveVineCount == 493)
    }

    // MARK: - 11/12. Piece rate uses the effective counts automatically

    @Test func pieceRateCostsTheSelectedRowsAtTheirEffectiveCounts() throws {
        let paddock = fixtureBlock()
        let workTaskId = UUID()
        let vineyardId = UUID()

        let snapshot = PieceRateCosting.snapshotRows(
            workTaskId: workTaskId,
            vineyardId: vineyardId,
            paddock: paddock,
            selectedRowIds: Set(paddock.rows.map(\.id))
        )

        // Row 42 manual 158, row 43 calculated 168, row 44 calculated 167.
        #expect(snapshot.compactMap(\.rowNumber) == [42, 43, 44])
        #expect(snapshot.map(\.vineCount) == [158, 168, 167])

        // The operator selected rows and typed a rate — never a quantity.
        let vineCount = PieceRateCosting.vineCount(forSelectedRows: snapshot)
        #expect(vineCount == 493)

        let cost = try #require(PieceRateCosting.cost(vineCount: vineCount, ratePerVine: 1.27))
        #expect(abs(cost - 626.11) < 0.0001)
        #expect(PieceRateCosting.currencyLabel(cost) == "$626.11")
        #expect(PieceRateCosting.isValid(ratePerVine: 1.27, vineCount: vineCount))
    }

    @Test func selectingASubsetCostsOnlyThoseRows() throws {
        let paddock = fixtureBlock()
        let row44 = try rowNumbered(44, in: paddock)
        let snapshot = PieceRateCosting.snapshotRows(
            workTaskId: UUID(),
            vineyardId: UUID(),
            paddock: paddock,
            selectedRowIds: [row44.id]
        )
        #expect(snapshot.map(\.vineCount) == [167])
        #expect(PieceRateCosting.vineCount(forSelectedRows: snapshot) == 167)
    }

    // MARK: - 13. The historical snapshot never re-prices

    @Test func laterRowEditsNeverChangeAFinishedPieceRateJob() throws {
        var paddock = fixtureBlock()
        let snapshot = PieceRateCosting.snapshotRows(
            workTaskId: UUID(),
            vineyardId: UUID(),
            paddock: paddock,
            selectedRowIds: []
        )
        let quantityAtCostingTime = PieceRateCosting.vineCount(forSelectedRows: snapshot)
        #expect(quantityAtCostingTime == 493)

        // Six months later the block is re-surveyed: the spacing changes, the
        // rows are re-mapped longer, and the manual count is cleared.
        paddock.vineSpacing = 1.2
        paddock.rows = [
            row(number: 42, lengthMetres: 300, index: 0),
            row(number: 43, lengthMetres: 310, index: 1),
            row(number: 44, lengthMetres: 305, index: 2)
        ]
        #expect(paddock.rowsEffectiveVineCount == 762)

        // The finished job is costed from its SNAPSHOT, so it is unmoved.
        let resolved = PieceRateCosting.resolve(
            method: .pieceRate,
            labourLines: [],
            pieceVineCount: quantityAtCostingTime,
            pieceRatePerVine: 1.27
        )
        let cost = try #require(resolved.cost)
        #expect(abs(cost - 626.11) < 0.0001)
        #expect(snapshot.map(\.vineCount) == [158, 168, 167])

        // A NEW job started today does use today's numbers.
        let today = PieceRateCosting.snapshotRows(
            workTaskId: UUID(),
            vineyardId: UUID(),
            paddock: paddock,
            selectedRowIds: []
        )
        #expect(PieceRateCosting.vineCount(forSelectedRows: today) == 762)
    }

    // MARK: - Override input validation

    @Test func theOverrideFieldTakesWholePositiveNumbersOnly() {
        #expect(PaddockRowVineCount.parseOverride("") == .cleared)
        #expect(PaddockRowVineCount.parseOverride("   ") == .cleared)
        #expect(PaddockRowVineCount.parseOverride("158") == .valid(158))
        #expect(PaddockRowVineCount.parseOverride(" 158 ") == .valid(158))
        #expect(PaddockRowVineCount.parseOverride("158.5").isInvalid)
        #expect(PaddockRowVineCount.parseOverride("-5").isInvalid)
        #expect(PaddockRowVineCount.parseOverride("0").isInvalid)
        #expect(PaddockRowVineCount.parseOverride("abc").isInvalid)
        #expect(PaddockRowVineCount.parseOverride("100001").isInvalid)
        #expect(PaddockRowVineCount.parseOverride("100000") == .valid(100_000))
    }
}
