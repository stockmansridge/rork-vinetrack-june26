import Foundation

/// P0 3.1.9 Phase C (Issue #40): derives whether a Trip may be reported as CLOSED_SYNCED.
/// Mirrors Android `TripClosureStatus` exactly (same states, evidence and reason codes).
/// CLOSED_SYNCED requires the terminal server state plus every required dependent acknowledged.
/// Display and diagnostics only: never acknowledges, clears or replays anything.
nonisolated enum TripClosureStatus {
    enum State: String, Sendable {
        case active = "ACTIVE"
        case localEndPending = "LOCAL_END_PENDING"
        case serverStateUnconfirmed = "SERVER_STATE_UNCONFIRMED"
        case dependentsPending = "ENDED_DEPENDENTS_PENDING"
        case dependentsHeld = "ENDED_DEPENDENTS_HELD"
        case closedSynced = "CLOSED_SYNCED"
    }

    enum ServerEvidence: String, Sendable {
        case freshRead = "fresh_server_read"
        case ackedLocalRow = "acknowledged_local_row"
        case readFailed = "server_read_failed"
        case absent = "server_row_absent"
    }

    struct Marker: Sendable, Equatable {
        let entityType: String
        let status: String
    }

    struct Input: Sendable, Equatable {
        var tripId: String
        var evidence: ServerEvidence
        var serverIsActive: Bool
        var serverEndTime: Date?
        /// Session ids on the evidence row; nil when unreadable.
        var serverSessionIds: Set<String>?
        var locallyEnded: Bool
        var unresolvedMarkers: [Marker]
        /// Pending occurrence operations; nil when the journal is unreadable.
        var occurrencePending: Int?
        var occurrenceHeldReason: String?
        var actualSessionIds: Set<String>
        var pendingActualIds: [String]
        var holdCodes: [String]
        var linkedSprayIssue: String? = nil
        var completionIntentPending: Bool = false
        var ownerScope: String = ""
        var selectedVineyardScope: String = ""
    }

    struct Result: Sendable, Equatable {
        let state: State
        let reasons: [String]
        var isClosedSynced: Bool { state == .closedSynced }
    }

    static let requiredSessionsUnreadable = "TRIP_TANK_REQUIRED_SESSIONS_UNREADABLE"
    private static let blockingStatuses: Set<String> = ["failed", "blocked"]

    static func normalized(_ id: String) -> String { id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    static func evaluate(_ input: Input) -> Result {
        var reasons: [String] = []
        let required = Set(input.actualSessionIds.map(normalized))
        let serverSessions = input.serverSessionIds.map { Set($0.map(normalized)) }
        if input.locallyEnded { reasons.append("END_NOT_ACKNOWLEDGED") }
        for m in input.unresolvedMarkers { reasons.append("MARKER_\(m.entityType.uppercased())_\(m.status.uppercased())") }
        if let pending = input.occurrencePending {
            if pending > 0 { reasons.append("OCCURRENCE_OPERATIONS_PENDING_\(pending)") }
        } else {
            reasons.append("OCCURRENCE_JOURNAL_UNREADABLE")
        }
        if input.occurrenceHeldReason != nil { reasons.append("OCCURRENCE_HELD") }
        if !input.pendingActualIds.isEmpty { reasons.append("TANK_ACTUALS_PENDING_\(input.pendingActualIds.count)") }
        reasons.append(contentsOf: input.holdCodes)
        if let issue = input.linkedSprayIssue { reasons.append(issue) }
        if input.completionIntentPending { reasons.append("TRACKED_SPRAY_COMPLETION_INTENT_PENDING") }
        let sessionProblem: Bool
        if required.isEmpty {
            sessionProblem = false
        } else if let serverSessions {
            sessionProblem = !required.isSubset(of: serverSessions)
            if sessionProblem { reasons.append(TankDependencyVerification.requiredSessionMissing) }
        } else {
            sessionProblem = true
            reasons.append(requiredSessionsUnreadable)
        }

        if input.locallyEnded { return Result(state: .localEndPending, reasons: reasons) }
        switch input.evidence {
        case .readFailed: return Result(state: .serverStateUnconfirmed, reasons: reasons + ["SERVER_READ_FAILED"])
        case .absent: return Result(state: .serverStateUnconfirmed, reasons: reasons + ["SERVER_ROW_ABSENT"])
        default: break
        }
        if input.serverIsActive || input.serverEndTime == nil { return Result(state: .active, reasons: reasons) }
        let held = input.unresolvedMarkers.contains { blockingStatuses.contains($0.status.lowercased()) } ||
            input.occurrencePending == nil || input.occurrenceHeldReason != nil || !input.holdCodes.isEmpty || sessionProblem
        if held { return Result(state: .dependentsHeld, reasons: reasons) }
        if !reasons.isEmpty { return Result(state: .dependentsPending, reasons: reasons) }
        return Result(state: .closedSynced, reasons: [])
    }

    /// The terminal-state line of the copied status. Only a fresh server read may
    /// be labelled as the server's state: for every other kind of evidence the
    /// active/end values come from this device's own row, and printing them as
    /// `server_terminal` made a locally ended Trip look server-confirmed while
    /// the server still had it active.
    static func terminalLine(_ input: Input) -> String {
        if input.evidence == .freshRead {
            return "  server_terminal: active=\(input.serverIsActive); end_time_set=\(input.serverEndTime != nil)"
        }
        return "  server_terminal: not_read (evidence=\(input.evidence.rawValue)); local_row_active=\(input.serverIsActive); local_row_end_time_set=\(input.serverEndTime != nil)"
    }

    static func diagnosticLines(_ input: Input, _ result: Result) -> [String] {
        [
            "trip_closure: trip=\(input.tripId) state=\(result.state.rawValue) evidence=\(input.evidence.rawValue)",
            terminalLine(input),
            "  locally_ended: \(input.locallyEnded)",
            "  unresolved_markers: \(input.unresolvedMarkers.count)",
            "  occurrence_pending: \(input.occurrencePending.map(String.init) ?? "unreadable"); held=\(input.occurrenceHeldReason != nil)",
            "  tank_actuals: total_sessions=\(input.actualSessionIds.count); pending=\(input.pendingActualIds.count)",
            "  server_sessions: \(input.serverSessionIds.map { String($0.count) } ?? "unreadable")",
            "  linked_spray: \(input.linkedSprayIssue ?? "matching_completion"); completion_intent_pending=\(input.completionIntentPending)",
            "  reasons: \((result.reasons.isEmpty ? ["none"] : result.reasons).joined(separator: ","))",
        ]
    }
}
