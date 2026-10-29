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
    @State private var showingCamera = false
    @State private var isAdding = false
    @State private var selectedResultVisible = false
    private var country: String { ChemicalRegistration.normaliseCountry(store.selectedVineyard?.country ?? "") }
    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
            List {
                Section {
                    TextField("Product name or registration number", text: $model.query)
                        .submitLabel(.search).onSubmit { Task { await model.search(country: country) } }
                    Button { Task { await model.search(country: country) } } label: {
                        Label("Search Chemicals", systemImage: "magnifyingglass").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.query.isEmpty || model.context != nil)
                    Button { showingCamera = true } label: {
                        Label("Take Photo of Label", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.busy || model.context != nil)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose Existing Photo", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
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
                            Button {
                                selectedResultVisible = true
                                Task {
                                    await model.select(match)
                                    if model.result != nil {
                                        withAnimation(.easeInOut(duration: 0.2)) { reader.scrollTo("catalogue.selected.review", anchor: .top) }
                                    } else { selectedResultVisible = false }
                                }
                            } label: {
                                HStack {
                                    CatalogueLabelView(path: match.text("front_label_image_path"), labelURL: match.text("manufacturer_label_url"))
                                    VStack(alignment: .leading) {
                                        Text(match.text("product_name") ?? "Product")
                                        Text(CatalogueWire.compactManufacturer(match.text("manufacturer") ?? "")).font(.caption).foregroundStyle(.secondary)
                                        Label("VineTrack catalogue", systemImage: "checkmark.seal.fill")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Color(red: 0.38, green: 0.56, blue: 0.12))
                                    }
                                }
                            }.buttonStyle(.plain).disabled(model.context != nil || model.busy)
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
                        Button {
                            guard let vineyard = store.selectedVineyardId, !isAdding else { return }
                            isAdding = true
                            Task {
                                defer { isAdding = false }
                                do { let saved = try await model.add(vineyard: vineyard, store: store); onSaved(saved); dismiss() }
                                catch { model.error = "Unable to add this result. Check permissions and try again." }
                            }
                        } label: {
                            Text(isAdding ? "Adding to Vineyard…" : "Add to Vineyard")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || isAdding)
                    }
                    .id("catalogue.selected.review")
                }
                if model.busy { ProgressView() }
                if selectedResultVisible && model.busy { Text("Opening selected product…").foregroundStyle(.secondary) }
                if let error = model.error { Text(error).foregroundStyle(.secondary) }
            }
            .navigationTitle("Chemical Search")
            .sheet(isPresented: $showingCamera) {
                CameraImagePicker { data in
                    guard let data, let vineyard = store.selectedVineyardId else { return }
                    Task { await model.discover(vineyard: vineyard, country: country, photo: data) }
                }
            }
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
