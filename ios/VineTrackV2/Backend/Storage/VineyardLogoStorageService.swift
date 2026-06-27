import Foundation
import Supabase

nonisolated enum VineyardLogoStorage {
    static let bucket = "vineyard-logos"

    static func path(for vineyardId: UUID) -> String {
        "\(vineyardId.uuidString.lowercased())/logo.jpg"
    }
}

final class VineyardLogoStorageService {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    /// Uploads (or replaces) the logo for the given vineyard. Returns the
    /// storage path that should be stored in `vineyards.logo_path`.
    @discardableResult
    func uploadLogo(vineyardId: UUID, imageData: Data, remoteUpdatedAt: Date? = nil) async throws -> String {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let path = VineyardLogoStorage.path(for: vineyardId)
        _ = try await provider.client.storage
            .from(VineyardLogoStorage.bucket)
            .upload(
                path,
                data: imageData,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: "image/jpeg",
                    upsert: true
                )
            )
        SharedImageCache.shared.saveImageData(
            imageData,
            for: .vineyardLogo(vineyardId: vineyardId),
            remotePath: path,
            remoteUpdatedAt: remoteUpdatedAt
        )
        return path
    }

    func downloadLogo(path: String, vineyardId: UUID, remoteUpdatedAt: Date? = nil) async throws -> Data {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let data = try await provider.client.storage
            .from(VineyardLogoStorage.bucket)
            .download(path: path)
        SharedImageCache.shared.saveImageData(
            data,
            for: .vineyardLogo(vineyardId: vineyardId),
            remotePath: path,
            remoteUpdatedAt: remoteUpdatedAt
        )
        return data
    }

    func deleteLogo(path: String, vineyardId: UUID? = nil) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        _ = try await provider.client.storage
            .from(VineyardLogoStorage.bucket)
            .remove(paths: [path])
        if let vineyardId {
            SharedImageCache.shared.removeCachedImage(for: .vineyardLogo(vineyardId: vineyardId))
        }
    }
}
