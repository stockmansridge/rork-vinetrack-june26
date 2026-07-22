import Foundation
import UIKit

extension MigratedDataStore {

    var paddockCentroidLatitude: Double? {
        let coords = paddocks.flatMap { $0.polygonPoints }
        guard !coords.isEmpty else { return nil }
        let sum = coords.reduce(0.0) { $0 + $1.latitude }
        return sum / Double(coords.count)
    }

    // MARK: - Custom E-L Stage Image storage
    //
    // Phase 15F: stored per-vineyard so each vineyard's owners can curate
    // their own reference imagery and share it with members through Supabase
    // Storage. A legacy global directory (no vineyard scoping) is still
    // consulted as a read-only fallback so we don't lose pre-15F images.

    private static let legacyELImagesDirName = "CustomELStageImages"
    private static let scopedELImagesDirName = "CustomELStageImages_v2"

    private var legacyCustomELImagesDir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(Self.legacyELImagesDirName, isDirectory: true)
    }

    private func customELImagesDir(for vineyardId: UUID) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base
            .appendingPathComponent(Self.scopedELImagesDirName, isDirectory: true)
            .appendingPathComponent(vineyardId.uuidString.lowercased(), isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func sanitizedStageCode(_ code: String) -> String {
        code.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func customELImageURL(vineyardId: UUID, code: String) -> URL? {
        customELImagesDir(for: vineyardId)?
            .appendingPathComponent("\(sanitizedStageCode(code)).jpg")
    }

    private func legacyCustomELImageURL(for code: String) -> URL? {
        legacyCustomELImagesDir?
            .appendingPathComponent("\(sanitizedStageCode(code)).jpg")
    }

    private func resolvedCustomELImageURL(for code: String) -> URL? {
        if let vineyardId = selectedVineyardId,
           let url = customELImageURL(vineyardId: vineyardId, code: code),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = legacyCustomELImageURL(for: code),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    func hasCustomELStageImage(for code: String) -> Bool {
        resolvedCustomELImageURL(for: code) != nil
    }

    /// Persist a custom E-L stage image for the currently selected vineyard
    /// and notify sync observers so it can be uploaded.
    func saveCustomELStageImage(_ image: UIImage, for code: String) {
        guard let vineyardId = selectedVineyardId,
              let url = customELImageURL(vineyardId: vineyardId, code: code),
              let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: url, options: .atomic)
        onCustomELStageImageChanged?(vineyardId, code)
    }

    /// Apply image bytes pulled from a remote sync. Does NOT fire change hooks.
    func applyRemoteCustomELStageImage(data: Data, for code: String) {
        guard let vineyardId = selectedVineyardId,
              let url = customELImageURL(vineyardId: vineyardId, code: code) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Apply a remote delete pulled from sync. Does NOT fire change hooks.
    func applyRemoteCustomELStageImageDelete(stageCode: String) {
        guard let vineyardId = selectedVineyardId,
              let url = customELImageURL(vineyardId: vineyardId, code: stageCode) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Read raw JPEG bytes for the currently selected vineyard's custom image.
    func loadCustomELStageImageData(for code: String) -> Data? {
        guard let vineyardId = selectedVineyardId,
              let url = customELImageURL(vineyardId: vineyardId, code: code),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    func removeCustomELStageImage(for code: String) {
        guard let vineyardId = selectedVineyardId else { return }
        if let scoped = customELImageURL(vineyardId: vineyardId, code: code) {
            try? FileManager.default.removeItem(at: scoped)
        }
        // Also clear any legacy global copy so the image truly disappears.
        if let legacy = legacyCustomELImageURL(for: code) {
            try? FileManager.default.removeItem(at: legacy)
        }
        onCustomELStageImageDeleted?(vineyardId, code)
    }

    func resolvedELStageImage(for stage: GrowthStage) -> UIImage? {
        if let url = resolvedCustomELImageURL(for: stage.code),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        if let name = stage.imageName, let bundled = UIImage(named: name) {
            return bundled
        }
        return nil
    }
}
