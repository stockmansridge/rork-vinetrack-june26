import Foundation
import XCTest
@testable import VineTrack

final class SprayPlanningAttemptTests: XCTestCase {
    typealias W = SprayPlanningProtocol
    private let scope = W.Scope(actorId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", vineyardId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", incarnation: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
    private let record = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    private let revision = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    private let digest = String(repeating: "a", count: 64)
    private func raw<T: Encodable>(_ value: T) throws -> W.JSON { try JSONDecoder().decode(W.JSON.self, from: JSONEncoder().encode(value)) }
    private func request(configuration: SprayPassConfiguration = .standardPass, method: SprayPlanningMethod = .byArea,
                         specification: SprayFullTankSpecification = .targetArea, kind: W.Kind = .save) throws -> W.Request {
        let intent = SprayPlanningIntent(configuration: configuration, method: method, fullTankSpecification: specification,
            intendedTankLitres: 600, targetAreaHa: 1, calibratedLitresPerHectare: 600,
            inputProvenance: .init(tankText: "600,00", areaText: "1", rateText: "600", volumeUnit: "L", areaUnit: "ha", rateAreaUnit: "ha", countryCode: "AU"))
        let resolution = try XCTUnwrap(intent.resolve(selectedAreaHa: 1, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 1200))
        let bound = [.bind, .start, .tank].contains(kind)
        let trip = [.start, .tank].contains(kind) ? "ffffffff-ffff-4fff-8fff-ffffffffffff" : nil
        let snapshot = W.Snapshot(recordId: record, tripId: trip, recipeRevisionId: revision,
            expectedPreviousRevisionId: kind == .save ? nil : revision, expectedRecipeDigest: kind == .save ? nil : digest,
            routeRevisionId: bound ? "11111111-1111-4111-8111-111111111111" : nil,
            tankSessionId: kind == .tank ? "original-text-session" : nil,
            actualUseId: kind == .tank ? "22222222-2222-4222-8222-222222222222" : nil,
            planningInputs: try raw(intent), frozenOutputs: try raw(resolution),
            chemicalLines: .array([.object(["lineId": .string("original-line"), "rateBasis": .string("per_100_litres"), "quantity": .number(1.5), "unit": .string("L"), "labelPermission": .string("unknown")])]),
            equipment: .object(["id": .string("original-equipment")]), geometry: .object(["frozen": .bool(true)]),
            route: bound ? .object(["wholePasses": .array([])]) : nil, originalRecord: .object(["id": .string(record), "notes": .string("retain")]),
            originalTrip: trip.map { .object(["id": .string($0)]) }, reviewedActuals: kind == .tank ? .object(["water": .number(600)]) : nil,
            dependencies: .object([:]))
        return W.Request(scope: scope, kind: kind, snapshot: snapshot)
    }
    private func receipt(_ r: W.Request, phase: W.Phase? = nil) -> W.Receipt {
        let s = r.snapshot
        return .init(contract: W.contract, schemaVersion: 1, operationId: r.operationId, actorId: r.actorId, vineyardId: r.vineyardId,
            request: r, digestAlgorithm: W.digestAlgorithm, canonicalRequestSHA256: digest, recipeSHA256: digest,
            serverRevision: 1, acceptedAt: "2026-10-15T10:00:00Z", result: .init(recordId: s.recordId, tripId: s.tripId,
                recipeRevisionId: s.recipeRevisionId, routeRevisionId: s.routeRevisionId, tankSessionId: s.tankSessionId,
                actualUseId: s.actualUseId, phase: phase ?? ([.start, .tank].contains(r.kind) ? .active : r.kind == .bind ? .bound : .savedUnbound),
                snapshot: s, establishedEffects: .object([:])))
    }
    @MainActor private func journal(_ root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) throws -> SprayPlanningAttemptJournal {
        try SprayPlanningAttemptJournal(scope: scope, root: root)
    }
    @MainActor func testSixConfigurationVariantsAcrossFiveOperationsPreserveCF2AndEvidence() throws {
        for configuration in SprayPassConfiguration.allCases {
            for variant in 0..<3 {
                for kind in W.Kind.allCases {
                    let r = try request(configuration: configuration, method: variant == 0 ? .byArea : .fullTank,
                        specification: variant == 2 ? .calibratedRate : .targetArea, kind: kind)
                    try W.validate(r); try W.verify(receipt(r), for: r)
                    XCTAssertEqual(r.snapshot.frozenOutputs[occurrence: "concentrationFactor"], .number(2))
                    XCTAssertEqual(try JSONDecoder().decode(W.Request.self, from: JSONEncoder().encode(r)), r)
                }
            }
        }
    }
    @MainActor func testOriginalRequestAndIDsSurviveAtomicFileRecreationWhileUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try request(); let first = try journal(root)
        try first.prepare(r, currentScope: scope); try first.markSent(r.operationId, currentScope: scope)
        let restored = try journal(root); let a = try XCTUnwrap(restored.pending(currentScope: scope).first)
        XCTAssertEqual(a.request, r); XCTAssertEqual(a.stage, .outcomeUnknown)
        XCTAssertEqual(try restored.prepare(r, currentScope: scope).request.operationId, r.operationId)
    }
    @MainActor func testReceiptDurabilityPrecedesRepairAndComplete() throws {
        let j = try journal(); let r = try request(); try j.prepare(r, currentScope: scope)
        try j.accept(receipt(r), currentScope: scope)
        XCTAssertThrowsError(try j.repair(r.operationId, currentScope: scope) { _ in false })
        XCTAssertEqual(try j.load().attempts[0].stage, .receiptVerified)
        var repairs = 0
        try j.repair(r.operationId, currentScope: scope) { _ in repairs += 1; return true }
        try j.repair(r.operationId, currentScope: scope) { _ in repairs += 1; return true }
        XCTAssertEqual(repairs, 1); XCTAssertEqual(try j.load().attempts[0].stage, .complete)
    }
    @MainActor func testStorageFailurePreventsIntentAndTransmission() async throws {
        let j = try SprayPlanningAttemptJournal(scope: scope, root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), beforeWrite: { throw W.Failure.storage })
        let transport = Transport { _, _ in XCTFail("HTTP before durability"); return (500, Data()) }
        let client = SprayPlanningClient(journal: j, transport: transport, currentScope: { self.scope })
        do { try await client.send(request()); XCTFail("Expected storage failure") } catch { }
        XCTAssertTrue(try j.load().attempts.isEmpty)
    }
    @MainActor func testScopeSwitchQuarantinesWithoutReassigningPayload() throws {
        let j = try journal(); let r = try request(); try j.prepare(r, currentScope: scope)
        let other = W.Scope(actorId: scope.actorId, vineyardId: UUID().uuidString.lowercased(), incarnation: scope.incarnation)
        XCTAssertThrowsError(try j.pending(currentScope: other))
        XCTAssertEqual(try j.load().attempts[0].request, r)
        XCTAssertEqual(try j.load().attempts[0].stage, .quarantined)
        XCTAssertThrowsError(try j.accept(receipt(r), currentScope: scope))
    }
    @MainActor func testChangedPayloadUnderSameOperationRejected() throws {
        let j = try journal(); let r = try request(); try j.prepare(r, currentScope: scope)
        let changed = W.Request(scope: scope, kind: .replace, snapshot: r.snapshot, operationId: r.operationId)
        XCTAssertThrowsError(try j.prepare(changed, currentScope: scope))
    }
    @MainActor func testDelayedDuplicateReceiptCannotApplyRepairTwice() throws {
        let j = try journal(); let r = try request(); try j.prepare(r, currentScope: scope)
        try j.accept(receipt(r), currentScope: scope); try j.repair(r.operationId, currentScope: scope) { _ in true }
        let next = try request(kind: .replace); try j.prepare(next, currentScope: scope)
        try j.accept(receipt(r), currentScope: scope)
        XCTAssertEqual(try j.pending(currentScope: scope).map(\.request), [next])
    }
    @MainActor func testUnboundReceiptCannotClaimReadyOrTrip() throws {
        let r = try request(); XCTAssertThrowsError(try W.verify(receipt(r, phase: .ready), for: r))
        try W.verify(receipt(r, phase: .savedUnbound), for: r)
    }
    @MainActor func testWrongRequestReceiptHeldNoSuccess() async throws {
        let r = try request(); let wrong = try JSONEncoder().encode(receipt(try request()))
        var receiptFields = try XCTUnwrap(raw(receipt(r)).occurrenceObject)
        var requestFields = try XCTUnwrap(receiptFields["request"]?.occurrenceObject)
        var snapshotFields = try XCTUnwrap(requestFields["snapshot"]?.occurrenceObject)
        snapshotFields["tripId"] = .null
        requestFields["snapshot"] = .object(snapshotFields); receiptFields["request"] = .object(requestFields)
        let changedNullPresence = try JSONEncoder().encode(W.JSON.object(receiptFields))
        for response in [wrong, changedNullPresence] {
            let j = try journal()
            let t = Transport { rpc, _ in rpc == "get_spray_planning_capability_v1" ? (200, try self.capability(r)) : (200, response) }
            do { try await SprayPlanningClient(journal: j, transport: t, currentScope: { self.scope }).send(r); XCTFail() } catch { }
            XCTAssertEqual(try j.load().attempts[0].stage, .held)
        }
    }
    @MainActor func test409NeverMeansSuccess() async throws {
        let j = try journal(); let r = try request()
        let t = Transport { rpc, _ in rpc == "get_spray_planning_capability_v1" ? (200, try self.capability(r)) : (409, Data()) }
        do { try await SprayPlanningClient(journal: j, transport: t, currentScope: { self.scope }).send(r); XCTFail() } catch { }
        XCTAssertNil(try j.load().attempts[0].receipt); XCTAssertEqual(try j.load().attempts[0].stage, .held)
    }
    @MainActor func testLostResponseRetainsExactOriginalRequestForRecovery() async throws {
        let j = try journal(); let r = try request()
        let t = Transport { rpc, _ in
            if rpc == "get_spray_planning_capability_v1" { return (200, try self.capability(r)) }
            throw URLError(.networkConnectionLost)
        }
        do { try await SprayPlanningClient(journal: j, transport: t, currentScope: { self.scope }).send(r); XCTFail() } catch { }
        XCTAssertEqual(try j.load().attempts[0].stage, .outcomeUnknown)
        XCTAssertEqual(try j.load().attempts[0].request, r)
        let recovery = W.Recovery(contract: W.contract, schemaVersion: 1, actorId: scope.actorId, vineyardId: scope.vineyardId,
            receipts: [receipt(r)], currentState: .object(["newer": .bool(true)]))
        let recover = Transport { _, _ in (200, try JSONEncoder().encode(recovery)) }
        try await SprayPlanningClient(journal: j, transport: recover, currentScope: { self.scope }).recover()
        XCTAssertEqual(try j.load().attempts[0].stage, .receiptVerified)
    }
    @MainActor func testUnavailableCapabilityRetainsIntentWithoutWriteRPC() async throws {
        let j = try journal(); let r = try request(); var calls: [String] = []
        let t = Transport { rpc, _ in calls.append(rpc); return (404, Data()) }
        do { try await SprayPlanningClient(journal: j, transport: t, currentScope: { self.scope }).send(r); XCTFail() } catch { }
        XCTAssertEqual(calls, ["get_spray_planning_capability_v1"])
        XCTAssertEqual(try j.load().attempts[0].stage, .intentDurable)
    }
    @MainActor func testPassSelectionsKeepRepeatedAndBlockQualifiedIdentityWithoutCoverage() throws {
        let vineyard = try XCTUnwrap(UUID(uuidString: scope.vineyardId))
        let a = TripOccurrencePlanner.Candidate(vineyardId: vineyard, blockId: UUID(), blockName: "A", label: 38.5, rows: [])
        let b = TripOccurrencePlanner.Candidate(vineyardId: vineyard, blockId: UUID(), blockName: "B", label: 38.5, rows: [])
        let choices = SprayWorkAreaSelection.choices([a, a, b])
        XCTAssertEqual(Set(choices.map(\.id)).count, 3); XCTAssertEqual(choices.map(\.ordinal), [1, 2, 1])
        let selected = SprayWorkAreaSelection.select(choices[1], configuration: .overRow)
        XCTAssertEqual(selected.travelPassCount, 1); XCTAssertEqual(selected.controllerRowEquivalents, 2)
        XCTAssertTrue(SprayWorkAreaSelection.retained(selected, choices: choices, configuration: .overRow))
        XCTAssertFalse(SprayWorkAreaSelection.retained(selected, choices: choices, configuration: .standardPass))
        XCTAssertFalse(choices[1].hasGeometry)
        XCTAssertNil(selected.physicalEvidence[occurrence: "status"])
    }
    @MainActor func testMissingRecoveryReceiptDoesNotInferAcceptanceFromExistingRecord() async throws {
        let j = try journal(); let r = try request(); try j.prepare(r, currentScope: scope); try j.markSent(r.operationId, currentScope: scope)
        let body = W.Recovery(contract: W.contract, schemaVersion: 1, actorId: scope.actorId, vineyardId: scope.vineyardId,
            receipts: [], currentState: .object(["recordId": .string(record)]))
        try await SprayPlanningClient(journal: j, transport: Transport { _, _ in (200, try JSONEncoder().encode(body)) }, currentScope: { self.scope }).recover()
        XCTAssertEqual(try j.load().attempts[0].stage, .outcomeUnknown)
    }
    @MainActor func testProductionSnapshotBuilderRetainsOriginalTankRecipeWithoutUnboundTrip() throws {
        let source = try request()
        var geometry = SprayApplicationSnapshot(grossAreaHa: 1)
        geometry.planningIntent = try JSONDecoder().decode(SprayPlanningIntent.self, from: JSONEncoder().encode(source.snapshot.planningInputs))
        geometry.planningResolution = try JSONDecoder().decode(SprayPlanningResolution.self, from: JSONEncoder().encode(source.snapshot.frozenOutputs))
        let chemical = SprayChemical(name: "Original label", volumePerTank: 1.5, ratePer100L: 0.25, unit: .litres, rateBasis: .per100Litres)
        let tank = SprayTank(waterVolume: 600, sprayRatePerHa: 600, concentrationFactor: 2, chemicals: [chemical])
        let record = SprayRecord(vineyardId: try XCTUnwrap(UUID(uuidString: scope.vineyardId)), tanks: [tank], notes: "Full original payload", applicationGeometry: geometry)
        let binding = SprayPlanningSnapshotBuilder.Binding(recipeRevisionId: revision, previousRevisionId: nil,
            previousRecipeDigest: nil, routeRevisionId: nil, route: nil, trip: nil, equipment: .object([:]),
            physicalGeometry: .object([:]), dependencies: .object([:]), tankSessionId: nil, actualUseId: nil, reviewedActuals: nil)
        let r = try SprayPlanningSnapshotBuilder.freeze(record, scope: scope, kind: .save, binding: binding)
        XCTAssertEqual(try JSONDecoder().decode(SprayRecord.self, from: JSONEncoder().encode(r.snapshot.originalRecord)), record)
        XCTAssertNil(r.snapshot.tripId); XCTAssertNil(r.snapshot.originalTrip)
        try SprayPlanningSnapshotBuilder.validateTankConfirmation(captured: record, current: record)
        var edited = record; edited.notes = "Newer revision"
        XCTAssertThrowsError(try SprayPlanningSnapshotBuilder.validateTankConfirmation(captured: record, current: edited))
    }
    @MainActor func testPresentationNeverCallsPendingOrUnboundReady() throws {
        let j = try journal(); let r = try request()
        XCTAssertEqual(SprayPlanningPresentation.state(nil), .draft)
        try j.prepare(r, currentScope: scope)
        XCTAssertEqual(SprayPlanningPresentation.state(try j.load().attempts.first), .saveRequested)
        try j.accept(receipt(r), currentScope: scope)
        XCTAssertEqual(SprayPlanningPresentation.state(try j.load().attempts.first), .repairRequired)
        try j.repair(r.operationId, currentScope: scope) { _ in true }
        XCTAssertEqual(SprayPlanningPresentation.state(try j.load().attempts.first), .savedUnbound)
    }
    private func capability(_ r: W.Request) throws -> Data {
        try JSONEncoder().encode(W.Capability(contract: W.contract, schemaVersion: 1, vineyardId: r.vineyardId, enabled: true,
            migrationId: "synthetic", validationSuiteId: "synthetic", digestAlgorithm: W.digestAlgorithm, operations: W.Kind.allCases, occurrenceVersion: 1, tankVersion: 1))
    }
    @MainActor private final class Transport: SprayPlanningTransport {
        let handler: (String, Data) throws -> (Int, Data)
        init(_ handler: @escaping (String, Data) throws -> (Int, Data)) { self.handler = handler }
        func call(_ rpc: String, body: Data) async throws -> (status: Int, data: Data) { let r = try handler(rpc, body); return (r.0, r.1) }
    }
}
