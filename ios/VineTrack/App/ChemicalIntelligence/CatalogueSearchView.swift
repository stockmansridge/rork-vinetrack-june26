import SwiftUI
import PhotosUI

struct CatalogueSearchView: View {
    var prefillQuery: String = ""
    var onOpenExisting: (SavedChemical) -> Void = { _ in }
    var onSaved: (SavedChemical) -> Void = { _ in }
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model: CatalogueSearchModel = CatalogueSearchModel()
    @State private var photo: PhotosPickerItem?
    private var country: String { ChemicalRegistration.normaliseCountry(store.selectedVineyard?.country ?? "") }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Product name or registration number", text: $model.query)
                        .submitLabel(.search).onSubmit { Task { await model.search(country: country) } }
                    Button("Search") { Task { await model.search(country: country) } }.disabled(model.busy || model.query.isEmpty || model.context != nil)
                    PhotosPicker(selection: $photo, matching: .images) { Label("Search by Photo", systemImage: "camera") }
                        .disabled(model.busy || model.context != nil)
                }
                if let context = model.context {
                    Section("Finding your product") {
                        ProgressView(value: (model.job?.number("progress_percent") ?? 0) / 100)
                        Text(model.job?.text("user_message") ?? "Finding product information…")
                        Button("Resume discovery") { model.poll() }
                        Text("You can close this screen. This search is saved.").font(.caption)
                        Text(context.query).font(.caption)
                    }
                }
                if !model.matches.isEmpty {
                    Section("Matches in the VineTrack catalogue") {
                        ForEach(model.matches) { match in
                            Button { Task { await model.select(match) } } label: {
                                HStack {
                                    CatalogueLabelView(path: match.text("front_label_image_path"), labelURL: match.text("manufacturer_label_url"))
                                    VStack(alignment: .leading) {
                                        Text(match.text("product_name") ?? "Product")
                                        Text(CatalogueWire.compactManufacturer(match.text("manufacturer") ?? "")).font(.caption).foregroundStyle(.secondary)
                                        Text("VineTrack catalogue").font(.caption)
                                    }
                                }
                            }.buttonStyle(.plain).disabled(model.context != nil)
                        }
                    }
                    Section {
                        Text("Can't find the right product?").font(.caption)
                        Button("Find a different product") { discover() }.font(.subheadline).disabled(model.busy || model.context != nil)
                    }
                } else if model.searched {
                    Section {
                        Text("We haven't seen this product before")
                        Button("Find this product") { discover() }.disabled(model.busy || model.context != nil)
                    }
                }
                if let result = model.result {
                    Section(result.badge) {
                        HStack {
                            CatalogueLabelView(path: result.text("front_label_image_path"), labelURL: result.text("manufacturer_label_url"))
                            VStack(alignment: .leading) {
                                Text(result.text("product_name") ?? "Product").font(.headline)
                                Text(result.text("manufacturer") ?? "")
                                Text(result.groupText)
                                Text(result.targets.joined(separator: " · "))
                            }
                        }
                        rates(result, key: "per_hectare", title: "Per hectare")
                        rates(result, key: "per_100_litres", title: "Per 100 L")
                        Button("Add to Vineyard") {
                            guard let vineyard = store.selectedVineyardId else { return }
                            Task {
                                do { let saved = try await model.add(vineyard: vineyard, store: store); onSaved(saved); dismiss() }
                                catch { model.error = "Unable to add this result. Check permissions and try again." }
                            }
                        }.disabled(model.busy)
                    }
                }
                if model.busy { ProgressView() }
                if let error = model.error { Text(error).foregroundStyle(.secondary) }
            }
            .navigationTitle("Chemical Search")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                model.query = prefillQuery
                if let vineyard = store.selectedVineyardId { await model.restore(vineyard: vineyard) }
            }
            .onChange(of: photo) { _, item in
                Task {
                    guard let item else { return }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85),
                          let vineyard = store.selectedVineyardId else { model.error = "Unable to read this photo. Please choose another image."; return }
                    await model.discover(vineyard: vineyard, country: country, photo: jpeg)
                }
            }
        }
    }
    private func discover() { if let vineyard = store.selectedVineyardId { Task { await model.discover(vineyard: vineyard, country: country) } } }
    @ViewBuilder private func rates(_ result: CatalogueWire, key: String, title: String) -> some View {
        let rows = result.rateRows(key)
        if !rows.isEmpty {
            Text(title).font(.subheadline.bold())
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rate in Text(rate.rateText).font(.caption) }
        }
    }
}
