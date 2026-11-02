import Foundation

/// P0 Phase A (iOS parity with Android `TripActivityCancellation.kt`): Cancel Trip recovery for a
/// Trip this installation ended locally but could not finalise. Server contract:
/// sql/281 `cancel_trip_activity_v1` — identical RPC, receipt fields and error codes on both platforms.
///
/// Fixed, fail-closed order:
///  1. eligibility + explicit application classification (Not sure is held, never guessed);
///  2. original evidence written and fsynced BEFORE any request;
///  3. durable intent committed with a stable operation id (a lost response replays the same id);
///  4. server receipt verified against operation/Trip/vineyard/classification;
///  5. ACKED committed BEFORE local cleanup; cleanup removes only this Trip's exact queue entries,
///     tank actuals, occurrence journal and local-end claim — never by count, never mid-sync.
/// No Tank session is fabricated and no recorded quantity is changed or substituted.
nonisolated enum TripActivityCancellation {
    typealias JSON = SprayReportPayloadV1.JSONValue

    enum Classification: String, Codable, Sendable, CaseIterable {
        case notApplied = "not_applied"
        case applied
        case unknown
        var wire: String? { self == .unknown ? nil : rawValue }
    }

    enum State: String, Codable, Sendable { case REQUESTED, REFUSED, RECEIPT_MISMATCH, ACKED, CLEANED }

    static let contract = "vinetrack.trip-activity-cancellation"

    /// Definitive server refusals: nothing changed server-side; local evidence and queues stay.
    static let definitiveRefusals: Set<String> = [
        "TRIP_CANCEL_FORBIDDEN", "TRIP_CANCEL_TRIP_NOT_FOUND", "TRIP_CANCEL_TRIP_ALREADY_DELETED",
        "TRIP_CANCEL_TRIP_COMPLETED", "TRIP_CANCEL_MANUAL_ENTRY_UNSUPPORTED",
        "TRIP_CANCEL_SERVER_ACTUALS_REQUIRE_APPLIED_REVIEW", "TRIP_CANCEL_COMPLIANCE_FACTS_REQUIRED",
        "TRIP_CANCEL_CLASSIFICATION_REQUIRED", "TRIP_CANCEL_INVALID_IDENTITY", "TRIP_CANCEL_INVALID_BASELINE",
        "TRIP_CANCEL_OPERATION_CONFLICT",
    ]

    struct Intent: Codable, Sendable, Equatable {
        let operationId: String
        let ownerId: String
        let vineyardId: String
        let tripId: String
        let classification: String
        let sprayRecordIds: [String]
        let localActualIds: [String]
        let baseline: JSON
        let complianceFacts: JSON?
        let evidencePath: String
        var state: State
        let requestedAt: Date
        var receipt: JSON?
        var lastCode: String?

        /// REQUESTED / ACKED / RECEIPT_MISMATCH hold replay of this Trip's queues.
        var isOpen: Bool { state == .REQUESTED || state == .ACKED || state == .RECEIPT_MISMATCH }
        /// Any non-refused intent blocks re-upload; a cleaned Trip is tombstoned server-side.
        var blocksReplay: Bool { state != .REFUSED }
    }

    struct Request: Sendable, Equatable {
        let ownerId: String
        let vineyardId: String
        let tripId: String
        let classification: Classification
        /// Required when Not applied but this device holds recorded tank actuals.
        var confirmedRecordedActualsWereNotApplied: Bool = false
    }

    /// The iOS original-device proof. iOS releases the tracking claim at End, so the claim is captured
    /// at that moment (or derived from this install's account/vineyard-scoped occurrence journal).
    struct LocalEndClaim: Codable, Sendable, Equatable {
        let tripId: String
        let ownerId: String?
        let vineyardId: String
        let endedAt: Date
        let source: String
    }

    struct Eligibility: Equatable, Sendable { let allowed: Bool; let code: String? }

    static func eligibility(role: String?, signedInUserId: String?, claim: LocalEndClaim?,
                            tripId: String, vineyardId: String, localEndPending: Bool) -> Eligibility {
        func no(_ code: String) -> Eligibility { Eligibility(allowed: false, code: code) }
        guard let user = signedInUserId?.lowercased(), !user.isEmpty else { return no("TRIP_CANCEL_AUTH_REQUIRED") }
        guard let role = role?.lowercased(), ["owner", "manager", "supervisor"].contains(role) else { return no("TRIP_CANCEL_FORBIDDEN") }
        guard localEndPending else { return no("TRIP_CANCEL_NOT_LOCAL_END_PENDING") }
        guard let claim, claim.tripId.lowercased() == tripId.lowercased() else { return no("TRIP_CANCEL_NOT_DEVICE_CLAIM") }
        guard claim.ownerId?.lowercased() == user else { return no("TRIP_CANCEL_CLAIM_OWNER_MISMATCH") }
        guard claim.vineyardId.lowercased() == vineyardId.lowercased() else { return no("TRIP_CANCEL_CLAIM_VINEYARD_MISMATCH") }
        return Eligibility(allowed: true, code: nil)
    }

    /// One durable local queue entry whose identity is this Trip (or its linked spray record).
    struct QueueEntry: Codable, Sendable, Hashable {
        let kind: String
        let id: String
        static let tripUpsert = "trip_upsert"
        static let tripWorkTaskClear = "trip_work_task_clear"
        static let sprayRecordUpsert = "spray_record_upsert"
        static let sprayRecordDelete = "spray_record_delete"
        static let tankActualPending = "tank_actual_pending"
        static let initialMixDraft = "initial_mix_draft"
        static let occurrencePending = "occurrence_pending_operation"
    }

    enum Plan: Equatable, Sendable {
        case ready([QueueEntry])
        case refused(String)
    }

    static func plan(_ entries: [QueueEntry], writeInFlight: Bool) -> Plan {
        if writeInFlight && !entries.isEmpty { return .refused("TRIP_CANCEL_WRITE_IN_FLIGHT") }
        return .ready(entries)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Facts copied verbatim from recorded actuals; planned values are never substituted.
    static func complianceFacts(tripId: String, vineyardId: String, actuals: [SprayTankActual]) -> JSON {
        let tanks: [JSON] = actuals.sorted { $0.tankNumber < $1.tankNumber }.map { a in
            var chemicals: [JSON] = []
            for c in a.chemicals {
                var line: [String: JSON] = [
                    "id": .string(c.id.uuidString.lowercased()),
                    "name": .string(c.name),
                    "actual_amount_base": .number(c.actualAmountBase),
                    "unit": .string(c.unit.rawValue),
                ]
                if let saved = c.savedChemicalId { line["saved_chemical_id"] = .string(saved.uuidString.lowercased()) }
                if let planned = c.plannedChemicalId { line["planned_chemical_id"] = .string(planned.uuidString.lowercased()) }
                chemicals.append(.object(line))
            }
            return .object([
                "actual_id": .string(a.id.uuidString.lowercased()),
                "spray_record_id": .string(a.sprayRecordId.uuidString.lowercased()),
                "tank_session_id": .string(a.tankSessionId),
                "tank_number": .number(Double(a.tankNumber)),
                "water_volume_l": a.waterVolumeL.map { JSON.number($0) } ?? .null,
                "confirmed_at": .string(iso(a.confirmedAt)),
                "confirmed_by": .string(a.confirmedBy.uuidString.lowercased()),
                "chemicals": .array(chemicals),
            ])
        }
        return .object([
            "contract": .string(contract),
            "trip_id": .string(tripId),
            "vineyard_id": .string(vineyardId),
            "source": .string("device_recorded_tank_actuals"),
            "tanks": .array(tanks),
        ])
    }

    static func string(_ json: JSON?, _ key: String) -> String? {
        guard case .object(let object)? = json, case .string(let value)? = object[key] else { return nil }
        return value
    }

    static func revision(_ json: JSON?) -> Int64? {
        guard case .object(let object)? = json else { return nil }
        switch object["server_revision"] {
        case .number(let value)? where value.isFinite && value == value.rounded(): return Int64(value)
        case .string(let value)?: return Int64(value)
        default: return nil
        }
    }

    /// Nil when valid, otherwise the mismatch reason. `acceptOtherOperation` is true only for a readback
    /// after ALREADY_CANCELLED_OTHER_OPERATION (or a readback carrying another operation id): the durable
    /// server tombstone for this exact Trip/vineyard is authoritative.
    static func verifyReceipt(_ receipt: JSON, intent: Intent, acceptOtherOperation: Bool = false) -> String? {
        if string(receipt, "status") != "CANCELLED_ACKED" { return "status" }
        if string(receipt, "trip_id")?.lowercased() != intent.tripId.lowercased() { return "trip_id" }
        if string(receipt, "vineyard_id")?.lowercased() != intent.vineyardId.lowercased() { return "vineyard_id" }
        if !acceptOtherOperation {
            if string(receipt, "operation_id")?.lowercased() != intent.operationId.lowercased() { return "operation_id" }
            if string(receipt, "application_classification") != intent.classification { return "classification" }
        } else if (string(receipt, "operation_id") ?? "").isEmpty { return "operation_id" }
        guard let revision = revision(receipt), revision > 0 else { return "server_revision" }
        if intent.classification == "applied", !acceptOtherOperation, (string(receipt, "compliance_archive_id") ?? "").isEmpty {
            return "compliance_archive_id"
        }
        return nil
    }

    /// Fixed server code from a PostgREST error body; never echoes free text.
    static func serverCode(_ body: String?) -> String? {
        guard let body, let range = body.range(of: "TRIP_CANCEL[A-Z_]*|TRIP_CANCELLED_TOMBSTONE", options: .regularExpression) else { return nil }
        return String(body[range])
    }
}

// MARK: - Durable files

/// Atomic, fsynced file writes. Used for intents, evidence and local-end claims.
nonisolated enum TripCancellationFiles {
    static func root() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TripActivityCancellation", isDirectory: true)
    }

    static func writeDurably(_ data: Data, to target: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".tmp")
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temp)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
            return (try? Data(contentsOf: target)) == data
        } catch { return false }
    }
}

/// Durable, synchronous intent store. One record per (owner, vineyard, trip).
nonisolated final class TripCancellationIntentStore: @unchecked Sendable {
    static let shared = TripCancellationIntentStore(directory: nil)
    private let explicitDirectory: URL?
    private let lock = NSLock()

    init(directory: URL?) { self.explicitDirectory = directory }

    private func directory() throws -> URL {
        try explicitDirectory ?? TripCancellationFiles.root().appendingPathComponent("intents", isDirectory: true)
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// Throws when a stored intent is unreadable: an unknown intent must hold, not look absent.
    func all() throws -> [TripActivityCancellation.Intent] {
        lock.lock(); defer { lock.unlock() }
        let dir = try directory()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try files.map { try decoder().decode(TripActivityCancellation.Intent.self, from: Data(contentsOf: $0)) }
    }

    func find(tripId: String) throws -> TripActivityCancellation.Intent? {
        try all().first { $0.tripId.lowercased() == tripId.lowercased() }
    }

    /// True while a cancellation for this Trip is open or acknowledged; unreadable state also holds.
    func blocksReplay(tripId: UUID) -> Bool {
        do { return try find(tripId: tripId.uuidString)?.blocksReplay == true } catch { return true }
    }

    @discardableResult
    func commit(_ intent: TripActivityCancellation.Intent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let dir = try? directory(), let data = try? encoder().encode(intent) else { return false }
        let name = "\(intent.ownerId.lowercased())_\(intent.vineyardId.lowercased())_\(intent.tripId.lowercased()).json"
        return TripCancellationFiles.writeDurably(data, to: dir.appendingPathComponent(name))
    }
}

/// Original evidence, written atomically and fsynced before any server request. Never deleted by this flow.
nonisolated struct TripCancellationEvidenceWriter: Sendable {
    let directory: URL?

    func write(operationId: String, evidence: TripActivityCancellation.JSON) -> URL? {
        guard UUID(uuidString: operationId) != nil,
              let dir = try? directory ?? TripCancellationFiles.root().appendingPathComponent("evidence", isDirectory: true) else { return nil }
        let target = dir.appendingPathComponent(operationId.lowercased() + ".json")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(evidence), TripCancellationFiles.writeDurably(data, to: target) else { return nil }
        return target
    }
}

/// The local-end claim captured when this installation ends a Trip (iOS releases its tracking claim at End).
nonisolated final class TripLocalEndClaimStore: @unchecked Sendable {
    static let shared = TripLocalEndClaimStore(directory: nil)
    private let explicitDirectory: URL?
    init(directory: URL?) { self.explicitDirectory = directory }

    private func url(_ tripId: String) throws -> URL {
        try (explicitDirectory ?? TripCancellationFiles.root().appendingPathComponent("local-end-claims", isDirectory: true))
            .appendingPathComponent(tripId.lowercased() + ".json")
    }

    @discardableResult
    func record(_ claim: TripActivityCancellation.LocalEndClaim) -> Bool {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let target = try? url(claim.tripId), let data = try? encoder.encode(claim) else { return false }
        if FileManager.default.fileExists(atPath: target.path) { return true }
        return TripCancellationFiles.writeDurably(data, to: target)
    }

    func raw(tripId: String) throws -> Data? {
        let target = try url(tripId)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try Data(contentsOf: target)
    }

    func find(tripId: String) throws -> TripActivityCancellation.LocalEndClaim? {
        guard let data = try raw(tripId: tripId) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TripActivityCancellation.LocalEndClaim.self, from: data)
    }

    /// True when no claim for this Trip remains afterwards.
    func remove(tripId: String) -> Bool {
        guard let target = try? url(tripId) else { return false }
        guard FileManager.default.fileExists(atPath: target.path) else { return true }
        return (try? FileManager.default.removeItem(at: target)) != nil
    }
}

// MARK: - Coordinator

protocol TripCancellationRemote: AnyObject {
    func cancel(_ intent: TripActivityCancellation.Intent) async throws -> TripActivityCancellation.JSON
    /// Nil when the server has no receipt for this Trip (RLS-scoped readback).
    func readReceipt(tripId: String, vineyardId: String) async throws -> TripActivityCancellation.JSON?
}

protocol TripCancellationLocal: AnyObject {
    var writeInFlight: Bool { get }
    func queueEntries(tripId: String, sprayRecordIds: [String]) throws -> [TripActivityCancellation.QueueEntry]
    func removeQueueEntry(_ entry: TripActivityCancellation.QueueEntry, tripId: String) -> Bool
    func localActuals(tripId: String) throws -> [SprayTankActual]
    func removeActual(id: String) -> Bool
    func rawJournal(ownerId: String, vineyardId: String, tripId: String) throws -> Data?
    func removeJournal(ownerId: String, vineyardId: String, tripId: String) -> Bool
    func rawClaim(tripId: String) throws -> Data?
    /// True when no local-end claim for this exact Trip remains afterwards.
    func clearClaim(tripId: String) -> Bool
}

struct TripCancellationServerRefusal: Error, Sendable {
    let status: Int
    let code: String?
}

@MainActor
final class TripActivityCancellationCoordinator {
    typealias C = TripActivityCancellation
    enum Outcome: Equatable, Sendable {
        case refused(String)
        /// Request sent or to be retried; outcome unknown; evidence retained.
        case pending(String?)
        case acked(cleaned: Bool)
    }

    private let intents: TripCancellationIntentStore
    private let evidence: TripCancellationEvidenceWriter
    private let remote: TripCancellationRemote
    private let local: TripCancellationLocal
    private let now: () -> Date
    private let newOperationId: () -> String

    init(intents: TripCancellationIntentStore, evidence: TripCancellationEvidenceWriter,
         remote: TripCancellationRemote, local: TripCancellationLocal,
         now: @escaping () -> Date = Date.init,
         newOperationId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.intents = intents; self.evidence = evidence; self.remote = remote; self.local = local
        self.now = now; self.newOperationId = newOperationId
    }

    func cancel(_ request: C.Request, sprayRecordIds: [String]) async -> Outcome {
        let existing: C.Intent?
        do { existing = try intents.find(tripId: request.tripId) } catch { return .refused("TRIP_CANCEL_EVIDENCE_UNREADABLE") }
        if let existing, existing.isOpen { return await reconcile(existing) }
        guard let wire = request.classification.wire else { return .refused("TRIP_CANCEL_CLASSIFICATION_UNKNOWN_HELD") }
        let actuals: [SprayTankActual]
        do { actuals = try local.localActuals(tripId: request.tripId) } catch { return .refused("TRIP_CANCEL_EVIDENCE_UNREADABLE") }
        if request.classification == .notApplied, !actuals.isEmpty, !request.confirmedRecordedActualsWereNotApplied {
            return .refused("TRIP_CANCEL_LOCAL_ACTUALS_REQUIRE_CONFIRMATION")
        }
        let entries: [C.QueueEntry]
        do { entries = try local.queueEntries(tripId: request.tripId, sprayRecordIds: sprayRecordIds) }
        catch { return .refused("TRIP_CANCEL_EVIDENCE_UNREADABLE") }
        guard case .ready(let writes) = C.plan(entries, writeInFlight: local.writeInFlight) else {
            return .refused("TRIP_CANCEL_WRITE_IN_FLIGHT")
        }
        if request.classification == .applied, actuals.isEmpty { return .refused("TRIP_CANCEL_COMPLIANCE_FACTS_REQUIRED") }
        // Evidence must be complete: an unreadable journal or claim holds instead of being recorded as absent.
        let journal: Data?, claim: Data?
        do {
            journal = try local.rawJournal(ownerId: request.ownerId, vineyardId: request.vineyardId, tripId: request.tripId)
            claim = try local.rawClaim(tripId: request.tripId)
        } catch { return .refused("TRIP_CANCEL_EVIDENCE_UNREADABLE") }
        let operationId = newOperationId()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        func raw(_ data: Data?) -> C.JSON { data.flatMap { String(data: $0, encoding: .utf8) }.map(C.JSON.string) ?? .null }
        let actualsJSON: C.JSON = (try? encoder.encode(actuals)).flatMap { try? JSONDecoder().decode(C.JSON.self, from: $0) } ?? .null
        guard actualsJSON != .null || actuals.isEmpty else { return .refused("TRIP_CANCEL_EVIDENCE_UNREADABLE") }
        let evidenceDoc: C.JSON = .object([
            "contract": .string(C.contract),
            "operation_id": .string(operationId),
            "owner_id": .string(request.ownerId), "vineyard_id": .string(request.vineyardId), "trip_id": .string(request.tripId),
            "classification": .string(wire),
            "captured_at": .string(C.iso(now())),
            "app_platform": .string("ios"),
            "local_end_claim_raw": raw(claim),
            "occurrence_journal_raw": raw(journal),
            "matching_queue_entries": .array(writes.map { .object(["kind": .string($0.kind), "id": .string($0.id)]) }),
            "local_tank_actuals": actuals.isEmpty ? .array([]) : actualsJSON,
            "spray_record_ids": .array(sprayRecordIds.map(C.JSON.string)),
        ])
        guard let file = evidence.write(operationId: operationId, evidence: evidenceDoc) else {
            return .refused("TRIP_CANCEL_EVIDENCE_NOT_SAVED")
        }
        let types = Array(Set(writes.map(\.kind))).sorted()
        let baseline: C.JSON = .object([
            "app_platform": .string("ios"),
            "local_pending_write_count": .number(Double(writes.count)),
            "local_pending_write_types": .array(types.map(C.JSON.string)),
            "local_tank_actual_count": .number(Double(actuals.count)),
            "evidence_file": .string(file.lastPathComponent),
        ])
        let intent = C.Intent(
            operationId: operationId, ownerId: request.ownerId, vineyardId: request.vineyardId, tripId: request.tripId,
            classification: wire, sprayRecordIds: sprayRecordIds, localActualIds: actuals.map { $0.id.uuidString.lowercased() },
            baseline: baseline,
            complianceFacts: request.classification == .applied ? C.complianceFacts(tripId: request.tripId, vineyardId: request.vineyardId, actuals: actuals) : nil,
            evidencePath: file.path, state: .REQUESTED, requestedAt: now(), receipt: nil, lastCode: nil)
        guard intents.commit(intent) else { return .refused("TRIP_CANCEL_INTENT_NOT_SAVED") }
        return await send(intent)
    }

    private func send(_ intent: C.Intent) async -> Outcome {
        let receipt: C.JSON
        do {
            receipt = try await remote.cancel(intent)
        } catch let refusal as TripCancellationServerRefusal {
            let code = refusal.code
            if code == "TRIP_CANCEL_ALREADY_CANCELLED_OTHER_OPERATION" { return await readback(intent, acceptOtherOperation: true) }
            if let code, C.definitiveRefusals.contains(code) {
                var refused = intent; refused.state = .REFUSED; refused.lastCode = code
                intents.commit(refused)
                return .refused(code)
            }
            var pending = intent; pending.lastCode = code ?? "HTTP_\(refusal.status)"
            intents.commit(pending)
            return .pending(code)
        } catch {
            var pending = intent; pending.lastCode = "TRIP_CANCEL_RESPONSE_UNKNOWN"
            intents.commit(pending)
            return .pending("TRIP_CANCEL_RESPONSE_UNKNOWN")
        }
        return accept(intent, receipt: receipt, acceptOtherOperation: false)
    }

    private func readback(_ intent: C.Intent, acceptOtherOperation: Bool) async -> Outcome {
        let receipt: C.JSON?
        do { receipt = try await remote.readReceipt(tripId: intent.tripId, vineyardId: intent.vineyardId) }
        catch { return .pending("TRIP_CANCEL_READBACK_UNAVAILABLE") }
        guard let receipt else { return .pending("TRIP_CANCEL_READBACK_ABSENT") }
        let other = acceptOtherOperation || C.string(receipt, "operation_id")?.lowercased() != intent.operationId.lowercased()
        return accept(intent, receipt: receipt, acceptOtherOperation: other)
    }

    private func accept(_ intent: C.Intent, receipt: C.JSON, acceptOtherOperation: Bool) -> Outcome {
        if let reason = C.verifyReceipt(receipt, intent: intent, acceptOtherOperation: acceptOtherOperation) {
            var mismatch = intent
            mismatch.state = .RECEIPT_MISMATCH; mismatch.receipt = receipt
            mismatch.lastCode = "TRIP_CANCEL_RECEIPT_MISMATCH_\(reason.uppercased())"
            intents.commit(mismatch)
            return .refused("TRIP_CANCEL_RECEIPT_MISMATCH")
        }
        var acked = intent
        acked.state = .ACKED; acked.receipt = receipt; acked.lastCode = nil
        // The ack must be durable before anything local is removed.
        guard intents.commit(acked) else { return .pending("TRIP_CANCEL_ACK_NOT_SAVED") }
        return .acked(cleaned: cleanup(acked))
    }

    /// Removes only this Trip's exact local dependents after a verified, durable ack. Idempotent.
    private func cleanup(_ intent: C.Intent) -> Bool {
        guard intent.state == .ACKED, intent.receipt != nil else { return false }
        guard let entries = try? local.queueEntries(tripId: intent.tripId, sprayRecordIds: intent.sprayRecordIds),
              case .ready(let writes) = C.plan(entries, writeInFlight: local.writeInFlight) else { return false }
        var complete = true
        for entry in writes where !local.removeQueueEntry(entry, tripId: intent.tripId) { complete = false }
        if let actuals = try? local.localActuals(tripId: intent.tripId) {
            for actual in actuals where !local.removeActual(id: actual.id.uuidString) { complete = false }
        } else { complete = false }
        if !local.removeJournal(ownerId: intent.ownerId, vineyardId: intent.vineyardId, tripId: intent.tripId) { complete = false }
        if !local.clearClaim(tripId: intent.tripId) { complete = false }
        if complete {
            let remaining = try? local.queueEntries(tripId: intent.tripId, sprayRecordIds: intent.sprayRecordIds)
            if remaining == nil || remaining?.isEmpty == false { complete = false }
        }
        if complete {
            var cleaned = intent; cleaned.state = .CLEANED
            complete = intents.commit(cleaned)
        }
        return complete
    }

    /// Startup/refresh: resolve lost responses by readback, then idempotent replay; finish cleanup.
    func reconcile(_ intent: C.Intent) async -> Outcome {
        switch intent.state {
        case .ACKED: return .acked(cleaned: cleanup(intent))
        case .REQUESTED:
            let read = await readback(intent, acceptOtherOperation: false)
            if case .pending(let code) = read, code == "TRIP_CANCEL_READBACK_ABSENT" { return await send(intent) }
            return read
        case .RECEIPT_MISMATCH: return .refused(intent.lastCode ?? "TRIP_CANCEL_RECEIPT_MISMATCH")
        case .REFUSED: return .refused(intent.lastCode ?? "TRIP_CANCEL_REFUSED")
        case .CLEANED: return .acked(cleaned: true)
        }
    }

    func reconcileAll() async -> [(String, Outcome)] {
        guard let all = try? intents.all() else { return [] }
        var results: [(String, Outcome)] = []
        for intent in all where intent.isOpen { results.append((intent.tripId, await reconcile(intent))) }
        return results
    }
}
