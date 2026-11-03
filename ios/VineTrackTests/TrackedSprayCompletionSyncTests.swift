import Foundation
import XCTest
@testable import VineTrack

final class TrackedSprayCompletionSyncTests: XCTestCase {
    // Keep MainActor-owned persistence teardown inside XCTest's async task context.
    // Swift 6.2.4: https://github.com/swiftlang/swift/issues/87316
    @MainActor func testFirstEndAndIdentitySurviveReloadAndLaterRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UUID(), trip = Trip(tripFunction: "spraying")
        let spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        let original = Date(timeIntervalSince1970: 1_793_600_100)
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        XCTAssertEqual(try queue.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: original), original)
        let reopened = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        XCTAssertEqual(try reopened.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: original.addingTimeInterval(500)), original)
        XCTAssertEqual(try reopened.intents(), [.init(ownerId: owner, vineyardId: trip.vineyardId, tripId: trip.id, sprayRecordId: spray.id, endTime: original)])
        XCTAssertThrowsError(try reopened.prepare(ownerId: UUID(), trip: trip, sprays: [spray], proposed: original))
        XCTAssertThrowsError(try reopened.prepare(ownerId: owner, trip: trip,
            sprays: [SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)], proposed: original))
        XCTAssertEqual(try reopened.intents().count, 1)
    }

    @MainActor func testFailedPrepareDoesNotPublishQueuedSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        persistence.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteOutOfSpace) }
        let queue = TrackedSprayCompletionSync(persistence: persistence)
        let trip = Trip(tripFunction: "spraying"), owner = UUID()
        let spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        XCTAssertThrowsError(try queue.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: Date()))
        XCTAssertTrue(try queue.intents().isEmpty)
        XCTAssertEqual(queue.revision, 0)
        XCTAssertTrue(try TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory)).intents().isEmpty)
    }

    @MainActor func testUnreadableOutboxNeverBecomesEmptyAndOriginalBytesRemain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(TrackedSprayCompletionSync.persistenceKey + ".json")
        let original = Data("{original-unreadable".utf8)
        try original.write(to: file)
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        let trip = Trip(tripFunction: "spraying")
        XCTAssertThrowsError(try queue.intents())
        XCTAssertThrowsError(try queue.prepare(ownerId: UUID(), trip: trip,
            sprays: [SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)], proposed: Date()))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor func testMissingAmbiguousManualTemplateAndWrongVineyardAreHeld() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        let trip = Trip(tripFunction: "spraying"), owner = UUID()
        let spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        XCTAssertThrowsError(try queue.prepare(ownerId: owner, trip: trip, sprays: [], proposed: Date()))
        XCTAssertThrowsError(try queue.prepare(ownerId: owner, trip: trip, sprays: [spray, spray], proposed: Date()))
        var manual = spray; manual.entrySource = "manual"
        XCTAssertThrowsError(try queue.prepare(ownerId: owner, trip: trip, sprays: [manual], proposed: Date()))
        manual.entrySource = nil; manual.manualEntryId = UUID()
        XCTAssertThrowsError(try queue.prepare(ownerId: owner, trip: trip, sprays: [manual], proposed: Date()))
        var template = spray; template.isTemplate = true
        XCTAssertThrowsError(try queue.prepare(ownerId: owner, trip: trip, sprays: [template], proposed: Date()))
        var foreign = spray; foreign.vineyardId = UUID()
        XCTAssertThrowsError(try queue.prepare(ownerId: owner, trip: trip, sprays: [foreign], proposed: Date()))
        XCTAssertTrue(try queue.intents().isEmpty)
    }

    @MainActor func testNonSprayAndHistoricalEndDoNotCreateCompletionIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        let proposed = Date(), owner = UUID()
        XCTAssertEqual(try queue.prepare(ownerId: owner, trip: Trip(tripFunction: "mowing"), sprays: [], proposed: proposed), proposed)
        let historical = Trip(endTime: proposed, isActive: false, tripFunction: "spraying")
        XCTAssertThrowsError(try queue.prepare(ownerId: owner, trip: historical,
            sprays: [SprayRecord(tripId: historical.id, vineyardId: historical.vineyardId)], proposed: proposed))
        XCTAssertTrue(try queue.intents().isEmpty)
    }

    @MainActor func testReplayRequiresIndependentReadbackAndDurablyRetiresExactIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        let owner = UUID(); var trip = Trip(tripFunction: "spraying")
        var spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId, notes: "Original planned quantities unchanged")
        let end = try queue.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: Date())
        trip.isActive = false; trip.endTime = end
        let original = spray
        var calls = 0, tripReads = 0, sprayReads = 0
        var verified: SprayRecord?
        await queue.replay(ownerId: owner, vineyardId: trip.vineyardId, isCurrent: { true },
            fetchTrip: { _ in tripReads += 1; return trip }, fetchSprays: { _ in sprayReads += 1; return [spray] },
            dependenciesReady: { _ in true }, expectedSprayIds: { _ in [spray.id] }, complete: { id in
                calls += 1; spray.endTime = end
                return SprayCompletionResponse(sprayRecordId: id, endTime: end, completionSource: "trip_end", serverConfirmed: true,
                    updatedAt: end, updatedBy: owner, clientUpdatedAt: end, syncVersion: 2)
            }, onVerified: { verified = $0 })
        XCTAssertEqual(calls, 1); XCTAssertEqual(tripReads, 2); XCTAssertEqual(sprayReads, 2)
        XCTAssertEqual(verified?.id, original.id); XCTAssertEqual(verified?.endTime, end)
        XCTAssertEqual(verified?.notes, original.notes); XCTAssertEqual(verified?.tanks, original.tanks)
        XCTAssertTrue(try TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory)).intents().isEmpty)
        let bytes = try Data(contentsOf: directory.appendingPathComponent(TrackedSprayCompletionSync.persistenceKey + ".json"))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("independentlyReadAt"))
    }

    @MainActor func testDependenciesBlockRPCAndRetainOriginalIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        let owner = UUID(); var trip = Trip(tripFunction: "spraying")
        let spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        let end = try queue.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: Date())
        trip.isActive = false; trip.endTime = end
        await queue.replay(ownerId: owner, vineyardId: trip.vineyardId, isCurrent: { true },
            fetchTrip: { _ in trip }, fetchSprays: { _ in XCTFail("Dependencies must gate reads"); return [] },
            dependenciesReady: { _ in false }, expectedSprayIds: { _ in [] },
            complete: { _ in XCTFail("Must not dispatch"); throw URLError(.notConnectedToInternet) }, onVerified: { _ in XCTFail("Not verified") })
        XCTAssertEqual(try queue.intents().first?.endTime, end)
    }

    @MainActor func testLostResponseSurvivesReloadAndRecoversWithoutSecondRPC() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        let owner = UUID(); var trip = Trip(tripFunction: "spraying")
        var spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        let end = try queue.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: Date())
        trip.isActive = false; trip.endTime = end
        await queue.replay(ownerId: owner, vineyardId: trip.vineyardId, isCurrent: { true },
            fetchTrip: { _ in trip }, fetchSprays: { _ in [spray] }, dependenciesReady: { _ in true }, expectedSprayIds: { _ in [] },
            complete: { _ in spray.endTime = end; throw URLError(.networkConnectionLost) }, onVerified: { _ in XCTFail("Lost response is not acknowledgement") })
        XCTAssertEqual(try queue.intents().count, 1)
        let reopened = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        var recovered = false
        await reopened.replay(ownerId: owner, vineyardId: trip.vineyardId, isCurrent: { true },
            fetchTrip: { _ in trip }, fetchSprays: { _ in [spray] }, dependenciesReady: { _ in true }, expectedSprayIds: { _ in [] },
            complete: { _ in XCTFail("Already complete: readback only"); throw URLError(.badServerResponse) }, onVerified: { _ in recovered = true })
        XCTAssertTrue(recovered); XCTAssertTrue(try reopened.intents().isEmpty)
    }

    @MainActor func testSuccessfulRPCWithoutSprayReadbackNeverAcknowledges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        let owner = UUID(); var trip = Trip(tripFunction: "spraying")
        let spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        let end = try queue.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: Date())
        trip.isActive = false; trip.endTime = end
        await queue.replay(ownerId: owner, vineyardId: trip.vineyardId, isCurrent: { true },
            fetchTrip: { _ in trip }, fetchSprays: { _ in [spray] }, dependenciesReady: { _ in true }, expectedSprayIds: { _ in [] },
            complete: { id in SprayCompletionResponse(sprayRecordId: id, endTime: end, completionSource: "trip_end", serverConfirmed: true,
                updatedAt: end, updatedBy: owner, clientUpdatedAt: end, syncVersion: 2) }, onVerified: { _ in XCTFail("RPC alone is not independent evidence") })
        XCTAssertEqual(try queue.intents().count, 1)
    }

    @MainActor func testFailedAcknowledgementWriteRetainsIntentAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let queue = TrackedSprayCompletionSync(persistence: persistence)
        let owner = UUID(); var trip = Trip(tripFunction: "spraying")
        var spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        let end = try queue.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: Date())
        trip.isActive = false; trip.endTime = end; spray.endTime = end
        persistence.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteOutOfSpace) }
        await queue.replay(ownerId: owner, vineyardId: trip.vineyardId, isCurrent: { true },
            fetchTrip: { _ in trip }, fetchSprays: { _ in [spray] }, dependenciesReady: { _ in true }, expectedSprayIds: { _ in [] },
            complete: { _ in XCTFail("Already ended"); throw URLError(.badServerResponse) }, onVerified: { _ in XCTFail("Receipt was not durable") })
        XCTAssertEqual(try queue.intents().count, 1)
        XCTAssertEqual(try TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory)).intents().first?.endTime, end)
    }

    @MainActor func testOtherAccountVineyardAndMidflightSwitchCannotRetireOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TrackedSprayCompletionSync(persistence: PersistenceStore(directory: directory))
        let owner = UUID(); var trip = Trip(tripFunction: "spraying")
        let spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        let end = try queue.prepare(ownerId: owner, trip: trip, sprays: [spray], proposed: Date())
        trip.isActive = false; trip.endTime = end
        for scope in [(UUID(), trip.vineyardId), (owner, UUID())] {
            await queue.replay(ownerId: scope.0, vineyardId: scope.1, isCurrent: { true },
                fetchTrip: { _ in XCTFail("Foreign scope must not dispatch"); return nil }, fetchSprays: { _ in [] },
                dependenciesReady: { _ in true }, expectedSprayIds: { _ in [] },
                complete: { _ in XCTFail("Foreign RPC"); throw URLError(.badServerResponse) }, onVerified: { _ in XCTFail("Foreign acknowledgement") })
        }
        var current = true
        await queue.replay(ownerId: owner, vineyardId: trip.vineyardId, isCurrent: { current },
            fetchTrip: { _ in current = false; return trip }, fetchSprays: { _ in XCTFail("Switched scope"); return [] },
            dependenciesReady: { _ in true }, expectedSprayIds: { _ in [] },
            complete: { _ in XCTFail("Switched RPC"); throw URLError(.badServerResponse) }, onVerified: { _ in XCTFail("Switched acknowledgement") })
        XCTAssertEqual(try queue.intents().first?.ownerId, owner)
    }

    @MainActor func testTripOnlyEndCannotCompleteSprayOrClosure() {
        let end = Date(); let trip = Trip(endTime: end, isActive: false, tripFunction: "spraying")
        var spray = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId)
        XCTAssertNotEqual(SprayCompletionResolver.status(record: spray, trip: trip), .completed)
        XCTAssertEqual(TrackedSprayCompletionSync.completionIssue(trip: trip, sprays: [spray]), "LINKED_SPRAY_COMPLETION_PENDING")
        spray.endTime = end.addingTimeInterval(1)
        XCTAssertEqual(TrackedSprayCompletionSync.completionIssue(trip: trip, sprays: [spray]), "LINKED_SPRAY_END_TIME_MISMATCH")
        spray.endTime = end
        XCTAssertNil(TrackedSprayCompletionSync.completionIssue(trip: trip, sprays: [spray]))
        XCTAssertEqual(TrackedSprayCompletionSync.completionIssue(trip: trip, sprays: [spray], expectedIds: [UUID()]), "LINKED_SPRAY_IDENTITY_UNVERIFIED")
        var input = TripClosureStatus.Input(tripId: trip.id.uuidString, evidence: .freshRead,
            serverIsActive: false, serverEndTime: end, serverSessionIds: [], locallyEnded: false,
            unresolvedMarkers: [], occurrencePending: 0, occurrenceHeldReason: nil, actualSessionIds: [], pendingActualIds: [], holdCodes: [])
        input.linkedSprayIssue = "LINKED_SPRAY_COMPLETION_PENDING"
        XCTAssertEqual(TripClosureStatus.evaluate(input).state, .dependentsPending)
        input.linkedSprayIssue = nil; input.completionIntentPending = true
        XCTAssertEqual(TripClosureStatus.evaluate(input).state, .dependentsPending)
        input.completionIntentPending = false
        XCTAssertEqual(TripClosureStatus.evaluate(input).state, .closedSynced)
    }
}
