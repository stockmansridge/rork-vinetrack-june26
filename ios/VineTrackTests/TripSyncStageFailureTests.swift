import Foundation
import Supabase
import XCTest
@testable import VineTrack

// Incident: original Trip 492ebafc-b996-4ec4-8ea9-4261a3056810 never finished
// its upload. Every HTTP answer on the occurrence chain was flattened into a
// synthetic code, classified "retry forever" and hid the real reason, so a
// deterministic server refusal was re-sent on every sweep and the Sync screen
// could only say "Upload didn't complete".
//
// This file pins the typed replacement. Part 1 is pure (no network, no store).
// Part 2 drives the shipping TripSyncService with a fake repository to prove a
// deterministic answer is kept visible, not re-sent, and never discards the
// original Trip, tank sessions or queue entry.

private struct UnrelatedFailure: Error {}

// MARK: - Part 1: pure

final class TripSyncStageFailureTests: XCTestCase {
    private typealias Stage = TripSyncStageFailure.Stage
    private typealias Disposition = TripSyncStageFailure.Disposition

    private let originalTrip = UUID(uuidString: "492EBAFC-B996-4EC4-8EA9-4261A3056810")!
    private let originalOperation = "0f6c2f0e-6a43-4a8e-9a38-7a1f6d2f6c11"
    private let jhTesting = UUID(uuidString: "59973CED-1FB9-42EC-A66D-9EAAD3172824")!
    private let stockmansRidge = UUID(uuidString: "FE952AFE-437F-4BE7-8CBF-FDD8E630411C")!

    private func failure(
        stage: Stage = .occurrenceAction, operationId: String? = nil,
        endpoint: String = "rpc/apply_trip_occurrence_action_v1",
        httpStatus: Int? = nil, postgrestCode: String? = nil, serverMessage: String? = nil,
        occurrenceCode: String? = nil, transportCode: Int? = nil, verificationCode: String? = nil,
        journalHeld: Bool = false, disposition: Disposition? = nil
    ) -> TripSyncStageFailure {
        TripSyncStageFailure(
            stage: stage, tripId: originalTrip, operationId: operationId, endpoint: endpoint,
            httpStatus: httpStatus, postgrestCode: postgrestCode, serverMessage: serverMessage,
            occurrenceCode: occurrenceCode, transportCode: transportCode,
            verificationCode: verificationCode, journalHeld: journalHeld, disposition: disposition)
    }

    private func classify(_ httpStatus: Int? = nil, _ code: String? = nil,
                          occurrence: String? = nil, url: Int? = nil) -> Disposition {
        TripSyncStageFailure.classify(httpStatus: httpStatus, postgrestCode: code,
                                      occurrenceCode: occurrence, urlErrorCode: url)
    }

    private func postgrestError(code: String?, message: String) throws -> PostgrestError {
        var object: [String: Any] = ["message": message]
        if let code { object["code"] = code }
        return try JSONDecoder().decode(
            PostgrestError.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: Classification

    func testTransportErrorIsAlwaysRetryable() {
        XCTAssertEqual(classify(url: -1001), .retryable)
        XCTAssertEqual(classify(500, "40001", occurrence: "OCCURRENCE_TANK_LINK_CONFLICT", url: -1009), .retryable)
        XCTAssertEqual(classify(400, "22P02", url: -1005), .retryable)
    }

    func testServerRejectionTokenIsDeterministicEvenWhenPostgrestMapsItTo500() {
        // The incident's exact answer: SQLSTATE 40001 is class 40, which
        // PostgREST reports as HTTP 500, and the message is the token.
        XCTAssertEqual(classify(500, "40001", occurrence: "OCCURRENCE_TANK_LINK_CONFLICT"), .nonRetryable)
        for token in ["OCCURRENCE_TANK_REVIEW_REQUIRED", "OCCURRENCE_REVISION_CONFLICT",
                      "OCCURRENCE_UPDATE_REQUIRED", "OCCURRENCE_DELETE_FORBIDDEN"] {
            XCTAssertEqual(classify(500, nil, occurrence: token), .nonRetryable, token)
        }
    }

    func testLegacySyntheticUnavailableCodeRemainsTransient() {
        XCTAssertEqual(classify(500, nil, occurrence: "OCCURRENCE_SYNC_UNAVAILABLE"), .retryable)
        XCTAssertEqual(classify(400, "22P02", occurrence: "OCCURRENCE_SYNC_UNAVAILABLE"), .retryable)
    }

    func testTransientPostgresAndPostgrestCodesWinOverTheHttpStatus() {
        for code in ["08006", "53300", "57014", "40001", "40P01", "PGRST000", "PGRST301", "pgrst301"] {
            XCTAssertEqual(classify(400, code), .retryable, code)
        }
    }

    func testDeterministicPostgresAndPostgrestCodesWinOverTheHttpStatus() {
        for code in ["23505", "22P02", "42501", "42883", "PGRST100", "PGRST202", "PGRST204", "pgrst204"] {
            XCTAssertEqual(classify(500, code), .nonRetryable, code)
        }
    }

    func testHttpStatusAloneDecidesWhenThereIsNoCode() {
        for status in [401, 408, 425, 429, 500, 502, 503, 504, 599] {
            XCTAssertEqual(classify(status), .retryable, "\(status)")
        }
        for status in [400, 403, 404, 409, 422] {
            XCTAssertEqual(classify(status), .nonRetryable, "\(status)")
        }
        XCTAssertEqual(classify(200), .retryable)
        XCTAssertEqual(classify(), .retryable)
        // An unknown code falls through to the status; an empty one is no code.
        XCTAssertEqual(classify(500, "XX000"), .retryable)
        XCTAssertEqual(classify(400, "XX000"), .nonRetryable)
        XCTAssertEqual(classify(400, ""), .nonRetryable)
    }

    func testAnAnonymousRequestIsRetryableButAForbiddenOneIsNot() {
        // PostgREST answers a call with no valid token as 401 + 42501
        // ("permission denied for function ..."). Signing in again cures that, so
        // the status must win over the code. The same 42501 on a 403 is a real
        // access rule and stays deterministic.
        XCTAssertEqual(classify(401, "42501"), .retryable)
        XCTAssertEqual(classify(401, "PGRST301"), .retryable)
        XCTAssertEqual(classify(401), .retryable)
        XCTAssertEqual(classify(403, "42501"), .nonRetryable)
        XCTAssertEqual(classify(500, "42501"), .nonRetryable)
        // A server rejection token is still decisive, whatever the status.
        XCTAssertEqual(classify(401, "42501", occurrence: "OCCURRENCE_TRIP_FORBIDDEN"), .nonRetryable)
        // A transport failure outranks everything.
        XCTAssertEqual(classify(401, "42501", url: -1009), .retryable)
    }

    func testInitDerivesDispositionAndAHeldJournalAlwaysWins() {
        XCTAssertEqual(failure(httpStatus: 400, postgrestCode: "22P02").disposition, .nonRetryable)
        XCTAssertEqual(failure(httpStatus: 503).disposition, .retryable)
        XCTAssertEqual(failure(httpStatus: 400, postgrestCode: "22P02", disposition: .retryable).disposition, .retryable)
        XCTAssertEqual(failure(httpStatus: 503, journalHeld: true).disposition, .held)
        XCTAssertEqual(failure(httpStatus: 503, journalHeld: true, disposition: .retryable).disposition, .held)
    }

    // MARK: Message hygiene

    func testServerMessageIsSanitisedAndBounded() throws {
        let long = failure(serverMessage: String(repeating: "a", count: 1_000))
        let text = try XCTUnwrap(long.serverMessage)
        XCTAssertLessThan(text.count, 400)
        XCTAssertTrue(text.hasSuffix("(truncated)"))

        let leaked = failure(serverMessage: #"{"access_token":"abc.def.ghi","message":"x"}"#)
        XCTAssertTrue(leaked.serverMessage?.contains("<redacted>") == true)
        XCTAssertFalse(leaked.serverMessage?.contains("abc.def.ghi") == true)
        XCTAssertFalse(leaked.technicalDetail.contains("abc.def.ghi"))
        XCTAssertNil(failure().serverMessage)
    }

    // MARK: Presentation

    func testReasonCodePriority() {
        XCTAssertEqual(failure(httpStatus: 400, postgrestCode: "pgrst204", occurrenceCode: "OCCURRENCE_X",
                               transportCode: -1, verificationCode: "TANK_STAGING_CAS_NO_MATCH").reasonCode,
                       "OCCURRENCE_X")
        XCTAssertEqual(failure(httpStatus: 400, postgrestCode: "pgrst204", transportCode: -1,
                               verificationCode: "TANK_STAGING_CAS_NO_MATCH").reasonCode,
                       "TANK_STAGING_CAS_NO_MATCH")
        XCTAssertEqual(failure(httpStatus: 400, postgrestCode: "pgrst204", transportCode: -1).reasonCode, "PGRST204")
        XCTAssertEqual(failure(httpStatus: 400, postgrestCode: "", transportCode: -1).reasonCode, "HTTP_400")
        XCTAssertEqual(failure(transportCode: -1001).reasonCode, "NETWORK_-1001")
        XCTAssertEqual(failure(stage: .finalize).reasonCode, "TRIP_SYNC_FINALIZE")
    }

    func testKindIsRetryableOnlyForRetryableFailures() {
        XCTAssertEqual(failure(httpStatus: 503).kind, .retryable)
        XCTAssertEqual(failure(httpStatus: 400, postgrestCode: "22P02").kind, .permanent)
        XCTAssertEqual(failure(journalHeld: true).kind, .permanent)
    }

    func testFriendlyMessageNamesTheStageAndCodeAndPromisesNothingWasLost() {
        let conflict = failure(httpStatus: 500, postgrestCode: "40001",
                               occurrenceCode: "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertTrue(conflict.friendlyMessage.contains("OCCURRENCE_TANK_LINK_CONFLICT"))
        XCTAssertTrue(conflict.friendlyMessage.contains("kept unchanged"))
        XCTAssertTrue(conflict.friendlyMessage.contains("nothing was discarded"))

        let review = failure(occurrenceCode: "OCCURRENCE_TANK_REVIEW_REQUIRED")
        XCTAssertTrue(review.friendlyMessage.contains("OCCURRENCE_TANK_REVIEW_REQUIRED"))
        XCTAssertTrue(review.friendlyMessage.contains("unchanged"))

        let rejected = failure(occurrenceCode: "OCCURRENCE_REVISION_CONFLICT")
        XCTAssertTrue(rejected.friendlyMessage.contains("OCCURRENCE_REVISION_CONFLICT"))
        XCTAssertFalse(rejected.friendlyMessage.contains("held for review"))
        let held = failure(occurrenceCode: "OCCURRENCE_REVISION_CONFLICT", journalHeld: true)
        XCTAssertTrue(held.friendlyMessage.contains("held for review"))
        XCTAssertTrue(held.friendlyMessage.contains("Nothing was discarded"))

        let transient = failure(stage: .finalize, httpStatus: 503)
        XCTAssertTrue(transient.friendlyMessage.contains("Trip finish"))
        XCTAssertTrue(transient.friendlyMessage.contains("HTTP_503"))
        XCTAssertTrue(transient.friendlyMessage.contains("try again"))

        let rejection = failure(stage: .tankStagingPatch, httpStatus: 400, postgrestCode: "PGRST204")
        XCTAssertTrue(rejection.friendlyMessage.contains("the tank-session upload"))
        XCTAssertTrue(rejection.friendlyMessage.contains("PGRST204"))
        XCTAssertTrue(rejection.friendlyMessage.contains("kept unchanged"))
        XCTAssertTrue(rejection.friendlyMessage.contains("paused"))

        let offline = failure(stage: .parentCreate, transportCode: -1009)
        XCTAssertTrue(offline.friendlyMessage.contains("Trip creation"))
        XCTAssertTrue(offline.friendlyMessage.contains("try again"))

        let journal = failure(verificationCode: TripSyncVerificationCode.journalHeld, journalHeld: true)
        XCTAssertTrue(journal.friendlyMessage.contains("on hold"))
        XCTAssertTrue(journal.friendlyMessage.contains("OCCURRENCE_JOURNAL_HELD"))

        let legacy = failure(httpStatus: 500, occurrenceCode: "OCCURRENCE_SYNC_UNAVAILABLE")
        XCTAssertTrue(legacy.friendlyMessage.contains("try again"))

        for item in [conflict, review, rejected, held, transient, rejection, offline, journal, legacy] {
            XCTAssertFalse(item.friendlyMessage.isEmpty)
            XCTAssertFalse(item.friendlyMessage.contains("{"), "No raw JSON on screen")
            XCTAssertEqual(item.errorDescription, item.friendlyMessage)
        }
    }

    func testTechnicalDetailCarriesStageRequestAndServerAnswer() {
        let detail = failure(operationId: originalOperation, httpStatus: 500, postgrestCode: "40001",
                             serverMessage: "OCCURRENCE_TANK_LINK_CONFLICT",
                             occurrenceCode: "OCCURRENCE_TANK_LINK_CONFLICT").technicalDetail
        let lines = detail.split(separator: "\n").map(String.init)
        for expected in [
            "stage: OCCURRENCE_ACTION",
            "trip_id: 492ebafc-b996-4ec4-8ea9-4261a3056810",
            "operation_id: \(originalOperation)",
            "endpoint: rpc/apply_trip_occurrence_action_v1",
            "http_status: 500",
            "postgrest_code: 40001",
            "occurrence_code: OCCURRENCE_TANK_LINK_CONFLICT",
            "transport_code: none",
            "verification_code: none",
            "server_message: OCCURRENCE_TANK_LINK_CONFLICT",
            "disposition: non_retryable",
            "journal_held: no",
        ] {
            XCTAssertTrue(lines.contains(expected), expected)
        }
        XCTAssertTrue(detail.contains("evidence: preserved"))
        let bare = failure().technicalDetail
        XCTAssertTrue(bare.contains("operation_id: none"))
        XCTAssertTrue(bare.contains("http_status: none"))
        XCTAssertTrue(bare.contains("server_message: none"))
    }

    func testSyncQueueClassifierReturnsTheTypedDetailBeforeAnyTextHeuristic() {
        // The sanitised message contains digits that a substring match would
        // mistake for another failure ("502", "42501", "timeout", "offline").
        let typed = failure(httpStatus: 500, postgrestCode: "40001",
                            serverMessage: "timeout 502 42501 offline",
                            occurrenceCode: "OCCURRENCE_TANK_LINK_CONFLICT")
        let detail = BackendErrorDiagnostics.classify(typed, endpoint: "Trips")
        XCTAssertEqual(detail, typed.syncFailureDetail)
        XCTAssertEqual(detail.kind, .permanent)
        XCTAssertEqual(detail.reasonCode, "OCCURRENCE_TANK_LINK_CONFLICT")

        // Untyped errors keep their existing classification.
        let network = BackendErrorDiagnostics.classify(URLError(.timedOut), endpoint: "Trips")
        XCTAssertEqual(network.reasonCode, "network_-1001")
        XCTAssertEqual(network.kind, .retryable)
        let unknown = BackendErrorDiagnostics.classify(UnrelatedFailure(), endpoint: "Trips")
        XCTAssertEqual(unknown.reasonCode, "unknown")
        XCTAssertEqual(unknown.kind, .retryable)
    }

    // MARK: Export allow-list

    func testExportAllowListAcceptsOnlyClosedVocabularyCodes() {
        for code in ["OCCURRENCE_TANK_LINK_CONFLICT", "TANK_STAGING_CAS_NO_MATCH", "NON_AUTHORITY_PATCH_NO_ROW",
                     "TRIP_SYNC_FINALIZE", "HTTP_500", "NETWORK_-1001", "40001", "22P02", "PGRST204"] {
            XCTAssertTrue(TripSyncStageFailure.isExportSafe(code), code)
        }
        for code in ["", "OCCURRENCE_", "network_offline", "occurrence_tank_link_conflict", "HTTP_600",
                     "some free text", "OCCURRENCE_X secret", "OCCURRENCE_X\nsecret", "Chardonnay Block 7"] {
            XCTAssertFalse(TripSyncStageFailure.isExportSafe(code), code)
        }
    }

    func testEveryVerificationCodeAndEveryDefaultStageCodeIsExportSafe() {
        let codes = [
            TripSyncVerificationCode.tripNotEnded, TripSyncVerificationCode.noRequiredSessions,
            TripSyncVerificationCode.coverageUnreadable, TripSyncVerificationCode.duplicateSession,
            TripSyncVerificationCode.duplicateTankNumber, TripSyncVerificationCode.requiredNotLocal,
            TripSyncVerificationCode.noAccount, TripSyncVerificationCode.serverRowMismatch,
            TripSyncVerificationCode.serverSessionConflict, TripSyncVerificationCode.revisionMissing,
            TripSyncVerificationCode.requestInvalid, TripSyncVerificationCode.casNoMatch,
            TripSyncVerificationCode.readbackMismatch, TripSyncVerificationCode.journalHeld,
            TripSyncVerificationCode.parentOperationsPending, TripSyncVerificationCode.parentReadbackMismatch,
            TripSyncVerificationCode.operationsPending, TripSyncVerificationCode.nonAuthorityNoRow,
        ]
        XCTAssertEqual(codes.count, 18)
        XCTAssertEqual(Set(codes).count, 18, "Each verification step has its own code")
        for code in codes { XCTAssertTrue(TripSyncStageFailure.isExportSafe(code), code) }

        for stage in Stage.allCases {
            let code = failure(stage: stage).reasonCode
            XCTAssertEqual(code, "TRIP_SYNC_\(stage.rawValue)")
            XCTAssertTrue(TripSyncStageFailure.isExportSafe(code), code)
        }
        let labels = Stage.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "Stage labels are distinct")
        XCTAssertFalse(labels.contains { $0.isEmpty })
    }

    func testRpcNamesMapToTheStageThatOwnsThem() {
        XCTAssertEqual(Stage.forRPC("create_trip_with_occurrences_v1"), .parentCreate)
        XCTAssertEqual(Stage.forRPC("activate_trip_occurrences_v1"), .parentActivate)
        XCTAssertEqual(Stage.forRPC("finalize_trip_occurrences_v1"), .finalize)
        XCTAssertEqual(Stage.forRPC("get_trip_occurrence_recovery_v1"), .occurrenceRecovery)
        XCTAssertEqual(Stage.forRPC("apply_trip_occurrence_action_v1"), .occurrenceAction)
        XCTAssertEqual(Stage.forRPC("something_new"), .occurrenceAction)
    }

    // MARK: Server answers

    func testPostgrestAnswerParsesTheServerBodyAndRejectsAnythingElse() {
        let real = Data(#"{"code":"40001","details":null,"hint":null,"message":"OCCURRENCE_TANK_LINK_CONFLICT"}"#.utf8)
        XCTAssertEqual(PostgrestAnswer.parse(real),
                       PostgrestAnswer(code: "40001", message: "OCCURRENCE_TANK_LINK_CONFLICT"))
        let nothing = PostgrestAnswer(code: nil, message: nil)
        XCTAssertEqual(PostgrestAnswer.parse(Data("<html>502</html>".utf8)), nothing)
        XCTAssertEqual(PostgrestAnswer.parse(Data(#"[{"code":"40001"}]"#.utf8)), nothing)
        XCTAssertEqual(PostgrestAnswer.parse(Data()), nothing)
        XCTAssertEqual(PostgrestAnswer.parse(Data(#"{"code":42,"message":""}"#.utf8)), nothing)
    }

    func testOccurrenceTokenIsTheFirstUppercaseRejectionToken() {
        XCTAssertEqual(PostgrestAnswer.occurrenceToken(in: "OCCURRENCE_TANK_LINK_CONFLICT"),
                       "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertEqual(PostgrestAnswer.occurrenceToken(in: #"{"message":"OCCURRENCE_REVISION_CONFLICT: stale"}"#),
                       "OCCURRENCE_REVISION_CONFLICT")
        XCTAssertEqual(PostgrestAnswer.occurrenceToken(in: "first OCCURRENCE_A then OCCURRENCE_B"), "OCCURRENCE_A")
        XCTAssertNil(PostgrestAnswer.occurrenceToken(in: "occurrence_tank_link_conflict"))
        XCTAssertNil(PostgrestAnswer.occurrenceToken(in: "relation does not exist"))
        XCTAssertNil(PostgrestAnswer.occurrenceToken(in: ""))
    }

    func testOccurrenceRejectionIsBuiltFromTheLiveAnswerWithoutLosingAnything() {
        let body = Data(#"{"code":"40001","details":null,"hint":null,"message":"OCCURRENCE_TANK_LINK_CONFLICT"}"#.utf8)
        let rejection = OccurrenceRPCFailure.from(httpStatus: 500, body: body)
        XCTAssertEqual(rejection, OccurrenceRPCFailure(
            code: "OCCURRENCE_TANK_LINK_CONFLICT", httpStatus: 500, postgrestCode: "40001",
            message: "OCCURRENCE_TANK_LINK_CONFLICT"))
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(for: rejection),
                     "A repairable tank-link answer must never hold the immutable journal")

        let typed = TripSyncStageFailure(rejection: rejection, rpc: "apply_trip_occurrence_action_v1",
                                         tripId: originalTrip, operationId: originalOperation, journalHeld: false)
        XCTAssertEqual(typed.stage, .occurrenceAction)
        XCTAssertEqual(typed.endpoint, "rpc/apply_trip_occurrence_action_v1")
        XCTAssertEqual(typed.httpStatus, 500)
        XCTAssertEqual(typed.postgrestCode, "40001")
        XCTAssertEqual(typed.occurrenceCode, "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertEqual(typed.operationId, originalOperation)
        XCTAssertEqual(typed.disposition, .nonRetryable)
        XCTAssertEqual(typed.reasonCode, "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertFalse(typed.journalHeld)

        // A gateway page has no token: it is transient and never relabelled.
        let gateway = OccurrenceRPCFailure.from(httpStatus: 502, body: Data("<html>Bad gateway</html>".utf8))
        XCTAssertNil(gateway.code)
        XCTAssertNil(gateway.postgrestCode)
        XCTAssertEqual(gateway.httpStatus, 502)
        XCTAssertEqual(gateway.message, "<html>Bad gateway</html>")
        let gatewayTyped = TripSyncStageFailure(rejection: gateway, rpc: "finalize_trip_occurrences_v1",
                                                tripId: originalTrip, operationId: nil, journalHeld: false)
        XCTAssertEqual(gatewayTyped.stage, .finalize)
        XCTAssertEqual(gatewayTyped.disposition, .retryable)
        XCTAssertEqual(gatewayTyped.reasonCode, "HTTP_502")
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(for: gateway))

        // A missing server function is a deterministic schema answer, still not a hold.
        let missing = OccurrenceRPCFailure.from(httpStatus: 404, body: Data(
            #"{"code":"PGRST202","message":"Could not find the function public.apply_trip_occurrence_action_v1"}"#.utf8))
        XCTAssertEqual(missing.postgrestCode, "PGRST202")
        XCTAssertNil(missing.code)
        let missingTyped = TripSyncStageFailure(rejection: missing, rpc: "apply_trip_occurrence_action_v1",
                                                tripId: originalTrip, operationId: nil, journalHeld: false)
        XCTAssertEqual(missingTyped.disposition, .nonRetryable)
        XCTAssertEqual(missingTyped.reasonCode, "PGRST202")
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(for: missing))
    }

    func testRestFailureIsBuiltFromTheBodyOfTheRefusedRequest() {
        let schema = TripSyncStageFailure(
            stage: .tankStagingPatch, tripId: originalTrip,
            endpoint: "PATCH rest/v1/trips (tank_sessions, compare-and-swap)", httpStatus: 400,
            body: Data(#"{"code":"PGRST204","message":"Could not find the 'x' column of 'trips' in the schema cache"}"#.utf8))
        XCTAssertEqual(schema.postgrestCode, "PGRST204")
        XCTAssertEqual(schema.httpStatus, 400)
        XCTAssertNil(schema.occurrenceCode)
        XCTAssertEqual(schema.disposition, .nonRetryable)
        XCTAssertEqual(schema.reasonCode, "PGRST204")
        XCTAssertTrue(schema.serverMessage?.contains("schema cache") == true)

        let upstream = TripSyncStageFailure(
            stage: .nonAuthorityPatch, tripId: originalTrip, endpoint: "PATCH rest/v1/trips (non-authority fields)",
            httpStatus: 503, body: Data("upstream connect error".utf8), operationId: originalOperation)
        XCTAssertEqual(upstream.disposition, .retryable)
        XCTAssertEqual(upstream.reasonCode, "HTTP_503")
        XCTAssertEqual(upstream.operationId, originalOperation)
        XCTAssertEqual(upstream.serverMessage, "upstream connect error")

        // A trigger on the PATCH can raise the same rejection token.
        let trigger = TripSyncStageFailure(
            stage: .tankStagingPatch, tripId: originalTrip, endpoint: "PATCH rest/v1/trips", httpStatus: 500,
            body: Data(#"{"code":"40001","message":"OCCURRENCE_TANK_LINK_CONFLICT"}"#.utf8))
        XCTAssertEqual(trigger.occurrenceCode, "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertEqual(trigger.disposition, .nonRetryable)
    }

    func testWrappingTurnsSdkAndTransportErrorsIntoTypedFailuresAndLeavesTheRestAlone() throws {
        func wrap(_ error: Error) -> TripSyncStageFailure? {
            TripSyncStageFailure.wrapping(error, stage: .tankStagingPatch, tripId: originalTrip,
                                          operationId: originalOperation, endpoint: "PATCH rest/v1/trips")
        }
        let invalid = try XCTUnwrap(wrap(try postgrestError(code: "22P02", message: "invalid input syntax for type uuid")))
        XCTAssertEqual(invalid.postgrestCode, "22P02")
        XCTAssertEqual(invalid.disposition, .nonRetryable)
        XCTAssertEqual(invalid.stage, .tankStagingPatch)
        XCTAssertEqual(invalid.operationId, originalOperation)
        XCTAssertEqual(invalid.endpoint, "PATCH rest/v1/trips")

        let conflict = try XCTUnwrap(wrap(try postgrestError(code: "40001", message: "OCCURRENCE_TANK_LINK_CONFLICT")))
        XCTAssertEqual(conflict.occurrenceCode, "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertEqual(conflict.reasonCode, "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertEqual(conflict.disposition, .nonRetryable)

        let timeout = try XCTUnwrap(wrap(URLError(.timedOut)))
        XCTAssertEqual(timeout.transportCode, -1001)
        XCTAssertEqual(timeout.disposition, .retryable)
        XCTAssertEqual(timeout.reasonCode, "NETWORK_-1001")

        // These flow unchanged: SyncQueuePush.hold reads VT_READ_ONLY from the
        // SDK error, and cancellation is not a failure.
        XCTAssertNil(wrap(try postgrestError(code: "VT_READ_ONLY", message: "read only")))
        XCTAssertNil(wrap(URLError(.cancelled)))
        XCTAssertNil(wrap(CancellationError()))
        XCTAssertNil(wrap(UnrelatedFailure()))
        XCTAssertEqual(wrap(invalid), invalid, "An existing typed failure is never rewrapped")
    }

    // MARK: Hold policy

    func testHoldPolicyHoldsTheJournalOnlyForGenuineConflicts() {
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(code: nil))
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(code: "OCCURRENCE_SYNC_UNAVAILABLE"))
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(code: "OCCURRENCE_TANK_LINK_CONFLICT"))
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(code: "OCCURRENCE_TANK_REVIEW_REQUIRED"))
        XCTAssertEqual(OccurrenceHoldPolicy.holdReason(code: "OCCURRENCE_UPDATE_REQUIRED"), "OCCURRENCE_UPDATE_REQUIRED")
        XCTAssertEqual(OccurrenceHoldPolicy.holdReason(code: "OCCURRENCE_UNSUPPORTED_ACTION"), "OCCURRENCE_UPDATE_REQUIRED")
        XCTAssertEqual(OccurrenceHoldPolicy.holdReason(code: "OCCURRENCE_REVISION_CONFLICT"), "OCCURRENCE_CONFLICT")
        XCTAssertEqual(OccurrenceHoldPolicy.holdReason(code: "OCCURRENCE_DELETE_FORBIDDEN"), "OCCURRENCE_CONFLICT")
        XCTAssertEqual(OccurrenceHoldPolicy.holdReason(for: OccurrenceRPCFailure(
            code: "OCCURRENCE_REVISION_CONFLICT", httpStatus: 409, postgrestCode: nil, message: nil)), "OCCURRENCE_CONFLICT")
        XCTAssertNil(OccurrenceHoldPolicy.holdReason(for: OccurrenceRPCFailure(
            code: "OCCURRENCE_TANK_LINK_CONFLICT", httpStatus: 500, postgrestCode: "40001", message: nil)))
        XCTAssertEqual(OccurrenceHoldPolicy.nonHoldingCodes,
                       ["OCCURRENCE_TANK_LINK_CONFLICT", "OCCURRENCE_TANK_REVIEW_REQUIRED"])
    }

    // MARK: Retry throttle

    func testThrottleRecordsOnlyDeterministicAnswersAndHonoursTheCooldown() {
        var throttle = TripSyncRetryThrottle()
        let id = UUID(), other = UUID()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(TripSyncRetryThrottle.cooldown, 30 * 60)

        // A transient answer is never throttled.
        throttle.record(tripId: id, disposition: .retryable, reasonCode: "HTTP_503", now: t0)
        XCTAssertFalse(throttle.isCoolingDown(id, now: t0))
        XCTAssertTrue(throttle.entries.isEmpty)

        throttle.record(tripId: id, disposition: .nonRetryable, reasonCode: "22P02", now: t0)
        XCTAssertTrue(throttle.isCoolingDown(id, now: t0))
        XCTAssertTrue(throttle.isCoolingDown(id, now: t0.addingTimeInterval(29 * 60)))
        XCTAssertFalse(throttle.isCoolingDown(id, now: t0.addingTimeInterval(30 * 60)))
        XCTAssertFalse(throttle.isCoolingDown(other, now: t0), "The cooldown is per Trip")
        XCTAssertEqual(throttle.nextAttempt(id, now: t0), t0.addingTimeInterval(30 * 60))
        XCTAssertNil(throttle.nextAttempt(id, now: t0.addingTimeInterval(31 * 60)))
        XCTAssertEqual(throttle.entries[id]?.attempts, 1)
        XCTAssertEqual(throttle.entries[id]?.reasonCode, "22P02")
        XCTAssertEqual(throttle.entries[id]?.disposition, .nonRetryable)

        // The same Trip answers again after the window: the count grows and the window restarts.
        let t1 = t0.addingTimeInterval(31 * 60)
        throttle.record(tripId: id, disposition: .held, reasonCode: "OCCURRENCE_JOURNAL_HELD", now: t1)
        XCTAssertEqual(throttle.entries[id]?.attempts, 2)
        XCTAssertEqual(throttle.entries[id]?.disposition, .held)
        XCTAssertTrue(throttle.isCoolingDown(id, now: t1.addingTimeInterval(29 * 60)))

        // A later transient answer ends the cooldown at once.
        throttle.record(tripId: id, disposition: .retryable, reasonCode: "NETWORK_-1001", now: t1)
        XCTAssertNil(throttle.entries[id])
        XCTAssertFalse(throttle.isCoolingDown(id, now: t1))
    }

    func testThrottleRecordsTypedFailuresAndClearsPerTripOrAll() {
        var throttle = TripSyncRetryThrottle()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let conflict = failure(httpStatus: 500, postgrestCode: "40001",
                               occurrenceCode: "OCCURRENCE_TANK_LINK_CONFLICT")
        throttle.record(conflict, now: t0)
        XCTAssertTrue(throttle.isCoolingDown(originalTrip, now: t0))
        XCTAssertEqual(throttle.entries[originalTrip]?.reasonCode, "OCCURRENCE_TANK_LINK_CONFLICT")

        let secondTrip = UUID()
        throttle.record(tripId: secondTrip, disposition: .held, reasonCode: "OCCURRENCE_JOURNAL_HELD", now: t0)
        XCTAssertEqual(throttle.entries.count, 2)

        throttle.clear(originalTrip)
        XCTAssertFalse(throttle.isCoolingDown(originalTrip, now: t0))
        XCTAssertTrue(throttle.isCoolingDown(secondTrip, now: t0))

        throttle.record(failure(httpStatus: 503), now: t0)
        XCTAssertNil(throttle.entries[originalTrip], "A transient typed failure is not recorded")

        throttle.clearAll()
        XCTAssertTrue(throttle.entries.isEmpty)
    }

    // MARK: Resume target

    func testResumeTargetNamesTheOnlyOwningVineyard() {
        let trip = UUID()
        let accountVineyards: [(id: UUID, name: String)] = [
            (id: jhTesting, name: "JH Testing"), (id: stockmansRidge, name: "Stockmans Ridge")]

        XCTAssertEqual(
            TripResumeTarget.resolve(
                tripId: trip, selectedVineyardId: stockmansRidge,
                persistedSnapshots: [(tripId: trip, vineyardId: jhTesting)],
                accountVineyards: accountVineyards),
            TripResumeTarget(vineyardId: jhTesting, vineyardName: "JH Testing"))

        // Duplicate rows under one owner are still one owner.
        XCTAssertEqual(
            TripResumeTarget.resolve(
                tripId: trip, selectedVineyardId: stockmansRidge,
                persistedSnapshots: [(tripId: trip, vineyardId: jhTesting), (tripId: trip, vineyardId: jhTesting)],
                accountVineyards: accountVineyards)?.vineyardId, jhTesting)

        // The selected vineyard already owns it: nothing to switch to.
        XCTAssertNil(TripResumeTarget.resolve(
            tripId: trip, selectedVineyardId: jhTesting,
            persistedSnapshots: [(tripId: trip, vineyardId: jhTesting)], accountVineyards: accountVineyards))

        // Two vineyards claim it: ambiguous ownership offers nothing.
        XCTAssertNil(TripResumeTarget.resolve(
            tripId: trip, selectedVineyardId: UUID(),
            persistedSnapshots: [(tripId: trip, vineyardId: jhTesting), (tripId: trip, vineyardId: stockmansRidge)],
            accountVineyards: accountVineyards))

        // A vineyard outside the signed-in account is never offered.
        XCTAssertNil(TripResumeTarget.resolve(
            tripId: trip, selectedVineyardId: stockmansRidge,
            persistedSnapshots: [(tripId: trip, vineyardId: jhTesting)],
            accountVineyards: [(id: stockmansRidge, name: "Stockmans Ridge")]))

        // Another Trip's snapshot says nothing about this one.
        XCTAssertNil(TripResumeTarget.resolve(
            tripId: trip, selectedVineyardId: stockmansRidge,
            persistedSnapshots: [(tripId: UUID(), vineyardId: jhTesting)], accountVineyards: accountVineyards))
        XCTAssertNil(TripResumeTarget.resolve(
            tripId: trip, selectedVineyardId: stockmansRidge, persistedSnapshots: [], accountVineyards: accountVineyards))
    }

    func testResumeTargetTrimsNamesAndFallsBackWhenBlank() {
        let trip = UUID()
        XCTAssertEqual(
            TripResumeTarget.resolve(
                tripId: trip, selectedVineyardId: stockmansRidge,
                persistedSnapshots: [(tripId: trip, vineyardId: jhTesting)],
                accountVineyards: [(id: jhTesting, name: "  JH Testing \n")])?.vineyardName, "JH Testing")
        XCTAssertEqual(
            TripResumeTarget.resolve(
                tripId: trip, selectedVineyardId: stockmansRidge,
                persistedSnapshots: [(tripId: trip, vineyardId: jhTesting)],
                accountVineyards: [(id: jhTesting, name: "   ")])?.vineyardName,
            TripResumeTarget.unnamedVineyard)
        XCTAssertEqual(TripResumeTarget.unnamedVineyard, "the other vineyard")
    }

    // MARK: Queue breakdown

    func testQueueBreakdownBucketsAreMutuallyExclusiveAndAddUpToTheQueue() {
        let third = UUID(uuidString: "3C3C3C3C-3C3C-4C3C-8C3C-3C3C3C3C3C3C")!
        let live = UUID(uuidString: "0A5466DF-1111-4111-8111-111111111111")!
        let liveTwice = UUID(uuidString: "2BE68A70-2222-4222-8222-222222222222")!
        let cancelled = UUID(uuidString: "78BFC262-3333-4333-8333-333333333333")!
        let cancelledNoSnapshot = UUID(uuidString: "A3C31B89-4444-4444-8444-444444444444")!
        let other = UUID(uuidString: "492EBAFC-B996-4EC4-8EA9-4261A3056810")!
        let ambiguous = UUID(uuidString: "DEAD3350-5555-4555-8555-555555555555")!
        let noSnapshot = UUID(uuidString: "F2CBF5B2-6666-4666-8666-666666666666")!
        let queue: Set<UUID> = [live, liveTwice, cancelled, cancelledNoSnapshot, other, ambiguous, noSnapshot]

        let breakdown = TripQueueScopeBreakdown.evaluate(
            queuedIds: queue, selectedVineyardId: stockmansRidge,
            snapshots: [
                (tripId: live, vineyardId: stockmansRidge),
                (tripId: liveTwice, vineyardId: stockmansRidge), (tripId: liveTwice, vineyardId: stockmansRidge),
                (tripId: cancelled, vineyardId: stockmansRidge),
                (tripId: other, vineyardId: jhTesting),
                (tripId: ambiguous, vineyardId: jhTesting), (tripId: ambiguous, vineyardId: third),
                (tripId: UUID(), vineyardId: jhTesting),
            ],
            cancelledIds: [cancelled, cancelledNoSnapshot])

        XCTAssertEqual(breakdown.selectedVineyardLive, 2)
        XCTAssertEqual(breakdown.cancelledHistory, 2, "Cancelled history takes precedence over ownership")
        XCTAssertEqual(breakdown.otherVineyardSavedOnDevice,
                       [TripQueueScopeBreakdown.OtherVineyardEntry(tripId: other, vineyardId: jhTesting)])
        XCTAssertEqual(breakdown.unattributedOrAmbiguous, 2)
        XCTAssertEqual(breakdown.total, queue.count, "Every queued ID lands in exactly one bucket")

        let lines = breakdown.lines
        XCTAssertTrue(lines.contains("queue_breakdown_total: 7"))
        XCTAssertTrue(lines.contains("queue_breakdown_selected_vineyard_live: 2"))
        XCTAssertTrue(lines.contains("queue_breakdown_cancelled_history: 2"))
        XCTAssertTrue(lines.contains("queue_breakdown_other_vineyard_saved_on_device: 1"))
        XCTAssertTrue(lines.contains("queue_breakdown_unattributed_or_ambiguous_owner: 2"))
        XCTAssertTrue(lines.contains(
            "other_vineyard_queue_entry: trip=\(other.uuidString.lowercased()); saved_vineyard=\(jhTesting.uuidString.lowercased()); action: select_that_vineyard_to_resume; no_cross_vineyard_replay"))
        XCTAssertFalse(lines.joined(separator: "\n").contains(other.uuidString), "IDs are written lower-case")

        let empty = TripQueueScopeBreakdown.evaluate(
            queuedIds: [], selectedVineyardId: stockmansRidge, snapshots: [], cancelledIds: [])
        XCTAssertEqual(empty.total, 0)
        XCTAssertTrue(empty.lines.contains("queue_breakdown_total: 0"))
        XCTAssertFalse(empty.lines.contains { $0.hasPrefix("other_vineyard_queue_entry") })
    }

    // MARK: Server-terminal wording

    private func closureInput(
        evidence: TripClosureStatus.ServerEvidence, active: Bool = false,
        end: Date? = Date(timeIntervalSince1970: 1_793_600_000)
    ) -> TripClosureStatus.Input {
        TripClosureStatus.Input(
            tripId: "3bfb7f81-2ae2-4f33-8fd8-6666b2b45393", evidence: evidence,
            serverIsActive: active, serverEndTime: end, serverSessionIds: nil,
            locallyEnded: false, unresolvedMarkers: [], occurrencePending: 0, occurrenceHeldReason: nil,
            actualSessionIds: [], pendingActualIds: [], holdCodes: [])
    }

    func testOnlyAFreshServerReadIsLabelledAsTheServersTerminalState() {
        XCTAssertEqual(
            TripClosureStatus.terminalLine(closureInput(evidence: .freshRead, active: true, end: nil)),
            "  server_terminal: active=true; end_time_set=false")
        XCTAssertEqual(
            TripClosureStatus.terminalLine(closureInput(evidence: .freshRead, active: false)),
            "  server_terminal: active=false; end_time_set=true")

        // Build 215 printed this local value as the server's: the Trip looked
        // server-confirmed while the server still had it active.
        for evidence in [TripClosureStatus.ServerEvidence.ackedLocalRow, .readFailed, .absent] {
            let line = TripClosureStatus.terminalLine(closureInput(evidence: evidence, active: false))
            XCTAssertTrue(line.contains("server_terminal: not_read (evidence=\(evidence.rawValue))"), line)
            XCTAssertTrue(line.contains("local_row_active=false"), line)
            XCTAssertTrue(line.contains("local_row_end_time_set=true"), line)
            XCTAssertFalse(line.contains("server_terminal: active="), line)
        }
    }

    func testDiagnosticLinesUseTheSameTerminalLine() {
        for evidence in [TripClosureStatus.ServerEvidence.freshRead, .ackedLocalRow, .readFailed, .absent] {
            let input = closureInput(evidence: evidence)
            let lines = TripClosureStatus.diagnosticLines(input, TripClosureStatus.evaluate(input))
            XCTAssertTrue(lines[0].hasPrefix("trip_closure: trip=3bfb7f81-2ae2-4f33-8fd8-6666b2b45393 state="))
            XCTAssertEqual(lines[1], TripClosureStatus.terminalLine(input))
        }
    }
}

// MARK: - Part 2: shipping TripSyncService with a fake repository

@MainActor private final class ThrottleProbeRepository: TripSyncRepositoryProtocol {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
    private(set) var upsertCalls: [[UUID]] = []
    private(set) var accepted: [UUID] = []
    private(set) var establishCalls: [Set<String>] = []
    /// Trips whose upload is refused. A batch holding one fails as a whole,
    /// like a transactional upsert.
    var failures: [UUID: Error] = [:]
    var establishFailure: Error?

    func upsertTrips(_ trips: [BackendTripUpsert]) async throws {
        upsertCalls.append(trips.map(\.id))
        for trip in trips {
            if let failure = failures[trip.id] { throw failure }
        }
        accepted += trips.map(\.id)
    }
    func upsertTrip(_ trip: BackendTripUpsert) async throws { try await upsertTrips([trip]) }
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { [] }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { [] }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {}
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {}
    func softDeleteTrip(id: UUID) async throws {}
    func establishOccurrenceTankSessions(_ trip: BackendTripUpsert, required: Set<String>) async throws {
        establishCalls.append(required)
        if let establishFailure { throw establishFailure }
    }
}

@MainActor
final class TripSyncDeterministicFailureTests: XCTestCase {
    private let jhTesting = UUID(uuidString: "59973CED-1FB9-42EC-A66D-9EAAD3172824")!
    private let stockmansRidge = UUID(uuidString: "FE952AFE-437F-4BE7-8CBF-FDD8E630411C")!
    private let owner = UUID(uuidString: "94238371-53C6-472D-975B-48BF98A268A9")!
    private var directories: [URL] = []
    private var trackedTripIds: [UUID] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        SyncIssueCenter.shared.clearIssues(trackedTripIds)
        trackedTripIds = []
        super.tearDown()
    }

    private struct Harness {
        let service: TripSyncService
        let metadata: TripSyncMetadata
        let repository: ThrottleProbeRepository
        let store: MigratedDataStore
        let auth: NewBackendAuthService
    }

    private func harness(selected: UUID, trips: [Trip]) -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagefail-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let persistence = PersistenceStore(directory: directory)
        let metadata = TripSyncMetadata(persistence: persistence)
        let repository = ThrottleProbeRepository()
        let service = TripSyncService(repository: repository, metadata: metadata)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = selected
        store.trips = trips
        let account = owner
        store.currentUserIdProvider = { account }
        let auth = NewBackendAuthService()
        auth.isSignedIn = true
        auth.userId = account
        service.configure(store: store, auth: auth)
        trackedTripIds += trips.map(\.id)
        return Harness(service: service, metadata: metadata, repository: repository, store: store, auth: auth)
    }

    private func activeTrip(vineyard: UUID) -> Trip {
        Trip(id: UUID(), vineyardId: vineyard, startTime: Date(timeIntervalSince1970: 1_790_000_000),
             endTime: nil, isActive: true)
    }

    private func endedOccurrenceTrip(vineyard: UUID, session: UUID) throws -> Trip {
        let block = UUID()
        let coverage = try TripOccurrencePlanner.commit([
            .init(vineyardId: vineyard, blockId: block, blockName: "Original", label: 1.5, rows: [])
        ], vineyardId: vineyard)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let end = Date(timeIntervalSince1970: 1_790_000_600)
        return Trip(vineyardId: vineyard, paddockId: block, paddockName: "Original", paddockIds: [block],
                    startTime: start, endTime: end, isActive: false, rowSequence: [1.5],
                    tankSessions: [TankSession(id: session, tankNumber: 1, startTime: start, endTime: end)],
                    occurrenceCoverage: coverage)
    }

    /// The incident's exact answer: PostgREST reports SQLSTATE 40001 as HTTP 500
    /// and the server's message is the rejection token.
    private func tankLinkConflict(_ tripId: UUID) -> TripSyncStageFailure {
        TripSyncStageFailure(
            rejection: OccurrenceRPCFailure(code: "OCCURRENCE_TANK_LINK_CONFLICT", httpStatus: 500,
                                            postgrestCode: "40001", message: "OCCURRENCE_TANK_LINK_CONFLICT"),
            rpc: "apply_trip_occurrence_action_v1", tripId: tripId,
            operationId: "0f6c2f0e-6a43-4a8e-9a38-7a1f6d2f6c11", journalHeld: false)
    }

    // MARK: Deterministic answers are kept and not re-sent

    func testDeterministicServerAnswerIsKeptVisibleAndNotResentUntilNewEvidence() async throws {
        let trip = activeTrip(vineyard: jhTesting)
        let h = harness(selected: jhTesting, trips: [trip])
        h.repository.failures[trip.id] = tankLinkConflict(trip.id)
        h.metadata.markDirty(trip.id, at: Date())

        // Sweep 1: one request. The typed answer is recorded and nothing is discarded.
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.upsertCalls.count, 1)
        XCTAssertNotNil(h.metadata.pendingUpserts[trip.id], "A failure never clears the queue entry")
        XCTAssertTrue(h.metadata.isUpsertFailed(trip.id))
        XCTAssertTrue(h.service.coolingDownTripIds().contains(trip.id))
        XCTAssertEqual(h.store.trips.map(\.id), [trip.id])
        let issue = try XCTUnwrap(SyncIssueCenter.shared.issues[trip.id])
        XCTAssertEqual(issue.reasonCode, "OCCURRENCE_TANK_LINK_CONFLICT")
        XCTAssertEqual(issue.kind, .permanent)
        XCTAssertEqual(issue.entity, "Trips")
        XCTAssertTrue(issue.technicalDetail.contains("http_status: 500"))
        XCTAssertTrue(issue.technicalDetail.contains("postgrest_code: 40001"))

        // Sweep 2, nothing changed: the same answer is not requested again.
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.upsertCalls.count, 1)
        XCTAssertNotNil(h.metadata.pendingUpserts[trip.id])
        XCTAssertNotNil(SyncIssueCenter.shared.issues[trip.id], "The reason stays on screen while waiting")

        // An explicit Sync re-checks every Trip at once.
        h.service.clearRetryCooldowns()
        XCTAssertTrue(h.service.coolingDownTripIds().isEmpty)
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.upsertCalls.count, 2)

        // A new local edit through the production wiring (store -> onTripChanged
        // -> markTripDirty) is new evidence and lifts the cooldown for that Trip.
        XCTAssertTrue(h.service.coolingDownTripIds().contains(trip.id))
        var edited = try XCTUnwrap(h.store.trips.first { $0.id == trip.id })
        edited.completionNotes = "operator note"
        h.store.updateTrip(edited)
        XCTAssertFalse(h.service.coolingDownTripIds().contains(trip.id))
        XCTAssertFalse(h.metadata.isUpsertFailed(trip.id))
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.upsertCalls.count, 3)
    }

    func testHeldJournalAnswerIsThrottledToo() async throws {
        let trip = activeTrip(vineyard: jhTesting)
        let h = harness(selected: jhTesting, trips: [trip])
        h.repository.failures[trip.id] = TripSyncStageFailure(
            stage: .occurrenceAction, tripId: trip.id, endpoint: "local/occurrence-journal",
            verificationCode: TripSyncVerificationCode.journalHeld, journalHeld: true)
        h.metadata.markDirty(trip.id, at: Date())

        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.upsertCalls.count, 1)
        XCTAssertTrue(h.service.coolingDownTripIds().contains(trip.id))
        let issue = try XCTUnwrap(SyncIssueCenter.shared.issues[trip.id])
        XCTAssertEqual(issue.reasonCode, "OCCURRENCE_JOURNAL_HELD")
        XCTAssertEqual(issue.kind, .permanent)
        XCTAssertNotNil(h.metadata.pendingUpserts[trip.id])
    }

    func testTransientFailureIsNeverThrottled() async throws {
        let trip = activeTrip(vineyard: jhTesting)
        let h = harness(selected: jhTesting, trips: [trip])
        h.repository.failures[trip.id] = TripSyncStageFailure(
            stage: .tripUpsert, tripId: trip.id, endpoint: "POST rest/v1/trips",
            transportCode: URLError.timedOut.rawValue)
        h.metadata.markDirty(trip.id, at: Date())

        for sweep in 1...3 {
            do {
                try await h.service.pushLocalTrips(vineyardId: jhTesting)
                XCTFail("A transient failure must still report a failed sweep (\(sweep))")
            } catch {
                XCTAssertTrue(error is SyncPushError, "\(error)")
            }
            XCTAssertEqual(h.repository.upsertCalls.count, sweep, "Every sweep retries a transient failure")
            XCTAssertTrue(h.service.coolingDownTripIds().isEmpty)
        }
        let issue = try XCTUnwrap(SyncIssueCenter.shared.issues[trip.id])
        XCTAssertEqual(issue.kind, .retryable)
        XCTAssertEqual(issue.reasonCode, "NETWORK_-1001")
        XCTAssertNotNil(h.metadata.pendingUpserts[trip.id])
    }

    func testOneRejectedTripNeitherBlocksNorThrottlesAHealthyTrip() async throws {
        let bad = activeTrip(vineyard: jhTesting)
        let good = activeTrip(vineyard: jhTesting)
        let h = harness(selected: jhTesting, trips: [bad, good])
        h.repository.failures[bad.id] = TripSyncStageFailure(
            stage: .tripUpsert, tripId: bad.id, endpoint: "POST rest/v1/trips", httpStatus: 400,
            postgrestCode: "22P02", serverMessage: "invalid input syntax for type uuid")
        h.metadata.markDirty(bad.id, at: Date())
        h.metadata.markDirty(good.id, at: Date())

        // The batch fails as a whole, then each Trip is sent on its own.
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.upsertCalls.count, 3)
        XCTAssertEqual(h.repository.accepted, [good.id])
        XCTAssertNil(h.metadata.pendingUpserts[good.id])
        XCTAssertNotNil(h.metadata.pendingUpserts[bad.id])
        XCTAssertTrue(h.metadata.isUpsertFailed(bad.id))
        XCTAssertEqual(h.service.coolingDownTripIds(), [bad.id])
        XCTAssertEqual(SyncIssueCenter.shared.issues[bad.id]?.reasonCode, "22P02")
        XCTAssertEqual(SyncIssueCenter.shared.issues[bad.id]?.kind, .permanent)
        XCTAssertNil(SyncIssueCenter.shared.issues[good.id])

        // Nothing is left to send: the rejected Trip waits, the good one is done.
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.upsertCalls.count, 3)
    }

    // MARK: Occurrence tank-staging stage

    func testTankStageRejectionKeepsTheOriginalEvidenceCoolsDownAndRetriesAfterNewEvidence() async throws {
        let session = UUID()
        let trip = try endedOccurrenceTrip(vineyard: jhTesting, session: session)
        let h = harness(selected: jhTesting, trips: [trip])
        let tripId = trip.id
        let requiredSession = session.uuidString.lowercased()
        h.service.configurePhase5EndGate { $0 == tripId }
        h.service.configureTankDependencies { $0 == tripId ? [requiredSession] : [] }
        h.repository.establishFailure = TripSyncStageFailure(
            stage: .tankStagingPatch, tripId: tripId,
            endpoint: "PATCH rest/v1/trips (tank_sessions, compare-and-swap)",
            httpStatus: 400, postgrestCode: "PGRST204", serverMessage: "schema cache")
        let queuedAt = Date()
        h.metadata.markDirty(tripId, at: queuedAt)

        // Sweep 1: the stage runs once and stops with the server's own code.
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.establishCalls, [[requiredSession]])
        XCTAssertEqual(h.service.tankDependencyHolds[tripId], TankDependencyVerification.patchReadbackMismatch)
        XCTAssertEqual(h.metadata.pendingUpserts[tripId], queuedAt, "The original queue entry and revision are untouched")
        XCTAssertTrue(h.metadata.isUpsertFailed(tripId))
        XCTAssertFalse(h.metadata.isParentEstablished(tripId), "A failed stage is not an acknowledgement")
        XCTAssertTrue(h.service.coolingDownTripIds().contains(tripId))
        let issue = try XCTUnwrap(SyncIssueCenter.shared.issues[tripId])
        XCTAssertEqual(issue.reasonCode, "PGRST204")
        XCTAssertEqual(issue.kind, .permanent)
        let kept = try XCTUnwrap(h.store.trips.first { $0.id == tripId })
        XCTAssertEqual(kept.tankSessions.map(\.id), [session], "The original tank session is kept, never replaced")
        XCTAssertEqual(kept.endTime, trip.endTime)
        XCTAssertFalse(kept.isActive)

        // Sweep 2: the same answer is not requested again.
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.establishCalls.count, 1)

        // Sync now re-checks immediately.
        h.service.clearRetryCooldowns()
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.establishCalls.count, 2)

        // The server is repaired: the same original Trip and session now succeed.
        h.repository.establishFailure = nil
        h.service.clearRetryCooldowns()
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.establishCalls.count, 3)
        XCTAssertTrue(h.metadata.isParentEstablished(tripId))
        XCTAssertNil(h.service.tankDependencyHolds[tripId])
        XCTAssertNil(SyncIssueCenter.shared.issues[tripId])
        XCTAssertTrue(h.service.coolingDownTripIds().isEmpty)
        XCTAssertNotNil(h.metadata.pendingUpserts[tripId], "Staging the tanks is not a Trip completion receipt")
        XCTAssertTrue(h.repository.upsertCalls.isEmpty, "The original finalise is never sent from the staging stage")
    }

    // MARK: Vineyard fence and resume

    func testOtherVineyardTripIsNotSentFromTheWrongVineyardAndResumesWithTheSameIdAfterSwitching() async throws {
        let original = activeTrip(vineyard: jhTesting)
        let h = harness(selected: stockmansRidge, trips: [])
        trackedTripIds.append(original.id)
        h.store.tripRepo.saveSlice([original], for: jhTesting)
        h.metadata.markDirty(original.id, at: Date())

        // Selected vineyard is Stockmans Ridge: the Trip is fenced off, untouched and still queued.
        try await h.service.pushLocalTrips(vineyardId: stockmansRidge)
        XCTAssertTrue(h.repository.upsertCalls.isEmpty, "No cross-vineyard replay")
        XCTAssertNotNil(h.metadata.pendingUpserts[original.id])
        XCTAssertFalse(h.metadata.isUpsertFailed(original.id))
        XCTAssertTrue(h.service.coolingDownTripIds().isEmpty)

        // Selecting the owning vineyard resumes the same Trip under its own identity.
        h.store.selectedVineyardId = jhTesting
        h.store.trips = h.store.tripRepo.load(for: jhTesting)
        XCTAssertEqual(h.store.trips.map(\.id), [original.id])
        try await h.service.pushLocalTrips(vineyardId: jhTesting)
        XCTAssertEqual(h.repository.upsertCalls, [[original.id]])
        XCTAssertEqual(h.repository.accepted, [original.id])
        XCTAssertNil(h.metadata.pendingUpserts[original.id])
    }

    func testGuidedQueueNamesTheOwningVineyardAndNeverUploads() async throws {
        let original = activeTrip(vineyard: jhTesting)
        let h = harness(selected: stockmansRidge, trips: [])
        trackedTripIds.append(original.id)
        h.store.tripRepo.saveSlice([original], for: jhTesting)
        h.store.vineyards = [Vineyard(id: stockmansRidge, name: "Stockmans Ridge"),
                             Vineyard(id: jhTesting, name: "JH Testing")]
        h.metadata.markDirty(original.id, at: Date())

        let item = try XCTUnwrap(h.service.guidedQueueItems(vineyardId: stockmansRidge).first { $0.id == original.id })
        XCTAssertTrue(item.pendingUpload)
        XCTAssertFalse(item.belongsToCurrentVineyard)
        XCTAssertFalse(item.originalTripPresent)
        XCTAssertEqual(item.resumeTarget, TripResumeTarget(vineyardId: jhTesting, vineyardName: "JH Testing"))

        // The owning vineyard is not in this account's list: nothing is offered.
        h.store.vineyards = [Vineyard(id: stockmansRidge, name: "Stockmans Ridge")]
        let hidden = try XCTUnwrap(h.service.guidedQueueItems(vineyardId: stockmansRidge).first { $0.id == original.id })
        XCTAssertNil(hidden.resumeTarget)
        XCTAssertFalse(hidden.belongsToCurrentVineyard)

        // Selected vineyard owns it: it belongs here and no switch is offered.
        h.store.vineyards = [Vineyard(id: stockmansRidge, name: "Stockmans Ridge"),
                             Vineyard(id: jhTesting, name: "JH Testing")]
        h.store.selectedVineyardId = jhTesting
        h.store.trips = [original]
        let own = try XCTUnwrap(h.service.guidedQueueItems(vineyardId: jhTesting).first { $0.id == original.id })
        XCTAssertTrue(own.belongsToCurrentVineyard)
        XCTAssertTrue(own.originalTripPresent)
        XCTAssertNil(own.resumeTarget)

        XCTAssertTrue(h.repository.upsertCalls.isEmpty, "Reading the queue never uploads")
        XCTAssertNotNil(h.metadata.pendingUpserts[original.id])
    }

    // MARK: Scoped support export

    func testScopedSupportExportShowsTypedCodesButNeverServerText() async throws {
        let tripId = UUID(), freeTextId = UUID()
        trackedTripIds += [tripId, freeTextId]
        let typed = TripSyncStageFailure(
            stage: .occurrenceAction, tripId: tripId, endpoint: "rpc/apply_trip_occurrence_action_v1",
            httpStatus: 500, postgrestCode: "40001",
            serverMessage: "OCCURRENCE_TANK_LINK_CONFLICT Chardonnay Block 7 mix 2.5 L",
            occurrenceCode: "OCCURRENCE_TANK_LINK_CONFLICT")
        SyncIssueCenter.shared.recordFailure(
            id: tripId, entity: "Trips", detail: typed.syncFailureDetail,
            queuedAt: nil, payloadKeys: [], vineyardId: jhTesting)

        let text = SyncIssueCenter.shared.privateSafeDiagnosticsText(vineyardId: jhTesting, visibleIds: [tripId])
        XCTAssertTrue(text.contains("record_id: \(tripId.uuidString.lowercased())"))
        XCTAssertTrue(text.contains("failure_code: OCCURRENCE_TANK_LINK_CONFLICT"))
        XCTAssertTrue(text.contains("retry_classification: permanent"))
        XCTAssertFalse(text.contains("Chardonnay"))
        XCTAssertFalse(text.contains("2.5 L"))

        // Another vineyard, or an ID that is not visible, never appears.
        let wrongVineyard = SyncIssueCenter.shared.privateSafeDiagnosticsText(
            vineyardId: stockmansRidge, visibleIds: [tripId])
        XCTAssertFalse(wrongVineyard.contains(tripId.uuidString.lowercased()))
        let notVisible = SyncIssueCenter.shared.privateSafeDiagnosticsText(vineyardId: jhTesting, visibleIds: [])
        XCTAssertFalse(notVisible.contains(tripId.uuidString.lowercased()))

        // A free-text reason code is never exported.
        SyncIssueCenter.shared.recordFailure(
            id: freeTextId, entity: "Trips",
            detail: SyncFailureDetail(kind: .retryable, reasonCode: "Chardonnay Block 7",
                                      friendlyMessage: "x", technicalDetail: "y"),
            queuedAt: nil, payloadKeys: [], vineyardId: jhTesting)
        let freeText = SyncIssueCenter.shared.privateSafeDiagnosticsText(
            vineyardId: jhTesting, visibleIds: [freeTextId])
        XCTAssertTrue(freeText.contains("failure_code: UNCLASSIFIED_FAILURE_REQUIRES_PRIVATE_REVIEW"))
        XCTAssertFalse(freeText.contains("Chardonnay"))
    }
}
