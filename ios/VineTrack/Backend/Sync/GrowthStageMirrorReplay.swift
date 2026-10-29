import Foundation

/// Positive identity acknowledgement only; never an overwrite or unique-index bypass.
nonisolated enum GrowthStageMirrorReplay {
    static func isUnmodifiedBackfill(_ local: GrowthStageRecord, of server: BackendGrowthStageRecord) -> Bool {
        guard let pin = local.pinId, server.pinId == pin,
              server.id != local.id, server.vineyardId == local.vineyardId,
              server.deletedAt == nil, server.stageCode == local.stageCode,
              server.paddockId == local.paddockId, server.rowNumber == local.rowNumber,
              server.side == local.side, server.notes == local.notes,
              let serverObserved = server.observedAt,
              let serverCreated = server.createdAt,
              // Historical Pins can be saved up to two minutes after field capture.
              // The extended window is admissible ONLY if the canonical record
              // was actually created alongside the Pin (not during a later backfill).
              (abs(local.observedAt.timeIntervalSince(serverObserved)) <= 30 ||
               (abs(local.createdAt.timeIntervalSince(serverCreated)) <= 3 &&
                abs(local.observedAt.timeIntervalSince(serverObserved)) <= 120)),
              local.createdAt == local.observedAt, local.updatedAt == local.observedAt,
              sameCoordinate(local.latitude, server.latitude),
              sameCoordinate(local.longitude, server.longitude),
              Set(local.photoPaths).isSubset(of: Set(server.photoPaths ?? [])) else { return false }
        // Unknown ownership is not affirmative identity evidence.
        guard let author = local.createdBy, author == server.createdBy,
              local.updatedBy == nil || local.updatedBy == author,
              local.variety == nil || local.variety == server.variety,
              local.varietyId == nil || local.varietyId == server.varietyId,
              local.recordedByName == nil || local.recordedByName == server.recordedByName,
              server.createdAt != nil, server.updatedAt != nil else { return false }
        return true
    }

    private static func sameCoordinate(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.isFinite && b.isFinite && abs(a - b) < 0.00001
        default: return false
        }
    }
}
