import Foundation
import Testing
@testable import VineTrack

@MainActor struct TripDeletionRecoveryTests {
    @Test func filteredMissingRowNeverAcknowledgesLegacyDeletion() async throws {
        let disk = try persistence()
        let metadata = TripSyncMetadata(persistence: disk)
        let id = UUID(), vineyard = UUID()
        metadata.markDeleted(id, at: Date(timeIntervalSince1970: 100))
        let repo = DeletionRegressionRepository()
        let service = TripSyncService(repository: repo, metadata: metadata)
        let store = MigratedDataStore(persistence: disk)
        let auth = NewBackendAuthService()
        service.configure(store: store, auth: auth)
        try await service.pushLocalTrips(vineyardId: vineyard)
        #expect(metadata.pendingDeletes[id] != nil)
    }
    @Test func originalAbsenceHoldCanBeReverifiedWithoutClearingCancellation() async throws {
        let disk = try persistence(), journal = TripDeletionJournal(persistence: disk)
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        let original = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: Data([9]), established: true)
        try journal.hold(original, reason: "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED")
        let restarted = TripDeletionJournal(persistence: disk)
        let held = try #require(restarted.load().intents[scope.trip])
        var calls = 0
        let acknowledged = try await restarted.replay(held, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
            calls += 1
            let cancelled = try restarted.isCancelled(scope.trip)
            let reason = try restarted.load().intents[scope.trip]?.reviewReason
            #expect(cancelled)
            #expect(reason == held.reviewReason)
            return "SERVER_ABSENCE_VERIFIED_TEST_RECEIPT"
        }
        #expect(acknowledged && calls == 1)
        let saved = try #require(restarted.load().intents[scope.trip])
        #expect(saved.revision == original.revision && saved.originalEvidence == original.originalEvidence)
        #expect(saved.reviewReason == nil && saved.acknowledgement != nil)
        #expect(try restarted.isCancelled(scope.trip))
    }

    private func persistence() throws -> PersistenceStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PersistenceStore(directory: directory)
    }

    @Test func neverUploadedLegacyAndOccurrenceCancelWithoutRemoteAndKeepEvidence() async throws {
        for basis in ["legacy", "occurrence"] {
            let disk = try persistence(), journal = TripDeletionJournal(persistence: disk)
            let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
            try journal.registerCreation(scope)
            let evidence = Data("original-\(basis)-recipe-and-journal".utf8)
            let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: evidence)
            var calls = 0
            let ack = try await journal.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
                calls += 1; return "unexpected"
            }
            #expect(ack && calls == 0)
            let reopened = try TripDeletionJournal(persistence: disk).load()
            #expect(reopened.intents[scope.trip]?.originalEvidence == evidence)
            #expect(reopened.intents[scope.trip]?.acknowledgement == "LOCAL_CREATION_NEVER_SENT_CANCELLED")
            #expect(throws: TripDeletionJournal.Held.self) { try journal.beginSend(scope) }
        }
    }

    @Test func alreadyDeletedRetryUsesPositiveScopedTombstoneOnly() async throws {
        let disk = try persistence(), journal = TripDeletionJournal(persistence: disk)
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: Data([1]), established: true)
        var calls = 0
        let ack = try await journal.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { requested in
            calls += 1
            let tombstone = try TripDeletionJournal.hasServerTombstone([.init(id: scope.trip, vineyard_id: scope.vineyard, deleted_at: "2026-10-30T04:11:00Z")], scope: requested)
            #expect(tombstone)
            return "SERVER_TOMBSTONE_OBSERVED"
        }
        let reloaded = try #require(journal.load().intents[scope.trip])
        let second = try await journal.replay(reloaded, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
            calls += 1; return "unexpected"
        }
        #expect(ack && second && calls == 1)
    }

    @Test func accessHiddenEmptyAndWrongVineyardNeverCountAsAbsence() throws {
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        #expect(throws: TripDeletionJournal.Held.self) { try TripDeletionJournal.hasServerTombstone([], scope: scope) }
        #expect(throws: TripDeletionJournal.Held.self) {
            try TripDeletionJournal.hasServerTombstone([.init(id: scope.trip, vineyard_id: UUID(), deleted_at: "deleted")], scope: scope)
        }
        #expect(try !TripDeletionJournal.hasServerTombstone([.init(id: scope.trip, vineyard_id: scope.vineyard, deleted_at: nil)], scope: scope))
    }

    @Test func unknownCreationOutcomeAndInFlightAreHeldAcrossRestart() async throws {
        for inFlight in [true, false] {
            let disk = try persistence(), journal = TripDeletionJournal(persistence: disk)
            let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
            try journal.registerCreation(scope)
            try journal.beginSend(scope)
            if !inFlight { try journal.endSend(scope, established: false) }
            let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: Data([2]))
            #expect(intent.reviewReason == (inFlight ? "TRIP_DELETE_CREATE_IN_FLIGHT" : "TRIP_DELETE_CREATE_OUTCOME_UNKNOWN"))
            if inFlight { try journal.endSend(scope, established: false) }
            let reopened = TripDeletionJournal(persistence: disk)
            let retained = try #require(reopened.load().intents[scope.trip])
            let ack = try await reopened.replay(retained, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
                Issue.record("Uncertain create must not be deleted or replayed automatically"); return "unexpected"
            }
            #expect(!ack && retained.originalEvidence == Data([2]))
        }
    }

    @Test func offlineRestartRetainsExactRevisionThenAcknowledgesExistingTrip() async throws {
        let disk = try persistence(), journal = TripDeletionJournal(persistence: disk)
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: Data([3]), established: true)
        do {
            _ = try await journal.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in throw URLError(.notConnectedToInternet) }
            Issue.record("Offline replay should throw")
        } catch { #expect(error is URLError) }
        let restarted = TripDeletionJournal(persistence: disk)
        #expect(try restarted.load().intents[scope.trip] == intent)
        let ack = try await restarted.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in "DELETE_RPC_ACKNOWLEDGED" }
        #expect(ack)
    }

    @Test func accountAndVineyardSwitchCannotSendOrAcknowledge() async throws {
        let journal = TripDeletionJournal(persistence: try persistence())
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: nil, established: true)
        var calls = 0
        let wrongAccount = try await journal.replay(intent, account: UUID(), vineyard: scope.vineyard, isCurrent: { true }) { _ in calls += 1; return "unexpected" }
        let wrongVineyard = try await journal.replay(intent, account: scope.account, vineyard: UUID(), isCurrent: { true }) { _ in calls += 1; return "unexpected" }
        var current = true
        let switched = try await journal.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { current }) { _ in
            calls += 1; current = false; return "DELETE_RPC_ACKNOWLEDGED"
        }
        #expect(!wrongAccount && !wrongVineyard && !switched && calls == 1)
        #expect(try journal.load().intents[scope.trip]?.acknowledgement == nil)
    }

    @Test func failedIntentPersistenceLeavesTripAndLinksUntouched() throws {
        let disk = try persistence(), store = MigratedDataStore(persistence: disk)
        let account = UUID(), vineyard = UUID()
        store.currentUserIdProvider = { account }; store.selectedVineyardId = vineyard
        let trip = Trip(vineyardId: vineyard, paddockName: "Original", isActive: false)
        store.trips = [trip]
        try store.tripRepo.saveSliceOrThrow([trip], for: vineyard)
        let diskBefore = store.tripRepo.loadAll()
        var published = 0
        store.onTripDeleted = { _ in published += 1 }
        disk.durableSaveFailureForTesting = { $0 == TripDeletionJournal.key ? URLError(.cannotWriteToFile) : nil }
        store.deleteTrip(trip.id)
        #expect(store.trips == [trip] && store.tripRepo.loadAll() == diskBefore)
        #expect(published == 0 && store.tripDeletionError != nil)
        #expect(try store.tripDeletionJournal.load().intents.isEmpty)
    }

    @Test func failedCacheRemovalKeepsSnapshotAndBlocksCreationReplay() throws {
        let disk = try persistence(), store = MigratedDataStore(persistence: disk)
        let account = UUID(), vineyard = UUID()
        store.currentUserIdProvider = { account }; store.selectedVineyardId = vineyard
        let trip = Trip(vineyardId: vineyard, paddockName: "Original", isActive: false)
        store.trips = [trip]
        try store.tripRepo.saveSliceOrThrow([trip], for: vineyard)
        disk.durableSaveFailureForTesting = { $0 == TripRepository.storageKey ? URLError(.cannotWriteToFile) : nil }
        store.deleteTrip(trip.id)
        #expect(store.trips == [trip] && store.tripDeletionError != nil)
        let retainedBytes = try #require(store.tripDeletionJournal.load().intents[trip.id]?.originalEvidence)
        let retainedTrip = try JSONDecoder().decode(Trip.self, from: retainedBytes)
        #expect(retainedTrip == trip)
        disk.durableSaveFailureForTesting = nil
        let intent = try #require(store.tripDeletionJournal.load().intents[trip.id])
        try store.finishTripDeletionLocally(intent)
        #expect(store.trips.isEmpty && store.tripRepo.loadAll().isEmpty)
        #expect(try store.tripDeletionJournal.load().intents[trip.id]?.originalEvidence == retainedBytes)
        #expect(throws: TripDeletionJournal.Held.self) {
            try store.tripDeletionJournal.beginSend(.init(account: account, vineyard: vineyard, trip: trip.id))
        }
    }

    @Test func newerDeletionAndQueuedEditsSurviveOldAcknowledgementAndDiskFailure() async throws {
        let disk = try persistence(), journal = TripDeletionJournal(persistence: disk), metadata = TripSyncMetadata(persistence: disk)
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        let oldDate = Date(timeIntervalSince1970: 100), newDate = Date(timeIntervalSince1970: 200)
        let old = try journal.prepare(trip: scope.trip, queuedAt: oldDate, scope: scope, evidence: Data([1]), established: true)
        metadata.markDeleted(scope.trip, at: oldDate)
        let ack = try await journal.replay(old, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
            _ = try journal.prepare(trip: scope.trip, queuedAt: newDate, scope: scope, evidence: Data([2]), established: true)
            metadata.markDeleted(scope.trip, at: newDate)
            metadata.markDirty(scope.trip, at: newDate)
            return "DELETE_RPC_ACKNOWLEDGED"
        }
        #expect(!ack)
        try metadata.clearDeletedRevision(scope.trip, at: oldDate)
        #expect(metadata.pendingDeletes[scope.trip] == newDate && metadata.pendingUpserts[scope.trip] == newDate)
        #expect(try journal.load().history.first == old)
        disk.durableSaveFailureForTesting = { _ in URLError(.cannotWriteToFile) }
        #expect(throws: (any Error).self) { try metadata.clearDeletedRevision(scope.trip, at: newDate) }
        #expect(metadata.pendingDeletes[scope.trip] == newDate)
        disk.durableSaveFailureForTesting = nil
        let restored = TripSyncMetadata(persistence: disk)
        #expect(restored.pendingDeletes[scope.trip] == newDate && restored.pendingUpserts[scope.trip] == newDate)
    }

    @Test func legacyWalScopeRecoveryNeverUsesSelectedVineyardAndNeverResurrects() async throws {
        for occurrence in [false, true] {
            let disk = try persistence(), store = MigratedDataStore(persistence: disk)
            let original = UUID(), actor = UUID(), id = UUID()
            let scope = LegacySpraySaveRecovery.Scope(actor: actor, session: UUID(), vineyard: original)
            var trip = Trip(id: id, vineyardId: original, paddockName: "Original", isActive: false)
            if occurrence {
                let rows = [PaddockRow(number: 1, startPoint: .init(latitude: 0, longitude: 0), endPoint: .init(latitude: 0, longitude: 1)),
                            PaddockRow(number: 2, startPoint: .init(latitude: 1, longitude: 0), endPoint: .init(latitude: 1, longitude: 1))]
                let block = Paddock(vineyardId: original, name: "Original", rows: rows)
                let candidates = TripOccurrencePlanner.candidates([block])
                trip.occurrenceCoverage = try TripOccurrencePlanner.commit(
                    TripOccurrencePlanner.plan(candidates, pattern: .sequential, startKey: candidates.first?.id, higherFirst: true), vineyardId: original)
                #expect(trip.coverageBasis == .occurrence)
            }
            let record = SprayRecord(tripId: id, vineyardId: original)
            let wal = LegacySpraySaveRecovery(persistence: disk)
            try wal.prepare(scope: scope, record: record, trip: trip)
            let before = try wal.attempts()
            let metadata = TripSyncMetadata(persistence: disk)
            metadata.markDeleted(id, at: Date(timeIntervalSince1970: 100))
            store.selectedVineyardId = UUID()
            let intent = try store.recoverTripDeletionIntent(id: id, queuedAt: Date(timeIntervalSince1970: 100), established: false)
            #expect(intent.scope == .init(account: actor, vineyard: original, trip: id))
            _ = try wal.reconcile(scope: scope, record: { _ in Issue.record("Cancelled recipe replayed") }, trip: { _ in Issue.record("Cancelled Trip recreated") })
            try await wal.replay(scope: scope, isCurrent: { true }) { _, _ in Issue.record("Cancelled pair sent"); return Data() }
            #expect(try wal.attempts() == before)
            #expect(throws: TripDeletionJournal.Held.self) {
                try store.tripDeletionJournal.beginSend(.init(account: actor, vineyard: original, trip: id))
            }
        }
    }

    @Test func occurrenceCancellationPreservesRealCreateAndActivationJournalAcrossRestart() async throws {
        for provenNeverSent in [true, false] {
            let disk = try persistence(), store = MigratedDataStore(persistence: disk)
            let account = UUID(), vineyard = UUID(), tripId = UUID()
            let scope = TripDeletionJournal.Scope(account: account, vineyard: vineyard, trip: tripId)
            let journalScope = TripOccurrenceJournal.Scope(ownerId: account.uuidString.lowercased(), vineyardId: vineyard.uuidString.lowercased(), tripId: tripId.uuidString.lowercased())
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let ownerDirectory = support.appendingPathComponent("TripOccurrenceJournals").appendingPathComponent(journalScope.ownerId)
            defer { try? FileManager.default.removeItem(at: ownerDirectory) }
            let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            authority.bind(userId: account)
            let occurrence = try TripOccurrenceJournal(scope: journalScope, authority: authority)
            let rows = [PaddockRow(number: 1, startPoint: .init(latitude: 0, longitude: 0), endPoint: .init(latitude: 0, longitude: 1)),
                        PaddockRow(number: 2, startPoint: .init(latitude: 1, longitude: 0), endPoint: .init(latitude: 1, longitude: 1))]
            let block = Paddock(vineyardId: vineyard, name: "Original", rows: rows)
            let candidates = TripOccurrencePlanner.candidates([block])
            let coverage = try TripOccurrencePlanner.commit(TripOccurrencePlanner.plan(candidates, pattern: .sequential, startKey: candidates.first?.id, higherFirst: true), vineyardId: vineyard)
            var trip = Trip(id: tripId, vineyardId: vineyard, paddockName: "Original", isActive: false)
            trip.occurrenceCoverage = coverage
            _ = try occurrence.prepareCreation(trip: .object(["id": .string(journalScope.tripId), "vineyard_id": .string(journalScope.vineyardId)]), coverage: coverage)
            _ = try occurrence.activate(.object([:]))
            let loadedOriginal = try occurrence.load()
            let original = try #require(loadedOriginal)
            let file = ownerDirectory.appendingPathComponent(journalScope.vineyardId).appendingPathComponent(journalScope.tripId + ".json")
            let bytes = try Data(contentsOf: file)
            if provenNeverSent { try store.tripDeletionJournal.registerCreation(scope) }
            store.selectedVineyardId = vineyard; store.currentUserIdProvider = { account }
            store.trips = [trip]
            try store.tripRepo.saveSliceOrThrow([trip], for: vineyard)
            if provenNeverSent {
                store.deleteTrip(tripId)
                #expect(store.trips.isEmpty && store.tripDeletionError == nil)
            } else {
                // Pre-upgrade ID-only queue: original scope comes solely from the real journal.
                let metadata = TripSyncMetadata(persistence: disk)
                metadata.markDeleted(tripId, at: Date(timeIntervalSince1970: 100))
                store.selectedVineyardId = UUID()
                _ = try store.recoverTripDeletionIntent(id: tripId, queuedAt: Date(timeIntervalSince1970: 100), established: false)
            }
            let reopened = TripDeletionJournal(persistence: disk)
            let intent = try #require(reopened.load().intents[tripId])
            #expect(intent.scope == scope)
            #expect(intent.creationOutcome == (provenNeverSent ? "neverSent" : "uncertain"))
            let ack = try await reopened.replay(intent, account: account, vineyard: vineyard, isCurrent: { true }) { _ in
                Issue.record("Cancelled or uncertain occurrence create must not send"); return "unexpected"
            }
            #expect(ack == provenNeverSent)
            #expect(throws: TripDeletionJournal.Held.self) { try reopened.beginSend(scope) }
            #expect(try occurrence.load() == original)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func failedAcknowledgementPersistenceRetainsExactIntentAndQueue() async throws {
        let disk = try persistence(), journal = TripDeletionJournal(persistence: disk), metadata = TripSyncMetadata(persistence: disk)
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        let date = Date(timeIntervalSince1970: 100)
        let intent = try journal.prepare(trip: scope.trip, queuedAt: date, scope: scope, evidence: Data([5]), established: true)
        metadata.markDeleted(scope.trip, at: date)
        disk.durableSaveFailureForTesting = { $0 == TripDeletionJournal.key ? URLError(.cannotWriteToFile) : nil }
        do {
            _ = try await journal.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in "DELETE_RPC_ACKNOWLEDGED" }
            Issue.record("Unpersisted acknowledgement cannot report completion")
        } catch { #expect(error is URLError) }
        #expect(try TripDeletionJournal(persistence: disk).load().intents[scope.trip] == intent)
        #expect(TripSyncMetadata(persistence: disk).pendingDeletes[scope.trip] == date)
    }

    @Test func unresolvedScopeAndForeignActorCannotBorrowActiveVineyard() async throws {
        let disk = try persistence(), store = MigratedDataStore(persistence: disk)
        let id = UUID(), selected = UUID()
        store.selectedVineyardId = selected
        let intent = try store.recoverTripDeletionIntent(id: id, queuedAt: Date(timeIntervalSince1970: 100), established: false)
        #expect(intent.scope == nil && intent.reviewReason == "TRIP_DELETE_ORIGINAL_SCOPE_UNRESOLVED")
        let ack = try await store.tripDeletionJournal.replay(intent, account: UUID(), vineyard: selected, isCurrent: { true }) { _ in
            Issue.record("Unresolved deletion must not use selection as scope"); return "unexpected"
        }
        #expect(!ack)
    }

    @Test func legacyClaimWithoutReceiptRemainsUnknownRatherThanNeverSent() throws {
        let journal = TripDeletionJournal(persistence: try persistence())
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: Data([6]), uncertainCreation: true)
        #expect(intent.creationOutcome == "uncertain" && intent.reviewReason == "TRIP_DELETE_CREATE_OUTCOME_UNKNOWN")
    }

    @Test func acknowledgedNeverSentLegacyCancellationAllowsNewSaveWithoutReplayingOriginal() async throws {
        let disk = try persistence(), wal = LegacySpraySaveRecovery(persistence: disk), deletion = TripDeletionJournal(persistence: disk)
        let vineyard = UUID(), actor = UUID()
        let scope = LegacySpraySaveRecovery.Scope(actor: actor, session: UUID(), vineyard: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockName: "Cancelled", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        try wal.prepare(scope: scope, record: record, trip: trip)
        let original = try wal.attempts()
        let intent = try deletion.prepare(trip: trip.id, queuedAt: Date(timeIntervalSince1970: 100),
            scope: .init(account: actor, vineyard: vineyard, trip: trip.id), evidence: JSONEncoder().encode(trip))
        let ack = try await deletion.replay(intent, account: actor, vineyard: vineyard, isCurrent: { true }) { _ in Issue.record("Never-sent cancellation must be local"); return "unexpected" }
        #expect(ack)
        let newTrip = Trip(vineyardId: vineyard, paddockName: "New", isActive: false)
        let newRecord = SprayRecord(tripId: newTrip.id, vineyardId: vineyard)
        try wal.prepare(scope: scope, record: newRecord, trip: newTrip)
        #expect(try wal.attempts().first == original.first)
        #expect(try wal.contains(trip: trip.id)) // Cancelled paired record must still be blocked from REST replay.
        #expect(try !wal.requiresLegacyReceipt(original[0]))
    }

    @Test func newerLocalTripSnapshotBlocksRemovalAndDeletionReplay() throws {
        let disk = try persistence(), store = MigratedDataStore(persistence: disk)
        let actor = UUID(), vineyard = UUID()
        let original = Trip(vineyardId: vineyard, paddockName: "Original", isActive: false)
        var newer = original; newer.currentRowNumber = 42.5
        store.selectedVineyardId = vineyard; store.currentUserIdProvider = { actor }; store.trips = [newer]
        try store.tripRepo.saveSliceOrThrow([newer], for: vineyard)
        let intent = try store.tripDeletionJournal.prepare(trip: original.id, queuedAt: Date(timeIntervalSince1970: 100),
            scope: .init(account: actor, vineyard: vineyard, trip: original.id), evidence: JSONEncoder().encode(original), established: true)
        #expect(throws: TripDeletionJournal.Held.self) { try store.finishTripDeletionLocally(intent) }
        #expect(store.trips == [newer])
        #expect(store.tripRepo.loadAll().first?.currentRowNumber == 42.5)
    }

    @Test func deletionAcknowledgementPreservesSeparateMissingUploadAndNewerCancelledEdits() async throws {
        let disk = try persistence(), store = MigratedDataStore(persistence: disk), metadata = TripSyncMetadata(persistence: disk)
        let vineyard = UUID(), actor = UUID(), deleted = UUID(), separateUpload = UUID()
        store.selectedVineyardId = vineyard; store.currentUserIdProvider = { actor }
        let date = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
        _ = try store.tripDeletionJournal.prepare(trip: deleted, queuedAt: date,
            scope: .init(account: actor, vineyard: vineyard, trip: deleted), evidence: Data([7]), established: true)
        metadata.markDeleted(deleted, at: date)
        metadata.markDirty(deleted, at: newer)
        metadata.markDirty(separateUpload, at: date)
        let repo = DeletionRegressionRepository(); repo.deletionEvidence = "DELETE_RPC_ACKNOWLEDGED"
        let service = TripSyncService(repository: repo, metadata: metadata), auth = NewBackendAuthService()
        service.configure(store: store, auth: auth)
        try await service.pushLocalTrips(vineyardId: vineyard)
        #expect(metadata.pendingDeletes[deleted] == nil && repo.deleteCalls == 1)
        #expect(metadata.pendingUpserts[deleted] == newer && metadata.pendingUpserts[separateUpload] == date)
        #expect(service.deletionRecoveryDiagnostics.contains("upload trip=\(separateUpload)"))
        #expect(service.deletionRecoveryDiagnostics.contains("TRIP_UPLOAD_ORIGINAL_SNAPSHOT_UNAVAILABLE"))
        #expect(try store.tripDeletionJournal.isCancelled(deleted))
    }

    @Test func laterReviewHoldInvalidatesCapturedReplaySnapshot() async throws {
        let journal = TripDeletionJournal(persistence: try persistence())
        let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
        let captured = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: nil, established: true)
        try journal.hold(captured, reason: "TRIP_DELETE_NEWER_LOCAL_WORK_RETAINED")
        let ack = try await journal.replay(captured, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
            Issue.record("Captured replay bypassed a newer review hold"); return "unexpected"
        }
        #expect(!ack)
    }

    @Test func hiddenDeletionIsHeldOnceAndUnrelatedUploadStaysIdentifiable() async throws {
        let disk = try persistence(), store = MigratedDataStore(persistence: disk), metadata = TripSyncMetadata(persistence: disk)
        let vineyard = UUID(), actor = UUID(), deleted = UUID()
        store.selectedVineyardId = vineyard; store.currentUserIdProvider = { actor }
        _ = try store.tripDeletionJournal.prepare(trip: deleted, queuedAt: Date(timeIntervalSince1970: 100),
            scope: .init(account: actor, vineyard: vineyard, trip: deleted), evidence: Data([4]), established: true)
        metadata.markDeleted(deleted, at: Date(timeIntervalSince1970: 100))
        // A distinct missing-function pending upload is retained by its own admission result.
        let upload = Trip(vineyardId: vineyard, paddockName: "Unrelated", isActive: false)
        store.trips = [upload]; metadata.markDirty(upload.id, at: Date(timeIntervalSince1970: 200))
        let repo = DeletionRegressionRepository()
        repo.rejectUploads = true
        let service = TripSyncService(repository: repo, metadata: metadata), auth = NewBackendAuthService()
        service.configure(store: store, auth: auth)
        for _ in 0..<2 { try? await service.pushLocalTrips(vineyardId: vineyard) }
        #expect(metadata.pendingDeletes[deleted] != nil && metadata.pendingUpserts[upload.id] != nil)
        #expect(service.deletionRecoveryDiagnostics.contains("upload trip=\(upload.id)"))
        #expect(repo.deleteCalls == 1)
        #expect(try store.tripDeletionJournal.load().intents[deleted]?.reviewReason == "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED")
        // Upload errors must not prevent the independent deletion recovery phase forever.
    }
}

@MainActor private final class DeletionRegressionRepository: TripSyncRepositoryProtocol {
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { [] }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { [] }
    func upsertTrip(_ trip: BackendTripUpsert) async throws {}
    var rejectUploads = false
    var deleteCalls = 0
    var deletionEvidence: String?
    func upsertTrips(_ trips: [BackendTripUpsert]) async throws { if rejectUploads { throw URLError(.notConnectedToInternet) } }
    func resolveDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String {
        deleteCalls += 1
        if let deletionEvidence { return deletionEvidence }
        throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED")
    }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {}
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {}
    func softDeleteTrip(id: UUID) async throws { throw NSError(domain: "RLS filtered no rows", code: 0) }
}
