//
//  TripEndServerReplayTests.swift
//  VineTrackTests
//
//  The app's own code, driven by the answers a real PostgREST in front of a real PostgreSQL gave to the
//  Trip End chain. TripEndServerGoldenFixtures.swift records where those answers came from and how to
//  regenerate them. Nothing in this file is a hand-written model of the server.
//
//  Against those exchanges it proves that
//    * the journal accepts every real answer of its own chain, in order, with and without a relaunch;
//    * after lost answers, or on a fresh install, `recover` rebuilds the journal from the server's receipts
//      and carries on to a finished Trip;
//    * the bodies the app builds equal, field for field, the requests the server accepted;
//    * the compare-and-swap URL carries `%2B`, so the server reads the revision it was given;
//    * each real failure answer is classified, held or left unheld exactly as the failure policy says.
//
//  It does not prove the production schema, GoTrue sessions, Spray actuals or the other Trip triggers. That
//  needs the non-production Supabase project.
//
//  A mismatch here is a finding about the app or about the Python model that produced the requests. The
//  assertions are never bent to fit: fix the model (scripts/test-trip-end-http-contract.py), regenerate the
//  fixtures, or fix the app.
//

import Foundation
import XCTest
@testable import VineTrack

private typealias Fixtures = TripEndServerGoldenFixtures
private typealias JSON = TripOccurrenceCoverage.JSON

private let tripUUID = UUID(uuidString: Fixtures.tripId)!
private let vineyardUUID = UUID(uuidString: Fixtures.vineyard)!
private let ownerUUID = UUID(uuidString: Fixtures.owner)!
private let startInstant = isoInstant("2026-10-14T08:00:00Z")
private let endInstant = isoInstant("2026-10-14T09:00:00Z")

private func isoInstant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text) ?? .distantPast
}

// MARK: - Labels

/// The sixteen exchanges of one real chain, in the order the app performs them.
private enum ReplayGolden {
    static let create = "golden: 01 create"
    static let activate = "golden: 02 activate"
    static let recoveryAfterActivate = "golden: 03 recovery after create and activate"
    static let readRow = "golden: 04 read the Trip row"
    static let casPatch = "golden: 05 CAS PATCH tank_sessions"
    static let readBack = "golden: 06 read back tank_sessions"
    static let detailsBefore = "golden: 07 PATCH non-authority fields before the first link"
    static let done1 = "golden: 08 setStatus done, tank 1 linked (manual)"
    static let done2 = "golden: 09 setStatus done, tank 2 linked (manual)"
    static let recoveryMidChain = "golden: 10 recovery mid-chain"
    static let skipped1 = "golden: 11 setStatus skipped (manual)"
    static let skipped2 = "golden: 12 setStatus skipped (endReview)"
    static let finalise = "golden: 13 finalise"
    static let recoveryAfterFinalise = "golden: 14 recovery after finalise"
    static let detailsAfter = "golden: 15 PATCH non-authority fields after finalise"
    static let finalRow = "golden: 16 read the final Trip row"

    /// The seven journal operations, in the order the app queues them.
    static let chain = [create, activate, done1, done2, skipped1, skipped2, finalise]
}

/// Answers the server gave to requests that must NOT succeed.
private enum ReplayEdge {
    static let casUnencodedPlus = "01: CAS PATCH, unencoded + (build 214)"
    static let casEncodedPlus = "01: CAS PATCH, %2B (build 215)"
    static let linkConflict = "02: setStatus with tank links, BEFORE the repair"
    static let openTank = "06: finalise with an open tank"
    static let staleRevision = "07: stale expected revision"
    static let otherVineyard = "07: member of another vineyard"
    static let noToken = "07: no token"
}

// MARK: - Fixture access

private struct ReplayFixtureError: Error, CustomStringConvertible {
    let description: String
}

private func capturedExchange(_ label: String) throws -> TripEndGoldenExchange {
    guard let found = Fixtures.exchanges.first(where: { $0.label == label }) else {
        throw ReplayFixtureError(description: "No golden exchange labelled \(label)")
    }
    return found
}

private func parseJSON(_ text: String) throws -> JSON {
    try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
}

private func capturedRequest(_ label: String) throws -> JSON {
    guard let body = try capturedExchange(label).request else {
        throw ReplayFixtureError(description: "\(label) has no request body")
    }
    return try parseJSON(body)
}

private func capturedAnswer(_ label: String) throws -> JSON {
    try parseJSON(try capturedExchange(label).body)
}

private func tripRow(_ label: String) throws -> JSON {
    guard case .array(let rows) = try capturedAnswer(label), rows.count == 1, let row = rows.first else {
        throw ReplayFixtureError(description: "\(label) did not answer exactly one Trip row")
    }
    return row
}

// MARK: - JSON helpers (file scope: no actor, usable from any closure)

private func jsonMember(_ value: JSON, _ key: String) throws -> JSON {
    guard let found = value[occurrence: key] else {
        throw ReplayFixtureError(description: "missing \"\(key)\" in \(describeJSON(value))")
    }
    return found
}

private func jsonString(_ value: JSON, _ key: String) throws -> String {
    guard case .string(let found) = try jsonMember(value, key) else {
        throw ReplayFixtureError(description: "\"\(key)\" is not a string in \(describeJSON(value))")
    }
    return found
}

private func jsonNumber(_ value: JSON, _ key: String) throws -> Double {
    guard case .number(let found) = try jsonMember(value, key) else {
        throw ReplayFixtureError(description: "\"\(key)\" is not a number in \(describeJSON(value))")
    }
    return found
}

private func jsonStrings(_ value: JSON) -> [String] {
    guard case .array(let items) = value else { return [] }
    return items.compactMap { $0.occurrenceString }
}

/// Replaces every string value and every object key that is a key of `ids`. The captured answers carry the
/// operation ids of the device that was captured; the journal under test mints its own.
private func replacingIds(in value: JSON, using ids: [String: String]) -> JSON {
    switch value {
    case .string(let text):
        return .string(ids[text] ?? text)
    case .array(let items):
        return .array(items.map { replacingIds(in: $0, using: ids) })
    case .object(let fields):
        var mapped: [String: JSON] = [:]
        for (key, inner) in fields { mapped[ids[key] ?? key] = replacingIds(in: inner, using: ids) }
        return .object(mapped)
    case .number, .bool, .null:
        return value
    }
}

private func describeJSON(_ value: JSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "?" }
    return text.count > 200 ? String(text.prefix(200)) + "…" : text
}

private func firstDifferenceBetween(_ left: JSON, _ right: JSON, at path: String = "$") -> String? {
    switch (left, right) {
    case let (.object(a), .object(b)):
        for key in Set(a.keys).union(b.keys).sorted() {
            guard let x = a[key] else {
                return "\(path).\(key) is missing on the left; the right has \(describeJSON(b[key] ?? .null))"
            }
            guard let y = b[key] else {
                return "\(path).\(key) is missing on the right; the left has \(describeJSON(x))"
            }
            if let difference = firstDifferenceBetween(x, y, at: "\(path).\(key)") { return difference }
        }
        return nil
    case let (.array(a), .array(b)):
        if a.count != b.count { return "\(path) has \(a.count) elements on the left and \(b.count) on the right" }
        for (index, pair) in zip(a, b).enumerated() {
            if let difference = firstDifferenceBetween(pair.0, pair.1, at: "\(path)[\(index)]") { return difference }
        }
        return nil
    default:
        return left == right ? nil : "\(path): \(describeJSON(left)) is not \(describeJSON(right))"
    }
}

/// How PostgREST reads a query string: `+` is a space, `%XX` is a byte.
private func formDecoded(_ query: String) -> [String: String] {
    func decode(_ part: Substring) -> String {
        let spaced = String(part).replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
    var result: [String: String] = [:]
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 { result[decode(parts[0])] = decode(parts[1]) }
    }
    return result
}

/// `:` is legal unescaped in a query; Foundation and Python disagree about whether to escape it. Nothing else
/// is normalised, so the `+` / `%2B` difference stays visible.
private func withoutColonEscapes(_ query: String) -> String {
    query.replacingOccurrences(of: "%3A", with: ":", options: .caseInsensitive)
}

private func changingStates(_ coverage: JSON, _ change: ([String: JSON]) -> [String: JSON]) -> JSON {
    guard var fields = coverage.occurrenceObject, let states = fields["states"]?.occurrenceObject else { return coverage }
    var changed: [String: JSON] = [:]
    for (occurrence, state) in states { changed[occurrence] = .object(change(state.occurrenceObject ?? [:])) }
    fields["states"] = .object(changed)
    return .object(fields)
}

private func decodedTankSessions(_ value: JSON) throws -> [TankSession] {
    try JSONDecoder().decode([TankSession].self, from: JSONEncoder().encode(value))
}

// MARK: - A journal that has queued the whole chain

private struct ReplayChain {
    let scope: TripOccurrenceJournal.Scope
    let directory: URL
    let authority: VineyardWriteAuthority
    var journal: TripOccurrenceJournal
    /// Operations the journal under test minted, in queue order.
    var operations: [TripOccurrenceJournal.Operation]
    /// Captured operation id -> the id the journal under test minted for the same step.
    var ids: [String: String]
}

@MainActor
final class TripEndServerReplayTests: XCTestCase {

    /// `serverActive` after each of the seven operations is acknowledged.
    private static let activeAfter: [Bool] = [false, true, true, true, true, true, false]

    // MARK: Plumbing

    private var scope: TripOccurrenceJournal.Scope {
        TripOccurrenceJournal.Scope(ownerId: Fixtures.owner, vineyardId: Fixtures.vineyard, tripId: Fixtures.tripId)
    }

    private func newDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trip-end-replay-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A private authority, so this suite never touches the shared one other suites depend on.
    private func makeAuthority() -> VineyardWriteAuthority {
        let defaults = UserDefaults(suiteName: "trip-end-replay-" + UUID().uuidString)!
        let authority = VineyardWriteAuthority(defaults: defaults)
        authority.bind(userId: ownerUUID)
        return authority
    }

    private func assertSame(_ actual: JSON, _ expected: JSON, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        if let difference = firstDifferenceBetween(actual, expected) {
            XCTFail("\(what): \(difference)", file: file, line: line)
        }
    }

    /// Queues the operation the device queued for this captured exchange, the way the app queues it.
    @discardableResult
    private func queue(_ journal: TripOccurrenceJournal, from label: String) throws -> TripOccurrenceJournal.Operation {
        let exchange = try capturedExchange(label)
        let captured = try capturedRequest(label)
        switch exchange.path {
        case "/rpc/create_trip_with_occurrences_v1":
            return try journal.prepareCreation(trip: jsonMember(captured, "p_trip"),
                                               coverage: jsonMember(captured, "p_coverage"))
        case "/rpc/activate_trip_occurrences_v1":
            return try journal.activate(jsonMember(captured, "p_start"))
        case "/rpc/finalize_trip_occurrences_v1":
            return try journal.finalize(jsonMember(captured, "p_end"))
        case "/rpc/apply_trip_occurrence_action_v1":
            let action = try jsonMember(captured, "p_action")
            XCTAssertEqual(try jsonString(action, "kind"), "setStatus", label)
            let links = jsonStrings(try jsonMember(action, "tankSessionIds"))
            return try journal.setStatus(jsonString(action, "occurrenceId"), status: jsonString(action, "toStatus"),
                                         tankSessionIds: links, source: jsonString(action, "source"))
        default:
            throw ReplayFixtureError(description: "\(label) is not an occurrence operation")
        }
    }

    /// The device queued all seven operations offline. What the app queued must equal, apart from the
    /// operation ids it minted itself, what the server accepted.
    private func buildChain() throws -> ReplayChain {
        let directory = newDirectory()
        let authority = makeAuthority()
        let journal = try TripOccurrenceJournal(scope: scope, directory: directory, authority: authority)
        var operations: [TripOccurrenceJournal.Operation] = []
        var ids: [String: String] = [:]
        for label in ReplayGolden.chain {
            let captured = try capturedRequest(label)
            let operation = try queue(journal, from: label)
            ids[try jsonString(captured, "p_operation_id")] = operation.id
            operations.append(operation)
            assertSame(operation.params, replacingIds(in: captured, using: ids),
                       "\(label): the request the app queued differs from the request the server accepted")
        }
        return ReplayChain(scope: scope, directory: directory, authority: authority,
                           journal: journal, operations: operations, ids: ids)
    }

    private func reopen(_ chain: ReplayChain) throws -> TripOccurrenceJournal {
        try TripOccurrenceJournal(scope: chain.scope, directory: chain.directory, authority: chain.authority)
    }

    /// Acknowledges the real answer of operation `index` and checks everything the app promises about it.
    /// Returns false, after reporting, when the journal held itself.
    private func acknowledgeAnswer(of index: Int, in chain: ReplayChain,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let label = ReplayGolden.chain[index]
        let operation = chain.operations[index]
        let response = replacingIds(in: try capturedAnswer(label), using: chain.ids)
        try chain.journal.acknowledge(response)
        let after = try XCTUnwrap(chain.journal.load(), file: file, line: line)
        if let held = after.heldReason {
            let returned = try jsonMember(response, "coverage")
            XCTFail("\(label): the journal held itself (\(held)). First difference between the coverage the app expected and the one the server returned: \(firstDifferenceBetween(operation.after, returned) ?? "none")",
                    file: file, line: line)
            return false
        }
        XCTAssertEqual(after.pending.map(\.id), chain.operations.dropFirst(index + 1).map(\.id),
                       "operations still pending after \(label)", file: file, line: line)
        XCTAssertEqual(after.acknowledged, operation.after, "acknowledged coverage after \(label)", file: file, line: line)
        XCTAssertEqual(after.serverActive, Self.activeAfter[index], "serverActive after \(label)", file: file, line: line)
        XCTAssertEqual(after.creationConfirmed, true, "creation confirmed after \(label)", file: file, line: line)
        return true
    }

    /// The Trip is finished on the server and in the journal.
    private func assertFinished(_ chain: ReplayChain, file: StaticString = #filePath, line: UInt = #line) throws {
        let final = try XCTUnwrap(chain.journal.load(), file: file, line: line)
        XCTAssertNil(final.heldReason, file: file, line: line)
        XCTAssertTrue(final.pending.isEmpty, "no operation is left to send", file: file, line: line)
        XCTAssertEqual(final.serverActive, false, "the server reports the Trip ended", file: file, line: line)
        XCTAssertEqual(final.creationConfirmed, true, file: file, line: line)
        let finalCoverage = try jsonMember(replacingIds(in: try capturedAnswer(ReplayGolden.finalise), using: chain.ids), "coverage")
        XCTAssertEqual(final.acknowledged, finalCoverage, "the journal holds the coverage the server finalised",
                       file: file, line: line)
        let document = try XCTUnwrap(TripOccurrenceCoverage.read(final.acknowledged), file: file, line: line)
        XCTAssertEqual(document.revision, 6, file: file, line: line)
        XCTAssertEqual(document.count("done"), 2, file: file, line: line)
        XCTAssertEqual(document.count("skipped"), 2, file: file, line: line)
        XCTAssertNil(document.selectedOccurrenceId, file: file, line: line)
        XCTAssertNil(document.plannedCursorId, file: file, line: line)
        XCTAssertFalse(chain.journal.canOperate(final), "an ended Trip accepts no further operation", file: file, line: line)
    }

    // MARK: - Real failure answers

    func testTheBuild214PlusSignFailureIsClassifiedFromTheServersOwnAnswer() async throws {
        let sent = try capturedExchange(ReplayEdge.casUnencodedPlus)
        let failure = TripSyncStageFailure(stage: .tankStagingPatch, tripId: tripUUID,
                                           endpoint: "PATCH rest/v1/trips (tank sessions)",
                                           httpStatus: sent.status, body: Data(sent.body.utf8))
        XCTAssertEqual(failure.httpStatus, 400)
        XCTAssertEqual(failure.postgrestCode, "22007")
        XCTAssertNil(failure.occurrenceCode)
        XCTAssertEqual(failure.reasonCode, "22007")
        XCTAssertEqual(failure.disposition, .nonRetryable)
        XCTAssertTrue(failure.serverMessage?.contains("invalid input syntax for type timestamp with time zone") == true,
                      "the server's own words must reach the Sync screen: \(failure.serverMessage ?? "nil")")
        XCTAssertTrue(failure.technicalDetail.contains("http_status: 400"))
        XCTAssertTrue(failure.technicalDetail.contains("postgrest_code: 22007"))
        XCTAssertTrue(TripSyncStageFailure.isExportSafe(failure.reasonCode))
    }

    func testTheTankLinkConflictIsADeterministicAnswerAndDoesNotHoldTheJournal() async throws {
        let sent = try capturedExchange(ReplayEdge.linkConflict)
        let rejection = OccurrenceRPCFailure.from(httpStatus: sent.status, body: Data(sent.body.utf8))
        XCTAssertEqual(rejection.code, "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertEqual(rejection.httpStatus, 500)
        XCTAssertEqual(rejection.postgrestCode, "40001")
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(for: rejection),
                     "a tank link the server could not match is repairable on the server; it must not lock the journal")
        let failure = TripSyncStageFailure(rejection: rejection, rpc: "apply_trip_occurrence_action_v1",
                                           tripId: tripUUID, operationId: nil, journalHeld: false)
        XCTAssertEqual(failure.stage, .occurrenceAction)
        XCTAssertEqual(failure.disposition, .nonRetryable)
        XCTAssertEqual(failure.reasonCode, "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertTrue(failure.friendlyMessage.contains("OCCURRENCE_TANK_LINK_CONFLICT"))
        XCTAssertTrue(failure.technicalDetail.contains("http_status: 500"))
        XCTAssertTrue(failure.technicalDetail.contains("postgrest_code: 40001"))
    }

    func testFinalisingWithAnOpenTankIsDeterministicAndDoesNotHoldTheJournal() async throws {
        let sent = try capturedExchange(ReplayEdge.openTank)
        let rejection = OccurrenceRPCFailure.from(httpStatus: sent.status, body: Data(sent.body.utf8))
        XCTAssertEqual(rejection.code, "OCCURRENCE_TANK_REVIEW_REQUIRED")
        XCTAssertEqual(rejection.httpStatus, 500)
        XCTAssertEqual(rejection.postgrestCode, "55000")
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(for: rejection))
        let failure = TripSyncStageFailure(rejection: rejection, rpc: "finalize_trip_occurrences_v1",
                                           tripId: tripUUID, operationId: nil, journalHeld: false)
        XCTAssertEqual(failure.stage, .finalize)
        XCTAssertEqual(failure.disposition, .nonRetryable)
        XCTAssertEqual(failure.reasonCode, "OCCURRENCE_TANK_REVIEW_REQUIRED")
    }

    func testARevisionConflictAndAForbiddenTripHoldTheJournalAsAConflict() async throws {
        for (label, code, status, postgrest) in [
            (ReplayEdge.staleRevision, "OCCURRENCE_REVISION_CONFLICT", 500, "40001"),
            (ReplayEdge.otherVineyard, "OCCURRENCE_TRIP_FORBIDDEN", 403, "42501"),
        ] {
            let sent = try capturedExchange(label)
            let rejection = OccurrenceRPCFailure.from(httpStatus: sent.status, body: Data(sent.body.utf8))
            XCTAssertEqual(rejection.code, code, label)
            XCTAssertEqual(rejection.httpStatus, status, label)
            XCTAssertEqual(rejection.postgrestCode, postgrest, label)
            XCTAssertEqual(OccurrenceHoldPolicy.holdReason(for: rejection), "OCCURRENCE_CONFLICT", label)
            let failure = TripSyncStageFailure(rejection: rejection, rpc: "apply_trip_occurrence_action_v1",
                                               tripId: tripUUID, operationId: nil, journalHeld: true)
            XCTAssertEqual(failure.disposition, .held, label)
            XCTAssertEqual(failure.reasonCode, code, label)
        }
    }

    func testAMissingTokenIsRetryableAndNeverHoldsAnything() async throws {
        let sent = try capturedExchange(ReplayEdge.noToken)
        XCTAssertEqual(sent.status, 401)
        let rejection = OccurrenceRPCFailure.from(httpStatus: sent.status, body: Data(sent.body.utf8))
        XCTAssertNil(rejection.code, "an anonymous answer carries no OCCURRENCE token")
        XCTAssertEqual(rejection.postgrestCode, "42501")
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(for: rejection))
        let failure = TripSyncStageFailure(rejection: rejection, rpc: "apply_trip_occurrence_action_v1",
                                           tripId: tripUUID, operationId: nil, journalHeld: false)
        XCTAssertEqual(failure.disposition, .retryable, "signing in again cures a 401; it must not pause the Trip")
        XCTAssertEqual(failure.httpStatus, 401)
    }

    // MARK: - The identity case that caused the incident

    func testTheCapturedChainHasTheIdentityCaseTheIncidentNeeded() async throws {
        let create = try capturedRequest(ReplayGolden.create)
        XCTAssertEqual(try jsonString(try jsonMember(create, "p_trip"), "id"), Fixtures.tripId.uppercased(),
                       "the Trip row id is written in upper case, the RPC ids in lower case")
        let casSessions = try jsonMember(try capturedRequest(ReplayGolden.casPatch), "tank_sessions")
        guard case .array(let rawSessions) = casSessions else {
            throw ReplayFixtureError(description: "tank_sessions is not an array")
        }
        let wire = try rawSessions.map { try jsonString($0, "id") }
        XCTAssertEqual(wire.count, 2)
        for id in wire {
            XCTAssertEqual(id, id.uppercased(), "the app writes tank session ids in upper case on the wire")
            XCTAssertNotEqual(id, id.lowercased(), "a digits-only id could not show the case defect")
        }
        var links: [String] = []
        for label in [ReplayGolden.done1, ReplayGolden.done2] {
            let action = try jsonMember(try capturedRequest(label), "p_action")
            let linked = jsonStrings(try jsonMember(action, "tankSessionIds"))
            links.append(contentsOf: linked)
        }
        XCTAssertEqual(links, wire.map { $0.lowercased() }, "the journal links the lower-case form of each session")
        XCTAssertTrue(Set(wire).isDisjoint(with: Set(links)),
                      "exact text never matches, which is the precondition of OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertEqual(Set(links), TankDependencyVerification.ids(try decodedTankSessions(casSessions)))
        let accepted = try jsonMember(try capturedAnswer(ReplayGolden.done1), "coverage")
        XCTAssertNotNil(TripOccurrenceCoverage.read(accepted), "the server's lower-case links are readable coverage")
    }

    // MARK: - The journal against the real answers

    func testTheJournalAcceptsEveryRealAnswerOfItsOwnChain() async throws {
        let chain = try buildChain()
        for index in ReplayGolden.chain.indices {
            guard try acknowledgeAnswer(of: index, in: chain) else { return }
        }
        try assertFinished(chain)
    }

    func testTheJournalAcceptsEveryRealAnswerAcrossARelaunchBeforeEachOne() async throws {
        var chain = try buildChain()
        for index in ReplayGolden.chain.indices {
            chain.journal = try reopen(chain)
            guard try acknowledgeAnswer(of: index, in: chain) else { return }
        }
        chain.journal = try reopen(chain)
        try assertFinished(chain)
    }

    // MARK: - Recovery after lost answers

    /// The device queued all seven operations. The server accepted the first `accepted` of them, but the
    /// answers never reached the app. `recover` must rebuild from the receipts, and the rest must still go.
    private func recoverAfterLostAnswers(using recovery: String, accepted: Int, serverActive: Bool,
                                         relaunching: Bool) throws {
        var chain = try buildChain()
        if relaunching { chain.journal = try reopen(chain) }
        let response = replacingIds(in: try capturedAnswer(recovery), using: chain.ids)
        try chain.journal.recover(response)
        let recovered = try XCTUnwrap(chain.journal.load())
        if let held = recovered.heldReason {
            XCTFail("\(recovery): recover held the journal (\(held))")
            return
        }
        XCTAssertEqual(recovered.pending.map(\.id), chain.operations.dropFirst(accepted).map(\.id),
                       "\(recovery): exactly the operations the server never saw stay pending")
        XCTAssertEqual(recovered.acknowledged, try jsonMember(response, "coverage"))
        XCTAssertEqual(recovered.serverActive, serverActive)
        XCTAssertEqual(recovered.creationConfirmed, true)
        for index in accepted..<chain.operations.count {
            if relaunching { chain.journal = try reopen(chain) }
            guard try acknowledgeAnswer(of: index, in: chain) else { return }
        }
        if relaunching { chain.journal = try reopen(chain) }
        try assertFinished(chain)
    }

    func testRecoveryAfterLostAnswersToCreateAndActivate() async throws {
        try recoverAfterLostAnswers(using: ReplayGolden.recoveryAfterActivate, accepted: 2,
                                    serverActive: true, relaunching: false)
    }

    func testRecoveryAfterLostAnswersMidChain() async throws {
        try recoverAfterLostAnswers(using: ReplayGolden.recoveryMidChain, accepted: 4,
                                    serverActive: true, relaunching: false)
    }

    func testRecoveryAfterEveryAnswerWasLostIncludingFinalise() async throws {
        try recoverAfterLostAnswers(using: ReplayGolden.recoveryAfterFinalise, accepted: 7,
                                    serverActive: false, relaunching: false)
    }

    func testRecoveryAfterLostAnswersSurvivesARelaunchAtEveryStep() async throws {
        try recoverAfterLostAnswers(using: ReplayGolden.recoveryAfterActivate, accepted: 2,
                                    serverActive: true, relaunching: true)
        try recoverAfterLostAnswers(using: ReplayGolden.recoveryMidChain, accepted: 4,
                                    serverActive: true, relaunching: true)
        try recoverAfterLostAnswers(using: ReplayGolden.recoveryAfterFinalise, accepted: 7,
                                    serverActive: false, relaunching: true)
    }

    // MARK: - Recovery on a fresh install

    func testAFreshInstallRebuildsItsJournalFromTheMidChainRecoveryAnswerAndFinishesTheTrip() async throws {
        let journal = try TripOccurrenceJournal(scope: scope, directory: newDirectory(), authority: makeAuthority())
        let response = try capturedAnswer(ReplayGolden.recoveryMidChain)
        try journal.recover(response)
        let state = try XCTUnwrap(journal.load())
        XCTAssertNil(state.heldReason)
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(state.creationConfirmed, true)
        XCTAssertEqual(state.serverActive, true)
        XCTAssertEqual(state.acknowledged, try jsonMember(response, "coverage"))
        let capturedDone2 = try jsonString(try capturedRequest(ReplayGolden.done2), "p_operation_id")
        XCTAssertEqual(try journal.undoTarget()?.id, capturedDone2,
                       "the last accepted setStatus is still reversible after a reinstall")

        var ids: [String: String] = [:]
        for label in [ReplayGolden.skipped1, ReplayGolden.skipped2, ReplayGolden.finalise] {
            let captured = try capturedRequest(label)
            let operation = try queue(journal, from: label)
            ids[try jsonString(captured, "p_operation_id")] = operation.id
            assertSame(operation.params, replacingIds(in: captured, using: ids),
                       "\(label): the request queued after a reinstall differs from the one the server accepted")
            try journal.acknowledge(replacingIds(in: try capturedAnswer(label), using: ids))
            if let held = try XCTUnwrap(journal.load()).heldReason {
                XCTFail("\(label): the journal held itself after a reinstall (\(held))")
                return
            }
        }
        let final = try XCTUnwrap(journal.load())
        XCTAssertTrue(final.pending.isEmpty)
        XCTAssertEqual(final.serverActive, false)
        let finalCoverage = try jsonMember(replacingIds(in: try capturedAnswer(ReplayGolden.finalise), using: ids), "coverage")
        XCTAssertEqual(final.acknowledged, finalCoverage)
        XCTAssertFalse(journal.canOperate(final))
    }

    func testAFreshInstallRecoveredAfterFinaliseCanNoLongerOperate() async throws {
        let journal = try TripOccurrenceJournal(scope: scope, directory: newDirectory(), authority: makeAuthority())
        let response = try capturedAnswer(ReplayGolden.recoveryAfterFinalise)
        try journal.recover(response)
        let state = try XCTUnwrap(journal.load())
        XCTAssertNil(state.heldReason)
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(state.serverActive, false)
        XCTAssertEqual(state.creationConfirmed, true)
        XCTAssertEqual(state.acknowledged, try jsonMember(response, "coverage"))
        XCTAssertFalse(journal.canOperate(state))
        XCTAssertNil(try journal.undoTarget())
        let document = try XCTUnwrap(TripOccurrenceCoverage.read(state.acknowledged))
        XCTAssertEqual(document.revision, 6)
        XCTAssertEqual(document.count("done"), 2)
        XCTAssertEqual(document.count("skipped"), 2)
    }

    // MARK: - Answers the journal must refuse

    func testUppercaseIdentityInACoverageIsUnreadable() async throws {
        let coverage = try jsonMember(try capturedAnswer(ReplayGolden.done1), "coverage")
        XCTAssertNotNil(TripOccurrenceCoverage.read(coverage))
        let upperLinks = changingStates(coverage) { state in
            var changed = state
            if case .array(let ids)? = state["tankSessionIds"] {
                changed["tankSessionIds"] = .array(ids.map { .string(($0.occurrenceString ?? "").uppercased()) })
            }
            return changed
        }
        XCTAssertNil(TripOccurrenceCoverage.read(upperLinks), "an upper-case tank link must never be accepted as coverage")
        let upperOperation = changingStates(coverage) { state in
            var changed = state
            if case .string(let id)? = state["lastOperationId"] { changed["lastOperationId"] = .string(id.uppercased()) }
            return changed
        }
        XCTAssertNil(TripOccurrenceCoverage.read(upperOperation), "an upper-case operation id must never be accepted as coverage")
    }

    func testACoverageThatDiffersFromTheQueuedOneHoldsTheJournalAndChangesNothingElse() async throws {
        let chain = try buildChain()
        for index in 0..<2 {
            guard try acknowledgeAnswer(of: index, in: chain) else { return }
        }
        let before = try XCTUnwrap(chain.journal.load())
        let response = replacingIds(in: try capturedAnswer(ReplayGolden.done1), using: chain.ids)
        let tampered = changingStates(try jsonMember(response, "coverage")) { state in
            var changed = state
            if state["status"] == .string("done") { changed["status"] = .string("skipped") }
            return changed
        }
        var fields = try XCTUnwrap(response.occurrenceObject)
        fields["coverage"] = tampered
        try chain.journal.acknowledge(.object(fields))
        let after = try XCTUnwrap(chain.journal.load())
        XCTAssertNotNil(after.heldReason, "a coverage the app did not queue must hold the journal")
        XCTAssertEqual(after.pending, before.pending, "nothing queued is discarded")
        XCTAssertEqual(after.acknowledged, before.acknowledged, "nothing is overwritten")
        XCTAssertEqual(after.history, before.history)
        XCTAssertEqual(after.serverActive, before.serverActive)
    }

    func testAnAnswerForAnotherTripIsRefusedAndChangesNothing() async throws {
        let chain = try buildChain()
        let before = try XCTUnwrap(chain.journal.load())
        let response = replacingIds(in: try capturedAnswer(ReplayGolden.create), using: chain.ids)
        var fields = try XCTUnwrap(response.occurrenceObject)
        fields["tripId"] = .string("99999999-9999-4999-8999-999999999999")
        XCTAssertThrowsError(try chain.journal.acknowledge(.object(fields))) { error in
            XCTAssertEqual(error as? TripOccurrenceCoverage.Failure, .scopeConflict)
        }
        XCTAssertEqual(try chain.journal.load(), before)
    }

    func testOutOfOrderAndRepeatedAnswersChangeNothing() async throws {
        let chain = try buildChain()
        let initial = try XCTUnwrap(chain.journal.load())
        try chain.journal.acknowledge(replacingIds(in: try capturedAnswer(ReplayGolden.done1), using: chain.ids))
        XCTAssertEqual(try chain.journal.load(), initial, "the answer to the third operation arrived first")
        let create = replacingIds(in: try capturedAnswer(ReplayGolden.create), using: chain.ids)
        try chain.journal.acknowledge(create)
        let afterFirst = try XCTUnwrap(chain.journal.load())
        XCTAssertEqual(afterFirst.pending.count, 6)
        try chain.journal.acknowledge(create)
        XCTAssertEqual(try chain.journal.load(), afterFirst, "the same answer delivered twice")
    }

    // MARK: - The compare-and-swap request

    func testTheCompareAndSwapURLCarriesTheRevisionTheServerStored() async throws {
        let row = try tripRow(ReplayGolden.readRow)
        let raw = try jsonString(row, "updated_at")
        let syncVersion = Int(try jsonNumber(row, "sync_version"))
        XCTAssertTrue(raw.hasSuffix("+00:00"), "the stored revision ends in a positive offset: \(raw)")
        let base = try XCTUnwrap(URL(string: "https://nonprod.example.supabase.co"))

        let url = try XCTUnwrap(TripTankCASRequestURL.make(baseURL: base, tripId: tripUUID, vineyardId: vineyardUUID,
                                                           syncVersion: syncVersion, rawUpdatedAt: raw))
        XCTAssertEqual(url.path, "/rest/v1/trips")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertFalse(query.contains("+"), "a bare + is read by PostgREST as a space: \(query)")
        XCTAssertTrue(query.contains("%2B"))
        let decoded = formDecoded(query)
        XCTAssertEqual(decoded["updated_at"], "eq.\(raw)")
        XCTAssertEqual(decoded["sync_version"], "eq.\(syncVersion)")
        XCTAssertEqual(decoded["id"], "eq.\(Fixtures.tripId)")
        XCTAssertEqual(decoded["vineyard_id"], "eq.\(Fixtures.vineyard)")
        XCTAssertEqual(decoded["deleted_at"], "is.null")
        XCTAssertEqual(decoded["is_active"], "eq.true")
        XCTAssertEqual(decoded["end_time"], "is.null")

        // The very query the server accepted.
        let accepted = try capturedExchange(ReplayGolden.casPatch)
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(withoutColonEscapes(query), withoutColonEscapes(accepted.query),
                       "the app builds the query the server answered 200 to")

        // Build 214 sent a bare +; the server read a space and refused it. Build 215 does not.
        let old = try capturedExchange(ReplayEdge.casUnencodedPlus)
        XCTAssertEqual(old.status, 400)
        XCTAssertTrue((formDecoded(old.query)["updated_at"] ?? "").hasSuffix(" 00:00"),
                      "build 214 sent a + that PostgREST read as a space: \(old.query)")
        let fixed = try capturedExchange(ReplayEdge.casEncodedPlus)
        XCTAssertEqual(fixed.status, 200)
        XCTAssertTrue((formDecoded(fixed.query)["updated_at"] ?? "").hasSuffix("+00:00"))

        // A positive offset other than +00:00 survives as well.
        let shifted = "2026-11-04T05:42:51.237375+11:00"
        let shiftedURL = try XCTUnwrap(TripTankCASRequestURL.make(baseURL: base, tripId: tripUUID, vineyardId: vineyardUUID,
                                                                  syncVersion: syncVersion, rawUpdatedAt: shifted))
        let shiftedQuery = try XCTUnwrap(URLComponents(url: shiftedURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertFalse(shiftedQuery.contains("+"))
        XCTAssertEqual(formDecoded(shiftedQuery)["updated_at"], "eq.\(shifted)")
    }

    // MARK: - Tank sessions

    func testTheTankSessionsRoundTripExactlyAsTheServerStoredThem() async throws {
        let sent = try jsonMember(try capturedRequest(ReplayGolden.casPatch), "tank_sessions")
        let stored = try jsonMember(try tripRow(ReplayGolden.readBack), "tank_sessions")
        let local = try decodedTankSessions(sent)
        let remote = try decodedTankSessions(stored)
        XCTAssertEqual(local.count, 2)
        XCTAssertEqual(remote.count, 2)

        // What the app writes for these sessions is what the server was sent.
        let reencoded = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(local))
        assertSame(reencoded, sent, "re-encoding the decoded sessions")

        // What the server stored is what was sent.
        assertSame(stored, sent, "the stored tank_sessions")
        XCTAssertEqual(local.map(\.id), remote.map(\.id))
        for (mine, theirs) in zip(local, remote) {
            XCTAssertNil(TankSessionReceiptMatch.discrepancy(local: mine, remote: theirs),
                         "session \(mine.tankNumber) does not match its server read-back")
            XCTAssertTrue(TankSessionReceiptMatch.equivalent(local: mine, remote: theirs))
        }
    }

    // MARK: - The bodies the app builds

    private func startedTrip(coverage: JSON) throws -> Trip {
        let pTrip = try jsonMember(try capturedRequest(ReplayGolden.create), "p_trip")
        let block = try XCTUnwrap(UUID(uuidString: try jsonString(pTrip, "paddock_id")))
        return Trip(id: tripUUID, vineyardId: vineyardUUID, paddockId: nil, paddockName: "Block X", paddockIds: [block],
                    startTime: startInstant, endTime: nil, currentRowNumber: 38.5, nextRowNumber: 38.5,
                    isActive: false, trackingPattern: .sequential, rowSequence: [38.5, 38.5, 38.5, 38.5],
                    personName: "Operator", tripFunction: "spraying", operatorUserId: ownerUUID,
                    occurrenceCoverage: coverage)
    }

    private func endedTrip() throws -> Trip {
        let sessions = try decodedTankSessions(try jsonMember(try capturedRequest(ReplayGolden.casPatch), "tank_sessions"))
        var trip = try startedTrip(coverage: try jsonMember(try capturedAnswer(ReplayGolden.finalise), "coverage"))
        trip.endTime = endInstant
        trip.isActive = false
        trip.totalDistance = 123.4
        trip.tankSessions = sessions
        trip.totalTanks = 2
        trip.startEngineHours = 1234.5
        trip.endEngineHours = 1240.5
        trip.completionNotes = "Golden chain note"
        return trip
    }

    func testTheBodiesTheAppBuildsAreTheBodiesTheServerAccepted() async throws {
        let createRequest = try capturedRequest(ReplayGolden.create)

        // Trip start: the envelope of the create operation.
        let started = try startedTrip(coverage: try jsonMember(createRequest, "p_coverage"))
        let upsert = BackendTrip.upsert(from: started, createdBy: ownerUUID, clientUpdatedAt: started.startTime)
        let envelope = OccurrenceCreateBlockUUID.canonicalize(try OccurrenceWirePayload.tripMetadata(upsert))
        assertSame(.object(envelope), try jsonMember(createRequest, "p_trip"), "p_trip of the create operation")

        // Trip end: the details PATCH, before the first tank link and again after finalise.
        let ended = try endedTrip()
        let endedUpsert = BackendTrip.upsert(from: ended, createdBy: ownerUUID, clientUpdatedAt: endInstant)
        let fields = JSON.object(try OccurrenceWirePayload.nonAuthorityFields(endedUpsert))
        assertSame(fields, try capturedRequest(ReplayGolden.detailsBefore), "Trip details PATCH before the first link")
        assertSame(fields, try capturedRequest(ReplayGolden.detailsAfter), "Trip details PATCH after finalise")

        // Authority, route identity and lifecycle never travel in that PATCH.
        let sent = try XCTUnwrap(fields.occurrenceObject)
        for key in OccurrenceWirePayload.authorityKeys {
            XCTAssertNil(sent[key], "\(key) must only go through its dedicated RPC")
        }
    }

    func testThePlannerBuildsTheCoverageTheServerAccepted() async throws {
        let captured = try jsonMember(try capturedRequest(ReplayGolden.create), "p_coverage")
        let document = try XCTUnwrap(TripOccurrenceCoverage.read(captured))
        let item = try XCTUnwrap(document.items.first)
        guard case .array(let rawItems) = try jsonMember(captured, "items"), let firstItem = rawItems.first,
              case .array(let snapshots) = try jsonMember(try jsonMember(firstItem, "physicalPathRef"), "rowSnapshots") else {
            throw ReplayFixtureError(description: "the captured coverage has no row snapshots")
        }
        let rows: [PaddockRow] = try snapshots.map { snapshot in
            func point(_ key: String) throws -> CoordinatePoint {
                let value = try jsonMember(snapshot, key)
                return CoordinatePoint(latitude: try jsonNumber(value, "latitude"), longitude: try jsonNumber(value, "longitude"))
            }
            let id = try XCTUnwrap(UUID(uuidString: try jsonString(snapshot, "id")))
            return PaddockRow(id: id, number: Int(try jsonNumber(snapshot, "number")),
                              startPoint: try point("startPoint"), endPoint: try point("endPoint"))
        }
        let blockId = try XCTUnwrap(UUID(uuidString: item.blockId))
        let candidate = TripOccurrencePlanner.Candidate(vineyardId: vineyardUUID, blockId: blockId,
                                                        blockName: item.blockNameSnapshot, label: item.pathNumber, rows: rows)

        let generated = try TripOccurrencePlanner.commit(Array(repeating: candidate, count: document.items.count),
                                                         vineyardId: vineyardUUID)
        let made = try XCTUnwrap(TripOccurrenceCoverage.read(generated))
        XCTAssertEqual(made.items.count, document.items.count)
        // The planner mints fresh ids; map them onto the captured ones by position and compare everything else.
        var ids: [String: String] = [made.planId: document.planId]
        for (mine, theirs) in zip(made.items, document.items) {
            ids[mine.occurrenceId] = theirs.occurrenceId
            ids[mine.physicalPathRef.pathId] = theirs.physicalPathRef.pathId
        }
        assertSame(replacingIds(in: generated, using: ids), captured, "the coverage the planner commits")
    }

    // MARK: - The rows the server returns

    func testTheServerRowsDecodeAsTheAppReadsThem() async throws {
        func backendTrip(_ label: String) throws -> BackendTrip {
            try RPCDecoding.decoder.decode(BackendTrip.self, from: JSONEncoder().encode(try tripRow(label)))
        }
        let sent = try decodedTankSessions(try jsonMember(try capturedRequest(ReplayGolden.casPatch), "tank_sessions"))

        let active = try backendTrip(ReplayGolden.readRow)
        XCTAssertEqual(active.id, tripUUID)
        XCTAssertEqual(active.vineyardId, vineyardUUID)
        XCTAssertEqual(active.isActive, true)
        XCTAssertNil(active.endTime)
        XCTAssertNil(active.deletedAt)
        XCTAssertEqual(active.syncVersion, 2)
        XCTAssertEqual(active.startEngineHours, 1234.5)
        XCTAssertEqual(active.tankSessions?.count, 0)
        XCTAssertEqual(TripOccurrenceCoverage.read(active.occurrenceCoverage)?.revision, 1)

        let staged = try backendTrip(ReplayGolden.readBack)
        XCTAssertEqual(staged.isActive, true)
        XCTAssertNil(staged.endTime)
        XCTAssertEqual(staged.tankSessions?.map(\.id), sent.map(\.id))
        XCTAssertEqual(staged.syncVersion, 2, "the tank-session CAS PATCH does not change the revision it was checked against")

        let finished = try backendTrip(ReplayGolden.finalRow)
        XCTAssertEqual(finished.isActive, false)
        XCTAssertEqual(finished.endTime, endInstant)
        XCTAssertNil(finished.deletedAt)
        XCTAssertEqual(finished.endEngineHours, 1240.5)
        XCTAssertEqual(finished.completionNotes, "Golden chain note")
        XCTAssertEqual(finished.totalTanks, 2)
        XCTAssertEqual(finished.tankSessions?.map(\.id), sent.map(\.id))
        XCTAssertGreaterThan(finished.syncVersion ?? 0, active.syncVersion ?? Int.max)
        let document = try XCTUnwrap(TripOccurrenceCoverage.read(finished.occurrenceCoverage))
        XCTAssertEqual(document.revision, 6)
        XCTAssertEqual(document.count("done"), 2)
        XCTAssertEqual(document.count("skipped"), 2)
        XCTAssertNil(document.plannedCursorId)
        XCTAssertNil(document.selectedOccurrenceId)
    }
}
