import Foundation

nonisolated struct CatalogueDiscoveryContext: Codable, Sendable {
    let jobId: String
    let userId: String
    let vineyardId: UUID
    let query: String
    let country: String
    let inputKind: String
    let photoPath: String?
    let startedAt: Date
}
