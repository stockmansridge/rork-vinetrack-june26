import Foundation
import UIKit

/// App-private file storage for Scout photographs.
///
/// ## Why the bytes go to disk before anything else happens
///
/// A scouting photograph is evidence of a condition that existed at one moment
/// in one block. It cannot be retaken later — the powdery mildew either looked
/// like that on the day or it did not. So the bytes are written to app-private
/// storage FIRST, and only then is an upload queued. An implementation that
/// uploads from memory loses the photograph whenever the app is killed in a
/// paddock with no signal, which is precisely where scouting happens.
///
/// ## Layout mirrors the server path convention
///
/// `.../ScoutPhotos/{vineyardId}/{observationId}/{photoId}.jpg`
///
/// This is the same shape as the `scout-photos` bucket path in SQL 236
/// (`{vineyard_id}/{observation_id}/{uuid}.jpg`), so the local file and the
/// remote object are trivially reconcilable, and every file is already scoped
/// by vineyard for the sign-out wipe.
///
/// ## One file per photo id, never a shared name
///
/// The filename is the photo's own client-generated id. Two photographs of the
/// same item therefore cannot overwrite one another — the defect that a
/// "current photo" filename would reintroduce.
nonisolated final class ScoutPhotoFileStore: @unchecked Sendable {

    private let fileManager: FileManager
    private let root: URL?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        // Application Support is backed up and not purgeable, unlike Caches.
        // A field photograph must not be evicted by the system to reclaim space
        // before it has been uploaded.
        self.root = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ScoutPhotos", isDirectory: true)
    }

    /// Relative path stored on the record. Kept relative so the photograph
    /// survives the container path changing between app launches or upgrades —
    /// an absolute path captured in June can be invalid in July.
    static func relativePath(vineyardID: UUID, observationID: UUID, photoID: UUID) -> String {
        "\(vineyardID.uuidString.lowercased())/\(observationID.uuidString.lowercased())/\(photoID.uuidString.lowercased()).jpg"
    }

    /// The matching object path inside the private `scout-photos` bucket.
    ///
    /// The first folder MUST be the vineyard id: the SQL 236 storage policies
    /// authorise on `storage_first_folder_uuid(name)`, so any other shape would
    /// be refused by the bucket rather than silently misfiled.
    static func storagePath(vineyardID: UUID, observationID: UUID, photoID: UUID) -> String {
        relativePath(vineyardID: vineyardID, observationID: observationID, photoID: photoID)
    }

    func absoluteURL(forRelativePath path: String) -> URL? {
        root?.appendingPathComponent(path)
    }

    /// Compress using the same convention as the existing pin photo pipeline
    /// (1600 px longest edge, JPEG 0.8) so Scout photographs are the same
    /// weight as every other photograph the app uploads.
    static func compress(_ data: Data) -> Data? {
        PinPhotoStorage.compress(data)
    }

    /// Write the bytes durably and return the relative path.
    ///
    /// Throws rather than returning nil: a caller must not be able to treat a
    /// failed write as a successful capture. `.atomic` means a crash mid-write
    /// leaves either the old file or the new one, never a truncated JPEG that
    /// would later decode to a grey rectangle.
    @discardableResult
    func write(
        data: Data,
        vineyardID: UUID,
        observationID: UUID,
        photoID: UUID
    ) throws -> String {
        guard let root else { throw ScoutPhotoStoreError.noStorageDirectory }
        let relative = Self.relativePath(
            vineyardID: vineyardID,
            observationID: observationID,
            photoID: photoID
        )
        let url = root.appendingPathComponent(relative)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = Self.compress(data) ?? data
        try payload.write(to: url, options: .atomic)
        return relative
    }

    func data(atRelativePath path: String) -> Data? {
        guard let url = absoluteURL(forRelativePath: path) else { return nil }
        return try? Data(contentsOf: url)
    }

    func image(atRelativePath path: String) -> UIImage? {
        guard let data = data(atRelativePath: path) else { return nil }
        return UIImage(data: data)
    }

    func exists(atRelativePath path: String) -> Bool {
        guard let url = absoluteURL(forRelativePath: path) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Remove one photograph's bytes. Used when the operator deletes a photo.
    func remove(relativePath: String) {
        guard let url = absoluteURL(forRelativePath: relativePath) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Drop every locally held Scout photograph.
    ///
    /// Sign-out must not leave one System Admin's field photographs readable to
    /// the next person who signs in on the same handset.
    func clearForSignOut() {
        guard let root else { return }
        try? fileManager.removeItem(at: root)
    }
}

nonisolated enum ScoutPhotoStoreError: LocalizedError, Sendable {
    case noStorageDirectory

    var errorDescription: String? {
        switch self {
        case .noStorageDirectory:
            return "This device has no available storage location for photographs."
        }
    }
}
