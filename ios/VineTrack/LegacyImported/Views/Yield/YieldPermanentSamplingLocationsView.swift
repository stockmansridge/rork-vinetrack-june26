import SwiftUI
import MapKit
import CoreLocation

/// Issue #54 fixed yield sample sites, separate from general Permanent Items.
/// Online-first editing never says "Confirmed" until the server readback does.
struct YieldPermanentSamplingLocationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var locationService
    let vineyardId: UUID
    let paddocks: [Paddock]

    @State private var selectedBlockId: UUID?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var sets: [YieldSamplingSiteSetRow] = []
    @State private var draftSites: [YieldSamplingSiteRow] = []
    @State private var confirmedSites: [YieldSamplingSiteRow] = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var statusText: String?
    @State private var showEditor = false
    @State private var showConfirm = false
    @State private var editingSite: YieldSamplingSiteRow?
    @State private var editCoordinate: CLLocationCoordinate2D?
    @State private var nameText = ""
    @State private var rowText = ""
    @State private var panelText = ""
    @State private var notesText = ""
    private let repository = SupabaseYieldSamplingSitesRepository()

    private var selectedBlock: Paddock? { paddocks.first { $0.id == selectedBlockId } }
    private var draft: YieldSamplingSiteSetRow? { sets.first { $0.status == "draft" } }
    private var confirmed: YieldSamplingSiteSetRow? { sets.first(where: \.isConfirmed) }
    private var displaySites: [YieldSamplingSiteRow] { draft != nil ? draftSites : confirmedSites }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Block", selection: $selectedBlockId) {
                        ForEach(paddocks) { block in
                            Text(block.name).tag(block.id as UUID?)
                        }
                    }
                    Text("Saved locations are assigned to a specific block and can be revisited for future vintages. They are not general Permanent Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Location map") {
                    if let block = selectedBlock {
                        MapReader { proxy in
                            Map(position: $mapPosition) {
                                MapPolygon(coordinates: block.polygonPoints.map(\.coordinate))
                                    .foregroundStyle(Color.purple.opacity(0.16))
                                    .stroke(Color.purple, lineWidth: 2)
                                ForEach(displaySites) { site in
                                    Annotation(site.name, coordinate: CLLocationCoordinate2D(
                                        latitude: site.latitude, longitude: site.longitude
                                    )) {
                                        Button {
                                            if draft != nil { editExisting(site) }
                                        } label: {
                                            Text("\(site.siteNumber)")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                                .frame(width: 32, height: 32)
                                                .background(draft == nil ? Color.green : Color.purple, in: Circle())
                                        }
                                        .disabled(draft == nil || busy)
                                    }
                                }
                            }
                            .mapStyle(.hybrid)
                            .onTapGesture(coordinateSpace: .local) { point in
                                guard draft != nil, !busy,
                                      let coordinate = proxy.convert(point, from: .local) else { return }
                                openNewSite(at: coordinate)
                            }
                        }
                        .frame(height: 320)
                        .clipShape(.rect(cornerRadius: 12))
                        Text(draft != nil ? "Tap inside the purple block to add a site, or tap a draft pin to edit it." :
                             "Confirmed sites are locked. Start a new draft revision to add or move locations.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Choose a mapped block.").foregroundStyle(.secondary)
                    }
                }
                Section("Permanent sampling locations") {
                    if let confirmed {
                        Label("Confirmed version \(confirmed.version) · \(confirmedSites.count) sites", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("No confirmed locations for this block").foregroundStyle(.secondary)
                    }
                    if let draft {
                        Label("Draft version \(draft.version) · \(draftSites.count) sites — not shared as confirmed", systemImage: "pencil.circle")
                            .foregroundStyle(.purple)
                    }
                    if draft == nil {
                        Button {
                            Task { await beginDraft() }
                        } label: {
                            Label(confirmed == nil ? "Create Draft Locations" : "Revise Confirmed Locations",
                                  systemImage: "plus.circle")
                        }
                        .disabled(busy || selectedBlock == nil)
                    } else {
                        Button {
                            locationService.requestPermission()
                            locationService.startUpdating()
                            let capture = locationService.freshLocation()
                            guard case .fresh = capture.quality, let fix = capture.location else {
                                errorText = "A fresh, accurate GPS fix is required. Check location permissions and accuracy, then try again."
                                return
                            }
                            let matching = paddocks.filter {
                                YieldSamplingSiteGeometry.contains(fix.coordinate, polygon: $0.polygonPoints)
                            }
                            guard matching.count == 1 else {
                                errorText = "GPS location does not match one unambiguous mapped block. Select the correct block on the map and place the site manually."
                                return
                            }
                            if matching[0].id != selectedBlockId {
                                selectedBlockId = matching[0].id
                                statusText = "Location belongs to \(matching[0].name). Selected that block; create or open its draft before placing a pin."
                                return
                            }
                            openNewSite(at: fix.coordinate)
                        } label: {
                            Label("Set Location in Field — Place Pin Here", systemImage: "location.fill")
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("yield.sites.placeGPS")
                        ForEach(draftSites.sorted(by: { $0.siteNumber < $1.siteNumber })) { site in
                            HStack {
                                Button {
                                    editExisting(site)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text("\(site.siteNumber). \(site.name)")
                                            .font(.subheadline.weight(.medium))
                                        Text("Row \(site.rowNumber ?? "—") · Panel \(site.panelNumber ?? "—")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await delete(site) }
                                } label: { Image(systemName: "trash") }
                                    .disabled(busy)
                            }
                        }
                        Button {
                            showConfirm = true
                        } label: {
                            Label("Review and Confirm Block Locations", systemImage: "checkmark.seal")
                        }
                        .disabled(busy || draftSites.isEmpty)
                    }
                    if draft == nil {
                        ForEach(confirmedSites.sorted(by: { $0.siteNumber < $1.siteNumber })) { site in
                            HStack {
                                Text("\(site.siteNumber). \(site.name)")
                                Spacer()
                                Text("Row \(site.rowNumber ?? "—")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let statusText {
                    Section { Label(statusText, systemImage: "info.circle").foregroundStyle(.secondary) }
                }
                if let errorText {
                    Section { Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red) }
                }
            }
            .navigationTitle("Permanent Yield Locations")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay { if busy { ProgressView("Checking server…").padding().background(.regularMaterial, in: .rect(cornerRadius: 14)) } }
            .task {
                if selectedBlockId == nil { selectedBlockId = paddocks.first?.id }
                await reload()
            }
            .onChange(of: selectedBlockId) { _, _ in
                sets = []; draftSites = []; confirmedSites = []
                zoomToBlock()
                Task { await reload() }
            }
            .sheet(isPresented: $showEditor) { editorSheet }
            .confirmationDialog("Confirm these permanent locations for this block?", isPresented: $showConfirm,
                titleVisibility: .visible) {
                Button("Confirm Locations") { Task { await confirmDraft() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("After confirmation these coordinates are immutable. Changes require a new revision. Other vineyard devices see only confirmed sets.")
            }
        }
    }

    private var editorSheet: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    if let c = editCoordinate {
                        Text(String(format: "Lat %.7f · Long %.7f", c.latitude, c.longitude))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Site name", text: $nameText)
                    TextField("Row (optional)", text: $rowText)
                    TextField("Panel (optional)", text: $panelText)
                    TextField("Notes (optional)", text: $notesText, axis: .vertical)
                }
                Section {
                    Button("Save Site") { Task { await saveEditor() } }
                        .disabled(busy || nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(editingSite == nil ? "Add Yield Site" : "Edit Draft Site")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showEditor = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func openNewSite(at coordinate: CLLocationCoordinate2D) {
        guard let block = selectedBlock,
              YieldSamplingSiteGeometry.contains(coordinate, polygon: block.polygonPoints) else {
            errorText = "The pin must be inside the selected block boundary."
            return
        }
        let next = (draftSites.map(\.siteNumber).max() ?? 0) + 1
        editCoordinate = coordinate
        editingSite = nil
        nameText = "Sample \(next)"
        rowText = ""
        panelText = ""
        notesText = ""
        showEditor = true
        errorText = nil
    }

    private func editExisting(_ site: YieldSamplingSiteRow) {
        guard draft != nil else { return }
        editingSite = site
        editCoordinate = CLLocationCoordinate2D(latitude: site.latitude, longitude: site.longitude)
        nameText = site.name
        rowText = site.rowNumber ?? ""
        panelText = site.panelNumber ?? ""
        notesText = site.notes ?? ""
        showEditor = true
    }

    private func zoomToBlock() {
        guard let block = selectedBlock, !block.polygonPoints.isEmpty else { return }
        let lat = block.polygonPoints.map(\.latitude)
        let lon = block.polygonPoints.map(\.longitude)
        let centre = CLLocationCoordinate2D(latitude: ((lat.min() ?? 0) + (lat.max() ?? 0)) / 2,
                                            longitude: ((lon.min() ?? 0) + (lon.max() ?? 0)) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.0008, ((lat.max() ?? 0) - (lat.min() ?? 0)) * 1.5),
                                    longitudeDelta: max(0.0008, ((lon.max() ?? 0) - (lon.min() ?? 0)) * 1.5))
        mapPosition = .region(MKCoordinateRegion(center: centre, span: span))
    }

    private func reload() async {
        guard let block = selectedBlock, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let rows = try await repository.listSets(vineyardId: vineyardId, paddockId: block.id)
            let draftRow = rows.first { $0.status == "draft" }
            let confirmedRow = rows.first(where: \.isConfirmed)
            let draftValues = try await draftRow.map { try await repository.listSites($0) } ?? []
            let confirmedValues = try await confirmedRow.map { try await repository.listSites($0) } ?? []
            guard selectedBlockId == block.id else { return }
            sets = rows
            draftSites = draftValues
            confirmedSites = confirmedValues
            errorText = nil
        } catch {
            errorText = "Could not read sampling locations from the server: \(error.localizedDescription)"
        }
    }

    private func beginDraft() async {
        guard let block = selectedBlock, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let draft = try await repository.beginDraft(vineyardId: vineyardId, paddockId: block.id)
            let values = try await repository.listSites(draft)
            guard selectedBlockId == block.id else { return }
            sets = try await repository.listSets(vineyardId: vineyardId, paddockId: block.id)
            draftSites = values
            statusText = "Draft saved on server. Confirm it when all locations have been reviewed."
            errorText = nil
        } catch {
            errorText = "Could not create or read back the draft. Previous confirmed sites are unchanged. \(error.localizedDescription)"
        }
    }

    private func saveEditor() async {
        guard let draft, let block = selectedBlock, let coordinate = editCoordinate, !busy else { return }
        guard YieldSamplingSiteGeometry.contains(coordinate, polygon: block.polygonPoints) else {
            errorText = "The selected location is outside the block."
            showEditor = false
            return
        }
        busy = true
        defer { busy = false }
        let row = YieldSamplingSiteRow(
            id: editingSite?.id ?? UUID(),
            siteSetId: draft.id, vineyardId: vineyardId, paddockId: block.id,
            siteId: editingSite?.siteId ?? UUID(),
            siteNumber: editingSite?.siteNumber ?? ((draftSites.map(\.siteNumber).max() ?? 0) + 1),
            name: nameText.trimmingCharacters(in: .whitespacesAndNewlines),
            rowNumber: rowText.isEmpty ? nil : rowText, panelNumber: panelText.isEmpty ? nil : panelText,
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            notes: notesText.isEmpty ? nil : notesText
        )
        do {
            _ = try await repository.saveSite(row, set: draft)
            let values = try await repository.listSites(draft)
            guard selectedBlockId == block.id else { return }
            draftSites = values
            showEditor = false
            statusText = "Saved draft site to server. Still awaiting block confirmation."
            errorText = nil
        } catch {
            errorText = "Site was not confirmed saved: \(error.localizedDescription)"
        }
    }

    private func delete(_ site: YieldSamplingSiteRow) async {
        guard let draft, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await repository.removeDraftSite(site, set: draft)
            draftSites = try await repository.listSites(draft)
            statusText = "Draft site removed. Historical confirmed locations are unchanged."
            errorText = nil
        } catch {
            errorText = "Could not remove draft site: \(error.localizedDescription)"
        }
    }

    private func confirmDraft() async {
        guard let draft, let block = selectedBlock, !busy else { return }
        guard !draftSites.isEmpty,
              draftSites.allSatisfy({
                YieldSamplingSiteGeometry.contains(CLLocationCoordinate2D(latitude: $0.latitude,
                    longitude: $0.longitude), polygon: block.polygonPoints)
              }) else {
            errorText = "Every site must have a valid position inside this block before confirmation."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let verified = try await repository.confirm(draft)
            sets = try await repository.listSets(vineyardId: vineyardId, paddockId: block.id)
            confirmedSites = try await repository.listSites(verified)
            draftSites = []
            statusText = "Confirmed version \(verified.version) with \(confirmedSites.count) sites. Server readback verified."
            errorText = nil
        } catch {
            errorText = "Confirmation or readback failed. Reload and check the server before retrying. \(error.localizedDescription)"
        }
    }
}
