import Testing
import Foundation
@testable import VineTrack

/// Customisable Operational Tools (sql/159) — layout resolution and mutation
/// rules on iOS. Mirrors the Android `OperationalToolLayoutTest`.
@MainActor
struct OperationalToolLayoutTests {

    // MARK: - Fixtures

    /// In-memory stand-in for the Supabase RPCs so the rules can be tested
    /// without a network round trip.
    private final class FakePreferences: OperationalToolPreferencesProviding, @unchecked Sendable {
        var stored = OperationalToolPreferences.empty
        var shouldFail = false
        private(set) var saveCount = 0

        func fetch() async throws -> OperationalToolPreferences {
            if shouldFail { throw BackendRepositoryError.missingSupabaseConfiguration }
            return stored
        }

        func save(visibleToolIds: [String], hiddenToolIds: [String]) async throws -> OperationalToolPreferences {
            saveCount += 1
            if shouldFail { throw BackendRepositoryError.missingSupabaseConfiguration }
            stored = OperationalToolPreferences(
                hasPreference: true,
                version: 1,
                visibleToolIds: visibleToolIds,
                hiddenToolIds: hiddenToolIds,
                updatedAt: Date()
            )
            return stored
        }

        func reset() async throws -> OperationalToolPreferences {
            if shouldFail { throw BackendRepositoryError.missingSupabaseConfiguration }
            stored = .empty
            return stored
        }
    }

    private static let userId = UUID(uuidString: "b1c2d3e4-0000-4000-8000-00000000abcd")!

    private func makeStore(
        fake: FakePreferences = FakePreferences(),
        suite: String = UUID().uuidString
    ) -> OperationalToolLayoutStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return OperationalToolLayoutStore(repository: fake, defaults: defaults)
    }

    private var allTools: [OperationalTool] { OperationalToolCatalog.authorised(canViewCosting: true) }
    private var operatorTools: [OperationalTool] { OperationalToolCatalog.authorised(canViewCosting: false) }

    // MARK: - Catalogue

    @Test("Catalogue exposes the 12-tile grid with stable IDs")
    func catalogueMatchesGrid() {
        #expect(OperationalToolCatalog.all.count == 12)
        #expect(OperationalToolCatalog.defaultOrder.first == "work_tasks")
        #expect(OperationalToolCatalog.defaultOrder.last == "irrigation_records")
        // Stable, snake-case, unique.
        #expect(Set(OperationalToolCatalog.defaultOrder).count == 12)
        #expect(OperationalToolCatalog.tool(id: "cost_reports")?.requirement == .costing)
    }

    @Test("A restricted tool is absent from the authorised catalogue")
    func costingIsGated() {
        #expect(allTools.contains { $0.id == "cost_reports" })
        #expect(!operatorTools.contains { $0.id == "cost_reports" })
    }

    // MARK: - Default layout

    @Test("A new user sees every authorised tool in the default order")
    func newUserDefaults() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        #expect(store.isReady)
        #expect(store.visibleTools(authorised: allTools).map(\.id) == OperationalToolCatalog.defaultOrder)
        #expect(store.hiddenTools(authorised: allTools).isEmpty)
        #expect(!store.isCustomised)
    }

    @Test("An unauthorised tool never appears in either section")
    func unauthorisedToolHidden() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        let visible = store.visibleTools(authorised: operatorTools).map(\.id)
        let hidden = store.hiddenTools(authorised: operatorTools).map(\.id)
        #expect(!visible.contains("cost_reports"))
        #expect(!hidden.contains("cost_reports"))
        #expect(visible.count == 11)
    }

    // MARK: - Mutations

    @Test("Hiding a tool removes it from the grid and lists it as hidden")
    func hideTool() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        #expect(store.hide(toolId: "fuel_log", authorised: allTools))
        #expect(!store.visibleTools(authorised: allTools).map(\.id).contains("fuel_log"))
        #expect(store.hiddenTools(authorised: allTools).map(\.id) == ["fuel_log"])
    }

    @Test("The last visible tool cannot be hidden")
    func minimumVisibleEnforced() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        var remaining = OperationalToolCatalog.defaultOrder
        while remaining.count > 1 {
            let id = remaining.removeLast()
            #expect(store.hide(toolId: id, authorised: allTools))
        }
        let last = store.visibleTools(authorised: allTools)
        #expect(last.count == 1)
        #expect(store.hide(toolId: last[0].id, authorised: allTools) == false)
        #expect(store.visibleTools(authorised: allTools).count == 1)
    }

    @Test("Restoring a hidden tool appends it to the end")
    func restoreTool() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        #expect(store.hide(toolId: "work_tasks", authorised: allTools))
        store.show(toolId: "work_tasks", authorised: allTools)
        #expect(store.visibleTools(authorised: allTools).last?.id == "work_tasks")
        #expect(store.hiddenTools(authorised: allTools).isEmpty)
    }

    @Test("Reordering keeps every tool and only changes position")
    func reorderTool() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        store.move(from: IndexSet(integer: 11), to: 0, authorised: allTools)
        let visible = store.visibleTools(authorised: allTools).map(\.id)
        #expect(visible.first == "irrigation_records")
        #expect(Set(visible) == Set(OperationalToolCatalog.defaultOrder))
    }

    @Test("Reset restores the default order and shows every authorised tool")
    func resetLayout() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        #expect(store.hide(toolId: "fuel_log", authorised: allTools))
        store.resetToDefault()
        #expect(store.visibleTools(authorised: allTools).map(\.id) == OperationalToolCatalog.defaultOrder)
        #expect(!store.isCustomised)
    }

    // MARK: - Contract resilience

    @Test("A newly released tool is appended for a user with an older layout")
    func newToolAppended() async {
        let fake = FakePreferences()
        // Saved on an older build that never knew irrigation_records.
        fake.stored = OperationalToolPreferences(
            hasPreference: true,
            version: 1,
            visibleToolIds: OperationalToolCatalog.defaultOrder.filter { $0 != "irrigation_records" },
            hiddenToolIds: [],
            updatedAt: nil
        )
        let store = makeStore(fake: fake)
        store.configure(userId: Self.userId)
        await store.refreshFromServer(force: true)
        let visible = store.visibleTools(authorised: allTools).map(\.id)
        #expect(visible.last == "irrigation_records")
        #expect(visible.count == 12)
    }

    @Test("Unknown tool IDs in a saved layout are ignored")
    func unknownIdsIgnored() async {
        let fake = FakePreferences()
        fake.stored = OperationalToolPreferences(
            hasPreference: true,
            version: 1,
            visibleToolIds: ["seeder_records", "work_tasks", "not_a_tool"],
            hiddenToolIds: ["ghost_tool", "fuel_log"],
            updatedAt: nil
        )
        let store = makeStore(fake: fake)
        store.configure(userId: Self.userId)
        await store.refreshFromServer(force: true)
        let visible = store.visibleTools(authorised: allTools).map(\.id)
        #expect(visible.first == "work_tasks")
        #expect(!visible.contains("seeder_records"))
        #expect(store.hiddenTools(authorised: allTools).map(\.id) == ["fuel_log"])
    }

    @Test("A hidden tool the user loses access to is not offered under Hidden Tools")
    func restrictedHiddenToolNotOffered() async {
        let fake = FakePreferences()
        fake.stored = OperationalToolPreferences(
            hasPreference: true,
            version: 1,
            visibleToolIds: ["work_tasks"],
            hiddenToolIds: ["cost_reports"],
            updatedAt: nil
        )
        let store = makeStore(fake: fake)
        store.configure(userId: Self.userId)
        await store.refreshFromServer(force: true)
        #expect(store.hiddenTools(authorised: operatorTools).isEmpty)
        #expect(store.hiddenTools(authorised: allTools).map(\.id) == ["cost_reports"])
    }

    @Test("A failed save keeps the local layout and marks it for retry")
    func failedSaveKeepsLocalLayout() async {
        let fake = FakePreferences()
        fake.shouldFail = true
        let store = makeStore(fake: fake)
        store.configure(userId: Self.userId)
        #expect(store.hide(toolId: "fuel_log", authorised: allTools))
        // Let the background push run and fail.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!store.visibleTools(authorised: allTools).map(\.id).contains("fuel_log"))
        #expect(store.hasPendingSync)
        #expect(store.lastSyncErrorMessage == OperationalToolLayoutStore.offlineSaveMessage)
    }

    @Test("A server refresh failure keeps the cached layout")
    func failedRefreshKeepsCache() async {
        let fake = FakePreferences()
        let store = makeStore(fake: fake)
        store.configure(userId: Self.userId)
        #expect(store.hide(toolId: "fuel_log", authorised: allTools))
        try? await Task.sleep(for: .milliseconds(50))
        fake.shouldFail = true
        await store.refreshFromServer(force: true)
        #expect(store.hiddenTools(authorised: allTools).map(\.id) == ["fuel_log"])
    }

    @Test("Switching user isolates the layout")
    func layoutIsolatedPerUser() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        #expect(store.hide(toolId: "fuel_log", authorised: allTools))
        let other = UUID(uuidString: "c0ffee00-0000-4000-8000-00000000beef")!
        store.configure(userId: other)
        #expect(store.visibleTools(authorised: allTools).map(\.id) == OperationalToolCatalog.defaultOrder)
        #expect(store.hiddenTools(authorised: allTools).isEmpty)
    }

    @Test("Sign-out clears in-memory layout state")
    func signOutClearsState() {
        let store = makeStore()
        store.configure(userId: Self.userId)
        #expect(store.hide(toolId: "fuel_log", authorised: allTools))
        store.signOut()
        #expect(!store.isReady)
        #expect(!store.isCustomised)
    }
}
