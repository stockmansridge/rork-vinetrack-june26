#if DEBUG
import Foundation
import SwiftUI
import CryptoKit

/// Explicit opt-in, process-wide sandbox. Release builds contain none of this code.
/// A run UUID preserves this sandbox across terminate/relaunch without deleting any data.
enum SprayLifecycleSandbox {
    nonisolated static var runID: UUID? {
        let args = CommandLine.arguments
        guard args.contains("--spray-lifecycle-validation"),
              let index = args.firstIndex(of: "--spray-lifecycle-run"), index + 1 < args.count,
              let id = UUID(uuidString: args[index + 1]) else { return nil }
        return id
    }
    nonisolated static var directory: URL? {
        runID.map { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SprayLifecycleSandbox", isDirectory: true)
            .appendingPathComponent($0.uuidString, isDirectory: true) }
    }
    static let actor = UUID(uuidString: "99000000-0000-4000-8000-000000000001")!
    static let vineyard = UUID(uuidString: "99000000-0000-4000-8000-000000000002")!
    static let session = UUID(uuidString: "99000000-0000-4000-8000-000000000003")!
}

/// Uses real receipt validation; only the remote boundary is simulated.
@MainActor @Observable
final class SprayLifecycleServer {
    struct Snapshot: Codable {
        var requests: [String: Data] = [:]
        var trips: [Trip] = []
        var sprays: [SprayRecord] = []
        var actuals: [SprayTankActual] = []
        var tripReads = 0
        var sprayReads = 0
    }
    let persistence: PersistenceStore
    var error: String?
    var revision = 0
    init() {
        let root = SprayLifecycleSandbox.directory!.appendingPathComponent("server", isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { fatalError("Cannot create isolated server storage: \(error)") }
        persistence = PersistenceStore(directory: root)
    }
    func load() -> Snapshot { persistence.load(key: "server") ?? Snapshot() }
    func save(_ state: Snapshot) throws { try persistence.saveOrThrow(state, key: "server"); revision += 1 }

    func receipt(rpc: String, body: Data) async throws -> Data {
        guard ["save_legacy_spray_pair_v1", "recover_legacy_spray_pair_v1"].contains(rpc),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let operation = object["p_operation_id"] as? String,
              let trip = object["p_trip"] as? [String: Any], let record = object["p_record"] as? [String: Any],
              trip["created_by"] as? String == SprayLifecycleSandbox.actor.uuidString.lowercased(),
              trip["vineyard_id"] as? String == SprayLifecycleSandbox.vineyard.uuidString.lowercased(),
              record["trip_id"] as? String == trip["id"] as? String else { throw LegacySprayPairReceipt.failure }
        var state = load()
        if rpc == "save_legacy_spray_pair_v1", state.requests[operation] == nil {
            state.requests[operation] = body; try save(state)
        }
        guard state.requests[operation] == body else { throw LegacySprayPairReceipt.failure }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "status": "accepted",
            "operation_id": operation, "vineyard_id": trip["vineyard_id"]!, "trip_id": trip["id"]!,
            "spray_record_id": record["id"]!,
            "request_sha256": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
            "committed_at": ISO8601DateFormatter().string(from: Date())])
    }

    /// Simulated remote persistence followed by the production durable completion replay.
    /// This is NOT a Supabase sync or a replacement for live-backend verification.
    func synchronize(store: MigratedDataStore) async {
        guard let trip = store.trips.first, !trip.isActive, trip.endTime != nil else { return }
        do {
            let actuals = SprayTankActualStore.shared.records.filter { $0.tripId == trip.id }
            guard trip.tankSessions.count == 2, trip.tankSessions.allSatisfy({ $0.endTime != nil }),
                  actuals.count == 2, let spray = store.sprayRecords.first(where: { $0.canonicalTripId == trip.id }) else {
                throw SprayPlanningAdmissionError(message: "Sandbox refuses completion: tank sessions or actuals are incomplete")
            }
            var state = load(); state.trips = [trip]; state.actuals = actuals
            if state.sprays.isEmpty { state.sprays = [spray] }
            try save(state)
            await TrackedSprayCompletionSync.shared.replay(ownerId: SprayLifecycleSandbox.actor,
                vineyardId: SprayLifecycleSandbox.vineyard,
                isCurrent: { store.currentUserIdProvider?() == SprayLifecycleSandbox.actor && store.selectedVineyardId == SprayLifecycleSandbox.vineyard },
                fetchTrip: { id in
                    var snapshot = self.load(); snapshot.tripReads += 1; try self.save(snapshot)
                    return snapshot.trips.first { $0.id == id }
                }, fetchSprays: { id in
                    var snapshot = self.load(); snapshot.sprayReads += 1; try self.save(snapshot)
                    return snapshot.sprays.filter { $0.canonicalTripId == id }
                }, dependenciesReady: { remote in
                    let snapshot = self.load()
                    return remote.tankSessions.allSatisfy { session in
                        session.endTime != nil && snapshot.actuals.contains { $0.tankSessionId == session.id.uuidString.lowercased() || $0.tankSessionId == session.id.uuidString }
                    }
                }, expectedSprayIds: { _ in [spray.id] }, complete: { id in
                    var snapshot = self.load()
                    guard let index = snapshot.sprays.firstIndex(where: { $0.id == id }), let end = trip.endTime else { throw TrackedSprayCompletionSync.Failure.held }
                    snapshot.sprays[index].endTime = end; try self.save(snapshot)
                    return SprayCompletionResponse(sprayRecordId: id, endTime: end, completionSource: "trip_end", serverConfirmed: true,
                        updatedAt: end, updatedBy: SprayLifecycleSandbox.actor, clientUpdatedAt: end, syncVersion: 2)
                }, onVerified: { verified in
                    if !store.updateSprayRecord(verified) { self.error = "Verified sandbox completion could not be saved locally" }
                })
            if try !TrackedSprayCompletionSync.shared.hasAcknowledgedCompletion(tripId: trip.id, sprayRecordId: spray.id,
                ownerId: SprayLifecycleSandbox.actor, vineyardId: SprayLifecycleSandbox.vineyard) {
                throw TrackedSprayCompletionSync.Failure.held
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct SprayLifecycleValidationView: View {
    @State private var store: MigratedDataStore
    @State private var auth = NewBackendAuthService()
    @State private var tracking = TripTrackingService()
    @State private var location = LocationService()
    @State private var access = BackendAccessControl()
    @State private var admin = SystemAdminService()
    @State private var server = SprayLifecycleServer()
    @State private var tripSync = TripSyncService()
    @State private var spraySync = SprayRecordSyncService()
    @State private var canopy = CanopyReferenceImageRepository(baseDirectory: SprayLifecycleSandbox.directory!.appendingPathComponent("canopy"), remote: LifecycleCanopyImages())
    @State private var showsCalculator = false
    @State private var ready = false

    init() {
        let store = MigratedDataStore()
        store.currentUserIdProvider = { SprayLifecycleSandbox.actor }
        store.currentUserNameProvider = { "Isolated operator" }
        store.legacySprayScopeProvider = { .init(actor: SprayLifecycleSandbox.actor, session: SprayLifecycleSandbox.session, vineyard: SprayLifecycleSandbox.vineyard) }
        store.load()
        store.selectedVineyardId = SprayLifecycleSandbox.vineyard
        store.reloadCurrentVineyardData()
        // Seed only planning inputs. Never seed an active Trip, tank or completed Spray.
        let block = Paddock(vineyardId: SprayLifecycleSandbox.vineyard, name: "Isolated lifecycle block", polygonPoints: [
            CoordinatePoint(latitude: -35, longitude: 149), CoordinatePoint(latitude: -35, longitude: 149.002),
            CoordinatePoint(latitude: -35.002, longitude: 149.002), CoordinatePoint(latitude: -35.002, longitude: 149)
        ], rows: [], rowWidth: 2.8)
        store.paddocks = [block]
        store.sprayEquipment = [SprayEquipmentItem(vineyardId: SprayLifecycleSandbox.vineyard, name: "Isolated 500 L unit", tankCapacityLitres: 500)]
        store.savedChemicals = [SavedChemical(vineyardId: SprayLifecycleSandbox.vineyard, name: "Isolated product", unit: .grams)]
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            VStack {
                Text("ISOLATED • SIMULATED SERVER").font(.caption.bold())
                if let trip = tracking.activeTrip {
                    Text("Active Trip • Tank \(trip.activeTankNumber ?? 0) • ended \(trip.tankSessions.filter { $0.endTime != nil }.count)")
                        .accessibilityIdentifier("lifecycle.active")
                    ActiveTripView(trip: trip)
                } else if let trip = store.trips.first, !trip.isActive, trip.endTime != nil {
                    List {
                        Text("Trip ended").accessibilityIdentifier("lifecycle.ended")
                        Text("Tank sessions: \(trip.tankSessions.count); ended: \(trip.tankSessions.filter { $0.endTime != nil }.count)")
                            .accessibilityIdentifier("lifecycle.tanks")
                        Text("Actual records: \(SprayTankActualStore.shared.records.filter { $0.tripId == trip.id }.count)")
                            .accessibilityIdentifier("lifecycle.actuals")
                        Text(store.sprayRecords.first?.endTime == trip.endTime ? "Linked Spray finalised" : "Linked Spray pending")
                            .accessibilityIdentifier("lifecycle.spray")
                        Text("Simulated readbacks: \(server.load().tripReads) Trip; \(server.load().sprayReads) Spray")
                        Text("Trip ID: \(trip.id)").accessibilityIdentifier("lifecycle.tripID")
                        Text((PersistenceStore.shared.load(key: "lifecycle.tank2.closed.before.trip") as Bool? == true) ? "Tank 2 persisted before Trip end" : "Tank-before-Trip order UNVERIFIED")
                            .accessibilityIdentifier("lifecycle.order")
                        if let error = server.error { Text(error).accessibilityIdentifier("lifecycle.error") }
                    }
                    .task { await server.synchronize(store: store) }
                } else {
                    Button("Open Spray Calculator") { showsCalculator = true }.disabled(!ready)
                }
            }
            .sheet(isPresented: $showsCalculator) {
                if let block = store.paddocks.first {
                    SprayCalculatorView.keyboardRegression(blockID: block.id, equipmentID: store.sprayEquipment.first?.id, chemicalID: store.savedChemicals.first?.id)
                }
            }
        }
        .environment(store).environment(auth).environment(tracking).environment(location)
        .environment(access).environment(admin).environment(canopy).environment(NetworkMonitor.shared)
        .environment(tripSync).environment(spraySync)
        .task {
            guard !ready else { return }
            auth.userId = SprayLifecycleSandbox.actor; auth.isSignedIn = true; auth.userName = "Isolated operator"
            access.currentRole = .owner
            let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: "spray-lifecycle-\(SprayLifecycleSandbox.runID!)")!)
            authority.bind(userId: SprayLifecycleSandbox.actor)
            store.operationalWriteAuthority = authority
            store.lifecycleReceiptTransport = { rpc, body in try await server.receipt(rpc: rpc, body: body) }
            store.onTripChanged = { id in
                let disk = TripRepository().loadAll()
                if let trip = disk.first(where: { $0.id == id }), trip.isActive, trip.endTime == nil,
                   trip.tankSessions.count == 2, trip.tankSessions.allSatisfy({ $0.endTime != nil }) {
                    do { try PersistenceStore.shared.saveOrThrow(true, key: "lifecycle.tank2.closed.before.trip") }
                    catch { server.error = "Could not persist ordering evidence: \(error)" }
                }
            }
            tracking.lifecycleTankOperator = { auth.userId }
            tracking.configure(store: store, locationService: location, accessControl: access, auth: auth)
            ready = true
        }
    }
}

private struct LifecycleCanopyImages: CanopyReferenceImageRemote {
    func fetchConfiguration() async throws -> CanopyReferenceConfiguration { .init(bucket: "isolated", configUpdatedAt: nil, images: [:]) }
    func downloadImage(bucket: String, path: String) async throws -> Data { throw URLError(.resourceUnavailable) }
}
#endif
