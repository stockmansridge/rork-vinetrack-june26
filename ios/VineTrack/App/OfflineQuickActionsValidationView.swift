#if DEBUG
import SwiftUI
import CoreLocation

/// Isolated UI fixture: production role cache and durable pin stores, no live auth or transport.
struct OfflineQuickActionsValidationView: View {
    private static let actor = UUID(uuidString: "d1100000-0000-4000-8000-000000000001")!
    private static let a = UUID(uuidString: "d1100000-0000-4000-8000-000000000002")!
    private static let b = UUID(uuidString: "d1100000-0000-4000-8000-000000000003")!
    @State private var auth: NewBackendAuthService
    @State private var access: BackendAccessControl
    @State private var store: MigratedDataStore
    @State private var selected: UUID = Self.a
    @State private var count: Int = 0
    @State private var error: String?
    private let persistence: PersistenceStore
    private let metadata: PinSyncMetadata

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offline-quick-actions-validation", isDirectory: true)
        if CommandLine.arguments.contains("--reset-offline-quick-actions") { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: root)
        self.persistence = persistence
        let auth = NewBackendAuthService()
        auth.userId = Self.actor; auth.isSignedIn = true
        let cache = VerifiedVineyardRoleCache(persistence: persistence)
        let seeded: Bool = persistence.load(key: "seeded") ?? false
        if !seeded {
            for vineyard in [Self.a, Self.b] {
                if let session = auth.legacySprayScope(vineyard: vineyard)?.session {
                    try? cache.save(.init(userId: Self.actor, vineyardId: vineyard, sessionId: session,
                                         role: vineyard == Self.a ? .operator : .supervisor, workerTypeId: nil))
                }
            }
            try? persistence.saveOrThrow(true, key: "seeded")
        }
        let store = MigratedDataStore(persistence: persistence)
        let metadata = PinSyncMetadata(persistence: persistence)
        self.metadata = metadata
        store.currentUserIdProvider = { Self.actor }
        store.onPinCreateWillPersist = { id, date in try metadata.markDirtyDurably(id, at: date) }
        _auth = State(initialValue: auth)
        _store = State(initialValue: store)
        _access = State(initialValue: BackendAccessControl(roleCache: cache, membershipRead: { _ in throw URLError(.notConnectedToInternet) }))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Offline acceptance fixture").font(.headline)
                Text(selected == Self.a ? "Vineyard A" : "Vineyard B").accessibilityIdentifier("offline.vineyard")
                Button("Switch vineyard") { selected = selected == Self.a ? Self.b : Self.a }
                if access.canCreateOperationalRecords {
                    Text("Quick Actions")
                    Button("Repairs") { save(.repairs) }
                    Button("Growth") { save(.growth) }
                    Button("Add Pin") { save(.repairs) }
                }
                Text("Pending pins: \(count)").accessibilityIdentifier("offline.pins")
                if let error { Text(error) }
            }
            .buttonStyle(.bordered)
            .padding()
            .task(id: selected) {
                store.selectedVineyardId = selected
                store.reloadCurrentVineyardData()
                count = store.pins.count
                await access.refresh(for: selected, auth: auth)
            }
        }
    }

    private func save(_ mode: PinMode) {
        let button = ButtonConfig(vineyardId: selected, name: "Offline test", color: "red", index: 0, mode: mode)
        if store.createPinFromButton(button: button, coordinate: CLLocationCoordinate2D(latitude: -34, longitude: 138),
            heading: nil, createdByUserId: Self.actor, notes: "Synthetic manual placement", locationScope: "point") == nil {
            error = "Local pin save failed"
        }
        count = store.pins.count
    }
}
#endif
