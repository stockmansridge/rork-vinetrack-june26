#if DEBUG
import SwiftUI

/// Test-only production workflow with disposable local storage and no shared-default/master transport.
struct YieldTripValidationView: View {
    private static let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let block = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private static let trip = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    @State private var store: MigratedDataStore
    @State private var network = NetworkMonitor()
    @State private var systemAdmin = SystemAdminService()
    private static let fixtureStore = makeStore()
    init() { _store = State(initialValue: Self.fixtureStore) }
    private static func makeStore() -> MigratedDataStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yield-trip-validation", isDirectory: true)
        if CommandLine.arguments.contains("--reset-yield-trip") { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        store.selectedVineyardId = Self.vineyard
        let d = 100.0 / 111320
        store.paddocks = [Paddock(id: Self.block, vineyardId: Self.vineyard, name: "Synthetic Yield Block",
            polygonPoints: [CoordinatePoint(latitude: 0, longitude: 0), CoordinatePoint(latitude: d, longitude: 0), CoordinatePoint(latitude: d, longitude: d), CoordinatePoint(latitude: 0, longitude: d)],
            vineCountOverride: 1000,
            varietyAllocations: [PaddockVarietyAllocation(varietyId: Self.vineyard, percent: 100, name: "Shiraz", varietyKey: "shiraz")])]
        store.yieldSessions = store.yieldRepo.loadSessions(for: Self.vineyard)
        if store.yieldSessions.isEmpty {
            let draft = YieldEstimationSession(id: Self.trip, vineyardId: Self.vineyard, createdAt: Date(), selectedPaddockIds: [Self.block],
                sampleSites: [SampleSite(paddockId: Self.block, rowNumber: 1, latitude: d / 2, longitude: d / 2, siteIndex: 1,
                    bunchCountEntry: BunchCountEntry(bunchesPerVine: 20))], blockBunchWeightsKg: [Self.block: 0.15])
            _ = store.saveYieldSession(draft)
        }
        return store
    }
    var body: some View {
        NavigationStack { YieldEstimationView(refreshSharedDefaults: false) }
            .environment(store)
            .environment(network)
            .environment(systemAdmin)
    }
}
#endif
