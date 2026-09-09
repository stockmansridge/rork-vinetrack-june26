import XCTest
@testable import VineTrack

final class PinPresentationTargetTests: XCTestCase {
    private let vineyardId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testStandaloneGrowthRoutesToGrowthRecord() {
        let growth = makeGrowth(id: UUID(), pinId: nil)
        let target = PinPresentationTarget.resolve(displayId: growth.id, pins: [], growthRecords: [growth])

        XCTAssertEqual(target?.kind, .standaloneGrowth)
        XCTAssertEqual(target?.growthRecordId, growth.id)
        XCTAssertNil(target?.pinId)
    }

    func testLinkedGrowthKeepsBothIdsWithoutLocalPin() {
        let pinId = UUID()
        let growth = makeGrowth(id: UUID(), pinId: pinId)
        let target = PinPresentationTarget.resolve(displayId: pinId, pins: [], growthRecords: [growth])

        XCTAssertEqual(target?.kind, .linkedGrowth)
        XCTAssertEqual(target?.pinId, pinId)
        XCTAssertEqual(target?.growthRecordId, growth.id)
    }

    func testOrdinaryPinStaysPinOnly() {
        let pin = VinePin(
            id: UUID(), vineyardId: vineyardId, latitude: 0, longitude: 0,
            heading: nil, buttonName: "Repair", buttonColor: "red", side: nil, mode: .repairs
        )
        let target = PinPresentationTarget.resolve(displayId: pin.id, pins: [pin], growthRecords: [])

        XCTAssertEqual(target?.kind, .pin)
        XCTAssertEqual(target?.pinId, pin.id)
        XCTAssertNil(target?.growthRecordId)
    }

    private func makeGrowth(id: UUID, pinId: UUID?) -> GrowthStageRecord {
        GrowthStageRecord(
            id: id,
            vineyardId: vineyardId,
            paddockId: nil,
            pinId: pinId,
            stageCode: "EL4",
            observedAt: Date(),
            latitude: 0,
            longitude: 0
        )
    }
}
