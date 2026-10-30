import Foundation
import Testing
import UIKit
@testable import VineTrack

@MainActor
struct VineyardHomeLogoRefreshTests {
    private func bytes(_ color: UIColor = .green) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).jpegData(withCompressionQuality: 0.9) { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
    private func remote(_ id: UUID, path: String?, updated: Date? = nil) -> BackendVineyard {
        BackendVineyard(id: id, name: "Logo fixture", ownerId: nil, country: "AU", logoPath: path,
            logoUpdatedAt: updated, createdAt: nil, updatedAt: nil, deletedAt: nil)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("records"), withIntermediateDirectories: true)
        return root
    }

    @Test func ordinaryRefreshPublishesAndPersistsReplacement() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root.appendingPathComponent("records")))
        let id = UUID(), path = VineyardLogoStorage.path(for: id), old = bytes(), replacement = bytes(.blue)
        let cache = SharedImageCache(baseDir: root.appendingPathComponent("images"))
        store.upsertLocalVineyard(Vineyard(id: id, name: "Fixture", logoData: old, logoPath: path))
        let updated = Date(timeIntervalSince1970: 1000)
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, cache: cache, online: true,
            isCurrent: { true }, metadata: { remote(id, path: path, updated: updated) }, download: { _ in replacement })
        #expect(store.vineyards.first?.logoData == replacement)
        #expect(store.vineyards.first?.logoUpdatedAt == updated)
        #expect(cache.cachedImageData(for: .vineyardLogo(vineyardId: id)) == replacement)
    }

    @Test func offlineRestartHydratesWithoutNetwork() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = PersistenceStore(directory: root.appendingPathComponent("records"))
        let id = UUID(), path = VineyardLogoStorage.path(for: id), image = bytes()
        let cache = SharedImageCache(baseDir: root.appendingPathComponent("images"))
        cache.saveImageData(image, for: .vineyardLogo(vineyardId: id), remotePath: path, remoteUpdatedAt: nil)
        MigratedDataStore(persistence: disk).upsertLocalVineyard(Vineyard(id: id, name: "Fixture", logoPath: path))
        let reopened = MigratedDataStore(persistence: disk)
        var calls = 0
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: reopened, cache: cache, online: false,
            isCurrent: { true }, metadata: { calls += 1; return nil }, download: { _ in calls += 1; return Data() })
        #expect(calls == 0)
        #expect(reopened.vineyards.first?.logoData == image)
    }

    @Test func metadataFailureRetainsKnownMetadataAndBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let id = UUID(), path = VineyardLogoStorage.path(for: id), image = bytes(), stamp = Date()
        store.upsertLocalVineyard(Vineyard(id: id, name: "Fixture", logoData: image, logoPath: path, logoUpdatedAt: stamp))
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, online: true,
            isCurrent: { true }, metadata: { throw URLError(.notConnectedToInternet) }, download: { _ in Data() })
        #expect(store.vineyards.first?.logoPath == path)
        #expect(store.vineyards.first?.logoUpdatedAt == stamp)
        #expect(store.vineyards.first?.logoData == image)
    }

    @Test func storageFailureRetainsBytesAndRetriesNextRefresh() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root.appendingPathComponent("records")))
        let cache = SharedImageCache(baseDir: root.appendingPathComponent("images"))
        let id = UUID(), path = VineyardLogoStorage.path(for: id), image = bytes(), replacement = bytes(.blue)
        let stamp = Date(timeIntervalSince1970: 1000)
        store.upsertLocalVineyard(Vineyard(id: id, name: "Fixture", logoData: image, logoPath: path))
        cache.saveImageData(image, for: .vineyardLogo(vineyardId: id), remotePath: path, remoteUpdatedAt: nil)
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, cache: cache, online: true,
            isCurrent: { true }, metadata: { remote(id, path: path, updated: stamp) }, download: { _ in throw URLError(.userAuthenticationRequired) })
        #expect(store.vineyards.first?.logoData == image)
        #expect(cache.cachedImageData(for: .vineyardLogo(vineyardId: id)) == image)
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, cache: cache, online: true,
            isCurrent: { true }, metadata: { remote(id, path: path, updated: stamp) }, download: { _ in replacement })
        #expect(store.vineyards.first?.logoData == replacement)
    }

    @Test func authoritativeNullRemovesButMissingRowRetains() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root.appendingPathComponent("records")))
        let cache = SharedImageCache(baseDir: root.appendingPathComponent("images"))
        let id = UUID(), path = VineyardLogoStorage.path(for: id), image = bytes(), key = SharedImageCacheKey.vineyardLogo(vineyardId: id)
        store.upsertLocalVineyard(Vineyard(id: id, name: "Fixture", logoData: image, logoPath: path))
        cache.saveImageData(image, for: key, remotePath: path, remoteUpdatedAt: nil)
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, cache: cache, online: true,
            isCurrent: { true }, metadata: { nil }, download: { _ in Data() })
        #expect(store.vineyards.first?.logoData == image)
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, cache: cache, online: true,
            isCurrent: { true }, metadata: { remote(id, path: nil) }, download: { _ in Data() })
        #expect(store.vineyards.first?.logoData == nil)
        #expect(store.vineyards.first?.logoPath == nil)
        #expect(cache.cachedImageData(for: key) == nil)
    }

    @Test(arguments: [true, false])
    func changedScopeDropsMetadataOrDownload(_ duringMetadata: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root.appendingPathComponent("records")))
        let cache = SharedImageCache(baseDir: root.appendingPathComponent("images"))
        let id = UUID(), path = VineyardLogoStorage.path(for: id), image = bytes()
        store.upsertLocalVineyard(Vineyard(id: id, name: "Fixture", logoData: image, logoPath: path))
        var scopeCurrent = true
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, cache: cache, online: true,
            isCurrent: { scopeCurrent }, metadata: {
                if duringMetadata { scopeCurrent = false }; await Task.yield()
                return remote(id, path: path, updated: Date(timeIntervalSince1970: 1000))
            }, download: { _ in scopeCurrent = false; await Task.yield(); return bytes(.blue) })
        #expect(store.vineyards.first?.logoData == image)
        #expect(cache.cachedImageData(for: .vineyardLogo(vineyardId: id)) == nil)
        if duringMetadata { #expect(store.vineyards.first?.logoUpdatedAt == nil) }
    }

    @Test func newerLocalReplacementWinsDuringDownload() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root.appendingPathComponent("records")))
        let cache = SharedImageCache(baseDir: root.appendingPathComponent("images"))
        let id = UUID(), path = VineyardLogoStorage.path(for: id), newest = bytes(.red)
        store.upsertLocalVineyard(Vineyard(id: id, name: "Fixture", logoPath: path))
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, cache: cache, online: true,
            isCurrent: { true }, metadata: { remote(id, path: path) }, download: { _ in
                var newer = store.vineyards[0]; newer.logoData = newest; newer.logoUpdatedAt = Date(timeIntervalSince1970: 2000)
                store.upsertLocalVineyard(newer); await Task.yield(); return bytes(.blue)
            })
        #expect(store.vineyards.first?.logoData == newest)
        #expect(cache.cachedImageData(for: .vineyardLogo(vineyardId: id)) == nil)
    }

    @Test func foreignVineyardPathNeverDownloads() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let id = UUID(); store.upsertLocalVineyard(Vineyard(id: id, name: "Fixture"))
        var downloads = 0
        await VineyardHomeLogoRefresh.refresh(vineyardId: id, store: store, online: true,
            isCurrent: { true }, metadata: { remote(id, path: VineyardLogoStorage.path(for: UUID())) },
            download: { _ in downloads += 1; return bytes() })
        #expect(downloads == 0)
        #expect(store.vineyards.first?.logoPath == nil)
    }

    @Test func authoritativeNullDoesNotHydrateOrphanOnInitialMapping() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), key = SharedImageCacheKey.vineyardLogo(vineyardId: id)
        defer { SharedImageCache.shared.removeCachedImage(for: key) }
        SharedImageCache.shared.saveImageData(bytes(), for: key, remotePath: VineyardLogoStorage.path(for: id), remoteUpdatedAt: nil)
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        store.mapBackendVineyardsIntoLocal([remote(id, path: nil)])
        #expect(store.vineyards.first?.logoData == nil)
        #expect(SharedImageCache.shared.cachedImageData(for: key) == nil)
    }
}
