import Foundation
import Testing
@testable import VineTrack

@MainActor
struct ChemicalInventorySummaryTests {
    @Test func archiveEvictsTotalsAndReloadNeverRequestsHistoricalRows() async {
        let vineyard = UUID()
        let active = SavedChemical(vineyardId: vineyard, name: "Active")
        var archived = SavedChemical(vineyardId: vineyard, name: "Historical")
        var requests: [UUID] = []
        let cache = ChemicalInventorySummaryState { id in
            requests.append(id)
            return CatalogueWire(fields: ["tracked": .bool(true), "estimated_stock_value": .number(25)])
        }
        cache.update(scope: "account|vineyard|owner", chemicals: [active, archived])
        await cache.waitForRefresh()
        #expect(cache.summaries.values.reduce(0) { $0 + ($1.number("estimated_stock_value") ?? 0) } == 50)
        archived.isActive = false
        cache.update(scope: "account|vineyard|owner", chemicals: [active, archived])
        await cache.waitForRefresh()
        #expect(Set(cache.summaries.keys) == [active.id])
        #expect(requests.count == 2)
        #expect(cache.summaries.values.reduce(0) { $0 + ($1.number("estimated_stock_value") ?? 0) } == 25)
        let restarted = ChemicalInventorySummaryState { id in
            #expect(id == active.id)
            return CatalogueWire(fields: ["tracked": .bool(true)])
        }
        let restored = try? JSONDecoder().decode([SavedChemical].self, from: JSONEncoder().encode([active, archived]))
        restarted.update(scope: "account|vineyard|owner", chemicals: restored ?? [])
        await restarted.waitForRefresh()
        #expect(Set(restarted.summaries.keys) == [active.id])
        #expect(archived.name == "Historical")
    }

    @Test func onlyChangedSummaryReloadsAndExplicitMutationInvalidatesOne() async {
        let first = SavedChemical(name: "One"), second = SavedChemical(name: "Two")
        var requests: [UUID] = []
        let cache = ChemicalInventorySummaryState { id in requests.append(id); return CatalogueWire(fields: [:]) }
        cache.update(scope: "A", chemicals: [first, second]); await cache.waitForRefresh()
        cache.update(scope: "A", chemicals: [first, second]); await cache.waitForRefresh()
        #expect(requests.count == 2)
        var changed = first; changed.notes = "Edited"
        cache.update(scope: "A", chemicals: [changed, second]); await cache.waitForRefresh()
        #expect(requests.filter { $0 == first.id }.count == 2)
        #expect(requests.filter { $0 == second.id }.count == 1)
        cache.update(scope: "A", chemicals: [changed, second], force: [second.id]); await cache.waitForRefresh()
        #expect(requests.count == 4)
    }

    @Test func oldScopeAndOldMutationResponsesCannotPublishAndRequestsAreSerialized() async {
        let chemical = SavedChemical(name: "One")
        var cache: ChemicalInventorySummaryState?
        var requests = 0, active = 0, maximum = 0
        let state = ChemicalInventorySummaryState { _ in
            requests += 1; active += 1; maximum = max(maximum, active)
            defer { active -= 1 }
            if requests == 1 { cache?.update(scope: "B", chemicals: [chemical]) }
            if requests == 2 { cache?.update(scope: "B", chemicals: [chemical], force: [chemical.id]) }
            return CatalogueWire(fields: ["estimated_stock_value": .number(Double(requests))])
        }
        cache = state
        state.update(scope: "A", chemicals: [chemical]); await state.waitForRefresh()
        #expect(requests == 3 && maximum == 1)
        #expect(state.values(for: "A").isEmpty)
        #expect(state.values(for: "B")[chemical.id]?.number("estimated_stock_value") == 3)
        state.update(scope: nil, chemicals: [])
        #expect(state.summaries.isEmpty)
        cache = nil
    }

    @Test func offlineFailureRetainsUnchangedRowsAndPermissionChangeClearsCache() async {
        let chemical = SavedChemical(name: "One")
        var fail = false
        let state = ChemicalInventorySummaryState { _ in
            if fail { throw URLError(.notConnectedToInternet) }
            return CatalogueWire(fields: ["tracked": .bool(true)])
        }
        state.update(scope: "owner", chemicals: [chemical]); await state.waitForRefresh()
        fail = true
        state.update(scope: "owner", chemicals: [chemical]); await state.waitForRefresh()
        #expect(state.summaries.count == 1)
        state.update(scope: "operator", chemicals: [chemical])
        #expect(state.values(for: "owner").isEmpty)
        await state.waitForRefresh()
        #expect(state.summaries.isEmpty && state.error != nil)
        fail = false; state.retry(); await state.waitForRefresh()
        #expect(state.summaries.count == 1 && state.error == nil)
    }
}
