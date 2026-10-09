#if DEBUG
import SwiftUI

/// Presents the production calculator with isolated local data, never a signed-in account.
struct SprayCalculatorKeyboardValidationView: View {
    @State private var store: MigratedDataStore = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spray-keyboard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.paddocks = [Paddock(name: "Regression block")]
        return store
    }()
    @State private var tracking: TripTrackingService = TripTrackingService()
    @State private var auth: NewBackendAuthService = NewBackendAuthService()
    @State private var admin: SystemAdminService = SystemAdminService()
    @State private var access: BackendAccessControl = BackendAccessControl()
    @State private var location: LocationService = LocationService()
    @State private var showsCalculator: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Button("Open Spray Calculator") { showsCalculator = true }
            Text("Sprays: \(store.sprayRecords.count); Trips: \(store.trips.count)")
                .accessibilityIdentifier("spray.keyboard.records")
        }
        .sheet(isPresented: $showsCalculator) {
            if let block = store.paddocks.first {
                SprayCalculatorView.keyboardRegression(blockID: block.id)
                    .environment(store)
                    .environment(tracking)
                    .environment(auth)
                    .environment(admin)
                    .environment(access)
                    .environment(location)
            }
        }
    }
}
#endif
