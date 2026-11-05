import Foundation
import Supabase
import CoreLocation

/// Issue #54. Yield sites are not general Permanent Items or Trip pins.
/// Only confirmed server-readback versions may be used as trip locations.
nonisolated struct YieldSamplingSiteSetRow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let setKey: UUID
    let version: Int
    let name: String
    let status: String
    enum CodingKeys: String, CodingKey {
        case id, vineyardId = "vineyard_id", paddockId = "paddock_id"
        case setKey = "set_key", version, name, status
    }
    var isConfirmed: Bool { status == "confirmed" }
}

nonisolated struct YieldSamplingSiteRow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let siteSetId: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let siteId: UUID
    let siteNumber: Int
    let name: String
    let rowNumber: String?
    let panelNumber: String?
    let latitude: Double
    let longitude: Double
    let notes: String?
    enum CodingKeys: String, CodingKey {
        case id, siteSetId = "site_set_id", vineyardId = "vineyard_id"
        case paddockId = "paddock_id", siteId = "site_id"
        case siteNumber = "site_number", name
        case rowNumber = "row_number", panelNumber = "panel_number"
        case latitude, longitude, notes
    }
}

nonisolated struct YieldSamplingSiteSource: Codable, Equatable, Sendable {
    let setKey: UUID
    let siteSetId: UUID
    let version: Int
    enum CodingKeys: String, CodingKey {
        case setKey, siteSetId, version
    }
}

/// Pure, deterministic geometry check. Boundary points are allowed.
/// For overlapping blocks the caller must ask the operator to choose a block.
nonisolated enum YieldSamplingSiteGeometry {
    static func contains(_ coordinate: CLLocationCoordinate2D, polygon: [CoordinatePoint]) -> Bool {
        guard polygon.count >= 3,
              coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              abs(coordinate.latitude) <= 90, abs(coordinate.longitude) <= 180 else { return false }
        let x = coordinate.longitude, y = coordinate.latitude
        var inside = false
        for i in polygon.indices {
            let j = (i + polygon.count - 1) % polygon.count
            let ax = polygon[j].longitude, ay = polygon[j].latitude
            let bx = polygon[i].longitude, by = polygon[i].latitude
            let cross = (x - ax) * (by - ay) - (y - ay) * (bx - ax)
            if abs(cross) < 1e-11 && x >= min(ax, bx) && x <= max(ax, bx)
                && y >= min(ay, by) && y <= max(ay, by) { return true }
            if (ay > y) != (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax {
                inside.toggle()
            }
        }
        return inside
    }
}

@MainActor
final class SupabaseYieldSamplingSitesRepository {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private func requireOnline() throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
    }

    func listSets(vineyardId: UUID, paddockId: UUID) async throws -> [YieldSamplingSiteSetRow] {
        try requireOnline()
        let rows: [YieldSamplingSiteSetRow] = try await provider.client.from("yield_sample_site_sets")
            .select("id,vineyard_id,paddock_id,set_key,version,name,status")
            .eq("vineyard_id", value: vineyardId.uuidString)
            .eq("paddock_id", value: paddockId.uuidString)
            .order("version", ascending: false).execute().value
        guard rows.allSatisfy({ $0.vineyardId == vineyardId && $0.paddockId == paddockId }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return rows
    }

    func listSites(_ set: YieldSamplingSiteSetRow) async throws -> [YieldSamplingSiteRow] {
        try requireOnline()
        let rows: [YieldSamplingSiteRow] = try await provider.client.from("yield_sample_sites")
            .select("id,site_set_id,vineyard_id,paddock_id,site_id,site_number,name,row_number,panel_number,latitude,longitude,notes")
            .eq("site_set_id", value: set.id.uuidString)
            .eq("vineyard_id", value: set.vineyardId.uuidString)
            .eq("paddock_id", value: set.paddockId.uuidString)
            .order("site_number").execute().value
        guard rows.allSatisfy({ $0.siteSetId == set.id && $0.vineyardId == set.vineyardId
                    && $0.paddockId == set.paddockId }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return rows
    }

    /// Confirmed read-back, not a local cache or merely an RPC acknowledgement.
    func confirmed(vineyardId: UUID, paddockId: UUID) async throws -> (YieldSamplingSiteSetRow, [YieldSamplingSiteRow])? {
        let sets = try await listSets(vineyardId: vineyardId, paddockId: paddockId)
        guard let set = sets.first(where: \.isConfirmed) else { return nil }
        let sites = try await listSites(set)
        // The final confirmed site can be physically deleted. An empty set is
        // no longer a usable sampling source, not a corrupt server response.
        guard !sites.isEmpty else { return nil }
        guard sites.allSatisfy({ $0.siteNumber > 0 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (set, sites)
    }

    private nonisolated struct DraftInput: Encodable, Sendable {
        let id: UUID
        let vineyard_id: UUID
        let paddock_id: UUID
        let set_key: UUID
        let version: Int
        let name: String
        let status: String
    }

    /// Creates a draft revision; copies unchanged physical site IDs from the
    /// last confirmed revision, while keeping old geometry immutable.
    func beginDraft(vineyardId: UUID, paddockId: UUID) async throws -> YieldSamplingSiteSetRow {
        let sets = try await listSets(vineyardId: vineyardId, paddockId: paddockId)
        if let draft = sets.first(where: { $0.status == "draft" }) { return draft }
        let source = sets.first(where: \.isConfirmed)
        let id = UUID()
        let nextVersion = source.map { ancestor in
            (sets.filter { $0.setKey == ancestor.setKey }.map(\.version).max() ?? 0) + 1
        } ?? 1
        let input = DraftInput(id: id, vineyard_id: vineyardId, paddock_id: paddockId,
                               set_key: source?.setKey ?? UUID(), version: nextVersion,
                               name: source?.name ?? "Permanent Yield Sampling Locations", status: "draft")
        let created: [YieldSamplingSiteSetRow] = try await provider.client.from("yield_sample_site_sets")
            .insert(input).select("id,vineyard_id,paddock_id,set_key,version,name,status").execute().value
        guard let draft = created.first, draft.id == id, draft.status == "draft" else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let source {
            let previous = try await listSites(source)
            if !previous.isEmpty {
                let copied = previous.map {
                    YieldSamplingSiteRow(id: UUID(), siteSetId: draft.id,
                        vineyardId: vineyardId, paddockId: paddockId, siteId: $0.siteId,
                        siteNumber: $0.siteNumber, name: $0.name, rowNumber: $0.rowNumber,
                        panelNumber: $0.panelNumber, latitude: $0.latitude,
                        longitude: $0.longitude, notes: $0.notes)
                }
                try await provider.client.from("yield_sample_sites").insert(copied).execute()
                guard try await listSites(draft).count == copied.count else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
        return draft
    }

    /// Add or edit only a draft site. A new physical site receives its own
    /// UUID; editing an existing site keeps its stable UUID through revisions.
    func saveSite(_ input: YieldSamplingSiteRow, set: YieldSamplingSiteSetRow) async throws -> YieldSamplingSiteRow {
        guard set.status == "draft", input.siteSetId == set.id,
              input.vineyardId == set.vineyardId, input.paddockId == set.paddockId,
              input.siteNumber > 0, input.latitude.isFinite, input.longitude.isFinite,
              abs(input.latitude) <= 90, abs(input.longitude) <= 180 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let before = try await listSites(set)
        let result: [YieldSamplingSiteRow]
        if before.contains(where: { $0.id == input.id }) {
            let patch = SitePatch(siteNumber: input.siteNumber, name: input.name,
                rowNumber: input.rowNumber, panelNumber: input.panelNumber,
                latitude: input.latitude, longitude: input.longitude, notes: input.notes)
            result = try await provider.client.from("yield_sample_sites").update(patch)
                .eq("id", value: input.id.uuidString).eq("site_set_id", value: set.id.uuidString)
                .select("id,site_set_id,vineyard_id,paddock_id,site_id,site_number,name,row_number,panel_number,latitude,longitude,notes")
                .execute().value
        } else {
            result = try await provider.client.from("yield_sample_sites").insert(input)
                .select("id,site_set_id,vineyard_id,paddock_id,site_id,site_number,name,row_number,panel_number,latitude,longitude,notes")
                .execute().value
        }
        guard let saved = result.first, saved.id == input.id, saved.siteId == input.siteId,
              saved.latitude == input.latitude, saved.longitude == input.longitude else {
            throw CocoaError(.fileWriteUnknown)
        }
        return saved
    }

    private nonisolated struct SitePatch: Encodable, Sendable {
        let site_number: Int
        let name: String
        let row_number: String?
        let panel_number: String?
        let latitude: Double
        let longitude: Double
        let notes: String?
        init(siteNumber: Int, name: String, rowNumber: String?, panelNumber: String?,
             latitude: Double, longitude: Double, notes: String?) {
            self.site_number = siteNumber
            self.name = name
            self.row_number = rowNumber
            self.panel_number = panelNumber
            self.latitude = latitude
            self.longitude = longitude
            self.notes = notes
        }
    }

    private nonisolated struct SiteDeletionReceipt: Decodable, Sendable {
        let deleted_row_id: UUID
        let site_set_id: UUID
        let vineyard_id: UUID
        let paddock_id: UUID
        let site_id: UUID
        let was_confirmed: Bool
    }

    private nonisolated struct SiteDeleteArgs: Encodable, Sendable {
        let p_id: UUID
        let p_set_id: UUID
        let p_vineyard_id: UUID
        let p_expected_status: String
    }

    /// Real DELETE, including confirmed locations for vineyard leadership.
    /// The trigger records metadata only; geometry is physically removed.
    func hardDeleteSite(_ site: YieldSamplingSiteRow, set: YieldSamplingSiteSetRow) async throws {
        guard ["draft", "confirmed"].contains(set.status),
              site.siteSetId == set.id, site.vineyardId == set.vineyardId,
              site.paddockId == set.paddockId else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let acknowledged: Bool = try await provider.client.rpc("hard_delete_yield_sample_site",
            params: SiteDeleteArgs(p_id: site.id, p_set_id: set.id,
                p_vineyard_id: set.vineyardId, p_expected_status: set.status)).execute().value
        guard acknowledged else { throw CocoaError(.fileWriteUnknown) }
        let receipts: [SiteDeletionReceipt] = try await provider.client
            .from("yield_sample_site_deletion_receipts")
            .select("deleted_row_id,site_set_id,vineyard_id,paddock_id,site_id,was_confirmed")
            .eq("deleted_row_id", value: site.id.uuidString)
            .eq("site_set_id", value: set.id.uuidString)
            .execute().value
        guard receipts.count == 1,
              receipts[0].deleted_row_id == site.id,
              receipts[0].site_set_id == set.id,
              receipts[0].vineyard_id == set.vineyardId,
              receipts[0].paddock_id == site.paddockId,
              receipts[0].site_id == site.siteId,
              receipts[0].was_confirmed == set.isConfirmed,
              !(try await listSites(set)).contains(where: { $0.id == site.id }) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private nonisolated struct SmallSiteId: Decodable, Sendable {
        let id: UUID
    }

    private nonisolated struct ConfirmArgs: Encodable, Sendable {
        let p_set_id: UUID
        let p_expected_version: Int
    }

    func confirm(_ set: YieldSamplingSiteSetRow) async throws -> YieldSamplingSiteSetRow {
        guard set.status == "draft", !(try await listSites(set)).isEmpty else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let _: YieldSamplingSiteSetRow = try await provider.client.rpc(
            "confirm_yield_sample_site_set",
            params: ConfirmArgs(p_set_id: set.id, p_expected_version: set.version)
        ).execute().value
        let verified = try await confirmed(vineyardId: set.vineyardId, paddockId: set.paddockId)
        guard let verified, verified.0.id == set.id, verified.0.version == set.version,
              !(verified.1.isEmpty) else { throw CocoaError(.fileWriteUnknown) }
        return verified.0
    }
}
