import Foundation
import Testing
@testable import VineTrack

@MainActor
struct WorkerTypeDecodingTests {
    @Test func serverTimestampAndNullableFieldsKeepSavedIdentityAndRate() throws {
        let json = """
        [{"id":"14a43189-ebe4-4343-80d0-baa4a738b008","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager (Mitch)","cost_per_hour":38,"created_at":"2026-09-01T12:34:56.123456+00:00","updated_at":"2026-09-02T12:34:56+00:00","deleted_at":null,"client_updated_at":null}]
        """
        let rows = try SupabaseOperatorCategorySyncRepository.decodeRows(Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].id == UUID(uuidString: "14a43189-ebe4-4343-80d0-baa4a738b008"))
        #expect(rows[0].name == "Vineyard Manager (Mitch)")
        #expect(rows[0].costPerHour == 38)
        #expect(rows[0].createdAt != nil && rows[0].updatedAt != nil)
        #expect(rows[0].deletedAt == nil && rows[0].clientUpdatedAt == nil)
    }

    @Test func auditedSevenActiveWorkerTypesKeepTheirNamesAndRates() throws {
        let json = """
        [
        {"id":"f8f0700e-01e6-4e76-96ce-d8f2d0c9f3b9","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Contractor","cost_per_hour":55,"created_at":"2026-09-01T12:34:56+00:00","deleted_at":null},
        {"id":"82eaf220-fd6a-4ba8-a9f3-0f54fdef7fbc","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"General Hand","cost_per_hour":32,"created_at":"2026-09-01T12:34:56+00:00","deleted_at":null},
        {"id":"3359a58a-b3b1-4cd6-9fb2-d3a38f435499","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Tractor Operator","cost_per_hour":45,"created_at":"2026-09-01T12:34:56+00:00","deleted_at":null},
        {"id":"150f6f18-eab4-4c3c-bb5f-613e98d254da","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Victoria Labour Hire ($32/Hr)","cost_per_hour":32,"created_at":"2026-09-01T12:34:56+00:00","deleted_at":null},
        {"id":"c0f3b25f-6abb-4617-86e0-7f5f24eda739","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Victoria Labour Hire ($35/Hr)","cost_per_hour":35,"created_at":"2026-09-01T12:34:56+00:00","deleted_at":null},
        {"id":"79fe2c89-05c5-4b2e-8202-65066a7e8b24","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager","cost_per_hour":65,"created_at":"2026-09-01T12:34:56+00:00","deleted_at":null},
        {"id":"14a43189-ebe4-4343-80d0-baa4a738b008","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager (Mitch)","cost_per_hour":38,"created_at":"2026-09-01T12:34:56+00:00","deleted_at":null}
        ]
        """
        let rows = try SupabaseOperatorCategorySyncRepository.decodeRows(Data(json.utf8))
        #expect(rows.count == 7)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id.uuidString.lowercased(), ($0.name, $0.costPerHour)) })
        #expect(byID["f8f0700e-01e6-4e76-96ce-d8f2d0c9f3b9"]?.0 == "Contractor" && byID["f8f0700e-01e6-4e76-96ce-d8f2d0c9f3b9"]?.1 == 55)
        #expect(byID["82eaf220-fd6a-4ba8-a9f3-0f54fdef7fbc"]?.0 == "General Hand" && byID["82eaf220-fd6a-4ba8-a9f3-0f54fdef7fbc"]?.1 == 32)
        #expect(byID["3359a58a-b3b1-4cd6-9fb2-d3a38f435499"]?.0 == "Tractor Operator" && byID["3359a58a-b3b1-4cd6-9fb2-d3a38f435499"]?.1 == 45)
        #expect(byID["150f6f18-eab4-4c3c-bb5f-613e98d254da"]?.0 == "Victoria Labour Hire ($32/Hr)" && byID["150f6f18-eab4-4c3c-bb5f-613e98d254da"]?.1 == 32)
        #expect(byID["c0f3b25f-6abb-4617-86e0-7f5f24eda739"]?.0 == "Victoria Labour Hire ($35/Hr)" && byID["c0f3b25f-6abb-4617-86e0-7f5f24eda739"]?.1 == 35)
        #expect(byID["79fe2c89-05c5-4b2e-8202-65066a7e8b24"]?.0 == "Vineyard Manager" && byID["79fe2c89-05c5-4b2e-8202-65066a7e8b24"]?.1 == 65)
        #expect(byID["14a43189-ebe4-4343-80d0-baa4a738b008"]?.0 == "Vineyard Manager (Mitch)" && byID["14a43189-ebe4-4343-80d0-baa4a738b008"]?.1 == 38)
    }

    @Test func managerMembershipRetainsIDEvenWhenLabelUnavailable() throws {
        let json = """
        {"membership_id":"a37e4812-c559-4750-8da1-fb6fa5f98ce8","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","user_id":"4728e1e6-c538-4f0d-bc2f-6c9dcde9ac69","role":"manager","worker_type_id":"14a43189-ebe4-4343-80d0-baa4a738b008","worker_type_name":null,"joined_at":null}
        """
        let member = try RPCDecoding.decoder.decode(BackendVineyardMember.self, from: Data(json.utf8))
        #expect(member.role == .manager)
        #expect(member.operatorCategoryId == UUID(uuidString: "14a43189-ebe4-4343-80d0-baa4a738b008"))
        #expect(member.operatorCategoryName == nil)
    }

    @Test func malformedRowDoesNotBecomeSuccessfulEmptyCatalogue() {
        let json = """
        [{"id":"14a43189-ebe4-4343-80d0-baa4a738b008","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager (Mitch)","cost_per_hour":38,"created_at":"not-a-date"}]
        """
        #expect(throws: DecodingError.self) {
            try SupabaseOperatorCategorySyncRepository.decodeRows(Data(json.utf8))
        }
    }
}
