//
//  SyncQueueDiagnostics.swift
//  VineTrack
//
//  Shared, transport-level diagnostics for every offline queue push and every
//  Supabase RPC decode.
//
//  Three concerns live here:
//
//    1. `BackendErrorDiagnostics` — turns an opaque `Error` (PostgREST failure,
//       URLError, `DecodingError`) into a *precise* technical description plus a
//       retryable / permanent classification. Decoding failures report the
//       coding path, the offending key, the expected Swift type and the actual
//       JSON value type — never just "The data couldn't be read".
//
//    2. `SyncIssueCenter` — an app-wide, per-record registry of queue failures
//       so the Sync screen can say *which* records are stuck and *why*, and so
//       "Copy diagnostics" produces something actionable.
//
//    3. `SyncQueuePush` — the shared upload driver. It tries the batch, and on
//       failure falls back to uploading every item individually so ONE bad
//       record can never block the other twenty-one.
//
//  Nothing here logs access tokens, refresh tokens, signed URLs or free-text
//  user content — payloads are reduced to their *key names* only.
//

import Foundation
import Observation

// MARK: - Failure classification

/// Whether a failed queue item should be retried automatically.
nonisolated enum SyncFailureKind: String, Sendable, Codable {
    /// Transient — network, timeout, 5xx, rate limit. Stays queued, retries.
    case retryable
    /// The server will never accept this record as-is (validation, schema,
    /// permission). Stays queued (we never silently discard user records) but
    /// is surfaced to the user with a reason instead of retrying silently.
    case permanent
}

/// A classified, human-explainable failure.
nonisolated struct SyncFailureDetail: Sendable, Equatable {
    let kind: SyncFailureKind
    /// Stable machine code, e.g. `23502`, `pgrst204`, `network_offline`.
    let reasonCode: String
    /// Short operator-facing sentence. Never raw JSON.
    let friendlyMessage: String
    /// Full sanitised technical detail for the diagnostics dump.
    let technicalDetail: String
}

// MARK: - Error diagnostics

nonisolated enum BackendErrorDiagnostics {

    // MARK: Decoding

    /// Full breakdown of a `DecodingError`: coding path, key, expected type and
    /// the value actually received. Returns `nil` for non-decoding errors.
    static func decodingDescription(_ error: Error, endpoint: String) -> String? {
        guard let decodingError = error as? DecodingError else { return nil }
        var lines: [String] = ["endpoint: \(endpoint)"]

        switch decodingError {
        case let .keyNotFound(key, context):
            lines.append("case: keyNotFound")
            lines.append("missing_key: \(key.stringValue)")
            lines.append("coding_path: \(path(context))")
            lines.append("context: \(context.debugDescription)")
        case let .typeMismatch(type, context):
            lines.append("case: typeMismatch")
            lines.append("expected_swift_type: \(type)")
            lines.append("coding_path: \(path(context))")
            lines.append("context: \(context.debugDescription)")
        case let .valueNotFound(type, context):
            lines.append("case: valueNotFound (server sent null)")
            lines.append("expected_swift_type: \(type)")
            lines.append("coding_path: \(path(context))")
            lines.append("context: \(context.debugDescription)")
        case let .dataCorrupted(context):
            lines.append("case: dataCorrupted")
            lines.append("coding_path: \(path(context))")
            lines.append("context: \(context.debugDescription)")
        @unknown default:
            lines.append("case: unknown")
            lines.append("raw: \(String(describing: decodingError))")
        }
        return lines.joined(separator: "\n")
    }

    private static func path(_ context: DecodingError.Context) -> String {
        guard !context.codingPath.isEmpty else { return "<root>" }
        return context.codingPath
            .map { $0.intValue.map { i in "[\(i)]" } ?? ".\($0.stringValue)" }
            .joined()
    }

    /// The JSON value kind actually present at a coding path, so a report can
    /// say "expected UUID, received number". Best-effort — returns nil when the
    /// body isn't JSON or the path can't be walked.
    static func actualValueType(in data: Data, at codingPath: [CodingKey]) -> String? {
        guard var current = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for key in codingPath {
            if let index = key.intValue {
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            } else {
                guard let object = current as? [String: Any], let next = object[key.stringValue] else { return nil }
                current = next
            }
        }
        return jsonTypeName(current)
    }

    private static func jsonTypeName(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let n as NSNumber:
            // Bool and numbers are both NSNumber in Foundation JSON.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "bool" }
            return n.doubleValue == n.doubleValue.rounded() ? "integer" : "decimal"
        case is String: return "string"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return String(describing: type(of: value))
        }
    }

    // MARK: Sanitising

    private static let sensitiveKeys: [String] = [
        "access_token", "refresh_token", "authorization", "apikey", "api_key",
        "password", "signature", "token", "secret", "jwt", "session",
    ]

    /// Redacts credentials and signed URLs, then truncates. Safe to log.
    static func sanitise(_ raw: String, limit: Int = 1200) -> String {
        var output = raw
        for key in sensitiveKeys {
            // key":"value"  /  key=value
            output = output.replacingOccurrences(
                of: "(?i)\"?\(key)\"?\\s*[:=]\\s*\"?[^\",&}\\s]+",
                with: "\(key)=<redacted>",
                options: .regularExpression
            )
        }
        output = output.replacingOccurrences(
            of: "(?i)(https?://[^\\s\"]*?)(token|signature|sig|x-amz-[a-z-]+)=[^&\\s\"]+",
            with: "$1$2=<redacted>",
            options: .regularExpression
        )
        if output.count > limit {
            return String(output.prefix(limit)) + "… (truncated)"
        }
        return output
    }

    /// Sanitised body preview — pretty JSON where possible.
    static func responsePreview(_ data: Data?, limit: Int = 1200) -> String {
        guard let data, !data.isEmpty else { return "<empty body>" }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: pretty, encoding: .utf8) {
            return sanitise(text, limit: limit)
        }
        return sanitise(String(data: data.prefix(limit * 2), encoding: .utf8) ?? "<non-utf8 body>", limit: limit)
    }

    // MARK: Classification

    /// Postgres / PostgREST codes that will never succeed on retry.
    private static let permanentCodes: [String: String] = [
        "23502": "A required field was empty.",
        "23503": "A linked record is missing on the server.",
        "23505": "The server already has a conflicting record.",
        "23514": "A value failed a server validation rule.",
        "22p02": "A value had the wrong format.",
        "22007": "A date value had the wrong format.",
        "42703": "The app sent a field the server doesn't have.",
        "42883": "A required server function is missing.",
        "42501": "You don't have permission to change this record.",
        "pgrst204": "The app sent a column the server doesn't have.",
        "pgrst202": "A required server function is missing.",
        "pgrst301": "Your session expired. Sign in again.",
    ]

    private static let retryableMarkers: [String] = [
        "timed out", "timeout", "network connection was lost", "offline",
        "cannot connect", "could not connect", "connection appears to be offline",
        "502", "503", "504", "429", "too many requests", "server error",
        "cancelled", "canceled", "the request timed out",
    ]

    /// Classifies any upload/download error into retryable vs permanent with a
    /// stable reason code and an operator-friendly sentence.
    static func classify(_ error: Error, endpoint: String) -> SyncFailureDetail {
        let raw = String(describing: error)
        let sanitised = sanitise(raw)
        let lowered = raw.lowercased()

        if let decoding = decodingDescription(error, endpoint: endpoint) {
            // The mutation itself very likely succeeded — only the response
            // shape was unexpected. Retrying is safe (upserts are keyed by id)
            // but this always needs a developer fix, so surface it.
            return SyncFailureDetail(
                kind: .permanent,
                reasonCode: "response_decode_failed",
                friendlyMessage: "The server replied in an unexpected format. Support has the details.",
                technicalDetail: decoding
            )
        }

        if let urlError = error as? URLError {
            return SyncFailureDetail(
                kind: .retryable,
                reasonCode: "network_\(urlError.code.rawValue)",
                friendlyMessage: "No usable connection — this will upload automatically when you're back online.",
                technicalDetail: "endpoint: \(endpoint)\nurlerror: \(urlError.code.rawValue) \(urlError.localizedDescription)"
            )
        }

        for (code, message) in permanentCodes where lowered.contains(code) {
            return SyncFailureDetail(
                kind: .permanent,
                reasonCode: code,
                friendlyMessage: message,
                technicalDetail: "endpoint: \(endpoint)\ncode: \(code)\n\(sanitised)"
            )
        }

        for marker in retryableMarkers where lowered.contains(marker) {
            return SyncFailureDetail(
                kind: .retryable,
                reasonCode: "transient",
                friendlyMessage: "Couldn't reach the server — VineTrack will keep trying.",
                technicalDetail: "endpoint: \(endpoint)\n\(sanitised)"
            )
        }

        // Unknown: assume retryable so we never strand a valid record.
        return SyncFailureDetail(
            kind: .retryable,
            reasonCode: "unknown",
            friendlyMessage: "Upload didn't complete — VineTrack will retry.",
            technicalDetail: "endpoint: \(endpoint)\n\(sanitised)"
        )
    }
}

// MARK: - Issue registry

/// App-wide record of *which* queued records are stuck and *why*. Purely
/// diagnostic — it never holds user content, only ids, entity names, payload
/// key names and classified reasons.
@Observable
@MainActor
final class SyncIssueCenter {
    static let shared = SyncIssueCenter()

    nonisolated struct Issue: Identifiable, Sendable, Hashable {
        /// Local queue id == the record's local UUID.
        let id: UUID
        let entity: String
        var operation: String
        var kind: SyncFailureKind
        var reasonCode: String
        var friendlyMessage: String
        var technicalDetail: String
        var queuedAt: Date?
        var lastAttemptAt: Date
        var attemptCount: Int
        var payloadKeys: [String]
        var vineyardId: UUID?
    }

    nonisolated struct CategorySummary: Identifiable, Sendable, Hashable {
        var id: String { entity }
        let entity: String
        let waiting: Int
        let permanent: Int
        let retryable: Int
        let reason: String
    }

    private(set) var issues: [UUID: Issue] = [:]
    /// Pending counts reported by each service on its last push, even when
    /// nothing failed — lets the UI group "Work Tasks 18 waiting".
    private(set) var pendingByEntity: [String: Int] = [:]

    private init() {}

    // MARK: Recording

    func notePending(entity: String, count: Int) {
        if count == 0 {
            pendingByEntity.removeValue(forKey: entity)
        } else {
            pendingByEntity[entity] = count
        }
    }

    func recordFailure(
        id: UUID,
        entity: String,
        operation: String = "upsert",
        detail: SyncFailureDetail,
        queuedAt: Date?,
        payloadKeys: [String],
        vineyardId: UUID?
    ) {
        let previous = issues[id]
        issues[id] = Issue(
            id: id,
            entity: entity,
            operation: operation,
            kind: detail.kind,
            reasonCode: detail.reasonCode,
            friendlyMessage: detail.friendlyMessage,
            technicalDetail: detail.technicalDetail,
            queuedAt: queuedAt ?? previous?.queuedAt,
            lastAttemptAt: Date(),
            attemptCount: (previous?.attemptCount ?? 0) + 1,
            payloadKeys: payloadKeys,
            vineyardId: vineyardId
        )
    }

    /// Clears issues for records that uploaded (or were reclaimed).
    func clearIssues(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { issues.removeValue(forKey: id) }
    }

    func clearAll() {
        issues.removeAll()
        pendingByEntity.removeAll()
    }

    // MARK: Reads

    var permanentCount: Int { issues.values.filter { $0.kind == .permanent }.count }
    var retryableCount: Int { issues.values.filter { $0.kind == .retryable }.count }
    var hasIssues: Bool { !issues.isEmpty }

    /// One row per entity type that still has queued or failed records,
    /// ordered by severity then size — "Work Tasks · 18 waiting".
    var summaries: [CategorySummary] {
        var entities = Set(pendingByEntity.keys)
        entities.formUnion(issues.values.map { $0.entity })
        return entities.map { entity in
            let entityIssues = issues.values.filter { $0.entity == entity }
            let permanent = entityIssues.filter { $0.kind == .permanent }
            let retryable = entityIssues.filter { $0.kind == .retryable }
            let reason = permanent.first?.friendlyMessage
                ?? retryable.first?.friendlyMessage
                ?? "Waiting to upload."
            return CategorySummary(
                entity: entity,
                waiting: pendingByEntity[entity] ?? entityIssues.count,
                permanent: permanent.count,
                retryable: retryable.count,
                reason: reason
            )
        }
        .filter { $0.waiting > 0 || $0.permanent > 0 || $0.retryable > 0 }
        .sorted {
            if $0.permanent != $1.permanent { return $0.permanent > $1.permanent }
            if $0.waiting != $1.waiting { return $0.waiting > $1.waiting }
            return $0.entity < $1.entity
        }
    }

    /// Full sanitised dump for the "Copy diagnostics" action. One block per
    /// queued item: queue id, entity, operation, queued/attempt timestamps,
    /// retry count, reason code, payload KEY NAMES only, vineyard id.
    func diagnosticsText() -> String {
        var lines: [String] = [
            "VineTrack sync diagnostics",
            "generated: \(ISO8601DateFormatter().string(from: Date()))",
            "queued_by_entity: \(pendingByEntity.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))",
            "failed_items: \(issues.count) (permanent \(permanentCount), retryable \(retryableCount))",
            "",
        ]
        for issue in issues.values.sorted(by: { $0.lastAttemptAt > $1.lastAttemptAt }) {
            lines.append("— queue_id: \(issue.id.uuidString)")
            lines.append("  entity: \(issue.entity)")
            lines.append("  operation: \(issue.operation)")
            lines.append("  queued_at: \(issue.queuedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
            lines.append("  last_attempt_at: \(ISO8601DateFormatter().string(from: issue.lastAttemptAt))")
            lines.append("  attempts: \(issue.attemptCount)")
            lines.append("  kind: \(issue.kind.rawValue)")
            lines.append("  reason_code: \(issue.reasonCode)")
            lines.append("  vineyard_id: \(issue.vineyardId?.uuidString ?? "unknown")")
            lines.append("  payload_keys: \(issue.payloadKeys.joined(separator: ","))")
            lines.append("  detail: \(issue.technicalDetail.replacingOccurrences(of: "\n", with: " | "))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Queue push driver

/// Outcome of one entity's upload pass.
nonisolated struct SyncPushResult: Sendable {
    /// Records the server accepted — clear these from the queue immediately.
    var uploaded: [UUID] = []
    /// Records that failed transiently — stay queued, retry next sweep.
    var retryable: [UUID] = []
    /// Records the server rejected outright — stay queued but surfaced.
    var permanent: [UUID] = []
    /// First transient error, so the service can still report "sync failed".
    var firstRetryableError: SyncPushError?

    var failed: [UUID] { retryable + permanent }
    var hasFailures: Bool { !retryable.isEmpty || !permanent.isEmpty }
}

/// Wrapper so a classified failure can be rethrown without losing the reason.
nonisolated struct SyncPushError: Error, LocalizedError, Sendable {
    let entity: String
    let detail: SyncFailureDetail
    var errorDescription: String? { detail.friendlyMessage }
}

/// The shared upload driver used by every per-record sync service.
///
/// Behaviour contract (regression: one malformed record blocked all 22):
///   * Batch first — fast path when everything is valid.
///   * On ANY batch failure, every item is retried **individually**, so a
///     single bad record can never block the rest.
///   * Successful items are returned for immediate queue removal.
///   * Failures are classified and registered with `SyncIssueCenter`.
///   * Upserts are keyed on the record's own UUID, so a retry after an
///     ambiguous failure updates the same row instead of duplicating it.
@MainActor
enum SyncQueuePush {

    static func run<Payload: Encodable & Sendable>(
        entity: String,
        ids: [UUID],
        payloads: [Payload],
        queuedAt: [UUID: Date] = [:],
        vineyardId: UUID? = nil,
        batch: ([Payload]) async throws -> Void
    ) async -> SyncPushResult {
        var result = SyncPushResult()
        guard !ids.isEmpty, ids.count == payloads.count else { return result }

        // Fast path: one round trip for the whole batch.
        do {
            try await batch(payloads)
            result.uploaded = ids
            SyncIssueCenter.shared.clearIssues(ids)
            return result
        } catch {
            #if DEBUG
            print("[\(entity)Sync] batch of \(ids.count) failed — falling back to per-item upload: \(BackendErrorDiagnostics.sanitise(String(describing: error), limit: 300))")
            #endif
        }

        // Isolation path: every item gets its own attempt.
        for (index, id) in ids.enumerated() {
            let payload = payloads[index]
            do {
                try await batch([payload])
                result.uploaded.append(id)
                SyncIssueCenter.shared.clearIssues([id])
            } catch {
                let detail = BackendErrorDiagnostics.classify(error, endpoint: entity)
                SyncIssueCenter.shared.recordFailure(
                    id: id,
                    entity: entity,
                    detail: detail,
                    queuedAt: queuedAt[id],
                    payloadKeys: payloadKeys(payload),
                    vineyardId: vineyardId
                )
                switch detail.kind {
                case .retryable:
                    result.retryable.append(id)
                    if result.firstRetryableError == nil {
                        result.firstRetryableError = SyncPushError(entity: entity, detail: detail)
                    }
                case .permanent:
                    result.permanent.append(id)
                }
            }
        }
        return result
    }

    /// Top-level key names of an encodable payload — never the values.
    static func payloadKeys<Payload: Encodable>(_ payload: Payload) -> [String] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard
            let data = try? encoder.encode(payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object.keys.sorted()
    }
}
