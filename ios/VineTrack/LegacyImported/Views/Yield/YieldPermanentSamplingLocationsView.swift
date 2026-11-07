import SwiftUI
import MapKit
import CoreLocation

/// Issue #54 fixed yield sample sites, separate from general Permanent Items.
/// Online-first editing never says "Confirmed" until the server readback does.
struct YieldPermanentSamplingLocationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessControl) private var accessControl
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var deleteTarget: YieldSamplingSiteRow?
    @State private var showDeleteConfirm = false
    @State private var fieldLocating = false
    @State private var fieldLocationMessage: String?
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
                blockPickerSection
                draftStartSection
                locationMapSection
                permanentSamplingSection
                statusSections
            }
            .navigationTitle("Permanent Yield Locations")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay { if busy { ProgressView("Checking server…").padding().background(.regularMaterial, in: .rect(cornerRadius: 14)) } }
            .task {
                // No default block: the map shows every block until one is chosen.
                zoomToBlock()
                // Request permission on this map so the native blue location
                // annotation can appear without starting a Trip.
                if locationService.authorizationStatus == .notDetermined {
                    locationService.requestPermission()
                }
                locationService.startUpdating()
                await reload()
            }
            .refreshable { await reload() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reload() } }
            }
            .onChange(of: selectedBlockId) { _, _ in
                deleteTarget = nil; showDeleteConfirm = false
                showEditor = false; statusText = nil
                sets = []; draftSites = []; confirmedSites = []
                zoomToBlock()
                Task { await reload() }
            }
            .sheet(isPresented: $showEditor) { editorSheet }
            .alert("Hard Delete Sampling Location?", isPresented: $showDeleteConfirm) {
                Button("Hard Delete", role: .destructive) {
                    if let target = deleteTarget { Task { await delete(target) } }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("Permanently remove \(deleteTarget?.name ?? "this location") from this block for everyone? Confirmed deletion also removes draft copies. Historical count observations retain their recorded GPS, row and panel. This cannot be undone.")
            }
            .confirmationDialog("Confirm these permanent locations for this block?", isPresented: $showConfirm,
                titleVisibility: .visible) {
                Button("Confirm Locations") { Task { await confirmDraft() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("After confirmation these coordinates are immutable. Changes require a new revision. Other vineyard devices see only confirmed sets.")
            }
        }
    }

    // Keep the large map, site editor, and per-block status in independent
    // ViewBuilder expressions to avoid exponential SwiftUI type-check costs.
    private var blockPickerSection: some View {
                Section {
                    Picker("Block", selection: $selectedBlockId) {
                        Text("Select a block").tag(nil as UUID?)
                        ForEach(paddocks) { block in
                            Text(block.name).tag(block.id as UUID?)
                        }
                    }
                    Text("Saved locations are assigned to a specific block and can be revisited for future vintages. They are not general Permanent Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
    }

    private var locationMapSection: some View {
                Section("Location map") {
                    if !mappedPaddocks.isEmpty {
                        MapReader { proxy in
                            Map(position: $mapPosition) {
                                UserAnnotation()
                                ForEach(mappedPaddocks) { block in
                                    let isSelected = block.id == selectedBlockId
                                    MapPolygon(coordinates: block.polygonPoints.map(\.coordinate))
                                        .foregroundStyle(isSelected ? Color.purple.opacity(0.16) : Color.yellow.opacity(0.08))
                                        .stroke(isSelected ? Color.purple : Color.yellow, lineWidth: isSelected ? 3 : 1.5)
                                }
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
                            .mapControls {
                                MapUserLocationButton()
                                MapCompass()
                            }
                            .onTapGesture(coordinateSpace: .local) { point in
                                guard !busy, let coordinate = proxy.convert(point, from: .local) else { return }
                                handleMapTap(at: coordinate)
                            }
                        }
                        .frame(height: 320)
                        .clipShape(.rect(cornerRadius: 12))
                        Text(mapHint).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No mapped blocks yet.").foregroundStyle(.secondary)
                    }
                }
    }

    private var mappedPaddocks: [Paddock] { paddocks.filter { $0.polygonPoints.count >= 3 } }

    private var draftButtonTitle: String {
        confirmed == nil ? "Create Draft Locations" : "Revise Confirmed Locations"
    }

    private var mapHint: String {
        if selectedBlock == nil { return "Select a block above (or tap one on the map) to manage its sampling sites." }
        if draft != nil { return "Tap inside the purple block to add a site, or tap a draft pin to edit it." }
        if confirmed != nil { return "Confirmed sites are locked. Press Revise Confirmed Locations above to make changes." }
        return "Press Create Draft Locations above, then tap inside the block."
    }

    /// Step 1 sits at the top so it is obvious a draft is needed before pins.
    @ViewBuilder
    private var draftStartSection: some View {
        if selectedBlock != nil, draft == nil, !busy {
            Section {
                Button {
                    Task { await beginDraft() }
                } label: {
                    Label(draftButtonTitle, systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                .disabled(accessControl?.canEditRecords != true)
            } footer: {
                Text("Create a draft first, then tap inside the block on the map to drop sampling pins.")
            }
        }
    }

    private func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        guard selectedBlock != nil else {
            if let hit = mappedPaddocks.first(where: {
                YieldSamplingSiteGeometry.contains(coordinate, polygon: $0.polygonPoints)
            }) {
                selectedBlockId = hit.id
            } else {
                statusText = "Select a block from the picker first."
            }
            return
        }
        guard draft != nil else {
            statusText = "Press \(draftButtonTitle) at the top first."
            return
        }
        openNewSite(at: coordinate)
    }

    private var permanentSamplingSection: some View {
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
                    if draft != nil {
                        Button {
                            Task { await captureFieldLocation() }
                        } label: {
                            Label(fieldLocating ? "Locating…" : "Set Location in Field — Place Pin Here",
                                  systemImage: "location.fill")
                        }
                        .disabled(busy || fieldLocating)
                        .accessibilityIdentifier("yield.sites.placeGPS")
                        if let fieldLocationMessage {
                            Text(fieldLocationMessage).font(.caption)
                                .foregroundStyle(fieldLocating ? Color.secondary : Color.red)
                        }
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
                                    deleteTarget = site; showDeleteConfirm = true
                                } label: { Image(systemName: "trash") }
                                    .disabled(busy || accessControl?.canEditRecords != true)
                                    .accessibilityLabel("Hard Delete Draft \(site.name)")
                            }
                        }
                        Button {
                            showConfirm = true
                        } label: {
                            Label("Review and Confirm Block Locations", systemImage: "checkmark.seal")
                        }
                        .disabled(busy || draftSites.isEmpty || accessControl?.canDelete != true)
                    }
                    if confirmed != nil {
                        Text("Confirmed locations").font(.headline)
                        ForEach(confirmedSites.sorted(by: { $0.siteNumber < $1.siteNumber })) { site in
                            HStack {
                                Text("\(site.siteNumber). \(site.name)")
                                Spacer()
                                Text("Row \(site.rowNumber ?? "—")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if accessControl?.canDelete == true {
                                    Button(role: .destructive) {
                                        deleteTarget = site; showDeleteConfirm = true
                                    } label: { Image(systemName: "trash") }
                                        .disabled(busy)
                                        .accessibilityLabel("Hard Delete Confirmed \(site.name)")
                                }
                            }
                        }
                    }
                }
    }

    @ViewBuilder
    private var statusSections: some View {
                if let statusText {
                    Section { Label(statusText, systemImage: "info.circle").foregroundStyle(.secondary) }
                }
                if let errorText {
                    Section { Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red) }
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
                    TextField(editingSite?.name ?? "Sample \((draftSites.map(\.siteNumber).max() ?? 0) + 1)",
                              text: $nameText)
                    Text("Site name is optional").font(.caption2).foregroundStyle(.secondary)
                    TextField("Row (optional)", text: $rowText)
                    TextField("Panel (optional)", text: $panelText)
                    TextField("Notes (optional)", text: $notesText, axis: .vertical)
                }
                Section {
                    Button("Save Site") { Task { await saveEditor() } }
                        .disabled(busy)
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

    /// Permission prompts are asynchronous. Wait for a fresh authorised fix
    /// rather than trying the cache immediately after asking permission.
    private func captureFieldLocation() async {
        guard draft != nil, let selectedBlock else {
            fieldLocationMessage = "Create or open a block draft before placing a field pin."
            return
        }
        guard !fieldLocating else { return }
        fieldLocating = true
        defer { fieldLocating = false }
        fieldLocationMessage = "Getting a fresh, accurate GPS location…"
        locationService.requestPermission()
        locationService.startUpdating()
        var accepted: CLLocation?
        for _ in 0..<30 {
            if Task.isCancelled { return }
            switch locationService.authorizationStatus {
            case .denied, .restricted:
                fieldLocationMessage = "Location access is denied. Enable Precise Location in iPhone Settings, or place the pin on the map."
                return
            default:
                break
            }
            let captured = locationService.freshLocation()
            if case .fresh = captured.quality, let fix = captured.location {
                accepted = fix
                break
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        guard let accepted else {
            fieldLocationMessage = "No fresh accurate GPS fix yet. Check Location Services and Precise Location, then try again."
            return
        }
        let matched = paddocks.filter {
            YieldSamplingSiteGeometry.contains(accepted.coordinate, polygon: $0.polygonPoints)
        }
        guard matched.count == 1 else {
            fieldLocationMessage = "The GPS position must match one mapped block. Use the map or move within the block."
            return
        }
        guard matched[0].id == selectedBlock.id else {
            selectedBlockId = matched[0].id
            fieldLocationMessage = "GPS matched \(matched[0].name). Open that block’s draft and press Place Pin Here again."
            return
        }
        fieldLocationMessage = nil
        openNewSite(at: accepted.coordinate)
    }

    private func openNewSite(at coordinate: CLLocationCoordinate2D) {
        guard let block = selectedBlock,
              YieldSamplingSiteGeometry.contains(coordinate, polygon: block.polygonPoints) else {
            errorText = "The pin must be inside the selected block boundary."
            return
        }
        editCoordinate = coordinate
        editingSite = nil
        nameText = "" // Optional; blank saves as "Sample N".
        rowText = ""
        panelText = ""
        notesText = ""
        showEditor = true
        errorText = nil
    }

    private func editExisting(_ site: YieldSamplingSiteRow) {
        guard draft != nil, accessControl?.canEditRecords == true else { return }
        editingSite = site
        editCoordinate = CLLocationCoordinate2D(latitude: site.latitude, longitude: site.longitude)
        nameText = site.name
        rowText = site.rowNumber ?? ""
        panelText = site.panelNumber ?? ""
        notesText = site.notes ?? ""
        showEditor = true
    }

    private func zoomToBlock() {
        let points = selectedBlock?.polygonPoints ?? mappedPaddocks.flatMap(\.polygonPoints)
        guard !points.isEmpty else { return }
        let lat = points.map(\.latitude)
        let lon = points.map(\.longitude)
        let centre = CLLocationCoordinate2D(latitude: ((lat.min() ?? 0) + (lat.max() ?? 0)) / 2,
                                            longitude: ((lon.min() ?? 0) + (lon.max() ?? 0)) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.0008, ((lat.max() ?? 0) - (lat.min() ?? 0)) * 1.5),
                                    longitudeDelta: max(0.0008, ((lon.max() ?? 0) - (lon.min() ?? 0)) * 1.5))
        mapPosition = .region(MKCoordinateRegion(center: centre, span: span))
    }

    private func reload() async {
        guard let block = selectedBlock, !busy else { return }
        busy = true
        defer {
            busy = false
            // A block switch during a network wait must schedule its own read.
            if selectedBlockId != block.id { Task { await reload() } }
        }
        do {
            let rows = try await repository.listSets(vineyardId: vineyardId, paddockId: block.id)
            let draftRow = rows.first { $0.status == "draft" }
            let confirmedRow = rows.first(where: \.isConfirmed)
            let draftValues: [YieldSamplingSiteRow]
            if let draftRow { draftValues = try await repository.listSites(draftRow) } else { draftValues = [] }
            let confirmedValues: [YieldSamplingSiteRow]
            if let confirmedRow { confirmedValues = try await repository.listSites(confirmedRow) } else { confirmedValues = [] }
            guard selectedBlockId == block.id else { return }
            sets = rows
            draftSites = draftValues
            confirmedSites = confirmedValues
            errorText = nil
        } catch {
            guard selectedBlockId == block.id else { return }
            errorText = "Could not read sampling locations from the server: \(error.localizedDescription)"
        }
    }

    private func beginDraft() async {
        guard let block = selectedBlock, !busy, accessControl?.canEditRecords == true else { return }
        busy = true
        defer {
            busy = false
            if selectedBlockId != block.id { Task { await reload() } }
        }
        do {
            let draft = try await repository.beginDraft(vineyardId: vineyardId, paddockId: block.id)
            let values = try await repository.listSites(draft)
            let rows = try await repository.listSets(vineyardId: vineyardId, paddockId: block.id)
            guard selectedBlockId == block.id else { return }
            sets = rows
            draftSites = values
            statusText = "Draft saved on server. Confirm it when all locations have been reviewed."
            errorText = nil
        } catch {
            guard selectedBlockId == block.id else { return }
            errorText = "Could not create or read back the draft. Previous confirmed sites are unchanged. \(error.localizedDescription)"
        }
    }

    private func saveEditor() async {
        guard let draft, let block = selectedBlock, let coordinate = editCoordinate, !busy,
              accessControl?.canEditRecords == true else { return }
        guard YieldSamplingSiteGeometry.contains(coordinate, polygon: block.polygonPoints) else {
            errorText = "The selected location is outside the block."
            showEditor = false
            return
        }
        busy = true
        defer {
            busy = false
            if selectedBlockId != block.id { Task { await reload() } }
        }
        let siteNumber = editingSite?.siteNumber ?? ((draftSites.map(\.siteNumber).max() ?? 0) + 1)
        let typedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = YieldSamplingSiteRow(
            id: editingSite?.id ?? UUID(),
            siteSetId: draft.id, vineyardId: vineyardId, paddockId: block.id,
            siteId: editingSite?.siteId ?? UUID(),
            siteNumber: siteNumber,
            name: typedName.isEmpty ? (editingSite?.name ?? "Sample \(siteNumber)") : typedName,
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
            guard selectedBlockId == block.id else { return }
            errorText = "Site was not confirmed saved: \(error.localizedDescription)"
            // Re-read so a save that did land is shown rather than duplicated on retry.
            Task { await reload() }
        }
    }

    private func delete(_ site: YieldSamplingSiteRow) async {
        guard !busy, site.vineyardId == vineyardId, site.paddockId == selectedBlockId,
              let set = sets.first(where: { $0.id == site.siteSetId }),
              (set.isConfirmed ? accessControl?.canDelete : accessControl?.canEditRecords) == true else { return }
        busy = true
        defer {
            busy = false; deleteTarget = nil
            if selectedBlockId != site.paddockId { Task { await reload() } }
        }
        do {
            try await repository.hardDeleteSite(site, set: set)
            // Refresh both collections: confirmed deletion removes draft copies.
            let rows = try await repository.listSets(vineyardId: vineyardId, paddockId: site.paddockId)
            let pending = rows.first { $0.status == "draft" }
            let ready = rows.first(where: \.isConfirmed)
            let pendingValues: [YieldSamplingSiteRow]
            if let pending { pendingValues = try await repository.listSites(pending) } else { pendingValues = [] }
            let readyValues: [YieldSamplingSiteRow]
            if let ready { readyValues = try await repository.listSites(ready) } else { readyValues = [] }
            guard selectedBlockId == site.paddockId else { return }
            sets = rows; draftSites = pendingValues; confirmedSites = readyValues
            statusText = "Hard Delete verified by server receipt and absence. Historical observations are unchanged."
            errorText = nil
        } catch {
            guard selectedBlockId == site.paddockId else { return }
            errorText = "Hard Delete not confirmed. Reload and retry: \(error.localizedDescription)"
        }
    }

    private func confirmDraft() async {
        guard let draft, let block = selectedBlock, !busy, accessControl?.canDelete == true else { return }
        guard !draftSites.isEmpty,
              draftSites.allSatisfy({
                YieldSamplingSiteGeometry.contains(CLLocationCoordinate2D(latitude: $0.latitude,
                    longitude: $0.longitude), polygon: block.polygonPoints)
              }) else {
            errorText = "Every site must have a valid position inside this block before confirmation."
            return
        }
        busy = true
        defer {
            busy = false
            if selectedBlockId != block.id { Task { await reload() } }
        }
        do {
            let verified = try await repository.confirm(draft)
            let rows = try await repository.listSets(vineyardId: vineyardId, paddockId: block.id)
            let values = try await repository.listSites(verified)
            guard selectedBlockId == block.id else { return }
            sets = rows
            confirmedSites = values
            draftSites = []
            statusText = "Confirmed version \(verified.version) with \(confirmedSites.count) sites. Server readback verified."
            errorText = nil
        } catch {
            guard selectedBlockId == block.id else { return }
            errorText = "Confirmation or readback failed. Reload and check the server before retrying. \(error.localizedDescription)"
        }
    }
}
