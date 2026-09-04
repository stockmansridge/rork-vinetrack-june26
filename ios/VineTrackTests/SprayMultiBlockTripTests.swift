import CoreLocation
import Foundation
import Testing
import XCTest
@testable import VineTrack

struct SprayMultiBlockTripTests {
    private let vineyardId = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let sauvId = UUID(uuidString: "10000000-0000-4000-8000-000000000101")!
    private let pinotId = UUID(uuidString: "10000000-0000-4000-8000-000000000102")!
    private let grisId = UUID(uuidString: "10000000-0000-4000-8000-000000000103")!

    private func block(id: UUID, name: String, row: Int, longitude: Double) -> Paddock {
        let polygon = [
            CoordinatePoint(latitude: -33.001, longitude: longitude - 0.001),
            CoordinatePoint(latitude: -33.001, longitude: longitude + 0.001),
            CoordinatePoint(latitude: -32.999, longitude: longitude + 0.001),
            CoordinatePoint(latitude: -32.999, longitude: longitude - 0.001),
        ]
        let mappedRow = PaddockRow(
            number: row,
            startPoint: CoordinatePoint(latitude: -33.0008, longitude: longitude),
            endPoint: CoordinatePoint(latitude: -32.9992, longitude: longitude)
        )
        return Paddock(
            id: id,
            vineyardId: vineyardId,
            name: name,
            polygonPoints: polygon,
            rows: [mappedRow],
            rowDirection: 0,
            rowWidth: 3
        )
    }

    private var completeTrip: Trip {
        Trip(
            vineyardId: vineyardId,
            paddockId: sauvId,
            paddockName: "Sauv Blanc, Pinot Noir, Pinot Gris",
            paddockIds: [sauvId, pinotId, grisId],
            currentRowNumber: 0.5,
            nextRowNumber: 1.5,
            isActive: false,
            trackingPattern: .everySecondRow,
            rowSequence: [0.5, 68.5, 108.5],
            sequenceIndex: 1,
            personName: "Operator",
            totalTanks: 4,
            tractorId: UUID(uuidString: "10000000-0000-4000-8000-000000000201"),
            operatorUserId: UUID(uuidString: "10000000-0000-4000-8000-000000000301")
        )
    }

    @Test("Three selected block IDs and complete plan survive persistence and relaunch")
    func completeTripRoundTrip() throws {
        let original = completeTrip
        let encoded = try JSONEncoder().encode(original)
        let relaunched = try JSONDecoder().decode(Trip.self, from: encoded)
        #expect(relaunched.id == original.id)
        #expect(relaunched.paddockId == sauvId)
        #expect(relaunched.paddockIds == [sauvId, pinotId, grisId])
        #expect(relaunched.rowSequence == [0.5, 68.5, 108.5])
        #expect(relaunched.trackingPattern == .everySecondRow)
        #expect(relaunched.sequenceIndex == 1)
        #expect(relaunched.totalTanks == 4)
        #expect(relaunched.tractorId == original.tractorId)
        #expect(relaunched.operatorUserId == original.operatorUserId)

        let syncPayload = BackendTrip.upsert(
            from: relaunched,
            createdBy: relaunched.operatorUserId,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let syncData = try JSONEncoder().encode(syncPayload)
        let syncJSON = try #require(JSONSerialization.jsonObject(with: syncData) as? [String: Any])
        #expect((syncJSON["paddock_ids"] as? [String])?.count == 3)
        #expect((syncJSON["row_sequence"] as? [Double]) == [0.5, 68.5, 108.5])
        #expect(syncJSON["tracking_pattern"] as? String == TrackingPattern.everySecondRow.rawValue)
        #expect(syncJSON["total_tanks"] as? Int == 4)
    }

    @Test("Saved job activation refreshes operational clocks without changing identity or plan")
    @MainActor
    func savedJobActivationUsesActualStart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spray-activation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId

        let plannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let activatedAt = Date()
        let trip = Trip(
            id: UUID(), vineyardId: vineyardId, paddockId: sauvId,
            paddockName: "Sauv Blanc, Pinot Noir, Pinot Gris",
            paddockIds: [sauvId, pinotId, grisId], startTime: plannedAt,
            currentRowNumber: 0.5, nextRowNumber: 68.5, isActive: false,
            trackingPattern: .everySecondRow,
            rowSequence: [0.5, 68.5, 108.5], totalTanks: 1
        )
        let plannedTanks = [SprayTank(tankNumber: 1, waterVolume: 2_000, sprayRatePerHa: 500)]
        let record = SprayRecord(
            tripId: trip.id, vineyardId: vineyardId, date: plannedAt,
            startTime: plannedAt, sprayReference: "Saved plan", tanks: plannedTanks
        )
        store.addInactiveTrip(trip)
        store.addSprayRecord(record)

        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        tracking.activateSavedTrip(trip, at: activatedAt)

        let activatedTrip = try #require(store.trips.first { $0.id == trip.id })
        let activatedRecord = try #require(store.sprayRecords.first { $0.id == record.id })
        #expect(activatedTrip.id == trip.id)
        #expect(activatedRecord.tripId == trip.id)
        #expect(activatedTrip.startTime == activatedAt)
        #expect(activatedRecord.startTime == activatedAt)
        #expect(activatedRecord.date == activatedAt)
        #expect(activatedRecord.tanks == plannedTanks)
        #expect(activatedTrip.paddockIds == trip.paddockIds)
        #expect(activatedTrip.rowSequence == trip.rowSequence)
        #expect(activatedTrip.activeDuration < 5)

        let relaunchedTrips = TripRepository(persistence: persistence).load(for: vineyardId)
        let relaunchedRecords = SprayRepository(persistence: persistence).loadRecords(for: vineyardId)
        let persistedStart = try #require(relaunchedTrips.first { $0.id == trip.id }?.startTime)
        #expect(abs(persistedStart.timeIntervalSince(activatedAt)) < 1)
        #expect(relaunchedRecords.first { $0.id == record.id }?.tanks == plannedTanks)
    }

    @Test("Activated three-block job processes GPS and pins through production boundaries")
    @MainActor
    func activatedJobProcessesGpsAndPinsAcrossSelectedBlocks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spray-gps-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        let blocks = [
            block(id: sauvId, name: "Sauv Blanc", row: 1, longitude: 149.000),
            block(id: pinotId, name: "Pinot Noir", row: 69, longitude: 149.010),
            block(id: grisId, name: "Pinot Gris", row: 109, longitude: 149.020),
        ]
        blocks.forEach(store.addPaddock)
        var planned = completeTrip
        planned.sequenceIndex = 0
        let record = SprayRecord(
            tripId: planned.id,
            vineyardId: vineyardId,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            sprayReference: "Three blocks",
            tanks: [SprayTank(tankNumber: 1, waterVolume: 1_000, sprayRatePerHa: 500)]
        )
        store.addInactiveTrip(planned)
        store.addSprayRecord(record)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        tracking.activateSavedTrip(planned, at: Date())

        for ((block, expectedRow), longitude) in zip(zip(blocks, [1, 69, 109]), [149.000, 149.010, 149.020]) {
            tracking.processLocation(CLLocation(latitude: -33.0, longitude: longitude), force: true)
            #expect(tracking.currentPaddockId == block.id)
            let pin = PinContextResolver.resolve(
                coordinate: CLLocationCoordinate2D(latitude: -33.0, longitude: longitude),
                store: store,
                tracking: tracking
            )
            #expect(pin.paddockId == block.id)
            #expect(pin.rowNumber == expectedRow)
        }

        let neighbour = block(id: UUID(), name: "Unselected", row: 500, longitude: 149.030)
        store.addPaddock(neighbour)
        tracking.processLocation(CLLocation(latitude: -33.0, longitude: 149.030), force: true)
        #expect(tracking.currentPaddockId == nil)
        let rejected = PinContextResolver.resolve(
            coordinate: CLLocationCoordinate2D(latitude: -33.0, longitude: 149.030),
            store: store,
            tracking: tracking
        )
        #expect(rejected.paddockId == nil)
    }

    @Test("Overlapping selected blocks choose the closest valid row")
    func overlappingBlocksChooseClosestRow() {
        let farther = Paddock(
            id: sauvId,
            vineyardId: vineyardId,
            name: "Sauv Blanc",
            polygonPoints: block(id: sauvId, name: "Sauv Blanc", row: 1, longitude: 149.010).polygonPoints,
            rows: [PaddockRow(
                number: 1,
                startPoint: CoordinatePoint(latitude: -33.0008, longitude: 149.0108),
                endPoint: CoordinatePoint(latitude: -32.9992, longitude: 149.0108)
            )],
            rowDirection: 0,
            rowWidth: 3
        )
        let closest = block(id: pinotId, name: "Pinot Noir", row: 69, longitude: 149.010)
        let coordinate = CLLocationCoordinate2D(latitude: -33.0, longitude: 149.010)
        #expect(RowGuidance.paddock(for: coordinate, in: [farther, closest])?.id == pinotId)
    }

    @Test("Pinot containment beats primary Sauv Blanc and resolves its local/global row")
    func pinotContainmentWins() {
        let sauv = block(id: sauvId, name: "Sauv Blanc", row: 1, longitude: 149.000)
        let pinot = block(id: pinotId, name: "Pinot Noir", row: 69, longitude: 149.010)
        let gris = block(id: grisId, name: "Pinot Gris", row: 109, longitude: 149.020)
        let coordinate = CLLocationCoordinate2D(latitude: -33.0, longitude: 149.010)
        let selected = [sauv, pinot, gris]

        let containing = RowGuidance.paddock(for: coordinate, in: selected)
        let local = containing.flatMap { RowGuidance.nearestRow(for: coordinate, in: $0) }
        let global: Int? = if let containing, let local {
            GlobalRowIndex(paddocks: selected).globalRow(
                paddockId: containing.id,
                localRow: Int(local.rowNumber)
            )
        } else {
            nil
        }
        #expect(containing?.id == pinotId)
        #expect(local?.rowNumber == 69)
        #expect(global == 69)
    }

    @Test("Every selected block resolves its own local and trip-global row for Auto Path and pins")
    func everyBlockResolves() {
        let blocks = [
            block(id: sauvId, name: "Sauv Blanc", row: 1, longitude: 149.000),
            block(id: pinotId, name: "Pinot Noir", row: 69, longitude: 149.010),
            block(id: grisId, name: "Pinot Gris", row: 109, longitude: 149.020),
        ]
        let index = GlobalRowIndex(paddocks: blocks)
        for (block, expectedRow) in zip(blocks, [1, 69, 109]) {
            let coordinate = CLLocationCoordinate2D(latitude: -33.0, longitude: block.polygonPoints[0].longitude + 0.001)
            let resolved = RowGuidance.paddock(for: coordinate, in: blocks)
            let row = resolved.flatMap { RowGuidance.nearestRow(for: coordinate, in: $0) }
            #expect(resolved?.id == block.id)
            #expect(row.map { Int($0.rowNumber) } == expectedRow)
            #expect(index.globalRow(paddockId: block.id, localRow: expectedRow) == expectedRow)
        }
    }
}

@MainActor
final class SpraySavedJobActivationIntegrationTests: XCTestCase {
    private func makeBlock(vineyardId: UUID, id: UUID, name: String, row: Int, longitude: Double) -> Paddock {
        Paddock(
            id: id,
            vineyardId: vineyardId,
            name: name,
            polygonPoints: [
                CoordinatePoint(latitude: -33.001, longitude: longitude - 0.001),
                CoordinatePoint(latitude: -33.001, longitude: longitude + 0.001),
                CoordinatePoint(latitude: -32.999, longitude: longitude + 0.001),
                CoordinatePoint(latitude: -32.999, longitude: longitude - 0.001),
            ],
            rows: [PaddockRow(
                number: row,
                startPoint: CoordinatePoint(latitude: -33.0008, longitude: longitude),
                endPoint: CoordinatePoint(latitude: -32.9992, longitude: longitude)
            )],
            rowDirection: 0,
            rowWidth: 3
        )
    }

    func testSavedJobActivationRefreshesOperationalStartAndPreservesPlan() throws {
        let vineyardId = UUID()
        let blockIds = [UUID(), UUID(), UUID()]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spray-activation-xctest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        let plannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let activatedAt = Date()
        let trip = Trip(
            id: UUID(), vineyardId: vineyardId, paddockId: blockIds[0],
            paddockName: "Three blocks", paddockIds: blockIds, startTime: plannedAt,
            currentRowNumber: 0.5, nextRowNumber: 68.5, isActive: false,
            trackingPattern: .everySecondRow, rowSequence: [0.5, 68.5, 108.5], totalTanks: 1
        )
        let tanks = [SprayTank(tankNumber: 1, waterVolume: 2_000, sprayRatePerHa: 500)]
        let record = SprayRecord(
            tripId: trip.id, vineyardId: vineyardId, date: plannedAt,
            startTime: plannedAt, sprayReference: "Saved plan", tanks: tanks
        )
        store.addInactiveTrip(trip)
        store.addSprayRecord(record)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())

        tracking.activateSavedTrip(trip, at: activatedAt)

        let active = try XCTUnwrap(store.trips.first { $0.id == trip.id })
        let linked = try XCTUnwrap(store.sprayRecords.first { $0.id == record.id })
        XCTAssertEqual(active.id, trip.id)
        XCTAssertEqual(linked.tripId, trip.id)
        XCTAssertEqual(active.startTime, activatedAt)
        XCTAssertEqual(linked.startTime, activatedAt)
        XCTAssertEqual(active.paddockIds, blockIds)
        XCTAssertEqual(active.rowSequence, trip.rowSequence)
        XCTAssertEqual(linked.tanks, tanks)
        XCTAssertLessThan(active.activeDuration, 5)
        let relaunchedTrips = TripRepository(persistence: persistence).load(for: vineyardId)
        let relaunchedRecords = SprayRepository(persistence: persistence).loadRecords(for: vineyardId)
        let persistedStart = try XCTUnwrap(relaunchedTrips.first { $0.id == trip.id }?.startTime)
        XCTAssertEqual(persistedStart.timeIntervalSince1970, activatedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(relaunchedRecords.first { $0.id == record.id }?.tanks, tanks)
    }

    func testActivatedJobGpsAndPinBoundariesStayWithinSelectedBlocks() throws {
        let vineyardId = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spray-gps-xctest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyardId
        let blocks = [
            makeBlock(vineyardId: vineyardId, id: ids[0], name: "Sauv Blanc", row: 1, longitude: 149.000),
            makeBlock(vineyardId: vineyardId, id: ids[1], name: "Pinot Noir", row: 69, longitude: 149.010),
            makeBlock(vineyardId: vineyardId, id: ids[2], name: "Pinot Gris", row: 109, longitude: 149.020),
        ]
        blocks.forEach(store.addPaddock)
        let trip = Trip(
            id: UUID(), vineyardId: vineyardId, paddockId: ids[0], paddockName: "Three blocks",
            paddockIds: ids, currentRowNumber: 0.5, nextRowNumber: 68.5, isActive: false,
            trackingPattern: .everySecondRow, rowSequence: [0.5, 68.5, 108.5], totalTanks: 1
        )
        let record = SprayRecord(
            tripId: trip.id, vineyardId: vineyardId, date: Date(), startTime: Date(),
            sprayReference: "Three blocks", tanks: [SprayTank(tankNumber: 1, waterVolume: 1_000)]
        )
        store.addInactiveTrip(trip)
        store.addSprayRecord(record)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        tracking.activateSavedTrip(trip, at: Date())

        for ((block, expectedRow), longitude) in zip(zip(blocks, [1, 69, 109]), [149.000, 149.010, 149.020]) {
            tracking.processLocation(CLLocation(latitude: -33.0, longitude: longitude), force: true)
            XCTAssertEqual(tracking.currentPaddockId, block.id)
            let pin = PinContextResolver.resolve(
                coordinate: CLLocationCoordinate2D(latitude: -33.0, longitude: longitude),
                store: store,
                tracking: tracking
            )
            XCTAssertEqual(pin.paddockId, block.id)
            XCTAssertEqual(pin.rowNumber, expectedRow)
        }

        let unselected = makeBlock(vineyardId: vineyardId, id: UUID(), name: "Neighbour", row: 500, longitude: 149.030)
        store.addPaddock(unselected)
        tracking.processLocation(CLLocation(latitude: -33.0, longitude: 149.030), force: true)
        XCTAssertNil(tracking.currentPaddockId)
        XCTAssertNil(PinContextResolver.resolve(
            coordinate: CLLocationCoordinate2D(latitude: -33.0, longitude: 149.030),
            store: store,
            tracking: tracking
        ).paddockId)
    }

    func testAutoPathCompletesAcrossSelectedBlocks() throws {
        let vineyardId = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spray-auto-path-xctest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyardId
        let blocks = [
            makeBlock(vineyardId: vineyardId, id: ids[0], name: "Sauv Blanc", row: 1, longitude: 149.000),
            makeBlock(vineyardId: vineyardId, id: ids[1], name: "Pinot Noir", row: 69, longitude: 149.010),
            makeBlock(vineyardId: vineyardId, id: ids[2], name: "Pinot Gris", row: 109, longitude: 149.020),
        ]
        blocks.forEach(store.addPaddock)
        let planned = Trip(
            id: UUID(), vineyardId: vineyardId, paddockId: ids[0], paddockName: "Three blocks",
            paddockIds: ids, currentRowNumber: 68.5, nextRowNumber: 108.5, isActive: false,
            trackingPattern: .everySecondRow, rowSequence: [68.5, 108.5, 0.5],
            sequenceIndex: 0, totalTanks: 1
        )
        let record = SprayRecord(
            tripId: planned.id,
            vineyardId: vineyardId,
            endTime: nil,
            sprayReference: "Auto Path three blocks",
            tanks: [SprayTank(tankNumber: 1, waterVolume: 1_000, sprayRatePerHa: 500)],
            isTemplate: false
        )
        store.addInactiveTrip(planned)
        store.addSprayRecord(record)

        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        tracking.activateSavedTrip(planned, at: Date())

        let activated = try XCTUnwrap(tracking.activeTrip)
        XCTAssertEqual(activated.id, planned.id)
        XCTAssertTrue(activated.isActive, "Saved Auto Path trip should be active after activation")
        XCTAssertNil(tracking.errorMessage)

        let latitudes: [Double] = (0...16).map { step in
            -33.0008 + (Double(step) * 0.0001)
        }
        tracking.processLocation(CLLocation(latitude: latitudes[0], longitude: 149.010), force: true)
        XCTAssertEqual(tracking.currentPaddockId, ids[1])
        XCTAssertEqual(tracking.currentRowNumber, 68.5)
        for latitude in latitudes.dropFirst() {
            tracking.processLocation(CLLocation(latitude: latitude, longitude: 149.010), force: true)
        }

        var active = try XCTUnwrap(store.trips.first { $0.id == planned.id })
        XCTAssertTrue(
            active.completedPaths.contains(68.5),
            "Pinot path 68.5 should complete; completed=\(active.completedPaths), " +
            "detected=\(String(describing: tracking.diagLiveDetectedPath)), " +
            "match=\(tracking.diagPathMatch), corridor=\(tracking.diagInCorridor), " +
            "accumulated=\(tracking.diagAccumulatedMeters), " +
            "plannedLength=\(String(describing: tracking.diagPlannedPathLengthMeters)), " +
            "nearEnd=\(tracking.diagNearRowEnd)"
        )
        XCTAssertEqual(active.sequenceIndex, 1)
        XCTAssertEqual(active.currentRowNumber, 108.5)
        XCTAssertEqual(active.nextRowNumber, 0.5)

        for latitude in latitudes {
            tracking.processLocation(CLLocation(latitude: latitude, longitude: 149.020), force: true)
        }

        active = try XCTUnwrap(store.trips.first { $0.id == planned.id })
        XCTAssertEqual(tracking.currentPaddockId, ids[2])
        XCTAssertTrue(
            active.completedPaths.contains(108.5),
            "Pinot Gris path 108.5 should complete; completed paths: \(active.completedPaths)"
        )
        XCTAssertEqual(active.sequenceIndex, 2)
        XCTAssertEqual(active.currentRowNumber, 0.5)
    }
}
