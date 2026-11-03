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

/// A durable, per-record audit: logs user selection BEFORE any attempted write,
/// retains all subsequent stages and never claims server completion from the
/// mere absence of a local queue entry. Server Actual corrections additionally
/// have their own authoritative amendment rows (SQL correct_*_v1).
@MainActor
final class GuidedRepairAuditLedger {
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

    static func fingerprint(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func begin(account: UUID, vineyard: UUID, record: UUID,
               correction: String, inputHash: String, reason: String) throws -> UUID {
        var snapshot = try load()
        if let existing = snapshot.entries.last(where: {
            $0.account == account && $0.vineyard == vineyard && $0.record == record &&
            $0.correction == correction && $0.inputHash == inputHash &&
            !$0.stages.contains(where: { $0.code == "VERIFIED" })
        }) { return existing.id } // Preserve the same server operation after an unknown response.
        let id = UUID()
        snapshot.entries.append(Entry(
            id: id, account: account, vineyard: vineyard, record: record,
            correction: correction, inputHash: inputHash, reason: reason,
            startedAt: Date(),
            stages: [Stage(date: Date(), code: "REQUESTED", explanation: "Operator initiated original-record correction.")]))
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

    struct Requested: Encodable {
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
        operationId: UUID
    ) async throws -> SprayTankActual {
        guard GuidedRepairFieldValidation.note(reason) != nil else {
            throw Rejected(message: "Enter a reason and evidence source (12–500 characters) before correcting a compliance record.")
        }
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured, provider.client.auth.currentUser?.id == owner else {
            throw Rejected(message: "The original signed-in account is not verified.")
        }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: vineyard.uuidString)
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
        guard let onServer = try await localStore.actualReader(original),
              GuidedRepairFieldValidation.immutableIdentityMatches(original, onServer),
              TankDependencyVerification.actualMatches(local: original, server: onServer) else {
            throw Rejected(message: "The server Actual Use is missing or conflicts with the saved original. Refresh and inspect before editing.")
        }

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
        guard waterValue != original.waterVolumeL || chemicals != original.chemicals else {
            throw Rejected(message: "The entered water and chemical amounts already match the original confirmed record. No amendment is needed.")
        }
        guard provider.client.auth.currentUser?.id == owner else {
            throw Rejected(message: "The signed-in account changed; no correction was sent.")
        }

        let request = Requested(
            p_operation_id: operationId,
            p_actual_id: original.id,
            p_trip_id: original.tripId,
            p_spray_record_id: original.sprayRecordId,
            p_tank_session_id: original.tankSessionId,
            p_tank_number: original.tankNumber,
            p_expected_version: onServer.correctionVersion ?? 0,
            p_water_volume_l: waterValue,
            p_chemicals: chemicals)
        try await provider.client.rpc("correct_spray_tank_actual_v1", params: request).execute()
        // Do NOT accept HTTP 200 as a correction receipt; exact independent
        // authenticated readback (including identity and actual amounts) is
        // required before showing success.
        guard provider.client.auth.currentUser?.id == owner,
              let verified = try await localStore.actualReader(original),
              GuidedRepairFieldValidation.immutableIdentityMatches(original, verified),
              verified.waterVolumeL == waterValue,
              verified.chemicals == chemicals,
              (verified.correctionVersion ?? 0) >= (onServer.correctionVersion ?? 0)
        else {
            throw Rejected(message: "The correction response was not independently verified. Retain the same operation ID for reconciliation.")
        }
        // An amount readback is necessary but not sufficient to prove who
        // amended a compliance record. Confirm the exact operation UUID in
        // the immutable server amendment ledger before reporting success.
        struct AmendmentRow: Decodable {
            let operationId: UUID
            enum CodingKeys: String, CodingKey { case operationId = "operation_id" }
        }
        let amendmentRows: [AmendmentRow] = try await provider.client
            .from("spray_tank_actual_amendments")
            .select("operation_id")
            .eq("operation_id", value: operationId.uuidString)
            .eq("spray_tank_actual_id", value: original.id.uuidString)
            .eq("vineyard_id", value: vineyard.uuidString)
            .limit(1).execute().value
        guard amendmentRows.count == 1,
              amendmentRows[0].operationId == operationId,
              provider.client.auth.currentUser?.id == owner else {
            throw Rejected(message: "Exact original Actual Use amounts were read back, but the audited amendment operation receipt is not visible. It remains unverified.")
        }
        await localStore.pull(vineyardId: vineyard)
        return verified
    }
}
