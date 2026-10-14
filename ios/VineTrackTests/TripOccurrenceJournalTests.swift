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
    @MainActor func testUnknownFieldsSurviveJournalProjection() throws {
        let dir=directory(); defer { try? FileManager.default.removeItem(at: dir) }; let j=try journal(dir)
        try j.setStatus(a,status:"done"); XCTAssertEqual(try j.load()?.projected[occurrence:"extension"],try fixture()[occurrence:"extension"])
    }
}
