import Foundation
import UIKit
import Supabase

nonisolated enum PinPhotoStorage {
    static let bucket = "vineyard-pin-photos"

    static func path(vineyardId: UUID, pinId: UUID, revision: UUID? = nil) -> String {
        let filename = revision.map { "photo-\($0.uuidString.lowercased()).jpg" } ?? "photo.jpg"
        return "\(vineyardId.uuidString.lowercased())/pins/\(pinId.uuidString.lowercased())/\(filename)"
    }

    static func growthPath(vineyardId: UUID, recordId: UUID, revision: UUID? = nil) -> String {
        let filename = revision.map { "photo-\($0.uuidString.lowercased()).jpg" } ?? "photo.jpg"
        return "\(vineyardId.uuidString.lowercased())/growth/\(recordId.uuidString.lowercased())/\(filename)"
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

protocol PinPhotoStorageProtocol: Sendable {
    func uploadPhoto(vineyardId: UUID, pinId: UUID, revision: UUID, imageData: Data) async throws -> String
    func uploadGrowthPhoto(vineyardId: UUID, recordId: UUID, revision: UUID, imageData: Data) async throws -> String
    func downloadPhoto(path: String, vineyardId: UUID, pinId: UUID) async throws -> Data
    func downloadGrowthPhoto(path: String, vineyardId: UUID, recordId: UUID) async throws -> Data
}

final class PinPhotoStorageService: PinPhotoStorageProtocol, @unchecked Sendable {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    @discardableResult
    func uploadPhoto(vineyardId: UUID, pinId: UUID, revision: UUID, imageData: Data) async throws -> String {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let path = PinPhotoStorage.path(vineyardId: vineyardId, pinId: pinId, revision: revision)
        let payload = PinPhotoStorage.compress(imageData) ?? imageData
        _ = try await provider.client.storage
            .from(PinPhotoStorage.bucket)
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
            for: .pinPhoto(vineyardId: vineyardId, pinId: pinId),
            remotePath: path,
            remoteUpdatedAt: nil,
            attachmentRevision: revision
        )
        return path
    }

    @discardableResult
    func uploadGrowthPhoto(vineyardId: UUID, recordId: UUID, revision: UUID, imageData: Data) async throws -> String {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let path = PinPhotoStorage.growthPath(vineyardId: vineyardId, recordId: recordId, revision: revision)
        let payload = PinPhotoStorage.compress(imageData) ?? imageData
        _ = try await provider.client.storage.from(PinPhotoStorage.bucket).upload(
            path,
            data: payload,
            options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true)
        )
        SharedImageCache.shared.saveImageData(
            payload,
            for: .growthRecordPhoto(vineyardId: vineyardId, recordId: recordId),
            remotePath: path,
            remoteUpdatedAt: nil,
            attachmentRevision: revision
        )
        return path
    }

    func downloadPhoto(path: String, vineyardId: UUID, pinId: UUID) async throws -> Data {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let data = try await provider.client.storage
            .from(PinPhotoStorage.bucket)
            .download(path: path)
        SharedImageCache.shared.saveImageData(
            data,
            for: .pinPhoto(vineyardId: vineyardId, pinId: pinId),
            remotePath: path,
            remoteUpdatedAt: nil
        )
        return data
    }

    func downloadGrowthPhoto(path: String, vineyardId: UUID, recordId: UUID) async throws -> Data {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let data = try await provider.client.storage.from(PinPhotoStorage.bucket).download(path: path)
        SharedImageCache.shared.saveImageData(
            data,
            for: .growthRecordPhoto(vineyardId: vineyardId, recordId: recordId),
            remotePath: path,
            remoteUpdatedAt: nil
        )
        return data
    }

    func deletePhoto(path: String, vineyardId: UUID? = nil, pinId: UUID? = nil) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        _ = try await provider.client.storage
            .from(PinPhotoStorage.bucket)
            .remove(paths: [path])
        if let vineyardId, let pinId {
            SharedImageCache.shared.removeCachedImage(
                for: .pinPhoto(vineyardId: vineyardId, pinId: pinId)
            )
        }
    }
}
