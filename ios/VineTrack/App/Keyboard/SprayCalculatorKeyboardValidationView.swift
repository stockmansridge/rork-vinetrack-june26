#if DEBUG
import SwiftUI

/// Presents the production calculator with isolated local data, never a signed-in account.
struct SprayCalculatorKeyboardValidationView: View {
    @State private var store: MigratedDataStore = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spray-keyboard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        if CommandLine.arguments.contains("--spray-regional-validation") {
            let vineyard = UUID()
            store.selectedVineyardId = vineyard
            store.paddocks = [Paddock(vineyardId: vineyard, name: "Synthetic regional block", polygonPoints: [
                CoordinatePoint(latitude: -35, longitude: 149), CoordinatePoint(latitude: -35, longitude: 149.002),
                CoordinatePoint(latitude: -35.002, longitude: 149.002), CoordinatePoint(latitude: -35.002, longitude: 149)
            ], rows: [
                PaddockRow(number: 1, startPoint: CoordinatePoint(latitude: -35, longitude: 149), endPoint: CoordinatePoint(latitude: -35.001, longitude: 149)),
                PaddockRow(number: 2, startPoint: CoordinatePoint(latitude: -35, longitude: 149.00003), endPoint: CoordinatePoint(latitude: -35.001, longitude: 149.00003))
            ], rowWidth: 2.8)]
            store.sprayEquipment = [SprayEquipmentItem(vineyardId: vineyard, name: "Synthetic 1000 L unit", tankCapacityLitres: 1000)]
        } else {
            store.paddocks = [Paddock(name: "Regression block")]
        }
        return store
    }()
    @State private var canopyImages: CanopyReferenceImageRepository = CanopyReferenceImageRepository(
        baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("canopy-fixture-\(UUID().uuidString)"),
        remote: LocalCanopyImages())
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
                SprayCalculatorView.keyboardRegression(blockID: block.id, equipmentID: store.sprayEquipment.first?.id)
                    .environment(store)
                    .environment(tracking)
                    .environment(auth)
                    .environment(admin)
                    .environment(access)
                    .environment(location)
                    .environment(canopyImages)
            }
        }
    }
}

private struct LocalCanopyImages: CanopyReferenceImageRemote {
    func fetchConfiguration() async throws -> CanopyReferenceConfiguration {
        CanopyReferenceConfiguration(bucket: "fixture", configUpdatedAt: nil, images: [:])
    }
    func downloadImage(bucket: String, path: String) async throws -> Data { Data() }
}
#endif
