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

@MainActor
final class MaintenancePhotoStorageService {
    private let provider: SupabaseClientProvider
    private let makeAdmission: () throws -> VineyardMutationAdmission
    private let readOwnership: (UUID) async throws -> [VineyardMutationAdmission.Ownership]
    private let uploadObject: (String, Data) async throws -> Void
    private let removeObject: (String) async throws -> Void

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
        self.makeAdmission = { try VineyardMutationAdmission(provider: provider) }
        self.readOwnership = { id in
            guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
            return try await provider.client.from("maintenance_logs").select("id,vineyard_id")
                .eq("id", value: id.uuidString).execute().value
        }
        self.uploadObject = { path, payload in
            _ = try await provider.client.storage.from(MaintenancePhotoStorage.bucket).upload(
                path, data: payload,
                options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true))
        }
        self.removeObject = { path in
            _ = try await provider.client.storage.from(MaintenancePhotoStorage.bucket).remove(paths: [path])
        }
    }

    /// Test seam replaces only external I/O; production ownership/admission and cache behavior remain in use.
    init(admission: @escaping () throws -> VineyardMutationAdmission,
         readOwnership: @escaping (UUID) async throws -> [VineyardMutationAdmission.Ownership],
         upload: @escaping (String, Data) async throws -> Void,
         remove: @escaping (String) async throws -> Void) {
        self.provider = .shared
        self.makeAdmission = admission
        self.readOwnership = readOwnership
        self.uploadObject = upload
        self.removeObject = remove
    }

    private func owner(id: UUID, vineyardId: UUID, allowMissing: Bool,
                       admission: VineyardMutationAdmission) async throws -> UUID {
        // Known holds stop before even an ownership read. Existing remote rows must agree;
        // an absent row is permitted only for an explicit local-first create/upload.
        try admission.requireWrite(vineyardId: vineyardId)
        return try await admission.resolve(id: id, expectedVineyardId: vineyardId,
                                          allowMissingForCreate: allowMissing) {
            try await readOwnership(id)
        }
    }

    @discardableResult
    func uploadPhoto(vineyardId: UUID, maintenanceId: UUID, imageData: Data) async throws -> String {
        let admission = try makeAdmission()
        let vineyard = try await owner(id: maintenanceId, vineyardId: vineyardId, allowMissing: true, admission: admission)
        let path = MaintenancePhotoStorage.path(vineyardId: vineyard, maintenanceId: maintenanceId)
        let payload = MaintenancePhotoStorage.compress(imageData) ?? imageData
        try await admission.send(vineyardId: vineyard) { try await uploadObject(path, payload) }
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
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[1] == "maintenance", parts[3] == "photo.jpg",
              let vineyard = UUID(uuidString: String(parts[0])),
              let record = UUID(uuidString: String(parts[2])),
              path == MaintenancePhotoStorage.path(vineyardId: vineyard, maintenanceId: record),
              vineyardId == nil || vineyardId == vineyard,
              maintenanceId == nil || maintenanceId == record else {
            throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED")
        }
        let admission = try makeAdmission()
        _ = try await owner(id: record, vineyardId: vineyard, allowMissing: false, admission: admission)
        try await admission.send(vineyardId: vineyard) { try await removeObject(path) }
        SharedImageCache.shared.removeCachedImage(for: .maintenancePhoto(vineyardId: vineyard, maintenanceId: record))
    }
}
