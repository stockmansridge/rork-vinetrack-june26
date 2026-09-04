import CoreLocation
import Foundation
import Testing
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
