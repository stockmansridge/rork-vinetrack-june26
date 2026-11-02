import Foundation
import XCTest
@testable import VineTrack

final class SprayTankActualTests: XCTestCase {
    func testSharedRepositoryChemicalFixtureDecodesCompleteContract() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "spray_tank_actual_chemical", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(SprayTankActualChemical.self, from: data)
        XCTAssertEqual(decoded.plannedChemicalId?.uuidString.lowercased(), "10000000-0000-4000-8000-000000000002")
        XCTAssertEqual(decoded.savedChemicalId?.uuidString.lowercased(), "10000000-0000-4000-8000-000000000003")
        XCTAssertEqual(decoded.actualAmountBase, 1250.5)
        XCTAssertEqual(decoded.unit, .millilitres)
    }

    func testSharedChemicalJsonAndZeroRemainDistinctFromMissing() throws {
        let json = #"{"id":"10000000-0000-4000-8000-000000000001","plannedChemicalId":null,"savedChemicalId":null,"name":"Product","actualAmountBase":0,"unit":"Litres"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SprayTankActualChemical.self, from: json)
        XCTAssertEqual(decoded.actualAmountBase, 0)
        XCTAssertEqual(decoded.displayAmount, 0)
    }

    func testLiquidAndSolidConversionsPreserveExactBaseValues() throws {
        let liquid = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, name: "Liquid", actualAmountBase: ChemicalUnit.litres.toBase(3.5), unit: .litres)
        let solid = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, name: "Solid", actualAmountBase: ChemicalUnit.kilograms.toBase(1.125), unit: .kilograms)
        XCTAssertEqual(liquid.actualAmountBase, 3500)
        XCTAssertEqual(solid.actualAmountBase, 1125)
    }

    func testInvalidAmountsAreRejectedButZeroIsValid() throws {
        XCTAssertNoThrow(try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, name: "Zero", actualAmountBase: 0, unit: .millilitres))
        XCTAssertThrowsError(try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, name: "Negative", actualAmountBase: -1, unit: .millilitres))
        XCTAssertThrowsError(try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, name: "NaN", actualAmountBase: .nan, unit: .millilitres))
        XCTAssertThrowsError(try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, name: "Infinity", actualAmountBase: .infinity, unit: .millilitres))
    }

    func testCompletenessRequiresWaterAndExactSessionButAcceptsValidAmendmentLines() throws {
        let vineyardId = UUID(), recordId = UUID(), tripId = UUID(), sessionId = UUID(), plannedId = UUID()
        let tank = SprayTank(tankNumber: 1, waterVolume: 500, chemicals: [SprayChemical(id: plannedId, name: "Product", volumePerTank: 1_000, unit: .millilitres)])
        let substitute = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, replacesPlannedChemicalId: plannedId, usageKind: "substitution", name: "Replacement", actualAmountBase: 900, unit: .millilitres)
        let addition = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, usageKind: "additional", name: "Addition", actualAmountBase: 250, unit: .millilitres)
        let actual = try SprayTankActual(vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionId: sessionId.uuidString, tankNumber: 1, waterVolumeL: 0, chemicals: [substitute, addition], confirmedAt: Date(), confirmedBy: UUID())
        XCTAssertTrue(areSprayTankActualsComplete(plannedTanks: [tank], actuals: [actual], vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionIdsByNumber: [1: [sessionId.uuidString]]))
        let missingWater = try SprayTankActual(id: actual.id, vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionId: sessionId.uuidString, tankNumber: 1, waterVolumeL: nil, chemicals: [substitute, addition], confirmedAt: actual.confirmedAt, confirmedBy: actual.confirmedBy)
        XCTAssertFalse(areSprayTankActualsComplete(plannedTanks: [tank], actuals: [missingWater], vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionIdsByNumber: [1: [sessionId.uuidString]]))
        XCTAssertFalse(areSprayTankActualsComplete(plannedTanks: [tank], actuals: [actual], vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionIdsByNumber: [:]))
        let extra = try SprayTankActual(vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionId: UUID().uuidString, tankNumber: 2, waterVolumeL: 1, chemicals: [], confirmedAt: Date(), confirmedBy: UUID())
        XCTAssertFalse(areSprayTankActualsComplete(plannedTanks: [tank], actuals: [actual, extra], vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionIdsByNumber: [1: [sessionId.uuidString]]))
        let duplicatedAddition = try SprayTankActual(id: actual.id, vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionId: sessionId.uuidString, tankNumber: 1, waterVolumeL: 0, chemicals: [substitute, addition, addition], confirmedAt: actual.confirmedAt, confirmedBy: actual.confirmedBy)
        XCTAssertFalse(areSprayTankActualsComplete(plannedTanks: [tank], actuals: [duplicatedAddition], vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionIdsByNumber: [1: [sessionId.uuidString]]))
        let zeroPlanned = try SprayTankActualChemical(plannedChemicalId: plannedId, savedChemicalId: nil, name: "Product", actualAmountBase: 0, unit: .millilitres)
        let amended = try SprayTankActual(id: actual.id, vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionId: sessionId.uuidString, tankNumber: 1, waterVolumeL: 0, chemicals: [zeroPlanned, substitute, addition], confirmedAt: actual.confirmedAt, confirmedBy: actual.confirmedBy)
        XCTAssertTrue(areSprayTankActualsComplete(plannedTanks: [tank], actuals: [amended], vineyardId: vineyardId, sprayRecordId: recordId, tripId: tripId, tankSessionIdsByNumber: [1: [sessionId.uuidString]]))
    }

    func testLifecycleResultReusesFillSessionIdentity() {
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        var trip = Trip(vineyardId: UUID(), paddockName: "Block", startTime: Date(), isActive: true)
        trip.tankSessions = [TankSession(id: id, tankNumber: 1, startTime: Date(), fillStartTime: Date())]
        trip.fillingTankNumber = 1
        let result = TankSessionLifecycle.startResult(trip: trip, at: Date(), currentRow: nil, plannedTankNumbers: [1])
        XCTAssertEqual(result?.tankSessionId, id)
        XCTAssertEqual(result?.tankNumber, 1)
    }

    func testCompletedPlanCannotStartAnotherTank() {
        var trip = Trip(vineyardId: UUID(), paddockName: "Block", startTime: Date(), isActive: true)
        trip.tankSessions = [TankSession(tankNumber: 1, startTime: Date(), endTime: Date())]
        XCTAssertNil(TankSessionLifecycle.startResult(trip: trip, at: Date(), currentRow: nil, plannedTankNumbers: [1]))
    }

    // Issue #43 RED: the actual production RPC request must preserve both explicitly null linkage keys.
    func testIssue43ProductionRPCRequestRequiresNullLinkageKeys() throws {
        let line = try SprayTankActualChemical(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            plannedChemicalId: nil, savedChemicalId: nil,
            usageKind: "additional", name: "Added product",
            actualAmountBase: 250, unit: .millilitres
        )
        let actual = try SprayTankActual(
            vineyardId: UUID(), sprayRecordId: UUID(), tripId: UUID(),
            tankSessionId: UUID().uuidString, tankNumber: 1, waterVolumeL: 500,
            chemicals: [line], confirmedAt: Date(timeIntervalSince1970: 1_790_000_000),
            confirmedBy: UUID()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(SprayTankActualUpsertRequest(actual: actual))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(request["p_chemicals"] as? [[String: Any]])
        let json = try XCTUnwrap(rows.first)
        XCTAssertTrue(json.keys.contains("plannedChemicalId"), "Backend requires explicit nullable plannedChemicalId")
        XCTAssertTrue(json.keys.contains("savedChemicalId"), "Backend requires explicit nullable savedChemicalId")
        XCTAssertTrue(json["plannedChemicalId"] is NSNull)
        XCTAssertTrue(json["savedChemicalId"] is NSNull)
        XCTAssertEqual(json["actualAmountBase"] as? Double, 250)
    }

    // Issue #43 RED: old/new JSONB provenance must not disappear after a typed iOS read and encode.
    func testIssue43ChemicalRoundTripRetainsAndroidProvenance() throws {
        let source = #"{"id":"10000000-0000-4000-8000-000000000001","plannedChemicalId":null,"savedChemicalId":null,"name":"Product","actualAmountBase":250,"unit":"mL","productCategory":"Herbicide","physicalForm":"Liquid","snapshotAt":"2026-11-02T01:00:00Z"}"#.data(using: .utf8)!
        let value = try JSONDecoder().decode(SprayTankActualChemical.self, from: source)
        let written = try JSONEncoder().encode(value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(json["productCategory"] as? String, "Herbicide")
        XCTAssertEqual(json["physicalForm"] as? String, "Liquid")
        XCTAssertEqual(json["snapshotAt"] as? String, "2026-11-02T01:00:00Z")
    }


}
