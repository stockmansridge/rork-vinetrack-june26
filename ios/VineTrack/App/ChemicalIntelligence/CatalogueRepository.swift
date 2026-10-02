import Foundation
import Supabase

@MainActor
final class CatalogueRepository: CatalogueBackendProtocol {
    private var client: SupabaseClient { SupabaseClientProvider.shared.client }
    func rpc(_ name: String, _ params: [String: SprayReportPayloadV1.JSONValue]) async throws -> [CatalogueWire] {
        try await client.rpc(name, params: params).execute().value
    }
    func search(query: String, country: String) async throws -> [CatalogueWire] {
        try await rpc("search_chemical_v3_catalogue", ["p_query": .string(query), "p_country_code": country.isEmpty ? .null : .string(country), "p_limit": .number(20)])
    }
    func revision(_ id: String) async throws -> CatalogueWire {
        let row: CatalogueWire = try await client.from("chemical_v3_product_revisions").select().eq("id", value: id).single().execute().value
        guard row.id.lowercased() == id.lowercased() else { throw BackendRepositoryError.emptyResponse }
        return row
    }
    func job(_ id: String) async throws -> CatalogueWire {
        try await client.from("chemical_v3_discovery_jobs").select("id,status,stage,revision_id,product_id,progress_percent,user_message").eq("id", value: id).single().execute().value
    }
    func invoke(_ id: String) async throws {
        let _: CatalogueWire = try await client.functions.invoke("chemical-lookup-v3", options: FunctionInvokeOptions(body: ["action": "start", "job_id": id]))
    }
    func photo(_ data: Data) async throws -> String {
        let user = try await client.auth.session.user.id.uuidString.lowercased()
        let path = "search-inputs/\(user)/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from("chemical-v3-media").upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
        return path
    }
    func media(_ path: String) async throws -> Data {
        try await client.storage.from("chemical-v3-media").download(path: path)
    }
    func add(revisionId: String, vineyardId: UUID) async throws -> SavedChemical {
        let rows = try await rpc("chemical_v3_add_to_vineyard", ["p_revision_id": .string(revisionId), "p_vineyard_id": .string(vineyardId.uuidString), "p_opening_quantity": .null, "p_opening_unit": .null])
        guard let id = rows.first?.text("saved_chemical_id") else { throw BackendRepositoryError.emptyResponse }
        let backend: BackendSavedChemical = try await client.from("saved_chemicals").select().eq("id", value: id).eq("vineyard_id", value: vineyardId.uuidString).single().execute().value
        guard backend.id.uuidString.lowercased() == id.lowercased() else { throw BackendRepositoryError.emptyResponse }
        return backend.toSavedChemical()
    }
}
