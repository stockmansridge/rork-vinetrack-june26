import Foundation
import Testing
import Supabase
@testable import VineTrack

@MainActor
struct VineyardWriteAuthorityTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "write-authority-test-" + UUID().uuidString)! }
    private let expired = VineyardOperationalAccess(legacyCanEnter: false, canEnterVineyard: true, canWrite: false, readOnlyReason: "trial_expired")
    private let paid = VineyardOperationalAccess(legacyCanEnter: true, canWrite: true)

    private struct QueuedPayload: Encodable, Sendable {
        let id: UUID
        let vineyard_id: UUID
        let evidence: String
    }

    @Test func sharedReplayHoldsOriginalPayloadWithoutCallingTransport() async {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID()
        gate.bind(userId: UUID(), cached: [vineyard.uuidString: expired])
        let payload = QueuedPayload(id: UUID(), vineyard_id: vineyard, evidence: "original")
        var sent = 0
        let result = await SyncQueuePush.run(entity: "Synthetic", ids: [payload.id], payloads: [payload], authority: gate) { _ in sent += 1 }
        #expect(sent == 0)
        #expect(result.uploaded.isEmpty && result.failed.isEmpty)
        #expect(payload.evidence == "original")
    }

    @Test func sharedReplayUsesPayloadScopeNotSelectedPaidVineyard() async {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID()
        gate.bind(userId: UUID(), cached: [vineyard.uuidString: expired])
        let payload = QueuedPayload(id: UUID(), vineyard_id: vineyard, evidence: "retained")
        var sent = 0
        let result = await SyncQueuePush.run(entity: "Synthetic", ids: [payload.id], payloads: [payload], vineyardId: UUID(), authority: gate) { _ in sent += 1 }
        #expect(sent == 0 && result.uploaded.isEmpty)
    }

    @Test func mixedVineyardReplaySendsOnlyWritableOriginal() async {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID()
        gate.bind(userId: UUID(), cached: [vineyard.uuidString: expired])
        let held = QueuedPayload(id: UUID(), vineyard_id: vineyard, evidence: "held")
        let paid = QueuedPayload(id: UUID(), vineyard_id: UUID(), evidence: "paid")
        var sent: [UUID] = []
        let result = await SyncQueuePush.run(entity: "Synthetic", ids: [held.id, paid.id], payloads: [held, paid], authority: gate) { sent += $0.map(\.id) }
        #expect(sent == [paid.id] && result.uploaded == [paid.id])
        #expect(result.failed.isEmpty)
    }

    @Test func structuredBatchRejectionDoesNotFanOutOrClassifyOrdinaryFailure() async throws {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID()
        gate.bind(userId: UUID())
        let payloads = [QueuedPayload(id: UUID(), vineyard_id: vineyard, evidence: "one"), QueuedPayload(id: UUID(), vineyard_id: vineyard, evidence: "two")]
        let error = try JSONDecoder().decode(PostgrestError.self, from: Data(#"{"code":"VT_READ_ONLY","message":"Read only","details":null,"hint":null}"#.utf8))
        var calls = 0
        let result = await SyncQueuePush.run(entity: "Synthetic", ids: payloads.map(\.id), payloads: payloads, authority: gate) { _ in calls += 1; throw error }
        #expect(calls == 1)
        #expect(result.failed.isEmpty && result.uploaded.isEmpty)
        #expect(gate.heldReason(vineyardId: vineyard.uuidString) == "VT_READ_ONLY")
    }

    @Test func sharedReplayRechecksAfterSuspensionAndRestoresOriginalIds() async {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID(), paidVineyard = UUID()
        gate.bind(userId: UUID())
        // Different scopes force isolated sends; expiry arrives while the first is in flight.
        let first = QueuedPayload(id: UUID(), vineyard_id: paidVineyard, evidence: "first")
        let retained = QueuedPayload(id: UUID(), vineyard_id: vineyard, evidence: "retained")
        var sent: [UUID] = []
        let result = await SyncQueuePush.run(entity: "Synthetic", ids: [first.id, retained.id], payloads: [first, retained], authority: gate) { values in
            sent += values.map(\.id)
            await Task.yield()
            gate.verified(vineyardId: vineyard.uuidString, access: expired, explicitlyWritable: false)
        }
        #expect(sent == [first.id] && result.uploaded == [first.id])
        gate.verified(vineyardId: vineyard.uuidString, access: paid, explicitlyWritable: true)
        let resumed = await SyncQueuePush.run(entity: "Synthetic", ids: [retained.id], payloads: [retained], authority: gate) { sent += $0.map(\.id) }
        #expect(resumed.uploaded == [retained.id])
        #expect(sent == [first.id, retained.id])
    }

    @Test func unknownOldServerRemainsCompatible() {
        let gate = VineyardWriteAuthority(defaults: defaults())
        gate.bind(userId: UUID())
        #expect(gate.canWrite(vineyardId: UUID().uuidString))
    }
    @Test func explicitExpiryDeniesWhileCapabilityKeepsEntry() throws {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID().uuidString
        gate.bind(userId: UUID(), cached: [vineyard: expired])
        #expect(expired.canEnter)
        #expect(!gate.admit(vineyardId: vineyard))
        #expect(throws: VineyardWriteAuthority.Restricted.self) { try gate.requireWrite(vineyardId: vineyard) }
        #expect(gate.deniedVineyardId == vineyard)
    }
    @Test func durableHoldSurvivesNewAuthorityWithoutSnapshot() {
        let storage = defaults(), user = UUID(), vineyard = UUID().uuidString
        let before = VineyardWriteAuthority(defaults: storage)
        before.bind(userId: user, cached: [vineyard: expired])
        let restarted = VineyardWriteAuthority(defaults: storage)
        restarted.bind(userId: user)
        #expect(restarted.heldReason(vineyardId: vineyard) == VineyardWriteAuthority.holdReason)
    }
    @Test func legacyRefreshDoesNotReleaseKnownHold() {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID().uuidString
        gate.bind(userId: UUID(), cached: [vineyard: expired])
        gate.verified(vineyardId: vineyard, access: paid, explicitlyWritable: false)
        #expect(!gate.canWrite(vineyardId: vineyard))
    }
    @Test func onlyVerifiedWritableRestoresOriginalScope() {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID().uuidString
        gate.bind(userId: UUID(), cached: [vineyard: expired])
        gate.verified(vineyardId: vineyard, access: paid, explicitlyWritable: true)
        #expect(gate.canWrite(vineyardId: vineyard))
    }
    @Test func explicitWritableButEntryDeniedDoesNotRelease() {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID().uuidString
        gate.bind(userId: UUID(), cached: [vineyard: expired])
        gate.verified(vineyardId: vineyard, access: VineyardOperationalAccess(legacyCanEnter: false, canWrite: true), explicitlyWritable: true)
        #expect(!gate.canWrite(vineyardId: vineyard))
    }
    @Test func switchingVineyardsIsIndependent() {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID().uuidString
        gate.bind(userId: UUID(), cached: [vineyard: expired])
        #expect(gate.canWrite(vineyardId: UUID().uuidString))
        #expect(!gate.canWrite(vineyardId: vineyard.lowercased()))
    }
    @Test func switchingAccountsCannotEraseOrInheritHold() {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID().uuidString, user = UUID()
        gate.bind(userId: user, cached: [vineyard: expired])
        gate.bind(userId: UUID())
        #expect(gate.canWrite(vineyardId: vineyard))
        gate.bind(userId: user)
        #expect(!gate.canWrite(vineyardId: vineyard))
    }
    @Test func structuredServerCodeHoldsWithoutInventingTrialReason() {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID().uuidString
        gate.bind(userId: UUID())
        #expect(!gate.handleServerCode("401", vineyardId: vineyard))
        #expect(gate.handleServerCode("VT_READ_ONLY", vineyardId: vineyard))
        #expect(gate.heldReason(vineyardId: vineyard) == "VT_READ_ONLY")
        #expect(!gate.canWrite(vineyardId: vineyard))
    }
    @Test func serverRejectionPreservesConfirmedTrialReason() {
        let gate = VineyardWriteAuthority(defaults: defaults()), vineyard = UUID().uuidString
        gate.bind(userId: UUID(), cached: [vineyard: expired])
        #expect(gate.handleServerCode("VT_READ_ONLY", vineyardId: vineyard))
        #expect(gate.heldReason(vineyardId: vineyard) == VineyardWriteAuthority.holdReason)
    }
    @Test func saveForLaterDeniedBeforeJournalAndPublication() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceStore(directory: root), vineyard = UUID()
        let store = MigratedDataStore(persistence: persistence)
        let gate = VineyardWriteAuthority(defaults: defaults())
        gate.bind(userId: UUID(), cached: [vineyard.uuidString: expired])
        store.operationalWriteAuthority = gate
        store.selectedVineyardId = vineyard
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        store.legacySprayScopeProvider = { scope }
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        #expect(throws: VineyardWriteAuthority.Restricted.self) { try store.saveSprayForLater(record: record, trip: trip) }
        #expect(try LegacySpraySaveRecovery(persistence: persistence).attempts().isEmpty)
        #expect(store.trips.isEmpty && store.sprayRecords.isEmpty)
    }
    @Test func existingJournalIsUnchangedByBlockedNewSave() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceStore(directory: root), vineyard = UUID()
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockName: "Retained", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = LegacySpraySaveRecovery(persistence: persistence)
        try journal.prepare(scope: scope, record: record, trip: trip)
        let before = try journal.attempts()
        let gate = VineyardWriteAuthority(defaults: defaults())
        gate.bind(userId: scope.actor, cached: [vineyard.uuidString: expired])
        let store = MigratedDataStore(persistence: persistence)
        store.operationalWriteAuthority = gate
        store.selectedVineyardId = vineyard
        store.legacySprayScopeProvider = { scope }
        #expect(throws: VineyardWriteAuthority.Restricted.self) { try store.prepareLegacySpraySave(record: record, trip: trip) }
        // Compare retained semantic identity/evidence; no replacement attempt is minted.
        let after = try journal.attempts()
        #expect(after.count == before.count)
        #expect(after.first?.record == before.first?.record)
        #expect(after.first?.trip == before.first?.trip)
    }
    @Test func staleTripAndSprayCommandsDoNotPublishOrQueue() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vineyard = UUID(), store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let gate = VineyardWriteAuthority(defaults: defaults())
        gate.bind(userId: UUID(), cached: [vineyard.uuidString: expired])
        store.operationalWriteAuthority = gate
        store.selectedVineyardId = vineyard
        var queued = 0
        store.onTripChanged = { _ in queued += 1 }
        store.onSprayRecordChanged = { _ in queued += 1 }
        let trip = Trip(vineyardId: vineyard, paddockName: "Blocked", isActive: false)
        store.startTrip(trip)
        store.addInactiveTrip(trip)
        #expect(!store.addSprayRecord(SprayRecord(tripId: trip.id, vineyardId: vineyard)))
        #expect(throws: VineyardWriteAuthority.Restricted.self) { try store.savePlannedTripOrThrow(trip) }
        #expect(queued == 0 && store.trips.isEmpty && store.sprayRecords.isEmpty)
    }
}
