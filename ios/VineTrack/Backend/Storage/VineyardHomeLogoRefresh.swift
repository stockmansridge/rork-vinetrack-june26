import Foundation
import UIKit

/// Read-only logo reconciliation, independent of operational queues and writes.
/// Captured scope includes the account incarnation and selection generation.
@MainActor
enum VineyardHomeLogoRefresh {
    static func refresh(
        vineyardId: UUID,
        store: MigratedDataStore,
        cache: SharedImageCache = .shared,
        online: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        metadata: () async throws -> BackendVineyard?,
        download: (String) async throws -> Data
    ) async {
        guard isCurrent(), var initial = store.vineyards.first(where: { $0.id == vineyardId }) else { return }
        let key = SharedImageCacheKey.vineyardLogo(vineyardId: vineyardId)
        if initial.logoPath != nil, initial.logoData == nil,
           let bytes = cache.cachedImageData(for: key), UIImage(data: bytes) != nil {
            initial.logoData = bytes
            store.upsertLocalVineyard(initial)
        }
        guard online else { return }
        do {
            // Inaccessible/absent rows are not authoritative logo removal.
            guard let remote = try await metadata(), remote.id == vineyardId,
                  !Task.isCancelled, isCurrent(),
                  var current = store.vineyards.first(where: { $0.id == vineyardId }),
                  current.logoPath == initial.logoPath, current.logoUpdatedAt == initial.logoUpdatedAt else { return }
            if let path = remote.logoPath {
                // A metadata mistake must never fetch another vineyard's object.
                guard (try? VineyardAttachmentPath.vineyard(path)) == vineyardId else { return }
            }
            current.logoPath = remote.logoPath
            current.logoUpdatedAt = remote.logoUpdatedAt
            guard let path = remote.logoPath else {
                current.logoData = nil
                cache.removeCachedImage(for: key)
                store.upsertLocalVineyard(current)
                return
            }
            // Retain known-good bytes while the replacement downloads.
            store.upsertLocalVineyard(current)
            if cache.isCacheCurrent(for: key, remotePath: path, remoteUpdatedAt: remote.logoUpdatedAt),
               (cache.metadata(for: key)?.remoteUpdatedAt == nil) == (remote.logoUpdatedAt == nil),
               current.logoData != nil { return }
            let bytes = try await download(path)
            guard !Task.isCancelled, isCurrent(), UIImage(data: bytes) != nil,
                  var latest = store.vineyards.first(where: { $0.id == vineyardId }),
                  latest.logoPath == path, latest.logoUpdatedAt == remote.logoUpdatedAt else { return }
            cache.saveImageData(bytes, for: key, remotePath: path, remoteUpdatedAt: remote.logoUpdatedAt)
            latest.logoData = bytes
            store.upsertLocalVineyard(latest)
        } catch {
            // Offline, expired credentials and transient storage errors retain
            // both known metadata and bytes. The next ordinary sweep retries.
        }
    }
}
