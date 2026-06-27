import Foundation
import UIKit
import Supabase

nonisolated enum ELStageImageStorage {
    static let bucket = "vineyard-el-stage-images"

    static func path(vineyardId: UUID, stageCode: String) -> String {
        let safe = stageCode
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(vineyardId.uuidString.lowercased())/el-stages/\(safe).jpg"
    }

    static func compress(_ data: Data, maxEdge: CGFloat = 1400, quality: CGFloat = 0.8) -> Data? {
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

final class ELStageImageStorageService {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    @discardableResult
    func uploadStageImage(vineyardId: UUID, stageCode: String, imageData: Data, remoteUpdatedAt: Date? = nil) async throws -> String {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let path = ELStageImageStorage.path(vineyardId: vineyardId, stageCode: stageCode)
        let payload = ELStageImageStorage.compress(imageData) ?? imageData
        _ = try await provider.client.storage
            .from(ELStageImageStorage.bucket)
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
            for: .elStageImage(vineyardId: vineyardId, stageCode: stageCode),
            remotePath: path,
            remoteUpdatedAt: remoteUpdatedAt
        )
        return path
    }

    func downloadStageImage(path: String, vineyardId: UUID, stageCode: String, remoteUpdatedAt: Date? = nil) async throws -> Data {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let data = try await provider.client.storage
            .from(ELStageImageStorage.bucket)
            .download(path: path)
        SharedImageCache.shared.saveImageData(
            data,
            for: .elStageImage(vineyardId: vineyardId, stageCode: stageCode),
            remotePath: path,
            remoteUpdatedAt: remoteUpdatedAt
        )
        return data
    }

    func deleteStageImage(path: String, vineyardId: UUID? = nil, stageCode: String? = nil) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        _ = try await provider.client.storage
            .from(ELStageImageStorage.bucket)
            .remove(paths: [path])
        if let vineyardId, let stageCode {
            SharedImageCache.shared.removeCachedImage(
                for: .elStageImage(vineyardId: vineyardId, stageCode: stageCode)
            )
        }
    }
}
