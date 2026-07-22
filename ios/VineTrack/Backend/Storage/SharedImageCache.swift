import Foundation

/// Identifies a cached image by vineyard scope and image type.
nonisolated enum SharedImageCacheKey: Hashable, Sendable {
    case vineyardLogo(vineyardId: UUID)
    case pinPhoto(vineyardId: UUID, pinId: UUID)
    case elStageImage(vineyardId: UUID, stageCode: String)
    case maintenancePhoto(vineyardId: UUID, maintenanceId: UUID)

    var relativePath: String {
        switch self {
        case .vineyardLogo(let vineyardId):
            return "vineyards/\(vineyardId.uuidString.lowercased())/logo.jpg"
        case .pinPhoto(let vineyardId, let pinId):
            return "vineyards/\(vineyardId.uuidString.lowercased())/pins/\(pinId.uuidString.lowercased()).jpg"
        case .elStageImage(let vineyardId, let stageCode):
            let safe = stageCode
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            return "vineyards/\(vineyardId.uuidString.lowercased())/el-stages/\(safe).jpg"
        case .maintenancePhoto(let vineyardId, let maintenanceId):
            return "vineyards/\(vineyardId.uuidString.lowercased())/maintenance/\(maintenanceId.uuidString.lowercased()).jpg"
        }
    }
}

nonisolated struct SharedImageCacheMetadata: Codable, Sendable {
    var remotePath: String?
    var remoteUpdatedAt: Date?
    var cachedAt: Date
}

/// Disk-backed cache for shared vineyard image assets (logos, pin photos,
/// custom E-L reference images, future maintenance photos). Lives under
/// `Application Support/VineTrackImageCache/...` so cached images survive
/// app relaunches and are available immediately on cold start, without
/// requiring a manual sync.
///
/// The cache is intentionally vineyard-scoped: removing a vineyard from
/// the device does not automatically purge its images, but a cached image
/// is removed when the user explicitly deletes it or when sync reports a
/// remote soft-delete. The remote Storage/database remain the source of
/// truth — the cache only mirrors successful downloads/uploads.
nonisolated final class SharedImageCache: @unchecked Sendable {
    static let shared = SharedImageCache()

    private let baseDir: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseDir: URL? = nil) {
        if let baseDir {
            self.baseDir = baseDir
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.baseDir = support.appendingPathComponent("VineTrackImageCache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.baseDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - URLs

    func localFileURL(for key: SharedImageCacheKey) -> URL {
        baseDir.appendingPathComponent(key.relativePath)
    }

    private func metadataURL(for key: SharedImageCacheKey) -> URL {
        baseDir.appendingPathComponent(key.relativePath + ".meta.json")
    }

    private func ensureDir(for url: URL) {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Read

    func cachedImageData(for key: SharedImageCacheKey) -> Data? {
        let url = localFileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    func metadata(for key: SharedImageCacheKey) -> SharedImageCacheMetadata? {
        let url = metadataURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SharedImageCacheMetadata.self, from: data)
    }

    // MARK: - Write

    func saveImageData(
        _ data: Data,
        for key: SharedImageCacheKey,
        remotePath: String?,
        remoteUpdatedAt: Date?
    ) {
        let fileURL = localFileURL(for: key)
        ensureDir(for: fileURL)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[SharedImageCache] write failed \(fileURL.lastPathComponent): \(error.localizedDescription)")
            #endif
            return
        }
        let meta = SharedImageCacheMetadata(
            remotePath: remotePath,
            remoteUpdatedAt: remoteUpdatedAt,
            cachedAt: Date()
        )
        if let encoded = try? encoder.encode(meta) {
            let metaURL = metadataURL(for: key)
            try? encoded.write(to: metaURL, options: .atomic)
        }
    }

    func removeCachedImage(for key: SharedImageCacheKey) {
        try? FileManager.default.removeItem(at: localFileURL(for: key))
        try? FileManager.default.removeItem(at: metadataURL(for: key))
    }

    /// Marks the cache stale without deleting the cached bytes, so the next
    /// sync forces a re-download but the old image is still displayed in the
    /// meantime.
    func markStale(for key: SharedImageCacheKey) {
        try? FileManager.default.removeItem(at: metadataURL(for: key))
    }

    // MARK: - Freshness

    /// Returns `true` if a cached image exists and its recorded remote path
    /// (and optional `remoteUpdatedAt`) match what we know remotely. When
    /// either side has no `remoteUpdatedAt`, only the path is compared.
    func isCacheCurrent(
        for key: SharedImageCacheKey,
        remotePath: String?,
        remoteUpdatedAt: Date?
    ) -> Bool {
        let url = localFileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let meta = metadata(for: key) else { return false }

        if let remotePath {
            if let cachedPath = meta.remotePath, cachedPath != remotePath {
                return false
            }
            if meta.remotePath == nil { return false }
        }

        if let remoteUpdatedAt, let cachedAt = meta.remoteUpdatedAt {
            if abs(cachedAt.timeIntervalSince(remoteUpdatedAt)) > 0.5 {
                return false
            }
        } else if remoteUpdatedAt != nil, meta.remoteUpdatedAt == nil {
            // We have a remote timestamp but never recorded one locally.
            return false
        }

        return true
    }
}
