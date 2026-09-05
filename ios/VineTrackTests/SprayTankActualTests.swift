import Foundation
import Testing
@testable import VineTrack

@Suite("Phase 5 actual tank use")
struct SprayTankActualTests {
    @Test func sharedChemicalJsonAndZeroRemainDistinctFromMissing() throws {
        let json = #"{"id":"10000000-0000-4000-8000-000000000001","plannedChemicalId":null,"savedChemicalId":null,"name":"Product","actualAmountBase":0,"unit":"Litres"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SprayTankActualChemical.self, from: json)
        #expect(decoded.actualAmountBase == 0)
        #expect(decoded.displayAmount == 0)
    }

    @Test func liquidAndSolidConversionsPreserveExactBaseValues() throws {
        let liquid = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, name: "Liquid", actualAmountBase: ChemicalUnit.litres.toBase(3.5), unit: .litres)
        let solid = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, name: "Solid", actualAmountBase: ChemicalUnit.kilograms.toBase(1.125), unit: .kilograms)
        #expect(liquid.actualAmountBase == 3500)
        #expect(solid.actualAmountBase == 1125)
    }

    @Test func lifecycleResultReusesFillSessionIdentity() {
        let id = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        var trip = Trip(vineyardId: UUID(), paddockName: "Block", startTime: Date(), isActive: true)
        trip.tankSessions = [TankSession(id: id, tankNumber: 1, startTime: Date(), fillStartTime: Date())]
        trip.fillingTankNumber = 1
        let result = TankSessionLifecycle.startResult(trip: trip, at: Date(), currentRow: nil, plannedTankNumbers: [1])
        #expect(result?.tankSessionId == id)
        #expect(result?.tankNumber == 1)
    }
}
