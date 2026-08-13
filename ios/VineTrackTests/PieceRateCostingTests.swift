import Foundation
import Testing
@testable import VineTrack

/// PIECE RATE COSTING (sql/188) — the iOS twin of `PieceRateCostingTest.kt`.
/// Both suites assert the SAME fixtures, so any divergence between the
/// platforms fails a build.
///
/// The rules under test:
/// * a task's labour cost comes from EXACTLY ONE source, chosen by
///   `costing_method` — hourly lines and a piece-rate total are never summed;
/// * hours stay recordable on a piece-rate job as operational history but NEVER
///   drive its cost;
/// * a completed piece-rate job is costed from its SNAPSHOT, so later edits to
///   the block's rows can never re-price finished work;
/// * every legacy record resolves to `.hourly` and behaves exactly as before.
struct PieceRateCostingTests {

    private let taskId = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let paddockId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func line(
        hoursPerWorker: Double,
        workerCount: Int = 1,
        hourlyRate: Double? = nil
    ) -> WorkTaskLabourLine {
        WorkTaskLabourLine(
            workTaskId: taskId,
            vineyardId: vineyardId,
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate
        )
    }

    private func snapshotRow(vineCount: Int, rowNumber: Int) -> WorkTaskPieceRateRow {
        WorkTaskPieceRateRow(
            workTaskId: taskId,
            vineyardId: vineyardId,
            paddockId: paddockId,
            paddockRowId: UUID(),
            rowNumber: rowNumber,
            vineCount: vineCount
        )
    }

    // MARK: - Method resolution — legacy records must not change behaviour

    @Test func legacyAndUnknownCostingMethodsResolveToHourly() {
        #expect(WorkTaskCostingMethod.resolve(nil) == .hourly)
        #expect(WorkTaskCostingMethod.resolve("") == .hourly)
        #expect(WorkTaskCostingMethod.resolve("   ") == .hourly)
        #expect(WorkTaskCostingMethod.resolve("hourly") == .hourly)
        #expect(WorkTaskCostingMethod.resolve("HOURLY") == .hourly)
        // Anything a future client writes that this build does not understand
        // falls back to the behaviour every record has always had.
        #expect(WorkTaskCostingMethod.resolve("per_bin") == .hourly)
    }

    @Test func pieceRateIsDecodedCaseInsensitivelyFromItsStoredValue() {
        #expect(WorkTaskCostingMethod.resolve("piece_rate") == .pieceRate)
        #expect(WorkTaskCostingMethod.resolve("  Piece_Rate  ") == .pieceRate)
        #expect(WorkTaskCostingMethod.pieceRate.rawValue == "piece_rate")
        #expect(WorkTaskCostingMethod.hourly.rawValue == "hourly")
    }

    // MARK: - Arithmetic — identical to the Kotlin twin, to the cent

    @Test func costIsVinesTimesRateRoundedToCents() throws {
        // THE worked example carried in both platforms' documentation.
        let costed = try #require(PieceRateCosting.cost(vineCount: 2_238, ratePerVine: 1.27))
        #expect(abs(costed - 2_842.26) < 0.0001)
        #expect(PieceRateCosting.cost(vineCount: 0, ratePerVine: 1.27) == 0)
        #expect(PieceRateCosting.cost(vineCount: 1, ratePerVine: 1.27) == 1.27)
        // Half away from zero, matching the database's round(numeric, 2).
        #expect(abs(PieceRateCosting.roundedToCents(0.125) - 0.13) < 0.0001)
        #expect(abs(PieceRateCosting.roundedToCents(9.995) - 10.0) < 0.0001)
    }

    @Test func aMissingRateOrQuantityIsNotSpecifiedRatherThanZeroDollars() {
        #expect(PieceRateCosting.cost(vineCount: nil, ratePerVine: 1.27) == nil)
        #expect(PieceRateCosting.cost(vineCount: 2_238, ratePerVine: nil) == nil)
        #expect(PieceRateCosting.cost(vineCount: nil, ratePerVine: nil) == nil)
    }

    @Test func negativeInputsAreClampedInsteadOfProducingANegativeBill() {
        #expect(PieceRateCosting.cost(vineCount: -500, ratePerVine: 1.27) == 0)
        #expect(PieceRateCosting.cost(vineCount: 2_238, ratePerVine: -1.27) == 0)
    }

    @Test func costPerHectareNeedsAPositiveArea() {
        #expect(PieceRateCosting.costPerHectare(cost: 1_000, hectares: 2) == 500)
        #expect(PieceRateCosting.costPerHectare(cost: 1_000, hectares: 0) == nil)
        #expect(PieceRateCosting.costPerHectare(cost: 1_000, hectares: -2) == nil)
        #expect(PieceRateCosting.costPerHectare(cost: 1_000, hectares: nil) == nil)
        #expect(PieceRateCosting.costPerHectare(cost: nil, hectares: 2) == nil)
    }

    // MARK: - Quantity derived from the selected rows

    @Test func vineCountIsTheSumOfTheSelectedRowsSnapshots() {
        let rows = [
            snapshotRow(vineCount: 746, rowNumber: 1),
            snapshotRow(vineCount: 746, rowNumber: 2),
            snapshotRow(vineCount: 746, rowNumber: 3)
        ]
        #expect(PieceRateCosting.vineCount(forSelectedRows: rows) == 2_238)
        #expect(PieceRateCosting.vineCount(forSelectedRows: []) == 0)
    }

    @Test func aRowsManualCountOverridesTheCalculatedEstimate() {
        // 300 m at 1.8 m spacing = 166.67 → 167 whole vines, but the operator
        // counted 150. See `RowVineCountTests` for the full rule.
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 300, vineSpacing: 1.8) == 167)
        #expect(PaddockRowVineCount.effective(override: nil, rowLengthMetres: 300, vineSpacing: 1.8) == 167)
        #expect(PaddockRowVineCount.effective(override: 150, rowLengthMetres: 300, vineSpacing: 1.8) == 150)
        // A zero/negative override is not an override at all.
        #expect(PaddockRowVineCount.effective(override: 0, rowLengthMetres: 300, vineSpacing: 1.8) == 167)
        #expect(PaddockRowVineCount.effective(override: -5, rowLengthMetres: 300, vineSpacing: 1.8) == 167)
        // No usable spacing or geometry means NO estimate — nil, never 0,
        // because 0 would be a claim that the row has no vines.
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 300, vineSpacing: 0) == nil)
        #expect(PaddockRowVineCount.calculated(rowLengthMetres: 0, vineSpacing: 1.8) == nil)
    }

    // MARK: - Exactly one cost source

    @Test func anHourlyTaskIsCostedFromItsLabourLinesExactlyAsBefore() throws {
        let lines = [
            line(hoursPerWorker: 8, workerCount: 2, hourlyRate: 32),
            line(hoursPerWorker: 6, workerCount: 1, hourlyRate: 40)
        ]
        let resolved = PieceRateCosting.resolve(
            method: .hourly,
            labourLines: lines,
            pieceVineCount: 2_238,
            pieceRatePerVine: 1.27
        )
        #expect(resolved.method == .hourly)
        // 16 h × $32 + 6 h × $40 = $752 — the piece-rate columns are ignored.
        let cost = try #require(resolved.cost)
        #expect(abs(cost - 752) < 0.0001)
        #expect(abs(resolved.hours - 22) < 0.0001)
        #expect(resolved.vineCount == nil)
        #expect(resolved.ratePerVine == nil)
        #expect(resolved.hoursAreOperationalOnly == false)
    }

    @Test func aPieceRateTaskIsCostedFromItsSnapshotAndNeverFromItsHours() throws {
        // Rated hourly lines that must NOT contribute a second cost.
        let lines = [line(hoursPerWorker: 8, workerCount: 3, hourlyRate: 32)]
        let resolved = PieceRateCosting.resolve(
            method: .pieceRate,
            labourLines: lines,
            pieceVineCount: 2_238,
            pieceRatePerVine: 1.27
        )
        #expect(resolved.method == .pieceRate)
        let cost = try #require(resolved.cost)
        #expect(abs(cost - 2_842.26) < 0.0001)
        // Hours are preserved as operational history…
        #expect(abs(resolved.hours - 24) < 0.0001)
        // …and explicitly flagged as not being the basis of the cost.
        #expect(resolved.hoursAreOperationalOnly)
        #expect(resolved.vineCount == 2_238)
        #expect(resolved.ratePerVine == 1.27)
    }

    @Test func theTwoCostingMethodsAreNeverSummed() throws {
        let lines = [line(hoursPerWorker: 10, workerCount: 1, hourlyRate: 50)]
        let hourly = PieceRateCosting.resolve(
            method: .hourly, labourLines: lines, pieceVineCount: 2_238, pieceRatePerVine: 1.27
        )
        let piece = PieceRateCosting.resolve(
            method: .pieceRate, labourLines: lines, pieceVineCount: 2_238, pieceRatePerVine: 1.27
        )
        let hourlyCost = try #require(hourly.cost)
        let pieceCost = try #require(piece.cost)
        #expect(abs(hourlyCost - 500) < 0.0001)
        #expect(abs(pieceCost - 2_842.26) < 0.0001)
        // Neither total contains any part of the other.
        #expect(hourlyCost != pieceCost)
        #expect(hourlyCost + pieceCost != hourlyCost)
    }

    @Test func unratedHourlyLinesReportNotSpecifiedRatherThanZero() {
        let lines = [line(hoursPerWorker: 8, workerCount: 2, hourlyRate: nil)]
        let resolved = PieceRateCosting.resolve(
            method: .hourly, labourLines: lines, pieceVineCount: nil, pieceRatePerVine: nil
        )
        #expect(resolved.cost == nil)
        #expect(abs(resolved.hours - 16) < 0.0001)
    }

    @Test func aPieceRateJobWithNoHoursIsStillFullyCosted() throws {
        let resolved = PieceRateCosting.resolve(
            method: .pieceRate, labourLines: [], pieceVineCount: 2_238, pieceRatePerVine: 1.27
        )
        let cost = try #require(resolved.cost)
        #expect(abs(cost - 2_842.26) < 0.0001)
        #expect(resolved.hours == 0)
        // No hours means nothing to describe as "operational only".
        #expect(resolved.hoursAreOperationalOnly == false)
    }

    @Test func aPieceRateJobWithoutAnAgreedRateIsNotSpecified() {
        let resolved = PieceRateCosting.resolve(
            method: .pieceRate, labourLines: [], pieceVineCount: 2_238, pieceRatePerVine: nil
        )
        #expect(resolved.cost == nil)
        #expect(resolved.vineCount == 2_238)
    }

    // MARK: - Snapshot immutability

    @Test func editingTheBlocksRowsNeverRepricesACompletedJob() throws {
        // The job was priced on 2,238 vines. The block is later re-mapped and
        // now carries far more vines — the completed job must not change.
        let costed = try #require(PieceRateCosting.cost(vineCount: 2_238, ratePerVine: 1.27))
        let rowsToday = [
            snapshotRow(vineCount: 900, rowNumber: 1),
            snapshotRow(vineCount: 900, rowNumber: 2),
            snapshotRow(vineCount: 900, rowNumber: 3)
        ]
        #expect(PieceRateCosting.vineCount(forSelectedRows: rowsToday) == 2_700)
        // The stored snapshot, not today's rows, is what the job is costed on.
        #expect(abs(costed - 2_842.26) < 0.0001)
    }

    @Test func aSnapshotRowNeverStoresANegativeQuantity() {
        let row = snapshotRow(vineCount: -40, rowNumber: 1)
        #expect(row.vineCount == 0)
    }

    // MARK: - Validation

    @Test func aRateAndAQuantityAreBothRequired() {
        #expect(PieceRateCosting.isValid(ratePerVine: 1.27, vineCount: 2_238))

        let noRate = PieceRateCosting.validate(ratePerVine: nil, vineCount: 2_238)
        #expect(PieceRateCosting.message(noRate, for: .ratePerVine) == "Enter the agreed rate per vine.")
        #expect(PieceRateCosting.message(noRate, for: .vineCount) == nil)

        let noVines = PieceRateCosting.validate(ratePerVine: 1.27, vineCount: 0)
        #expect(
            PieceRateCosting.message(noVines, for: .vineCount)
                == "Select the rows this job covers so the vine count can be calculated."
        )

        // Every problem is reported at once so the form can mark each field.
        #expect(PieceRateCosting.validate(ratePerVine: nil, vineCount: nil).count == 2)
    }

    @Test func implausibleRatesAndQuantitiesAreCaughtAsTypos() {
        let bigRate = PieceRateCosting.validate(ratePerVine: 5_000, vineCount: 2_238)
        #expect(
            PieceRateCosting.message(bigRate, for: .ratePerVine)
                == "That rate per vine looks too high — check the number."
        )
        let bigCount = PieceRateCosting.validate(ratePerVine: 1.27, vineCount: 50_000_000)
        #expect(
            PieceRateCosting.message(bigCount, for: .vineCount)
                == "That vine count looks too high — check the selected rows."
        )
        // The boundaries themselves are acceptable.
        #expect(
            PieceRateCosting.isValid(
                ratePerVine: PieceRateCosting.maxRatePerVine,
                vineCount: PieceRateCosting.maxVineCount
            )
        )
    }

    @Test func aNegativeRateIsRejected() {
        #expect(PieceRateCosting.isValid(ratePerVine: -1, vineCount: 2_238) == false)
        #expect(PieceRateCosting.isValid(ratePerVine: 0, vineCount: 2_238) == false)
    }

    // MARK: - Formatting parity

    @Test func moneyAndQuantitiesAreFormattedIdenticallyOnBothPlatforms() {
        #expect(PieceRateCosting.currencyLabel(2_842.26) == "$2,842.26")
        #expect(PieceRateCosting.currencyLabel(0) == "$0.00")
        #expect(PieceRateCosting.rateLabel(1.27) == "$1.27")
        #expect(PieceRateCosting.rateLabel(1) == "$1.00")
        #expect(PieceRateCosting.vineCountLabel(2_238) == "2,238")
        #expect(PieceRateCosting.vineCountLabel(0) == "0")
    }
}
