#if DEBUG
import SwiftUI

/// Disposable fixtures exercise the shipping List and journal-first deletion.
/// No authentication, network, historical Trip or shared persistence is changed.
struct TripDeletionValidationView: View {
    @State private var store: MigratedDataStore
    @State private var access = BackendAccessControl()
    @State private var tracking = TripTrackingService()
    @State private var location = LocationService()
    @State private var publications = 0
    @State private var tripSync: TripSyncService

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trip-delete-validation-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let disk = PersistenceStore(directory: root)
        _tripSync = State(initialValue: TripSyncService(metadata: TripSyncMetadata(persistence: disk)))
        let store = MigratedDataStore(persistence: disk)
        let account = UUID(), vineyard = UUID()
        store.currentUserIdProvider = { account }
        store.selectedVineyardId = vineyard
        store.operationalWriteAuthority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: "trip-delete-validation-" + UUID().uuidString)!)
        store.operationalWriteAuthority.bind(userId: account)
        store.trips = [
            Trip(id: UUID(uuidString: "35000000-0000-4000-8000-000000000001")!, vineyardId: vineyard, paddockName: "Synthetic", startTime: Date(timeIntervalSince1970: 300), isActive: false, tripTitle: "Delete fixture"),
            Trip(id: UUID(uuidString: "35000000-0000-4000-8000-000000000002")!, vineyardId: vineyard, paddockName: "Synthetic", startTime: Date(timeIntervalSince1970: 200), isActive: false, tripTitle: "Keep fixture"),
            Trip(id: UUID(uuidString: "35000000-0000-4000-8000-000000000003")!, vineyardId: vineyard, paddockName: "Synthetic", startTime: Date(timeIntervalSince1970: 100), isActive: true, tripTitle: "Active fixture")
        ]
        try! store.tripRepo.saveSliceOrThrow(store.trips, for: vineyard)
        _store = State(initialValue: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Isolated deletion fixture").font(.caption)
            Text("Rows: \(store.trips.count) · Disk: \(store.tripRepo.loadAll().count) · Deletes: \(publications)")
                .accessibilityIdentifier("trip.delete.fixture.state")
            TripView(historyOnly: true)
        }
        .environment(store).environment(access).environment(tracking).environment(location).environment(tripSync)
        .onAppear {
            access.currentRole = .owner
            store.onTripDeleted = { _ in publications += 1 }
        }
    }
}
#endif
