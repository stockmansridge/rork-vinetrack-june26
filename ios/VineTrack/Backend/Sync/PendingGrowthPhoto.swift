import Foundation

/// Durable attachment work for a standalone or pin-linked growth observation.
nonisolated struct PendingGrowthPhoto: Codable, Sendable {
    let recordId: UUID
    let vineyardId: UUID
    let pinId: UUID?
    let revision: UUID
    let imageData: Data
    let capturedAt: Date
    let previousRemotePath: String?
    var uploadedPath: String?

    private enum CodingKeys: String, CodingKey {
        case recordId, vineyardId, pinId, revision, imageData, capturedAt, previousRemotePath, uploadedPath
    }

    init(
        recordId: UUID,
        vineyardId: UUID,
        pinId: UUID?,
        revision: UUID,
        imageData: Data,
        capturedAt: Date,
        previousRemotePath: String?,
        uploadedPath: String? = nil
    ) {
        self.recordId = recordId
        self.vineyardId = vineyardId
        self.pinId = pinId
        self.revision = revision
        self.imageData = imageData
        self.capturedAt = capturedAt
        self.previousRemotePath = previousRemotePath
        self.uploadedPath = uploadedPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordId = try container.decode(UUID.self, forKey: .recordId)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        pinId = try container.decodeIfPresent(UUID.self, forKey: .pinId)
        revision = try container.decode(UUID.self, forKey: .revision)
        imageData = try container.decode(Data.self, forKey: .imageData)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        previousRemotePath = try container.decodeIfPresent(String.self, forKey: .previousRemotePath)
        uploadedPath = try container.decodeIfPresent(String.self, forKey: .uploadedPath)
    }
}
