import Foundation
import XCTest
@testable import VineTrack

final class TankMixPresentationTests: XCTestCase {
    private let tripId = UUID(uuidString: "70000000-0000-4000-8000-000000000001")!
    private let vineyardId = UUID(uuidString: "70000000-0000-4000-8000-000000000002")!

    private var fullTank: SprayTank {
        SprayTank(
            id: UUID(uuidString: "70000000-0000-4000-8000-000000000101")!,
            tankNumber: 1,
            waterVolume: 2_000,
            sprayRatePerHa: 500,
            concentrationFactor: 1,
            rowApplications: [TankRowApplication(
                id: UUID(uuidString: "70000000-0000-4000-8000-000000000201")!,
                startRow: 1,
                endRow: 8
            )],
            chemicals: [SprayChemical(
                id: UUID(uuidString: "70000000-0000-4000-8000-000000000301")!,
                name: "Frozen Copper",
                volumePerTank: 5_000,
                ratePerHa: 1_250,
                unit: .litres
            )]
        )
    }

    private var partialTank: SprayTank {
        SprayTank(
            id: UUID(uuidString: "70000000-0000-4000-8000-000000000102")!,
            tankNumber: 2,
            waterVolume: 1_250,
            sprayRatePerHa: 500,
            concentrationFactor: 1.5,
            rowApplications: [TankRowApplication(
                id: UUID(uuidString: "70000000-0000-4000-8000-000000000202")!,
                startRow: 9,
                endRow: 12.5
            )],
            chemicals: [
                SprayChemical(
                    id: UUID(uuidString: "70000000-0000-4000-8000-000000000302")!,
                    name: "Frozen Copper",
                    volumePerTank: 3_125,
                    ratePerHa: 1_250,
                    unit: .litres
                ),
                SprayChemical(
                    id: UUID(uuidString: "70000000-0000-4000-8000-000000000303")!,
                    name: "Frozen Powder",
                    volumePerTank: 625,
                    ratePerHa: 250,
                    unit: .grams
                ),
            ]
        )
    }

    private func record(tanks: [SprayTank]? = nil) -> SprayRecord {
        SprayRecord(
            tripId: tripId,
            vineyardId: vineyardId,
            sprayReference: "Frozen two-tank plan",
            tanks: tanks ?? [partialTank, fullTank]
        )
    }

    private func trip(sessions: [TankSession] = [], isActive: Bool = true) -> Trip {
        Trip(
            id: tripId,
            vineyardId: vineyardId,
            paddockName: "Local Block",
            startTime: Date(timeIntervalSince1970: 1_780_000_000),
            isActive: isActive,
            tankSessions: sessions,
            totalTanks: 2
        )
    }

    func testFrozenPlanSortsWithoutMutationAndPreservesTankSpecificQuantities() {
        let storedRecord = record()
        let storedTanks = storedRecord.tanks
        let presentation = TankMixPresentation(record: storedRecord, trip: trip())

        XCTAssertEqual(presentation.tanks.map(\.tankNumber), [1, 2])
        XCTAssertEqual(storedRecord.tanks, storedTanks)
        XCTAssertEqual(storedRecord.tanks.map(\.tankNumber), [2, 1])
        XCTAssertEqual(presentation.tanks[0].waterVolume, 2_000)
        XCTAssertEqual(presentation.tanks[1].waterVolume, 1_250)
        XCTAssertEqual(presentation.tanks[0].chemicals[0].volumePerTank, 5_000)
        XCTAssertEqual(presentation.tanks[1].chemicals[0].volumePerTank, 3_125)
        XCTAssertEqual(presentation.tanks[0].chemicals[0].displayVolume, 5)
        XCTAssertEqual(presentation.tanks[0].chemicals[0].unitLabel, "Litres")
        XCTAssertEqual(presentation.tanks[1].chemicals[1].displayVolume, 625)
        XCTAssertEqual(presentation.tanks[1].chemicals[1].unitLabel, "g")
        XCTAssertEqual(presentation.tanks[0].areaPerTank, 4)
        XCTAssertEqual(presentation.tanks[1].areaPerTank, 3.75)
        XCTAssertTrue(presentation.isPartial(presentation.tanks[1]))
    }

    func testDefaultsUseActiveNextAndFinalStoredTankNumbers() {
        let endedOne = TankSession(
            tankNumber: 1,
            startTime: Date(timeIntervalSince1970: 10),
            endTime: Date(timeIntervalSince1970: 20)
        )
        let activeTwo = TankSession(tankNumber: 2, startTime: Date(timeIntervalSince1970: 30))
        let active = TankMixPresentation(record: record(), trip: trip(sessions: [activeTwo, endedOne]))
        XCTAssertEqual(active.selectedTankNumber, 2)
        XCTAssertEqual(active.activeTankNumber, 2)
        XCTAssertEqual(active.progress(for: active.tanks[1]), .current)

        let next = TankMixPresentation(record: record(), trip: trip(sessions: [endedOne]))
        XCTAssertEqual(next.selectedTankNumber, 2)
        XCTAssertEqual(next.progress(for: next.tanks[1]), .next)

        let endedTwo = TankSession(
            tankNumber: 2,
            startTime: Date(timeIntervalSince1970: 30),
            endTime: Date(timeIntervalSince1970: 40)
        )
        let complete = TankMixPresentation(
            record: record(),
            trip: trip(sessions: [endedTwo, endedOne], isActive: false)
        )
        XCTAssertEqual(complete.selectedTankNumber, 2)
        XCTAssertEqual(complete.completedTankNumbers, [1, 2])
        XCTAssertEqual(complete.progress(for: complete.tanks[1]), .completed)
    }

    func testOutOfOrderAndMissingSessionNumbersAreIgnoredSafely() {
        let sessions = [
            TankSession(tankNumber: 99, startTime: Date(timeIntervalSince1970: 1)),
            TankSession(tankNumber: 0, startTime: Date(timeIntervalSince1970: 2), endTime: Date(timeIntervalSince1970: 3)),
            TankSession(tankNumber: 2, startTime: Date(timeIntervalSince1970: 6), endTime: Date(timeIntervalSince1970: 7)),
            TankSession(tankNumber: 1, startTime: Date(timeIntervalSince1970: 4)),
        ]
        let presentation = TankMixPresentation(record: record(), trip: trip(sessions: sessions))

        XCTAssertEqual(presentation.activeTankNumber, 1)
        XCTAssertEqual(presentation.selectedTankNumber, 1)
        XCTAssertEqual(presentation.completedTankNumbers, [2])
    }

    func testHistoricalOfflineLookupUsesOnlyExactTripIdAndMissingDataIsUnavailable() throws {
        let linked = record()
        let unrelated = SprayRecord(
            tripId: UUID(),
            vineyardId: vineyardId,
            sprayReference: "Same-looking record",
            tanks: [fullTank]
        )
        let cachedData = try JSONEncoder().encode([unrelated, linked])
        let cachedRecords = try JSONDecoder().decode([SprayRecord].self, from: cachedData)
        let resolved = TankMixPresentation.linkedRecord(for: tripId, in: cachedRecords)

        XCTAssertEqual(resolved?.id, linked.id)
        XCTAssertNil(TankMixPresentation.linkedRecord(for: UUID(), in: cachedRecords))
        let historical = TankMixPresentation(record: resolved, trip: trip(isActive: false))
        XCTAssertTrue(historical.isAvailable)
        XCTAssertEqual(historical.tanks, [fullTank, partialTank])

        let unavailable = TankMixPresentation(record: nil, trip: trip())
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertNil(unavailable.selectedTankNumber)
        XCTAssertTrue(unavailable.tanks.isEmpty)
    }

    func testCatalogueChangesAndSheetSelectionCannotRestateFrozenPlan() {
        let storedRecord = record()
        var currentCatalogueChemical = SprayChemical(
            name: "Frozen Copper",
            volumePerTank: 99_000,
            unit: .millilitres
        )
        let presentation = TankMixPresentation(record: storedRecord, trip: trip())
        let tripBefore = trip()
        let recordBefore = storedRecord

        currentCatalogueChemical.volumePerTank = 1
        let selectedSecond = presentation.tanks.first { $0.tankNumber == 2 }

        XCTAssertEqual(selectedSecond?.waterVolume, 1_250)
        XCTAssertEqual(selectedSecond?.chemicals[0].volumePerTank, 3_125)
        XCTAssertEqual(currentCatalogueChemical.volumePerTank, 1)
        XCTAssertEqual(storedRecord, recordBefore)
        XCTAssertEqual(trip(), tripBefore)
    }

    func testStartEndConfirmationAndStatusActionsAreIsolatedAndSingleInvocation() {
        var controls = TankControlInteractionState()
        var starts = 0
        var ends = 0
        var opens = 0

        controls.tapStart { starts += 1 }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 0)

        controls.tapEnd()
        XCTAssertTrue(controls.isEndConfirmationPresented)
        XCTAssertEqual(ends, 0)
        controls.cancelEnd()
        XCTAssertFalse(controls.isEndConfirmationPresented)
        XCTAssertEqual(ends, 0)

        controls.tapEnd()
        controls.confirmEnd { ends += 1 }
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(controls.isEndConfirmationPresented)
        controls.confirmEnd { ends += 1 }
        XCTAssertEqual(ends, 1)

        controls.tapStatus { opens += 1 }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
    }
}
