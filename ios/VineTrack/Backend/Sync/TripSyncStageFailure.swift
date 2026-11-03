//
//  TripSyncStageFailure.swift
//  VineTrack
//
//  An original occurrence Trip uploads through a chain of independently
//  verified stages: parent create, parent activate, tank-session staging and
//  read-back, non-authority fields, occurrence actions (including the tank
//  links) and finalise. Before this file, every HTTP failure on that chain was
//  flattened into `TripOccurrenceCoverage.Failure.reconciliation` or a
//  synthetic `OCCURRENCE_SYNC_UNAVAILABLE`. The status, the PostgREST code and
//  the server's own message were discarded, the error was classified
//  "unknown, retry forever", and the Sync screen could only say "Upload didn't
//  complete".
//
//  This file adds three pure, testable pieces and changes no data:
//
//    * `TripSyncStageFailure` names the stage that stopped, the Trip and
//      operation, the request, and exactly what the server answered. It also
//      decides whether retrying can possibly help.
//    * `OccurrenceHoldPolicy` decides, separately, whether the immutable
//      occurrence journal may be HELD. A hold has no general release path, so
//      it is reserved for genuine conflicts.
//    * `TripSyncRetryThrottle` stops a deterministic server answer from being
//      re-sent on every sweep.
//
//  Nothing here fabricates, rewrites or discards a Trip, tank session, actual,
//  journal operation or timestamp.
//

import Foundation

// MARK: - Stage failure

nonisolated struct TripSyncStageFailure: Error, LocalizedError, Sendable, Equatable {

    /// The step of the original Trip upload that stopped.
    enum Stage: String, Sendable, Equatable, CaseIterable {
        case admission = "ADMISSION"
        case occurrenceRecovery = "OCCURRENCE_RECOVERY"
        case parentCreate = "PARENT_CREATE"
        case parentActivate = "PARENT_ACTIVATE"
        case tankStagingRead = "TANK_STAGING_READ"
        case tankStagingPatch = "TANK_STAGING_PATCH"
        case tankStagingReadback = "TANK_STAGING_READBACK"
        case nonAuthorityPatch = "NON_AUTHORITY_PATCH"
        case occurrenceAction = "OCCURRENCE_ACTION"
        case finalize = "FINALIZE"
        case tripUpsert = "TRIP_UPSERT"

        /// Plain-language name used inside the on-screen sentence ("at ...").
        var label: String {
            switch self {
            case .admission: return "the upload check"
            case .occurrenceRecovery: return "saved-action recovery"
            case .parentCreate: return "Trip creation"
            case .parentActivate: return "Trip activation"
            case .tankStagingRead: return "the tank-session read"
            case .tankStagingPatch: return "the tank-session upload"
            case .tankStagingReadback: return "tank-session verification"
            case .nonAuthorityPatch: return "the Trip details update"
            case .occurrenceAction: return "a saved-action upload"
            case .finalize: return "Trip finish"
            case .tripUpsert: return "the Trip upload"
            }
        }

        /// The stage that an occurrence RPC belongs to.
        static func forRPC(_ rpc: String) -> Stage {
            switch rpc {
            case "create_trip_with_occurrences_v1": return .parentCreate
            case "activate_trip_occurrences_v1": return .parentActivate
            case "finalize_trip_occurrences_v1": return .finalize
            case "get_trip_occurrence_recovery_v1": return .occurrenceRecovery
            default: return .occurrenceAction
            }
        }
    }

    enum Disposition: String, Sendable, Equatable {
        /// Transient: network, timeout, rate limit, 5xx without a rejection token.
        case retryable
        /// The server will answer the same until its data or schema changes.
        /// Not re-sent on the normal sweep cadence; checked again on a long cooldown.
        case nonRetryable = "non_retryable"
        /// The immutable occurrence journal itself is held.
        case held
    }

    let stage: Stage
    let tripId: UUID
    /// Journal operation id (lower-case UUID) when a specific operation was in flight.
    let operationId: String?
    /// Human-readable request, for example `rpc/apply_trip_occurrence_action_v1`.
    let endpoint: String
    let httpStatus: Int?
    let postgrestCode: String?
    /// The server's own message, sanitised and truncated.
    let serverMessage: String?
    /// `OCCURRENCE_*` token found in the server answer, if any.
    let occurrenceCode: String?
    /// `URLError` raw code when the request never produced an HTTP answer.
    let transportCode: Int?
    /// Fixed code for a local verification step that failed without an HTTP error.
    let verificationCode: String?
    let journalHeld: Bool
    let disposition: Disposition

    init(stage: Stage, tripId: UUID, operationId: String? = nil, endpoint: String,
         httpStatus: Int? = nil, postgrestCode: String? = nil, serverMessage: String? = nil,
         occurrenceCode: String? = nil, transportCode: Int? = nil, verificationCode: String? = nil,
         journalHeld: Bool = false, disposition: Disposition? = nil) {
        self.stage = stage
        self.tripId = tripId
        self.operationId = operationId
        self.endpoint = endpoint
        self.httpStatus = httpStatus
        self.postgrestCode = postgrestCode
        self.serverMessage = serverMessage.map { BackendErrorDiagnostics.sanitise($0, limit: 300) }
        self.occurrenceCode = occurrenceCode
        self.transportCode = transportCode
        self.verificationCode = verificationCode
        self.journalHeld = journalHeld
        self.disposition = journalHeld ? .held : (disposition ?? Self.classify(
            httpStatus: httpStatus, postgrestCode: postgrestCode,
            occurrenceCode: occurrenceCode, urlErrorCode: transportCode))
    }

    // MARK: Classification

    /// Legacy synthetic code that earlier builds invented for any non-2xx
    /// answer without a rejection token. Kept only so an old value is still
    /// treated as transient.
    static let legacySyntheticCode = "OCCURRENCE_SYNC_UNAVAILABLE"

    /// Whether retrying can possibly help. Pure and exhaustive over its inputs.
    ///
    /// Order matters: a transport error is always transient; a server
    /// rejection token is a deterministic answer; PostgREST/Postgres codes are
    /// read before the bare HTTP status, because PostgREST maps SQLSTATE class
    /// 40/55/57 to HTTP 500.
    static func classify(httpStatus: Int?, postgrestCode: String?,
                         occurrenceCode: String?, urlErrorCode: Int?) -> Disposition {
        if urlErrorCode != nil { return .retryable }
        if let occurrenceCode {
            return occurrenceCode == legacySyntheticCode ? .retryable : .nonRetryable
        }
        // 401 is an authentication problem (missing or expired token) that signing in again cures.
        // PostgREST labels an anonymous call 42501 ("permission denied"), which on a 403 is a
        // deterministic access rule, so the status must win over the code here.
        if httpStatus == 401 { return .retryable }
        let code = (postgrestCode ?? "").uppercased()
        if !code.isEmpty {
            // Transient server conditions first.
            if code.hasPrefix("08") || code.hasPrefix("53") || code.hasPrefix("57") { return .retryable }
            if code == "40001" || code == "40P01" { return .retryable }
            if code.hasPrefix("PGRST0") || code.hasPrefix("PGRST3") { return .retryable }
            // Deterministic: data exception, integrity violation, syntax or
            // access rule, undefined function/column, or an unparseable request.
            if code.hasPrefix("22") || code.hasPrefix("23") || code.hasPrefix("42") { return .nonRetryable }
            if code.hasPrefix("PGRST1") || code == "PGRST202" || code == "PGRST204" { return .nonRetryable }
        }
        guard let httpStatus else { return .retryable }
        switch httpStatus {
        case 401, 408, 425, 429: return .retryable
        case 500...599: return .retryable
        case 400...499: return .nonRetryable
        default: return .retryable
        }
    }

    // MARK: Presentation

    var kind: SyncFailureKind { disposition == .retryable ? .retryable : .permanent }

    /// Stable machine code for the Sync screen and exported diagnostics.
    var reasonCode: String {
        if let occurrenceCode { return occurrenceCode }
        if let verificationCode { return verificationCode }
        if let postgrestCode, !postgrestCode.isEmpty { return postgrestCode.uppercased() }
        if let httpStatus { return "HTTP_\(httpStatus)" }
        if let transportCode { return "NETWORK_\(transportCode)" }
        return "TRIP_SYNC_\(stage.rawValue)"
    }

    var friendlyMessage: String {
        switch occurrenceCode {
        case "OCCURRENCE_TANK_LINK_CONFLICT":
            return "The server did not accept the tank records for this Trip (OCCURRENCE_TANK_LINK_CONFLICT). Your Trip, tank sessions and saved actions are kept unchanged on this device and nothing was discarded. A server update is required; VineTrack will check again automatically."
        case "OCCURRENCE_TANK_REVIEW_REQUIRED":
            return "The server reports this Trip still has an unfinished or unreviewed tank (OCCURRENCE_TANK_REVIEW_REQUIRED). Your saved tank records are unchanged. Review the Trip's tanks, then sync again."
        case .some(let code) where code != Self.legacySyntheticCode:
            return journalHeld
                ? "The server rejected a saved action for this Trip (\(code)) and it is held for review. Nothing was discarded."
                : "The server rejected a saved action for this Trip (\(code)). Nothing was discarded."
        default:
            break
        }
        if transportCode != nil {
            return "No usable connection at \(stage.label); your Trip is kept safely and VineTrack will try again."
        }
        switch disposition {
        case .retryable:
            return "Not finished yet at \(stage.label) (\(reasonCode)); your Trip is kept safely and VineTrack will try again."
        case .nonRetryable:
            return "The server did not accept this Trip at \(stage.label) (\(reasonCode)). Your Trip and its records are kept unchanged; automatic retries are paused for now."
        case .held:
            return "This Trip's saved actions are on hold at \(stage.label) (\(reasonCode)). Nothing was discarded."
        }
    }

    var errorDescription: String? { friendlyMessage }

    /// Full sanitised technical block for "Copy diagnostics". No tokens, no
    /// payload values, no quantities.
    var technicalDetail: String {
        [
            "stage: \(stage.rawValue)",
            "trip_id: \(tripId.uuidString.lowercased())",
            "operation_id: \(operationId ?? "none")",
            "endpoint: \(endpoint)",
            "http_status: \(httpStatus.map(String.init) ?? "none")",
            "postgrest_code: \(postgrestCode ?? "none")",
            "occurrence_code: \(occurrenceCode ?? "none")",
            "transport_code: \(transportCode.map(String.init) ?? "none")",
            "verification_code: \(verificationCode ?? "none")",
            "server_message: \(serverMessage ?? "none")",
            "disposition: \(disposition.rawValue)",
            "journal_held: \(journalHeld ? "yes" : "no")",
            "evidence: preserved (no Trip, tank session, actual or journal operation was removed or rewritten by this failure)",
        ].joined(separator: "\n")
    }

    var syncFailureDetail: SyncFailureDetail {
        SyncFailureDetail(kind: kind, reasonCode: reasonCode,
                          friendlyMessage: friendlyMessage, technicalDetail: technicalDetail)
    }

    // MARK: Export allow-list

    /// True for a code from a closed vocabulary that cannot carry user
    /// content: a server `OCCURRENCE_*` token (regex-extracted, upper-case
    /// letters and underscores only), one of this file's fixed verification
    /// codes, `HTTP_nnn`, `NETWORK_nnn`, a 5-character SQLSTATE or `PGRSTnnn`.
    /// Never true for free text, so the scoped support export can include it.
    static func isExportSafe(_ reasonCode: String) -> Bool {
        reasonCode.range(
            of: "^(OCCURRENCE_[A-Z_]{1,60}|TANK_STAGING_[A-Z_]{1,60}|NON_AUTHORITY_PATCH_[A-Z_]{1,60}|TRIP_SYNC_[A-Z_]{1,40}|HTTP_[1-5][0-9]{2}|NETWORK_-?[0-9]{1,5}|[0-9A-Z]{5}|PGRST[0-9]{3})$",
            options: .regularExpression) != nil
    }
}

// MARK: - Fixed verification codes

/// Fixed codes for local verification steps that stop without an HTTP error.
/// Each replaces an earlier, indistinguishable `reconciliation` throw.
nonisolated enum TripSyncVerificationCode {
    // Local admission to the tank-staging stage.
    static let tripNotEnded = "TANK_STAGING_TRIP_NOT_ENDED"
    static let noRequiredSessions = "TANK_STAGING_NO_REQUIRED_SESSIONS"
    static let coverageUnreadable = "TANK_STAGING_COVERAGE_UNREADABLE"
    static let duplicateSession = "TANK_STAGING_DUPLICATE_SESSION"
    static let duplicateTankNumber = "TANK_STAGING_DUPLICATE_TANK_NUMBER"
    static let requiredNotLocal = "TANK_STAGING_REQUIRED_NOT_LOCAL"
    static let noAccount = "TANK_STAGING_NO_ACCOUNT"
    // Server read of the Trip before staging.
    static let serverRowMismatch = "TANK_STAGING_SERVER_ROW_MISMATCH"
    static let serverSessionConflict = "TANK_STAGING_SERVER_SESSION_CONFLICT"
    static let revisionMissing = "TANK_STAGING_REVISION_MISSING"
    static let requestInvalid = "TANK_STAGING_REQUEST_INVALID"
    // The compare-and-swap PATCH.
    static let casNoMatch = "TANK_STAGING_CAS_NO_MATCH"
    // Independent read-back after the PATCH.
    static let readbackMismatch = "TANK_STAGING_READBACK_MISMATCH"
    // Occurrence journal and parent checks.
    static let journalHeld = "OCCURRENCE_JOURNAL_HELD"
    static let parentOperationsPending = "OCCURRENCE_PARENT_OPERATIONS_PENDING"
    static let parentReadbackMismatch = "OCCURRENCE_PARENT_READBACK_MISMATCH"
    static let operationsPending = "OCCURRENCE_OPERATIONS_PENDING"
    // Non-authority PATCH answered 200 without exactly the Trip's row.
    static let nonAuthorityNoRow = "NON_AUTHORITY_PATCH_NO_ROW"
}

// MARK: - Server answer parsing

/// Reads what PostgREST actually said. Raw `URLSession` calls bypass the SDK
/// and therefore its `PostgrestError`; the body is the only evidence.
nonisolated struct PostgrestAnswer: Sendable, Equatable {
    let code: String?
    let message: String?

    static func parse(_ data: Data) -> PostgrestAnswer {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PostgrestAnswer(code: nil, message: nil)
        }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return PostgrestAnswer(code: string("code"), message: string("message"))
    }

    /// First `OCCURRENCE_*` rejection token in any text, or nil.
    static func occurrenceToken(in text: String) -> String? {
        text.range(of: "OCCURRENCE_[A-Z_]+", options: .regularExpression).map { String(text[$0]) }
    }
}

// MARK: - Occurrence RPC rejection

/// An occurrence RPC answered with a non-2xx status. Carries everything the
/// server said so the failure is never reduced to a synthetic placeholder.
nonisolated struct OccurrenceRPCFailure: Error, LocalizedError, Sendable, Equatable {
    /// `OCCURRENCE_*` token from the body, or nil when the server gave none.
    let code: String?
    let httpStatus: Int
    let postgrestCode: String?
    let message: String?

    var errorDescription: String? {
        "Occurrence sync needs review (\(code ?? postgrestCode ?? "HTTP_\(httpStatus)")). Saved work was retained."
    }
}

// MARK: - Typed construction from raw server answers

/// Pure constructors for the three places a raw `URLSession` answer becomes a
/// typed failure. They read only the HTTP status and the response body, so the
/// exact shapes the live server produces (for example HTTP 500 with SQLSTATE
/// 40001 and an `OCCURRENCE_TANK_LINK_CONFLICT` message) are unit-testable
/// without a network.
nonisolated extension OccurrenceRPCFailure {
    /// A non-2xx occurrence RPC answer. The `OCCURRENCE_*` token is read from the
    /// raw body; a body without one is never relabelled as a synthetic code.
    static func from(httpStatus: Int, body: Data) -> OccurrenceRPCFailure {
        let answer = PostgrestAnswer.parse(body)
        let text = String(data: body, encoding: .utf8) ?? ""
        return OccurrenceRPCFailure(
            code: PostgrestAnswer.occurrenceToken(in: text),
            httpStatus: httpStatus,
            postgrestCode: answer.code,
            message: answer.message ?? BackendErrorDiagnostics.responsePreview(body, limit: 300))
    }
}

nonisolated extension TripSyncStageFailure {
    /// An occurrence RPC rejection, with everything the server said.
    init(rejection: OccurrenceRPCFailure, rpc: String, tripId: UUID,
         operationId: String?, journalHeld: Bool) {
        self.init(stage: .forRPC(rpc), tripId: tripId, operationId: operationId,
                  endpoint: "rpc/\(rpc)", httpStatus: rejection.httpStatus,
                  postgrestCode: rejection.postgrestCode, serverMessage: rejection.message,
                  occurrenceCode: rejection.code, journalHeld: journalHeld)
    }

    /// A raw REST request answered non-2xx. The server's own code and message
    /// are read from the body; nothing is guessed.
    init(stage: Stage, tripId: UUID, endpoint: String, httpStatus: Int?, body: Data,
         operationId: String? = nil) {
        let answer = PostgrestAnswer.parse(body)
        let message = answer.message ?? BackendErrorDiagnostics.responsePreview(body, limit: 300)
        self.init(stage: stage, tripId: tripId, operationId: operationId, endpoint: endpoint,
                  httpStatus: httpStatus, postgrestCode: answer.code, serverMessage: message,
                  occurrenceCode: PostgrestAnswer.occurrenceToken(in: message))
    }
}

// MARK: - Hold policy

/// Whether a server rejection may HOLD the immutable occurrence journal.
///
/// A held journal has no general release path (only an original, never-accepted
/// create+activate pair can be released), and the hold records only a generic
/// sentence, not the server's code. So a hold is reserved for genuine
/// conflicts. These two answers depend on server data state that can change by
/// itself (a server repair, a later finalisation) and are idempotent on retry,
/// so holding would turn a repairable server-side state into a permanent
/// local lock:
///
///   * `OCCURRENCE_TANK_LINK_CONFLICT`: a tank link was not recognised by the
///     server's comparison of tank-session identity.
///   * `OCCURRENCE_TANK_REVIEW_REQUIRED`: the server's tank state is not yet
///     clean enough to finalise.
nonisolated enum OccurrenceHoldPolicy {
    static let nonHoldingCodes: Set<String> = [
        "OCCURRENCE_TANK_LINK_CONFLICT",
        "OCCURRENCE_TANK_REVIEW_REQUIRED",
    ]

    /// The reason to pass to the journal's hold, or nil to leave it unheld.
    static func holdReason(code: String?) -> String? {
        guard let code,
              code != TripSyncStageFailure.legacySyntheticCode,
              !nonHoldingCodes.contains(code) else { return nil }
        return code.contains("UPDATE_REQUIRED") || code.contains("UNSUPPORTED")
            ? "OCCURRENCE_UPDATE_REQUIRED" : "OCCURRENCE_CONFLICT"
    }

    static func holdReason(for failure: OccurrenceRPCFailure) -> String? {
        holdReason(code: failure.code)
    }
}

// MARK: - Retry throttle

/// In-memory cooldown for Trips whose last answer was deterministic.
///
/// Only `nonRetryable` and `held` failures are throttled: re-sending the same
/// request cannot succeed until server data changes, and doing so every sweep
/// spends the user's battery and hides the real reason behind a spinner.
/// Transient failures are never throttled here, so ordinary connectivity
/// recovery is unchanged.
///
/// In-memory on purpose: a relaunch is always one fresh attempt, which is how a
/// Trip heals after a server repair without any local state being edited.
nonisolated struct TripSyncRetryThrottle: Sendable, Equatable {
    static let cooldown: TimeInterval = 30 * 60

    struct Entry: Sendable, Equatable {
        let until: Date
        let reasonCode: String
        let disposition: TripSyncStageFailure.Disposition
        let attempts: Int
    }

    private(set) var entries: [UUID: Entry] = [:]

    init() {}

    mutating func record(tripId: UUID, disposition: TripSyncStageFailure.Disposition,
                         reasonCode: String, now: Date) {
        guard disposition != .retryable else {
            entries.removeValue(forKey: tripId)
            return
        }
        entries[tripId] = Entry(until: now.addingTimeInterval(Self.cooldown), reasonCode: reasonCode,
                                disposition: disposition, attempts: (entries[tripId]?.attempts ?? 0) + 1)
    }

    mutating func record(_ failure: TripSyncStageFailure, now: Date) {
        record(tripId: failure.tripId, disposition: failure.disposition,
               reasonCode: failure.reasonCode, now: now)
    }

    func isCoolingDown(_ tripId: UUID, now: Date) -> Bool {
        guard let entry = entries[tripId] else { return false }
        return now < entry.until
    }

    func nextAttempt(_ tripId: UUID, now: Date) -> Date? {
        guard let entry = entries[tripId], now < entry.until else { return nil }
        return entry.until
    }

    mutating func clear(_ tripId: UUID) { entries.removeValue(forKey: tripId) }
    mutating func clearAll() { entries.removeAll() }
}
