#if DEBUG
import Foundation
import CoreLocation
import Darwin

nonisolated struct GPSFixMeasurement: Sendable {
    let appendMS: Double
    let guidanceMS: Double
    let persistenceAndDirtyMS: Double
    let publicationAndSpeedMS: Double
    let totalMS: Double
}

/// Isolated production GPS/store/sync wiring, NOT a live server or a Start Trip
/// acceptance fixture. The active maintenance Trip is explicitly seeded.
@MainActor
final class GPSPersistenceFixture {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
    let directory: URL
    let persistence: PersistenceStore
    let store: MigratedDataStore
    let metadata: TripSyncMetadata
    let transport = GPSProbeOfflineRepository()
    let sync: TripSyncService
    let auth = NewBackendAuthService()
    let tracking = TripTrackingService()
    let location = LocationService()
    let vineyard = UUID()
    let actor = UUID()
    private let defaultsName = "gps-probe-" + UUID().uuidString
    private(set) var gps: [GPSFixMeasurement] = []
    private(set) var storage: [PersistenceMeasurement] = []
    private(set) var injectedIDs: [UUID] = []
    private(set) var controls: [String] = []

    init(points: Int, compact: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gps-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        persistence = PersistenceStore(directory: directory)
        persistence.compactTripEncodingForTesting = compact
        // Representative retained queue, not a statement of customer volume.
        var state = TripSyncMetadata.State()
        for _ in 0..<500 { state.pendingUpserts[UUID()] = Date(timeIntervalSince1970: 1_700_000_000) }
        try persistence.saveOrThrow(state, key: "vinetrack_trip_sync_metadata")
        metadata = TripSyncMetadata(persistence: persistence)
        sync = TripSyncService(repository: transport, metadata: metadata)
        store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        let owner = actor
        store.currentUserIdProvider = { owner }
        auth.userId = actor; auth.isSignedIn = true
        let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: defaultsName)!)
        authority.bind(userId: actor)
        store.operationalWriteAuthority = authority
        let block = Paddock(vineyardId: vineyard, name: "Synthetic 200 rows", polygonPoints: [
            CoordinatePoint(latitude: -35.002, longitude: 149), CoordinatePoint(latitude: -35.002, longitude: 149.01),
            CoordinatePoint(latitude: -34.998, longitude: 149.01), CoordinatePoint(latitude: -34.998, longitude: 149)
        ], rows: (1...200).map { row in
            let lon = 149.0001 + Double(row) * 0.00004
            return PaddockRow(number: row, startPoint: CoordinatePoint(latitude: -35.001, longitude: lon),
                              endPoint: CoordinatePoint(latitude: -34.999, longitude: lon))
        }, rowWidth: 2.8)
        store.paddocks = [block]
        store.settings.rowTrackingEnabled = true
        // Configure before claiming: no real location/timer loop is started by
        // setup. All measured fixes explicitly call the production entry point.
        tracking.configure(store: store, locationService: location)
        sync.configure(store: store, auth: auth) // installs the REAL dirty hook
        let trip = Trip(vineyardId: vineyard, paddockId: block.id, paddockIds: [block.id],
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            pathPoints: (0..<points).map { CoordinatePoint(latitude: -35 + Double($0 % 100) * 0.000001,
                                                         longitude: 149.0041) }, isActive: true)
        store.startTrip(trip)
        store.claimDeviceTrip(trip.id)
        tracking.onGPSMeasurementForTesting = { [weak self] in
            guard let self, self.gps.count < 4_096 else { return }; self.gps.append($0)
        }
        tracking.onControlMeasurementForTesting = { [weak self] name, milliseconds in
            guard let self, self.controls.count < 16 else { return }
            self.controls.append("\(name) service=\(String(format: "%.2f", milliseconds))ms syncInFlight=\(self.transport.inFlight) priorGPS=\(self.gps.count)")
        }
        persistence.onPersistenceMeasurementForTesting = { [weak self] in
            guard let self, self.storage.count < 32_768 else { return }; self.storage.append($0)
        }
    }

    func append(_ index: Int) {
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: -35 + Double(index % 100) * 0.000001,
            longitude: 149.0041), altitude: 0, horizontalAccuracy: 2, verticalAccuracy: 2,
            timestamp: Date())
        tracking.processLocation(fix, force: true)
        if let last = store.deviceOwnedTrip?.pathPoints.last, injectedIDs.last != last.id { injectedIDs.append(last.id) }
    }

    func verify() -> Bool {
        guard let live = store.deviceOwnedTrip,
              let disk = TripRepository(persistence: PersistenceStore(directory: directory)).loadAll().first(where: { $0.id == live.id }) else { return false }
        let ids = Set(disk.pathPoints.map(\.id))
        // The existing ISO8601 disk schema stores whole-second dates. Compare
        // that established representation, and separately demand exact GPS IDs,
        // order and Double precision; do not mistake date truncation for loss.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let bytes = try? encoder.encode(live), let normalized = try? decoder.decode(Trip.self, from: bytes) else { return false }
        return disk == normalized && disk.pathPoints == live.pathPoints
            && Set(injectedIDs).count == injectedIDs.count && injectedIDs.allSatisfy { ids.contains($0) }
            && metadata.pendingUpserts.count >= 501
    }

    /// Stop only this isolated fixture's ordinary tracking loops at the probe
    /// boundary. Suppress measurement hooks BEFORE the automatic pause so it
    /// cannot masquerade as a real user button or extend the measured sample.
    func stopProbeTracking() {
        persistence.onPersistenceMeasurementForTesting = nil
        tracking.onGPSMeasurementForTesting = nil
        tracking.onControlMeasurementForTesting = nil
        tracking.pauseTrip()
        location.stopUpdating()
    }

    func cleanup() {
        stopProbeTracking()
        if let id = store.deviceActiveTripId { SyncIssueCenter.shared.clearIssues([id]) }
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }

    static func percentile(_ values: [Double], _ fraction: Double = 0.5) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    static func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    var summary: String {
        func ms(_ values: [Double]) -> String { String(format: "%.2f", Self.percentile(values)) }
        let tripWrites = storage.filter { $0.dataset == .trips && $0.operation != .read }
        let reads = storage.filter { $0.dataset == .trips && $0.operation == .read }
        let metadataWrites = storage.filter { $0.dataset == .metadata && $0.operation != .read }
        return "n=\(gps.count); GPS median/p95=\(ms(gps.map(\.totalMS)))/\(String(format: "%.2f", Self.percentile(gps.map(\.totalMS), 0.95)))ms\n"
            + "append=\(ms(gps.map(\.appendMS))) guidance=\(ms(gps.map(\.guidanceMS))) publish/speed=\(ms(gps.map(\.publicationAndSpeedMS)))ms\n"
            + "Trip read=\(ms(reads.map(\.mainMilliseconds))) encode=\(ms(tripWrites.map(\.codecMilliseconds))) write=\(ms(tripWrites.map(\.writeMilliseconds)))ms\n"
            + "dirty metadata=\(ms(metadataWrites.map(\.mainMilliseconds)))ms; bytes=\(tripWrites.last?.bytes ?? 0)"
    }
}

/// An explicit offline transport with an awaited delay. It cannot ACK anything,
/// contact Supabase or mutate server state. Production sync admission/retries run.
@MainActor
final class GPSProbeOfflineRepository: TripSyncRepositoryProtocol {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
    var delayMilliseconds: Int = 120
    private(set) var attempts = 0
    private(set) var inFlight = 0
    func upsertTrips(_ trips: [BackendTripUpsert]) async throws {
        attempts += 1; inFlight += 1
        defer { inFlight -= 1 }
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        throw URLError(.notConnectedToInternet)
    }
    func upsertTrip(_ trip: BackendTripUpsert) async throws { try await upsertTrips([trip]) }
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { throw URLError(.notConnectedToInternet) }
    // Explicit simulated empty preflight, so the production upload stage is
    // reached. No server row or successful-upload receipt is being fabricated.
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { throw URLError(.notConnectedToInternet) }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws { throw URLError(.notConnectedToInternet) }
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws { throw URLError(.notConnectedToInternet) }
    func softDeleteTrip(id: UUID) async throws { throw URLError(.notConnectedToInternet) }
}
#endif
