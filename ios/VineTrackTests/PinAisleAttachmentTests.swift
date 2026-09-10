import Testing
import Foundation
import CoreLocation
@testable import VineTrack

/// Core pin-location contract: an automatic Left/Right drop must identify the
/// actual aisle and attach to the physically adjacent vine row on the
/// operator's side for their recorded facing
/// (docs/core-pin-location-contract.md).
///
/// Mirrored by Android's `PinAisleAttachmentTest.kt`. Fixture geometry: straight
/// rows around latitude -33, spaced 0.00004° of longitude (~3.7 m at this
/// latitude). Row-number ordering deliberately varies between fixtures so
/// nothing can pass by assuming "Left = lower row number".
struct PinAisleAttachmentTests {

    private let rowSpacing = 0.00004
    private let southLat = -33.0010
    private let northLat = -32.9990

    /// Rows numbered west -> east (32 lies west of 33).
    private func eastwardBlock(
        numbers: [Int] = [31, 32, 33, 34],
        reversedEndpoints: Bool = false
    ) -> Paddock {
        Paddock(
            name: "Block 1",
            polygonPoints: [
                CoordinatePoint(latitude: southLat, longitude: 148.99980),
                CoordinatePoint(latitude: southLat, longitude: 149.00060),
                CoordinatePoint(latitude: northLat, longitude: 149.00060),
                CoordinatePoint(latitude: northLat, longitude: 148.99980)
            ],
            rows: numbers.map { number in
                let lon = 149.0 + Double(number - 32) * rowSpacing
                return PaddockRow(
                    number: number,
                    startPoint: CoordinatePoint(
                        latitude: reversedEndpoints ? northLat : southLat,
                        longitude: lon
                    ),
                    endPoint: CoordinatePoint(
                        latitude: reversedEndpoints ? southLat : northLat,
                        longitude: lon
                    )
                )
            },
            rowDirection: 0,
            rowWidth: 3.7
        )
    }

    /// Same physical rows, numbered east -> west (33 lies WEST of 32).
    private func westwardBlock() -> Paddock {
        Paddock(
            name: "Reversed numbering",
            polygonPoints: [
                CoordinatePoint(latitude: southLat, longitude: 148.99980),
                CoordinatePoint(latitude: southLat, longitude: 149.00060),
                CoordinatePoint(latitude: northLat, longitude: 149.00060),
                CoordinatePoint(latitude: northLat, longitude: 148.99980)
            ],
            rows: [31, 32, 33, 34].map { number in
                let lon = 149.0 - Double(number - 32) * rowSpacing
                return PaddockRow(
                    number: number,
                    startPoint: CoordinatePoint(latitude: southLat, longitude: lon),
                    endPoint: CoordinatePoint(latitude: northLat, longitude: lon)
                )
            },
            rowDirection: 0,
            rowWidth: 3.7
        )
    }

    /// Rows running east-west, numbered south -> north (rotated 90°).
    private func rotatedBlock() -> Paddock {
        Paddock(
            name: "Rotated",
            polygonPoints: [
                CoordinatePoint(latitude: -33.00120, longitude: 148.99900),
                CoordinatePoint(latitude: -33.00120, longitude: 149.00100),
                CoordinatePoint(latitude: -32.99880, longitude: 149.00100),
                CoordinatePoint(latitude: -32.99880, longitude: 148.99900)
            ],
            rows: [31, 32, 33, 34].map { number in
                let lat = -33.0 + Double(number - 32) * 0.0000336
                return PaddockRow(
                    number: number,
                    startPoint: CoordinatePoint(latitude: lat, longitude: 148.99920),
                    endPoint: CoordinatePoint(latitude: lat, longitude: 149.00080)
                )
            },
            rowDirection: 90,
            rowWidth: 3.7
        )
    }

    /// Aisle 32.5: midway between rows 32 and 33.
    private var aisle32_5Longitude: Double { 149.0 + rowSpacing / 2.0 }

    private func automatic(
        _ block: Paddock?,
        latitude: Double = -33.0,
        longitude: Double,
        side: PinSide,
        heading: Double?
    ) -> PinAttachmentResolver.Attachment {
        PinAttachmentResolver.resolveAutomatic(
            rawCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            heading: heading,
            operatorSide: side,
            paddock: block
        )
    }

    // MARK: - Fixture matrix

    @Test func facingNorthAttachesLeftToRow32AndRightToRow33() {
        let block = eastwardBlock()
        let left = automatic(block, longitude: aisle32_5Longitude, side: .left, heading: 0)
        let right = automatic(block, longitude: aisle32_5Longitude, side: .right, heading: 0)

        #expect(left.snappedToRow)
        #expect(left.pinRowNumber == 32)
        #expect(left.drivingRowNumber == 32.5)
        #expect(left.pinSide == .left)
        #expect(left.heading == 0)

        #expect(right.snappedToRow)
        #expect(right.pinRowNumber == 33)
        #expect(right.drivingRowNumber == 32.5)
        #expect(right.pinSide == .right)

        // The audited defect: two opposite presses at one fix resolving to the
        // same row. They must never agree.
        #expect(left.pinRowNumber != right.pinRowNumber)
    }

    @Test func reversingTheHeadingReversesSidesAndKeepsTheAisle() {
        let block = eastwardBlock()
        let left = automatic(block, longitude: aisle32_5Longitude, side: .left, heading: 180)
        let right = automatic(block, longitude: aisle32_5Longitude, side: .right, heading: 180)

        #expect(left.pinRowNumber == 33)
        #expect(right.pinRowNumber == 32)
        #expect(left.drivingRowNumber == 32.5)
        #expect(right.drivingRowNumber == 32.5)
    }

    @Test func sideFollowsPhysicalGeometryNotRowNumberOrdering() {
        // Physically identical aisle, numbered the other way round: row 33 now
        // lies west, so facing North the LEFT press must attach to row 33.
        let block = westwardBlock()
        let longitude = 149.0 - rowSpacing / 2.0
        let left = automatic(block, longitude: longitude, side: .left, heading: 0)
        let right = automatic(block, longitude: longitude, side: .right, heading: 0)

        #expect(left.pinRowNumber == 33)
        #expect(right.pinRowNumber == 32)
        #expect(left.drivingRowNumber == 32.5)
    }

    @Test func reversedRowEndpointOrderProducesTheSamePhysicalAnswer() {
        let normal = automatic(eastwardBlock(), longitude: aisle32_5Longitude, side: .left, heading: 0)
        let reversed = automatic(
            eastwardBlock(reversedEndpoints: true),
            longitude: aisle32_5Longitude,
            side: .left,
            heading: 0
        )
        #expect(normal.pinRowNumber == reversed.pinRowNumber)
        #expect(normal.drivingRowNumber == reversed.drivingRowNumber)
        let a = try! #require(normal.snappedCoordinate)
        let b = try! #require(reversed.snappedCoordinate)
        #expect(abs(a.longitude - b.longitude) < 1e-9)
    }

    @Test func rotatedRowsResolveTheSideFromTheActualBearing() {
        // Rows run east-west, numbered south -> north. Facing East (90°), left
        // is north, so the left press attaches to the higher-numbered row.
        let block = rotatedBlock()
        let latitude = -33.0 + 0.0000168
        let left = automatic(block, latitude: latitude, longitude: 149.0, side: .left, heading: 90)
        let right = automatic(block, latitude: latitude, longitude: 149.0, side: .right, heading: 90)

        #expect(left.pinRowNumber == 33)
        #expect(right.pinRowNumber == 32)
        #expect(left.drivingRowNumber == 32.5)
    }

    @Test func nonContiguousRowNumbersReportTheRealAdjacentPair() {
        let block = eastwardBlock(numbers: [32, 34])
        let left = automatic(block, longitude: 149.0 + rowSpacing, side: .left, heading: 0)
        #expect(left.snappedToRow)
        #expect(left.pinRowNumber == 32)
        // Aisle between the two rows that genuinely exist; row 33 is never invented.
        #expect(left.drivingRowNumber == 33.0)
        #expect(left.pinRowNumber != 33)
    }

    @Test func headlandPositionKeepsHonestPointOnlySemantics() {
        let block = eastwardBlock()
        let attachment = automatic(
            block,
            longitude: 149.0 + 3 * rowSpacing, // east of row 34
            side: .left,
            heading: 0
        )
        #expect(!attachment.snappedToRow)
        #expect(attachment.pinRowNumber == nil)
        #expect(attachment.drivingRowNumber == nil)
        #expect(attachment.snappedCoordinate == nil)
        // The operator's own side is recorded evidence and is retained.
        #expect(attachment.pinSide == .left)
    }

    // MARK: - No false certainty

    @Test func missingHeadingNeverBecomesNorthAndNeverClaimsARow() {
        let attachment = automatic(
            eastwardBlock(),
            longitude: aisle32_5Longitude,
            side: .left,
            heading: nil
        )
        #expect(!attachment.snappedToRow)
        #expect(attachment.pinRowNumber == nil)
        #expect(attachment.drivingRowNumber == nil)
        #expect(attachment.heading == nil)
        #expect(attachment.pinSide == .left)
    }

    @Test func invalidHeadingsAreRejectedAndGenuineNorthIsKept() {
        for heading in [-1.0, 361.0, Double.nan, Double.infinity] {
            let attachment = automatic(
                eastwardBlock(),
                longitude: aisle32_5Longitude,
                side: .left,
                heading: heading
            )
            #expect(attachment.heading == nil)
            #expect(attachment.pinRowNumber == nil)
        }
        let north = automatic(eastwardBlock(), longitude: aisle32_5Longitude, side: .left, heading: 0)
        #expect(north.heading == 0)
        #expect(north.snappedToRow)
    }

    @Test func aFixOnTheVineRowItselfDoesNotGuessAnAisle() {
        let attachment = automatic(eastwardBlock(), longitude: 149.0, side: .left, heading: 0)
        #expect(!attachment.snappedToRow)
        #expect(attachment.drivingRowNumber == nil)
        #expect(attachment.pinRowNumber == nil)
    }

    @Test func aBlockWithoutMappedRowsStaysUnsnapped() {
        let bare = Paddock(
            name: "Bare",
            polygonPoints: eastwardBlock().polygonPoints,
            rows: [],
            rowDirection: 0,
            rowWidth: 3.7
        )
        let attachment = automatic(bare, longitude: 149.0, side: .left, heading: 0)
        #expect(!attachment.snappedToRow)
        #expect(attachment.pinRowNumber == nil)
        #expect(attachment.drivingRowNumber == nil)
    }

    @Test func noPaddockGeometryKeepsSideOnly() {
        let attachment = automatic(nil, longitude: aisle32_5Longitude, side: .right, heading: 10)
        #expect(!attachment.snappedToRow)
        #expect(attachment.pinRowNumber == nil)
        #expect(attachment.pinSide == .right)
        #expect(attachment.heading == 10)
    }

    @Test func pinSnapsOntoTheSelectedVineRowNotTheAisleCentreline() {
        let block = eastwardBlock()
        let attachment = automatic(block, longitude: aisle32_5Longitude, side: .left, heading: 0)
        let snapped = try! #require(attachment.snappedCoordinate)
        // Row 32's centreline, not the 32.5 midline the fix sits on.
        #expect(abs(snapped.longitude - 149.0) < 1e-9)
        #expect(abs(snapped.longitude - aisle32_5Longitude) > 1e-7)
        let along = try! #require(attachment.alongRowDistanceM)
        #expect(abs(along - 111.0) < 8.0)
    }

    // MARK: - Live trip lock

    @Test func liveTripLockAttachesToTheSelectedRowAndNotThePathCentreline() {
        let block = eastwardBlock()
        let coordinate = CLLocationCoordinate2D(latitude: -33.0, longitude: aisle32_5Longitude)
        let left = PinAttachmentResolver.resolveLive(
            rawCoordinate: coordinate,
            heading: 0,
            operatorSide: .left,
            drivingPath: 32.5,
            paddock: block,
            confident: true
        )
        let right = PinAttachmentResolver.resolveLive(
            rawCoordinate: coordinate,
            heading: 0,
            operatorSide: .right,
            drivingPath: 32.5,
            paddock: block,
            confident: true
        )
        #expect(left.pinRowNumber == 32)
        #expect(right.pinRowNumber == 33)
        #expect(left.drivingRowNumber == 32.5)
        let snapped = try! #require(left.snappedCoordinate)
        #expect(abs(snapped.longitude - 149.0) < 1e-9)
    }

    @Test func liveTripLockWithoutAValidHeadingKeepsTheAisleButClaimsNoRow() {
        let attachment = PinAttachmentResolver.resolveLive(
            rawCoordinate: CLLocationCoordinate2D(latitude: -33.0, longitude: aisle32_5Longitude),
            heading: nil,
            operatorSide: .left,
            drivingPath: 32.5,
            paddock: eastwardBlock(),
            confident: true
        )
        #expect(attachment.drivingRowNumber == 32.5)
        #expect(attachment.pinRowNumber == nil)
        #expect(!attachment.snappedToRow)
        #expect(attachment.snappedCoordinate == nil)
        #expect(attachment.heading == nil)
    }

    @Test func anUnconfidentLockRecordsNoAisleAtAll() {
        let attachment = PinAttachmentResolver.resolveLive(
            rawCoordinate: CLLocationCoordinate2D(latitude: -33.0, longitude: aisle32_5Longitude),
            heading: 0,
            operatorSide: .left,
            drivingPath: 32.5,
            paddock: eastwardBlock(),
            confident: false
        )
        #expect(attachment.drivingRowNumber == nil)
        #expect(attachment.pinRowNumber == nil)
        #expect(!attachment.snappedToRow)
    }

    // MARK: - Manual contract unchanged

    @Test func explicitManualPlacementNeverGainsADrivingPath() {
        let manual = PinAttachmentResolver.resolveManual(
            coordinate: CLLocationCoordinate2D(latitude: -33.0, longitude: aisle32_5Longitude),
            operatorSide: .left,
            paddock: eastwardBlock()
        )
        #expect(manual.pinRowNumber == 32)
        #expect(manual.drivingRowNumber == nil)
        #expect(manual.heading == nil)
    }

    // MARK: - Display fixture (supplied screenshot)

    private func screenshotPin() -> VinePin {
        VinePin(
            latitude: -33.295584,
            longitude: 148.957383,
            heading: 346,
            buttonName: "Irrigation",
            buttonColor: "blue",
            side: .right,
            mode: .repairs,
            rowNumber: 26,
            drivingRowNumber: 26.5,
            pinRowNumber: 26,
            pinSide: .right,
            alongRowDistanceM: 40,
            snappedLatitude: -33.295590,
            snappedLongitude: 148.957400,
            snappedToRow: true
        )
    }

    @Test func screenshotFixtureRendersItsStoredLocationLines() {
        let pin = screenshotPin()
        #expect(PinAttachmentFormatter.attachmentLine(pin) == "Row 26")
        #expect(
            PinAttachmentFormatter.drivingPathLine(pin)
                == "Row 26.5 — Right hand side facing North"
        )
        #expect(PinAttachmentFormatter.fullCompassName(degrees: 346) == "North")
    }

    @Test func aPinWithoutARecordedPathShowsNoFabricatedPathLine() {
        // Legacy row_number alone must never become a "Row X.5" driving path.
        let legacy = VinePin(
            latitude: -33.0,
            longitude: 149.0,
            heading: nil,
            buttonName: "Broken Post",
            buttonColor: "red",
            side: nil,
            mode: .repairs,
            rowNumber: 26
        )
        #expect(legacy.drivingRowNumber == nil)
        #expect(PinAttachmentFormatter.drivingPathLine(legacy) == nil)
    }

    @Test func markerDistanceAndDirectionsShareTheAttachedCoordinate() {
        let pin = screenshotPin()
        #expect(abs(pin.attachedCoordinate.latitude - (-33.295590)) < 1e-9)
        #expect(abs(pin.attachedCoordinate.longitude - 148.957400) < 1e-9)
        // The raw observation is preserved unchanged on the record.
        #expect(abs(pin.latitude - (-33.295584)) < 1e-9)

        var pointOnly = pin
        pointOnly.snappedToRow = false
        #expect(abs(pointOnly.attachedCoordinate.latitude - pin.latitude) < 1e-9)
        #expect(abs(pointOnly.attachedCoordinate.longitude - pin.longitude) < 1e-9)
    }

    // MARK: - Frozen capture

    @Test func theFrozenHeadingIsTheOneUsedToChooseTheRow() {
        let block = eastwardBlock()
        let attachment = automatic(block, longitude: aisle32_5Longitude, side: .right, heading: 346)
        // 346° is North-ish: right of North is east, so row 33.
        #expect(attachment.pinRowNumber == 33)
        #expect(attachment.heading == 346)

        // A later compass reading cannot change the frozen result.
        let moved = automatic(block, longitude: aisle32_5Longitude, side: .right, heading: 166)
        #expect(moved.pinRowNumber == 32)
        #expect(attachment.pinRowNumber == 33)
        #expect(attachment.drivingRowNumber == moved.drivingRowNumber)
    }
}
