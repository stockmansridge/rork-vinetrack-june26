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

    @Test func bootstrapFrostSelectionCreatesSaveableTypeOnlyOfflineDraft() throws {
        let frost = try #require(VintageNoteCatalog.systemTypes.first { $0.code == "frost" })
        var draft = VintageNoteDraft()
        draft.noteTypeID = frost.persistedIdentity
        draft.noteTypeLabel = frost.label
        #expect(draft.noteTypeID == "frost")
        #expect(draft.noteTypeLabel == "Frost")
        #expect(draft.canSave)

        let suite = "insights-focused-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = VineyardInsightsService(store: VineyardInsightsStore(defaults: defaults))
        let note = try #require(service.saveNote(
            draft: draft, vineyardID: UUID(), observedByUserID: nil,
            observerName: "Scout", seasonStartMonth: 7, seasonStartDay: 1
        ))
        #expect(note.noteTypeID == "frost")
        #expect(note.noteTypeLabelSnapshot == "Frost")
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

    @Test func signOutClearsCleanupJournalAndCancelsPendingDebounce() async throws {
        let suite = "insights-focused-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VineyardInsightsStore(defaults: defaults)
        let vineyardID = UUID()
        #expect(store.queueLocalFileCleanup(vineyardID: vineyardID, relativePaths: ["v/o/p.jpg"]))
        let service = VineyardInsightsService(store: store)
        var draft = VintageNoteDraft()
        draft.notes = "Pending debounce"
        _ = service.saveNote(
            draft: draft, vineyardID: vineyardID, observedByUserID: nil,
            observerName: "Scout", seasonStartMonth: 7, seasonStartDay: 1
        )
        service.clearOnSignOut()
        try await Task.sleep(for: .milliseconds(800))
        #expect(store.loadLocalFileCleanup().isEmpty)
        #expect(store.loadNotes().isEmpty)
        #expect(service.notes.isEmpty)
    }

    @Test func singleFlightDoesNotOverlapAndRetainsOneFollowUp() async {
        let coordinator = VineyardInsightsSingleFlightCoordinator()
        let vineyardID = UUID()
        var passes = 0
        var active = 0
        var maximumActive = 0
        var release: CheckedContinuation<Void, Never>?

        let first = Task { @MainActor in
            await coordinator.request(vineyardID: vineyardID) {
                passes += 1
                active += 1
                maximumActive = max(maximumActive, active)
                if passes == 1 {
                    await withCheckedContinuation { continuation in release = continuation }
                }
                active -= 1
            }
        }
        while release == nil { await Task.yield() }
        await coordinator.request(vineyardID: vineyardID) { Issue.record("follow-up must reuse active pass") }
        release?.resume()
        await first.value
        #expect(passes == 2)
        #expect(maximumActive == 1)
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
