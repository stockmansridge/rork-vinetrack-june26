import Foundation
import XCTest
@testable import VineTrack

final class TripOccurrenceJournalTests: XCTestCase {
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"
    private let scope = TripOccurrenceJournal.Scope(ownerId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", vineyardId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", tripId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
    private func fixture(otherBlock: Bool = false) throws -> TripOccurrenceCoverage.JSON {
        let block = otherBlock ? "99999999-9999-4999-8999-999999999999" : "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let physical = otherBlock ? "88888888-8888-4888-8888-888888888888" : "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let raw = """
        {"contract":"vinetrack.planned-occurrence","schemaVersion":1,"planId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","revision":0,"planRevision":1,
        "items":[{"occurrenceId":"\(a)","blockId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","blockNameSnapshot":"Block X","pathNumber":38.5,"passOrdinal":1,"physicalPathRef":{"pathId":"ffffffff-ffff-4fff-8fff-ffffffffffff","rowIds":[],"geometryRevision":"unresolved"}},
        {"occurrenceId":"\(b)","blockId":"\(block)","blockNameSnapshot":"\(otherBlock ? "Block Y" : "Block X")","pathNumber":38.5,"passOrdinal":2,"physicalPathRef":{"pathId":"\(physical)","rowIds":[],"geometryRevision":"unresolved"}}],
        "activeOrder":["\(a)","\(b)"],"retired":[],"states":{"\(a)":{"status":"incomplete","source":null,"lastOperationId":null,"tankSessionIds":[]},"\(b)":{"status":"incomplete","source":null,"lastOperationId":null,"tankSessionIds":[]}},"plannedCursorId":"\(a)","selectedOccurrenceId":null,"extension":{"retain":true}}
        """
        return try JSONDecoder().decode(TripOccurrenceCoverage.JSON.self, from: Data(raw.utf8))
    }
    @MainActor private func journal(_ directory: URL, otherBlock: Bool = false) throws -> TripOccurrenceJournal {
        let j = try TripOccurrenceJournal(scope: scope, directory: directory)
        if try j.load() == nil { try j.initialize(fixture(otherBlock: otherBlock)) }
        return j
    }
    @MainActor private func status(_ j: TripOccurrenceJournal, _ id: String) throws -> String? {
        let state = try XCTUnwrap(j.load())
        return try TripOccurrenceCoverage.requireDocument(state.projected).states[id]?.status
    }
    private func ack(_ op: TripOccurrenceJournal.Operation) -> TripOccurrenceCoverage.JSON {
        .object(["tripId": .string(scope.tripId), "operationId": .string(op.id), "coverage": op.after])
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @MainActor func testEntitlementHoldPreservesJournalBytesButAllowsRealReceiptAndOriginalResume() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        authority.bind(userId: UUID(uuidString: scope.ownerId)!)
        let j = try TripOccurrenceJournal(scope: scope, directory: dir, authority: authority)
        try j.initialize(fixture())
        let original = try j.setStatus(a, status: "done")
        let file = dir.appendingPathComponent(scope.ownerId).appendingPathComponent(scope.vineyardId).appendingPathComponent(scope.tripId + ".json")
        let bytes = try Data(contentsOf: file)
        authority.verified(vineyardId: scope.vineyardId, access: VineyardOperationalAccess(legacyCanEnter: false, canEnterVineyard: true, canWrite: false, readOnlyReason: "trial_expired"), explicitlyWritable: false)
        let reopened = try TripOccurrenceJournal(scope: scope, directory: dir, authority: authority)
        XCTAssertThrowsError(try reopened.setStatus(b, status: "skipped")) { XCTAssertTrue($0 is VineyardWriteAuthority.Restricted) }
        XCTAssertThrowsError(try reopened.finalize(.object([:]))) { XCTAssertTrue($0 is VineyardWriteAuthority.Restricted) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try reopened.load()?.pending, [original])
        try reopened.acknowledge(ack(original))
        XCTAssertTrue(try XCTUnwrap(reopened.load()).pending.isEmpty)
        XCTAssertEqual(try status(reopened, a), "done")
        authority.verified(vineyardId: scope.vineyardId, access: VineyardOperationalAccess(legacyCanEnter: true, canWrite: true), explicitlyWritable: true)
        let resumed = try reopened.setStatus(b, status: "skipped")
        XCTAssertEqual(try reopened.load()?.pending, [resumed])
        XCTAssertEqual(try status(reopened, a), "done")
    }

    @MainActor func testHeldCreationLeavesNoJournalDocument() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        authority.bind(userId: UUID(uuidString: scope.ownerId)!)
        _ = authority.handleServerCode("VT_READ_ONLY", vineyardId: scope.vineyardId)
        let j = try TripOccurrenceJournal(scope: scope, directory: dir, authority: authority)
        XCTAssertThrowsError(try j.prepareCreation(trip: .object(["id": .string(scope.tripId), "vineyard_id": .string(scope.vineyardId)]), coverage: fixture())) { XCTAssertTrue($0 is VineyardWriteAuthority.Restricted) }
        XCTAssertNil(try j.load())
    }

    @MainActor func testBlockQualifiedPlannerKeepsFourSameLabelPassesAndSubset() throws {
        let vineyard = try XCTUnwrap(UUID(uuidString: scope.vineyardId))
        let rows = [PaddockRow(number: 38, startPoint: .init(latitude: 0, longitude: 0), endPoint: .init(latitude: 0, longitude: 1)),
                    PaddockRow(number: 39, startPoint: .init(latitude: 1, longitude: 0), endPoint: .init(latitude: 1, longitude: 1))]
        let blocks = [Paddock(vineyardId: vineyard, name: "A", rows: rows), Paddock(vineyardId: vineyard, name: "B", rows: rows)]
        let choices = TripOccurrencePlanner.candidates(blocks).filter { $0.label == 38.5 }
        XCTAssertEqual(choices.count, 2); XCTAssertEqual(Set(choices.map(\.id)).count, 2)
        let planned = TripOccurrencePlanner.plan(choices, pattern: .upAndBack, startKey: choices[1].id, higherFirst: true)
        XCTAssertEqual(planned.map(\.blockId), [blocks[1].id, blocks[1].id, blocks[0].id, blocks[0].id])
        let d = try TripOccurrenceCoverage.requireDocument(TripOccurrencePlanner.commit(planned, vineyardId: vineyard))
        XCTAssertEqual(Set(d.activeOrder).count, 4); XCTAssertEqual(d.items.map(\.passOrdinal), [1,2,1,2])
        XCTAssertEqual(d.items.map(\.pathNumber), [38.5,38.5,38.5,38.5])
        XCTAssertEqual(TripOccurrencePlanner.candidates([blocks[0]]).filter { $0.label == 38.5 }.count, 1)
        XCTAssertEqual(TripOccurrencePlanner.candidates(blocks).filter { $0.label == 38.5 }, choices)
    }

    @MainActor func testOfflineCreateActivationRetainsIDsThroughFileRecreationAndTripReload() throws {
        let vineyard = try XCTUnwrap(UUID(uuidString: scope.vineyardId))
        let candidates = [TripOccurrencePlanner.Candidate(vineyardId: vineyard, blockId: UUID(), blockName: "A", label: 38.5, rows: []),
                          TripOccurrencePlanner.Candidate(vineyardId: vineyard, blockId: UUID(), blockName: "B", label: 38.5, rows: [])]
        let raw = try TripOccurrencePlanner.commit(TripOccurrencePlanner.plan(candidates, pattern: .upAndBack, startKey: candidates[0].id, higherFirst: true), vineyardId: vineyard)
        let initial = try TripOccurrenceCoverage.requireDocument(raw)
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var j = try TripOccurrenceJournal(scope: scope, directory: dir)
        let metadata: TripOccurrenceCoverage.JSON = .object(["id": .string(scope.tripId), "vineyard_id": .string(scope.vineyardId), "is_active": .bool(false), "trip_title": .string("Kept title")])
        let create = try j.prepareCreation(trip: metadata, coverage: raw)
        let activate = try j.activate(.object(["startTime": .string("2026-10-14T08:00:00Z"), "startEngineHours": .number(123.5)]))
        j = try TripOccurrenceJournal(scope: scope, directory: dir)
        XCTAssertEqual(try j.load()?.pending.map(\.params), [create.params, activate.params])
        XCTAssertTrue(try j.canOperate(XCTUnwrap(j.load())))
        try j.acknowledge(ack(create)); try j.acknowledge(ack(activate))
        var trip = Trip(id: try XCTUnwrap(UUID(uuidString: scope.tripId)), vineyardId: vineyard, paddockName: "A, B", isActive: true)
        trip = try trip.withOccurrenceProjection(XCTUnwrap(j.load()).projected)
        let restored = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip))
        XCTAssertEqual(restored.occurrenceDocument?.activeOrder, initial.activeOrder)
        XCTAssertTrue(restored.completedPaths.isEmpty); XCTAssertTrue(restored.skippedPaths.isEmpty)
        XCTAssertEqual(try j.load()?.history.first?.params[occurrence: "p_trip"], metadata)
    }

    @MainActor func testOfflineLifecycleActionsUndoAndFinalReviewBeforeAnyReceipt() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var j = try TripOccurrenceJournal(scope: scope, directory: dir)
        let create = try j.prepareCreation(trip: .object(["id": .string(scope.tripId), "vineyard_id": .string(scope.vineyardId), "is_active": .bool(false)]), coverage: fixture(otherBlock: true))
        XCTAssertFalse(try j.canOperate(XCTUnwrap(j.load())))
        let activate = try j.activate(.object(["startTime": .string("2026-10-14T08:00:00Z")]))
        let done = try j.setStatus(a, status: "done"); let skip = try j.setStatus(a, status: "skipped")
        j = try TripOccurrenceJournal(scope: scope, directory: dir)
        XCTAssertEqual(try j.undoTarget()?.id, skip.id)
        let undo = try j.undo(skip.id); let other = try j.setStatus(b, status: "skipped"); let otherDone = try j.setStatus(b, status: "done")
        let final = try j.finalize(.object(["endTime": .string("2026-10-14T09:00:00Z")]))
        let ordered = [create, activate, done, skip, undo, other, otherDone, final]
        XCTAssertEqual(try j.load()?.pending.map(\.params), ordered.map(\.params))
        XCTAssertFalse(try j.canOperate(XCTUnwrap(j.load()))); XCTAssertNil(try j.undoTarget())
        XCTAssertThrowsError(try j.setStatus(a, status: "incomplete"))
        for operation in ordered {
            try j.acknowledge(ack(operation)); try j.acknowledge(ack(create))
            XCTAssertEqual(try status(j, a), "done"); XCTAssertEqual(try status(j, b), "done")
        }
        XCTAssertTrue(try XCTUnwrap(j.load()).pending.isEmpty); XCTAssertEqual(try j.load()?.serverActive, false)
    }

    @MainActor func testSnapshotWithoutDurableActivationRequiresRecovery() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = try TripOccurrenceJournal(scope: scope, directory: dir)
        let raw = try fixture(); try j.initialize(raw, requiresRecovery: true)
        XCTAssertFalse(try j.canOperate(XCTUnwrap(j.load())))
        XCTAssertThrowsError(try j.setStatus(a, status: "done"))
        try j.recover(.object(["contract": .string("vinetrack.occurrence-recovery"), "schemaVersion": .number(1),
            "tripId": .string(scope.tripId), "vineyardId": .string(scope.vineyardId), "coverage": raw,
            "isActive": .bool(true), "reversibleOperations": .array([]), "receipts": .array([])]))
        XCTAssertTrue(try j.canOperate(XCTUnwrap(j.load()))); try j.setStatus(a, status: "done")
        XCTAssertEqual(try status(j, a), "done"); XCTAssertEqual(try status(j, b), "incomplete")
    }

    @MainActor func testHeldLocalActivationCannotBeBypassed() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = try TripOccurrenceJournal(scope: scope, directory: dir)
        try j.prepareCreation(trip: .object(["id": .string(scope.tripId), "vineyard_id": .string(scope.vineyardId), "is_active": .bool(false)]), coverage: fixture())
        try j.activate(.object(["startTime": .string("2026-10-14T08:00:00Z")]))
        let done = try j.setStatus(a, status: "done"); try j.hold("OCCURRENCE_REVISION_CONFLICT")
        XCTAssertFalse(try j.canOperate(XCTUnwrap(j.load()))); XCTAssertNil(try j.undoTarget())
        XCTAssertThrowsError(try j.undo(done.id)); XCTAssertThrowsError(try j.finalize(.object([:])))
        XCTAssertEqual(try j.load()?.pending.last?.params, done.params)
    }

    @MainActor func testLegacyRowIdentityRemainsManualOnlyAcrossCacheEncoding() throws {
        let raw = Data("{\"number\":38,\"decimalNumber\":38.25,\"startPoint\":{\"latitude\":-33.4,\"longitude\":149.1},\"endPoint\":{\"latitude\":-33.399,\"longitude\":149.1}}".utf8)
        let row = try JSONDecoder().decode(PaddockRow.self, from: raw)
        let reloaded = try JSONDecoder().decode(PaddockRow.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(row.id, reloaded.id); XCTAssertFalse(reloaded.hasStoredIdentity)
        XCTAssertEqual(reloaded.calculationRowNumber, 38.25)
        let candidate = TripOccurrencePlanner.Candidate(vineyardId: try XCTUnwrap(UUID(uuidString: scope.vineyardId)), blockId: UUID(), blockName: "X", label: 38.75, rows: [reloaded])
        let coverage = try TripOccurrencePlanner.commit([candidate], vineyardId: candidate.vineyardId)
        guard case .array(let items) = coverage[occurrence: "items"], let ref = items.first?[occurrence: "physicalPathRef"] else { return XCTFail("Reference missing") }
        XCTAssertEqual(ref[occurrence: "rowIds"], .array([]))
        XCTAssertEqual(ref[occurrence: "geometryRevision"], .string("unresolved"))
        XCTAssertEqual(ref[occurrence: "candidateRowIds"], .array([.string(row.id.uuidString.lowercased())]))
    }

    @MainActor func testReplacementRetiresDoneEvidenceWithoutInheritance() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let j = try journal(dir); try j.setStatus(a, status: "done"); try j.reorder([b,a])
        let candidate = TripOccurrencePlanner.Candidate(vineyardId: try XCTUnwrap(UUID(uuidString: scope.vineyardId)), blockId: UUID(), blockName: "X", label: 38.5, rows: [])
        let raw = try TripOccurrencePlanner.commit([candidate], vineyardId: candidate.vineyardId)
        guard case .array(let items) = raw[occurrence: "items"], let item = items.first,
              let newId = item[occurrence: "occurrenceId"]?.occurrenceString else { return XCTFail("New item missing") }
        try j.replaceOccurrence(a, newItem: item)
        let d = try TripOccurrenceCoverage.requireDocument(XCTUnwrap(j.load()).projected)
        XCTAssertEqual(d.activeOrder, [b,newId]); XCTAssertEqual(d.retired, [a])
        XCTAssertEqual(d.states[a]?.status, "done"); XCTAssertEqual(d.states[newId]?.status, "incomplete"); XCTAssertEqual(d.states[b]?.status, "incomplete")
        XCTAssertThrowsError(try j.replaceOccurrence(b, newItem: item))
    }

    @MainActor func testSingleOccurrenceCreationHasNoNumericNextFallback() throws {
        let vineyard = try XCTUnwrap(UUID(uuidString: scope.vineyardId))
        let candidate = TripOccurrencePlanner.Candidate(vineyardId: vineyard, blockId: UUID(), blockName: "X", label: 38.5, rows: [])
        let raw = try TripOccurrencePlanner.commit([candidate], vineyardId: vineyard)
        var trip = Trip(vineyardId: vineyard, paddockName: "X", currentRowNumber: 38.5, nextRowNumber: 38.5, rowSequence: [38.5])
        trip.occurrenceCoverage = raw
        let payload = BackendTrip.upsert(from: trip, createdBy: nil, clientUpdatedAt: trip.startTime)
        XCTAssertNil(payload.nextRowNumber)
        XCTAssertEqual(payload.occurrenceCoverage, raw)
    }

    @MainActor func testPlannerRejectsCrossVineyardCommit() throws {
        let candidate = TripOccurrencePlanner.Candidate(vineyardId: UUID(), blockId: UUID(), blockName: "X", label: 38.5, rows: [])
        XCTAssertThrowsError(try TripOccurrencePlanner.commit([candidate], vineyardId: UUID()))
    }

    @MainActor func testADoneLeavesBIncomplete() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        try j.setStatus(a,status:"done"); XCTAssertEqual(try status(j,a),"done"); XCTAssertEqual(try status(j,b),"incomplete")
    }
    @MainActor func testBDoneLeavesAIncomplete() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        try j.setStatus(b,status:"done"); XCTAssertEqual(try status(j,a),"incomplete"); XCTAssertEqual(try status(j,b),"done")
    }
    @MainActor func testDoneSkipAndUndoRemainIndependent() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        let op=try j.setStatus(a,status:"done"); try j.setStatus(b,status:"skipped"); try j.undo(op.id)
        XCTAssertEqual(try status(j,a),"incomplete"); XCTAssertEqual(try status(j,b),"skipped")
    }
    @MainActor func testSkipToDoneChangesOnlySelectedOccurrence() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        try j.select(b); try j.setStatus(b,status:"skipped"); try j.setStatus(b,status:"done")
        XCTAssertEqual(try status(j,a),"incomplete"); XCTAssertEqual(try status(j,b),"done")
    }
    @MainActor func testReorderPreservesIDsAndStates() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        try j.setStatus(a,status:"done"); try j.reorder([b,a]); let state=try XCTUnwrap(j.load())
        XCTAssertEqual(try TripOccurrenceCoverage.requireDocument(state.projected).activeOrder,[b,a])
        XCTAssertEqual(try status(j,a),"done"); XCTAssertEqual(try status(j,b),"incomplete")
    }
    @MainActor func testFileRecreationDoneSkipUndoRestoresDone() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let original=try journal(dir)
        try original.setStatus(a,status:"done"); let skip=try original.setStatus(a,status:"skipped")
        let restored=try journal(dir); try restored.undo(skip.id)
        XCTAssertEqual(try status(restored,a),"done"); XCTAssertEqual(try status(restored,b),"incomplete"); XCTAssertEqual(try restored.load()?.pending.count,3)
    }
    @MainActor func testDelayedDuplicateAckPreservesNewerAction() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        let done=try j.setStatus(a,status:"done"); let skip=try j.setStatus(a,status:"skipped")
        try j.acknowledge(ack(done)); try j.acknowledge(ack(done)); XCTAssertEqual(try status(j,a),"skipped")
        XCTAssertEqual(try j.load()?.pending,[skip]); try j.acknowledge(ack(skip)); try j.acknowledge(ack(done)); XCTAssertEqual(try status(j,a),"skipped")
    }
    @MainActor func testUncertainRetryRetainsExactWireAfterFileRecreation() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        let op=try j.setStatus(a,status:"done"); let restored=try journal(dir)
        XCTAssertEqual(try restored.load()?.pending.first?.params,op.params); XCTAssertEqual(try restored.load()?.pending.first?.id,op.id)
    }
    @MainActor func testRemoteConflictHeldWithoutRebaseOrLoss() throws {
        let dir=directory(); let otherDir=directory(); defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: otherDir) }
        let j=try journal(dir); let op=try j.setStatus(a,status:"done"); let other=try journal(otherDir); try other.setStatus(b,status:"skipped")
        let remote=try XCTUnwrap(other.load()).projected; try j.reconcile(remote)
        XCTAssertNotNil(try j.load()?.heldReason); XCTAssertEqual(try j.load()?.pending.first?.params,op.params)
        XCTAssertEqual(try status(j,a),"done"); XCTAssertEqual(try status(j,b),"incomplete")
    }
    @MainActor func testGuardRejectionRetainsAuthoritativeStateAndActions() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        let op=try j.setStatus(a,status:"done"); try j.hold("OCCURRENCE_UPDATE_REQUIRED")
        XCTAssertTrue(try j.load()?.heldReason?.contains("Update required") == true); XCTAssertEqual(try j.load()?.pending,[op]); XCTAssertEqual(try status(j,a),"done")
    }
    @MainActor func testSameLabelsInDifferentBlocksStaySeparate() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir,otherBlock:true)
        try j.setStatus(a,status:"done"); XCTAssertEqual(try status(j,b),"incomplete")
        let state=try XCTUnwrap(j.load()); XCTAssertEqual(Set(try TripOccurrenceCoverage.requireDocument(state.projected).items.map(\.blockId)).count,2)
    }
    @MainActor func testFailedFileWriteDoesNotPublishAnAction() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        try FileManager.default.removeItem(at: dir)
        XCTAssertThrowsError(try j.setStatus(a,status:"done"))
    }
    @MainActor func testTripBackendRoundTripAndFutureVersionNeverUseNumericCoverage() throws {
        let raw=try fixture(); let trip=Trip(vineyardId:UUID(uuidString:scope.vineyardId)!,rowSequence:[38.5,38.5],completedPaths:[38.5],occurrenceCoverage:raw)
        let restored=try JSONDecoder().decode(Trip.self,from:JSONEncoder().encode(trip)); XCTAssertEqual(restored.occurrenceCoverage,raw)
        let payload=BackendTrip.upsert(from:trip,createdBy:nil,clientUpdatedAt:Date())
        let encoded=try JSONEncoder().encode(payload); let backend=try JSONDecoder().decode(BackendTrip.self,from:encoded)
        XCTAssertEqual(backend.toTrip().occurrenceCoverage,raw)
        XCTAssertEqual(RowCompletionDeriver.results(for:trip).filter { $0.status == .complete }.count,0)
        var fields=try XCTUnwrap(raw.occurrenceObject); fields["schemaVersion"] = .number(99)
        var future=trip; future.occurrenceCoverage = .object(fields)
        XCTAssertEqual(future.coverageBasis,.updateRequired); XCTAssertTrue(RowCompletionDeriver.results(for:future).isEmpty)
        var legacy=trip; legacy.occurrenceCoverage=nil; XCTAssertEqual(RowCompletionDeriver.results(for:legacy).filter { $0.status == .complete }.count,2)
    }
    @MainActor private func recovery(_ journal: TripOccurrenceJournal, _ op: TripOccurrenceJournal.Operation, receipt: Bool = false) throws -> TripOccurrenceCoverage.JSON {
        let state = try XCTUnwrap(journal.load()); let id = try XCTUnwrap(op.action[occurrence:"occurrenceId"]?.occurrenceString)
        let row: TripOccurrenceCoverage.JSON = .object(["operationId":.string(op.id),"tripId":.string(scope.tripId),"actorId":.string(scope.ownerId),
            "request":.object(["tripId":.string(scope.tripId),"expectedRevision":op.params[occurrence:"p_expected_revision"]!,"expectedPlanRevision":op.params[occurrence:"p_expected_plan_revision"]!,"action":op.action]),
            "result":ack(op),"previousState":op.before[occurrence:"states"]![occurrence:id]!,"resultingState":op.after[occurrence:"states"]![occurrence:id]!])
        return .object(["contract":.string("vinetrack.occurrence-recovery"),"schemaVersion":.number(1),"tripId":.string(scope.tripId),"vineyardId":.string(scope.vineyardId),
            "isActive":.bool(true),"coverage":state.projected,"reversibleOperations":.array([row]),"receipts":.array(receipt ? [row] : [])])
    }
    @MainActor func testReinstallRecoversActualUndoFromServerLedger() throws {
        let dir=directory(); let other=directory(); defer { try? FileManager.default.removeItem(at:dir); try? FileManager.default.removeItem(at:other) }
        let server=try journal(dir); try server.setStatus(a,status:"done"); let skip=try server.setStatus(a,status:"skipped")
        let restored=try TripOccurrenceJournal(scope:scope,directory:other); try restored.recover(recovery(server,skip))
        XCTAssertEqual(try restored.undoTarget()?.id,skip.id); try restored.undo(skip.id)
        XCTAssertEqual(try status(restored,a),"done"); XCTAssertEqual(try status(restored,b),"incomplete")
    }
    @MainActor func testUncertainAcceptedActionRecoveredByExactReceipt() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at:dir) }; let j=try journal(dir)
        let op=try j.setStatus(a,status:"done"); try j.recover(recovery(j,op,receipt:true))
        XCTAssertTrue(try j.load()?.pending.isEmpty == true); XCTAssertEqual(try j.undoTarget()?.id,op.id)
    }
    @MainActor func testUnverifiedReceiptCannotClearPendingWork() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at:dir) }; let j=try journal(dir)
        let op=try j.setStatus(a,status:"done"); var response=try XCTUnwrap(recovery(j,op,receipt:true).occurrenceObject)
        guard case .array(let receipts)=response["receipts"], var row=receipts.first?.occurrenceObject else { return XCTFail("Missing receipt") }
        row["actorId"] = .string("99999999-9999-4999-8999-999999999999"); response["receipts"] = .array([.object(row)])
        XCTAssertThrowsError(try j.recover(.object(response))); XCTAssertEqual(try j.load()?.pending,[op])
    }
    @MainActor func testLostCreateAndActivationResponsesRecoverExactReceiptsWithoutDuplicateOperations() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try TripOccurrenceJournal(scope: scope, directory: dir)
        let metadata: TripOccurrenceCoverage.JSON = .object(["id": .string(scope.tripId), "vineyard_id": .string(scope.vineyardId), "is_active": .bool(false)])
        let create = try journal.prepareCreation(trip: metadata, coverage: fixture())
        let start: TripOccurrenceCoverage.JSON = .object(["startTime": .string("2026-10-29T02:07:00Z")])
        let activation = try journal.activate(start)
        XCTAssertThrowsError(try journal.activate(start))
        let reopened = try TripOccurrenceJournal(scope: scope, directory: dir)
        let response: TripOccurrenceCoverage.JSON = .object([
            "contract": .string("vinetrack.occurrence-recovery"), "schemaVersion": .number(1),
            "tripId": .string(scope.tripId), "vineyardId": .string(scope.vineyardId),
            "coverage": activation.after, "isActive": .bool(true), "reversibleOperations": .array([]),
            "receipts": .array([
                .object(["operationId": .string(create.id), "actorId": .string(scope.ownerId),
                    "request": .object(["kind": .string("create"), "trip": metadata, "coverage": create.after]), "result": ack(create)]),
                .object(["operationId": .string(activation.id), "actorId": .string(scope.ownerId),
                    "request": .object(["kind": .string("activate"), "tripId": .string(scope.tripId),
                        "expectedRevision": activation.params[occurrence: "p_expected_revision"]!,
                        "expectedPlanRevision": activation.params[occurrence: "p_expected_plan_revision"]!, "start": start]), "result": ack(activation)])
            ])
        ])
        try reopened.recover(response)
        let recovered = try XCTUnwrap(reopened.load())
        XCTAssertTrue(recovered.pending.isEmpty)
        XCTAssertEqual(recovered.creationConfirmed, true); XCTAssertEqual(recovered.serverActive, true)
        XCTAssertEqual(recovered.history.map(\.id), [create.id, activation.id])
        XCTAssertEqual(recovered.acknowledged, activation.after)
        XCTAssertTrue(reopened.canOperate(recovered))
        try reopened.recover(response)
        XCTAssertEqual(try reopened.load(), recovered)
        XCTAssertThrowsError(try reopened.activate(start))
        XCTAssertEqual(try reopened.load(), recovered)
    }

    @MainActor func testCreationActivationNeedExactDurableAcknowledgement() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at:dir) }; let j=try TripOccurrenceJournal(scope:scope,directory:dir)
        let metadata: TripOccurrenceCoverage.JSON = .object(["id":.string(scope.tripId),"vineyard_id":.string(scope.vineyardId),"is_active":.bool(false),"trip_title":.string("Keep this"),"seeding_details":.object(["note":.string("retain")])])
        let create=try j.prepareCreation(trip:metadata,coverage:fixture()); XCTAssertEqual(create.params[occurrence:"p_trip"],metadata)
        XCTAssertThrowsError(try j.setStatus(a,status:"done")); XCTAssertEqual(try j.load()?.creationConfirmed,false)
        try j.acknowledge(ack(create)); let activation=try j.activate(.object(["startTime":.string("2026-10-14T08:00:00Z")]))
        XCTAssertTrue(try j.canOperate(XCTUnwrap(j.load()))); try j.acknowledge(ack(activation)); try j.setStatus(a,status:"done")
        XCTAssertEqual(try status(j,a),"done")
    }
    @MainActor func testFinalisationFreezesExactReviewAndPendingOrder() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at:dir) }; let j=try journal(dir)
        let done=try j.setStatus(a,status:"done"); let skip=try j.setStatus(b,status:"skipped")
        let final=try j.finalize(.object(["endTime":.string("2026-10-14T09:00:00Z")]))
        XCTAssertEqual(try j.load()?.pending.map(\.id),[done.id,skip.id,final.id])
        XCTAssertEqual(final.params[occurrence:"p_reviewed_states"],skip.after[occurrence:"states"])
        XCTAssertThrowsError(try j.setStatus(a,status:"incomplete"))
        try j.acknowledge(ack(done)); try j.acknowledge(ack(skip)); try j.acknowledge(ack(final))
        XCTAssertEqual(try j.load()?.serverActive,false); XCTAssertEqual(try status(j,a),"done"); XCTAssertEqual(try status(j,b),"skipped")
    }
    @MainActor func testSharedPostgresTranscriptSurvivesSwiftRecoveryUndoAndFinalReload() throws {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"occurrence-recovery-postgres",withExtension:"json"))
        let root=try JSONDecoder().decode(TripOccurrenceCoverage.JSON.self,from:Data(contentsOf:url))
        guard case .array(let fixtures)=root[occurrence:"fixtures"] else { return XCTFail("Shared PostgreSQL transcript missing") }
        XCTAssertEqual(fixtures.count,2)
        for fixture in fixtures {
            let decoder=JSONDecoder()
            let fixtureScope=try decoder.decode(TripOccurrenceJournal.Scope.self,from:JSONEncoder().encode(fixture[occurrence:"scope"]!))
            let dir=directory(); defer { try? FileManager.default.removeItem(at:dir) }
            let j=try TripOccurrenceJournal(scope:fixtureScope,directory:dir); try j.recover(fixture[occurrence:"recovery"]!)
            let current=try TripOccurrenceCoverage.requireDocument(XCTUnwrap(j.load()).projected)
            XCTAssertEqual(current.items.map { current.states[$0.occurrenceId]?.status },["skipped","incomplete"])
            let operation=try XCTUnwrap(j.undoTarget()); try j.undo(operation.id)
            let local=try TripOccurrenceCoverage.requireDocument(XCTUnwrap(j.load()).projected)
            let expected=try TripOccurrenceCoverage.requireDocument(fixture[occurrence:"undoResult"]![occurrence:"coverage"]!)
            XCTAssertEqual(local.items,expected.items); XCTAssertEqual(local.activeOrder,expected.activeOrder)
            XCTAssertEqual(local.items.map { local.states[$0.occurrenceId]?.status },expected.items.map { expected.states[$0.occurrenceId]?.status })
            decoder.dateDecodingStrategy = .custom { decoder in
                let value=try decoder.singleValueContainer().decode(String.self)
                let fractional=ISO8601DateFormatter(); fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
                if let date=fractional.date(from:value) ?? ISO8601DateFormatter().date(from:value) { return date }
                throw TripOccurrenceCoverage.Failure.invalidAction
            }
            let backend=try decoder.decode(BackendTrip.self,from:JSONEncoder().encode(fixture[occurrence:"backendTrip"]!))
            let trip=backend.toTrip(); let result=RowCompletionDeriver.results(for:trip)
            XCTAssertEqual(result.map(\.occurrenceState),["done","skipped"])
            XCTAssertEqual(Set(result.map(\.id)).count,2); XCTAssertFalse(trip.isActive); XCTAssertTrue(trip.completedPaths.isEmpty)
        }
    }
    @MainActor func testV2RowsRetainPassIdentityAndDisplayContext() throws {
        let raw = """
        {"rowNumber":38.5,"blockName":"Block X","status":"Complete","source":"manual","tank":null,"rowIdentity":"\(a)","occurrenceId":"\(a)","blockId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","planId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","passOrdinal":1,"state":"done","isRetired":false,"tankSessionIds":[],"lastOperationId":null}
        """
        let row=try JSONDecoder().decode(SprayReportPayloadV1.Row.self,from:Data(raw.utf8))
        XCTAssertEqual(row.occurrenceId,a); XCTAssertEqual(row.state,"done"); XCTAssertEqual(row.displayLabel,"Block X · 38.5 · Pass 1")
        let restored=try JSONDecoder().decode(SprayReportPayloadV1.Row.self,from:JSONEncoder().encode(row))
        XCTAssertEqual(restored,row)
    }
    @MainActor func testUnknownFieldsSurviveJournalProjection() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        try j.setStatus(a,status:"done"); XCTAssertEqual(try j.load()?.projected[occurrence:"extension"],try fixture()[occurrence:"extension"])
    }
    @MainActor func testBackendUpgradeRetriesOriginalHeldCreateWithoutChangingFrozenIDs() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try TripOccurrenceJournal(scope: scope, directory: dir)
        let frozen = try fixture()
        let trip: TripOccurrenceCoverage.JSON = .object([
            "id": .string(scope.tripId),
            "vineyard_id": .string(scope.vineyardId),
            "is_active": .bool(false)
        ])
        let create = try journal.prepareCreation(trip: trip, coverage: frozen)
        let activation = try journal.activate(.object([
            "startTime": .string("2026-10-29T02:07:00Z")
        ]))
        try journal.hold("OCCURRENCE_SYNC_UNAVAILABLE")
        let retained = try XCTUnwrap(journal.load())
        XCTAssertNotNil(retained.heldReason)
        try journal.releaseHeldOriginalCreationAfterVerifiedServerAbsence(
            expectedCoverage: frozen
        )
        let retried = try XCTUnwrap(journal.load())
        XCTAssertNil(retried.heldReason)
        XCTAssertEqual(retried.pending, [create, activation])
        XCTAssertEqual(retried.history.map(\.id), retained.history.map(\.id))
        XCTAssertEqual(retried.acknowledged, frozen)
        XCTAssertEqual(retried.creationConfirmed, false)
        XCTAssertEqual(retried.serverActive, false)
    }

    @MainActor func testBackendUpgradeRefusesChangedLocalCoverageAndKeepsHold() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try TripOccurrenceJournal(scope: scope, directory: dir)
        let original = try fixture()
        let trip: TripOccurrenceCoverage.JSON = .object([
            "id": .string(scope.tripId),
            "vineyard_id": .string(scope.vineyardId)
        ])
        _ = try journal.prepareCreation(trip: trip, coverage: original)
        _ = try journal.activate(.object([
            "startTime": .string("2026-10-29T02:07:00Z")
        ]))
        try journal.hold("OCCURRENCE_CONFLICT")
        let before = try XCTUnwrap(journal.load())
        XCTAssertThrowsError(try journal.releaseHeldOriginalCreationAfterVerifiedServerAbsence(
            expectedCoverage: fixture(otherBlock: true)
        ))
        XCTAssertEqual(try journal.load(), before)
    }

}
