import Foundation
import Testing
@testable import VineTrack

@Suite("Canonical Spray Report v1")
struct SprayReportPayloadV1Tests {
    @Test("Spray classification accepts the explicit trip function")
    func explicitSprayClassification() {
        let trip = Trip(tripFunction: TripFunction.spraying.rawValue)
        #expect(SprayReportPayloadV1.isSprayTrip(trip, linkedRecord: nil))
    }

    @Test("Projection preserves tank attribution and planned versus actual values")
    func projectionSemantics() throws {
        let tripId = UUID()
        let vineyardId = UUID()
        let lineId = UUID()
        let session = TankSession(tankNumber: 1, pathsCovered: [1.5])
        let trip = Trip(
            id: tripId,
            vineyardId: vineyardId,
            startTime: Date(timeIntervalSince1970: 1_788_480_000),
            endTime: Date(timeIntervalSince1970: 1_788_490_860),
            rowSequence: [1.5, 2.5],
            personName: "Operator",
            totalDistance: 12_439.15,
            completedPaths: [1.5],
            tankSessions: [session],
            tripFunction: TripFunction.spraying.rawValue,
            startEngineHours: 100,
            endEngineHours: 103.1
        )
        let chemical = SprayChemical(id: lineId, name: "Product", volumePerTank: 3_000, unit: .litres)
        let record = SprayRecord(tripId: tripId, vineyardId: vineyardId, sprayReference: "Late Woolly", tanks: [SprayTank(tankNumber: 1, waterVolume: 1_500, chemicals: [chemical])])
        let actualChemical = try SprayTankActualChemical(plannedChemicalId: lineId, savedChemicalId: nil, name: "Product", actualAmountBase: 2_800, unit: .litres)
        let substitute = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, replacesPlannedChemicalId: lineId, usageKind: "substitution", name: "Replacement", actualAmountBase: 500, unit: .millilitres)
        let actual = try SprayTankActual(vineyardId: vineyardId, sprayRecordId: record.id, tripId: tripId, tankSessionId: session.id.uuidString, tankNumber: 1, waterVolumeL: 1_450, chemicals: [actualChemical, substitute], confirmedAt: Date(), confirmedBy: UUID(), correctionVersion: 2)

        let payload = SprayReportPayloadV1.offlineProjection(trip: trip, record: record, vineyardName: "Stockmans Ridge", timeZone: TimeZone(identifier: "Australia/Sydney")!, paddocks: [], tractorName: "Tractor", sprayUnitName: "Sprayer", tankActuals: [actual])

        #expect(payload.rows.first?.tank == .number(1))
        #expect(payload.tanks.first?.plannedWaterLitres == 1_500)
        #expect(payload.tanks.first?.actualWaterLitres == 1_450)
        #expect(payload.tanks.first?.chemicals.first?.plannedAmountBase == 3_000)
        #expect(payload.tanks.first?.chemicals.first?.actualAmountBase == 2_800)
        #expect(payload.tanks.first?.actualVersion == 2)
        #expect(payload.tanks.first?.chemicals.last?.usageKind == "substitution")
        #expect(payload.tanks.first?.chemicals.last?.plannedAmountBase == nil)
        #expect(payload.actualChemicalTotals.count == 2)
        #expect(abs((payload.equipment.engineHoursUsed ?? 0) - 3.1) < 0.000_001)
    }

    @Test("iOS filename uses canonical prefix, stable fragment and suffix")
    func filename() {
        let trip = Trip(id: UUID(uuidString: "a1b2c3d4-0000-4000-8000-000000000001")!, vineyardId: UUID(), startTime: Date(timeIntervalSince1970: 1_788_480_000), endTime: Date(timeIntervalSince1970: 1_788_480_100), tripFunction: "spraying")
        let record = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId, sprayReference: "Late Woolly / Stage 2-3")
        let payload = SprayReportPayloadV1.offlineProjection(trip: trip, record: record, vineyardName: "Stockmans Ridge", timeZone: TimeZone(identifier: "Australia/Sydney")!, paddocks: [], tractorName: "", sprayUnitName: "", tankActuals: [])
        let name = payload.exportFileName(platform: "ios")
        #expect(name.hasPrefix("SprayReport_Stockmans_Ridge_"))
        #expect(name.contains("Late_Woolly_Stage_2-3_a1b2c3d4-ios.pdf"))
    }
}
