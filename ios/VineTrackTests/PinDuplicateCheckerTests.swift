import XCTest
import CoreLocation
@testable import VineTrack

@MainActor
final class PinDuplicateCheckerTests: XCTestCase {
    private let vineyardId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherVineyardId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let blockId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let otherBlockId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let coordinate = CLLocationCoordinate2D(latitude: -34.0, longitude: 138.0)

    private func pin(
        id: UUID = UUID(),
        type: String,
        mode: PinMode = .repairs,
        vineyardId: UUID? = nil,
        blockId: UUID? = nil,
        latitude: Double = -34.0,
        longitude: Double = 138.0,
        completed: Bool = false,
        row: Int? = nil,
        side: PinSide? = .left,
        along: Double? = nil
    ) -> VinePin {
        VinePin(
            id: id,
            vineyardId: vineyardId ?? self.vineyardId,
            latitude: latitude,
            longitude: longitude,
            heading: nil,
            buttonName: type,
            buttonColor: "red",
            side: side,
            mode: mode,
            paddockId: blockId ?? self.blockId,
            rowNumber: row,
            isCompleted: completed,
            pinRowNumber: row,
            pinSide: side,
            alongRowDistanceM: along,
            snappedLatitude: row == nil ? nil : latitude,
            snappedLongitude: row == nil ? nil : longitude,
            snappedToRow: row != nil
        )
    }

    private func evaluate(
        type: String,
        mode: PinMode = .repairs,
        vineyardId: UUID? = nil,
        blockId: UUID? = nil,
        coordinate: CLLocationCoordinate2D? = nil,
        row: Int? = nil,
        side: PinSide? = .left,
        pins: [VinePin],
        paddocks: [Paddock] = []
    ) -> PinDuplicateChecker.Evaluation {
        PinDuplicateChecker.evaluate(
            coordinate: coordinate ?? self.coordinate,
            vineyardId: vineyardId ?? self.vineyardId,
            paddockId: blockId ?? self.blockId,
            rowNumber: row,
            side: side,
            mode: mode,
            logicalType: type,
            in: pins,
            paddocks: paddocks
        )
    }

    func testSameTypeWarnsButDifferentLauncherTypesNeverWarn() throws {
        let broken = pin(type: "Broken Post")
        XCTAssertEqual(try XCTUnwrap(evaluate(type: "Broken Post", pins: [broken]).match).pin.id, broken.id)
        XCTAssertNil(evaluate(type: "Growth Stage", mode: .growth, pins: [broken]).match)
        XCTAssertNil(evaluate(type: "Irrigation", pins: [broken]).match)

        let powdery = pin(type: "Powdery", mode: .growth)
        XCTAssertNil(evaluate(type: "Downy", mode: .growth, pins: [powdery]).match)
    }

    func testGrowthStageCodesCaseAndWhitespaceNormalizeToOneLogicalType() throws {
        let growth = pin(type: " Growth   Stage EL 31 ", mode: .growth)
        let result = evaluate(type: "Growth Stage EL 33", mode: .growth, pins: [growth])
        XCTAssertEqual(try XCTUnwrap(result.match).pin.id, growth.id)
        XCTAssertEqual(result.diagnostics.candidateKey.logicalType, "growth stage")

        let broken = pin(type: "  broken   post ")
        XCTAssertEqual(try XCTUnwrap(evaluate(type: "Broken Post", pins: [broken]).match).pin.id, broken.id)
    }

    func testVineyardBlockRadiusAndOpenStateAreRequired() {
        let candidates = [
            pin(type: "Broken Post", vineyardId: otherVineyardId),
            pin(type: "Broken Post", blockId: otherBlockId),
            pin(type: "Broken Post", longitude: 138.001),
            pin(type: "Broken Post", completed: true),
        ]
        XCTAssertNil(evaluate(type: "Broken Post", pins: candidates).match)
    }

    func testSoftDeletedBackendPinsCannotEnterTheCandidateList() throws {
        let json = Data("""
        {"id":"55555555-5555-5555-5555-555555555555",
         "vineyard_id":"11111111-1111-1111-1111-111111111111",
         "paddock_id":"33333333-3333-3333-3333-333333333333",
         "mode":"Repairs","button_name":"Broken Post",
         "latitude":-34.0,"longitude":138.0,"is_completed":false,
         "deleted_at":1788480000}
        """.utf8)
        let backend = try JSONDecoder().decode(BackendPin.self, from: json)
        XCTAssertNil(backend.toVinePin())
    }

    func testAlongRowAndLegacyRawDistanceUseTheSameTypeContract() throws {
        let block = Paddock(
            id: blockId,
            vineyardId: vineyardId,
            name: "Block",
            polygonPoints: [],
            rows: [
                PaddockRow(
                    number: 1,
                    startPoint: CoordinatePoint(latitude: -34.0, longitude: 138.0),
                    endPoint: CoordinatePoint(latitude: -33.999, longitude: 138.0)
                )
            ],
            rowDirection: 0,
            rowWidth: 3.7
        )
        let alongPin = pin(type: "Broken Post", row: 1, along: 0)
        let alongResult = evaluate(type: "Broken Post", row: 1, pins: [alongPin], paddocks: [block])
        XCTAssertEqual(try XCTUnwrap(alongResult.match).method, .alongRow)
        XCTAssertNil(evaluate(type: "Irrigation", row: 1, pins: [alongPin], paddocks: [block]).match)

        let legacyPin = pin(type: "Broken Post")
        let rawResult = evaluate(type: "Broken Post", pins: [legacyPin], paddocks: [block])
        XCTAssertEqual(try XCTUnwrap(rawResult.match).method, .rawDistance)
        XCTAssertNil(evaluate(type: "Irrigation", pins: [legacyPin], paddocks: [block]).match)
    }

    func testAdjacentRowAttachedPinCannotReenterThroughRawDistance() {
        let attachedAdjacent = pin(type: "Broken Post", row: 2, along: 0)
        XCTAssertNil(evaluate(type: "Broken Post", row: 1, pins: [attachedAdjacent]).match)
    }

    func testLargeAccumulatedCollectionReturnsOnlySameTypeWithoutMutation() throws {
        let otherPins = (0..<5_000).map { index in
            pin(
                type: index.isMultiple(of: 2) ? "Irrigation" : "Growth Stage EL 31",
                mode: index.isMultiple(of: 2) ? .repairs : .growth
            )
        }
        let snapshot = otherPins
        let noMatch = evaluate(type: "Broken Post", pins: otherPins)
        XCTAssertNil(noMatch.match)
        XCTAssertEqual(noMatch.diagnostics.vineyardPinsInspected, 5_000)
        XCTAssertEqual(noMatch.diagnostics.sameTypeCandidates, 0)

        let validId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let valid = pin(id: validId, type: "Broken Post")
        let source = otherPins + [valid]
        let result = evaluate(type: "Broken Post", pins: source)
        XCTAssertEqual(try XCTUnwrap(result.match).pin.id, validId)
        XCTAssertEqual(otherPins, snapshot)
        XCTAssertEqual(source.count, 5_001)
        XCTAssertEqual(result.diagnostics.result, "duplicate_same_type_raw_distance")
    }
}
