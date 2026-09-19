import Foundation
import Testing
@testable import VineTrack

@MainActor
struct VineyardInsightsFocusedTests {
    @Test func growthStagePayloadUsesAppliedDatabaseColumn() throws {
        let payload = VineyardInsightsSyncRepository.ObservationUpsert(
            id: "o", assessment_id: "a", vineyard_id: "v", item_kind: "growth_stage",
            value_code: nil, value_label: nil, notes: nil, linked_pin_id: "pin",
            linked_growth_record_id: "growth", client_updated_at: "now"
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(object["linked_growth_record_id"] as? String == "growth")
        #expect(object["linked_growth_stage_record_id"] == nil)
    }

    @Test func customTypeHasStableUUIDAndRefreshesCatalogue() {
        let suite = "insights-focused-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = VineyardInsightsService(store: VineyardInsightsStore(defaults: defaults))
        let vineyardID = UUID()
        let type = service.addCustomNoteType(vineyardID: vineyardID, label: "Wind damage")
        #expect(type?.databaseID != nil)
        #expect(service.customNoteTypes(vineyardID: vineyardID).first?.databaseID == type?.databaseID)
    }

    @Test func legacyFrostResolvesToDatabaseUUIDWithoutLosingSnapshot() throws {
        let suite = "insights-focused-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VineyardInsightsStore(defaults: defaults)
        let service = VineyardInsightsService(store: store)
        let vineyardID = UUID()
        var draft = VintageNoteDraft()
        draft.noteTypeID = "frost"
        draft.noteTypeLabel = "Frost"
        let note = try #require(service.saveNote(
            draft: draft, vineyardID: vineyardID, observedByUserID: nil,
            observerName: "Scout", seasonStartMonth: 7, seasonStartDay: 1
        ))
        let frostID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000240"))
        let frost = VintageNoteType(
            databaseID: frostID, code: "frost", group: .weather, label: "Frost",
            sortOrder: 1, isCustom: false, vineyardID: nil, isSystem: true
        )
        #expect(store.reconcileNoteTypes([frost], vineyardID: vineyardID))
        let resolved = try #require(store.loadNotes().first { $0.id == note.id })
        #expect(resolved.noteTypeID == frostID.uuidString)
        #expect(resolved.noteTypeLabelSnapshot == "Frost")
    }

    @Test func cleanupObligationsSurviveRestart() throws {
        let suite = "insights-focused-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vineyardID = UUID()
        let first = VineyardInsightsStore(defaults: defaults)
        #expect(first.queueObjectCleanup(vineyardID: vineyardID, storagePath: "v/o/p.jpg"))
        #expect(first.queueLocalFileCleanup(vineyardID: vineyardID, relativePaths: ["v/o/p.jpg"]))
        let restarted = VineyardInsightsStore(defaults: defaults)
        #expect(restarted.loadObjectCleanup().singleValue?.storagePath == "v/o/p.jpg")
        #expect(restarted.loadLocalFileCleanup().singleValue?.relativePath == "v/o/p.jpg")
    }

    @Test func clearedObservationPayloadContainsNullValues() throws {
        let payload = VineyardInsightsSyncRepository.ObservationUpsert(
            id: "o", assessment_id: "a", vineyard_id: "v", item_kind: "disease",
            value_code: nil, value_label: nil, notes: nil, linked_pin_id: nil,
            linked_growth_record_id: nil, client_updated_at: "now"
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(object["value_code"] is NSNull)
        #expect(object["value_label"] is NSNull)
        #expect(object["notes"] is NSNull)
    }
}

private extension Array {
    var singleValue: Element? { count == 1 ? first : nil }
}
