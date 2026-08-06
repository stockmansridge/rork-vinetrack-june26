import Testing
import Foundation
import CoreLocation
@testable import VineTrack

/// One-shot manual pin placement tests — mirrored by Android's
/// `PinPlacementTest.kt`. Uses the shared parity fixture: straight
/// north-south rows anchored at (-34.0, 138.0), rows ~3.7 m apart
/// (0.00004° longitude), 0.001° latitude ≈ 111 m.
struct PinManualPlacementTests {

    private func rowLongitude(_ row: Int) -> Double {
        138.0 + Double(row - 1) * 0.00004
    }

    private func fixtureBlock() -> Paddock {
        Paddock(
            name: "Block 1",
            polygonPoints: [
                CoordinatePoint(latitude: -34.0005, longitude: 137.99995),
                CoordinatePoint(latitude: -34.0005, longitude: 138.00015),
                CoordinatePoint(latitude: -33.9985, longitude: 138.00015),
                CoordinatePoint(latitude: -33.9985, longitude: 137.99995)
            ],
            rows: (1...3).map { row in
                PaddockRow(
                    number: row,
                    startPoint: CoordinatePoint(latitude: -34.0, longitude: rowLongitude(row)),
                    endPoint: CoordinatePoint(latitude: -33.999, longitude: rowLongitude(row))
                )
            },
            rowDirection: 0,
            rowWidth: 3.7
        )
    }

    @Test func pinInsideAMappedBlockSnapsToTheNearestRow() {
        let block = fixtureBlock()
        let attachment = PinAttachmentResolver.resolveManual(
            coordinate: CLLocationCoordinate2D(latitude: -33.9995, longitude: rowLongitude(2) + 0.00001),
            operatorSide: .left,
            paddock: block
        )
        #expect(attachment.snappedToRow)
        #expect(attachment.pinRowNumber == 2)
        #expect(attachment.pinSide == .left)
        // Manual pins never speculate a driving path.
        #expect(attachment.drivingRowNumber == nil)
        // Snapped point sits on the row-2 centreline, ~55.7 m along the row.
        let snapped = try! #require(attachment.snappedCoordinate)
        #expect(abs(snapped.longitude - rowLongitude(2)) < 1e-7)
        #expect(abs(snapped.latitude - (-33.9995)) < 1e-6)
        let along = try! #require(attachment.alongRowDistanceM)
        #expect(abs(along - 55.66) < 1.0)
    }

    @Test func pinWithoutABlockStaysHonestlyUnsnapped() {
        let attachment = PinAttachmentResolver.resolveManual(
            coordinate: CLLocationCoordinate2D(latitude: -35.0, longitude: 139.0),
            operatorSide: .right,
            paddock: nil
        )
        #expect(!attachment.snappedToRow)
        #expect(attachment.pinRowNumber == nil)
        #expect(attachment.snappedCoordinate == nil)
        #expect(attachment.alongRowDistanceM == nil)
        // The operator's side is still carried verbatim.
        #expect(attachment.pinSide == .right)
    }

    @Test func syntheticOnlyGeometryRecordsTheRowButNotASnap() {
        // Block with a polygon + row width/direction but no mapped row lines:
        // the nearest synthetic row index is recorded, but snapped_to_row
        // stays false because no real centreline geometry exists.
        let block = Paddock(
            name: "Synthetic",
            polygonPoints: [
                CoordinatePoint(latitude: -34.0005, longitude: 137.99995),
                CoordinatePoint(latitude: -34.0005, longitude: 138.00015),
                CoordinatePoint(latitude: -33.9985, longitude: 138.00015),
                CoordinatePoint(latitude: -33.9985, longitude: 137.99995)
            ],
            rows: [],
            rowDirection: 0,
            rowWidth: 3.7
        )
        let attachment = PinAttachmentResolver.resolveManual(
            coordinate: CLLocationCoordinate2D(latitude: -33.9995, longitude: 138.0001),
            operatorSide: .left,
            paddock: block
        )
        #expect(!attachment.snappedToRow)
        #expect(attachment.pinRowNumber != nil)
        #expect(attachment.snappedCoordinate == nil)
    }
}
