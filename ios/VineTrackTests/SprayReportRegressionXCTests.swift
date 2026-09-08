import XCTest
import PDFKit
@testable import VineTrack

final class SprayReportRegressionXCTests: XCTestCase {
    func testDuplicateOperationalCacheRowsCollapseBeforeSpraysListRendering() throws {
        let sharedId = UUID()
        let older = SprayRecord(id: sharedId, date: Date(timeIntervalSince1970: 100), sprayReference: "Older", tanks: [SprayTank()])
        let newer = SprayRecord(id: sharedId, date: Date(timeIntervalSince1970: 200), sprayReference: "Newer", tanks: [SprayTank()])
        let other = SprayRecord(sprayReference: "Other", tanks: [SprayTank()])

        let records = SprayProgramOperationalRecords.unique([older, newer, other, newer])

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.id)).count, records.count)
        XCTAssertEqual(records.first(where: { $0.id == sharedId })?.sprayReference, "Newer")
    }

    func testContinuationPagesRepeatPlannedActualHeadersAndPageFooters() throws {
        let trip = Trip(vineyardId: UUID(), startTime: Date(timeIntervalSince1970: 1_788_480_000), endTime: Date(timeIntervalSince1970: 1_788_490_860), tripFunction: "spraying")
        let chemicals: [SprayChemical] = (1...55).map { index in
            SprayChemical(name: "Long wrapped product name \(index) with qualification and formulation detail", volumePerTank: Double(index) * 1_000, unit: index.isMultiple(of: 2) ? .litres : .kilograms)
        }
        let record = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId, sprayReference: "Continuation acceptance", tanks: [SprayTank(tankNumber: 1, waterVolume: 1_500, chemicals: chemicals)])
        let payload = SprayReportPayloadV1.offlineProjection(trip: trip, record: record, vineyardName: "Stockmans Ridge", timeZone: .gmt, paddocks: [], tractorName: "", sprayUnitName: "", tankActuals: [])
        let data = SprayRecordPDFService.generatePDF(payload: payload, record: record, trip: trip, vineyardName: "Stockmans Ridge", paddockName: "", personName: "", includeCostings: false, timeZone: .gmt)
        let document = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertGreaterThanOrEqual(document.pageCount, 3)
        var tablePageCount = 0
        for pageIndex in 0..<document.pageCount {
            let text = try XCTUnwrap(document.page(at: pageIndex)?.string)
            XCTAssertTrue(text.contains("Page \(pageIndex + 1)"))
            if text.contains("ITEM") {
                tablePageCount += 1
                XCTAssertTrue(text.contains("PLANNED"))
                XCTAssertTrue(text.contains("ACTUAL"))
            }
        }
        XCTAssertGreaterThanOrEqual(tablePageCount, 2)
    }
}
