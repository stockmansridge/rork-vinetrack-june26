import Foundation
import Testing
@testable import VineTrack

@MainActor
struct PruningActivityTimingPreflightTests {
    @Test func missingBusinessDateAndInvalidTimingRejectBeforeMutation() throws {
        var draft = PruningActivityDraft(vineyardId: UUID())
        draft.businessDateUnavailable = true
        var writes = 0
        for _ in 0..<4 {
            do {
                _ = try PruningActivityTimingPreflight.prepare(draft, timezone: "Australia/Sydney")
                writes += 1
            } catch {
                #expect(error.localizedDescription.contains("Business date unavailable"))
            }
        }
        #expect(writes == 0)
        draft.businessDateUnavailable = false
        draft.startTime = Date(timeIntervalSince1970: 100)
        draft.finishTime = Date(timeIntervalSince1970: 99)
        #expect(throws: PruningActivityTimingPreflight.Failure.invalidTiming) {
            try PruningActivityTimingPreflight.prepare(draft, timezone: "Australia/Sydney")
        }
    }

    @Test func frozenBusinessDayAndExactInstantsSurviveCacheAndZoneChanges() throws {
        let start = Date(timeIntervalSince1970: 1772958900.125)
        let finish = start.addingTimeInterval(3600.375)
        var draft = PruningActivityDraft(vineyardId: UUID(), date: start, startTime: start, finishTime: finish)
        draft = try PruningActivityTimingPreflight.prepare(draft, timezone: "America/Los_Angeles")
        let day = try #require(draft.businessDateSnapshot)
        let restored = try JSONDecoder().decode(PruningActivityDraft.self, from: JSONEncoder().encode(draft))
        for zone in ["Australia/Sydney", "Pacific/Auckland", "America/Los_Angeles"] {
            let replay = try PruningActivityTimingPreflight.prepare(restored, timezone: zone)
            #expect(PruningActivityPayload(from: replay).entryDate == day)
            #expect(replay.startTime == start)
            #expect(replay.finishTime == finish)
        }
    }
}
