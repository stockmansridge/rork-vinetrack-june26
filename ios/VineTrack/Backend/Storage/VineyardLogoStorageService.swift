import Foundation
import Supabase
import UIKit

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
        let admission = try VineyardMutationAdmission(provider: provider)
        let path = VineyardLogoStorage.path(for: vineyardId)
        _ = try await admission.send(vineyardId: vineyardId) { try await provider.client.storage
            .from(VineyardLogoStorage.bucket)
            .upload(
                path,
                data: imageData,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: "image/jpeg",
                    upsert: true
                )
            ) }
        try admission.requireCurrentAccount()
        SharedImageCache.shared.saveImageData(
            imageData,
            for: .vineyardLogo(vineyardId: vineyardId),
            remotePath: path,
            remoteUpdatedAt: remoteUpdatedAt
        )
        return path
    }

    func downloadLogo(path: String, vineyardId: UUID, remoteUpdatedAt: Date? = nil,
                      cacheResult: Bool = true, isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> Data {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        guard let account = provider.client.auth.currentUser?.id,
              (try? VineyardAttachmentPath.vineyard(path)) == vineyardId, isCurrent() else { throw CancellationError() }
        let data = try await provider.client.storage
            .from(VineyardLogoStorage.bucket)
            .download(path: path)
        guard !Task.isCancelled, provider.client.auth.currentUser?.id == account,
              isCurrent(), UIImage(data: data) != nil else { throw CancellationError() }
        if cacheResult {
            SharedImageCache.shared.saveImageData(
                data,
                for: .vineyardLogo(vineyardId: vineyardId),
                remotePath: path,
                remoteUpdatedAt: remoteUpdatedAt
            )
        }
        return data
    }

    func deleteLogo(path: String, vineyardId: UUID? = nil) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let owner = try VineyardAttachmentPath.vineyard(path)
        guard path == VineyardLogoStorage.path(for: owner), vineyardId == nil || vineyardId == owner else {
            throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED")
        }
        let admission = try VineyardMutationAdmission(provider: provider)
        _ = try await admission.send(vineyardId: owner) {
            try await provider.client.storage.from(VineyardLogoStorage.bucket).remove(paths: [path])
        }
        try admission.requireCurrentAccount()
        if let vineyardId {
            SharedImageCache.shared.removeCachedImage(for: .vineyardLogo(vineyardId: vineyardId))
        }
    }
}
