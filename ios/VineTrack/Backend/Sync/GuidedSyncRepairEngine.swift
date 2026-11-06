import Foundation
import CryptoKit
import Observation
import Supabase

/// Approved, human-reviewed corrections only. Unknown or invalid values are
/// never silently normalised to zero, the current time, a new ID or a guess.
nonisolated enum GuidedRepairFieldValidation {
    static func note(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 12 && trimmed.count <= 500 ? trimmed : nil
    }

    static func manualTankTime(_ value: Date, tripStart: Date, tripEnd: Date,
                               originalConfirmedAt: Date, reason: String) -> String? {
        guard note(reason) != nil else { return "Describe where the verified tank-start time came from (12–500 characters)." }
        guard value >= tripStart, value <= tripEnd else { return "The tank start must fall within the original Trip start and end." }
        // Confirmed Actual Use was created at Start Tank. An earlier operator-
        // verified start is permitted; a later timestamp contradicts the
        // original confirmation and must be independently reviewed instead.
        guard value <= originalConfirmedAt else { return "A tank start after the original Actual Use confirmation is contradictory." }
        return nil
    }

    static func nonnegativeNumber(_ value: String, allowMissing: Bool = false) -> Double? {
        let normalised = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        if normalised.isEmpty { return nil } // Blank is not an implicit zero.
        guard let number = Double(normalised), number.isFinite, number >= 0 else { return nil }
        return number
    }

    static func immutableIdentityMatches(_ original: SprayTankActual, _ server: SprayTankActual) -> Bool {
        original.id == server.id && original.vineyardId == server.vineyardId &&
            original.tripId == server.tripId && original.sprayRecordId == server.sprayRecordId &&
            TankDependencyVerification.normalized(original.tankSessionId) ==
                TankDependencyVerification.normalized(server.tankSessionId) &&
            original.tankNumber == server.tankNumber &&
            original.confirmedAt == server.confirmedAt &&
            original.confirmedBy == server.confirmedBy
    }
}

/// Frozen operator inputs survive reopening; only action-relevant fields are included.
nonisolated struct GuidedRepairReviewInput: Codable, Equatable, Sendable {
    let reason: String
    let water: String?
    let chemicals: [UUID: String]?
    let tankTime: Date?
    let sessionId: UUID?
    let applied: Bool?
    let recordedNotApplied: Bool?

    func fingerprint(issueId: String, correction: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // UUID dictionary encodes as an unkeyed sequence; explicitly order it.
        let ordered = chemicals?.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { $0.key.uuidString + "=" + $0.value }.joined(separator: "|") ?? ""
        let stable = GuidedRepairReviewInput(reason: reason, water: water, chemicals: nil,
            tankTime: tankTime, sessionId: sessionId, applied: applied, recordedNotApplied: recordedNotApplied)
        return GuidedRepairAuditLedger.fingerprint(issueId + "|" + correction + "|" +
            String(decoding: try encoder.encode(stable), as: UTF8.self) + "|" + ordered)
    }
}

/// A durable, per-record audit: logs user selection BEFORE any attempted write,
/// retains all subsequent stages and never claims server completion from the
/// mere absence of a local queue entry. Server Actual corrections additionally
/// have their own authoritative amendment rows (SQL correct_*_v1).
@MainActor
final class GuidedRepairAuditLedger {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
    static let shared = GuidedRepairAuditLedger(persistence: .shared)
    static let key = "vinetrack_guided_sync_repair_audit_v1"

    struct Stage: Codable, Sendable {
        let date: Date
        let code: String
        let explanation: String
    }
    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let account: UUID
        let vineyard: UUID
        let record: UUID
        let correction: String
        let inputHash: String
        let reason: String
        let startedAt: Date
        var stages: [Stage]
        var reviewInput: GuidedRepairReviewInput? = nil
    }
    private struct Snapshot: Codable {
        var entries: [Entry] = []
    }
    struct Unreadable: LocalizedError {
        var errorDescription: String? { "The original repair audit is unreadable; no correction was applied." }
    }

    private let persistence: PersistenceStore
    init(persistence: PersistenceStore) { self.persistence = persistence }

    private func load() throws -> Snapshot {
        let outcome: PersistenceStore.LoadOutcome<Snapshot> = persistence.loadOutcome(key: Self.key)
        switch outcome {
        case .missing: return Snapshot()
        case .decoded(let snapshot): return snapshot
        case .failed: throw Unreadable()
        }
    }

    func history(account: UUID, vineyard: UUID, record: UUID) throws -> [Entry] {
        try load().entries.filter {
            $0.account == account && $0.vineyard == vineyard && $0.record == record
        }.sorted { $0.startedAt > $1.startedAt }
    }

    nonisolated static func fingerprint(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    struct LegacyInputsUnavailable: LocalizedError {
        var errorDescription: String? { "This unresolved older operation has no frozen reviewed inputs. Retain its original ID and evidence for assisted reconciliation; no retry or replacement operation is permitted." }
    }

    struct PendingConflict: LocalizedError {
        var errorDescription: String? { "An unresolved correction already exists. Resume its frozen original inputs and operation ID; do not create a competing correction." }
    }

    @discardableResult
    func begin(account: UUID, vineyard: UUID, record: UUID,
               correction: String, inputHash: String, reason: String,
               preferredOperationId: UUID? = nil,
               reviewInput: GuidedRepairReviewInput? = nil) throws -> UUID {
        var snapshot = try load()
        if let existing = snapshot.entries.last(where: {
            $0.account == account && $0.vineyard == vineyard && $0.record == record &&
            $0.correction == correction &&
            !$0.stages.contains(where: { $0.code == "VERIFIED" })
        }) {
            guard existing.reviewInput != nil else { throw LegacyInputsUnavailable() }
            guard existing.inputHash == inputHash,
                  preferredOperationId == nil || existing.id == preferredOperationId else {
                throw PendingConflict()
            }
            return existing.id
        } // Preserve the same server operation after an unknown response.
        if let preferredOperationId,
           snapshot.entries.contains(where: { $0.id == preferredOperationId }) {
            throw Unreadable() // Same server ID must never be reused for a different correction.
        }
        let id = preferredOperationId ?? UUID()
        snapshot.entries.append(Entry(
            id: id, account: account, vineyard: vineyard, record: record,
            correction: correction, inputHash: inputHash, reason: reason,
            startedAt: Date(),
            stages: [Stage(date: Date(), code: "REQUESTED", explanation: "Operator initiated original-record correction.")],
            reviewInput: reviewInput))
        try persistence.saveOrThrow(snapshot, key: Self.key)
        return id
    }

    func stage(id: UUID, account: UUID, vineyard: UUID, code: String, explanation: String) throws {
        var snapshot = try load()
        guard let i = snapshot.entries.lastIndex(where: {
            $0.id == id && $0.account == account && $0.vineyard == vineyard
        }) else { throw Unreadable() }
        snapshot.entries[i].stages.append(
            Stage(date: Date(), code: code, explanation: explanation))
        try persistence.saveOrThrow(snapshot, key: Self.key)
    }
}

/// An existing confirmed Actual Use can be corrected through the server's
/// audited, optimistic-lock RPC. A missing or unacknowledged original Actual
/// must NOT be fabricated by this pathway: first restore its actual Trip tank
/// dependency and let the original upsert obtain a receipt.
@MainActor
enum GuidedActualUseCorrection {
    struct Rejected: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Requested: Codable, Equatable, Sendable {
        let p_operation_id: UUID
        let p_actual_id: UUID
        let p_trip_id: UUID
        let p_spray_record_id: UUID
        let p_tank_session_id: String
        let p_tank_number: Int
        let p_expected_version: Int
        let p_water_volume_l: Double?
        let p_chemicals: [SprayTankActualChemical]

        enum CodingKeys: String, CodingKey {
            case p_operation_id, p_actual_id, p_trip_id, p_spray_record_id,
                 p_tank_session_id, p_tank_number, p_expected_version,
                 p_water_volume_l, p_chemicals
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(p_operation_id, forKey: .p_operation_id)
            try c.encode(p_actual_id, forKey: .p_actual_id)
            try c.encode(p_trip_id, forKey: .p_trip_id)
            try c.encode(p_spray_record_id, forKey: .p_spray_record_id)
            try c.encode(p_tank_session_id, forKey: .p_tank_session_id)
            try c.encode(p_tank_number, forKey: .p_tank_number)
            try c.encode(p_expected_version, forKey: .p_expected_version)
            if let water = p_water_volume_l {
                try c.encode(water, forKey: .p_water_volume_l)
            } else {
                // This RPC has a required nullable argument. Encoding omission
                // is not equivalent to explicit "not recorded" NULL.
                try c.encodeNil(forKey: .p_water_volume_l)
            }
            try c.encode(p_chemicals, forKey: .p_chemicals)
        }
    }

    /// Preserve all immutable chemical IDs, units, additions and substitutions.
    /// Input fields use the units printed beside each chemical (not base units).
    static func reviewedChemicals(original: [SprayTankActualChemical],
                                  amounts: [UUID: String]) throws -> [SprayTankActualChemical] {
        guard Set(original.map(\.id)) == Set(amounts.keys),
              Set(original.map(\.id)).count == original.count else {
            throw Rejected(message: "Every recorded chemical needs one valid actual amount. No chemical may be silently added or removed.")
        }
        return try original.map { item in
            guard let entered = amounts[item.id],
                  let value = GuidedRepairFieldValidation.nonnegativeNumber(entered) else {
                throw Rejected(message: "Enter a valid amount for \(item.name) in \(item.unit.rawValue).")
            }
            return try SprayTankActualChemical(
                id: item.id, plannedChemicalId: item.plannedChemicalId,
                savedChemicalId: item.savedChemicalId,
                replacesPlannedChemicalId: item.replacesPlannedChemicalId,
                usageKind: item.usageKind, name: item.name,
                actualAmountBase: item.unit.toBase(value), unit: item.unit)
        }
    }

    static func amend(
        actualId: UUID, owner: UUID, vineyard: UUID, reason: String,
        waterText: String, chemicalDisplayAmounts: [UUID: String],
        operationId: UUID, store: MigratedDataStore
    ) async throws -> SprayTankActual {
        guard GuidedRepairFieldValidation.note(reason) != nil else {
            throw Rejected(message: "Enter a reason and evidence source (12–500 characters) before correcting a compliance record.")
        }
        let provider = SupabaseClientProvider.shared
        func requireContext() throws {
            try Task.checkCancellation()
            guard provider.isConfigured, provider.client.auth.currentUser?.id == owner,
                  store.currentUserIdProvider?() == owner, store.selectedVineyardId == vineyard else {
                throw Rejected(message: "The original signed-in account/vineyard changed. The frozen amendment is retained.")
            }
            try VineyardWriteAuthority.shared.requireWrite(vineyardId: vineyard.uuidString)
        }
        try requireContext()
        let localStore = SprayTankActualStore.shared
        guard let original = localStore.records.first(where: {
            $0.id == actualId && $0.vineyardId == vineyard
        }), !localStore.pendingIds.contains(actualId) else {
            throw Rejected(message: "This Actual Use has not been independently accepted by the server. Repair its original tank session and sync first.")
        }
        let remoteTrip = try await SupabaseTripSyncRepository()
            .fetchTripForOccurrenceStart(tripId: original.tripId, vineyardId: vineyard)
        guard let remoteTrip, remoteTrip.deletedAt == nil,
              TankDependencyVerification.ids(remoteTrip.tankSessions ?? [])
                .contains(TankDependencyVerification.normalized(original.tankSessionId)) else {
            throw Rejected(message: "The original Trip or its tank session is absent/deleted on the server. No correction was sent.")
        }
        try requireContext()

        let waterValue: Double?
        if waterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            waterValue = nil // Explicitly Not recorded, never implicit zero.
        } else if let parsed = GuidedRepairFieldValidation.nonnegativeNumber(waterText) {
            waterValue = parsed
        } else {
            throw Rejected(message: "Enter a non-negative water volume (litres), or leave blank only when not recorded.")
        }
        let chemicals = try reviewedChemicals(
            original: original.chemicals, amounts: chemicalDisplayAmounts)
        let verified = try await reconcileAmendment(
            original: original, owner: owner, vineyard: vineyard, reason: reason,
            water: waterValue, chemicals: chemicals, operationId: operationId,
            persistence: .shared, requireContext: requireContext,
            readActual: { try await localStore.actualReader(original) },
            readAmendments: {
                // Read the entire original operation, not just the first row.
                try await provider.client.from("spray_tank_actual_amendments")
                    .select("*").eq("operation_id", value: operationId.uuidString)
                    .execute().value
            }, send: { request in
                try await provider.client.rpc("correct_spray_tank_actual_v1", params: request).execute()
            })
        try requireContext()
        await localStore.pull(vineyardId: vineyard)
        try requireContext()
        return verified
    }

    struct AmendmentAttempt: Codable, Equatable {
        let owner: UUID
        let vineyard: UUID
        let reason: String
        let original: SprayTankActual
        let request: Requested
    }

    struct AmendmentRow: Codable {
        let operation_id: UUID
        let vineyard_id: UUID
        let trip_id: UUID
        let spray_record_id: UUID
        let spray_tank_actual_id: UUID
        let tank_number: Int
        let chemical_actual_id: UUID?
        let field_name: String
        let previous_value: TripActivityCancellation.JSON?
        let new_value: TripActivityCancellation.JSON?
        let revision: Int
        let edited_by: UUID
    }

    static func amendmentKey(_ operation: UUID) -> String {
        "vinetrack_guided_accepted_actual_request_v1_" + operation.uuidString.lowercased()
    }

    /// A Data envelope preserves exact Date/Double values rather than allowing
    /// the shared ISO-8601 cache encoder to truncate original confirmation times.
    static func savedAmendment(_ operation: UUID, persistence: PersistenceStore) throws -> AmendmentAttempt? {
        let outcome: PersistenceStore.LoadOutcome<Data> = persistence.loadOutcome(key: amendmentKey(operation))
        switch outcome {
        case .missing: return nil
        case .decoded(let bytes): return try JSONDecoder().decode(AmendmentAttempt.self, from: bytes)
        case .failed: throw Rejected(message: "The original amendment request is unreadable. No replacement or replay is permitted.")
        }
    }

    // MainActor reentrancy across transport awaits must not allow two callers
    // to freeze/overwrite the same operation or amend the same Actual at once.
    private static var inFlightOperations: Set<UUID> = []
    private static var inFlightActuals: Set<UUID> = []

    /// Shared by the real authenticated transport and bounded transport-failure
    /// tests. No local Actual/queue is edited here. An accepted-but-lost response
    /// is reconciled by its original receipt BEFORE comparing old quantities.
    static func reconcileAmendment(
        original: SprayTankActual, owner: UUID, vineyard: UUID, reason: String,
        water: Double?, chemicals: [SprayTankActualChemical], operationId: UUID,
        persistence: PersistenceStore, requireContext: () throws -> Void,
        readActual: () async throws -> SprayTankActual?,
        readAmendments: () async throws -> [AmendmentRow],
        send: (Requested) async throws -> Void
    ) async throws -> SprayTankActual {
        try requireContext()
        guard !inFlightOperations.contains(operationId), !inFlightActuals.contains(original.id) else {
            throw Rejected(message: "The original amendment is already being checked or sent. Wait for it; no competing request was saved.")
        }
        inFlightOperations.insert(operationId)
        inFlightActuals.insert(original.id)
        defer {
            inFlightOperations.remove(operationId)
            inFlightActuals.remove(original.id)
        }
        guard original.vineyardId == vineyard, GuidedRepairFieldValidation.note(reason) != nil else {
            throw Rejected(message: "The original vineyard and reviewed evidence note are required.")
        }
        var attempt = try savedAmendment(operationId, persistence: persistence)
        if let saved = attempt {
            guard saved.owner == owner, saved.vineyard == vineyard,
                  saved.reason == reason, saved.request.p_operation_id == operationId,
                  GuidedRepairFieldValidation.immutableIdentityMatches(saved.original, original),
                  saved.request.p_water_volume_l == water, saved.request.p_chemicals == chemicals else {
                throw Rejected(message: "This operation's frozen original inputs or scope differ. Its request cannot be replaced.")
            }
        }
        let rows = try await readAmendments()
        try requireContext()
        guard let remote = try await readActual() else {
            throw Rejected(message: "The original server Actual Use is absent. No amendment was sent.")
        }
        try requireContext()
        if let saved = attempt, !rows.isEmpty {
            try verifyAmendment(saved, remote: remote, rows: rows)
            return remote // Do not resend an already accepted original operation.
        }
        guard rows.isEmpty,
              GuidedRepairFieldValidation.immutableIdentityMatches(attempt?.original ?? original, remote),
              remote.waterVolumeL == (attempt?.original ?? original).waterVolumeL,
              remote.chemicals == (attempt?.original ?? original).chemicals else {
            throw Rejected(message: "The server differs from the frozen original without a matching amendment receipt. Retain it for reconciliation.")
        }
        if let saved = attempt {
            guard remote.correctionVersion ?? 0 == saved.request.p_expected_version else {
                throw Rejected(message: "The original expected version changed. Do not substitute a new version or operation.")
            }
        } else {
            guard water != original.waterVolumeL || chemicals != original.chemicals else {
                throw Rejected(message: "Quantities are unchanged; no amendment is required.")
            }
            let request = Requested(p_operation_id: operationId, p_actual_id: original.id,
                p_trip_id: original.tripId, p_spray_record_id: original.sprayRecordId,
                p_tank_session_id: original.tankSessionId, p_tank_number: original.tankNumber,
                p_expected_version: remote.correctionVersion ?? 0,
                p_water_volume_l: water, p_chemicals: chemicals)
            let saved = AmendmentAttempt(owner: owner, vineyard: vineyard, reason: reason,
                original: remote, request: request)
            try persistence.saveOrThrow(try JSONEncoder().encode(saved), key: amendmentKey(operationId))
            guard try savedAmendment(operationId, persistence: persistence) == saved else {
                throw Rejected(message: "The exact original request did not survive durable readback. No correction was sent.")
            }
            attempt = saved
        }
        guard let saved = attempt else { throw Rejected(message: "Original amendment request unavailable.") }
        try requireContext()
        // If dispatch throws (including a lost response), the immutable request
        // remains on disk. Explicit retry reads receipt first; never mint an ID.
        try await send(saved.request)
        try requireContext()
        let acceptedRows = try await readAmendments()
        try requireContext()
        guard let accepted = try await readActual() else {
            throw Rejected(message: "Amendment readback is absent; retain the original request.")
        }
        try requireContext()
        try verifyAmendment(saved, remote: accepted, rows: acceptedRows)
        return accepted
    }

    static func verifyAmendment(_ saved: AmendmentAttempt, remote: SprayTankActual,
                                rows: [AmendmentRow]) throws {
        let request = saved.request, before = saved.original
        let version = request.p_expected_version + 1
        guard GuidedRepairFieldValidation.immutableIdentityMatches(before, remote),
              remote.correctionVersion == version,
              remote.waterVolumeL == request.p_water_volume_l,
              remote.chemicals == request.p_chemicals,
              rows.allSatisfy({ $0.operation_id == request.p_operation_id &&
                  $0.vineyard_id == saved.vineyard && $0.trip_id == before.tripId &&
                  $0.spray_record_id == before.sprayRecordId && $0.spray_tank_actual_id == before.id &&
                  $0.tank_number == before.tankNumber && $0.edited_by == saved.owner && $0.revision == version }) else {
            throw Rejected(message: "Independent amendment identity, actor, version or reviewed amounts do not match. Nothing was acknowledged.")
        }
        let waterRows = rows.filter { $0.field_name == "actualWaterLitres" }
        let changedWater = before.waterVolumeL != request.p_water_volume_l
        func number(_ value: Double?) -> TripActivityCancellation.JSON { value.map { .number($0) } ?? .null }
        guard waterRows.count == (changedWater ? 1 : 0), waterRows.allSatisfy({
            $0.chemical_actual_id == nil && ($0.previous_value ?? .null) == number(before.waterVolumeL) &&
                ($0.new_value ?? .null) == number(request.p_water_volume_l)
        }) else { throw Rejected(message: "The original water amendment receipt is incomplete or different.") }
        let changed = request.p_chemicals.filter { item in before.chemicals.first(where: { $0.id == item.id }) != item }
        let chemicalRows = rows.filter { $0.field_name == "actualChemical" }
        guard rows.count == waterRows.count + chemicalRows.count,
              !rows.isEmpty, chemicalRows.count == changed.count else {
            throw Rejected(message: "The original chemical amendment receipt is incomplete or ambiguous.")
        }
        for chemical in changed {
            let matches = chemicalRows.filter { $0.chemical_actual_id == chemical.id }
            guard matches.count == 1, let row = matches.first,
                  let previous = row.previous_value, let next = row.new_value,
                  try JSONDecoder().decode(SprayTankActualChemical.self, from: JSONEncoder().encode(previous)) ==
                    before.chemicals.first(where: { $0.id == chemical.id }),
                  try JSONDecoder().decode(SprayTankActualChemical.self, from: JSONEncoder().encode(next)) == chemical else {
                throw Rejected(message: "Exact original chemical identities and before/after amounts were not independently receipted.")
            }
        }
    }

    private struct LocalOriginalCorrectionArchive: Codable {
        let operationId: UUID
        let owner: UUID
        let vineyard: UUID
        let original: SprayTankActual
        let reviewed: SprayTankActual
        let evidenceNote: String
        let savedAt: Date
    }

    /// Correct a never-uploaded Actual Use through its SAME original record
    /// ID and session. An independent server read must prove that it has NOT
    /// already been accepted; accepted records use the audited RPC instead.
    /// The frozen original and operator note are durably archived BEFORE
    /// updating the queued local record.
    static func correctPendingOriginal(
        actualId: UUID, owner: UUID, vineyard: UUID, reason: String,
        waterText: String, chemicalDisplayAmounts: [UUID: String],
        operationId: UUID, store: MigratedDataStore
    ) async throws -> SprayTankActual {
        guard GuidedRepairFieldValidation.note(reason) != nil,
              store.currentUserIdProvider?() == owner,
              store.selectedVineyardId == vineyard,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner
        else {
            throw Rejected(message: "Original account/vineyard and an evidence note are required.")
        }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: vineyard.uuidString)
        let actualStore = SprayTankActualStore.shared
        guard let original = actualStore.records.first(where: {
            $0.id == actualId && $0.vineyardId == vineyard
        }), actualStore.pendingIds.contains(actualId),
              let localTrip = store.trips.first(where: {
                  $0.id == original.tripId && $0.vineyardId == vineyard
              }),
              TankDependencyVerification.ids(localTrip.tankSessions)
                  .contains(TankDependencyVerification.normalized(original.tankSessionId)),
              (try? store.tripDeletionJournal.isCancelled(original.tripId)) == false,
              !TripCancellationIntentStore.shared.blocksReplay(tripId: original.tripId),
              store.sprayRecords.contains(where: {
                  $0.id == original.sprayRecordId && $0.vineyardId == vineyard &&
                  $0.canonicalTripId == original.tripId
              })
        else {
            throw Rejected(message: "The pending original Actual Use lacks a verified local tank session, Spray Record or writable parent. Repair the original dependency first.")
        }
        // Unlike amend(), a newly saved original does not need an already
        // present server tank session. It must, however, belong to an existing
        // non-deleted original Trip; the normal dependency sweep stages the
        // original session before this Actual is uploaded.
        let remoteTrip = try await SupabaseTripSyncRepository()
            .fetchTripForOccurrenceStart(tripId: original.tripId, vineyardId: vineyard)
        guard let remoteTrip, remoteTrip.id == original.tripId,
              remoteTrip.vineyardId == vineyard, remoteTrip.deletedAt == nil else {
            throw Rejected(message: "The original server Trip is deleted, absent or not in this vineyard. Nothing was edited.")
        }
        // A lost ACK can leave a locally pending record even when the server
        // already accepted it. Never overwrite that compliance row through
        // this local-only recovery path.
        guard try await actualStore.actualReader(original) == nil else {
            throw Rejected(message: "The original Actual Use is already present on the server. Verify its receipt, then use the audited server amendment option.")
        }
        let water: Double?
        if waterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            water = nil
        } else if let parsed = GuidedRepairFieldValidation.nonnegativeNumber(waterText) {
            water = parsed
        } else {
            throw Rejected(message: "Enter non-negative tank water in litres, or leave blank for Not recorded.")
        }
        let chemicalRows = try reviewedChemicals(
            original: original.chemicals, amounts: chemicalDisplayAmounts)
        guard water != original.waterVolumeL ||
              chemicalRows != original.chemicals else {
            throw Rejected(message: "The original pending quantities are unchanged; no correction is required.")
        }
        let revisionAt = max(Date(), original.clientUpdatedAt.addingTimeInterval(0.001))
        let corrected = try SprayTankActual(
            id: original.id, vineyardId: original.vineyardId,
            sprayRecordId: original.sprayRecordId, tripId: original.tripId,
            tankSessionId: original.tankSessionId, tankNumber: original.tankNumber,
            waterVolumeL: water, chemicals: chemicalRows,
            confirmedAt: original.confirmedAt, confirmedBy: original.confirmedBy,
            clientUpdatedAt: revisionAt, correctionVersion: original.correctionVersion,
            lastCorrectedAt: original.lastCorrectedAt)
        let key = "vinetrack_guided_original_actual_archive_v1_" +
            operationId.uuidString.lowercased()
        let archive = LocalOriginalCorrectionArchive(
            operationId: operationId, owner: owner, vineyard: vineyard,
            original: original, reviewed: corrected,
            evidenceNote: reason.trimmingCharacters(in: .whitespacesAndNewlines),
            savedAt: Date())
        let existing: PersistenceStore.LoadOutcome<LocalOriginalCorrectionArchive> =
            PersistenceStore.shared.loadOutcome(key: key)
        switch existing {
        case .failed:
            throw Rejected(message: "The original Actual Use evidence archive is unreadable. No correction was applied.")
        case .decoded(let previous):
            guard previous.owner == owner, previous.vineyard == vineyard,
                  previous.original.id == original.id,
                  previous.operationId == operationId else {
                throw Rejected(message: "The original correction operation conflicts with retained evidence.")
            }
        case .missing:
            try PersistenceStore.shared.saveOrThrow(archive, key: key)
        }
        guard store.currentUserIdProvider?() == owner,
              store.selectedVineyardId == vineyard,
              actualStore.pendingIds.contains(original.id),
              (try? store.tripDeletionJournal.isCancelled(original.tripId)) == false
        else {
            throw Rejected(message: "The original scope or deletion state changed. The archive is retained; no queued amount was changed.")
        }
        try actualStore.saveLocally(corrected)
        return corrected
    }
}
