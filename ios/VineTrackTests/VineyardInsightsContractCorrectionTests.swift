import Foundation
import Testing
@testable import VineTrack

@MainActor
struct VineyardInsightsContractCorrectionTests {
    @Test("Growth Stage payload uses the applied database column")
    func growthStagePayloadKey() throws {
        let payload = VineyardInsightsSyncRepository.ObservationUpsert(
            id: "o", assessment_id: "a", vineyard_id: "v", item_kind: "growth_stage",
            value_code: nil, value_label: nil, notes: nil, linked_pin_id: "pin",
            linked_growth_record_id: "growth", client_updated_at: "now"
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(object["linked_growth_record_id"] as? String == "growth")
        #expect(object["linked_growth_stage_record_id"] == nil)
    }

    @Test("Pulled observation restores pin and Growth Stage record ids")
    func growthStageResponseKey() throws {
        let json = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"assessment_id\":\"00000000-0000-0000-0000-000000000002\",\"vineyard_id\":\"00000000-0000-0000-0000-000000000003\",\"item_kind\":\"growth_stage\",\"linked_pin_id\":\"00000000-0000-0000-0000-000000000004\",\"linked_growth_record_id\":\"00000000-0000-0000-0000-000000000005\"}"
        let data = Data(json.utf8)
        let row = try JSONDecoder().decode(VineyardInsightsSyncRepository.ObservationRow.self, from: data)
        #expect(row.linked_pin_id?.uuidString == "00000000-0000-0000-0000-000000000004")
        #expect(row.linked_growth_record_id?.uuidString == "00000000-0000-0000-0000-000000000005")
    }

    @Test("upsert_vintage_note returns a scalar row, not a JSON array")
    func noteUpsertScalarResponse() throws {
        // SQL RETURNS vintage_notes; RPC serialises one row as a JSON object.
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000011",
          "vineyard_id": "00000000-0000-0000-0000-000000000012",
          "note_date": "2026-11-05",
          "vintage_year": 2027,
          "note_type_id": null,
          "note_type_label": "Frost",
          "notes": "Test observation",
          "sync_version": 1
        }
        """
        let row = try JSONDecoder().decode(
            VineyardInsightsSyncRepository.NoteRow.self, from: Data(json.utf8)
        )
        #expect(row.vintage_year == 2027)
        #expect(row.note_type_label == "Frost")
        #expect(row.id.uuidString == "00000000-0000-0000-0000-000000000011")
    }

    @Test("Custom note type owns a stable UUID")
    func customTypeIdentity() {
        let suite = "insights-contract-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = VineyardInsightsService(store: VineyardInsightsStore(defaults: defaults))
        let vineyardID = UUID()
        let type = service.addCustomNoteType(vineyardID: vineyardID, label: "Wind damage")
        #expect(type?.databaseID != nil)
        #expect(service.customNoteTypes(vineyardID: vineyardID).first?.databaseID == type?.databaseID)
    }
}
