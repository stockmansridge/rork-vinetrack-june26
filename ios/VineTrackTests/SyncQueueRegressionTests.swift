import Testing
import Foundation
@testable import VineTrack

/// Regression suite for the "22 pending uploads never clear" production issue
/// and the Grant Unlimited "The data couldn't be read because it isn't in the
/// correct format." decode failure.
///
/// Everything here is pure logic — no network, no Supabase client.
@MainActor
struct SyncQueueRegressionTests {

    // MARK: - Fixtures

    /// Minimal stand-in for a real upsert payload.
    nonisolated struct FakePayload: Encodable, Sendable {
        let id: UUID
        let vineyard_id: UUID
        let note: String
    }

    /// Server error whose description carries a PostgREST/Postgres code.
    nonisolated struct FakeServerError: Error {
        let text: String
    }

    private func payload(_ id: UUID, note: String = "field note") -> FakePayload {
        FakePayload(id: id, vineyard_id: UUID(), note: note)
    }

    // MARK: - One bad item must not block the rest

    @Test("First queue item fails while later items still upload")
    func firstItemFailureDoesNotBlockTheQueue() async {
        SyncIssueCenter.shared.clearAll()
        let ids = (0..<3).map { _ in UUID() }
        let payloads = ids.map { payload($0) }
        let poisoned = ids[0]

        let result = await SyncQueuePush.run(
            entity: "Work Tasks",
            ids: ids,
            payloads: payloads
        ) { batch in
            if batch.contains(where: { $0.id == poisoned }) {
                throw FakeServerError(text: "null value in column \"task_type\" violates not-null constraint (23502)")
            }
        }

        #expect(result.uploaded.count == 2)
        #expect(!result.uploaded.contains(poisoned))
        #expect(result.permanent == [poisoned])
        #expect(result.retryable.isEmpty)
        // A permanent rejection is not an error the whole sweep should throw on.
        #expect(result.firstRetryableError == nil)
    }

    @Test("A healthy batch uploads in one round trip and clears immediately")
    func healthyBatchUsesFastPath() async {
        SyncIssueCenter.shared.clearAll()
        let ids = (0..<22).map { _ in UUID() }
        var callCount = 0

        let result = await SyncQueuePush.run(
            entity: "Work Tasks",
            ids: ids,
            payloads: ids.map { payload($0) }
        ) { _ in callCount += 1 }

        #expect(callCount == 1)
        #expect(result.uploaded.count == 22)
        #expect(!result.hasFailures)
        #expect(SyncIssueCenter.shared.hasIssues == false)
    }

    @Test("Transient failures stay retryable and surface one error")
    func transientFailuresAreRetryable() async {
        SyncIssueCenter.shared.clearAll()
        let ids = (0..<2).map { _ in UUID() }

        let result = await SyncQueuePush.run(
            entity: "Fuel Logs",
            ids: ids,
            payloads: ids.map { payload($0) }
        ) { _ in throw URLError(.timedOut) }

        #expect(result.uploaded.isEmpty)
        #expect(result.retryable.count == 2)
        #expect(result.permanent.isEmpty)
        #expect(result.firstRetryableError != nil)
    }

    @Test("Retrying re-sends the same record id, so the server can't duplicate it")
    func retryIsIdempotentOnRecordId() async {
        SyncIssueCenter.shared.clearAll()
        let id = UUID()
        var seenIds: [UUID] = []

        for attempt in 0..<2 {
            _ = await SyncQueuePush.run(
                entity: "Yield Estimates",
                ids: [id],
                payloads: [payload(id)]
            ) { batch in
                seenIds.append(contentsOf: batch.map(\.id))
                if attempt == 0 { throw URLError(.networkConnectionLost) }
            }
        }

        // Both the failed attempt and the retry carried the SAME primary key,
        // so `upsert(onConflict: "id")` updates one row instead of inserting two.
        #expect(seenIds == [id, id])
        #expect(Set(seenIds).count == 1)
    }

    @Test("Successful items are reported for immediate queue removal")
    func successfulItemsAreReportedOnce() async {
        SyncIssueCenter.shared.clearAll()
        let good = UUID()
        let bad = UUID()

        let result = await SyncQueuePush.run(
            entity: "Damage Records",
            ids: [bad, good],
            payloads: [payload(bad), payload(good)]
        ) { batch in
            if batch.contains(where: { $0.id == bad }) {
                throw FakeServerError(text: "PGRST204 column \"widget\" of relation does not exist")
            }
        }

        #expect(result.uploaded == [good])
        #expect(result.permanent == [bad])
    }

    // MARK: - Issue registry

    @Test("Failures register a grouped, sanitised diagnostic with payload keys only")
    func issueCenterRecordsSanitisedDiagnostics() async {
        SyncIssueCenter.shared.clearAll()
        let id = UUID()

        _ = await SyncQueuePush.run(
            entity: "Work Tasks",
            ids: [id],
            payloads: [payload(id, note: "top secret vineyard note")]
        ) { _ in throw FakeServerError(text: "23503 insert or update violates foreign key constraint") }

        SyncIssueCenter.shared.notePending(entity: "Work Tasks", count: 18)
        let summaries = SyncIssueCenter.shared.summaries
        #expect(summaries.count == 1)
        #expect(summaries.first?.entity == "Work Tasks")
        #expect(summaries.first?.waiting == 18)
        #expect(summaries.first?.permanent == 1)

        let dump = SyncIssueCenter.shared.diagnosticsText()
        #expect(dump.contains(id.uuidString))
        #expect(dump.contains("payload_keys: id,note,vineyard_id"))
        // Values are never dumped — only key names.
        #expect(!dump.contains("top secret vineyard note"))
    }

    @Test("Uploading a previously failed record clears its issue")
    func successClearsPreviousIssue() async {
        SyncIssueCenter.shared.clearAll()
        let id = UUID()
        var shouldFail = true

        _ = await SyncQueuePush.run(entity: "Trips", ids: [id], payloads: [payload(id)]) { _ in
            if shouldFail { throw URLError(.timedOut) }
        }
        #expect(SyncIssueCenter.shared.issues[id] != nil)

        shouldFail = false
        _ = await SyncQueuePush.run(entity: "Trips", ids: [id], payloads: [payload(id)]) { _ in }
        #expect(SyncIssueCenter.shared.issues[id] == nil)
    }

    // MARK: - Error classification

    @Test("Retryable vs permanent classification")
    func errorClassification() {
        let offline = BackendErrorDiagnostics.classify(URLError(.notConnectedToInternet), endpoint: "work_tasks")
        #expect(offline.kind == .retryable)

        let notNull = BackendErrorDiagnostics.classify(
            FakeServerError(text: "23502 null value in column"), endpoint: "work_tasks"
        )
        #expect(notNull.kind == .permanent)
        #expect(notNull.reasonCode == "23502")

        let missingColumn = BackendErrorDiagnostics.classify(
            FakeServerError(text: "PGRST204 Could not find the 'foo' column"), endpoint: "work_tasks"
        )
        #expect(missingColumn.kind == .permanent)

        let serverBlip = BackendErrorDiagnostics.classify(
            FakeServerError(text: "503 service unavailable"), endpoint: "work_tasks"
        )
        #expect(serverBlip.kind == .retryable)

        // Unknown failures must stay retryable — never strand a valid record.
        let mystery = BackendErrorDiagnostics.classify(
            FakeServerError(text: "something odd happened"), endpoint: "work_tasks"
        )
        #expect(mystery.kind == .retryable)
    }

    @Test("An acknowledgement decode failure is diagnosed, not swallowed")
    func acknowledgementDecodeFailureIsDiagnosed() throws {
        struct Ack: Decodable { let id: UUID }
        let body = Data(#"{"id": 12345}"#.utf8)
        var thrown: Error?
        do { _ = try JSONDecoder().decode(Ack.self, from: body) } catch { thrown = error }

        let decodeError = try #require(thrown)
        let detail = BackendErrorDiagnostics.classify(decodeError, endpoint: "work_tasks.upsert")
        #expect(detail.kind == .permanent)
        #expect(detail.reasonCode == "response_decode_failed")
        #expect(detail.technicalDetail.contains("typeMismatch"))
        #expect(detail.technicalDetail.contains("coding_path: .id"))
    }

    @Test("Credentials never reach the diagnostics dump")
    func sanitiserRedactsSecrets() {
        let raw = #"{"access_token":"eyJhbGciOi.SECRET","message":"denied"}"#
        let clean = BackendErrorDiagnostics.sanitise(raw)
        #expect(!clean.contains("eyJhbGciOi.SECRET"))
        #expect(clean.contains("<redacted>"))
        #expect(clean.contains("denied"))
    }
}

/// `admin_list_user_vineyards` contract regressions — the Grant Unlimited
/// Primary Vineyard failure.
struct UserVineyardDecodingTests {

    /// Mirrors the private DTO in `SupabaseAdminRepository` field-for-field so
    /// the wire contract is protected by tests.
    nonisolated struct VineyardRow: Decodable, Sendable {
        let id: FlexibleUUID
        let name: String?
        let role: String?
        let isOwner: Bool?
        let country: String?
        let createdAt: Date?
        let deletedAt: Date?
        let memberCount: FlexibleInt?

        enum CodingKeys: String, CodingKey {
            case id, name, role, country
            case isOwner = "is_owner"
            case createdAt = "created_at"
            case deletedAt = "deleted_at"
            case memberCount = "member_count"
        }
    }

    private func decode(_ json: String) throws -> [VineyardRow] {
        try RPCDecoding.rows(
            VineyardRow.self,
            from: Data(json.utf8),
            status: 200,
            endpoint: "admin_list_user_vineyards"
        )
    }

    @Test("Live contract decodes, including columns the app doesn't know about")
    func decodesLiveContractWithExtraFields() throws {
        let rows = try decode("""
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Stockmans Ridge","role":"owner",
          "is_owner":true,"country":"AU","created_at":"2026-01-05T04:05:06+00:00",
          "deleted_at":null,"member_count":4,
          "grant_scope":"vineyard","is_billing_authority":true,"future_column":{"nested":1}}]
        """)
        #expect(rows.count == 1)
        #expect(rows[0].name == "Stockmans Ridge")
        #expect(rows[0].isOwner == true)
        #expect(rows[0].memberCount?.value == 4)
        #expect(rows[0].createdAt != nil)
    }

    @Test("Nullable role, country, name, timestamps and member_count survive")
    func decodesNullableFields() throws {
        let rows = try decode("""
        [{"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","name":null,"role":null,"is_owner":null,
          "country":null,"created_at":null,"deleted_at":null,"member_count":null}]
        """)
        #expect(rows.count == 1)
        #expect(rows[0].name == nil)
        #expect(rows[0].isOwner == nil)
        #expect(rows[0].memberCount == nil)
    }

    @Test("member_count as a string still decodes as a number")
    func decodesBigintAsString() throws {
        let rows = try decode("""
        [{"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","name":"Hill Block","member_count":"12"}]
        """)
        #expect(rows[0].memberCount?.value == 12)
    }

    @Test("An empty membership list is an empty result, never an error")
    func emptyResultIsNotAnError() throws {
        #expect(try decode("[]").isEmpty)
        #expect(try decode("null").isEmpty)
        #expect(try decode("").isEmpty)
    }

    @Test("A single object response is accepted as one row")
    func singleObjectResponse() throws {
        let rows = try decode("""
        {"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","name":"Solo Block","member_count":1}
        """)
        #expect(rows.count == 1)
        #expect(rows[0].name == "Solo Block")
    }

    @Test("An array wrapped in an envelope is unwrapped")
    func envelopeResponse() throws {
        let rows = try decode("""
        {"rows":[{"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","name":"Envelope Block"}]}
        """)
        #expect(rows.count == 1)
        #expect(rows[0].name == "Envelope Block")
    }

    @Test("Timestamps in Postgres space format decode")
    func postgresTimestampFormat() throws {
        let rows = try decode("""
        [{"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","name":"Old Block",
          "created_at":"2026-01-05 04:05:06+00"}]
        """)
        #expect(rows[0].createdAt != nil)
    }

    @Test("Malformed data reports the exact contract mismatch, not a generic message")
    func malformedResponseIsFullyDiagnosed() {
        var caught: RPCDecodingFailure?
        do {
            _ = try decode("""
            [{"id":12345,"name":"Bad Id Block"}]
            """)
        } catch let failure as RPCDecodingFailure {
            caught = failure
        } catch {
            Issue.record("expected RPCDecodingFailure, got \(error)")
        }

        guard let caught else {
            Issue.record("expected a decode failure")
            return
        }
        #expect(caught.endpoint == "admin_list_user_vineyards")
        #expect(caught.status == 200)
        #expect(caught.diagnostics.contains("coding_path"))
        #expect(caught.diagnostics.contains("actual_json_type: integer"))
        #expect(caught.diagnostics.contains("http_status: 200"))
        // The user-facing text is actionable, not "data couldn't be read".
        #expect(caught.errorDescription?.contains("Retry") == true)
    }

    @Test("A scalar response is rejected with diagnostics rather than crashing the screen")
    func scalarResponseIsRejected() {
        #expect(throws: RPCDecodingFailure.self) {
            _ = try decode("\"unexpected\"")
        }
    }
}

/// "Last full sync" must never advertise success while uploads are stuck.
@MainActor
struct SyncStatusTimestampTests {

    @Test("Full-sync timestamp does not advance while uploads remain")
    func fullSyncBlockedByPendingUploads() {
        let center = SyncStatusCenter()
        center.syncDidStart()
        center.syncDidFinish(upserts: 22, deletes: 0, pullSucceeded: true, error: nil)

        #expect(center.lastFullSyncAt == nil)
        #expect(center.lastPullAt != nil)          // the download really did work
        #expect(center.lastUploadAt == nil)
        #expect(center.incompleteSummary == "Sync incomplete — 22 items still waiting")
        #expect(center.displayState(isOnline: true) == .pending(22))
    }

    @Test("Full-sync timestamp advances only when the queue drains")
    func fullSyncAdvancesWhenDrained() {
        let center = SyncStatusCenter()
        center.syncDidStart()
        center.syncDidFinish(upserts: 0, deletes: 0, pullSucceeded: true, error: nil)

        #expect(center.lastFullSyncAt != nil)
        #expect(center.lastUploadAt != nil)
        #expect(center.incompleteSummary == nil)
        #expect(center.displayState(isOnline: true) == .synced)
    }

    @Test("A failed sweep records the failure and leaves the full-sync stamp alone")
    func failureDoesNotAdvanceFullSync() {
        let center = SyncStatusCenter()
        center.syncDidStart()
        center.syncDidFinish(upserts: 3, deletes: 1, pullSucceeded: false, error: "Couldn't reach the server")

        #expect(center.lastFullSyncAt == nil)
        #expect(center.lastPullAt == nil)
        #expect(center.lastFailureAt != nil)
        #expect(center.lastAttemptAt != nil)
        #expect(center.pendingTotal == 4)
    }
}
