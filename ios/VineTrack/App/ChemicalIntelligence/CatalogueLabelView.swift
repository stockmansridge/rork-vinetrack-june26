import SwiftUI

/// Private storage download; no public image URL is created.
struct CatalogueLabelView: View {
    let path: String?
    var labelURL: String? = nil
    @State private var image: UIImage?
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button {
            if let labelURL, let url = URL(string: labelURL), ["https", "http"].contains(url.scheme ?? "") { openURL(url) }
        } label: {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "flask").font(.title).foregroundStyle(.secondary) }
            }
            .frame(width: 64, height: 82)
            .background(.quaternary, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open product label")
        .task(id: path) {
            image = nil
            guard let path, !path.isEmpty else { return }
            if let data = try? await CatalogueRepository().media(path) { image = UIImage(data: data) }
        }
    }
}
