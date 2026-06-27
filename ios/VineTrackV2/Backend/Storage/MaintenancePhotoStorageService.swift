import Foundation
import UIKit
import Supabase

nonisolated enum MaintenancePhotoStorage {
    static let bucket = "vineyard-maintenance-photos"

    static func path(vineyardId: UUID, maintenanceId: UUID) -> String {
        "\(vineyardId.uuidString.lowercased())/maintenance/\(maintenanceId.uuidString.lowercased())/photo.jpg"
    }

    /// Resize JPEG to a max edge of ~1600 px and quality 0.8.
    static func compress(_ data: Data, maxEdge: CGFloat = 1600, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let w = image.size.width
        let h = image.size.height
        let scale = min(maxEdge / max(w, h), 1.0)
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

final class MaintenancePhotoStorageService {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    @discardableResult
    func uploadPhoto(vineyardId: UUID, maintenanceId: UUID, imageData: Data) async throws -> String {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let path = MaintenancePhotoStorage.path(vineyardId: vineyardId, maintenanceId: maintenanceId)
        let payload = MaintenancePhotoStorage.compress(imageData) ?? imageData
        _ = try await provider.client.storage
            .from(MaintenancePhotoStorage.bucket)
            .upload(
                path,
                data: payload,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: "image/jpeg",
                    upsert: true
                )
            )
        SharedImageCache.shared.saveImageData(
            payload,
            for: .maintenancePhoto(vineyardId: vineyardId, maintenanceId: maintenanceId),
            remotePath: path,
            remoteUpdatedAt: nil
        )
        return path
    }

    func downloadPhoto(path: String, vineyardId: UUID, maintenanceId: UUID) async throws -> Data {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let data = try await provider.client.storage
            .from(MaintenancePhotoStorage.bucket)
            .download(path: path)
        SharedImageCache.shared.saveImageData(
            data,
            for: .maintenancePhoto(vineyardId: vineyardId, maintenanceId: maintenanceId),
            remotePath: path,
            remoteUpdatedAt: nil
        )
        return data
    }

    func deletePhoto(path: String, vineyardId: UUID? = nil, maintenanceId: UUID? = nil) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        _ = try await provider.client.storage
            .from(MaintenancePhotoStorage.bucket)
            .remove(paths: [path])
        if let vineyardId, let maintenanceId {
            SharedImageCache.shared.removeCachedImage(
                for: .maintenancePhoto(vineyardId: vineyardId, maintenanceId: maintenanceId)
            )
        }
    }
}
