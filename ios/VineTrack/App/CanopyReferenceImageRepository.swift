import Foundation
import Observation
import Supabase
import UIKit

nonisolated struct CanopyReferenceRemoteImage: Codable, Equatable, Sendable {
    let path: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case path
        case updatedAt = "updated_at"
    }
}

nonisolated struct CanopyReferenceConfiguration: Codable, Equatable, Sendable {
    let bucket: String
    let configUpdatedAt: String?
    let images: [String: CanopyReferenceRemoteImage]

    enum CodingKeys: String, CodingKey {
        case bucket
        case configUpdatedAt = "config_updated_at"
        case images
    }
}

protocol CanopyReferenceImageRemote: Sendable {
    func fetchConfiguration() async throws -> CanopyReferenceConfiguration
    func downloadImage(bucket: String, path: String) async throws -> Data
}

final class SupabaseCanopyReferenceImageRemote: CanopyReferenceImageRemote, @unchecked Sendable {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchConfiguration() async throws -> CanopyReferenceConfiguration {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        return try await provider.client
            .rpc("get_canopy_reference_images_v1")
            .execute()
            .value
    }

    func downloadImage(bucket: String, path: String) async throws -> Data {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        return try await provider.client.storage.from(bucket).download(path: path)
    }
}

nonisolated struct CanopyReferenceManifestEntry: Codable, Equatable, Sendable {
    let slotKey: String
    let remotePath: String
    let remoteUpdatedAt: String
    let localFilename: String
    let successfulDownload: Bool

    func matches(_ remote: CanopyReferenceRemoteImage) -> Bool {
        successfulDownload && remotePath == remote.path && remoteUpdatedAt == remote.updatedAt
    }
}

nonisolated struct CanopyReferenceManifest: Codable, Equatable, Sendable {
    var entries: [String: CanopyReferenceManifestEntry]
}

/// Durable mirror of the eight portal-managed canopy reference images.
///
/// Image bytes live in Application Support and are never streamed by the UI.
/// The manifest is committed only after a replacement has been decoded and
/// atomically promoted, so a failed refresh cannot destroy a working image.
@MainActor
@Observable
final class CanopyReferenceImageRepository {
    private(set) var revision: Int = 0

    private let baseDirectory: URL
    private let manifestURL: URL
    private let remote: any CanopyReferenceImageRemote
    private let fileManager: FileManager
    private let validator: @Sendable (Data) -> Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var manifest: CanopyReferenceManifest
    private var hasAttemptedSessionRefresh = false
    private var isRefreshing = false

    init(
        baseDirectory: URL? = nil,
        remote: (any CanopyReferenceImageRemote)? = nil,
        fileManager: FileManager = .default,
        validator: @escaping @Sendable (Data) -> Bool = { data in
            guard let image = UIImage(data: data) else { return false }
            return image.size.width > 0 && image.size.height > 0
        }
    ) {
        self.fileManager = fileManager
        self.remote = remote ?? SupabaseCanopyReferenceImageRemote()
        self.validator = validator
        let root = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VineTrack", isDirectory: true)
            .appendingPathComponent("CanopyReferenceImages", isDirectory: true)
        self.baseDirectory = root
        self.manifestURL = root.appendingPathComponent("manifest.json")
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.manifestURL),
           let decoded = try? JSONDecoder().decode(CanopyReferenceManifest.self, from: data) {
            self.manifest = decoded
        } else {
            self.manifest = CanopyReferenceManifest(entries: [:])
        }
    }

    /// Called by Spray Setup. Recomposition cannot trigger another config read.
    func refreshOncePerSession() async {
        guard !hasAttemptedSessionRefresh else { return }
        await refresh()
    }

    /// Performs a lightweight config check and downloads only changed slots.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let configuration = try await remote.fetchConfiguration()
            guard !configuration.bucket.isEmpty else { return }
            hasAttemptedSessionRefresh = true
            try await apply(configuration)
        } catch {
            // Existing durable files remain the offline source. A later session
            // or explicit refresh can retry without blanking Spray Setup.
        }
    }

    func localImageURL(for slot: CanopyReferenceImageSlot) -> URL? {
        guard let entry = manifest.entries[slot.rawValue], entry.successfulDownload else { return nil }
        let url = baseDirectory.appendingPathComponent(entry.localFilename)
        guard let data = try? Data(contentsOf: url), validator(data) else { return nil }
        return url
    }

    func manifestEntry(for slot: CanopyReferenceImageSlot) -> CanopyReferenceManifestEntry? {
        manifest.entries[slot.rawValue]
    }

    private func apply(_ configuration: CanopyReferenceConfiguration) async throws {
        let supported = Set(CanopyReferenceImageSlot.allCases.map(\.rawValue))
        let remoteImages = configuration.images.filter { supported.contains($0.key) }

        // A missing slot is an intentional admin reset. Commit the fallback
        // state before deleting obsolete bytes.
        let removedKeys = Set(manifest.entries.keys).subtracting(remoteImages.keys)
        if !removedKeys.isEmpty {
            var resetManifest = manifest
            let obsolete = removedKeys.compactMap { resetManifest.entries.removeValue(forKey: $0) }
            try saveManifest(resetManifest)
            manifest = resetManifest
            obsolete.forEach { try? fileManager.removeItem(at: baseDirectory.appendingPathComponent($0.localFilename)) }
            revision += 1
        }

        for slot in CanopyReferenceImageSlot.allCases {
            guard let remoteImage = remoteImages[slot.rawValue],
                  !remoteImage.path.isEmpty,
                  !remoteImage.updatedAt.isEmpty else { continue }

            if let local = manifest.entries[slot.rawValue],
               local.matches(remoteImage),
               isUsableLocalFile(named: local.localFilename) {
                continue
            }

            do {
                let data = try await remote.downloadImage(bucket: configuration.bucket, path: remoteImage.path)
                guard validator(data) else { continue }
                try persistReplacement(data: data, slot: slot, remoteImage: remoteImage)
            } catch {
                // Keep the prior manifest entry and bytes. Only this changed slot
                // is retried on a later normal refresh.
                continue
            }
        }
    }

    private func persistReplacement(
        data: Data,
        slot: CanopyReferenceImageSlot,
        remoteImage: CanopyReferenceRemoteImage
    ) throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let filename = "\(slot.rawValue.replacingOccurrences(of: ".", with: "_"))-\(UUID().uuidString.lowercased()).img"
        let destination = baseDirectory.appendingPathComponent(filename)
        let temporary = baseDirectory.appendingPathComponent(".\(UUID().uuidString).download")
        try data.write(to: temporary, options: .atomic)
        guard let persistedData = try? Data(contentsOf: temporary), validator(persistedData) else {
            try? fileManager.removeItem(at: temporary)
            return
        }
        try fileManager.moveItem(at: temporary, to: destination)

        let previous = manifest.entries[slot.rawValue]
        var updatedManifest = manifest
        updatedManifest.entries[slot.rawValue] = CanopyReferenceManifestEntry(
            slotKey: slot.rawValue,
            remotePath: remoteImage.path,
            remoteUpdatedAt: remoteImage.updatedAt,
            localFilename: filename,
            successfulDownload: true
        )
        do {
            try saveManifest(updatedManifest)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        manifest = updatedManifest
        revision += 1
        if let previous, previous.localFilename != filename {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(previous.localFilename))
        }
    }

    private func saveManifest(_ value: CanopyReferenceManifest) throws {
        let data = try encoder.encode(value)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func isUsableLocalFile(named filename: String) -> Bool {
        let url = baseDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return false }
        return validator(data)
    }
}
