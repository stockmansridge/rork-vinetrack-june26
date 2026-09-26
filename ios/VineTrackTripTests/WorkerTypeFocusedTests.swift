import Foundation
import Testing
@testable import VineTrack

@Suite @MainActor struct WorkerTypeDecodingTests {
    @Test func cataloguePreservesAllSevenServerRows() throws {
        let json = """
        [
          {"id":"f8f0700e-01e6-4e76-96ce-d8f2d0c9f3b9","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Contractor","cost_per_hour":55,"created_at":"2026-09-01T12:34:56+00:00"},
          {"id":"82eaf220-fd6a-4ba8-a9f3-0f54fdef7fbc","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"General Hand","cost_per_hour":32,"created_at":"2026-09-01T12:34:56+00:00"},
          {"id":"3359a58a-b3b1-4cd6-9fb2-d3a38f435499","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Tractor Operator","cost_per_hour":45,"created_at":"2026-09-01T12:34:56+00:00"},
          {"id":"150f6f18-eab4-4c3c-bb5f-613e98d254da","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Victoria Labour Hire ($32/Hr)","cost_per_hour":32,"created_at":"2026-09-01T12:34:56+00:00"},
          {"id":"c0f3b25f-6abb-4617-86e0-7f5f24eda739","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Victoria Labour Hire ($35/Hr)","cost_per_hour":35,"created_at":"2026-09-01T12:34:56+00:00"},
          {"id":"79fe2c89-05c5-4b2e-8202-65066a7e8b24","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager","cost_per_hour":65,"created_at":"2026-09-01T12:34:56+00:00"},
          {"id":"14a43189-ebe4-4343-80d0-baa4a738b008","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager (Mitch)","cost_per_hour":38,"created_at":"2026-09-01T12:34:56.123456+00:00","updated_at":"2026-09-02T12:34:56+00:00","deleted_at":null}
        ]
        """
        let rows = try SupabaseOperatorCategorySyncRepository.decodeRows(Data(json.utf8))
        #expect(rows.count == 7)
        #expect(Set(rows.map(\.name)) == Set(["Contractor", "General Hand", "Tractor Operator", "Victoria Labour Hire ($32/Hr)", "Victoria Labour Hire ($35/Hr)", "Vineyard Manager", "Vineyard Manager (Mitch)"]))
        #expect(rows.first(where: { $0.id.uuidString.lowercased() == "14a43189-ebe4-4343-80d0-baa4a738b008" })?.costPerHour == 38)
    }

    @Test func malformedTimestampFailsRatherThanPublishingEmpty() {
        let json = """
        [{"id":"14a43189-ebe4-4343-80d0-baa4a738b008","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Manager","cost_per_hour":38,"created_at":"not-a-date"}]
        """
        #expect(throws: DecodingError.self) { try SupabaseOperatorCategorySyncRepository.decodeRows(Data(json.utf8)) }
    }

    @Test func savedAssignmentSurvivesMissingLabel() throws {
        let json = """
        {"membership_id":"a37e4812-c559-4750-8da1-fb6fa5f98ce8","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","user_id":"4728e1e6-c538-4f0d-bc2f-6c9dcde9ac69","role":"manager","worker_type_id":"14a43189-ebe4-4343-80d0-baa4a738b008","worker_type_name":null}
        """
        let member = try RPCDecoding.decoder.decode(BackendVineyardMember.self, from: Data(json.utf8))
        #expect(member.operatorCategoryId == UUID(uuidString: "14a43189-ebe4-4343-80d0-baa4a738b008"))
        #expect(member.operatorCategoryName == nil)
    }
}

@Suite @MainActor struct TripLabourCostContractTests {
    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let worker = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let workerType = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private func completedTrip() -> Trip {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Trip(vineyardId: vineyard, paddockName: "Fixture block", startTime: start,
                    endTime: start.addingTimeInterval(7200), isActive: false,
                    operatorUserId: worker, operatorCategoryId: workerType)
    }

    private func cost(_ trip: Trip, rate: Double?) -> TripCostService.Result {
        TripCostService.estimate(trip: trip,
            operatorCategory: rate.map { OperatorCategory(id: workerType, vineyardId: vineyard, name: "Fixture worker", costPerHour: $0) },
            tractor: nil, fuelPurchases: [], sprayRecord: nil)
    }

    @Test func twoHoursAtThirtyEightPersistsIdentityAndLocalCostAfterReloadAndTripSyncPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trip = completedTrip()
        let initial = cost(trip, rate: 38)
        #expect(initial.activeHours == 2)
        #expect(initial.labour.costPerHour == 38)
        #expect(initial.labour.cost == 76)
        let persistence = PersistenceStore(directory: directory)
        TripRepository(persistence: persistence).saveSlice([trip], for: vineyard)
        let reloaded = try #require(TripRepository(persistence: PersistenceStore(directory: directory)).load(for: vineyard).first)
        #expect(reloaded.operatorUserId == worker)
        #expect(reloaded.operatorCategoryId == workerType)
        #expect(cost(reloaded, rate: 38).labour.cost == 76)
        let payload = BackendTrip.upsert(from: reloaded, createdBy: nil, clientUpdatedAt: trip.endTime ?? trip.startTime)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let synced = try RPCDecoding.decoder.decode(BackendTrip.self, from: encoder.encode(payload))
        #expect(synced.operatorUserId == worker)
        #expect(synced.operatorCategoryId == workerType)
        let allocation = TripCostAllocation(vineyardId: vineyard, tripId: trip.id, seasonYear: 2026, labourCost: initial.labour.cost, totalCost: initial.totalCost)
        TripCostAllocationRepository(persistence: persistence).saveSlice([allocation], for: vineyard)
        let saved = try #require(TripCostAllocationRepository(persistence: PersistenceStore(directory: directory)).load(for: vineyard).first)
        #expect(saved.labourCost == 76)
    }

    @Test func completedTripMustNotRepriceWhenCurrentWorkerTypeChanges() {
        let trip = completedTrip()
        #expect(cost(trip, rate: 38).labour.cost == 76)
        // Current Trip Detail and Android reports re-estimate from the mutable catalogue.
        // This acceptance assertion remains red until historical rate snapshots exist.
        #expect(cost(trip, rate: 45).labour.cost == 76)
    }
}

@Suite @MainActor struct WorkTaskLabourCostingTests {
    @Test func savedTwoHourWorkerTypeSnapshotKeepsSeventySixWithoutCatalogue() {
        let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let workerType = UUID(uuidString: "14a43189-ebe4-4343-80d0-baa4a738b008")!
        let line = WorkTaskLabourLine(workTaskId: UUID(), vineyardId: vineyard, workDate: Date(), operatorCategoryId: workerType, workerType: "Vineyard Manager (Mitch)", workerCount: 1, hoursPerWorker: 2, hourlyRate: 38, notes: "")
        #expect(line.operatorCategoryId == workerType)
        #expect(WorkTaskLabourCosting.personHours(line) == 2)
        #expect(WorkTaskLabourCosting.lineCost(line) == 76)
        #expect(WorkTaskLabourCosting.defaultRate(nil) == nil)
    }
}
