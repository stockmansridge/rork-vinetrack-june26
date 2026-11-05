import Foundation
import SwiftUI
import Supabase
import MapKit
import CoreLocation
import PhotosUI
import UIKit

// Issue #53. Isolated System Admin pilot: not a mode of Pins, and never a Trip-sync job.
enum PermanentItemsPilotPolicy {
    static let flag = "permanent_items_admin_preview"
    static let types: [(id: String, label: String)] = [
        ("irrigation_valve", "Irrigation Valve"), ("flush_valve", "Flush Valve"),
        ("pump", "Pump"), ("filter", "Filter"), ("tank", "Tank"),
        ("gate", "Gate"), ("water_point", "Water Point"), ("other", "Other")
    ]
    static func valid(name: String, type: String, latitude: Double, longitude: Double) -> Bool {
        (1...100).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
            && types.contains(where: { $0.id == type })
            && latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    static func label(_ type: String) -> String {
        types.first(where: { $0.id == type })?.label ?? "Other"
    }
}

private struct PermanentItemPilotRow: Decodable, Identifiable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let name: String
    let itemType: String
    let latitude: Double
    let longitude: Double
    let notes: String?
    let photoPath: String?
    let serverRevision: Int64
    let archivedAt: String?
    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude, notes
        case vineyardId = "vineyard_id", paddockId = "paddock_id",
             itemType = "item_type", photoPath = "photo_path",
             serverRevision = "server_revision", archivedAt = "archived_at"
    }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct PermanentItemPilotDraft {
    var name = ""
    var itemType = "irrigation_valve"
    var latitude: Double = .nan
    var longitude: Double = .nan
    var paddockId: UUID?
    var notes: String?
    init(_ existing: PermanentItemPilotRow? = nil) {
        if let existing {
            name = existing.name; itemType = existing.itemType
            latitude = existing.latitude; longitude = existing.longitude
            paddockId = existing.paddockId; notes = existing.notes
        }
    }
}

private struct PermanentItemPilotOperation: Codable, Sendable {
    let p_operation_id: UUID
    let p_action: String
    let p_item_id: UUID
    let p_vineyard_id: UUID
    let p_expected_revision: Int64?
    let p_name: String?
    let p_item_type: String?
    let p_latitude: Double?
    let p_longitude: Double?
    let p_paddock_id: UUID?
    let p_notes: String?
    let p_photo_path: String?

    init(action: String, vineyardId: UUID, item: PermanentItemPilotRow?,
         draft: PermanentItemPilotDraft, photoPath: String? = nil) {
        p_operation_id = UUID()
        p_action = action
        p_item_id = item?.id ?? UUID()
        p_vineyard_id = vineyardId
        p_expected_revision = item?.serverRevision
        p_name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p_item_type = draft.itemType
        p_latitude = draft.latitude
        p_longitude = draft.longitude
        p_paddock_id = draft.paddockId
        p_notes = draft.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        p_photo_path = photoPath ?? item?.photoPath
    }
}

private struct PermanentItemPilotReceipt: Decodable {
    let itemId: UUID
    let serverRevision: Int64
    let operationId: UUID
    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", serverRevision = "server_revision",
             operationId = "operation_id"
    }
}

private enum PermanentItemsPilotError: LocalizedError {
    case unavailable, invalid, pending, wrongScope, receipt, photo
    var errorDescription: String? {
        switch self {
        case .unavailable: "System Admin access, feature flag or vineyard membership is unavailable."
        case .invalid: "Enter a name, valid category and a confirmed map or GPS location."
        case .pending: "A previous save is pending. Retry it before making another change."
        case .wrongScope: "Account or vineyard changed. This action was not sent."
        case .receipt: "Server write could not be verified. Retry the same saved operation."
        case .photo: "Photo must be a JPEG smaller than 5 MiB."
        }
    }
}

private struct PermanentItemPilotRepository {
    private let client = SupabaseClientProvider.shared.client

    func list(vineyardId: UUID) async throws -> [PermanentItemPilotRow] {
        try await client.from("permanent_items")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString.lowercased())
            .execute().value
    }

    func apply(_ op: PermanentItemPilotOperation) async throws -> PermanentItemPilotRow {
        let receipts: [PermanentItemPilotReceipt] = try await client
            .rpc("apply_permanent_item_v1", params: op).execute().value
        guard receipts.count == 1,
              let receipt = receipts.first,
              receipt.itemId == op.p_item_id,
              receipt.operationId == op.p_operation_id else {
            throw PermanentItemsPilotError.receipt
        }
        let verified: [PermanentItemPilotRow] = try await client.from("permanent_items")
            .select()
            .eq("vineyard_id", value: op.p_vineyard_id.uuidString.lowercased())
            .eq("id", value: op.p_item_id.uuidString.lowercased())
            .eq("server_revision", value: String(receipt.serverRevision))
            .execute().value
        guard let row = verified.first, verified.count == 1,
              row.id == op.p_item_id,
              row.vineyardId == op.p_vineyard_id,
              row.serverRevision == receipt.serverRevision,
              (op.p_action == "archive") == (row.archivedAt != nil),
              op.p_action == "archive" ||
              (row.name == op.p_name && row.itemType == op.p_item_type &&
               row.latitude == op.p_latitude && row.longitude == op.p_longitude &&
               row.paddockId == op.p_paddock_id && row.notes == op.p_notes &&
               row.photoPath == op.p_photo_path) else {
            throw PermanentItemsPilotError.receipt
        }
        return row
    }

    func uploadPhoto(_ data: Data, vineyardId: UUID, itemId: UUID) async throws -> String {
        guard !data.isEmpty && data.count <= 5 * 1024 * 1024 else {
            throw PermanentItemsPilotError.photo
        }
        let path = "\(vineyardId.uuidString.lowercased())/\(itemId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        _ = try await client.storage.from("permanent-item-photos")
            .upload(path, data: data, options: FileOptions(contentType: "image/jpeg", upsert: false))
        return path
    }
}

/// Pilot writes are isolated from the app's Pins / Trip / Spray journals.
/// A single retryable operation is stored under the exact signed-in account+vineyard.
/// A server timeout NEVER generates a second UUID; no "Synced" before readback.
struct PermanentItemsAdminPilotView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(SystemAdminService.self) private var systemAdmin
    @Environment(BackendAccessControl.self) private var access
    @State private var rows: [PermanentItemPilotRow] = []
    @State private var search = ""
    @State private var showMarkers = true
    @State private var showMap = true
    @State private var showEditor = false
    @State private var editing: PermanentItemPilotRow?
    @State private var pending: PermanentItemPilotOperation?
    @State private var busy = false
    @State private var message: String?
    @State private var archiveTarget: PermanentItemPilotRow?
    @State private var camera: MapCameraPosition = .automatic
    private let repository = PermanentItemPilotRepository()

    private var account: UUID? { auth.userId }
    private var vineyard: UUID? { store.selectedVineyardId }
    private var scope: String {
        "\(account?.uuidString ?? "signed-out")|\(vineyard?.uuidString ?? "none")|\(auth.completedSignOutSequence)"
    }
    private var permitted: Bool {
        auth.isSignedIn && account != nil && vineyard != nil &&
        systemAdmin.isSystemAdmin && systemAdmin.isEnabled(PermanentItemsPilotPolicy.flag) &&
        !access.isLoading && access.currentRole != nil &&
        access.loadedUserId == account && access.loadedVineyardId == vineyard
    }
    private var pendingKey: String {
        "permanent-item-op-v1|\(account?.uuidString ?? "none")|\(vineyard?.uuidString ?? "none")"
    }
    private var visible: [PermanentItemPilotRow] {
        rows.filter { $0.archivedAt == nil &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) ||
             PermanentItemsPilotPolicy.label($0.itemType).localizedCaseInsensitiveContains(search)) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if !permitted {
                ContentUnavailableView("System Admin pilot unavailable",
                                       systemImage: "lock.shield",
                                       description: Text("Requires an active System Admin account, this vineyard's membership and the Permanent Items preview switch."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Permanent property fixtures are separate from Repairs and Observations.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let pending {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Saved on device — not yet confirmed by server.")
                                    .font(.subheadline.bold())
                                Text("Pending \(pending.p_action) for \(pending.p_item_id.uuidString.prefix(8)).")
                                    .font(.caption.monospaced())
                                Button("Retry same operation") { Task { await retryPending() } }
                                    .disabled(busy)
                            }.padding().background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                        }
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button {
                            editing = nil
                            showEditor = true
                        } label: {
                            Label("New Permanent Item", systemImage: "mappin.and.ellipse")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || pending != nil)
                        HStack {
                            Toggle("Map layer", isOn: $showMarkers)
                            Spacer()
                            Toggle("Show map", isOn: $showMap)
                        }.font(.subheadline)
                        if showMap {
                            Map(position: $camera) {
                                if showMarkers {
                                    ForEach(visible) { item in
                                        Annotation(item.name, coordinate: item.coordinate) {
                                            Button {
                                                editing = item
                                                showEditor = true
                                            } label: {
                                                Image(systemName: "mappin.circle.fill")
                                                    .font(.title2).foregroundStyle(.indigo)
                                                    .padding(3).background(.white, in: .circle)
                                            }.accessibilityLabel("Permanent Item: \(item.name)")
                                        }
                                    }
                                }
                            }
                            .mapStyle(.hybrid)
                            .frame(height: 270)
                            .clipShape(.rect(cornerRadius: 12))
                        }
                        TextField("Search name or type", text: $search)
                            .textFieldStyle(.roundedBorder)
                        ForEach(visible) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.name).font(.headline)
                                Text("\(PermanentItemsPilotPolicy.label(item.itemType)) · revision \(item.serverRevision)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.6f, %.6f", item.latitude, item.longitude))
                                    .font(.caption.monospaced())
                                HStack {
                                    Button("View on Map") {
                                        showMap = true; showMarkers = true
                                        camera = .region(MKCoordinateRegion(
                                            center: item.coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)))
                                    }
                                    Button("Edit / Move") {
                                        editing = item; showEditor = true
                                    }.disabled(busy || pending != nil)
                                    Button("Archive", role: .destructive) {
                                        archiveTarget = item
                                    }.disabled(busy || pending != nil)
                                }.buttonStyle(.bordered)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
                        }
                        if rows.isEmpty && !busy {
                            Text("No Permanent Items yet.").foregroundStyle(.secondary)
                        }
                    }.padding()
                }
            }
        }
        .navigationTitle("Permanent Items")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.disabled(!permitted || busy)
            }
        }
        .task(id: scope) {
            rows = []; pending = nil; editing = nil; showEditor = false
            await systemAdmin.refresh()
            await load()
        }
        .onChange(of: scope) { _, _ in
            rows = []; pending = nil; editing = nil; showEditor = false
        }
        .sheet(isPresented: $showEditor) {
            if let vineyard {
                NavigationStack {
                    PermanentItemPilotEditor(
                        existing: editing, paddocks: store.paddocks,
                        onSave: { draft, image in try await save(draft, image: image) }
                    )
                }.id("\(scope)|\(editing?.id.uuidString ?? "new")")
            }
        }
        .confirmationDialog("Archive this Permanent Item?",
                            isPresented: Binding(
                                get: { archiveTarget != nil },
                                set: { if !$0 { archiveTarget = nil } }
                            ), titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                if let target = archiveTarget {
                    Task { await archive(target) }
                }
                archiveTarget = nil
            }
            Button("Cancel", role: .cancel) { archiveTarget = nil }
        } message: {
            Text("The fixture will disappear from the active map. Its history will remain.")
        }
    }

    private func isCurrent(_ captured: String) -> Bool { captured == scope && permitted }

    private func load() async {
        guard permitted, let vineyard else { return }
        let captured = scope
        pending = UserDefaults.standard.data(forKey: pendingKey)
            .flatMap { try? JSONDecoder().decode(PermanentItemPilotOperation.self, from: $0) }
        do {
            let result = try await repository.list(vineyardId: vineyard)
            guard isCurrent(captured) else { return }
            rows = result
        } catch {
            if isCurrent(captured) { message = "Couldn't load Permanent Items: \(error.localizedDescription)" }
        }
    }

    private func applyDurably(_ operation: PermanentItemPilotOperation) async throws -> PermanentItemPilotRow {
        guard permitted, operation.p_vineyard_id == vineyard, let account else {
            throw PermanentItemsPilotError.wrongScope
        }
        let captured = scope
        let key = pendingKey
        if let previous = pending, previous.p_operation_id != operation.p_operation_id {
            throw PermanentItemsPilotError.pending
        }
        if pending == nil {
            guard let data = try? JSONEncoder().encode(operation) else { throw PermanentItemsPilotError.invalid }
            UserDefaults.standard.set(data, forKey: key)
            pending = operation
        }
        let result = try await repository.apply(operation)
        guard isCurrent(captured), auth.userId == account else {
            throw PermanentItemsPilotError.wrongScope
        }
        UserDefaults.standard.removeObject(forKey: key)
        pending = nil
        rows.removeAll { $0.id == result.id }
        rows.append(result)
        message = "Synced · revision \(result.serverRevision)"
        return result
    }

    private func retryPending() async {
        guard let pending, !busy else { return }
        busy = true; defer { busy = false }
        do { _ = try await applyDurably(pending) }
        catch { message = error.localizedDescription }
    }

    private func save(_ draft: PermanentItemPilotDraft, image: Data?) async throws {
        guard permitted, let vineyard else { throw PermanentItemsPilotError.unavailable }
        guard PermanentItemsPilotPolicy.valid(name: draft.name, type: draft.itemType,
                                               latitude: draft.latitude, longitude: draft.longitude) else {
            throw PermanentItemsPilotError.invalid
        }
        guard pending == nil, !busy else { throw PermanentItemsPilotError.pending }
        let old = editing
        let capturedScope = scope
        busy = true
        defer { busy = false }
        let op = PermanentItemPilotOperation(action: old == nil ? "create" : "update",
                                              vineyardId: vineyard, item: old, draft: draft)
        var saved = try await applyDurably(op)
        // A photo-upload failure must not make the already-created row appear unsaved.
        editing = saved
        if let image {
            guard isCurrent(capturedScope) else { throw PermanentItemsPilotError.wrongScope }
            let path = try await repository.uploadPhoto(image, vineyardId: vineyard, itemId: saved.id)
            let photoOp = PermanentItemPilotOperation(action: "update", vineyardId: vineyard,
                                                       item: saved, draft: PermanentItemPilotDraft(saved),
                                                       photoPath: path)
            saved = try await applyDurably(photoOp)
        }
        editing = saved
        showEditor = false
    }

    private func archive(_ target: PermanentItemPilotRow) async {
        guard permitted, let vineyard, pending == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await applyDurably(PermanentItemPilotOperation(
                action: "archive", vineyardId: vineyard, item: target,
                draft: PermanentItemPilotDraft(target)))
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct PermanentItemPilotEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var locationService
    let existing: PermanentItemPilotRow?
    let paddocks: [Paddock]
    let onSave: (PermanentItemPilotDraft, Data?) async throws -> Void

    @State private var name: String
    @State private var type: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var paddockId: UUID?
    @State private var notes: String
    @State private var camera: MapCameraPosition = .automatic
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var message: String?
    @State private var saving = false

    init(existing: PermanentItemPilotRow?, paddocks: [Paddock],
         onSave: @escaping (PermanentItemPilotDraft, Data?) async throws -> Void) {
        self.existing = existing; self.paddocks = paddocks; self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _type = State(initialValue: existing?.itemType ?? "irrigation_valve")
        _latitude = State(initialValue: existing.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: existing.map { String($0.longitude) } ?? "")
        _paddockId = State(initialValue: existing?.paddockId)
        _notes = State(initialValue: existing?.notes ?? "")
    }

    private var location: CLLocationCoordinate2D? {
        guard let lat = Double(latitude), let lon = Double(longitude),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        Form {
            Section("Fixture") {
                TextField("Name", text: $name).textInputAutocapitalization(.words)
                Picker("Type", selection: $type) {
                    ForEach(PermanentItemsPilotPolicy.types.indices, id: \.self) { index in
                        Text(PermanentItemsPilotPolicy.types[index].label)
                            .tag(PermanentItemsPilotPolicy.types[index].id)
                    }
                }
                Picker("Block (optional)", selection: $paddockId) {
                    Text("No block / outside blocks").tag(UUID?.none)
                    ForEach(paddocks) { paddock in
                        Text(paddock.name).tag(UUID?.some(paddock.id))
                    }
                }
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            }
            Section("Location — tap map or use GPS") {
                HStack {
                    Button("Use Current GPS") {
                        if let coordinate = locationService.location?.coordinate,
                           CLLocationCoordinate2DIsValid(coordinate) {
                            setLocation(coordinate)
                        } else {
                            locationService.requestPermission()
                            locationService.startUpdating()
                            message = "Waiting for a GPS fix. Try again, or tap the map."
                        }
                    }
                    Spacer()
                    if let location {
                        Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                MapReader { proxy in
                    Map(position: $camera) {
                        if let location {
                            Annotation("Fixture", coordinate: location) {
                                Image(systemName: "mappin.circle.fill").font(.largeTitle)
                                    .foregroundStyle(.indigo)
                            }
                        }
                    }
                    .mapStyle(.hybrid)
                    .onTapGesture { point in
                        if let coordinate = proxy.convert(point, from: .local) {
                            setLocation(coordinate)
                        }
                    }
                }
                .frame(height: 250).clipShape(.rect(cornerRadius: 10))
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
            }
            Section("Photo (optional)") {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(imageData == nil ? "Select photo" : "Photo selected", systemImage: "photo")
                }
                if existing?.photoPath != nil {
                    Text("A photo is already attached. Choose another to replace its reference.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }
            Section {
                Button(existing == nil ? "Save Permanent Item" : "Save Changes") {
                    Task {
                        guard !saving else { return }
                        saving = true; defer { saving = false }
                        guard let location else {
                            message = "Choose a valid GPS or map location."; return
                        }
                        var draft = PermanentItemPilotDraft(existing)
                        draft.name = name
                        draft.itemType = type
                        draft.paddockId = paddockId
                        draft.notes = notes.isEmpty ? nil : notes
                        draft.latitude = location.latitude
                        draft.longitude = location.longitude
                        do {
                            try await onSave(draft, imageData)
                            dismiss()
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }.disabled(saving)
            }
        }
        .navigationTitle(existing == nil ? "New Permanent Item" : "Edit Permanent Item")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .task {
            locationService.startUpdating()
            if let location {
                camera = .region(MKCoordinateRegion(
                    center: location,
                    span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)))
            } else if let coordinate = locationService.location?.coordinate,
                      CLLocationCoordinate2DIsValid(coordinate) {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
            }
        }
        .onChange(of: selectedPhoto) { _, newPhoto in
            guard let newPhoto else { return }
            Task {
                do {
                    guard let raw = try await newPhoto.loadTransferable(type: Data.self),
                          let jpeg = PinPhotoStorage.compress(raw, maxEdge: 1600, quality: 0.75),
                          !jpeg.isEmpty, jpeg.count <= 5 * 1024 * 1024 else {
                        throw PermanentItemsPilotError.photo
                    }
                    imageData = jpeg
                    message = nil
                } catch { message = error.localizedDescription }
            }
        }
    }

    private func setLocation(_ coordinate: CLLocationCoordinate2D) {
        latitude = String(coordinate.latitude)
        longitude = String(coordinate.longitude)
        message = nil
        camera = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)))
    }
}
