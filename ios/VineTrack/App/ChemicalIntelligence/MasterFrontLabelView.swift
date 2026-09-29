import SwiftUI
import Supabase
import UIKit

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
        guard provider.isConfigured, !ids.isEmpty else { return [:] }
        let unique = Array(Set(ids))
        var found: [UUID: MasterFrontLabel] = [:]
        for start in stride(from: 0, to: unique.count, by: 100) {
            let rows: [MasterFrontLabel] = try await provider.client
                .rpc("get_approved_chemical_media", params: Params(p_master_ids: Array(unique[start..<min(start + 100, unique.count)])))
                .execute().value
            for row in rows { found[row.masterChemicalId] = row }
        }
        return found
    }

    func image(_ path: String) async throws -> UIImage? {
        let data = try await provider.client.storage.from("master-chemical-media").download(path: path)
        return UIImage(data: data)
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
            if let image = try? await MasterFrontLabelRepository().image(media.thumbnailPath) {
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
                        Text("Identification aid only — check the complete label for directions.")
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
