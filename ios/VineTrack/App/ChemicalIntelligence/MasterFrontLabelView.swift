import SwiftUI
import Supabase
import UIKit
import CryptoKit

/// Shared approved-only media projection. Paths are immutable version keys, never signed URLs.
nonisolated struct MasterFrontLabel: Codable, Sendable, Hashable {
    let masterChemicalId: UUID
    let registrationIdentityKey: String
    let documentSha256: String
    let sourceURL: String
    let documentVersion: String?
    let physicalPage: Int
    let pdfPath: String
    let fullImagePath: String
    let thumbnailPath: String

    enum CodingKeys: String, CodingKey {
        case masterChemicalId = "master_chemical_id", registrationIdentityKey = "registration_identity_key"
        case documentSha256 = "document_sha256", sourceURL = "source_url"
        case documentVersion = "document_version", physicalPage = "physical_page"
        case pdfPath = "pdf_path", fullImagePath = "full_image_path", thumbnailPath = "thumbnail_path"
    }

    func belongs(to id: UUID?, identity: String?) -> Bool {
        guard let id, let identity else { return false }
        return masterChemicalId == id && registrationIdentityKey == identity &&
            documentSha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
            thumbnailPath == "\(id.uuidString.lowercased())/\(documentSha256)/thumb-p\(physicalPage).webp" &&
            fullImagePath == "\(id.uuidString.lowercased())/\(documentSha256)/front-p\(physicalPage).png"
    }
}

@MainActor
struct MasterFrontLabelRepository {
    private let provider = SupabaseClientProvider.shared
    private struct Params: Encodable { let p_master_ids: [UUID] }

    func list(_ ids: [UUID]) async throws -> [UUID: MasterFrontLabel] {
        guard provider.isConfigured, !ids.isEmpty,
              let userId = provider.client.auth.currentUser?.id else { return [:] }
        let unique = Array(Set(ids))
        let defaults = UserDefaults.standard
        let prefix = "approvedFrontMedia.v1.\(userId)."
        do {
            var found: [UUID: MasterFrontLabel] = [:]
            for start in stride(from: 0, to: unique.count, by: 100) {
                let rows: [MasterFrontLabel] = try await provider.client
                    .rpc("get_approved_chemical_media", params: Params(p_master_ids: Array(unique[start..<min(start + 100, unique.count)])))
                    .execute().value
                for row in rows where unique.contains(row.masterChemicalId) && row.belongs(to: row.masterChemicalId, identity: row.registrationIdentityKey) {
                    found[row.masterChemicalId] = row
                }
            }
            for id in unique {
                let key = prefix + id.uuidString
                if let row = found[id], let data = try? JSONEncoder().encode(row) { defaults.set(data, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            return found
        } catch {
            var cached: [UUID: MasterFrontLabel] = [:]
            for id in unique {
                if let data = defaults.data(forKey: prefix + id.uuidString),
                   let row = try? JSONDecoder().decode(MasterFrontLabel.self, from: data),
                   row.belongs(to: id, identity: row.registrationIdentityKey) { cached[id] = row }
            }
            return cached
        }
    }

    func image(_ path: String, thumbnail: Bool = false) async throws -> UIImage? {
        guard provider.client.auth.currentUser != nil else { return nil }
        let validThumbnail = path.range(of: "^[a-f0-9-]{36}/[a-f0-9]{64}/thumb-p[1-9][0-9]*\\.webp$", options: .regularExpression) != nil
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("master-label-thumbnails", isDirectory: true)
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = folder?.appendingPathComponent(name)
        if thumbnail && validThumbnail, let file, let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            return image
        }
        let data = try await provider.client.storage.from("master-chemical-media").download(path: path)
        guard let image = UIImage(data: data) else { return nil }
        if thumbnail && validThumbnail && data.count <= 262_144, let folder, let file {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return image
    }
}

@MainActor
private enum MasterFrontLabelCache {
    static let images = NSCache<NSString, UIImage>()
}

struct MasterFrontLabelView: View {
    let media: MasterFrontLabel?
    var expanded: Bool = false
    var interactive: Bool = true
    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    @State private var isShowingFull: Bool = false

    var body: some View {
        Button { isShowingFull = true } label: {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: expanded ? 130 : 48, height: expanded ? 130 : 56)
            .background(Color(.secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(media == nil || !interactive)
        .accessibilityLabel(thumbnail == nil ? "No confirmed front label" : "Confirmed front label thumbnail")
        .task(id: media?.thumbnailPath) {
            thumbnail = nil
            guard let media else { return }
            let key = media.thumbnailPath as NSString
            if let cached = MasterFrontLabelCache.images.object(forKey: key) { thumbnail = cached; return }
            if let image = try? await MasterFrontLabelRepository().image(media.thumbnailPath, thumbnail: true) {
                guard !Task.isCancelled else { return }
                MasterFrontLabelCache.images.setObject(image, forKey: key)
                thumbnail = image
            }
        }
        .sheet(isPresented: $isShowingFull) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 18) {
                        if let fullImage {
                            Image(uiImage: fullImage).resizable().scaledToFit()
                        } else {
                            ContentUnavailableView("Image unavailable", systemImage: "photo", description: Text("The chemical is still available. Try opening its full label."))
                        }
                        Text("Identification aid only. Offline copies reflect the last approved version seen on this device; check the complete label for current directions.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let media, let url = URL(string: media.sourceURL) {
                            Link("View Full Label", destination: url)
                        }
                    }.padding(16)
                }
                .navigationTitle("Front label")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isShowingFull = false } } }
                .task(id: media?.fullImagePath) {
                    fullImage = nil
                    guard let media else { return }
                    fullImage = try? await MasterFrontLabelRepository().image(media.fullImagePath)
                }
            }
        }
    }
}
