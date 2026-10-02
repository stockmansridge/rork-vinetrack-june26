import Foundation

@MainActor protocol CatalogueBackendProtocol {
    func search(query: String, country: String) async throws -> [CatalogueWire]
    func revision(_ id: String) async throws -> CatalogueWire
    func job(_ id: String) async throws -> CatalogueWire
    func invoke(_ id: String) async throws
    func photo(_ data: Data) async throws -> String
    func rpc(_ name: String, _ params: [String: SprayReportPayloadV1.JSONValue]) async throws -> [CatalogueWire]
    func add(revisionId: String, vineyardId: UUID) async throws -> SavedChemical
}
