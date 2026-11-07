import Foundation
import SwiftUI
import Supabase
import MapKit
import CoreLocation
import PhotosUI
import UIKit

// Issue #53. Vineyard-member feature, separate from ordinary Pins and Trip/Spray sync.
enum PermanentItemsPilotPolicy {
    /// Server RLS and the permissions RPC make the authorization decision.
    /// Do not block this lookup on the unrelated Home role-cache refresh:
    /// that can complete after .task(id:) has already run.
    static func mayCheckVineyardAccess(isSignedIn: Bool, userId: UUID?, vineyardId: UUID?) -> Bool {
        isSignedIn && userId != nil && vineyardId != nil
    }
    static func roleMayHardDelete(_ role: BackendRole?) -> Bool {
        role == .owner || role == .manager || role == .supervisor
    }
    static let types: [(id: String, label: String, hex: String)] = [
        ("irrigation_valve", "Irrigation Valve", "#2D6CDF"),
        ("flush_valve", "Flush Valve", "#00A3B8"),
        ("pump", "Pump", "#7856D8"),
        ("filter", "Filter", "#0D9488"),
        ("tank", "Tank", "#249B58"),
        ("gate", "Gate", "#D97706"),
        ("water_point", "Water Point", "#1F82C7"),
        ("other", "Other", "#A8559A")
    ]
    static func valid(name: String, type: String, latitude: Double, longitude: Double) -> Bool {
        (1...100).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
            && (types.contains(where: { $0.id == type })
                || type.range(of: #"^custom_[0-9a-f]{32}$"#, options: .regularExpression) != nil)
            && latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    static func label(_ type: String, custom: [PermanentItemPilotType] = []) -> String {
        custom.first(where: { $0.typeKey == type })?.name
            ?? types.first(where: { $0.id == type })?.label ?? "Other"
    }
    static func hex(_ type: String, custom: [PermanentItemPilotType] = []) -> String {
        custom.first(where: { $0.typeKey == type })?.colorHex
            ?? types.first(where: { $0.id == type })?.hex ?? "#A8559A"
    }
    static func color(_ type: String, custom: [PermanentItemPilotType] = []) -> Color {
        let hex = hex(type, custom: custom)
        guard let rgb = UInt64(hex.dropFirst(), radix: 16) else { return .purple }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}

struct PermanentItemPilotType: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let typeKey: String
    let name: String
    let colorHex: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case vineyardId = "vineyard_id", typeKey = "type_key", colorHex = "color_hex"
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


private struct PermanentItemPilotPermissions: Decodable {
    let canRead: Bool
    let canManage: Bool
    let canHardDelete: Bool
    enum CodingKeys: String, CodingKey {
        case canRead = "can_read", canManage = "can_manage", canHardDelete = "can_hard_delete"
    }
}

private struct PermanentItemHardDeleteIntent: Codable, Sendable {
    let p_operation_id: UUID
    let p_item_id: UUID
    let p_vineyard_id: UUID
    let p_expected_revision: Int64

    init(item: PermanentItemPilotRow) {
        p_operation_id = UUID()
        p_item_id = item.id
        p_vineyard_id = item.vineyardId
        p_expected_revision = item.serverRevision
    }
}

private struct PermanentItemHardDeleteResponse: Decodable {
    let deleted: Bool
    let photoCleanupPending: Bool
    let itemId: UUID
    let operationId: UUID
    enum CodingKeys: String, CodingKey {
        case deleted
        case photoCleanupPending = "photo_cleanup_pending"
        case itemId = "item_id", operationId = "operation_id"
    }
}

private struct PermanentItemPermissionParams: Encodable {
    let p_vineyard_id: UUID
}

private struct PermanentItemTypeCreateParams: Encodable {
    let p_vineyard_id: UUID
    let p_name: String
    let p_color_hex: String
}

/// Postgres returns float8 with 15 significant digits (extra_float_digits = 0),
/// so a GPS value such as -33.29641018308584 reads back as -33.2964101830858.
/// Exact equality made every successful save look unverified. 1e-9 degrees is
/// about 0.1 mm, far below GPS precision but still catches a real mismatch.
enum PermanentItemPilotCoordinate {
    static let tolerance = 1e-9
    static func same(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) <= tolerance
        default: return false
        }
    }
}

private struct PermanentItemPilotRepository {
    private let client = SupabaseClientProvider.shared.client

    func permissions(vineyardId: UUID) async throws -> PermanentItemPilotPermissions {
        let rows: [PermanentItemPilotPermissions] = try await client.rpc(
            "permanent_item_permissions_v1",
            params: PermanentItemPermissionParams(p_vineyard_id: vineyardId)
        ).execute().value
        guard rows.count == 1, let permission = rows.first else {
            throw PermanentItemsPilotError.receipt
        }
        return permission
    }

    func hardDelete(_ op: PermanentItemHardDeleteIntent) async throws {
        let receipt: PermanentItemHardDeleteResponse = try await client.functions.invoke(
            "permanent-item-hard-delete-v1",
            options: FunctionInvokeOptions(body: op)
        )
        guard receipt.deleted, !receipt.photoCleanupPending,
              receipt.itemId == op.p_item_id,
              receipt.operationId == op.p_operation_id else {
            throw PermanentItemsPilotError.receipt
        }
    }

    func listTypes(vineyardId: UUID) async throws -> [PermanentItemPilotType] {
        try await client.from("permanent_item_types")
            .select("id,vineyard_id,type_key,name,color_hex")
            .eq("vineyard_id", value: vineyardId.uuidString.lowercased())
            .execute().value
    }

    func createType(vineyardId: UUID, name: String, hex: String) async throws -> PermanentItemPilotType {
        let rows: [PermanentItemPilotType] = try await client.rpc(
            "create_permanent_item_type_v1",
            params: PermanentItemTypeCreateParams(p_vineyard_id: vineyardId,
                                                  p_name: name, p_color_hex: hex)
        ).execute().value
        guard rows.count == 1, let row = rows.first,
              row.vineyardId == vineyardId, row.name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              row.colorHex.caseInsensitiveCompare(hex) == .orderedSame else {
            throw PermanentItemsPilotError.receipt
        }
        return row
    }

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
               PermanentItemPilotCoordinate.same(row.latitude, op.p_latitude) &&
               PermanentItemPilotCoordinate.same(row.longitude, op.p_longitude) &&
               row.paddockId == op.p_paddock_id && row.notes == op.p_notes &&
               row.photoPath == op.p_photo_path) else {
            throw PermanentItemsPilotError.receipt
        }
        return row
    }

    /// Private photo download; storage RLS allows active vineyard members only.
    func downloadPhoto(path: String) async throws -> Data {
        try await client.storage.from("permanent-item-photos").download(path: path)
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

/// Every signed-in vineyard member may open this shortcut. The destination
/// independently checks server-authoritative membership before showing data.
struct PermanentItemsPilotShortcut: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var grants: PermanentItemPilotPermissions?

    private var vineyard: UUID? { store.selectedVineyardId }
    private var validScope: Bool {
        PermanentItemsPilotPolicy.mayCheckVineyardAccess(
            isSignedIn: auth.isSignedIn, userId: auth.userId, vineyardId: vineyard)
    }
    // Changes when the account/vineyard/foreground session changes, not when
    // the unrelated BackendAccessControl role cache finishes loading.
    // This avoids a missing shortcut after a cold start with no cached role.
    private var scope: String {
        "\(auth.userId?.uuidString ?? "none")|\(vineyard?.uuidString ?? "none")|\(auth.isSignedIn)|\(auth.completedSignOutSequence)|\(scenePhase == .active)"
    }
    private var isVisible: Bool { validScope }
    private var subtitle: String {
        if grants?.canRead == true { return "Fixed property assets" }
        if grants?.canRead == false { return "Vineyard access required" }
        return "Checking vineyard access"
    }

    var body: some View {
        Group {
            if isVisible {
                NavigationLink {
                    // The visible entry cannot bypass server-authorised vineyard access.
                    PermanentItemsAdminPilotView()
                } label: {
                    HStack(spacing: 12) {
                        BrightToolIcon(symbol: "mappin.circle.fill",
                                       colors: [.indigo, .purple], size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Permanent Item").font(.subheadline.weight(.semibold))
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }.foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(
                        LinearGradient(colors: [.indigo, .purple],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 14)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
        .task(id: scope) {
            // Fail closed for every scope change, including a new account,
            // a different vineyard, sign out or a foreground revalidation.
            grants = nil
            guard validScope, let vineyard else { return }
            let capturedScope = scope
            do {
                let value = try await PermanentItemPilotRepository()
                    .permissions(vineyardId: vineyard)
                guard !Task.isCancelled, capturedScope == scope,
                      validScope else { return }
                grants = value
            } catch {
                // Keep the shortcut for a member to retry; no data is shown without server permission.
            }
        }
    }
}

/// Permanent Item writes are isolated from Pins / Trip / Spray journals.
/// A single retryable operation is stored under the exact signed-in account+vineyard.
/// A server timeout NEVER generates a second UUID; no "Synced" before readback.
struct PermanentItemsAdminPilotView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @State private var permissions: PermanentItemPilotPermissions?
    @State private var permissionCheckComplete = false
    @State private var rows: [PermanentItemPilotRow] = []
    @State private var customTypes: [PermanentItemPilotType] = []
    @State private var search = ""
    @State private var showEditor = false
    @State private var editing: PermanentItemPilotRow?
    @State private var pending: PermanentItemPilotOperation?
    @State private var busy = false
    @State private var message: String?
    @State private var typeFilter: String?
    @State private var directionsItem: PermanentItemPilotRow?
    @State private var photoItem: PermanentItemPilotRow?
    @State private var deleteTarget: PermanentItemPilotRow?
    @State private var pendingDelete: PermanentItemHardDeleteIntent?
    @State private var camera: MapCameraPosition = .automatic
    private let repository = PermanentItemPilotRepository()

    private var account: UUID? { auth.userId }
    private var vineyard: UUID? { store.selectedVineyardId }
    private var scope: String {
        "\(account?.uuidString ?? "signed-out")|\(vineyard?.uuidString ?? "none")|\(auth.isSignedIn)|\(auth.completedSignOutSequence)"
    }
    private var validScope: Bool {
        PermanentItemsPilotPolicy.mayCheckVineyardAccess(
            isSignedIn: auth.isSignedIn, userId: account, vineyardId: vineyard)
    }
    private var permitted: Bool { validScope && permissions?.canRead == true }
    private var canManage: Bool { permitted && permissions?.canManage == true }
    // The server computes this exclusively from the verified vineyard role:
    // Supervisor, Manager or Owner, never System Admin alone. Its decision
    // must not be overridden by a stale/missing Home role cache.
    private var canHardDelete: Bool { permitted && permissions?.canHardDelete == true }
    private var pendingDeleteKey: String {
        "permanent-item-hard-delete-v1|\(account?.uuidString ?? "none")|\(vineyard?.uuidString ?? "none")"
    }
    private var pendingKey: String {
        "permanent-item-op-v1|\(account?.uuidString ?? "none")|\(vineyard?.uuidString ?? "none")"
    }
    private var activeRows: [PermanentItemPilotRow] { rows.filter { $0.archivedAt == nil } }
    private var typesPresent: [String] {
        Array(Set(activeRows.map(\.itemType)))
            .sorted { PermanentItemsPilotPolicy.label($0, custom: customTypes)
                < PermanentItemsPilotPolicy.label($1, custom: customTypes) }
    }
    /// A filter whose type no longer has any items falls back to All.
    private var activeFilter: String? {
        guard let typeFilter, typesPresent.contains(typeFilter) else { return nil }
        return typeFilter
    }
    private var visible: [PermanentItemPilotRow] {
        activeRows.filter { (activeFilter == nil || $0.itemType == activeFilter) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) ||
             PermanentItemsPilotPolicy.label($0.itemType, custom: customTypes).localizedCaseInsensitiveContains(search)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var actionsDisabled: Bool { busy || pending != nil || pendingDelete != nil }

    @ViewBuilder
    private var typeFilterBar: some View {
        if typesPresent.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All", color: nil, selected: activeFilter == nil) { typeFilter = nil }
                    ForEach(typesPresent, id: \.self) { key in
                        filterChip(PermanentItemsPilotPolicy.label(key, custom: customTypes),
                                   color: PermanentItemsPilotPolicy.color(key, custom: customTypes),
                                   selected: activeFilter == key) {
                            typeFilter = activeFilter == key ? nil : key
                        }
                    }
                }
            }
        }
    }

    private func filterChip(_ title: String, color: Color?, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 10, height: 10) }
                Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? Color.blue : Color.primary)
            .background(selected ? Color.blue.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground),
                        in: .capsule)
            .overlay(Capsule().stroke(selected ? Color.blue.opacity(0.6) : Color(uiColor: .separator),
                                      lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Group {
            if !permitted {
                if validScope && !permissionCheckComplete {
                    ProgressView("Checking Permanent Items access…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Permanent Items unavailable",
                        systemImage: "lock.shield",
                        description: Text(
                            message ?? "Access requires signed-in membership of the selected vineyard."
                        )
                    )
                }
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
                        if let pendingDelete {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("A delete is still pending",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.footnote.bold())
                                Text("Item \(pendingDelete.p_item_id.uuidString.prefix(8)); no second delete will be started.")
                                    .font(.caption)
                                Button("Retry delete") {
                                    Task { await retryHardDelete() }
                                }.disabled(!canHardDelete || busy)
                            }
                            .padding().background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                        }
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        if canManage {
                            Button {
                                editing = nil
                                showEditor = true
                            } label: {
                                Label("New Permanent Item", systemImage: "mappin.and.ellipse")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || pending != nil || pendingDelete != nil)
                        }
                        typeFilterBar
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search permanent items", text: $search)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                            if !search.isEmpty {
                                Button { search = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }.accessibilityLabel("Clear search")
                            }
                        }
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: .rect(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11)
                            .stroke(Color(uiColor: .separator), lineWidth: 0.6))
                        Map(position: $camera) {
                            ForEach(store.paddocks) { block in
                                if block.polygonPoints.count >= 3 {
                                    MapPolygon(coordinates: block.polygonPoints.map {
                                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                    })
                                    .foregroundStyle(.yellow.opacity(0.10))
                                    .stroke(.yellow.opacity(0.9), lineWidth: 2)
                                }
                            }
                            // The map shows the same filtered items as the list.
                            ForEach(visible) { item in
                                Annotation(item.name, coordinate: item.coordinate) {
                                    Button {
                                        if canManage {
                                            editing = item
                                            showEditor = true
                                        } else if canHardDelete {
                                            deleteTarget = item
                                        }
                                    } label: {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(PermanentItemsPilotPolicy.color(
                                                item.itemType, custom: customTypes))
                                            .padding(3)
                                            .background(.white, in: .circle)
                                    }.accessibilityLabel("Permanent Item: \(item.name)")
                                }
                            }
                        }
                        .mapStyle(.hybrid)
                        .frame(height: 290)
                        .clipShape(.rect(cornerRadius: 12))
                        ForEach(visible) { item in
                            PermanentItemListRow(
                                item: item,
                                typeLabel: PermanentItemsPilotPolicy.label(item.itemType, custom: customTypes),
                                color: PermanentItemsPilotPolicy.color(item.itemType, custom: customTypes),
                                blockName: store.paddocks.first { $0.id == item.paddockId }?.name,
                                canEdit: canManage,
                                canDelete: canHardDelete,
                                onViewImage: item.photoPath == nil ? nil : { photoItem = item },
                                onOpen: {
                                    guard !actionsDisabled else { return }
                                    if canManage { editing = item; showEditor = true }
                                },
                                onDirections: { directionsItem = item },
                                onEdit: {
                                    guard !actionsDisabled else { return }
                                    editing = item; showEditor = true
                                },
                                onDelete: {
                                    guard !actionsDisabled else { return }
                                    deleteTarget = item
                                }
                            )
                        }
                        if !busy && visible.isEmpty {
                            Text(activeRows.isEmpty ? "No Permanent Items yet." : "No Permanent Items match this filter.")
                                .foregroundStyle(.secondary)
                        }
                    }.padding()
                }
            }
        }
        .navigationTitle("Permanent Items")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reloadPermissions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Retry Permanent Items access")
                .disabled(!validScope || busy)
            }
        }
        .task(id: scope) {
            rows = []; customTypes = []; permissions = nil
            permissionCheckComplete = false; message = nil
            pending = nil; pendingDelete = nil; editing = nil; showEditor = false
            deleteTarget = nil
            await reloadPermissions()
        }
        .onChange(of: scope) { _, _ in
            rows = []; customTypes = []; permissions = nil
            permissionCheckComplete = false; message = nil
            pending = nil; pendingDelete = nil
            editing = nil; showEditor = false; deleteTarget = nil
        }
        .sheet(isPresented: $showEditor) {
            if let vineyard {
                NavigationStack {
                    PermanentItemPilotEditor(
                        existing: editing, paddocks: store.paddocks, customTypes: customTypes,
                        onCreateType: { name, hex in try await createCustomType(name: name, hex: hex) },
                        onSave: { draft, image in try await save(draft, image: image) }
                    )
                }.id("\(scope)|\(editing?.id.uuidString ?? "new")")
            }
        }
        .confirmationDialog(
            deleteTarget.map { "Delete \($0.name)?" } ?? "Delete Permanent Item?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { Task { await hardDelete(target) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This cannot be undone. The item and its photos will be removed from iOS, Android and Portal.")
        }
        .fullScreenCover(item: $photoItem) { item in
            if let path = item.photoPath {
                PermanentItemPhotoLoader(path: path, repository: repository)
            }
        }
        .sheet(item: $directionsItem) { item in
            PermanentItemDirectionsSheet(
                title: item.name,
                coordinate: item.coordinate,
                color: PermanentItemsPilotPolicy.color(item.itemType, custom: customTypes)
            )
        }
    }

    private func reloadPermissions() async {
        permissions = nil
        permissionCheckComplete = false
        message = nil
        guard validScope, let vineyard else { return }
        let capturedScope = scope
        do {
            let grant = try await repository.permissions(vineyardId: vineyard)
            guard !Task.isCancelled, validScope,
                  capturedScope == scope else { return }
            permissions = grant
            permissionCheckComplete = true
            if grant.canRead {
                await load()
            } else {
                message = "This account is not authorised for Permanent Items in the selected vineyard. Check membership or select a vineyard you belong to."
            }
        } catch {
            if capturedScope == scope {
                permissionCheckComplete = true
                message = "Could not check Permanent Items access: \(error.localizedDescription). Tap refresh to retry."
            }
        }
    }

    private func isCurrent(_ captured: String) -> Bool { captured == scope && permitted }

    private func load() async {
        guard permitted, let vineyard else { return }
        let captured = scope
        pending = UserDefaults.standard.data(forKey: pendingKey)
            .flatMap { try? JSONDecoder().decode(PermanentItemPilotOperation.self, from: $0) }
        pendingDelete = UserDefaults.standard.data(forKey: pendingDeleteKey)
            .flatMap { try? JSONDecoder().decode(PermanentItemHardDeleteIntent.self, from: $0) }
        do {
            let result = try await repository.list(vineyardId: vineyard)
            guard isCurrent(captured) else { return }
            rows = result
            do {
                let options = try await repository.listTypes(vineyardId: vineyard)
                if isCurrent(captured) { customTypes = options }
            } catch {
                if isCurrent(captured) { message = "Couldn't load vineyard types: \(error.localizedDescription)" }
            }
        } catch {
            if isCurrent(captured) { message = "Couldn't load Permanent Items: \(error.localizedDescription)" }
        }
    }

    private func applyDurably(_ operation: PermanentItemPilotOperation) async throws -> PermanentItemPilotRow {
        guard canManage, operation.p_vineyard_id == vineyard, let account else {
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
        message = "Saved"
        return result
    }

    private func retryPending() async {
        guard let pending, !busy else { return }
        busy = true; defer { busy = false }
        do { _ = try await applyDurably(pending) }
        catch { message = error.localizedDescription }
    }

    private func save(_ draft: PermanentItemPilotDraft, image: Data?) async throws {
        guard canManage, let vineyard else { throw PermanentItemsPilotError.unavailable }
        guard PermanentItemsPilotPolicy.valid(name: draft.name, type: draft.itemType,
                                               latitude: draft.latitude, longitude: draft.longitude) else {
            throw PermanentItemsPilotError.invalid
        }
        guard pending == nil, pendingDelete == nil, !busy else { throw PermanentItemsPilotError.pending }
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

    private func createCustomType(name: String, hex: String) async throws -> PermanentItemPilotType {
        guard canManage, let vineyard else { throw PermanentItemsPilotError.unavailable }
        let captured = scope
        let row = try await repository.createType(vineyardId: vineyard, name: name, hex: hex)
        guard isCurrent(captured) else { throw PermanentItemsPilotError.wrongScope }
        if !customTypes.contains(where: { $0.id == row.id }) { customTypes.append(row) }
        return row
    }

    private func hardDelete(_ target: PermanentItemPilotRow) async {
        guard canHardDelete, let vineyard,
              target.vineyardId == vineyard, pending == nil, !busy else { return }
        if let prior = pendingDelete, prior.p_item_id != target.id {
            message = "Finish the previous permanent deletion before starting another."
            return
        }
        let operation = pendingDelete ?? PermanentItemHardDeleteIntent(item: target)
        await sendHardDelete(operation)
    }

    private func retryHardDelete() async {
        guard let operation = pendingDelete, canHardDelete, !busy else { return }
        await sendHardDelete(operation)
    }

    private func sendHardDelete(_ operation: PermanentItemHardDeleteIntent) async {
        guard canHardDelete, let account, let vineyard,
              operation.p_vineyard_id == vineyard, !busy else { return }
        let capturedScope = scope
        let key = pendingDeleteKey
        guard let data = try? JSONEncoder().encode(operation) else {
            message = "Couldn't save deletion intent on device."
            return
        }
        // Keep the same UUID across network failure and photo cleanup retries.
        UserDefaults.standard.set(data, forKey: key)
        guard UserDefaults.standard.data(forKey: key) == data else {
            message = "Couldn't retain deletion intent; nothing was sent."
            return
        }
        pendingDelete = operation
        busy = true
        defer { busy = false }
        do {
            try await repository.hardDelete(operation)
            guard scope == capturedScope, account == auth.userId,
                  canHardDelete else { return }
            UserDefaults.standard.removeObject(forKey: key)
            pendingDelete = nil
            rows.removeAll { $0.id == operation.p_item_id }
            message = "Permanently deleted from all platforms; attached photos removed."
        } catch {
            if scope == capturedScope {
                message = "Delete outcome or photo cleanup not fully confirmed. Retry the same operation: \(error.localizedDescription)"
            }
        }
    }

    private func archive(_ target: PermanentItemPilotRow) async {
        guard canManage, let vineyard, pending == nil, pendingDelete == nil, !busy else { return }
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
    let customTypes: [PermanentItemPilotType]
    let onCreateType: (String, String) async throws -> PermanentItemPilotType
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
    @State private var addedTypes: [PermanentItemPilotType] = []
    @State private var showNewType = false
    @State private var newTypeName = ""
    @State private var newTypeColor: Color = .purple
    @State private var savingType = false
    @State private var typeError: String?
    @State private var showPhotoOptions = false
    @State private var showLibrary = false
    @State private var showCamera = false

    // A newly-created server type is reflected in parent state as well as this
    // in-flight editor. Avoid duplicate Picker IDs on that parent rerender.
    private var typeOptions: [PermanentItemPilotType] {
        customTypes.filter { existing in
            !addedTypes.contains(where: { $0.id == existing.id })
        } + addedTypes
    }

    init(existing: PermanentItemPilotRow?, paddocks: [Paddock],
         customTypes: [PermanentItemPilotType],
         onCreateType: @escaping (String, String) async throws -> PermanentItemPilotType,
         onSave: @escaping (PermanentItemPilotDraft, Data?) async throws -> Void) {
        self.existing = existing; self.paddocks = paddocks
        self.customTypes = customTypes; self.onCreateType = onCreateType; self.onSave = onSave
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
                HStack {
                    Picker("Type", selection: $type) {
                        ForEach(PermanentItemsPilotPolicy.types.indices, id: \.self) { index in
                            Text(PermanentItemsPilotPolicy.types[index].label)
                                .tag(PermanentItemsPilotPolicy.types[index].id)
                        }
                        ForEach(typeOptions) { entry in
                            Text(entry.name).tag(entry.typeKey)
                        }
                    }
                    Button { showNewType = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(VineyardTheme.actionBlue)
                    }
                    .accessibilityLabel("Add a custom vineyard type")
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    Circle().fill(PermanentItemsPilotPolicy.color(
                        type, custom: typeOptions))
                        .frame(width: 14, height: 14)
                    Text("Pin colour")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(PermanentItemsPilotPolicy.hex(
                        type, custom: typeOptions))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
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
                Button {
                    if let coordinate = locationService.location?.coordinate,
                       CLLocationCoordinate2DIsValid(coordinate) {
                        setLocation(coordinate)
                    } else {
                        locationService.requestPermission()
                        locationService.startUpdating()
                        message = "Waiting for a GPS fix. Try again, or tap the map."
                    }
                } label: {
                    Label("Drop Permanent Pin Here", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(VineyardTheme.actionBlue)
                HStack {
                    if let location {
                        Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Text("No pin dropped").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Pin", role: .destructive) {
                        latitude = ""
                        longitude = ""
                        message = nil
                    }
                    .disabled(location == nil)
                }
                MapReader { proxy in
                    Map(position: $camera) {
                        ForEach(paddocks) { block in
                            if block.polygonPoints.count >= 3 {
                                MapPolygon(coordinates: block.polygonPoints.map {
                                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                })
                                .foregroundStyle(.yellow.opacity(0.10))
                                .stroke(.yellow.opacity(0.9), lineWidth: 2)
                            }
                        }
                        if let location {
                            Annotation("Fixture", coordinate: location) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(PermanentItemsPilotPolicy.color(
                                        type, custom: typeOptions))
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
                Button {
                    showPhotoOptions = true
                } label: {
                    Label(imageData == nil ? "Add Photo" : "Change Photo",
                          systemImage: "camera")
                }
                if imageData != nil {
                    Label("Photo ready to attach", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if existing?.photoPath != nil {
                    Text("An existing photo is attached. You can take a new one or upload another.")
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
        .sheet(isPresented: $showNewType) {
            NavigationStack {
                Form {
                    TextField("New custom type name", text: $newTypeName)
                        .textInputAutocapitalization(.words)
                    ColorPicker("Pin colour", selection: $newTypeColor, supportsOpacity: false)
                    if let typeError {
                        Text(typeError).foregroundStyle(.red).font(.footnote)
                    }
                }
                .navigationTitle("Add Vineyard Type")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showNewType = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add Type") {
                            Task {
                                guard !savingType else { return }
                                savingType = true
                                defer { savingType = false }
                                let normalized = newTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard (1...60).contains(normalized.count) else {
                                    typeError = "Enter a type name of up to 60 characters."
                                    return
                                }
                                let uiColor = UIColor(newTypeColor)
                                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                                guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                                    typeError = "Choose a valid colour."
                                    return
                                }
                                let hex = String(format: "#%02X%02X%02X",
                                                 Int(red * 255), Int(green * 255), Int(blue * 255))
                                do {
                                    let created = try await onCreateType(normalized, hex)
                                    addedTypes.append(created)
                                    type = created.typeKey
                                    newTypeName = ""
                                    typeError = nil
                                    showNewType = false
                                } catch {
                                    typeError = error.localizedDescription
                                }
                            }
                        }
                        .disabled(savingType || newTypeName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("Attach a photo", isPresented: $showPhotoOptions) {
            Button("Take Photo") {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = true
                } else {
                    message = "Camera unavailable on this device. Choose a photo instead."
                }
            }
            Button("Choose from Library") { showLibrary = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showLibrary, selection: $selectedPhoto, matching: .images)
        .sheet(isPresented: $showCamera) {
            PermanentItemCameraPicker { captured in
                guard let captured,
                      let jpeg = PinPhotoStorage.compress(captured, maxEdge: 1600, quality: 0.75),
                      jpeg.count <= 5 * 1024 * 1024 else {
                    message = "Could not prepare camera photo (5 MiB maximum)."
                    return
                }
                imageData = jpeg
                message = nil
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


/// Camera capture is intentionally isolated to the Permanent Items editor.
private struct PermanentItemCameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
        deinit {}
        var parent: PermanentItemCameraPicker
        init(_ parent: PermanentItemCameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.85)
            parent.onCapture(data)
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Pins-list style row: header bar in the item's pin colour and compact actions.
private struct PermanentItemListRow: View {
    let item: PermanentItemPilotRow
    let typeLabel: String
    let color: Color
    let blockName: String?
    let canEdit: Bool
    let canDelete: Bool
    /// Non-nil only when the item has a photo.
    let onViewImage: (() -> Void)?
    let onOpen: () -> Void
    let onDirections: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.white)
                    Text(item.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold()).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.gradient)
                .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(typeLabel + (blockName.map { " · \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold))
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            HStack(spacing: 0) {
                if let onViewImage {
                    ActionButton(icon: "photo", label: "View Image", color: .purple, action: onViewImage)
                    Spacer()
                }
                ActionButton(icon: "arrow.triangle.turn.up.right.diamond", label: "Directions",
                             color: VineyardTheme.leafGreen, action: onDirections)
                if canEdit {
                    Spacer()
                    ActionButton(icon: "pencil", label: "Edit", color: .blue, action: onEdit)
                }
                if canDelete {
                    Spacer()
                    ActionButton(icon: "trash", label: "Delete", color: .red, action: onDelete)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

/// Direct-line directions to a Permanent Item (same as the Pins directions sheet).
private struct PermanentItemDirectionsSheet: View {
    let title: String
    let coordinate: CLLocationCoordinate2D
    let color: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var locationService
    @Environment(MigratedDataStore.self) private var store
    @State private var position: MapCameraPosition = .automatic

    private var userCoordinate: CLLocationCoordinate2D? { locationService.location?.coordinate }

    private var distanceText: String {
        guard let userLocation = locationService.location else { return "—" }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return "\(store.settings.regionFormatter.formatShortDistance(metres: userLocation.distance(from: target))) away"
    }

    private var bearing: Double {
        guard let user = userCoordinate else { return 0 }
        let lat1 = user.latitude * .pi / 180
        let lat2 = coordinate.latitude * .pi / 180
        let dLon = (coordinate.longitude - user.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $position) {
                    Annotation(title, coordinate: coordinate) {
                        ZStack {
                            Circle().fill(color.gradient).frame(width: 36, height: 36)
                            Image(systemName: "mappin").font(.caption.bold()).foregroundStyle(.white)
                        }
                    }
                    if let user = userCoordinate {
                        MapPolyline(coordinates: [user, coordinate])
                            .stroke(.blue, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    }
                    UserAnnotation()
                }
                .mapStyle(.hybrid)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(distanceText).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "location.north.line")
                        .font(.title2)
                        .foregroundStyle(VineyardTheme.info)
                        .rotationEffect(.degrees(bearing))
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
            }
            .navigationTitle("Directions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear {
                locationService.requestPermission()
                locationService.startUpdating()
            }
        }
    }
}

/// Loads a private Permanent Item photo, then shows it full screen (Pins viewer).
private struct PermanentItemPhotoLoader: View {
    let path: String
    let repository: PermanentItemPilotRepository
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                PhotoViewerSheet(image: image)
            } else {
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        if failed {
                            Text("Could not load the photo. Check your connection and try again.")
                                .foregroundStyle(.white).multilineTextAlignment(.center).padding()
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                    }
                }
            }
        }
        .task(id: path) {
            do {
                let data = try await repository.downloadPhoto(path: path)
                if let decoded = UIImage(data: data) { image = decoded } else { failed = true }
            } catch {
                failed = true
            }
        }
    }
}
