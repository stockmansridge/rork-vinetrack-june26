import Foundation
import Testing
@testable import VineTrack

/// SHARED SEASON-ASSIGNMENT FIXTURE — the same cases exist as
/// `PruningSeasonAssignmentTest.kt` in the Android unit-test source set, and
/// as T3–T12 of `sql/tests/161_pruning_season_canonical_tests.sql`.
///
/// Canonical rule under test (sql/161):
///   * pruning season year = calendar year of the ENTRY DATE (the year the
///     winter pruning happened) — never the vintage, never the device clock,
///   * vintage year        = the season-start resolver (sql/119), unchanged,
///   * so 2 Aug 2026 → "2026 Winter Pruning · Vintage 2027".
struct PruningSeasonAssignmentTests {

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    private static let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let blockId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let otherBlockId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private func makeStore() -> PruningStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pruning-season-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PruningStore(persistence: PersistenceStore(directory: directory))
    }

    // MARK: The rule itself

    @Test("August 2026 work is season 2026 — the year of the work, not the vintage")
    func augustSeasonYear() {
        let day = Self.date(2026, 8, 2)
        #expect(PruningSeasonId.seasonYear(for: day, calendar: Self.calendar) == 2026)
        // The costing vintage for a 1 July season start is the NEXT year — the
        // two values must never be conflated.
        let vintage = VintageResolver.vintageYear(
            for: day, seasonStartMonth: 7, seasonStartDay: 1, calendar: Self.calendar
        )
        #expect(vintage == 2027)
    }

    @Test("December 2026 work is still season 2026")
    func decemberSeasonYear() {
        #expect(PruningSeasonId.seasonYear(for: Self.date(2026, 12, 31), calendar: Self.calendar) == 2026)
        #expect(PruningSeasonId.seasonYear(for: Self.date(2027, 1, 1), calendar: Self.calendar) == 2027)
    }

    @Test("A season id is derived from the entry date, not from today")
    func entryDefaultsToItsOwnSeason() {
        let entry = PruningEntry(vineyardId: Self.vineyardId, paddockId: Self.blockId, date: Self.date(2026, 8, 2))
        let expected = PruningSeasonId.make(
            vineyardId: Self.vineyardId, paddockId: Self.blockId, seasonYear: 2026
        )
        #expect(entry.seasonId == expected)
    }

    @Test("A backdated entry keeps the season of the work, not of the device clock")
    func backdatedEntryKeepsWorkSeason() {
        // Recorded in 2027 for work done on 31 Dec 2026 (the old iOS rule sent
        // the device's current year and filed this under 2027).
        let entry = PruningEntry(vineyardId: Self.vineyardId, paddockId: Self.blockId, date: Self.date(2026, 12, 31))
        #expect(entry.seasonId == PruningSeasonId.make(
            vineyardId: Self.vineyardId, paddockId: Self.blockId, seasonYear: 2026
        ))
        let params = RecordPruningEntryParams(from: entry, clientUpdatedAt: Self.date(2027, 1, 4))
        #expect(params.seasonYear == 2026)
        #expect(params.entryDate == "2026-12-31")
    }

    @Test("The RPC payload always carries the entry-date year")
    func rpcPayloadUsesEntryDateYear() {
        let entry = PruningEntry(vineyardId: Self.vineyardId, paddockId: Self.blockId, date: Self.date(2026, 8, 2))
        let params = RecordPruningEntryParams(from: entry, clientUpdatedAt: Date())
        #expect(params.seasonYear == 2026)
    }

    @Test("Two blocks recorded on the same day resolve to the same season year")
    func sameDayBlocksShareTheSeasonYear() {
        let day = Self.date(2026, 8, 2)
        let a = PruningEntry(vineyardId: Self.vineyardId, paddockId: Self.blockId, date: day)
        let b = PruningEntry(vineyardId: Self.vineyardId, paddockId: Self.otherBlockId, date: day)
        #expect(RecordPruningEntryParams(from: a, clientUpdatedAt: day).seasonYear
                == RecordPruningEntryParams(from: b, clientUpdatedAt: day).seasonYear)
        #expect(a.seasonId != b.seasonId) // different blocks, same year
    }

    // MARK: Season selection in the store

    @Test("A stray next-year season row never hijacks the current season")
    func futureSeasonRowIsNotSelected() {
        let store = makeStore()
        let current = PruningBlockSetup(
            vineyardId: Self.vineyardId, paddockId: Self.blockId,
            seasonYear: PruningSeasonId.currentSeasonYear
        )
        let future = PruningBlockSetup(
            vineyardId: Self.vineyardId, paddockId: Self.blockId,
            seasonYear: PruningSeasonId.currentSeasonYear + 1
        )
        // Insert the FUTURE row first — the old `max(seasonYear)` rule picked it.
        store.applyRemoteSeasonUpsert(future)
        store.applyRemoteSeasonUpsert(current)
        #expect(store.setup(for: Self.blockId)?.id == current.id)
    }

    @Test("Season selection falls back to the most recent PAST season")
    func fallsBackToPreviousSeason() {
        let store = makeStore()
        let past = PruningBlockSetup(
            vineyardId: Self.vineyardId, paddockId: Self.blockId,
            seasonYear: PruningSeasonId.currentSeasonYear - 1
        )
        store.applyRemoteSeasonUpsert(past)
        #expect(store.setup(for: Self.blockId)?.id == past.id)
        #expect(store.setup(for: Self.blockId, seasonYear: PruningSeasonId.currentSeasonYear)?.id == past.id)
    }

    @Test("Recording looks up the season of the entry date only")
    func setupLookupByEntryDate() {
        let store = makeStore()
        let s2026 = PruningBlockSetup(vineyardId: Self.vineyardId, paddockId: Self.blockId, seasonYear: 2026)
        let s2027 = PruningBlockSetup(vineyardId: Self.vineyardId, paddockId: Self.blockId, seasonYear: 2027)
        store.applyRemoteSeasonUpsert(s2026)
        store.applyRemoteSeasonUpsert(s2027)
        #expect(store.setup(for: Self.blockId, on: Self.date(2026, 8, 2))?.id == s2026.id)
        #expect(store.setup(for: Self.blockId, on: Self.date(2027, 1, 4))?.id == s2027.id)
        #expect(store.setup(for: Self.blockId, on: Self.date(2025, 8, 2)) == nil)
    }

    // MARK: Adopting the server's canonical season

    @Test("The server's canonical season is adopted without re-queuing a push")
    func adoptsServerSeason() {
        let store = makeStore()
        var recorded = false
        store.onEntryRecorded = { _ in recorded = true }
        let entry = PruningEntry(vineyardId: Self.vineyardId, paddockId: Self.blockId, date: Self.date(2026, 8, 2))
        store.addEntry(entry)
        recorded = false

        let canonical = PruningSeasonId.make(vineyardId: Self.vineyardId, paddockId: Self.blockId, seasonYear: 2026)
        store.adoptServerSeason(entryId: entry.id, seasonId: canonical)
        #expect(store.entries.first(where: { $0.id == entry.id })?.seasonId == canonical)
        #expect(recorded == false)
    }

    @Test("Adopting a different season id converges the local cache")
    func adoptsCorrectedSeason() {
        let store = makeStore()
        let wrongSeason = PruningSeasonId.make(
            vineyardId: Self.vineyardId, paddockId: Self.blockId, seasonYear: 2027
        )
        let entry = PruningEntry(
            vineyardId: Self.vineyardId, paddockId: Self.blockId,
            seasonId: wrongSeason, date: Self.date(2026, 8, 2)
        )
        store.addEntry(entry)
        let canonical = PruningSeasonId.make(
            vineyardId: Self.vineyardId, paddockId: Self.blockId, seasonYear: 2026
        )
        store.adoptServerSeason(entryId: entry.id, seasonId: canonical)
        #expect(store.entries.first(where: { $0.id == entry.id })?.seasonId == canonical)
    }

    // MARK: RPC response contract

    @Test("record_pruning_entry response decodes the canonical season fields")
    func decodesRecordResult() throws {
        let json = """
        {
          "entry_id": "44444444-4444-4444-8444-444444444444",
          "season_id": "55555555-5555-4555-8555-555555555555",
          "season_year": 2026,
          "season_year_requested": 2027,
          "season_corrected": true,
          "season_mismatch": false,
          "vintage_year": 2027,
          "requested": 2,
          "attributed": 2,
          "deleted": false,
          "an_unexpected_future_field": "ignored"
        }
        """
        let result = try JSONDecoder().decode(RecordPruningEntryResult.self, from: Data(json.utf8))
        #expect(result.seasonYear == 2026)
        #expect(result.seasonYearRequested == 2027)
        #expect(result.seasonCorrected == true)
        #expect(result.vintageYear == 2027)
        #expect(result.seasonId?.uuidString.lowercased() == "55555555-5555-4555-8555-555555555555")
    }

    @Test("A minimal response (older server) still decodes")
    func decodesMinimalRecordResult() throws {
        let json = #"{"entry_id":"44444444-4444-4444-8444-444444444444","requested":1,"attributed":1,"deleted":false}"#
        let result = try JSONDecoder().decode(RecordPruningEntryResult.self, from: Data(json.utf8))
        #expect(result.seasonId == nil)
        #expect(result.seasonYear == nil)
        #expect(result.attributed == 1)
    }

    // MARK: Display label

    @Test("The dashboard label pairs the season year with the vintage")
    func seasonVintageLabel() {
        let day = Self.date(2026, 8, 2)
        let season = PruningSeasonId.seasonYear(for: day, calendar: Self.calendar)
        let vintage = VintageResolver.vintageYear(
            for: day, seasonStartMonth: 7, seasonStartDay: 1, calendar: Self.calendar
        )
        #expect("\(String(season)) Winter Pruning · Vintage \(String(vintage))"
                == "2026 Winter Pruning · Vintage 2027")
    }
}
