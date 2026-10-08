import Foundation

/// Exact server comparison values. Keep the timestamp string at PostgreSQL precision.
nonisolated struct PruningResourceSnapshot: Codable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let clientUpdatedAt: String?
    let externalResourceId: UUID?
    let workerUserId: UUID?
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case clientUpdatedAt = "client_updated_at"
        case externalResourceId = "external_resource_id"
        case workerUserId = "worker_user_id"
        case deletedAt = "deleted_at"
    }
}

extension PruningResourceSnapshot {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(vineyardId, forKey: .vineyardId)
        try container.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try container.encode(externalResourceId, forKey: .externalResourceId)
        try container.encode(workerUserId, forKey: .workerUserId)
        try container.encode(deletedAt, forKey: .deletedAt)
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        clientUpdatedAt = try container.decode(String?.self, forKey: .clientUpdatedAt)
        externalResourceId = try container.decode(UUID?.self, forKey: .externalResourceId)
        workerUserId = try container.decode(UUID?.self, forKey: .workerUserId)
        deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
    }
}

/// Durable intent lives with the existing activity cache, independently of allocation replay.
nonisolated struct PruningResourceLink: Codable, Sendable, Hashable {
    let generation: UUID
    let externalResourceId: UUID?
    let workerUserId: UUID?
    let name: String
    let authoredBy: UUID
    var expected: PruningResourceSnapshot?
    var conflict: PruningResourceSnapshot?
    var acknowledged: Bool = false
    var failure: String?

    init(externalResourceId: UUID?, workerUserId: UUID?, name: String, authoredBy: UUID) {
        self.generation = UUID()
        self.externalResourceId = externalResourceId
        self.workerUserId = workerUserId
        self.name = name
        self.authoredBy = authoredBy
    }

    var isPending: Bool { !acknowledged }
    var message: String? {
        guard isPending else { return nil }
        if conflict != nil { return "Resource conflict: another device or Portal changed this activity. Your selection is retained; review the server selection before saving again." }
        return failure ?? "Activity saved locally. Resource selection is pending sync."
    }

    func request(activityId: UUID, vineyardId: UUID) throws -> PruningResourceCASParams {
        guard let expected, expected.id == activityId, expected.vineyardId == vineyardId,
              expected.deletedAt == nil, conflict == nil,
              externalResourceId == nil || workerUserId == nil else {
            throw PruningResourceLinkError.invalidBaseline
        }
        return PruningResourceCASParams(
            activityId: activityId, externalResourceId: externalResourceId, workerUserId: workerUserId,
            expectedClientUpdatedAt: expected.clientUpdatedAt,
            expectedExternalResourceId: expected.externalResourceId, expectedWorkerUserId: expected.workerUserId
        )
    }

    /// Never acknowledge an HTTP success unless this exact desired selection was returned.
    func accepting(_ result: PruningResourceCASResult, activityId: UUID) throws -> PruningResourceLink {
        guard result.activityId == activityId else { throw PruningResourceLinkError.invalidAcknowledgement }
        var copy = self
        if result.applied && result.conflict != true && result.externalResourceId == externalResourceId && result.workerUserId == workerUserId {
            copy.acknowledged = true
            copy.failure = nil
        } else if !result.applied && result.conflict == true, let canonical = result.canonical,
                  canonical.id == activityId, canonical.vineyardId == expected?.vineyardId {
            copy.conflict = canonical
            copy.failure = nil
        } else {
            throw PruningResourceLinkError.invalidAcknowledgement
        }
        return copy
    }
}

nonisolated enum PruningResourceLinkError: LocalizedError {
    case invalidBaseline, invalidAcknowledgement
    var errorDescription: String? {
        switch self {
        case .invalidBaseline: "Resource selection needs a verified server record before syncing."
        case .invalidAcknowledgement: "Activity saved; resource selection was not acknowledged. Retry safely."
        }
    }
}

/// All six argument keys must be present, including intentional nulls.
nonisolated struct PruningResourceCASParams: Encodable, Sendable {
    let activityId: UUID
    let externalResourceId: UUID?
    let workerUserId: UUID?
    let expectedClientUpdatedAt: String?
    let expectedExternalResourceId: UUID?
    let expectedWorkerUserId: UUID?
    enum CodingKeys: String, CodingKey {
        case activityId = "p_activity_id"
        case externalResourceId = "p_external_resource_id"
        case workerUserId = "p_worker_user_id"
        case expectedClientUpdatedAt = "p_expected_client_updated_at"
        case expectedExternalResourceId = "p_expected_external_resource_id"
        case expectedWorkerUserId = "p_expected_worker_user_id"
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activityId, forKey: .activityId)
        try container.encode(externalResourceId, forKey: .externalResourceId)
        try container.encode(workerUserId, forKey: .workerUserId)
        try container.encode(expectedClientUpdatedAt, forKey: .expectedClientUpdatedAt)
        try container.encode(expectedExternalResourceId, forKey: .expectedExternalResourceId)
        try container.encode(expectedWorkerUserId, forKey: .expectedWorkerUserId)
    }
}

nonisolated struct PruningResourceCASResult: Decodable, Sendable {
    let activityId: UUID
    let applied: Bool
    let conflict: Bool?
    let idempotent: Bool?
    let externalResourceId: UUID?
    let workerUserId: UUID?
    let canonical: PruningResourceSnapshot?
    enum CodingKeys: String, CodingKey {
        case activityId = "activity_id", applied, conflict, idempotent, canonical
        case externalResourceId = "external_resource_id"
        case workerUserId = "worker_user_id"
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activityId = try container.decode(UUID.self, forKey: .activityId)
        applied = try container.decode(Bool.self, forKey: .applied)
        conflict = try container.decodeIfPresent(Bool.self, forKey: .conflict)
        idempotent = try container.decodeIfPresent(Bool.self, forKey: .idempotent)
        // decode Optional rather than decodeIfPresent: absent identity keys are not acknowledgement.
        externalResourceId = try container.decode(UUID?.self, forKey: .externalResourceId)
        workerUserId = try container.decode(UUID?.self, forKey: .workerUserId)
        canonical = try container.decodeIfPresent(PruningResourceSnapshot.self, forKey: .canonical)
    }
}
